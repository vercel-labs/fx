const std = @import("std");
const execution_observation = @import("../agent/runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const approval_registry = @import("approval_registry.zig");
const reports = @import("reports.zig");
const agents = @import("../agents/agents.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const managed_owner = @import("managed_owner.zig");
const session_adapter = @import("../session/session_adapter.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const live_metrics = @import("live_metrics.zig");
const activity_status = @import("../output/activity_status.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const model_contract = @import("model_contract.zig");
const refusal = @import("refusal.zig");
const start_test_controls = @import("start_test_controls.zig");
const end_test_controls = @import("end_test_controls.zig");
const close_test_controls = @import("close_test_controls.zig");
const publish_test_controls = @import("publish_test_controls.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const execution_memory = @import("../agent/execution_memory.zig");
const io_mod = @import("../shared/io.zig");
const testing_event = @import("../shared/testing_event.zig");
const profiles = @import("../profiles/profiles.zig");
const started_with_mod = @import("../profiles/started_with.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const toolbox_core = @import("../tooling/toolbox.zig");
const types = @import("../shared/types.zig");
const usage_ledger = @import("usage_ledger.zig");

const Allocator = std.mem.Allocator;
/// Bounds how long a parent wait takes to observe cancellation or steering,
/// and how long the polling loops take to see a child change. The terminal
/// result wait also wakes on child state changes. Status publishing is rate
/// limited separately, so a short pulse only adds cheap wakeups.
pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    /// Where the host runs each child turn on a child agent of its own:
    /// binds the run's turn to that agent's worker before it starts.
    bind_fn: ?*const fn (
        ?*anyopaque,
        *execution.TurnContext,
        *std.atomic.Value(bool),
    ) execution.ServiceError!void = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

/// fx's note from a subagent whose command crossed the quiet limit, as its
/// parent reads it. `command` is already one terminal-safe line.
fn quietNoteText(writer: *std.Io.Writer, command: []const u8, quiet_ms: u64) std.Io.Writer.Error!void {
    try writer.print("fx: my command `{s}` has had no output for ", .{command});
    try activity_status.writeElapsed(writer, @intCast(quiet_ms / std.time.ms_per_s));
    try writer.writeAll(". It may still be working, or it may be hung. Message me to check on it, or stop me.");
}

test "the quiet note names the command and how long it has been quiet" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try quietNoteText(&writer, "node verify.mjs --mock", 125_000);
    try std.testing.expectEqualStrings(
        "fx: my command `node verify.mjs --mock` has had no output for 2m5s. It may still be working, or it may be hung. Message me to check on it, or stop me.",
        writer.buffered(),
    );
}

test "managed execution receipts retain the pending contract" {
    var runtime: Runtime = undefined;
    for ([_]bool{ false, true }) |pending| {
        const result = try runtime.encodeManaged(std.testing.allocator, .{ .ok = true, .pending = pending });
        defer std.testing.allocator.free(result.body);
        try std.testing.expectEqual(pending, result.pending);
    }
}

/// Delivers a child's report to the agent that owns this host. Each runtime
/// supplies its own, since only it can build that agent's next turn: the
/// report joins a running turn, or wakes the idle agent with the user's last
/// request as root context. It never interrupts the model.
pub const ReportSink = struct {
    context: ?*anyopaque = null,
    /// Called with the host the delivery comes from. It never blocks: the
    /// runtime copies what it keeps and delivers it later.
    post_fn: *const fn (?*anyopaque, *Runtime, Delivery) PostReportError!void,

    pub fn post(self: ReportSink, host: *Runtime, delivery: Delivery) PostReportError!void {
        return self.post_fn(self.context, host, delivery);
    }
};

/// What a host hands its runtime to deliver, borrowed for the call.
pub const Delivery = union(enum) {
    /// A child's report, for the agent that owns the host.
    report: reports.Report,
    /// A subagent's message to its parent.
    message: reports.Message,
};

/// `QueueFull`: the receiving agent's queue already holds
/// `agent_frame.queue_cap` messages from other agents. Only a message is
/// refused this way, never a report.
pub const PostReportError = error{ OutOfMemory, AgentGone, QueueFull };

pub const ProgressSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, types.SubagentStatus) void,

    pub fn publish(self: ProgressSink, status: types.SubagentStatus) void {
        self.publish_fn(self.context, status);
    }
};

/// Resolves a creation-time model override against the host's model catalog.
/// Returned slices are allocated from the passed allocator and must remain
/// valid for the duration of the `executeManaged` call.
pub const ModelOverrideResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch,

    pub fn resolve(
        self: ModelOverrideResolver,
        alloc: Allocator,
        raw_model: []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch {
        return self.resolve_fn(self.context, alloc, raw_model);
    }
};

pub const ExecuteOptions = struct {
    observer: ?*execution_observation.Observer = null,
    caller_id: []const u8,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    /// The caller's own worker, which `wait` blocks on.
    caller_worker: ?*worker_runtime.WorkerRuntime = null,
    progress: ?ProgressSink = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?ModelOverrideResolver = null,
};

pub const ManagedExecutionResult = struct {
    pending: bool = false,
    success: bool,
    body: []u8,
    /// The final status model is owned by the result allocator.
    final_status: ?types.SubagentStatus = null,
};

pub const Runtime = struct {
    alloc: Allocator,
    /// The parent's children, borrowed until deinit (D22).
    children: *child_state.V2Children,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    /// Where this host's children report, set by its runtime.
    report_sink: ?ReportSink = null,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    /// The profile each child started in, for its authority and prompt.
    profile_cache: ?authority.ProfileCache = null,
    managed: managed_owner.Owner,
    /// Guards admission, `pending`, and `busy`. Taken before the registry's
    /// lock and before the managed owner's.
    admission_mutex: std.Io.Mutex = .init,
    /// Messages for busy children, in the order they were sent.
    pending: std.ArrayList(Pending) = .empty,
    /// The children whose slot is running their work, between works too.
    busy: std.ArrayList([]u8) = .empty,
    /// The tool call that sent each work still running or waiting, so its
    /// report can point back at it. Guarded by `admission_mutex`.
    work_calls: std.ArrayList(WorkCall) = .empty,
    /// Children the user stopped on their own screen, with how many of the
    /// parent's messages waiting for them the stop dropped, until the
    /// stopped work's report or notice says so (`userStopped`).
    user_dropped: std.ArrayList(UserDrop) = .empty,
    /// The names of subagents the user closed, until main's message starts
    /// a new one under the name: main's status lists them, and that message
    /// says so, since the new one has none of the old one's history. Under
    /// `admission_mutex`.
    user_closed: std.ArrayList([]u8) = .empty,
    /// Children working on a turn their parent didn't start, as a work in
    /// the parent's log (`beginTurnWork`): the user's, typed on the child's
    /// screen, or one its own child's report woke.
    turn_works: std.ArrayList(TurnWork) = .empty,
    /// Children being closed for good (`closeChild`), until their close is
    /// written (`settleClose`) or its write fails: the list, the trace, and
    /// message admission all treat each as closing for that whole time
    /// (`tests/tla/subagent/StopMessage.tla` ClosingHoldsNothing). Guarded by
    /// `admission_mutex`.
    closing: std.ArrayList(Closing) = .empty,
    /// Children closed or closing whose agents the app has not yet dropped
    /// (`takeClosed`). Guarded by `admission_mutex`.
    closed_unseen: std.ArrayList([]u8) = .empty,
    /// Whether `closed_unseen` holds a child, read without the lock.
    closed_waiting: std.atomic.Value(bool) = .init(false),
    /// Messages waiting for a starting work's turn to begin. A close of
    /// their child marks them, so the message is refused instead of
    /// outliving the close. Guarded by `admission_mutex`.
    start_waits: std.ArrayList(*StartWait) = .empty,
    waiter_mutex: std.Io.Mutex = .init,
    /// The owner's worker while it waits in `wait`.
    waiter: ?*worker_runtime.WorkerRuntime = null,
    /// Whether this host's owner is itself a subagent, so a message to its
    /// parent has somewhere to go. Set by its runtime.
    owner_has_parent: bool = false,
    /// `teamNote`'s copy for the owner's turn `team_turn`, null when it
    /// had no subagents. Under `team_mutex`. Owned.
    team_note: ?[]u8 = null,
    team_turn: u64 = 0,
    team_mutex: std.Io.Mutex = .init,
    /// What each child that worked used since `trackUsage`, for a run that
    /// reports it (`fx ask --json`). Off for every other host. Guards itself.
    usage_ledger: usage_ledger.Ledger = .{},

    /// A host over a parent whose children live in its log (D22), returned
    /// only after abandoned child work has been recovered. Borrows
    /// `children` and the callback contexts until deinit; the parent stays
    /// open until then (`tests/tla/session_manager/Wiring.tla`
    /// ParentOutlivesChildren).
    pub fn create(
        alloc: Allocator,
        children: *child_state.V2Children,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        const root_id = children.parent.id();
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        runtime.* = .{
            .alloc = alloc,
            .children = children,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .approvals = undefined,
            .authority_resolver = undefined,
            .managed = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
        };
        // The session's own workspace, not the process's: an ACP session can be bound to another.
        runtime.profile_cache = .{ .alloc = alloc, .roots = .{ .home = io_mod.homeDir(), .workspace_root = children.workspace } };
        runtime.authority_resolver = .{
            .children = children,
            .root_id = runtime.root_id,
            .host = host_authority,
            .profiles = &runtime.profile_cache.?,
        };
        runtime.managed = runtime.managedOwnerValue();
        runtime.managed.on_end = .{ .context = runtime, .end_fn = workEnded };
        errdefer runtime.approvals.deinit();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.managed.deinit();
        if (self.team_note) |note| self.alloc.free(note);
        for (self.pending.items) |*item| {
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason=host_closed", .{ item.child_id, item.work.id });
            item.deinit(self.alloc);
        }
        self.pending.deinit(self.alloc);
        for (self.busy.items) |id| self.alloc.free(id);
        self.busy.deinit(self.alloc);
        for (self.work_calls.items) |*call| call.deinit(self.alloc);
        self.work_calls.deinit(self.alloc);
        for (self.user_dropped.items) |drop| self.alloc.free(drop.child_id);
        self.user_dropped.deinit(self.alloc);
        for (self.user_closed.items) |name| self.alloc.free(name);
        self.user_closed.deinit(self.alloc);
        for (self.turn_works.items) |*work| work.deinit(self.alloc);
        self.turn_works.deinit(self.alloc);
        for (self.closing.items) |entry| {
            debug_trace.eventf("mailbox", "close_dropped", .{}, "child={s} reason=host_closed", .{entry.id});
            self.alloc.free(entry.id);
        }
        self.closing.deinit(self.alloc);
        for (self.closed_unseen.items) |id| self.alloc.free(id);
        self.closed_unseen.deinit(self.alloc);
        self.start_waits.deinit(self.alloc);
        self.usage_ledger.deinit(self.alloc);
        self.approvals.deinit();
        if (self.profile_cache) |*cache| cache.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Points the host's callbacks, its child runner and its report sink,
    /// at a host context that moved; the children stay as they are. A sink
    /// left on the old context would post into memory no longer in use.
    /// `/close` is closing the tree this host belongs to: its subagents'
    /// works that end from now on owe no report. Call before their turns
    /// are cancelled.
    pub fn closeTree(self: *Runtime) void {
        self.managed.closeTree();
        debug_trace.eventf("mailbox", "tree_closed", .{}, "owner={s}", .{self.ownerName()});
    }

    /// Starts keeping what each child that works uses (`usage_ledger.zig`).
    /// Call before any child runs, from the command that reports it.
    pub fn trackUsage(self: *Runtime) void {
        self.usage_ledger.enable();
    }

    /// Child `child_id` opened a turn, so it did work in this run. Called from
    /// the thread that runs it.
    pub fn noteChildTurnStarted(self: *Runtime, child_id: []const u8, name: ?[]const u8) Allocator.Error!void {
        try self.usage_ledger.begin(self.alloc, child_id, name);
    }

    /// One reply of child `child_id` used `usage`. Called from the thread that
    /// runs it, so the count is right whether the turn ends well or is stopped.
    pub fn noteChildUsage(self: *Runtime, child_id: []const u8, usage: types.Usage) void {
        self.usage_ledger.add(child_id, usage);
    }

    /// What each child that worked used since `trackUsage`, in the order each
    /// first ran: a copy that the caller frees with `usage_ledger.freeEntries`.
    /// It is safe at any time; a child still at work adds to the ledger, not
    /// to the copy.
    pub fn usageSnapshot(self: *Runtime, alloc: Allocator) Allocator.Error![]usage_ledger.Entry {
        return self.usage_ledger.snapshot(alloc);
    }

    /// Ends the turns of the children that wait on an approval, as a quit
    /// ends them: each work ends interrupted and owes its report, which the
    /// sink posts. The other children go on. Returns how many turns it ended.
    /// For a host whose approvals reach no one, so none waits for ever.
    pub fn interruptApprovalWaits(self: *Runtime) usize {
        const count = self.managed.interruptApprovalWaits();
        debug_trace.eventf("mailbox", "approval_waits_interrupted", .{}, "owner={s} count={d}", .{ self.ownerName(), count });
        return count;
    }

    pub fn rebindHost(
        self: *Runtime,
        host_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.host_authority = host_authority;
        self.child_runner.context = host_context;
        if (self.report_sink) |*sink| sink.context = host_context;
        self.authority_resolver.children = self.children;
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.children = self.children;
        self.managed.state_store.children = self.children;
        self.managed.services.context = self;
        self.managed.on_end = .{ .context = self, .end_fn = workEnded };
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = &self.approvals;
    }

    /// Opens child `child_id`'s session for its own agent to hold, as main
    /// holds its own. The caller owns it.
    pub fn openChildSession(self: *Runtime, child_id: []const u8) !*session_adapter.Session {
        return managed_owner.openChildForAgent(&self.managed, child_id);
    }

    pub const ChildListing = struct {
        id: []u8,
        /// The name its parent gave it, or empty for a one-off.
        name: []u8,
        /// The profile it runs in. One started before subagents had a
        /// profile of their own runs as main.
        profile: []u8,
        /// What it is for (`Child.purpose`), or empty when it has none.
        purpose: []u8,
        /// How its last finished work ended, or null before it has finished
        /// one. Saved with the child, so a restart keeps it.
        last_outcome: ?child_state.Outcome = null,
    };

    /// The root's subagents in the order they started, after a restart too.
    /// Free with `freeChildListing`.
    pub fn listChildren(self: *Runtime, alloc: Allocator) ![]ChildListing {
        // Admission before the registry, as everywhere in this host.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        // One closing is gone for the list already.
        var count: usize = 0;
        for (registry.children) |child| {
            if (self.closingIndexLocked(child.id) == null) count += 1;
        }
        const listing = try alloc.alloc(ChildListing, count);
        var filled: usize = 0;
        errdefer {
            for (listing[0..filled]) |entry| freeListed(alloc, entry);
            alloc.free(listing);
        }
        for (registry.children) |child| {
            if (self.closingIndexLocked(child.id) != null) continue;
            const id = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, child.agentName() orelse "");
            errdefer alloc.free(name);
            const profile = try alloc.dupe(u8, child.profile orelse profiles.main_name);
            errdefer alloc.free(profile);
            listing[filled] = .{
                .id = id,
                .name = name,
                .profile = profile,
                .purpose = try alloc.dupe(u8, child.purpose orelse ""),
                .last_outcome = child.last_outcome,
            };
            filled += 1;
        }
        return listing;
    }

    pub fn freeChildListing(alloc: Allocator, listing: []ChildListing) void {
        for (listing) |entry| freeListed(alloc, entry);
        alloc.free(listing);
    }

    fn freeListed(alloc: Allocator, entry: ChildListing) void {
        alloc.free(entry.id);
        alloc.free(entry.name);
        alloc.free(entry.profile);
        alloc.free(entry.purpose);
    }

    /// What `/trace` says of one subagent from the registry.
    pub const TraceChild = struct {
        id: []u8,
        phase: child_state.Phase,
        /// How its last piece of work ended, or null before its first ends.
        last_outcome: ?child_state.Outcome,
        /// Why that work failed, or empty.
        last_failure: []u8,
        /// Whether `/close` is closing it.
        closing: bool,
    };

    /// Every subagent of the root, with its work phase and last outcome,
    /// one that is closing too. `alloc` owns the listing: `/trace` passes an
    /// arena, and this file's tests free it with `freeTraceChildren`.
    pub fn traceChildren(self: *Runtime, alloc: Allocator) ![]TraceChild {
        // Admission before the registry, as everywhere in this host.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        const listing = try alloc.alloc(TraceChild, registry.children.len);
        var filled: usize = 0;
        errdefer {
            for (listing[0..filled]) |entry| freeTraced(alloc, entry);
            alloc.free(listing);
        }
        for (registry.children) |child| {
            const id = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id);
            const failure = if (child.last_failure) |*diagnostic| diagnostic.view() else "";
            listing[filled] = .{
                .id = id,
                .phase = child.phase,
                .last_outcome = child.last_outcome,
                .last_failure = try alloc.dupe(u8, failure),
                .closing = self.closingIndexLocked(child.id) != null,
            };
            filled += 1;
        }
        return listing;
    }

    fn freeTraceChildren(alloc: Allocator, listing: []TraceChild) void {
        for (listing) |entry| freeTraced(alloc, entry);
        alloc.free(listing);
    }

    fn freeTraced(alloc: Allocator, entry: TraceChild) void {
        alloc.free(entry.id);
        alloc.free(entry.last_failure);
    }

    /// A child's saved conversation, read without opening it. The caller
    /// owns the turns (`types.freeHistoryTurnSlice`).
    pub fn childHistory(self: *Runtime, alloc: Allocator, child_id: []const u8) ![]types.HistoryTurn {
        return self.children.parent.store.childHistory(alloc, child_id);
    }

    /// A child's saved title, read without opening it; null when it has
    /// none. Caller owns it.
    pub fn childTitle(self: *Runtime, alloc: Allocator, child_id: []const u8) !?[]u8 {
        return self.children.parent.store.childTitle(alloc, child_id);
    }

    /// What a turn the user starts on a subagent's own screen runs under.
    pub const UserTurnAdmission = struct {
        admission: domain.AdmissionSnapshot,
        /// The child's instructions, for its system prompt. Owned.
        instructions: []u8,

        pub fn deinit(self: *UserTurnAdmission, alloc: Allocator) void {
            self.admission.deinit(alloc);
            alloc.free(self.instructions);
            self.* = undefined;
        }
    };

    /// Admits a turn the user starts on child `child_id`'s own screen,
    /// captured as a run's admission is, from the child's saved preferences,
    /// so its profile and main's live permissions limit it the same way.
    /// The registry is not changed: no work of main's is started, and
    /// a run main sends meanwhile waits for the turn to end. A one-off ran a
    /// single task for main and takes no turns of the user's. The caller owns
    /// the result.
    pub fn admitUserTurn(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) !UserTurnAdmission {
        const instructions = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(alloc);
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildUnavailable;
            if (child.agentName() == null) return error.OneOffChild;
            break :blk try alloc.dupe(u8, child.instructions());
        };
        errdefer alloc.free(instructions);
        var preferences = try managed_owner.readChildPreferences(&self.managed, child_id);
        defer preferences.deinit(self.managed.alloc);
        var snapshot = try self.authority_resolver.resolveForUser(alloc, child_id, permission_mode);
        defer snapshot.deinit(alloc);
        const admission = try admissionFrom(alloc, .{
            .child_id = child_id,
            .parent_id = self.managed.state_store.parent_id,
            .source_id = self.managed.state_store.parent_id,
            .preferences = managed_owner.turnPreferencesForDurable(preferences),
        }, &snapshot);
        return .{ .admission = admission, .instructions = instructions };
    }

    /// The resolver that decides a child's tools and permissions, for a
    /// turn's live authority.
    pub fn authorityResolver(self: *Runtime) *authority.Resolver {
        return &self.authority_resolver;
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
    ) u64 {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("model");
        hash.update(&.{0});
        hash.update(invocation_id);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.mem.readInt(u64, digest[0..8], .little) | 1;
    }

    pub fn executeManaged(
        self: *Runtime,
        alloc: Allocator,
        request: *model_contract.Request,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            self.issueOperationIdentity(options.invocation_id);
        const operation_id = try operationIdAlloc(
            alloc,
            options.invocation_id,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const from_root = std.mem.eql(u8, options.caller_id, self.root_id);

        switch (request.*) {
            .wait => return self.waitForMail(alloc, options),
            .status => {
                if (!from_root) return self.refuse(alloc, .{ .caller_unavailable = .not_owner });
                return self.statusOf(alloc, request.status.agent);
            },
            .stop => {
                if (!from_root) return self.refuse(alloc, .{ .caller_unavailable = .not_owner });
                return self.stopChild(alloc, request.stop.agent);
            },
            .close => {
                if (!from_root) return self.refuse(alloc, .{ .caller_unavailable = .not_owner });
                return self.closeNamed(alloc, request.close.agent);
            },
            .message => {},
        }
        if (request.toParent()) return self.messageParent(alloc, request.message.message, options, from_root);
        if (!from_root) return self.refuse(alloc, .{ .caller_unavailable = .not_owner });

        // A new child's profile sets its model and effort unless the
        // request names them. Loading it here refuses an unknown profile, or
        // one that would nest subagents, before any child exists.
        var profile_arena = std.heap.ArenaAllocator.init(alloc);
        defer profile_arena.deinit();
        var profiled = options;
        var model_override = request.override();
        // What the profile set, which a new child keeps (`child_state.Child`).
        var started_with: ?started_with_mod.StartedWith = null;
        if (model_override.profile) |name| {
            const profile = switch (try loadChildProfile(profile_arena.allocator(), self.profile_cache.?.roots, name)) {
                .rejected => |failure| return self.encodeManaged(alloc, failure),
                .loaded => |value| value,
            };
            // `main` sets nothing and nothing can replace it, so it saves nothing.
            if (!std.mem.eql(u8, profile.name, profiles.main_name)) started_with = started_with_mod.of(&profile);
            if (model_override.model == null) model_override.model = profile.model;
            if (model_override.effort == null) {
                if (profile.effort) |effort| profiled.defaults.effort = effort;
            }
        }
        const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, model_override, profiled)) {
            .rejected => |failure| return self.encodeManaged(alloc, failure),
            .accepted => |model| model,
        };
        if (request.override().model == null) {
            if (model_override.model) |raw| profiled.defaults.model = resolved_model orelse raw;
        }
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        const fingerprint = model_contract.requestFingerprint(request.*);
        if (self.managed.feedbackReplay(operation_id, fingerprint)) |replay| {
            return switch (replay) {
                .receipt => |delivery| self.encodeManaged(alloc, model_contract.feedbackResult(delivery)),
                else => self.refuse(alloc, .operation_conflict),
            };
        }
        // Remembered before admission, which can start the work and see it
        // end before returning. Only a started or waiting work keeps it.
        try self.rememberCall(operation_id, options.invocation_id);
        var keep_call = false;
        defer if (!keep_call) self.forgetCall(operation_id);
        var admission_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer admission_arena.deinit();
        const admission_alloc = admission_arena.allocator();
        const agent = request.message.agent;
        // A second pass runs only when the child went idle while this
        // message waited for the admission lock (the `.feedback` arm).
        admit: for (0..2) |pass| {
            var admitted = try self.admitAndStartManagedWork(admission_alloc, request.*, operation_id, profiled, resolved_model, started_with);
            defer admitted.deinit(admission_alloc);
            switch (admitted) {
                .feedback => |target| {
                    const delivery = steer: {
                        self.admission_mutex.lockUncancelable(io_mod.getIo());
                        defer self.admission_mutex.unlock(io_mod.getIo());
                        // Older messages for this child wait their turn; a new one
                        // never joins the running turn past them. A turn the user
                        // started has no slot to join, so they wait for it too.
                        // A child being closed takes no next turn, and what
                        // waits for it goes with the close, so it refuses the
                        // message as admission does
                        // (`tests/tla/subagent/StopMessage.tla`
                        // RefusedOnlyWhenClosing).
                        if (self.closingIndexLocked(target.child_id) != null) return self.refuse(alloc, .child_closing);
                        var turned_away = false;
                        if (!self.hasPendingLocked(target.child_id) and !self.inTurnWorkLocked(target.child_id)) {
                            var result = try self.managed.steer(target.child_id, target.work_id, operation_id, fingerprint, request.message.message);
                            // The work main started has not begun its turn: wait
                            // for it with the lock released, so other calls and
                            // ends go on, then send the message into that turn
                            // (`tests/tla/subagent/StopMessage.tla`
                            // JoinsStartingWork). Only a stuck start reaches the
                            // limit, which leaves the message for the next turn.
                            if (result == .starting) {
                                var start_wait: StartWait = .{ .child_id = target.child_id };
                                try self.start_waits.append(self.alloc, &start_wait);
                                defer self.removeStartWaitLocked(&start_wait);
                                debug_trace.eventf("mailbox", "message_waits_start", .{}, "child={s} work_id={s}", .{ target.child_id, target.work_id });
                                const limit_ms = start_test_controls.waitLimitMs();
                                const deadline = io_mod.milliTimestamp() +| @as(i64, @intCast(@min(limit_ms, std.math.maxInt(i64))));
                                while (result == .starting) {
                                    if (io_mod.milliTimestamp() >= deadline) {
                                        debug_trace.eventf("mailbox", "message_start_wait_expired", .{}, "child={s} work_id={s} limit_ms={d}", .{ target.child_id, target.work_id, limit_ms });
                                        result = .waiting;
                                        break;
                                    }
                                    self.admission_mutex.unlock(io_mod.getIo());
                                    io_mod.sleep(start_wait_poll_ns);
                                    self.admission_mutex.lockUncancelable(io_mod.getIo());
                                    // Main's turn was cancelled, or fx is quitting.
                                    if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
                                    // The child may have been closed, or a message may
                                    // have queued for it, while the lock was free.
                                    if (start_wait.closed or self.closingIndexLocked(target.child_id) != null) return self.refuse(alloc, .child_closing);
                                    if (self.hasPendingLocked(target.child_id) or self.inTurnWorkLocked(target.child_id)) {
                                        result = .waiting;
                                        break;
                                    }
                                    result = try self.managed.steer(target.child_id, target.work_id, operation_id, fingerprint, request.message.message);
                                }
                            }
                            switch (result) {
                                .receipt => |delivery| break :steer delivery,
                                // An ended work, or one a stop is ending, takes the
                                // message as its next turn: the stop told the
                                // parent the turn ended. A start past the limit
                                // does the same.
                                .waiting, .stopping, .starting => turned_away = true,
                                .capacity => {
                                    var buf: [sent_result_bytes]u8 = undefined;
                                    return self.encodeManaged(alloc, .{ .ok = false, .error_code = "feedback_capacity", .result = capacityResult(&buf, agent) });
                                },
                                .unavailable => return self.refuse(alloc, .state_unavailable),
                                .cancelled => return self.refuse(alloc, .child_cancelled),
                                .conflict => return self.refuse(alloc, .operation_conflict),
                            }
                        }
                        // The work ended while this message waited for the lock,
                        // and nothing keeps the child busy any more: admit the
                        // message again, so it starts a work rather than waiting
                        // for a turn no end will start.
                        if (turned_away and pass == 0 and !self.isBusyLocked(target.child_id) and !self.inTurnWorkLocked(target.child_id)) continue :admit;
                        // It waits, and starts the child's next turn.
                        self.queuePendingLocked(target.child_id, agent, operation_id, fingerprint, request.*, profiled, resolved_model) catch |err| {
                            if (err == error.QueueFull) return self.refuse(alloc, .{ .queue_full = .subagent });
                            return err;
                        };
                        keep_call = true;
                        if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = target.child_id, .work_id = operation_id, .phase = .dispatched } });
                        var buf: [sent_result_bytes]u8 = undefined;
                        return self.encodeManaged(alloc, .{ .ok = true, .result = queuedResult(&buf, agent) });
                    };
                    debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=joined receipt={s} operation={s}", .{ target.child_id, target.work_id, @tagName(delivery), operation_id });
                    if (options.observer) |observer| observer.emit(.{ .delegation = .{
                        .call_id = options.invocation_id,
                        .child_id = target.child_id,
                        .work_id = target.work_id,
                        .operation_id = operation_id,
                        .phase = switch (delivery) {
                            .queued => .feedback_queued,
                            .applied => .feedback_applied,
                            .not_applied => .feedback_not_applied,
                        },
                    } });
                    return self.encodeManaged(alloc, model_contract.feedbackResult(delivery));
                },
                .rejected => |failure| return self.refuse(alloc, failure.refusal),
                .ready => |ready| {
                    keep_call = true;
                    if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = .dispatched } });
                    var buf: [sent_result_bytes]u8 = undefined;
                    const sent = sentResult(&buf, agent);
                    if (!ready.created) return self.encodeManaged(alloc, .{ .ok = true, .result = sent });
                    var scratch = std.heap.ArenaAllocator.init(alloc);
                    defer scratch.deinit();
                    // The list is extra: without it the answer still goes.
                    const idle = self.idleOthers(scratch.allocator(), ready.child_id) catch |err| unread: {
                        debug_trace.eventf("mailbox", "idle_list_unavailable", .{}, "child={s} err={s}", .{ ready.child_id, @errorName(err) });
                        break :unread &.{};
                    };
                    return self.encodeManaged(alloc, .{ .ok = true, .result = try startedResult(scratch.allocator(), sent, agent, ready.user_closed, idle) });
                },
                .completed => |completed| {
                    if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = completed.child_id, .work_id = operation_id, .phase = .replayed } });
                    return self.encodeManaged(alloc, .{ .ok = true, .result = "This message was sent earlier, and the subagent's work on it has ended. Its report went to you then." });
                },
            }
        }
        unreachable;
    }

    const WorkCall = struct {
        work_id: []u8,
        call_id: []u8,

        fn deinit(self: *WorkCall, alloc: Allocator) void {
            alloc.free(self.work_id);
            alloc.free(self.call_id);
        }
    };

    fn rememberCall(self: *Runtime, work_id: []const u8, call_id: []const u8) !void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| if (std.mem.eql(u8, call.work_id, work_id)) return;
        const owned_work = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work);
        const owned_call = try self.alloc.dupe(u8, call_id);
        errdefer self.alloc.free(owned_call);
        try self.work_calls.append(self.alloc, .{ .work_id = owned_work, .call_id = owned_call });
    }

    fn forgetCall(self: *Runtime, work_id: []const u8) void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        self.forgetCallLocked(work_id);
    }

    fn forgetCallLocked(self: *Runtime, work_id: []const u8) void {
        for (self.work_calls.items, 0..) |*call, i| {
            if (!std.mem.eql(u8, call.work_id, work_id)) continue;
            call.deinit(self.alloc);
            _ = self.work_calls.swapRemove(i);
            return;
        }
    }

    /// The call that sent `work_id`, copied into `a`, or empty.
    fn callOf(self: *Runtime, a: Allocator, work_id: []const u8) []const u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| {
            if (std.mem.eql(u8, call.work_id, work_id)) return a.dupe(u8, call.call_id) catch "";
        }
        return "";
    }

    /// A message for a busy child, waiting to start its next turn.
    const Pending = struct {
        child_id: []u8,
        agent: []u8,
        work: child_state.ActiveWork,

        fn deinit(self: *Pending, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.agent);
            self.work.deinit(alloc);
        }
    };

    /// How many messages may wait for one busy child: the one cap on an
    /// agent's queue of other agents' messages.
    const max_pending_per_child: usize = agent_frame.queue_cap;

    fn hasPendingLocked(self: *const Runtime, child_id: []const u8) bool {
        for (self.pending.items) |item| if (std.mem.eql(u8, item.child_id, child_id)) return true;
        return false;
    }

    /// Queues a message behind the child's running turn. A call replayed
    /// with the same operation is queued once.
    fn queuePendingLocked(
        self: *Runtime,
        child_id: []const u8,
        agent: []const u8,
        operation_id: []const u8,
        fingerprint: [32]u8,
        request: model_contract.Request,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !void {
        var waiting: usize = 0;
        for (self.pending.items) |item| {
            if (std.mem.eql(u8, item.work.id, operation_id)) return;
            if (std.mem.eql(u8, item.child_id, child_id)) waiting += 1;
        }
        if (waiting >= max_pending_per_child) return error.QueueFull;
        try self.ensureManagedChildSession(child_id, operation_id, effectiveDefaults(options.defaults, request.override(), resolved_model));
        var work = try makeManagedWork(self.alloc, operation_id, fingerprint, request, options);
        errdefer work.deinit(self.alloc);
        const owned_child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child);
        const owned_agent = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(owned_agent);
        try self.pending.append(self.alloc, .{ .child_id = owned_child, .agent = owned_agent, .work = work });
        debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=queued waiting={d}", .{ child_id, operation_id, waiting + 1 });
    }

    /// Drops every message waiting for `child_id`, returning how many.
    fn dropPendingLocked(self: *Runtime, child_id: []const u8, reason: []const u8) usize {
        var dropped: usize = 0;
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (!std.mem.eql(u8, self.pending.items[index].child_id, child_id)) {
                index += 1;
                continue;
            }
            var item = self.pending.orderedRemove(index);
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ child_id, item.work.id, reason });
            self.forgetCallLocked(item.work.id);
            item.deinit(self.alloc);
            dropped += 1;
        }
        return dropped;
    }

    fn isBusyLocked(self: *const Runtime, child_id: []const u8) bool {
        for (self.busy.items) |id| if (std.mem.eql(u8, id, child_id)) return true;
        return false;
    }

    fn markBusyLocked(self: *Runtime, child_id: []const u8) !void {
        if (self.isBusyLocked(child_id)) return;
        try self.busy.append(self.alloc, try self.alloc.dupe(u8, child_id));
    }

    fn clearBusyLocked(self: *Runtime, child_id: []const u8) void {
        for (self.busy.items, 0..) |id, index| if (std.mem.eql(u8, id, child_id)) {
            self.alloc.free(self.busy.swapRemove(index));
            return;
        };
    }

    /// Whether any child is working, or a message waits for one.
    fn anyWorking(self: *Runtime) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.busy.items.len > 0 or self.pending.items.len > 0;
    }

    /// Whether nothing in this host's tree can still post to its owner:
    /// no child works and no message waits for one. `fx ask` and ACP finish
    /// only then.
    pub fn quiet(self: *Runtime) bool {
        return !self.anyWorking();
    }

    pub const TreeWake = enum { mail, quiet, stopped };
    const cancel_poll: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

    /// For a runtime that finishes only once its tree is quiet, as `fx ask`
    /// does: blocks until mail is queued for `worker`, nothing in this host
    /// can still post, or `worker` is stopped. A child posts its report
    /// before it stops counting as working, so `quiet` never leaves one
    /// behind.
    /// A set `cancel` stops it too. It is rechecked every `cancel_poll`, so
    /// a signal handler may set it without waking anything.
    pub fn awaitMailOrQuiet(self: *Runtime, worker: *worker_runtime.WorkerRuntime, cancel: ?*const std.atomic.Value(bool)) TreeWake {
        self.setWaiter(worker);
        defer self.setWaiter(null);
        while (true) {
            if (cancel) |flag| if (flag.load(.seq_cst)) return .stopped;
            if (worker.queuedPromptCount() > 0) return .mail;
            if (!self.anyWorking()) return .quiet;
            const wake = if (cancel != null)
                worker.waitForPostOrNudgeTimeout(cancel_poll) orelse continue
            else
                worker.waitForPostOrNudge();
            switch (wake) {
                .posted => return .mail,
                .nudged => continue,
                .stopped => return .stopped,
            }
        }
    }

    /// How trace lines name this host's owner: `main` for a root host, as the
    /// mailbox trace contract reads it, or the owner's own id.
    fn ownerName(self: *const Runtime) []const u8 {
        return if (self.owner_has_parent) self.root_id else "main";
    }

    fn setWaiter(self: *Runtime, worker: ?*worker_runtime.WorkerRuntime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        self.waiter = worker;
    }

    /// Ends the owner's `wait` when a child's work ended with nothing to
    /// post, so it can look again. Call it only after the end has changed
    /// what `anyWorking` reads, the child's busy flag cleared: `wait`
    /// registers and then reads `anyWorking`, so a nudge sent before the
    /// clear finds no waiter to wake, and a `wait` that reads the old state
    /// afterwards blocks with nothing left to wake it
    /// (`tests/tla/subagent/WaitNudge.tla`: `wait` always returns).
    fn nudgeWaiter(self: *Runtime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        if (self.waiter) |worker| worker.nudgeWaiter();
    }

    /// The owner's hook for a child's work ending (`managed_owner.EndHook`),
    /// on the child's slot thread: the report goes to the owner, the child is
    /// settled, and the owner's wait is nudged when nothing was posted, once
    /// the child's busy flag is clear. The next waiting message, if any,
    /// becomes the child's next work. Returns whether it did.
    fn workEnded(raw: *anyopaque, end: managed_owner.WorkEnd) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        var posted = self.deliverEnd(end);
        if (end_test_controls.settleArmed()) end_test_controls.holdBeforeSettle(end.child_id);
        const next = self.settleEnd(end, &posted);
        if (!posted) self.nudgeWaiter();
        return next;
    }

    /// `workEnded` after the owner was told of `end`: settles the child and
    /// returns whether its slot has a next work. `posted` is set when a turn
    /// work finished here posts to the owner too.
    fn settleEnd(self: *Runtime, end: managed_owner.WorkEnd, posted: *bool) bool {
        if (self.endClosingWork(end)) {
            _ = self.settleClose(end.child_id);
            return false;
        }
        var ended = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            self.forgetCallLocked(end.work_id);
            self.queueLeftoversLocked(end);
            switch (self.openWaitingTurnWorkLocked(end.child_id)) {
                .none => return self.nextOrIdleLocked(end.child_id),
                // The turn that began meanwhile keeps the child busy; the
                // parent's next message waits for it.
                .opened => {
                    self.managed.markEnding(end.child_id);
                    return false;
                },
                .ended => |work| break :blk work,
            }
        };
        // Its turn ended before the work could open: finish it now, and let
        // this slot take the parent's next message.
        defer ended.deinit(self.alloc);
        const reply = ended.ended.?.reply;
        if (self.finishTurnWork(ended, ended.ended.?.outcome, reply)) posted.* = true;
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.nextOrIdleLocked(end.child_id);
    }

    /// Makes the parent's next message waiting for `child_id` the slot's
    /// next work, or else marks the child idle.
    fn nextOrIdleLocked(self: *Runtime, child_id: []const u8) bool {
        const messages = self.startNextPendingLocked(child_id);
        if (messages > 0) {
            self.managed.markNext(child_id, messages);
            return true;
        }
        self.clearBusyLocked(child_id);
        self.managed.markEnding(child_id);
        return false;
    }

    /// Queues the parent's messages the ended turn never took ahead of the
    /// others waiting, so the child's next work takes them.
    fn queueLeftoversLocked(self: *Runtime, end: managed_owner.WorkEnd) void {
        if (end.leftovers.len == 0) return;
        // A stop or close that came after the slot kept them counted them as
        // dropped, so none may start a work.
        if (!self.managed.handOverLeftovers(end.child_id)) {
            for (end.leftovers) |work| {
                debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason=stopped", .{ end.child_id, work.id });
            }
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const name = self.childName(scratch.allocator(), end.child_id) catch end.child_id;
        var at: usize = self.pending.items.len;
        for (self.pending.items, 0..) |item, index| if (std.mem.eql(u8, item.child_id, end.child_id)) {
            at = index;
            break;
        };
        for (end.leftovers) |work| {
            const queued = for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.work.id, work.id)) break true;
            } else false;
            if (queued) continue;
            self.insertPendingLocked(at, end.child_id, name, work) catch |err| {
                debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ end.child_id, work.id, @errorName(err) });
                continue;
            };
            at += 1;
            debug_trace.eventf("mailbox", "handed_back", .{}, "child={s} work_id={s}", .{ end.child_id, work.id });
        }
    }

    fn insertPendingLocked(self: *Runtime, at: usize, child_id: []const u8, agent: []const u8, work: child_state.ActiveWork) !void {
        var copy = try work.clone(self.alloc);
        errdefer copy.deinit(self.alloc);
        const owned_child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child);
        const owned_agent = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(owned_agent);
        try self.pending.insert(self.alloc, at, .{ .child_id = owned_child, .agent = owned_agent, .work = copy });
    }

    /// Messages the user's stop or close of `child_id` dropped, for its
    /// parent's next report or notice.
    const UserDrop = struct { child_id: []u8, count: usize, closed: bool = false };

    /// fx is quitting: the works its quit cancels say so in their reports.
    /// Call before the quit stops any of this host's children.
    pub fn noteQuitting(self: *Runtime) void {
        self.managed.noteQuitting();
    }

    /// Esc on a subagent's own screen while it works for its parent, the
    /// user's own stop: the turn ends as
    /// the Esc ends it, and the parent's messages waiting for the subagent
    /// are dropped now, so none of them starts after it: those waiting here,
    /// and `from_queue` the subagent's own queue already dropped. The parent
    /// learns of the drop from the stopped work's report, or else a notice.
    pub fn userStopped(self: *Runtime, child_id: []const u8, from_queue: usize) void {
        self.managed.noteUserStop(child_id);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.findTurnWorkLocked(child_id)) |index| self.turn_works.items[index].stopped_by = .user;
        const dropped = self.dropPendingLocked(child_id, "stopped_by_user") + from_queue;
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=user running={} dropped={d}", .{ child_id, self.isBusyLocked(child_id), dropped });
        self.noteUserDropLocked(child_id, dropped, false);
    }

    /// Keeps `dropped`, the messages the user's stop or close of `child_id`
    /// dropped, for the report or notice its parent gets next. Hold the
    /// admission mutex.
    fn noteUserDropLocked(self: *Runtime, child_id: []const u8, dropped: usize, closed: bool) void {
        if (dropped == 0) return;
        for (self.user_dropped.items) |*drop| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            drop.count += dropped;
            drop.closed = drop.closed or closed;
            return;
        }
        const owned = self.alloc.dupe(u8, child_id) catch return self.logLostDrop(child_id, dropped);
        self.user_dropped.append(self.alloc, .{ .child_id = owned, .count = dropped, .closed = closed }) catch {
            self.alloc.free(owned);
            return self.logLostDrop(child_id, dropped);
        };
    }

    /// Keeps `name`, a subagent the user closed, for main's status and the
    /// message that starts a new one under it. Hold the admission mutex.
    fn noteUserClosedLocked(self: *Runtime, name: []const u8) void {
        for (self.user_closed.items) |known| if (std.mem.eql(u8, known, name)) return;
        noted: {
            self.user_closed.ensureUnusedCapacity(self.alloc, 1) catch break :noted;
            self.user_closed.appendAssumeCapacity(self.alloc.dupe(u8, name) catch break :noted);
            return;
        }
        debug_trace.logf("mailbox", "user close not noted agent={s} reason=out_of_memory", .{name});
    }

    /// Forgets `name`, which a new subagent now has. True when the user had
    /// closed one under it. Hold the admission mutex.
    fn forgetUserClosedLocked(self: *Runtime, name: []const u8) bool {
        for (self.user_closed.items, 0..) |known, index| {
            if (!std.mem.eql(u8, known, name)) continue;
            self.alloc.free(self.user_closed.swapRemove(index));
            return true;
        }
        return false;
    }

    fn logLostDrop(_: *Runtime, child_id: []const u8, dropped: usize) void {
        debug_trace.logf("mailbox", "stop notice lost child={s} dropped={d} reason=out_of_memory", .{ child_id, dropped });
    }

    /// What the user's stop or close of `child_id` dropped, forgotten once
    /// read.
    fn takeUserDropped(self: *Runtime, child_id: []const u8) Dropped {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.user_dropped.items, 0..) |drop, index| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            _ = self.user_dropped.swapRemove(index);
            self.alloc.free(drop.child_id);
            return .{ .count = drop.count, .closed = drop.closed };
        }
        return .{};
    }

    const Dropped = struct { count: usize = 0, closed: bool = false };

    /// Tells the owner of `end`: its report, or the notice that a stop or
    /// close dropped messages. True when the sink took one. When it did not,
    /// the caller nudges the owner's `wait` once the child's busy flag is
    /// clear (`nudgeWaiter`).
    fn deliverEnd(self: *Runtime, end: managed_owner.WorkEnd) bool {
        debug_trace.eventf("mailbox", "child_end", .{}, "child={s} work_id={s} outcome={s} report={}", .{ end.child_id, end.work_id, @tagName(end.outcome), end.report_owed });
        const dropped = self.takeUserDropped(end.child_id);
        if (end.report_owed) return self.postReportWith(end, dropped);
        // Nothing owed, but the parent's messages were dropped: say so.
        if (dropped.count > 0) return self.postReportWith(.{ .child_id = end.child_id, .work_id = "", .outcome = .cancelled, .report_owed = false }, dropped);
        return false;
    }

    /// Posts the reports `session`'s log still owes its owner, oldest first,
    /// as each would have been posted when its work ended: a restart, or an
    /// exit, left them untaken. Once per open of
    /// the session. Call it after the report sink is in place.
    pub fn resumeReports(self: *Runtime, parent: *session_adapter.Session) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const lines = (parent.pendingReportLines(a) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        }) orelse return;
        const pending = reports.pendingReports(a, lines) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        };
        for (pending) |item| {
            debug_trace.eventf("mailbox", "report_resumed", .{}, "session={s} child={s} work_id={s} outcome={s}", .{ parent.id(), item.child_id, item.work_id, @tagName(item.outcome) });
            self.postReport(.{ .child_id = item.child_id, .work_id = item.work_id, .outcome = item.outcome, .report_owed = true, .end = item.end });
        }
    }

    /// No work ends here, so no child's busy flag clears and no `wait` waits
    /// on this post.
    fn postReport(self: *Runtime, end: managed_owner.WorkEnd) void {
        _ = self.postReportWith(end, .{});
    }

    /// Posts `end`'s report, or with no `work_id` the notice that the user's
    /// stop or close dropped `dropped` messages. True when the sink took it.
    fn postReportWith(self: *Runtime, end: managed_owner.WorkEnd, dropped: Dropped) bool {
        const sink = self.report_sink orelse {
            // Nothing here can take it; it stays owed in the log.
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason=no_sink", .{ end.child_id, end.work_id });
            return false;
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const notice = end.work_id.len == 0;
        const output = if (notice)
            (a.print("The user {s} it, and {d} of your messages waiting for it were dropped.", .{
                if (dropped.closed) "closed" else "stopped",
                dropped.count,
            }) catch "")
        else
            self.reportOutput(a, end) catch "";
        const agent = self.childName(a, end.child_id) catch end.child_id;
        const idle = !notice and self.idleAfterEnd(a, end);
        sink.post(self, .{ .report = .{
            .agent = agent,
            .child_id = end.child_id,
            .work_id = end.work_id,
            .call_id = if (notice) "" else self.callOf(a, end.work_id),
            .outcome = end.outcome,
            .output = output,
            .dropped = dropped.count,
            .end = end.end,
            .idle = idle,
        } }) catch |err| {
            // A report stays owed in the log; a notice is lost.
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason={s} notice={}", .{ end.child_id, end.work_id, @errorName(err), notice });
            return false;
        };
        if (notice) {
            debug_trace.eventf("mailbox", "notice_queued", .{}, "to={s} from={s} dropped={d}", .{ self.ownerName(), end.child_id, dropped.count });
        } else {
            debug_trace.eventf("mailbox", "report_queued", .{}, "to={s} from={s} work={s} dropped={d} started_by={s} cause={s} idle={}", .{
                self.ownerName(),
                end.child_id,
                end.work_id,
                dropped.count,
                @tagName(end.end.started_by),
                if (end.end.cause) |cause| @tagName(cause) else "none",
                idle,
            });
        }
        return true;
    }

    /// Whether `end`'s child is idle once its report goes. Read before the
    /// slot starts the next message waiting for the child (`workEnded`), so
    /// a waiting message counts (`tests/tla/subagent/StopMessage.tla`
    /// IdleNoteHonest).
    fn idleAfterEnd(self: *Runtime, a: Allocator, end: managed_owner.WorkEnd) bool {
        const facts: IdleFacts = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            var facts: IdleFacts = .{
                .leftovers = end.leftovers.len > 0,
                .user_closed = if (end.end.cause) |cause| cause == .user_close else false,
                .closing = self.closingIndexLocked(end.child_id) != null,
                .waiting = self.hasPendingLocked(end.child_id),
                .turn_waiting = self.inTurnWorkLocked(end.child_id),
                .unusable = if (end.failure) |*failure| std.mem.startsWith(u8, failure.view(), managed_owner.profile_unavailable_code) else false,
            };
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            facts.open = if (self.managed.state_store.load(a)) |loaded| open: {
                var registry = loaded;
                break :open registry.findById(end.child_id) != null;
            } else |err| unread: {
                debug_trace.eventf("mailbox", "idle_unknown", .{}, "child={s} work_id={s} err={s}", .{ end.child_id, end.work_id, @errorName(err) });
                break :unread false;
            };
            break :blk facts;
        };
        return facts.idle();
    }

    /// What a report says about the work: the child's reply, or how it
    /// ended, with any text it had written.
    fn reportOutput(self: *Runtime, a: Allocator, end: managed_owner.WorkEnd) ![]const u8 {
        const saved = if (end.reply) |reply|
            reply
        else
            self.managedResultText(a, end.child_id, end.work_id) catch null;
        // An empty reply says nothing, so the report reads as if it had none.
        const text = if (saved) |value| (if (value.len > 0) value else null) else null;
        const output = switch (end.outcome) {
            .completed => return text orelse "The subagent ended its turn without a reply.",
            .lost => return lost_result,
            .failed => try formatFailedResult(a, if (end.failure) |*failure| failure.view() else null, text),
            .cancelled => try withPartial(a, cancelledSentence(end.end.cause), text),
            .interrupted => try withPartial(a, "fx stopped before it finished.", text),
        };
        // Work that ended early says what it already changed, so its parent
        // neither redoes it nor misses it. The list is extra: without it the
        // report still goes.
        const changed = (self.changedFiles(a, end.child_id, end.work_id) catch |err| unread: {
            debug_trace.eventf("mailbox", "report_files_unavailable", .{}, "child={s} work_id={s} err={s}", .{ end.child_id, end.work_id, @errorName(err) });
            break :unread null;
        }) orelse return output;
        return a.print("{s}\n\nFiles it changed before it ended: {s}", .{ output, changed });
    }

    /// The files work `work_id` changed, from its saved turn
    /// (`listChangedFiles`).
    fn changedFiles(self: *Runtime, a: Allocator, child_id: []const u8, work_id: []const u8) !?[]const u8 {
        const history = try self.children.parent.store.childHistory(a, child_id);
        return listChangedFiles(a, switch (turnForWork(history, work_id) orelse return null) {
            .assistant => |value| value.execution.files,
            .interrupted => |value| value.execution.files,
            .compacted_summary => return null,
        });
    }

    fn childName(self: *Runtime, a: Allocator, child_id: []const u8) ![]const u8 {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(a);
        if (registry.findById(child_id)) |child| return a.dupe(u8, child.agentName() orelse child_id);
        // A closed child is gone from the registry, but its close keeps its
        // name in the log, for a report owed from before it.
        return (try self.managed.state_store.closedName(a, child_id)) orelse child_id;
    }

    /// Makes the next message waiting for `child_id` its next work, which
    /// the child's slot runs at once. Returns how many of the parent's
    /// messages the work carries, or 0 when none waits or it could not be
    /// started, which drops it.
    fn startNextPendingLocked(self: *Runtime, child_id: []const u8) usize {
        const index = for (self.pending.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.child_id, child_id)) break i;
        } else return 0;
        var item = self.pending.orderedRemove(index);
        defer item.deinit(self.alloc);
        const messages = 1 + self.absorbPendingLocked(&item, index);
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = self.managed.state_store.load(self.alloc) catch |err| return self.dropStart(item, err);
        defer registry.deinit(self.alloc);
        _ = registry.startPersistentWork(self.alloc, item.agent, null, item.work) catch |err| return self.dropStart(item, err);
        self.managed.state_store.save(self.alloc, registry) catch |err| return self.dropStart(item, err);
        debug_trace.eventf("mailbox", "next_turn", .{}, "child={s} work_id={s}", .{ child_id, item.work.id });
        return messages;
    }

    /// The messages waiting for `head`'s child behind it join the turn it
    /// starts, in order: one turn and one report.
    /// They arrive as one message, each in its own paragraph, with the
    /// newest root request for the reviewer. `from` is where the next of
    /// the child's waiting messages can be. Returns how many it joined.
    fn absorbPendingLocked(self: *Runtime, head: *Pending, from: usize) usize {
        var index = from;
        var joined_count: usize = 0;
        while (index < self.pending.items.len) {
            const next = &self.pending.items[index];
            if (!std.mem.eql(u8, next.child_id, head.child_id)) {
                index += 1;
                continue;
            }
            const joined = std.mem.concat(self.alloc, u8, &.{ head.work.message, "\n\n", next.work.message }) catch {
                debug_trace.logf("mailbox", "absorb skipped child={s} work_id={s} reason=out_of_memory", .{ head.child_id, next.work.id });
                return joined_count;
            };
            self.alloc.free(head.work.message);
            head.work.message = joined;
            std.mem.swap([]u8, &head.work.root_user_intent_context, &next.work.root_user_intent_context);
            std.mem.swap([][]u8, &head.work.root_user_messages, &next.work.root_user_messages);
            std.mem.swap(bool, &head.work.root_user_evidence_complete, &next.work.root_user_evidence_complete);
            debug_trace.eventf("mailbox", "absorbed", .{}, "child={s} work_id={s} into={s}", .{ head.child_id, next.work.id, head.work.id });
            var absorbed = self.pending.orderedRemove(index);
            self.forgetCallLocked(absorbed.work.id);
            absorbed.deinit(self.alloc);
            joined_count += 1;
        }
        return joined_count;
    }

    fn inTurnWorkLocked(self: *const Runtime, child_id: []const u8) bool {
        return self.findTurnWorkLocked(child_id) != null;
    }

    fn findTurnWorkLocked(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.turn_works.items, 0..) |work, index| if (std.mem.eql(u8, work.child_id, child_id)) return index;
        return null;
    }

    /// A turn of a child's that its parent didn't start, as a work in the
    /// parent's log.
    const TurnWork = struct {
        child_id: []u8,
        work_id: []u8,
        started_by: reports.StartedBy,
        /// The child's own worker, which runs the turn, so the parent's
        /// stop can end it. Borrowed; null when the caller has none.
        worker: ?*worker_runtime.WorkerRuntime,
        /// False while the parent's work the child was finishing still
        /// holds it: this one opens in the log when that one ends.
        opened: bool,
        stopped_by: enum { none, parent, user } = .none,
        /// Set when the turn ended before its work could open, so it
        /// finishes as it opens. Owned reply.
        ended: ?struct { outcome: child_state.Outcome, reply: []u8 } = null,

        fn deinit(self: *TurnWork, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.work_id);
            if (self.ended) |ended| alloc.free(ended.reply);
        }
    };

    /// Opens a work in the parent's log for a turn the user starts on
    /// `child_id`'s own screen, as every child turn is one. Null while a work of the parent's is going, which
    /// the user's message then joins, or when the child can't take one. Its
    /// end owes the parent a report only under `every_turn`, or when it
    /// fails or is interrupted (`reports.reportable`). `worker` runs the
    /// turn. The caller owns the id, and ends the work with `endUserWork`.
    pub fn beginUserWork(self: *Runtime, alloc: Allocator, child_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.isBusyLocked(child_id) or self.closingIndexLocked(child_id) != null) return null;
        return self.openTurnWorkLocked(alloc, child_id, .user, worker, true) catch |err| {
            debug_trace.eventf("mailbox", "user_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    /// Opens a work in the parent's log for a turn `worker` began on
    /// `child_id` with no work going for it: the user's prompt it took after
    /// a hand-off, or a report from the child's own child. While the parent's last work for the child is still
    /// ending, the work opens as that one ends, and the parent's next message
    /// waits for it. Null when one is open already, or the child can't take
    /// one. The caller owns the id, and ends the work with `endUserWork`.
    pub fn beginTurnWork(self: *Runtime, alloc: Allocator, child_id: []const u8, started_by: reports.StartedBy, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.inTurnWorkLocked(child_id) or self.closingIndexLocked(child_id) != null) return null;
        return self.openTurnWorkLocked(alloc, child_id, started_by, worker, !self.isBusyLocked(child_id)) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    /// Who started `child_id`'s turn going now, when its parent didn't: the
    /// user on its screen, or its own child's report. Null when no such
    /// turn is going, as while it does work its parent sent.
    pub fn turnStartedBy(self: *Runtime, child_id: []const u8) ?reports.StartedBy {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const index = self.findTurnWorkLocked(child_id) orelse return null;
        return self.turn_works.items[index].started_by;
    }

    fn openTurnWorkLocked(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        started_by: reports.StartedBy,
        worker: ?*worker_runtime.WorkerRuntime,
        open_now: bool,
    ) ![]u8 {
        const suffix = try session_store.generateSessionId(self.alloc);
        defer self.alloc.free(suffix);
        const work_id = try alloc.print("{s}:{s}", .{ if (started_by == .user) "fxuser" else "fxwake", suffix });
        errdefer alloc.free(work_id);
        if (open_now) try self.startTurnWorkInLog(child_id, work_id, started_by);
        var work: TurnWork = .{
            .child_id = try self.alloc.dupe(u8, child_id),
            .work_id = undefined,
            .started_by = started_by,
            .worker = worker,
            .opened = open_now,
        };
        errdefer self.alloc.free(work.child_id);
        work.work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(work.work_id);
        try self.turn_works.append(self.alloc, work);
        errdefer _ = self.turn_works.pop();
        try self.markBusyLocked(child_id);
        debug_trace.eventf("mailbox", if (started_by == .user) "user_work" else "turn_work", .{}, "child={s} work_id={s} started_by={s} opened={}", .{ child_id, work_id, @tagName(started_by), open_now });
        return work_id;
    }

    /// Starts `work_id` as the child's work in the parent's log, saying who
    /// started it.
    fn startTurnWorkInLog(self: *Runtime, child_id: []const u8, work_id: []const u8, started_by: reports.StartedBy) !void {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const agent = child.agentName() orelse return error.OneOffChild;
        _ = try registry.startPersistentWork(self.alloc, agent, null, .{
            .id = @constCast(work_id),
            .message = @constCast(""),
            .created_at_ms = io_mod.milliTimestamp(),
            .started_by = started_by,
        });
        try self.managed.state_store.save(self.alloc, registry);
    }

    /// Opens the turn work that waited for `child_id`'s ending work, as
    /// that work ends. `.ended` hands back one whose turn ended meanwhile,
    /// removed from the list, for the caller to finish.
    fn openWaitingTurnWorkLocked(self: *Runtime, child_id: []const u8) union(enum) { none, opened, ended: TurnWork } {
        const index = self.findTurnWorkLocked(child_id) orelse return .none;
        const work = &self.turn_works.items[index];
        if (work.opened) return .none;
        self.startTurnWorkInLog(child_id, work.work_id, work.started_by) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} work_id={s} err={s}", .{ child_id, work.work_id, @errorName(err) });
            var dropped = self.turn_works.swapRemove(index);
            dropped.deinit(self.alloc);
            return .none;
        };
        work.opened = true;
        debug_trace.eventf("mailbox", "turn_work_opened", .{}, "child={s} work_id={s}", .{ child_id, work.work_id });
        if (work.ended == null) return .opened;
        return .{ .ended = self.turn_works.swapRemove(index) };
    }

    /// Ends the work `beginUserWork` or `beginTurnWork` opened, with the
    /// turn's `reply`, and starts the parent's next message waiting for the
    /// child. A work still waiting to open finishes as it opens.
    pub fn endUserWork(self: *Runtime, child_id: []const u8, work_id: []const u8, outcome: child_state.Outcome, reply: []const u8) void {
        var work = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const index = self.findTurnWorkLocked(child_id) orelse return;
            const item = &self.turn_works.items[index];
            if (!std.mem.eql(u8, item.work_id, work_id)) return;
            if (!item.opened) {
                const owned = self.alloc.dupe(u8, reply) catch "";
                item.ended = .{ .outcome = outcome, .reply = @constCast(owned) };
                debug_trace.eventf("mailbox", "turn_work_ended_early", .{}, "child={s} work_id={s} outcome={s}", .{ child_id, work_id, @tagName(outcome) });
                return;
            }
            break :blk self.turn_works.swapRemove(index);
        };
        defer work.deinit(self.alloc);
        const posted = self.finishTurnWork(work, outcome, reply);
        if (end_test_controls.settleArmed()) end_test_controls.holdBeforeSettle(child_id);
        // Defers run last-declared first: the lock below is released, then a
        // closing child's close is written, then the owner's `wait` is nudged,
        // so the child's busy flag is clear and its close is written by then
        // (`nudgeWaiter`).
        defer if (!posted) self.nudgeWaiter();
        defer _ = self.settleClose(child_id);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.closingIndexLocked(child_id) != null) {
            // A closing child takes no next work, as when a slot's work ends
            // (`endClosingWork`): what waits for it is dropped and it stops
            // counting as working. The close is written below, once nothing
            // of it runs, and the owner's `wait` is nudged after that.
            _ = self.dropPendingLocked(child_id, "closed");
            self.clearBusyLocked(child_id);
            return;
        }
        const messages = self.startNextPendingLocked(child_id);
        if (messages > 0) {
            _ = self.managed.start(child_id, messages) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} error={s}", .{ child_id, @errorName(err) });
                self.clearBusyLocked(child_id);
            };
            return;
        }
        self.clearBusyLocked(child_id);
    }

    /// Finishes `work` in the log and posts its report, if it owes one. True
    /// when the sink took a post (`deliverEnd`).
    fn finishTurnWork(self: *Runtime, work: TurnWork, outcome: child_state.Outcome, reply: []const u8) bool {
        const finished = self.managed.finishTurnWork(work.child_id, work.work_id, outcome, work.started_by, switch (work.stopped_by) {
            .none => .none,
            .parent => .parent,
            .user => .user,
        });
        return self.deliverEnd(.{
            .child_id = work.child_id,
            .work_id = work.work_id,
            .outcome = outcome,
            .report_owed = finished.report_owed,
            .reply = reply,
            .end = finished.end,
        });
    }

    /// Drops a message that could not be made a work: it carries no messages.
    fn dropStart(self: *Runtime, item: Pending, err: anyerror) usize {
        debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ item.child_id, item.work.id, @errorName(err) });
        self.forgetCallLocked(item.work.id);
        return 0;
    }

    /// `wait`: blocks on the caller's own worker until a report or message
    /// is queued for it, a child's work ends with nothing to post, or the
    /// caller is stopped. Returns at once when nothing can still arrive.
    fn waitForMail(self: *Runtime, alloc: Allocator, options: ExecuteOptions) !ManagedExecutionResult {
        const worker = options.caller_worker orelse return self.refuse(alloc, .wait_unavailable);
        // Registered first, so a child that ends before the wait starts
        // still ends it.
        self.setWaiter(worker);
        defer self.setWaiter(null);
        if (worker.queuedPromptCount() == 0 and !self.anyWorking()) {
            debug_trace.eventf("mailbox", "wait_skipped", .{}, "agent={s} reason=quiet", .{self.ownerName()});
            return self.encodeManaged(alloc, .{ .ok = true, .result = "No subagent is working and no message is waiting, so nothing more will arrive. Continue, or end your turn." });
        }
        // The ones it waits for, named in its result for its row.
        var roster_arena = std.heap.ArenaAllocator.init(alloc);
        defer roster_arena.deinit();
        const waited_for = try self.roster(roster_arena.allocator(), true);
        debug_trace.eventf("mailbox", "wait_begin", .{}, "agent={s}", .{self.ownerName()});
        const wake = worker.waitForPostOrNudge();
        // Mail joins the owner's running turn only where the host marks its
        // turns; elsewhere, as in ACP, it starts the next one, and the owner
        // must end this turn to read it (`tests/tla/subagent/MainMail.tla`
        // WaitHonest).
        const follows = wake == .posted and worker.queuedMailJoinsTurn();
        debug_trace.eventf("mailbox", "wait_end", .{}, "agent={s} reason={s} said={s}", .{ self.ownerName(), @tagName(wake), if (follows) "follows" else "next" });
        return switch (wake) {
            .posted => self.encodeManaged(alloc, .{
                .ok = true,
                .result = if (follows)
                    "A report or message arrived. It follows this result."
                else
                    "A report or message arrived. It starts your next turn once this one ends, so end your turn to read it.",
                .subagents = waited_for,
            }),
            .nudged => self.encodeManaged(alloc, .{ .ok = true, .result = "A subagent's turn ended without a report. Call status to see where things stand, or wait again.", .subagents = waited_for }),
            .stopped => error.Cancelled,
        };
    }

    /// The names of this host's open subagents, or of those working when
    /// `working_only`, joined with ", " in the order `status` lists them, for
    /// the row of a call that concerns them all. Null when there are none.
    /// Reads what `status` reads, under the same locks, so any thread may
    /// call it. The caller owns the result.
    pub fn rosterNames(self: *Runtime, alloc: Allocator, working_only: bool) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const names = try self.roster(arena.allocator(), working_only);
        if (names.len == 0) return null;
        return try std.mem.join(alloc, ", ", names);
    }

    /// The names `rosterNames` joins, allocated in `alloc`.
    fn roster(self: *Runtime, alloc: Allocator, working_only: bool) ![]const []const u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = try self.managed.state_store.load(alloc);
        return self.rosterOf(alloc, registry, working_only);
    }

    /// `roster` for a caller that holds the admission mutex and has loaded
    /// `registry` under the registry lock.
    fn rosterOf(self: *Runtime, alloc: Allocator, registry: child_state.Registry, working_only: bool) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (self.closingIndexLocked(child.id) != null) continue;
            if (working_only and !self.isBusyLocked(child.id)) continue;
            try names.append(alloc, name);
        }
        return names.items;
    }

    /// How long a team note is good for. A `kept` note is built for one turn of
    /// the owner and returned for the rest of it; a `fresh` one is built for
    /// each request.
    const NoteKind = enum { kept, fresh };

    /// The refusal for `stop`, `close`, or `status` naming `agent`, which no
    /// open subagent bears: it names the open ones. Takes the locks itself, so
    /// the caller holds neither.
    fn refuseNotOpen(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const open = try self.roster(scratch.allocator(), false);
        return self.refuse(alloc, .{ .child_unavailable = .{ .not_open = .{ .agent = agent, .open = open } } });
    }

    /// What a subagent is doing, as `status` says it.
    const ChildState = enum {
        awaiting_approval,
        awaiting_answer,
        working,
        interrupted,
        finished,
        idle,

        fn label(self: ChildState) []const u8 {
            return switch (self) {
                .awaiting_approval => "waiting for an approval",
                .awaiting_answer => "waiting for the user's answer",
                .working => "working",
                .interrupted => "interrupted",
                .finished => "finished",
                .idle => "idle",
            };
        }

        /// The state as a row of the team note says it. Neither the start nor
        /// the end of an approval or question wait reaches the owner during
        /// its turn, so a kept note shows each row as it was when the turn
        /// started. Only a waiting row says so: it is the row the owner could
        /// act on wrongly, by asking the user to answer a prompt already
        /// answered. A row that reads working after a wait began is as on
        /// main, and `status` shows the wait.
        fn noteLabel(self: ChildState, kind: NoteKind) []const u8 {
            return switch (kind) {
                .fresh => self.label(),
                .kept => switch (self) {
                    inline .awaiting_approval, .awaiting_answer => |state| comptime state.label() ++ " when this turn started",
                    .working, .interrupted, .finished, .idle => self.label(),
                },
            };
        }
    };

    /// The children whose running turns wait for the user to answer a
    /// permission request or a question now, which `childStateLocked`
    /// reports as waiting, not working. In the app a child's request waits on
    /// its own agent's worker and the registry says nothing of it, so this
    /// reads the workers: the owner's, for the parent's works, and those of
    /// the turns the user started on a child's screen. (ACP and `fx ask` keep
    /// the approval in the registry as `.awaiting_approval`.) Call it under
    /// `admission_mutex` and before taking the state-store lock
    /// (`managed_owner.Owner.userWaits`). The result is in `alloc`, which
    /// should be an arena.
    fn userWaitsLocked(self: *Runtime, alloc: Allocator) ![]const managed_owner.Owner.UserWaiting {
        var waits: std.ArrayList(managed_owner.Owner.UserWaiting) = .empty;
        for (self.turn_works.items) |work| {
            const worker = work.worker orelse continue;
            const waiting_for = worker.userWait() orelse continue;
            try waits.append(alloc, .{ .child_id = work.child_id, .wait = waiting_for });
        }
        try waits.appendSlice(alloc, try self.managed.userWaits(alloc));
        return waits.items;
    }

    /// Under `admission_mutex`. `waits` is what `userWaitsLocked` returned
    /// while the lock was held.
    fn childStateLocked(self: *const Runtime, child: child_state.Child, waits: []const managed_owner.Owner.UserWaiting) ChildState {
        if (child.phase == .awaiting_approval) return .awaiting_approval;
        if (self.isBusyLocked(child.id)) {
            // A wait counts only while the child works, so one a turn's end
            // left behind could not outlast it.
            for (waits) |entry| if (std.mem.eql(u8, entry.child_id, child.id)) return switch (entry.wait) {
                .approval => .awaiting_approval,
                .question => .awaiting_answer,
            };
            return .working;
        }
        return switch (child.phase) {
            .interrupted => .interrupted,
            .finished => .finished,
            else => .idle,
        };
    }

    /// How many idle subagents a new subagent's start names; it counts the
    /// rest.
    const max_named_idle: usize = 8;

    /// The names of this host's subagents other than `except_child_id` that
    /// `status` would list as idle with no message waiting, in its order:
    /// those a new subagent's start names
    /// (`tests/tla/subagent/StopMessage.tla` NamesTheIdle). Allocated in
    /// `alloc`, which should be an arena: the registry it reads stays there.
    fn idleOthers(self: *Runtime, alloc: Allocator, except_child_id: []const u8) ![]const IdleEntry {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = try self.managed.state_store.load(alloc);
        var entries: std.ArrayList(IdleEntry) = .empty;
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (std.mem.eql(u8, child.id, except_child_id)) continue;
            if (self.closingIndexLocked(child.id) != null or self.hasPendingLocked(child.id)) continue;
            // A child that waits for the user is busy, so it is not idle
            // whichever way it waits.
            if (self.childStateLocked(child, &.{}) != .idle) continue;
            try entries.append(alloc, .{ .name = name, .purpose = child.purpose });
        }
        return entries.items;
    }

    /// How many subagents the owner's list names; it counts the rest.
    const max_team_listed: usize = 20;

    /// The owner's subagents as one runtime note: each one's name, what it
    /// is doing, how its last work ended, and what it is for, with how to
    /// manage them. Null when it has none. The note for the owner's turn
    /// `turn_id` is built once and kept for the rest of that turn, so a
    /// request's runtime context changes only when a turn starts
    /// (`src/core/agent/runtime/runtime_context.zig`); a report or a new
    /// start tells the owner of a change within the turn. A row of the kept
    /// note that waits for the user says so "when this turn started", since
    /// neither the start nor the end of a wait tells the owner
    /// (`ChildState.noteLabel`). A `turn_id` of 0, as in ACP, whose turns
    /// have no id here, builds it afresh each time, and its rows say no more
    /// than `status` does. The note is in `alloc`.
    pub fn teamNote(self: *Runtime, alloc: Allocator, turn_id: u64) Allocator.Error!?[]u8 {
        if (turn_id != 0) {
            self.team_mutex.lockUncancelable(io_mod.getIo());
            defer self.team_mutex.unlock(io_mod.getIo());
            if (self.team_turn == turn_id) return if (self.team_note) |note| try alloc.dupe(u8, note) else null;
        }
        const started = io_mod.nanoTimestamp();
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const kind: NoteKind = if (turn_id == 0) .fresh else .kept;
        const built = self.buildTeamNote(scratch.allocator(), kind) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // The note is extra: a turn goes without it.
                debug_trace.eventf("subagent", "team_note_unavailable", .{}, "agent={s} turn={d} err={s}", .{ self.ownerName(), turn_id, @errorName(err) });
                return null;
            },
        };
        debug_trace.eventf("subagent", "team_note", .{}, "agent={s} turn={d} listed={d} more={d} bytes={d} build_us={d}", .{
            self.ownerName(),                 turn_id,                                           built.listed, built.more,
            if (built.note) |n| n.len else 0, @divTrunc(io_mod.nanoTimestamp() - started, 1000),
        });
        if (turn_id != 0) {
            const kept = if (built.note) |note| try self.alloc.dupe(u8, note) else null;
            self.team_mutex.lockUncancelable(io_mod.getIo());
            defer self.team_mutex.unlock(io_mod.getIo());
            if (self.team_note) |old| self.alloc.free(old);
            self.team_note = kept;
            self.team_turn = turn_id;
        }
        return if (built.note) |note| try alloc.dupe(u8, note) else null;
    }

    const BuiltTeam = struct { note: ?[]const u8, listed: usize, more: usize };

    /// Reads the registry under the same locks as `status`.
    fn buildTeamNote(self: *Runtime, alloc: Allocator, kind: NoteKind) !BuiltTeam {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const waits = try self.userWaitsLocked(alloc);
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = try self.managed.state_store.load(alloc);
        var rows: std.ArrayList(TeamRow) = .empty;
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (self.closingIndexLocked(child.id) != null) continue;
            try rows.append(alloc, .{
                .name = name,
                .state = self.childStateLocked(child, waits).noteLabel(kind),
                .outcome = if (child.last_outcome) |outcome| @tagName(outcome) else null,
                .purpose = child.purpose,
            });
        }
        if (rows.items.len == 0) return .{ .note = null, .listed = 0, .more = 0 };
        const listed = @min(rows.items.len, max_team_listed);
        return .{ .note = try teamNoteText(alloc, rows.items, max_team_listed), .listed = listed, .more = rows.items.len - listed };
    }

    /// `status`: each subagent, or the one named, with what it is doing.
    fn statusOf(self: *Runtime, alloc: Allocator, agent: ?[]const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var listed: usize = 0;
        // The open subagents a status that names none reports on, named in
        // its result for its row.
        var open: std.ArrayList([]const u8) = .empty;
        // Read before the locks below: the owner takes the registry's lock
        // under its own mutex.
        const calls = try self.managed.currentCalls(a);
        const now_ms = io_mod.milliTimestamp();
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const waits = try self.userWaitsLocked(a);
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(a);
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (self.closingIndexLocked(child.id) != null) continue;
            if (agent) |wanted| if (!std.mem.eql(u8, wanted, name)) continue;
            if (agent == null) try open.append(a, name);
            var waiting: usize = 0;
            for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.child_id, child.id)) waiting += 1;
            }
            if (listed > 0) try out.writer.writeByte('\n');
            try out.writer.print("{s}: {s}", .{ name, self.childStateLocked(child, waits).label() });
            if (self.isBusyLocked(child.id)) for (calls) |entry| {
                if (!std.mem.eql(u8, entry.child_id, child.id)) continue;
                try out.writer.print(", in {s} for ", .{entry.call.label()});
                try activity_status.writeElapsed(&out.writer, @intCast(entry.call.runningMs(now_ms) / std.time.ms_per_s));
                break;
            };
            if (waiting > 0) try out.writer.print(", {d} waiting message{s}", .{ waiting, if (waiting == 1) "" else "s" });
            if (child.last_outcome) |outcome| try out.writer.print(", last work {s}", .{@tagName(outcome)});
            try out.writer.print(", reports {s}", .{@tagName(child.report_rule)});
            if (child.purpose) |purpose| try out.writer.print(". For: {s}", .{purpose});
            listed += 1;
        }
        for (self.user_closed.items) |name| {
            if (agent) |wanted| if (!std.mem.eql(u8, wanted, name)) continue;
            // A close that couldn't be saved left the child in place.
            if (registry.findPersistent(name) != null) continue;
            if (listed > 0) try out.writer.writeByte('\n');
            try out.writer.print("{s}: closed by the user; a message to it starts a new one with no history", .{name});
            listed += 1;
        }
        if (agent) |wanted| if (listed == 0) {
            const open_now = try self.rosterOf(a, registry, false);
            return self.refuse(alloc, .{ .child_unavailable = .{ .not_open = .{ .agent = wanted, .open = open_now } } });
        };
        if (listed == 0) try out.writer.writeAll("No subagents yet.");
        return self.encodeManaged(alloc, .{ .ok = true, .result = out.written(), .subagents = if (agent == null) open.items else null });
    }

    /// `stop`: ends the named child's running turn, which then owes no
    /// report, and drops the messages waiting for it.
    fn stopChild(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const child_id = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(a);
            const child = registry.findPersistent(agent) orelse break :blk null;
            break :blk try a.dupe(u8, child.id);
        } orelse return self.refuseNotOpen(alloc, agent);
        const dropped, const stopped = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const waiting = self.dropPendingLocked(child_id, "stopped");
            // The stopped turn's unread messages go with it, so they count
            // too, and so do the messages its slot keeps or carries into the
            // next work (`tests/tla/subagent/StopMessage.tla` NoSilentLoss).
            const unread = self.managed.stop(child_id);
            end_test_controls.holdInStop(child_id);
            const held = self.managed.takeDropped(child_id);
            if (unread) |count| break :blk .{ waiting + count + held, true };
            break :blk .{ waiting + held, self.stopTurnWorkLocked(child_id) };
        };
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=parent running={} dropped={d}", .{ child_id, stopped, dropped });
        const dropped_text = switch (dropped) {
            0 => "",
            1 => "the message waiting for it was dropped",
            else => try a.print("the {d} messages waiting for it were dropped", .{dropped}),
        };
        const text = if (stopped)
            try a.print("Stopped {s}: its turn ended{s}{s}.", .{ agent, if (dropped > 0) ", and " else "", dropped_text })
        else
            try a.print("{s} was not working{s}{s}.", .{ agent, if (dropped > 0) "; " else "", dropped_text });
        return self.encodeManaged(alloc, .{ .ok = true, .result = text });
    }

    /// Ends the turn of a work the parent didn't start, as its `stop`
    /// ends one it did: the work owes no report.
    fn stopTurnWorkLocked(self: *Runtime, child_id: []const u8) bool {
        const index = self.findTurnWorkLocked(child_id) orelse return false;
        const work = &self.turn_works.items[index];
        work.stopped_by = .parent;
        if (work.worker) |worker| worker.requestTurnCancel();
        return true;
    }

    /// Who closes a child: its parent's `close`, or the user from the
    /// agent list.
    pub const CloseBy = enum { parent, user };

    /// What a close found: whether the child's work was running, and how
    /// many of the parent's messages waiting for it were dropped.
    pub const Closed = struct { stopped: bool, dropped: usize };

    /// Closes child `child_id` for good: the parent's messages waiting for
    /// it are dropped, its running work or turn is stopped, and once nothing
    /// of it runs the close is written to the parent's log and it leaves
    /// this host's children (`child_state.Store.close`). The parent's close
    /// owes no report; the user's close of work the parent started reports
    /// that the user closed it. The app drops the child's agent once it
    /// takes the child from `takeClosed`. False when there is no such child.
    pub fn closeChild(self: *Runtime, child_id: []const u8, by: CloseBy) !?Closed {
        var name_buf: [domain.max_agent_name_bytes]u8 = undefined;
        const name: ?[]const u8 = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(self.alloc);
            defer registry.deinit(self.alloc);
            const child = registry.findById(child_id) orelse return null;
            const value = child.agentName() orelse break :blk null;
            @memcpy(name_buf[0..value.len], value);
            break :blk name_buf[0..value.len];
        };
        const result: Closed, const settle_now = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            if (self.closingIndexLocked(child_id) != null) break :blk .{ .{ .stopped = false, .dropped = 0 }, false };
            const owned = try self.alloc.dupe(u8, child_id);
            errdefer self.alloc.free(owned);
            const unseen = try self.alloc.dupe(u8, child_id);
            errdefer self.alloc.free(unseen);
            try self.closing.ensureUnusedCapacity(self.alloc, 1);
            try self.closed_unseen.ensureUnusedCapacity(self.alloc, 1);
            const dropped = self.dropPendingLocked(child_id, "closed");
            // A message waiting for the closed child's start is refused by
            // its own call, so the close does not count it.
            for (self.start_waits.items) |wait| {
                if (std.mem.eql(u8, wait.child_id, child_id)) wait.closed = true;
            }
            // A user's close tells the parent what it dropped, as a stop does,
            // and keeps the name for main's status and its next message to it.
            if (by == .user) {
                self.noteUserDropLocked(child_id, dropped, true);
                if (name) |value| self.noteUserClosedLocked(value);
            }
            // The parent's close drops the closed turn's unread messages
            // and counts them, as its stop does.
            var unread: usize = 0;
            const stopped = switch (by) {
                .parent => if (self.managed.stop(child_id)) |count| ended: {
                    unread = count;
                    break :ended true;
                } else false,
                .user => self.managed.closeByUser(child_id),
            } or self.stopTurnWorkLocked(child_id);
            // So do the messages its slot keeps or carries into the next work.
            // The user's close counts none of them.
            if (by == .parent) {
                end_test_controls.holdInStop(child_id);
                unread += self.managed.takeDropped(child_id);
            }
            self.closing.appendAssumeCapacity(.{ .id = owned });
            self.closed_unseen.appendAssumeCapacity(unseen);
            self.closed_waiting.store(true, .release);
            debug_trace.eventf("mailbox", "close", .{}, "target={s} by={s} running={} dropped={d}", .{ child_id, @tagName(by), stopped, dropped + unread });
            break :blk .{ .{ .stopped = stopped, .dropped = dropped + unread }, !self.isBusyLocked(child_id) and !self.inTurnWorkLocked(child_id) };
        };
        if (settle_now and !self.settleClose(child_id)) return error.CloseNotSaved;
        return result;
    }

    /// `close`: closes the named child for good (`closeChild`).
    fn closeNamed(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const child_id = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(a);
            const child = registry.findPersistent(agent) orelse break :blk null;
            break :blk try a.dupe(u8, child.id);
        } orelse return self.refuseNotOpen(alloc, agent);
        const closed = (self.closeChild(child_id, .parent) catch |err| switch (err) {
            error.CloseNotSaved => return self.encodeManaged(alloc, .{
                .ok = false,
                .error_code = "close_not_saved",
                .result = try a.print("The close of {s} couldn't be saved, so it is still open.", .{agent}),
            }),
            else => return err,
        }) orelse return self.refuseNotOpen(alloc, agent);
        const dropped_text = switch (closed.dropped) {
            0 => "",
            1 => " The message waiting for it was dropped.",
            else => try a.print(" The {d} messages waiting for it were dropped.", .{closed.dropped}),
        };
        const text = try a.print("Closed {s}{s}.{s} A later message to {s} starts a new one.", .{
            agent,
            if (closed.stopped) ", ending its turn" else "",
            dropped_text,
            agent,
        });
        return self.encodeManaged(alloc, .{ .ok = true, .result = text });
    }

    /// Whether a child was closed since the last `takeClosed`.
    pub fn hasClosed(self: *const Runtime) bool {
        return self.closed_waiting.load(.acquire);
    }

    /// The children closed or closing since the last call, for the app to
    /// drop their agents. The caller owns the ids. Cheap when none is.
    pub fn takeClosed(self: *Runtime, alloc: Allocator) ![][]u8 {
        if (!self.closed_waiting.load(.acquire)) return &.{};
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const ids = try alloc.alloc([]u8, self.closed_unseen.items.len);
        var moved: usize = 0;
        errdefer {
            for (ids[0..moved]) |id| alloc.free(id);
            alloc.free(ids);
        }
        for (self.closed_unseen.items) |id| {
            ids[moved] = try alloc.dupe(u8, id);
            moved += 1;
        }
        for (self.closed_unseen.items) |id| self.alloc.free(id);
        self.closed_unseen.clearRetainingCapacity();
        self.closed_waiting.store(false, .release);
        return ids;
    }

    fn removeStartWaitLocked(self: *Runtime, wait: *StartWait) void {
        for (self.start_waits.items, 0..) |item, index| {
            if (item != wait) continue;
            _ = self.start_waits.swapRemove(index);
            return;
        }
    }

    fn closingIndexLocked(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.closing.items, 0..) |entry, index| if (std.mem.eql(u8, entry.id, child_id)) return index;
        return null;
    }

    /// A closing child's work ended: it takes no next work, and what waits
    /// for it is dropped. False for a child that isn't closing.
    fn endClosingWork(self: *Runtime, end: managed_owner.WorkEnd) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.closingIndexLocked(end.child_id) == null) return false;
        self.forgetCallLocked(end.work_id);
        _ = self.dropPendingLocked(end.child_id, "closed");
        // A turn that began before the close, waiting for this work to end
        // so its own could open, never reached the log: it goes with it.
        if (self.findTurnWorkLocked(end.child_id)) |index| if (!self.turn_works.items[index].opened) {
            var waiting = self.turn_works.swapRemove(index);
            debug_trace.eventf("mailbox", "turn_work_dropped", .{}, "child={s} work_id={s} reason=closed", .{ end.child_id, waiting.work_id });
            waiting.deinit(self.alloc);
        };
        self.clearBusyLocked(end.child_id);
        self.managed.markEnding(end.child_id);
        return true;
    }

    /// Writes the close of `child_id` once nothing of it runs, when it is
    /// closing. The child stays closing until the write returns: the write
    /// runs outside `admission_mutex`, which the main loop takes, so the mark
    /// is what keeps the child out of the list, marked in the trace, and
    /// closed to messages meanwhile. One thread writes a close; another that
    /// reaches it meanwhile leaves it to that one. False only when the write
    /// failed, which leaves the child listed again, as before its close, and
    /// is traced.
    fn settleClose(self: *Runtime, child_id: []const u8) bool {
        const work_id = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const index = self.closingIndexLocked(child_id) orelse return true;
            const entry = &self.closing.items[index];
            if (entry.settling) return true;
            if (self.isBusyLocked(child_id) or self.inTurnWorkLocked(child_id)) return true;
            const id = self.alloc.print(close_work_prefix ++ "{s}", .{entry.id}) catch |err| {
                self.finishCloseLocked(child_id, err);
                return false;
            };
            entry.settling = true;
            break :blk id;
        };
        defer self.alloc.free(work_id);
        const owned = work_id[close_work_prefix.len..];
        close_test_controls.holdWrite(owned);
        // The registry's lock is released before admission's is taken.
        const failure: ?anyerror = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            if (close_test_controls.failedWrite()) |err| break :blk err;
            self.managed.state_store.close(owned, work_id) catch |err| break :blk err;
            break :blk null;
        };
        self.finishClose(owned, failure);
        if (failure != null) return false;
        debug_trace.eventf("mailbox", "closed", .{}, "child={s}", .{owned});
        self.managed.forgetFeedback(owned);
        return true;
    }

    /// The end of a close, written or not: the child stops being closing. A
    /// close that couldn't be written leaves the child, so the app, if it
    /// hasn't yet, keeps its agent too.
    fn finishClose(self: *Runtime, child_id: []const u8, failure: ?anyerror) void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        self.finishCloseLocked(child_id, failure);
    }

    fn finishCloseLocked(self: *Runtime, child_id: []const u8, failure: ?anyerror) void {
        if (failure) |err| debug_trace.logf("mailbox", "close not written child={s} err={s}", .{ child_id, @errorName(err) });
        if (self.closingIndexLocked(child_id)) |index| self.alloc.free(self.closing.swapRemove(index).id);
        if (failure == null) return;
        for (self.closed_unseen.items, 0..) |id, index| {
            if (!std.mem.eql(u8, id, child_id)) continue;
            self.alloc.free(self.closed_unseen.orderedRemove(index));
            break;
        }
        if (self.closed_unseen.items.len == 0) self.closed_waiting.store(false, .release);
    }

    /// `message{agent: "parent"}`: a child of this host writes to the
    /// host's owner, and the owner, when it is a subagent, writes to its
    /// own parent. The message arrives framed as the subagent's.
    fn messageParent(self: *Runtime, alloc: Allocator, text: []const u8, options: ExecuteOptions, from_root: bool) !ManagedExecutionResult {
        if (from_root and !self.owner_has_parent) return self.refuse(alloc, .{ .no_parent = .none });
        const sink = self.report_sink orelse return self.refuse(alloc, .{ .no_parent = .unreachable_now });
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const agent = if (from_root) "" else self.childName(arena.allocator(), options.caller_id) catch options.caller_id;
        // What the user typed in the turn that sends it, from that turn's
        // own worker, so the parent sees the user's own words.
        const typed: []const []const u8 = if (options.caller_worker) |worker|
            worker.typedThisTurn(arena.allocator()) catch |err| blk: {
                debug_trace.logf("mailbox", "typed lines unavailable from={s} err={s}", .{ options.caller_id, @errorName(err) });
                break :blk &.{};
            }
        else
            &.{};
        sink.post(self, .{ .message = .{
            .to = if (from_root) .owners_parent else .owner,
            .agent = agent,
            .child_id = options.caller_id,
            .text = text,
            .user_typed = typed,
        } }) catch |err| return self.refuse(alloc, if (err == error.QueueFull) .{ .queue_full = .parent } else .{ .no_parent = .unreachable_now });
        debug_trace.eventf("mailbox", "post", .{}, "from={s} to={s} typed={d}", .{ options.caller_id, if (from_root) "owners_parent" else self.ownerName(), typed.len });
        return self.encodeManaged(alloc, .{ .ok = true, .result = "Sent to your parent. It arrives as your message, never as the user's." });
    }

    /// Tells the owner, as child `child_id`'s own message, that its request
    /// failed and waits: for a follow-up a message back gives it, when
    /// `resend`, and otherwise for the user. `reason` is the recovery's
    /// wording, such as "Sign-in expired".
    pub fn noteChildWaiting(self: *Runtime, child_id: []const u8, name: []const u8, reason: []const u8, resend: bool) void {
        const sink = self.report_sink orelse return debug_trace.logf("mailbox", "waiting note dropped child={s} reason=no_parent", .{child_id});
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const text = (if (resend)
            arena.allocator().print("fx: my last request failed and waits for a follow-up ({s}). A message from you sends it again.", .{reason})
        else
            arena.allocator().print("fx: my last request failed and waits for the user ({s}). Only the user can continue it, on my screen, so tell them.", .{reason})) catch return;
        sink.post(self, .{ .message = .{ .to = .owner, .agent = name, .child_id = child_id, .text = text } }) catch |err|
            debug_trace.logf("mailbox", "waiting note lost child={s} err={s}", .{ child_id, @errorName(err) });
    }

    /// Tells the owner, as child `child_id`'s own message, that a shell
    /// command of its running turn crossed the quiet limit, once for each
    /// quiet spell, so a parent that waits on it hears of a command that may
    /// be hung (`tests/tla/subagent/QuietRelay.tla`). A note for a child that
    /// is closing or gone, or one the parent's queue refuses, is dropped with
    /// a trace line. The check and the post are separate steps, since the
    /// sink takes its own locks: a close between them lets that one note
    /// through, as it does a child's own message.
    pub fn noteChildQuiet(self: *Runtime, child_id: []const u8, name: []const u8, crossing: types.QuietCrossing) void {
        if (!self.childOpen(child_id)) return debug_trace.eventf("mailbox", "quiet_note_dropped", .{}, "child={s} reason=closed quiet_ms={d}", .{ child_id, crossing.quiet_ms });
        const sink = self.report_sink orelse return debug_trace.eventf("mailbox", "quiet_note_dropped", .{}, "child={s} reason=no_parent quiet_ms={d}", .{ child_id, crossing.quiet_ms });
        var label: [live_metrics.max_label_bytes]u8 = undefined;
        const command = label[0..live_metrics.storeLabel(&label, crossing.command)];
        var buffer: [live_metrics.max_label_bytes + 256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        quietNoteText(&writer, command, crossing.quiet_ms) catch
            return debug_trace.eventf("mailbox", "quiet_note_dropped", .{}, "child={s} reason=too_long quiet_ms={d}", .{ child_id, crossing.quiet_ms });
        sink.post(self, .{ .message = .{ .to = .owner, .agent = name, .child_id = child_id, .text = writer.buffered() } }) catch |err|
            return debug_trace.eventf("mailbox", "quiet_note_dropped", .{}, "child={s} reason={s} quiet_ms={d}", .{ child_id, @errorName(err), crossing.quiet_ms });
        debug_trace.eventf("mailbox", "quiet_note_posted", .{}, "child={s} quiet_ms={d}", .{ child_id, crossing.quiet_ms });
    }

    /// Whether `child_id` is one of this host's children and not closing.
    fn childOpen(self: *Runtime, child_id: []const u8) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.closingIndexLocked(child_id) != null) return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = self.managed.state_store.load(arena.allocator()) catch |err| {
            debug_trace.logf("mailbox", "quiet note check failed child={s} err={s}", .{ child_id, @errorName(err) });
            return false;
        };
        for (registry.children) |child| if (std.mem.eql(u8, child.id, child_id)) return true;
        return false;
    }

    /// Records the start, or with a null `label` the end, of call `call_id`
    /// in child `child_id`'s running turn, for status and the agent list:
    /// the interactive app calls it for its hosted children, whose events
    /// reach the app instead of the turn.
    pub fn noteChildCall(self: *Runtime, child_id: []const u8, call_id: []const u8, label: ?[]const u8) void {
        self.managed.noteCall(child_id, call_id, label, io_mod.milliTimestamp());
    }

    /// Child `child_id`'s current tool call, while its turn runs.
    pub fn childCall(self: *Runtime, child_id: []const u8) ?live_metrics.Call {
        return self.managed.currentCall(child_id);
    }

    const ChildProfile = union(enum) {
        loaded: profiles.Profile,
        rejected: model_contract.Result,
    };

    /// Loads the profile a new child asks for, from the fx home and the
    /// session's workspace root (`cache_roots`, the profile cache's), as
    /// `fx --profile` does in the directory it runs in. The result and any
    /// message belong to `arena`.
    fn loadChildProfile(arena: Allocator, cache_roots: authority.ProfileCache.LoadRoots, name: []const u8) !ChildProfile {
        const roots = try profiles.Roots.init(arena, cache_roots.home, cache_roots.workspace_root);
        var failure: ?[]const u8 = null;
        const profile = profiles.load(arena, roots, name, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .rejected = .{ .ok = false, .error_code = "profile_unavailable", .result = failure } },
        };
        debug_trace.eventf("profile", "profile_admitted", .{}, "name={s} source={s} mode={s}", .{
            profile.name,
            @tagName(profile.source),
            if (profile.permission_mode) |mode| @tagName(mode) else "inherit",
        });
        return .{ .loaded = profile };
    }

    const OverrideModelResolution = union(enum) {
        /// Resolved canonical catalog ID, or null to keep the raw override.
        accepted: ?[]const u8,
        rejected: model_contract.Result,
    };

    /// Resolves a creation-time model override against the model catalog before
    /// any child session exists, so an unknown or ambiguous name fails fast
    /// with actionable guidance instead of dying in the child after a wasted
    /// gateway request. Without a resolver (or a ready catalog) the raw
    /// override passes through and the gateway remains the final arbiter.
    fn resolveOverrideModel(
        alloc: Allocator,
        override: model_contract.Override,
        options: ExecuteOptions,
    ) !OverrideModelResolution {
        const raw_model = override.model orelse return .{ .accepted = null };
        // Only the gateway catalog is an authoritative model list. Configured
        // providers (OpenAI-compatible endpoints) accept arbitrary model IDs,
        // so overrides for those children pass through to the provider.
        if (options.defaults.provider != .gateway) {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=non_gateway_provider", .{raw_model});
            return .{ .accepted = null };
        }
        const resolver = options.model_override_resolver orelse {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_resolver", .{raw_model});
            return .{ .accepted = null };
        };
        switch (try resolver.resolve(alloc, raw_model)) {
            .no_catalog => {
                debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_catalog", .{raw_model});
                return .{ .accepted = null };
            },
            .matched => |id| {
                if (!std.mem.eql(u8, id, raw_model)) {
                    debug_trace.logf(
                        "subagent",
                        "model override resolved raw={s} resolved={s}",
                        .{ raw_model, id },
                    );
                }
                return .{ .accepted = id };
            },
            .ambiguous => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=ambiguous_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "ambiguous_model",
                    .result = try modelOverrideFailureMessage(alloc, .ambiguous, raw_model, candidates),
                } };
            },
            .unknown => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=unknown_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "unknown_model",
                    .result = try modelOverrideFailureMessage(alloc, .unknown, raw_model, candidates),
                } };
            },
        }
    }

    fn managedOwnerValue(self: *Runtime) managed_owner.Owner {
        return .{
            .alloc = self.alloc,
            .children = self.children,
            .state_store = self.childStateStore(),
            .services = .{
                .context = self,
                .bind_fn = if (self.child_runner.bind_fn != null) bindChild else null,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = &self.approvals,
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{ .children = self.children, .parent_id = self.root_id };
    }

    const ManagedAdmission = union(enum) {
        /// `created` when this admission made the child, and `user_closed`
        /// when it took the name of one the user closed.
        ready: struct { child_id: []u8, created: bool = false, user_closed: bool = false },
        feedback: struct { child_id: []u8, work_id: []u8 },
        completed: struct {
            child_id: []u8,
            observation: managed_owner.Observation,
        },
        rejected: struct {
            child_id: ?[]u8 = null,
            refusal: refusal.Refusal,
        },

        fn deinit(self: *ManagedAdmission, alloc: Allocator) void {
            switch (self.*) {
                .ready => |ready| alloc.free(ready.child_id),
                .feedback => |value| {
                    alloc.free(value.child_id);
                    alloc.free(value.work_id);
                },
                .completed => |completed| alloc.free(completed.child_id),
                .rejected => |failure| if (failure.child_id) |child_id| {
                    alloc.free(child_id);
                },
            }
            self.* = undefined;
        }
    };

    fn admitAndStartManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
        started_with: ?started_with_mod.StartedWith,
    ) !ManagedAdmission {
        // A running registry entry must not be exposed before its Slot exists.
        // Release the registry lock before taking the managed-owner lock.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        var admitted = try self.admitManagedWork(alloc, request, operation_id, options, resolved_model, started_with);
        errdefer admitted.deinit(alloc);
        if (admitted == .ready) {
            const child_id = admitted.ready.child_id;
            try self.markBusyLocked(child_id);
            _ = self.managed.start(child_id, 0) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} work_id={s} error={s}", .{ child_id, operation_id, @errorName(err) });
                self.clearBusyLocked(child_id);
                return err;
            };
            if (admitted.ready.created) {
                debug_trace.eventf("mailbox", "launch", .{}, "child={s} work_id={s}", .{ child_id, operation_id });
                if (request.agentName()) |name| admitted.ready.user_closed = self.forgetUserClosedLocked(name);
            } else debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=next_turn", .{ child_id, operation_id });
        }
        return admitted;
    }

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
        started_with: ?started_with_mod.StartedWith,
    ) !ManagedAdmission {
        const fingerprint = model_contract.requestFingerprint(request);
        const defaults = effectiveDefaults(options.defaults, request.override(), resolved_model);
        debug_trace.logf(
            "subagent",
            "admission requested operation={s} action={s} agent={s} override={s}",
            .{
                operation_id,
                @tagName(request.action()),
                request.agentName() orelse "none",
                if (request.override().present()) "yes" else "no",
            },
        );
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        if (registry.findByOperation(operation_id)) |existing| {
            const observed = child_state.Registry.operationFingerprint(
                existing.*,
                operation_id,
            ) orelse return managedAdmissionRejected(
                alloc,
                existing.id,
                .operation_conflict,
            );
            if (!std.mem.eql(u8, &observed, &fingerprint)) {
                debug_trace.logf(
                    "subagent",
                    "admission rejected operation={s} child_id={s} code=operation_conflict",
                    .{ operation_id, existing.id },
                );
                return managedAdmissionRejected(
                    alloc,
                    existing.id,
                    .operation_conflict,
                );
            }
            try self.ensureManagedChildSession(
                existing.id,
                operation_id,
                defaults,
            );
            if (existing.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return .{ .completed = .{
                    .child_id = try alloc.dupe(u8, existing.id),
                    .observation = .{
                        .phase = existing.phase,
                        .outcome = existing.last_outcome,
                        .failure = existing.last_failure,
                    },
                } };
            }
            return managedAdmissionReady(alloc, existing.id, false);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
        );
        defer active.deinit(alloc);
        switch (request) {
            .wait, .status, .stop, .close => unreachable,
            .message => |message| {
                if (registry.findPersistent(message.agent)) |child| {
                    // Closing, it takes nothing; once gone, the name starts a new one.
                    if (self.closingIndexLocked(child.id) != null) return managedAdmissionRejected(alloc, child.id, .child_closing);
                    if (request.override().present()) {
                        debug_trace.logf(
                            "subagent",
                            "admission rejected operation={s} child_id={s} agent={s} code=override_after_create",
                            .{ operation_id, child.id, message.agent },
                        );
                        return managedAdmissionRejected(
                            alloc,
                            child.id,
                            .override_after_create,
                        );
                    }
                    // A child whose slot still runs works between turns too:
                    // the message joins or waits, never starts a second run.
                    const phase: child_state.Phase = if (self.isBusyLocked(child.id)) .running else child.phase;
                    const plan = model_contract.plan(request, .{ .kind = .persistent, .phase = phase });
                    if (plan != .reject) if (message.report) |rule| {
                        try registry.setReportRule(child.id, rule);
                        try self.managed.state_store.save(alloc, registry);
                    };
                    switch (plan) {
                        .steer_persistent => {
                            const id = try alloc.dupe(u8, child.id);
                            errdefer alloc.free(id);
                            // Between works there is no turn to join, so the
                            // message waits for the next one.
                            const work_id = if (child.active) |active_work| active_work.id else "";
                            return .{ .feedback = .{ .child_id = id, .work_id = try alloc.dupe(u8, work_id) } };
                        },
                        .reject => |code| return managedAdmissionRejected(alloc, child.id, refusal.fromReject(code)),
                        .continue_persistent => {},
                        .create_persistent => unreachable,
                    }
                    const started = try registry.startPersistentWork(
                        alloc,
                        message.agent,
                        message.instructions,
                        active,
                    );
                    try self.managed.state_store.save(alloc, registry);
                    // A child lost before its first turn has no log to
                    // resume, so its next work starts it fresh (D33).
                    try self.ensureManagedChildSession(started.id, active.id, defaults);
                    return managedAdmissionReady(alloc, started.id, false);
                }
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                ) catch |err| switch (err) {
                    error.CapacityExceeded => {
                        debug_trace.logf("subagent", "create refused agent={s}: open subagents at the limit", .{message.agent});
                        return managedAdmissionRejected(alloc, null, .{ .host_failure = .subagent_limit });
                    },
                    else => return err,
                };
                // Without one named it runs in fx's own main, which sets
                // nothing, so it has what its parent has.
                try registry.setProfile(alloc, child_id, request.override().profile orelse profiles.main_name);
                if (started_with) |started| if (request.override().profile) |name| try recordStartedWith(alloc, &registry, child_id, name, started);
                // What it is for, in its parent's list of subagents.
                if (try child_state.purposeOf(alloc, message.instructions, message.message)) |purpose| {
                    defer alloc.free(purpose);
                    try registry.setPurpose(alloc, child_id, purpose);
                }
                if (message.report) |rule| try registry.setReportRule(child_id, rule);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                    true,
                );
            },
        }
    }

    /// Saves what the profile a new child started in set with the child, unless
    /// it would not fit in a spawn line's data. Then the child saves none, reads
    /// its profile by name as a child from before this did, and a trace line
    /// names the child, the profile, and the size.
    fn recordStartedWith(alloc: Allocator, registry: *child_state.Registry, child_id: []const u8, profile_name: []const u8, started: started_with_mod.StartedWith) !void {
        const encoded = try started_with_mod.encode(alloc, started);
        defer alloc.free(encoded);
        if (!started_with_mod.fits(encoded)) {
            debug_trace.logf("subagent", "saved profile skipped child={s} profile={s} bytes={d} limit={d}; its profile is read by name", .{ child_id, profile_name, encoded.len, started_with_mod.max_bytes });
            return;
        }
        try registry.setStartedWith(alloc, child_id, started);
    }

    fn ensureManagedChildSession(
        self: *Runtime,
        child_id: []const u8,
        work_id: []const u8,
        defaults: Defaults,
    ) !void {
        // A child reaches the disk with its first turn, under the id its
        // spawn line names (D34); until then only its settings wait here.
        try self.children.rememberSeed(child_id, .{
            .preferences = .{
                .provider = defaults.provider,
                .model = @constCast(defaults.model),
                .effort = defaults.effort,
                .fast_mode = defaults.fast_mode,
                .ultrafast_mode = defaults.ultrafast_mode,
            },
            .language = defaults.conversation_language,
        });
        debug_trace.logf(
            "subagent",
            "child session reserved child_id={s} work_id={s} provider={s} model={s} effort={s} fast_mode={} ultrafast_mode={}",
            .{ child_id, work_id, @tagName(defaults.provider), defaults.model, defaults.effort.label(), defaults.fast_mode, defaults.ultrafast_mode },
        );
    }

    fn managedResultText(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
    ) !?[]u8 {
        const history = self.children.parent.store.childHistory(alloc, child_id) catch return null;
        defer types.freeHistoryTurnSlice(alloc, history);
        const text = assistantTextForWork(history, work_id) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, text));
    }

    /// A child's saved preferences, read without opening it. Caller owns.
    fn childPreferences(self: *Runtime, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        return self.children.parent.store.childPreferences(alloc, child_id);
    }

    fn encodeManaged(
        self: *Runtime,
        alloc: Allocator,
        result: model_contract.Result,
    ) !ManagedExecutionResult {
        _ = self;
        return .{
            .success = result.ok,
            .pending = result.pending,
            .body = try model_contract.encodeResultAlloc(alloc, result),
        };
    }

    /// A refusal as the result the model reads: its code and what to try
    /// next (`refusal.zig`).
    fn refuse(self: *Runtime, alloc: Allocator, why: refusal.Refusal) !ManagedExecutionResult {
        _ = self;
        return .{ .success = false, .body = try why.body(alloc) };
    }
};

fn operationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.print("fxop:2:m:{d}:{s}", .{ epoch, &hex });
}

test "internal operation identity is deterministic and invocation-bound" {
    const alloc = std.testing.allocator;
    const first = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(first);
    const replay = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(replay);
    const changed = try operationIdAlloc(alloc, "call-2", 41);
    defer alloc.free(changed);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try std.testing.expect(std.mem.startsWith(u8, first, "fxop:2:m:41:"));
}

test "creation defaults keep parent values unless the request overrides them" {
    const parent = Defaults{
        .provider = .gateway,
        .model = "parent-model",
        .effort = .auto,
        .conversation_language = session.ConversationLanguage.default(),
    };
    const inherited = effectiveDefaults(parent, .{}, null);
    try std.testing.expectEqualStrings("parent-model", inherited.model);
    try std.testing.expect(inherited.effort.isDefault());
    const overridden = effectiveDefaults(parent, .{
        .model = "gpt-5.6-sol-fast",
        .effort = types.ReasoningEffort.parse("medium"),
    }, null);
    try std.testing.expectEqualStrings("gpt-5.6-sol-fast", overridden.model);
    try std.testing.expectEqualStrings("medium", overridden.effort.label());
    try std.testing.expectEqual(parent.provider, overridden.provider);
    // Model-only and effort-only overrides leave the other value inherited.
    const model_only = effectiveDefaults(parent, .{ .model = "other-model" }, null);
    try std.testing.expectEqualStrings("other-model", model_only.model);
    try std.testing.expect(model_only.effort.isDefault());
    // A catalog-resolved model wins over the raw override text.
    const resolved = effectiveDefaults(parent, .{ .model = "terra-fast" }, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", resolved.model);
    // Without an override there is nothing to resolve.
    const no_override = effectiveDefaults(parent, .{}, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("parent-model", no_override.model);
}

/// A host whose children run until released, and whose reports and
/// messages are recorded, for the mailbox tests below.
const MailboxFixture = struct {
    /// While set, a run waits for `release` or its cancel.
    hold: bool = false,
    /// While set, a run's turn takes steering, as a model turn's does, so
    /// a message can join it.
    steerable: bool = false,
    /// While set, the first run fails once released.
    fail_first: bool = false,
    /// While set, a cancelled run stays in its turn until `release`, so a
    /// stop meets a turn that is still winding down.
    linger: bool = false,
    /// While set, each run saves an empty reply.
    empty_reply: bool = false,
    /// While set, the sink takes no report, as when its owner is gone.
    refuse_reports: bool = false,
    /// What each run waits on the user for, through its worker, before it
    /// goes on: a permission request or a question, as a child's tool call
    /// does in the app.
    asks: enum { nothing, permission, question } = .nothing,
    /// The worker of the child agent that runs each turn, as the app's does:
    /// set, the runs are hosted (`bind`), and a hosted run saves nothing.
    hosted: ?*worker_runtime.WorkerRuntime = null,
    /// While set, a hosted run fails to bind to its agent (`bind`), so its work
    /// ends before its worker attaches.
    bind_fails: std.atomic.Value(bool) = .init(false),
    /// While set, a hosted run's bind returns `error.Cancelled` when its cancel
    /// is already set, as the app's does, before it looks at `bind_fails`.
    bind_honors_cancel: bool = false,
    release: std.Io.Event = .unset,
    runs: std.atomic.Value(usize) = .init(0),
    /// How many runs began with their cancel flag already set: a work that
    /// was stopped before it started.
    cancelled_at_start: std.atomic.Value(usize) = .init(0),
    /// How many runs' turns began. A run a stop ended before its turn began
    /// is counted in `runs` and not here.
    begun: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// The text each run's turn began on, in order. Owned.
    began_contents: std.ArrayList([]u8) = .empty,
    /// "agent work_id outcome output" per report, in arrival order. Owned.
    reports: std.ArrayList([]u8) = .empty,
    /// Each report's facts, in the same order.
    ends: std.ArrayList(child_state.EndFacts) = .empty,
    /// When set, each report is also posted to this worker, as `fx ask`'s sink does.
    worker: ?*worker_runtime.WorkerRuntime = null,

    fn deinit(self: *MailboxFixture) void {
        for (self.began_contents.items) |content| std.testing.allocator.free(content);
        self.began_contents.deinit(std.testing.allocator);
        for (self.reports.items) |line| std.testing.allocator.free(line);
        self.reports.deinit(std.testing.allocator);
        self.ends.deinit(std.testing.allocator);
    }

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn bind(raw: ?*anyopaque, turn: *execution.TurnContext, cancel: *std.atomic.Value(bool)) execution.ServiceError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.bind_honors_cancel and cancel.load(.seq_cst)) return error.Cancelled;
        if (self.bind_fails.load(.seq_cst)) return error.ProviderFailed;
        turn.hosted_worker = self.hosted orelse return error.ProviderFailed;
    }

    /// Blocks on the user as `asks` says, until the answer, or until the
    /// turn is cancelled or the worker stops.
    fn ask(self: *const MailboxFixture, worker: *worker_runtime.WorkerRuntime, content: []const u8) void {
        const alloc = std.testing.allocator;
        // Only a message that starts with "ask" does.
        if (!std.mem.startsWith(u8, content, "ask")) return;
        switch (self.asks) {
            .nothing => {},
            .permission => {
                var response = worker.requestPermissionBlocking(alloc, .{ .label = "Run it?" }) catch return;
                response.deinit();
            },
            .question => {
                const options = [_]types.QuestionOption{.{ .label = "Yes", .description = null }};
                const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};
                const answers = worker.requestQuestionBatchAnswerBlocking(alloc, &entries) catch return;
                for (answers orelse return) |answer| alloc.free(answer);
                alloc.free(answers.?);
            },
        }
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (fixture_run_hook) |hook| hook();
        if (cancel.load(.seq_cst)) _ = self.cancelled_at_start.fetchAdd(1, .seq_cst);
        // The app hands a hosted turn to the child's agent through `postAndWait`
        // (`src/core/app/app_agents_runtime.zig`), which withdraws a post whose
        // cancel is set before the main loop takes it, so no turn begins.
        if (turn.isHosted() and cancel.load(.seq_cst)) return error.Cancelled;
        const worker = turn.workerRuntime();
        // Counted once its turn has begun, so a test that waits for the run
        // can message it. A run that takes no steering is a turn past its
        // last step, as a model turn's final answer is: it processes with
        // steering closed, so a message waits for the next turn.
        const turn_id = self.runs.load(.seq_cst) + 1;
        const processing = worker.beginDirectProcessing(turn_id);
        defer if (processing) worker.finishProcessing();
        if (processing) {
            _ = self.begun.fetchAdd(1, .seq_cst);
            self.noteBegan(message.content);
        }
        if (processing and !self.steerable) {
            var boundary = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer boundary.deinit();
            _ = worker.takeSteeringBoundaryInto(std.testing.allocator, boundary.allocator(), turn_id, .finalizing) catch return error.ProviderFailed;
        }
        const run_number = self.runs.fetchAdd(1, .seq_cst) + 1;
        self.ask(worker, message.content);
        while (self.hold and !self.release.isSet() and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        if (self.linger and cancel.load(.seq_cst)) self.release.waitUncancelable(io_mod.getIo());
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (self.fail_first and run_number == 1) return error.ProviderFailed;
        if (turn.isHosted()) return .completed;
        const reply = if (self.empty_reply)
            std.testing.allocator.dupe(u8, "") catch return error.ProviderFailed
        else
            std.testing.allocator.print("DONE {s}", .{message.content}) catch return error.ProviderFailed;
        defer std.testing.allocator.free(reply);
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = reply,
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn noteBegan(self: *MailboxFixture, content: []const u8) void {
        const copy = std.testing.allocator.dupe(u8, content) catch return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.began_contents.append(std.testing.allocator, copy) catch std.testing.allocator.free(copy);
    }

    fn post(raw: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.refuse_reports) return error.AgentGone;
        const report = delivery.report;
        const line = if (report.dropped > 0)
            try std.testing.allocator.print("{s} {s} {s} {s} {s} dropped={d}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output, report.dropped })
        else
            try std.testing.allocator.print("{s} {s} {s} {s} {s}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output });
        errdefer std.testing.allocator.free(line);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.ends.ensureUnusedCapacity(std.testing.allocator, 1);
        try self.reports.append(std.testing.allocator, line);
        self.ends.appendAssumeCapacity(report.end);
        if (self.worker) |worker| {
            worker.postMail(std.testing.allocator, .{
                .prompt = try std.testing.allocator.dupe(u8, line),
                .images = &.{},
                .model = &.{},
                .api_key = &.{},
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
                .author = .child,
            }) catch return error.AgentGone;
        }
    }

    fn reportCount(self: *MailboxFixture) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.reports.items.len;
    }
};

/// A host whose children run on an agent of their own, as the app's do.
fn hostedMailboxRuntime(alloc: Allocator, fixture: *MailboxFixture, parent: *child_state.TestParent) !*Runtime {
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = MailboxFixture.resolve }, .{ .context = fixture, .bind_fn = MailboxFixture.bind, .run_fn = MailboxFixture.run });
    runtime.report_sink = .{ .context = fixture, .post_fn = MailboxFixture.post };
    return runtime;
}

fn mailboxRuntime(alloc: Allocator, fixture: *MailboxFixture, parent: *child_state.TestParent) !*Runtime {
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = MailboxFixture.resolve }, .{ .context = fixture, .run_fn = MailboxFixture.run });
    runtime.report_sink = .{ .context = fixture, .post_fn = MailboxFixture.post };
    return runtime;
}

/// One call of the subagent tool from the root, as its model would make it.
fn callTool(runtime: *Runtime, arena: Allocator, input: model_contract.RequestInput, invocation_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ![]const u8 {
    var request = try model_contract.validateRequest(std.testing.allocator, input);
    defer request.deinit(std.testing.allocator);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = runtime.root_id,
        .invocation_id = invocation_id,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .caller_worker = worker,
    });
    return result.body;
}

fn waitForRuns(fixture: *MailboxFixture, count: usize) !void {
    for (0..5000) |_| {
        if (fixture.runs.load(.seq_cst) >= count) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "a message returns at once, and the subagent's report reaches its parent on its own" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "Sent to reviewer") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const line = fixture.reports.items[0];
    // It points back at the call that sent the work.
    try std.testing.expect(std.mem.startsWith(u8, line, "reviewer call-1 "));
    try std.testing.expect(std.mem.find(u8, line, " completed DONE check") != null);
    // The finish line records that the report was owed.
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.last_report_owed);

    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: idle, last work completed, reports final") != null);
}

test "a work that saves an empty reply reports that it ended without one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .empty_reply = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], " completed The subagent ended its turn without a reply."));
}

test "a message to a busy subagent waits and runs as its next work, in order" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    const status = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: working, 1 waiting message") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], "DONE first"));
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "reviewer call-1 "));
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], "DONE second"));
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[1], "reviewer call-2 "));
    // Nothing is left remembered once both works ended.
    try std.testing.expectEqual(@as(usize, 0), runtime.work_calls.items.len);
}

test "the roster names the open subagents, and the working ones while they work" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    try std.testing.expect(try runtime.rosterNames(alloc, false) == null);
    try std.testing.expect(try runtime.rosterNames(alloc, true) == null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "builder", .message = "first" } }, "call-2", null);
    try waitForRuns(&fixture, 2);
    {
        const working = (try runtime.rosterNames(alloc, true)).?;
        defer alloc.free(working);
        try std.testing.expectEqualStrings("reviewer, builder", working);
    }
    // A status that names no agent lists the ones it reports on; one about
    // a single subagent lists none.
    const status_all = try callTool(runtime, arena, .{ .status = .{} }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, status_all, "\"subagents\":[\"reviewer\",\"builder\"]") != null);
    const status_one = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, status_one, "\"subagents\"") == null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expect(try runtime.rosterNames(alloc, true) == null);
    const open = (try runtime.rosterNames(alloc, false)).?;
    defer alloc.free(open);
    try std.testing.expectEqualStrings("reviewer, builder", open);
}

test "a message past a busy subagent's full queue is refused to its sender" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-0", null);
    try waitForRuns(&fixture, 1);
    for (0..Runtime.max_pending_per_child) |index| {
        const call_id = try arena.print("call-{d}", .{index + 1});
        const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "more" } }, call_id, null);
        try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    }
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "one too many" } }, "call-full", null);
    try std.testing.expect(std.mem.find(u8, refused, "\"error_code\":\"queue_full\"") != null);
    // The refused message was never remembered as work.
    for (runtime.work_calls.items) |entry| try std.testing.expect(!std.mem.eql(u8, entry.call_id, "call-full"));

    _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-stop", null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
}

fn reviewerId(runtime: *Runtime, arena: Allocator) ![]const u8 {
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    return try arena.dupe(u8, registry.findPersistent("reviewer").?.id);
}

test "a user's stop drops the parent's messages waiting for a subagent, and its report says how many" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "next" } }, "call-2", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after that" } }, "call-3", null);
    const child_id = try reviewerId(runtime, arena);
    // Esc on its screen: the waiting messages go first, then the turn.
    runtime.userStopped(child_id, 0);
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    // Neither waiting message ran, and the cancelled work's report counts them.
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const line = fixture.reports.items[0];
    try std.testing.expect(std.mem.startsWith(u8, line, "reviewer call-1 "));
    try std.testing.expect(std.mem.find(u8, line, " cancelled ") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, " dropped=2"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
    // It says who stopped it, so the parent needn't guess.
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_stop }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, line, "The user stopped its turn before it finished.") != null);
}

test "a work fx's quit cancels says so in its report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    runtime.noteQuitting();
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " cancelled fx quit before it finished.") != null);
    // The log keeps the cause for a report posted after a restart.
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, registry.findPersistent("reviewer").?.last_end);
}

test "a user's stop of a work that owes no report tells the parent of its dropped messages" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "never" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "next" } }, "call-2", null);
    const child_id = try reviewerId(runtime, arena);
    runtime.userStopped(child_id, 0);
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    // A notice: no work to take, so no call and no work id.
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqualStrings(
        "reviewer   cancelled The user stopped it, and 1 of your messages waiting for it were dropped. dropped=1",
        fixture.reports.items[0],
    );
}

test "a turn the user starts on an idle subagent is a work, and reports its reply under every_turn" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);

    try std.testing.expectEqual(@as(?reports.StartedBy, null), runtime.turnStartedBy(child_id));
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    // A message the child sends now comes from the user's turn.
    try std.testing.expectEqual(@as(?reports.StartedBy, .user), runtime.turnStartedBy(child_id));
    {
        var lock = runtime.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try runtime.managed.state_store.load(arena);
        const child = registry.findPersistent("reviewer").?;
        try std.testing.expectEqual(child_state.Phase.running, child.phase);
        try std.testing.expectEqualStrings(work_id, child.active.?.id);
    }
    // A second turn can't open while this one is open.
    try std.testing.expect(runtime.beginUserWork(alloc, child_id, null) == null);
    runtime.endUserWork(child_id, work_id, .completed, "USER_TURN_REPLY");
    try std.testing.expectEqual(@as(?reports.StartedBy, null), runtime.turnStartedBy(child_id));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    const line = fixture.reports.items[1];
    try std.testing.expect(std.mem.find(u8, line, work_id) != null);
    try std.testing.expect(std.mem.endsWith(u8, line, " completed USER_TURN_REPLY"));
    try std.testing.expect(!runtime.anyWorking());
    // The parent learns the user started it, not the parent.
    try std.testing.expectEqual(reports.StartedBy.parent, fixture.ends.items[0].started_by);
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .user }, fixture.ends.items[1]);
}

test "a parent's message that joined a turn that failed runs as the child's next work" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true, .steerable = true, .fail_first = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);

    // The failed work reports, and the message it never took runs after it.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " failed ") != null);
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed DONE also this"));
}

test "the parent's stop drops a message that joined the turn it stops" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true, .steerable = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
}

test "the parent's stop ends a turn the user started on the child's screen, which owes no report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);
    // The user's turn runs on the child's own worker.
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    try std.testing.expect(worker.beginDirectProcessing(5));
    const work_id = runtime.beginUserWork(alloc, child_id, &worker).?;
    defer alloc.free(work_id);

    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended") != null);
    try std.testing.expect(worker.isCancelRequested());
    runtime.endUserWork(child_id, work_id, .cancelled, "");
    // Under every_turn the user's turn would report, but the parent's own stop answers it.
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(!runtime.anyWorking());
}

test "a turn the child's own child woke while the parent's work ended opens as that work ends, and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    // The parent's work still holds the child, so the woken turn's work waits.
    const work_id = runtime.beginTurnWork(alloc, child_id, .child, null).?;
    defer alloc.free(work_id);
    try std.testing.expect(runtime.beginTurnWork(alloc, child_id, .child, null) == null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after" } }, "call-2", null);
    fixture.release.set(io_mod.getIo());
    try waitForActiveWork(runtime, arena, child_id, work_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "WOKEN_REPLY");
    try waitUntilQuiet(runtime);
    // The parent's work, the woken turn, then the message that waited for it.
    try std.testing.expectEqual(@as(usize, 3), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed WOKEN_REPLY"));
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .child }, fixture.ends.items[1]);
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[2], " completed DONE after"));
}

test "a woken turn that ends before its work could open still finishes and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginTurnWork(alloc, child_id, .user, null).?;
    defer alloc.free(work_id);
    // The user's turn fails before the parent's work lets go of the child.
    runtime.endUserWork(child_id, work_id, .failed, "");
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], work_id) != null);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a user's turn under the final rule reports only when it fails" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const done = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(done);
    runtime.endUserWork(child_id, done, .completed, "fine");
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const failed = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(failed);
    runtime.endUserWork(child_id, failed, .failed, "");
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a parent's message while the user's turn runs waits for it, then starts" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "");
    try waitForRuns(&fixture, 2);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "DONE after the user") != null);
}

test "messages waiting for a busy subagent are taken into its next turn as one work" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "third" } }, "call-3", null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);

    // Two works, not three: the second took in the third.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "DONE second\n\nthird") != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.work_calls.items.len);
}

test "a work that ends after its tree closed owes no report and posts none" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    runtime.closeTree();
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    try std.testing.expect(!registry.children[0].last_report_owed);
}

test "a closed tree's teardown ends a running work cancelled, so a reopen has no report to post" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    runtime.closeTree();
    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    // The finish owes nothing, so it is saved without data. Only a cancelled
    // one reads that way on reopen: an interrupted one reads as crash repair,
    // which owes a report.
    const lines = try parent.parent.reportLines(arena);
    var finishes: usize = 0;
    for (lines) |line| switch (line) {
        .finished => |finished| {
            finishes += 1;
            try std.testing.expectEqual(session_adapter.ChildOutcome.cancelled, finished.outcome);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), finishes);
    try std.testing.expectEqual(@as(usize, 0), (try reports.pendingReports(arena, lines)).len);
}

test "a quit's teardown ends a running work interrupted, and a reopen posts its report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " interrupted fx stopped before it finished.") != null);
    const lines = try parent.parent.reportLines(arena);
    const pending = try reports.pendingReports(arena, lines);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(child_state.Outcome.interrupted, pending[0].outcome);
}

test "stop ends a subagent's turn without a report and drops what waits for it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    const child = registry.findPersistent("reviewer").?;
    try std.testing.expectEqual(child_state.Outcome.cancelled, child.last_outcome.?);
    try std.testing.expect(!child.last_report_owed);
    // The app reads it from the list, to say the subagent was stopped.
    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expectEqual(@as(?child_state.Outcome, .cancelled), listing[0].last_outcome);
    const again = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, again, "reviewer was not working.") != null);
    const missing = try callTool(runtime, arena, .{ .stop = .{ .agent = "nobody" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, missing, "child_unavailable") != null);
}

test "trace children show each subagent's work phase, last outcome, and closing" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    {
        const traced = try runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 0), traced.len);
    }
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    {
        const traced = try runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 1), traced.len);
        try std.testing.expectEqualStrings(child_id, traced[0].id);
        try std.testing.expectEqual(child_state.Phase.running, traced[0].phase);
        try std.testing.expect(traced[0].last_outcome == null);
        try std.testing.expectEqualStrings("", traced[0].last_failure);
        try std.testing.expect(!traced[0].closing);
    }
    _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-2", null);
    try waitUntilQuiet(runtime);
    {
        const traced = try runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 1), traced.len);
        try std.testing.expectEqual(child_state.Phase.idle, traced[0].phase);
        try std.testing.expectEqual(child_state.Outcome.cancelled, traced[0].last_outcome.?);
        try std.testing.expect(!traced[0].closing);
    }
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-3", null);
    try waitForRuns(&fixture, 2);
    _ = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-4", null);
    {
        // The list drops a closing subagent at once; the trace keeps it,
        // marked, until it is gone from the registry.
        const traced = try runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expect(traced.len <= 1);
        if (traced.len == 1) try std.testing.expect(traced[0].closing);
    }
    try waitUntilQuiet(runtime);
    try waitUntilClosed(runtime, child_id);
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    {
        const traced = try runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 0), traced.len);
    }
}

/// Holds the thread that settles a close just before it writes the close,
/// until a test lets it go, so the test can look at the host while the close
/// is not written yet (`close_test_controls`).
const CloseHold = struct {
    var settles = std.atomic.Value(u32).init(0);
    var reached: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;

    fn arm(write_error: ?anyerror) void {
        settles.store(0, .seq_cst);
        reached = .unset;
        go = .unset;
        close_test_controls.test_write_error = write_error;
        close_test_controls.test_hold = hold;
    }

    /// Lets a held thread go, and stops holding.
    fn disarm() void {
        close_test_controls.test_hold = null;
        close_test_controls.test_write_error = null;
        go.set(io_mod.getIo());
    }

    /// Holds the first close's write; a later close's goes straight on.
    fn hold(_: []const u8) void {
        if (settles.fetchAdd(1, .seq_cst) != 0) return;
        reached.set(io_mod.getIo());
        while (!go.isSet()) io_mod.sleep(std.time.ns_per_ms);
    }
};

/// A working subagent `reviewer` that its parent has closed, with its close
/// held just before the write: the child is closing and the registry still
/// holds it. Initialized in place, since the host points into it.
const ClosingSubagent = struct {
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    fixture: MailboxFixture,
    runtime: *Runtime,
    child_id: []const u8,
    /// Set by a test that leaves a thread of the host blocked for good: the
    /// host is not torn down, since that would wait for the thread.
    abandoned: bool = false,

    fn init(self: *ClosingSubagent, alloc: Allocator, write_error: ?anyerror) !void {
        self.* = .{ .arena_state = .init(alloc), .parent = undefined, .fixture = .{ .hold = true }, .runtime = undefined, .child_id = undefined };
        errdefer self.arena_state.deinit();
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        self.runtime = try mailboxRuntime(alloc, &self.fixture, &self.parent);
        errdefer self.runtime.deinit();
        const arena = self.arena_state.allocator();
        _ = try callTool(self.runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
        try waitForRuns(&self.fixture, 1);
        self.child_id = try reviewerId(self.runtime, arena);
        CloseHold.arm(write_error);
        errdefer CloseHold.disarm();
        _ = try callTool(self.runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-2", null);
        if (!testing_event.setInTime(&CloseHold.reached)) return error.Timeout;
    }

    fn deinit(self: *ClosingSubagent) void {
        CloseHold.disarm();
        if (!self.abandoned) {
            self.runtime.deinit();
            self.fixture.deinit();
            self.parent.deinit();
        }
        self.arena_state.deinit();
    }

    /// Lets the held close go on, and waits until the registry has dropped
    /// the child.
    fn letCloseGo(self: *ClosingSubagent) !void {
        CloseHold.go.set(io_mod.getIo());
        try waitUntilClosed(self.runtime, self.child_id);
    }
};

/// One message to `reviewer` made on a thread of its own, so a call that
/// blocks fails its test instead of hanging it.
const MessageToClosing = struct {
    runtime: *Runtime,
    answer: ?[]u8 = null,
    returned: std.Io.Event = .unset,

    fn run(self: *MessageToClosing) void {
        defer self.returned.set(io_mod.getIo());
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const body = callTool(self.runtime, arena_state.allocator(), .{ .message = .{ .agent = "reviewer", .message = "after the close" } }, "call-3", null) catch |err| {
            self.answer = std.testing.allocator.print("error {s}", .{@errorName(err)}) catch null;
            return;
        };
        self.answer = std.testing.allocator.dupe(u8, body) catch null;
    }
};

test "a test build holds and fails a close's write only through its hooks" {
    // Without a hook a hold returns at once and no write fails.
    close_test_controls.holdWrite("child");
    try std.testing.expect(close_test_controls.failedWrite() == null);
}

test "a subagent whose close is not written yet stays out of the list and marked in the trace" {
    const alloc = std.testing.allocator;
    var closing: ClosingSubagent = undefined;
    try closing.init(alloc, null);
    defer closing.deinit();

    // The work has ended and the registry still holds the child; the list
    // and the trace say it is closing, as they did while its work ended.
    // The app has taken the child to drop its agent, and its next sync of the
    // agent list adds an agent for every child this lists
    // (`syncChildList` in `src/core/app/app_agents_runtime.zig`): a child
    // listed now would come back as an agent that no close drops again.
    const taken = try closing.runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    {
        const listing = try closing.runtime.listChildren(alloc);
        defer Runtime.freeChildListing(alloc, listing);
        try std.testing.expectEqual(@as(usize, 0), listing.len);
    }
    {
        const traced = try closing.runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 1), traced.len);
        try std.testing.expectEqualStrings(closing.child_id, traced[0].id);
        try std.testing.expect(traced[0].closing);
    }
    try closing.letCloseGo();
    {
        const traced = try closing.runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 0), traced.len);
    }
}

test "a message to a subagent whose close is not written yet is refused with child_closing and does not block" {
    const alloc = std.testing.allocator;
    var closing: ClosingSubagent = undefined;
    try closing.init(alloc, null);
    defer closing.deinit();

    var message = MessageToClosing{ .runtime = closing.runtime };
    const thread = try std.Thread.spawn(.{}, MessageToClosing.run, .{&message});
    if (!testing_event.setInTime(&message.returned)) {
        // The call holds the host's admission lock and waits for the slot,
        // which waits for that lock: neither goes on, so the host is left.
        closing.abandoned = true;
        thread.detach();
        return error.MessageBlocked;
    }
    thread.join();
    defer if (message.answer) |text| alloc.free(text);
    try std.testing.expect(message.answer != null);
    try std.testing.expect(std.mem.find(u8, message.answer.?, "child_closing") != null);
    // No turn started for the closed subagent.
    try std.testing.expectEqual(@as(usize, 1), closing.fixture.runs.load(.seq_cst));
    try closing.letCloseGo();
}

test "a second close while the first is not written yet answers that it is closing, and the close is written once" {
    const alloc = std.testing.allocator;
    var closing: ClosingSubagent = undefined;
    try closing.init(alloc, null);
    defer closing.deinit();

    const second = (try closing.runtime.closeChild(closing.child_id, .parent)).?;
    // It ended nothing and dropped nothing: the first close did.
    try std.testing.expect(!second.stopped);
    try std.testing.expectEqual(@as(usize, 0), second.dropped);
    try closing.letCloseGo();
    try std.testing.expectEqual(@as(u32, 1), CloseHold.settles.load(.seq_cst));
    // The app drops the agent once.
    const taken = try closing.runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings(closing.child_id, taken[0]);
}

test "a settle of a close that is being written leaves the write to the thread that has it" {
    const alloc = std.testing.allocator;
    var closing: ClosingSubagent = undefined;
    try closing.init(alloc, null);
    defer closing.deinit();

    // Asked again while the first writes, it answers and writes nothing.
    try std.testing.expect(closing.runtime.settleClose(closing.child_id));
    try std.testing.expectEqual(@as(u32, 1), CloseHold.settles.load(.seq_cst));
    {
        var lock = closing.runtime.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try closing.runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expect(registry.findById(closing.child_id) != null);
    }
    try closing.letCloseGo();
}

test "a close whose write fails keeps the subagent closing until then, and lists it again" {
    const alloc = std.testing.allocator;
    var closing: ClosingSubagent = undefined;
    try closing.init(alloc, error.ChildBusy);
    defer closing.deinit();

    {
        const listing = try closing.runtime.listChildren(alloc);
        defer Runtime.freeChildListing(alloc, listing);
        try std.testing.expectEqual(@as(usize, 0), listing.len);
    }
    CloseHold.go.set(io_mod.getIo());
    // The write failed: the child is no longer closing, and the registry
    // still holds it.
    var listed: usize = 0;
    for (0..5000) |_| {
        const listing = try closing.runtime.listChildren(alloc);
        listed = listing.len;
        Runtime.freeChildListing(alloc, listing);
        if (listed == 1) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), listed);
    {
        const traced = try closing.runtime.traceChildren(alloc);
        defer Runtime.freeTraceChildren(alloc, traced);
        try std.testing.expectEqual(@as(usize, 1), traced.len);
        try std.testing.expect(!traced[0].closing);
    }
    // The app keeps the agent: nothing of this child is left to drop.
    try std.testing.expect(!closing.runtime.hasClosed());
    try std.testing.expectEqual(@as(usize, 0), (try closing.runtime.takeClosed(alloc)).len);
    // A later close goes through.
    close_test_controls.test_write_error = null;
    try std.testing.expect((try closing.runtime.closeChild(closing.child_id, .parent)) != null);
    try waitUntilClosed(closing.runtime, closing.child_id);
}

test "the parent's close ends a working subagent's turn without a report and removes it for good" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    const child_id = try reviewerId(runtime, arena);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer, ending its turn. The message waiting for it was dropped. A later message to reviewer starts a new one.") != null);
    // Closing, it is gone from the list already.
    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 0), listing.len);
    try waitUntilQuiet(runtime);
    try waitUntilClosed(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    {
        var registry = try runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expect(registry.findById(child_id) == null);
    }
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, status, "No subagents yet.") != null);
    // The app takes the child once, to drop its agent.
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings(child_id, taken[0]);
    try std.testing.expectEqual(@as(usize, 0), (try runtime.takeClosed(alloc)).len);
    const missing = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, missing, "child_unavailable") != null);
}

test "the user's close of a working subagent reports that the user closed it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(child_id, .user)).?;
    try std.testing.expect(closed.stopped);
    try waitUntilQuiet(runtime);
    try waitUntilClosed(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_close }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], "The user closed it before it finished.") != null);
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "reviewer "));
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);
    // Gone from the registry, it keeps its name for a report owed from
    // before its close, as one posted after a restart is.
    try std.testing.expectEqualStrings("reviewer", try runtime.childName(arena, child_id));
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "the user's close tells main how many of its messages waiting for the subagent it dropped" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "waiting" } }, "call-2", null);
    const child_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(child_id, .user)).?;
    try std.testing.expectEqual(@as(usize, 1), closed.dropped);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const report = fixture.reports.items[0];
    try std.testing.expect(std.mem.find(u8, report, "The user closed it before it finished.") != null);
    try std.testing.expect(std.mem.endsWith(u8, report, " dropped=1"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "an early-ended work names each file it changed once, without reads or failed changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = struct {
        fn make(path: []const u8, action: types.FileEvidenceAction, status: types.PersistedToolStatus) types.FileEvidence {
            return .{ .path = @constCast(path), .tool_call_id = @constCast("call"), .tool_name = @constCast("edit_file"), .action = action, .status = status };
        }
    }.make;
    try std.testing.expect((try listChangedFiles(a, &.{file("a.zig", .read, .success)})) == null);
    const listed = (try listChangedFiles(a, &.{
        file("a.zig", .read, .success),
        file("b.zig", .edit, .success),
        file("c.zig", .write, .failure),
        file("b.zig", .write, .success),
        file("d.zig", .write, .success),
    })).?;
    try std.testing.expectEqualStrings("b.zig, d.zig", listed);
}

test "after the user closes a subagent, main's status and the message that starts a new one under its name say so, once" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "tester", .message = "first" } }, "call-2", null);
    try waitUntilQuiet(runtime);
    _ = (try runtime.closeChild(try reviewerId(runtime, arena), .user)).?;
    // Main's own close is no news to main.
    {
        var registry = try runtime.managed.state_store.load(arena);
        _ = (try runtime.closeChild(registry.findPersistent("tester").?.id, .parent)).?;
    }
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: closed by the user") != null);
    try std.testing.expect(std.mem.find(u8, status, "tester") == null);
    const sent = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, sent, "The user closed the earlier reviewer, so this one starts with no history.") != null);
    try waitUntilQuiet(runtime);
    const later = try callTool(runtime, arena, .{ .status = .{} }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, later, "closed by the user") == null);
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
}

/// Holds a subagent's slot after its work ended and the host's end hook
/// returned, until a test lets it go, so the test can send a stop or a close
/// into the gap before the slot goes on (`publish_test_controls`).
const PublishHold = struct {
    var holds = std.atomic.Value(u32).init(0);
    var reached: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;

    fn arm() void {
        holds.store(0, .seq_cst);
        reached = .unset;
        go = .unset;
        publish_test_controls.test_hold = hold;
    }

    /// Lets a held slot go.
    fn release() void {
        go.set(io_mod.getIo());
    }

    /// Stops holding. Call it once no slot thread runs any more, since a
    /// slot reads the hook when each of its works ends.
    fn clear() void {
        publish_test_controls.test_hold = null;
    }

    /// Holds the first end; a later one goes straight on.
    fn hold(_: []const u8) void {
        if (holds.fetchAdd(1, .seq_cst) != 0) return;
        reached.set(io_mod.getIo());
        while (!go.isSet()) io_mod.sleep(std.time.ns_per_ms);
    }
};

/// A subagent `reviewer` whose first work has ended, with its slot held
/// before it goes on. With `next_waits`, a second message waited for it, so
/// the host chose that message's turn as the slot's next work; otherwise the
/// child is idle. With `hosted`, the turns run on a child agent's own worker,
/// as the app's do. Initialized in place, since the host points into it.
const EndedSubagent = struct {
    alloc: Allocator,
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    hosted_worker: worker_runtime.WorkerRuntime,
    fixture: MailboxFixture,
    runtime: *Runtime,
    child_id: []const u8,

    fn init(self: *EndedSubagent, alloc: Allocator, next_waits: bool, hosted: bool) !void {
        self.* = .{
            .alloc = alloc,
            .arena_state = .init(alloc),
            .parent = undefined,
            .hosted_worker = .{},
            .fixture = .{ .hold = next_waits, .hosted = if (hosted) &self.hosted_worker else null },
            .runtime = undefined,
            .child_id = undefined,
        };
        errdefer self.arena_state.deinit();
        errdefer self.hosted_worker.deinit(alloc);
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        PublishHold.arm();
        // Undone in reverse: the slot is let go, its threads end with the
        // runtime, and only then is the hook cleared.
        errdefer PublishHold.clear();
        self.runtime = if (hosted)
            try hostedMailboxRuntime(alloc, &self.fixture, &self.parent)
        else
            try mailboxRuntime(alloc, &self.fixture, &self.parent);
        errdefer self.runtime.deinit();
        errdefer PublishHold.release();
        const arena = self.arena_state.allocator();
        _ = try callTool(self.runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
        if (next_waits) {
            try waitForRuns(&self.fixture, 1);
            _ = try callTool(self.runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
            self.fixture.release.set(io_mod.getIo());
        }
        if (!testing_event.setInTime(&PublishHold.reached)) return error.Timeout;
        self.child_id = try reviewerId(self.runtime, arena);
        if (!next_waits) try waitUntilQuiet(self.runtime);
    }

    fn deinit(self: *EndedSubagent) void {
        PublishHold.release();
        self.runtime.deinit();
        PublishHold.clear();
        self.fixture.deinit();
        self.hosted_worker.deinit(self.alloc);
        self.parent.deinit();
        self.arena_state.deinit();
    }

    fn registryHolds(self: *EndedSubagent) !bool {
        var registry = try self.runtime.managed.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        return registry.findById(self.child_id) != null;
    }
};

test "a stop right after a subagent's work ended finds it not working" {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, false, false);
    defer ended.deinit();

    const answer = try callTool(ended.runtime, ended.arena_state.allocator(), .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, answer, "reviewer was not working.") != null);
    try std.testing.expect(std.mem.find(u8, answer, "Stopped") == null);
    // Nothing else changed: its report was posted once, and it is still open.
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
    try std.testing.expect(try ended.registryHolds());
}

test "a close right after a subagent's work ended closes it as an idle one" {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, false, false);
    defer ended.deinit();

    const answer = try callTool(ended.runtime, ended.arena_state.allocator(), .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, answer, "Closed reviewer. A later message to reviewer starts a new one.") != null);
    try std.testing.expect(std.mem.find(u8, answer, "ending its turn") == null);
    try std.testing.expect(!try ended.registryHolds());
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
    const taken = try ended.runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "the user's close right after a subagent's work ended ends no turn" {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, false, false);
    defer ended.deinit();

    const closed = (try ended.runtime.closeChild(ended.child_id, .user)).?;
    try std.testing.expect(!closed.stopped);
    try std.testing.expectEqual(@as(usize, 0), closed.dropped);
    try std.testing.expect(!try ended.registryHolds());
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
}

test "a stop right after a subagent's work ended stops the turn the user began on its screen" {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, false, false);
    defer ended.deinit();

    // The user's turn runs on the child's own worker.
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    try std.testing.expect(worker.beginDirectProcessing(5));
    const work_id = ended.runtime.beginUserWork(alloc, ended.child_id, &worker).?;
    defer alloc.free(work_id);

    const answer = try callTool(ended.runtime, ended.arena_state.allocator(), .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, answer, "Stopped reviewer: its turn ended") != null);
    try std.testing.expect(worker.isCancelRequested());
    ended.runtime.endUserWork(ended.child_id, work_id, .cancelled, "");
    // The parent's own stop answers that turn, so it owes no report.
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
}

fn expectStopStopsNextWork(hosted: bool) !void {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, true, hosted);
    defer ended.deinit();

    const answer = try callTool(ended.runtime, ended.arena_state.allocator(), .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    // The stop drops the message the next work carries, and says so.
    try std.testing.expect(std.mem.find(u8, answer, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
    PublishHold.release();
    try waitUntilQuiet(ended.runtime);
    // The second turn began stopped: its run saw the cancel at its start. It
    // owes no report, and the log says it was cancelled.
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.cancelled_at_start.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
    var registry = try ended.runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(child_state.Outcome.cancelled, registry.findById(ended.child_id).?.last_outcome.?);
}

fn expectCloseEndsNextWork(hosted: bool) !void {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, true, hosted);
    defer ended.deinit();

    const answer = try callTool(ended.runtime, ended.arena_state.allocator(), .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    // Its next turn was already chosen, so the close ends that turn.
    try std.testing.expect(std.mem.find(u8, answer, "Closed reviewer, ending its turn.") != null);
    PublishHold.release();
    try waitUntilQuiet(ended.runtime);
    try waitUntilClosed(ended.runtime, ended.child_id);
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.cancelled_at_start.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.reportCount());
    const taken = try ended.runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "a stop right after a subagent's work ended stops the turn its waiting message starts" {
    try expectStopStopsNextWork(false);
}

test "a stop right after a subagent's work ended stops the turn its waiting message starts, on a hosted subagent" {
    try expectStopStopsNextWork(true);
}

test "a close right after a subagent's work ended runs no turn for its waiting message and owes no report" {
    try expectCloseEndsNextWork(false);
}

test "a close right after a subagent's work ended runs no turn for its waiting message, on a hosted subagent" {
    try expectCloseEndsNextWork(true);
}

test "the user's close right after a subagent's work ended ends the turn its waiting message starts, and says so" {
    const alloc = std.testing.allocator;
    var ended: EndedSubagent = undefined;
    try ended.init(alloc, true, false);
    defer ended.deinit();

    const closed = (try ended.runtime.closeChild(ended.child_id, .user)).?;
    try std.testing.expect(closed.stopped);
    PublishHold.release();
    try waitUntilQuiet(ended.runtime);
    try waitUntilClosed(ended.runtime, ended.child_id);
    try std.testing.expectEqual(@as(usize, 1), ended.fixture.cancelled_at_start.load(.seq_cst));
    // What a user's close of a working subagent reports, and nothing of the
    // turn's own work.
    try std.testing.expectEqual(@as(usize, 2), ended.fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_close }, ended.fixture.ends.items[1]);
    try std.testing.expect(std.mem.find(u8, ended.fixture.reports.items[1], "The user closed it before it finished.") != null);
    try std.testing.expect(std.mem.find(u8, ended.fixture.reports.items[1], "DONE second") == null);
}

test "an idle subagent closes at once, and its name then starts a new one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const old_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(old_id, .parent)).?;
    try std.testing.expect(!closed.stopped);
    try std.testing.expectEqual(@as(usize, 0), closed.dropped);
    {
        var registry = try runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expect(registry.findById(old_id) == null);
    }
    try std.testing.expect((try runtime.closeChild(old_id, .parent)) == null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-2", null);
    try waitUntilQuiet(runtime);
    const new_id = try reviewerId(runtime, arena);
    try std.testing.expect(!std.mem.eql(u8, old_id, new_id));
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "a new subagent starts in the main profile unless its message names one, and the list says which" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "look" } }, "call-1", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "copy", .profile = "agent" } }, "call-2", null);
    try waitUntilQuiet(runtime);
    // A later message names no profile and changes none.
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "again" } }, "call-3", null);
    try waitUntilQuiet(runtime);

    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 2), listing.len);
    try std.testing.expectEqualStrings("reviewer", listing[0].name);
    try std.testing.expectEqualStrings("main", listing[0].profile);
    try std.testing.expectEqualStrings("copier", listing[1].name);
    try std.testing.expectEqualStrings("agent", listing[1].profile);

    // A child that started in no profile has nothing of one to keep, and one in
    // a profile keeps what it set, which for fx's own `agent` is nothing but
    // where it came from.
    var registry = try parent.stateStore().load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.started_with == null);
    try std.testing.expectEqual(profiles.Source.builtin, registry.findPersistent("copier").?.started_with.?.source);
}

test "a subagent's profile loads from its session's workspace, not the directory the process runs in" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    // The session's workspace is the test parent's folder, and the profile is
    // only there: the process runs in the repository checkout, which has none.
    const io = io_mod.getIo();
    try parent.tmp.dir.createDirPath(io, ".fx/agents/session-reviewer");
    var settings = try parent.tmp.dir.createFile(io, ".fx/agents/session-reviewer/profile.json", .{});
    defer settings.close(io);
    try settings.writeStreamingAll(io, "{\"description\": \"Reads the session workspace\", \"tools\": [\"read_file\"]}");
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const sent = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "look", .profile = "session-reviewer" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, sent, "profile_unavailable") == null);
    try waitUntilQuiet(runtime);
    var registry = try parent.stateStore().load(alloc);
    defer registry.deinit(alloc);
    const started = registry.findPersistent("reviewer").?.started_with.?;
    try std.testing.expectEqual(profiles.Source.project, started.source);
    try std.testing.expectEqual(@as(usize, 1), started.tools.?.len);
    try std.testing.expectEqualStrings("read_file", started.tools.?[0]);

    // A child saved with only its profile's name loads it from the same place.
    const reloaded = try runtime.profile_cache.?.get("name-only-child", "session-reviewer", null);
    try std.testing.expectEqualStrings("read_file", reloaded.tools.?[0]);
}

test "a new subagent saves what its profile set, unless that would not fit in a spawn line" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var first = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-1"), .message = try alloc.dupe(u8, "look"), .permission_mode = .ask, .created_at_ms = 1 };
    defer first.deinit(alloc);
    try registry.appendPersistent(alloc, "kid-fits", "fits", "", first);
    try registry.setProfile(alloc, "kid-fits", "reviewer");
    try Runtime.recordStartedWith(alloc, &registry, "kid-fits", "reviewer", .{ .source = .home, .permission_mode = .auto, .tools = &.{ "read_file", "!shell" }, .mcp_servers = &.{"github"} });
    const kept = registry.findById("kid-fits").?.started_with.?;
    try std.testing.expectEqual(types.PermissionMode.auto, kept.permission_mode.?);
    try std.testing.expectEqual(@as(usize, 2), kept.tools.?.len);

    // Forty names of 90 bytes do not fit. The child saves none and reads its
    // profile by name, as a child from before this did, and a profile that
    // works today still starts a subagent.
    var second = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-2"), .message = try alloc.dupe(u8, "look"), .permission_mode = .ask, .created_at_ms = 1 };
    defer second.deinit(alloc);
    try registry.appendPersistent(alloc, "kid-big", "big", "", second);
    try registry.setProfile(alloc, "kid-big", "wide");
    const text_utils = @import("../shared/text_utils.zig");
    var names: [40][]const u8 = undefined;
    for (&names, 0..) |*slot, index| slot.* = try alloc.print("{s}{d}", .{ text_utils.repeat("t", 90), index });
    defer for (names) |name| alloc.free(name);
    try Runtime.recordStartedWith(alloc, &registry, "kid-big", "wide", .{ .source = .home, .tools = &names });
    try std.testing.expect(registry.findById("kid-big").?.started_with == null);
    try std.testing.expectEqualStrings("wide", registry.findById("kid-big").?.profile.?);
}

test "wait returns at once when nothing works, and when a report arrives" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .hold = true, .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const quiet = try callTool(runtime, arena, .wait, "call-1", &worker);
    try std.testing.expect(std.mem.find(u8, quiet, "nothing more will arrive") != null);
    try std.testing.expect(std.mem.find(u8, quiet, "\"subagents\"") == null);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-2", &worker);
    try waitForRuns(&fixture, 1);
    const Releaser = struct {
        fn run(target: *MailboxFixture) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            target.release.set(io_mod.getIo());
        }
    };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&fixture});
    defer releaser.join();
    const woken = try callTool(runtime, arena, .wait, "call-3", &worker);
    try std.testing.expect(std.mem.find(u8, woken, "A report or message arrived") != null);
    // The worker runs no turn the mail could join, so it starts the next.
    try std.testing.expect(std.mem.find(u8, woken, "It starts your next turn once this one ends, so end your turn to read it.") != null);
    // It names the subagent that was working when it began.
    try std.testing.expect(std.mem.find(u8, woken, "\"subagents\":[\"reviewer\"]") != null);
    try std.testing.expectEqual(@as(usize, 1), worker.queuedPromptCount());
    const queued = worker.takeQueuedPrompt(alloc).?;
    defer worker_runtime.freeQueuedPrompt(alloc, queued);
    try std.testing.expectEqual(types.MessageAuthor.child, queued.author);
}

test "a subagent that reports never stays quiet when its work completes" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "quiet", .message = "go", .report = "never" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "quiet: idle, last work completed, reports never") != null);
}

/// Holds the host in the gap where it has told the owner a work ended and
/// has not yet cleared the child's busy flag (`end_test_controls.zig`).
const SettleGap = struct {
    var entered: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;

    fn arm() void {
        entered = .unset;
        go = .unset;
        end_test_controls.test_settle_hold = hold;
    }

    fn disarm() void {
        end_test_controls.test_settle_hold = null;
    }

    fn hold(_: []const u8) void {
        entered.set(io_mod.getIo());
        go.waitUncancelable(io_mod.getIo());
    }
};

/// A trace file for the `mailbox` scope, which a test reads to see that a
/// `wait` has looked and is about to block (`wait_begin`).
const GapTrace = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(self: *GapTrace, alloc: Allocator) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        defer alloc.free(root);
        self.path = try std.Io.Dir.path.join(alloc, &.{ root, "gap.log" });
        errdefer alloc.free(self.path);
        debug_trace.resetForTest();
        try debug_trace.configureForTestWithScopes(alloc, self.path, "mailbox");
    }

    fn deinit(self: *GapTrace, alloc: Allocator) void {
        debug_trace.resetForTest();
        alloc.free(self.path);
        self.tmp.cleanup();
    }

    fn waitFor(self: *const GapTrace, needle: []const u8) !void {
        for (0..5000) |_| {
            if (self.has(needle)) return;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return error.Timeout;
    }

    /// Reads the first 64 KiB, which holds every line a test of this scope
    /// writes. The host appends to the file while a test polls it, so this
    /// reads from offset 0 into a fixed buffer. `readFileToEnd` sizes the file
    /// first, and a file that grows during the read makes `std.Io.Writer`'s
    /// `sendFile` subtract past that size and panic.
    fn has(self: *const GapTrace, needle: []const u8) bool {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), self.path, .{}) catch return false;
        defer file.close(io_mod.getIo());
        var buf: [64 * 1024]u8 = undefined;
        const n = file.readPositionalAll(io_mod.getIo(), &buf, 0) catch return false;
        return std.mem.find(u8, buf[0..n], needle) != null;
    }
};

/// What every gap test builds: a parent log, main's worker, a fixture that
/// runs the children, the host, and a trace for the `mailbox` scope. Its parts
/// point at each other, so it stays where `init` built it.
const GapFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    worker: worker_runtime.WorkerRuntime,
    fixture: MailboxFixture,
    runtime: *Runtime,
    trace: GapTrace,
    armed: bool,

    const Options = struct {
        /// The first run of a child waits for its release.
        hold: bool = false,
        /// The report sink takes nothing, as when the owner is gone.
        refuse_reports: bool = false,
        /// Hold the host in the gap at every end. A test that needs an end
        /// first arms the hold itself, with `arm`.
        armed: bool = true,
    };

    fn init(self: *GapFixture, options: Options) !void {
        const alloc = std.testing.allocator;
        self.arena_state = std.heap.ArenaAllocator.init(alloc);
        errdefer self.arena_state.deinit();
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        self.worker = .{};
        errdefer self.worker.deinit(alloc);
        self.fixture = .{ .hold = options.hold, .worker = &self.worker, .refuse_reports = options.refuse_reports };
        errdefer self.fixture.deinit();
        self.runtime = try mailboxRuntime(alloc, &self.fixture, &self.parent);
        errdefer self.runtime.deinit();
        try self.trace.init(alloc);
        errdefer self.trace.deinit(alloc);
        self.armed = false;
        if (options.armed) self.arm();
    }

    /// Releases a held host first, so the runtime can join it, and keeps the
    /// trace until the runtime's threads are gone.
    fn deinit(self: *GapFixture) void {
        const alloc = std.testing.allocator;
        SettleGap.go.set(io_mod.getIo());
        if (self.armed) SettleGap.disarm();
        self.runtime.deinit();
        self.fixture.deinit();
        self.trace.deinit(alloc);
        self.worker.deinit(alloc);
        self.parent.deinit();
        self.arena_state.deinit();
    }

    fn arm(self: *GapFixture) void {
        SettleGap.arm();
        self.armed = true;
    }

    fn arena(self: *GapFixture) Allocator {
        return self.arena_state.allocator();
    }

    /// Calls the subagent tool as main's model would.
    fn call(self: *GapFixture, input: model_contract.RequestInput, invocation_id: []const u8) ![]const u8 {
        return callTool(self.runtime, self.arena(), input, invocation_id, null);
    }

    /// Starts `reviewer`'s first work, which owes main a report, and waits for
    /// it to end. Drops the report, so what follows has nothing queued, and
    /// returns the child's id.
    fn finishFirstWork(self: *GapFixture) ![]const u8 {
        _ = try self.call(.{ .message = .{ .agent = "reviewer", .message = "go" } }, "call-1");
        try waitUntilQuiet(self.runtime);
        const first = self.worker.takeQueuedPrompt(std.testing.allocator).?;
        worker_runtime.freeQueuedPrompt(std.testing.allocator, first);
        return reviewerId(self.runtime, self.arena());
    }
};

/// One `wait` call on its own thread, as main's worker makes it.
const GapWait = struct {
    runtime: *Runtime,
    worker: *worker_runtime.WorkerRuntime,
    /// A child the registry must no longer list when the wait returns. The
    /// wait's own thread reads the registry as it returns, in `listed_at_return`.
    child_id: ?[]const u8 = null,
    listed_at_return: bool = false,
    body: ?[]u8 = null,
    done: std.Io.Event = .unset,
    thread: std.Thread = undefined,

    fn run(self: *GapWait) void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        if (callTool(self.runtime, arena_state.allocator(), .wait, "gap-wait", self.worker)) |text| {
            self.body = std.testing.allocator.dupe(u8, text) catch null;
        } else |_| {}
        if (self.child_id) |id| self.listed_at_return = registryLists(self.runtime, id);
        self.done.set(io_mod.getIo());
    }

    fn start(self: *GapWait) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Starts the wait, then waits for its trace line, which it writes once it
    /// has read that a child works and before it blocks.
    fn startBlocked(self: *GapWait, trace: *const GapTrace) !void {
        try self.start();
        trace.waitFor("wait_begin") catch {
            self.worker.requestCancel();
            self.thread.join();
            return error.WaitNeverBegan;
        };
    }

    /// Joins the wait's thread and returns what it said, which the caller
    /// frees. Fails with `error.WaitBlockedWhileNothingWorks` when it has not
    /// returned within `gap_wait_limit`; it is then cancelled so the test can
    /// finish.
    fn finish(self: *GapWait) ![]u8 {
        self.done.waitTimeout(io_mod.getIo(), gap_wait_limit) catch {
            self.worker.requestCancel();
            self.thread.join();
            return error.WaitBlockedWhileNothingWorks;
        };
        self.thread.join();
        return self.body orelse error.WaitFailed;
    }
};

/// Whether the registry lists `child_id`. An unreadable registry counts as
/// listing it.
fn registryLists(runtime: *Runtime, child_id: []const u8) bool {
    var registry = runtime.managed.state_store.load(std.testing.allocator) catch return true;
    defer registry.deinit(std.testing.allocator);
    return registry.findById(child_id) != null;
}

/// How long a `wait` may stay blocked after the end it raced has settled.
const gap_wait_limit: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// Starts a `wait` once the host is held in the gap, lets the end go, and
/// returns what `wait` said, which the caller frees. By then `wait` has seen
/// the child working and is about to block, so only the end can wake it
/// (`tests/tla/subagent/WaitNudge.tla`: `wait` always returns).
fn waitInSettleGap(gap: *GapFixture) ![]u8 {
    defer SettleGap.go.set(io_mod.getIo());
    SettleGap.entered.waitTimeout(io_mod.getIo(), gap_wait_limit) catch return error.HostNeverReachedTheGap;
    var waiting = GapWait{ .runtime = gap.runtime, .worker = &gap.worker };
    try waiting.startBlocked(&gap.trace);
    SettleGap.go.set(io_mod.getIo());
    return waiting.finish();
}

/// One `wait` call with nothing held, returning what it said, which the
/// caller frees.
fn boundedWait(gap: *GapFixture) ![]u8 {
    var waiting = GapWait{ .runtime = gap.runtime, .worker = &gap.worker };
    try waiting.start();
    return waiting.finish();
}

test "a wait that starts as a subagent's work ends with nothing to report still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{});
    defer gap.deinit();

    // Its rule is never, so a completed work owes no report.
    _ = try gap.call(.{ .message = .{ .agent = "quiet", .message = "go", .report = "never" } }, "call-1");
    const said = try waitInSettleGap(&gap);
    defer std.testing.allocator.free(said);
    try std.testing.expect(std.mem.find(u8, said, "ended without a report") != null);
    try waitUntilQuiet(gap.runtime);
    try std.testing.expectEqual(@as(usize, 0), gap.fixture.reportCount());
}

test "a wait that starts as the parent's stop ends a subagent's turn still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .hold = true });
    defer gap.deinit();

    _ = try gap.call(.{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1");
    try waitForRuns(&gap.fixture, 1);
    // The stop answers for the turn it ends, so that end owes no report.
    _ = try gap.call(.{ .stop = .{ .agent = "reviewer" } }, "call-2");
    const said = try waitInSettleGap(&gap);
    defer std.testing.allocator.free(said);
    try std.testing.expect(std.mem.find(u8, said, "ended without a report") != null);
    try waitUntilQuiet(gap.runtime);
    try std.testing.expectEqual(@as(usize, 0), gap.fixture.reportCount());
}

test "a wait that starts as a report its owner's sink refuses is held still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .refuse_reports = true });
    defer gap.deinit();

    // The work owes a report, which the sink refuses, so none is posted.
    _ = try gap.call(.{ .message = .{ .agent = "reviewer", .message = "go" } }, "call-1");
    const said = try waitInSettleGap(&gap);
    defer std.testing.allocator.free(said);
    try std.testing.expect(std.mem.find(u8, said, "ended without a report") != null);
    try waitUntilQuiet(gap.runtime);
    try std.testing.expectEqual(@as(usize, 0), gap.fixture.reportCount());
    try std.testing.expectEqual(@as(usize, 0), gap.worker.queuedPromptCount());
}

test "a wait that starts as the parent's close ends a subagent's turn still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .hold = true });
    defer gap.deinit();

    _ = try gap.call(.{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1");
    try waitForRuns(&gap.fixture, 1);
    _ = try gap.call(.{ .close = .{ .agent = "reviewer" } }, "call-2");
    const said = try waitInSettleGap(&gap);
    defer std.testing.allocator.free(said);
    try std.testing.expect(std.mem.find(u8, said, "ended without a report") != null);
    try waitUntilQuiet(gap.runtime);
    try std.testing.expectEqual(@as(usize, 0), gap.fixture.reportCount());
}

test "a wait that starts as the user's turn on a subagent ends with nothing to report still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .armed = false });
    defer gap.deinit();

    const child_id = try gap.finishFirstWork();
    // The final rule reports only a user's turn that fails.
    const work_id = gap.runtime.beginUserWork(std.testing.allocator, child_id, null).?;
    defer std.testing.allocator.free(work_id);
    gap.arm();
    const ender = try std.Thread.spawn(.{}, endUserWorkOnThread, .{ gap.runtime, child_id, work_id, child_state.Outcome.completed });
    const said = waitInSettleGap(&gap);
    SettleGap.go.set(io_mod.getIo());
    ender.join();
    const text = try said;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "ended without a report") != null);
    try waitUntilQuiet(gap.runtime);
    try std.testing.expectEqual(@as(usize, 1), gap.fixture.reportCount());
}

fn endUserWorkOnThread(host: *Runtime, child: []const u8, work: []const u8, outcome: child_state.Outcome) void {
    host.endUserWork(child, work, outcome, "");
}

test "a wait that starts before and after the user's turn on a closing subagent ends still returns" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .armed = false });
    defer gap.deinit();

    const child_id = try gap.finishFirstWork();
    const work_id = gap.runtime.beginUserWork(std.testing.allocator, child_id, null).?;
    defer std.testing.allocator.free(work_id);
    // The user's turn keeps the subagent working, so this wait blocks.
    var waiting = GapWait{ .runtime = gap.runtime, .worker = &gap.worker, .child_id = child_id };
    try waiting.startBlocked(&gap.trace);
    // The parent closes the subagent meanwhile, and the turn then ends.
    const closed = (try gap.runtime.closeChild(child_id, .parent)).?;
    try std.testing.expect(closed.stopped);
    gap.runtime.endUserWork(child_id, work_id, .cancelled, "");

    const during = try waiting.finish();
    defer std.testing.allocator.free(during);
    try std.testing.expect(std.mem.find(u8, during, "ended without a report") != null);
    // Once it returns, the subagent is gone from the registry.
    try std.testing.expect(!waiting.listed_at_return);

    const said = try boundedWait(&gap);
    defer std.testing.allocator.free(said);
    try std.testing.expect(std.mem.find(u8, said, "nothing more will arrive") != null);
    try std.testing.expect(!registryLists(gap.runtime, child_id));
}

/// Whether the worker's sticky nudge flag is set.
fn nudgeSet(worker: *worker_runtime.WorkerRuntime) bool {
    worker.worker_mutex.lockUncancelable(io_mod.getIo());
    defer worker.worker_mutex.unlock(io_mod.getIo());
    return worker.mail_nudged;
}

/// Whether a thread is writing the close of `child_id`: the child is on the
/// host's closing list with its `settling` mark, which `settleClose` sets
/// before it takes the registry's lock for the write.
fn closeSettling(runtime: *Runtime, child_id: []const u8) bool {
    runtime.admission_mutex.lockUncancelable(io_mod.getIo());
    defer runtime.admission_mutex.unlock(io_mod.getIo());
    const index = runtime.closingIndexLocked(child_id) orelse return false;
    return runtime.closing.items[index].settling;
}

test "a user's turn on a closing subagent writes the close before it nudges main's wait" {
    var gap: GapFixture = undefined;
    try gap.init(.{ .armed = false });
    defer gap.deinit();

    const child_id = try gap.finishFirstWork();
    const work_id = gap.runtime.beginUserWork(std.testing.allocator, child_id, null).?;
    defer std.testing.allocator.free(work_id);
    _ = (try gap.runtime.closeChild(child_id, .parent)).?;
    // Main's wait is registered, as `waitForMail` registers it first, so a
    // nudge sets the worker's flag and stays set.
    gap.runtime.setWaiter(&gap.worker);
    defer gap.runtime.setWaiter(null);
    gap.arm();
    const ender = try std.Thread.spawn(.{}, endUserWorkOnThread, .{ gap.runtime, child_id, work_id, child_state.Outcome.cancelled });
    var ender_joined = false;
    defer if (!ender_joined) {
        SettleGap.go.set(io_mod.getIo());
        ender.join();
    };
    // The end has finished the work in the log and is held before it settles.
    try SettleGap.entered.waitTimeout(io_mod.getIo(), gap_wait_limit);
    // Hold the registry: the close write cannot finish. settleClose marks the
    // child settling, and keeps it on the closing list, before it waits for
    // the registry.
    var registry_lock = gap.runtime.managed.state_store.acquireLock();
    var registry_released = false;
    defer if (!registry_released) registry_lock.release();
    SettleGap.go.set(io_mod.getIo());
    for (0..5000) |_| {
        if (closeSettling(gap.runtime, child_id)) break;
        io_mod.sleep(std.time.ns_per_ms);
    } else return error.CloseWriteNeverStarted;
    // The close is next, and the nudge must not have come yet.
    const nudged_before_close = nudgeSet(&gap.worker);
    registry_lock.release();
    registry_released = true;
    ender.join();
    ender_joined = true;
    try std.testing.expect(!nudged_before_close);
    try std.testing.expect(nudgeSet(&gap.worker));
    try std.testing.expect(!registryLists(gap.runtime, child_id));
}

test "rebinding a moved host context moves its report sink too" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var before = MailboxFixture{};
    defer before.deinit();
    var after = MailboxFixture{};
    defer after.deinit();
    const runtime = try mailboxRuntime(alloc, &before, &parent);
    defer runtime.deinit();
    runtime.rebindHost(&after, .{ .resolve_fn = MailboxFixture.resolve });
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.report_sink.?.context);
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.child_runner.context);
}

test "the root has no parent to message" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "no_parent") != null);
}

/// One call of the subagent tool as `caller_id`, as its model would make it.
fn callToolAs(runtime: *Runtime, arena: Allocator, caller_id: []const u8, input: model_contract.RequestInput, invocation_id: []const u8) ![]const u8 {
    var request = try model_contract.validateRequest(std.testing.allocator, input);
    defer request.deinit(std.testing.allocator);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
    });
    return result.body;
}

/// Adds a line to `problems` unless `body` refuses with `code` and its
/// `result` is one short sentence for the model.
fn checkRefusalSentence(problems: *std.ArrayList(u8), scenario: []const u8, code: []const u8, body: []const u8) !void {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const sentence: ?[]const u8 = if (object.get("result")) |value| (if (value == .string) value.string else null) else null;
    const ok = object.get("ok").?.bool;
    const got_code = if (object.get("error_code").? == .string) object.get("error_code").?.string else "";
    const fits = if (sentence) |text|
        text.len > 0 and text.len <= 400 and text[text.len - 1] == '.' and std.mem.findScalar(u8, text, '\n') == null
    else
        false;
    if (!ok and std.mem.eql(u8, got_code, code) and fits) return;
    try problems.print(alloc, "{s}: expected a {s} refusal with a one-line sentence, got {s}\n", .{ scenario, code, body });
}

/// A sink whose agent is gone, for a message to a parent that cannot take it.
fn postGone(_: ?*anyopaque, _: *Runtime, _: Delivery) PostReportError!void {
    return error.AgentGone;
}

/// A sink whose queue is full.
fn postFull(_: ?*anyopaque, _: *Runtime, _: Delivery) PostReportError!void {
    return error.QueueFull;
}

/// A sink that posts into a real worker queue, as the app's, `fx ask`'s and
/// ACP's do, so the cap on messages is that queue's own.
fn postToWorker(raw: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
    const worker: *worker_runtime.WorkerRuntime = @ptrCast(@alignCast(raw.?));
    const alloc = std.testing.allocator;
    const text = try alloc.dupe(u8, delivery.message.text);
    worker.postMail(alloc, .{
        .prompt = text,
        .images = &.{},
        .model = &.{},
        .api_key = &.{},
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
        .author = .child,
        .mail = .message,
    }) catch |err| {
        alloc.free(text);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.QueueFull => error.QueueFull,
            else => error.AgentGone,
        };
    };
}

test "every refusal the host returns tells the model what happened and what to do next" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(alloc);

    // A subagent that is working until the test releases it.
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-0", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);

    try checkRefusalSentence(&problems, "instructions for a working subagent", "child_busy", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again", .instructions = "New rules." } }, "call-1", null));
    try checkRefusalSentence(&problems, "effort for an existing subagent", "override_after_create", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again", .effort = "high" } }, "call-2", null));
    try checkRefusalSentence(&problems, "a call id reused with another message", "operation_conflict", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "another" } }, "call-0", null));
    try checkRefusalSentence(&problems, "stop of an unknown name", "child_unavailable", try callTool(runtime, arena, .{ .stop = .{ .agent = "ghost" } }, "call-3", null));
    try checkRefusalSentence(&problems, "close of an unknown name", "child_unavailable", try callTool(runtime, arena, .{ .close = .{ .agent = "ghost" } }, "call-4", null));
    try checkRefusalSentence(&problems, "status of an unknown name", "child_unavailable", try callTool(runtime, arena, .{ .status = .{ .agent = "ghost" } }, "call-5", null));
    try checkRefusalSentence(&problems, "a subagent that manages subagents", "caller_unavailable", try callToolAs(runtime, arena, "some-child", .{ .status = .{} }, "call-6"));
    try checkRefusalSentence(&problems, "wait without a worker", "wait_unavailable", try callTool(runtime, arena, .wait, "call-7", null));

    // The root has no parent, and a parent that cannot take a message.
    try checkRefusalSentence(&problems, "the root messages its parent", "no_parent", try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-8", null));
    const sink = runtime.report_sink;
    defer runtime.report_sink = sink;
    runtime.report_sink = null;
    try checkRefusalSentence(&problems, "no sink for the message", "no_parent", try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-9", null));
    runtime.owner_has_parent = true;
    defer runtime.owner_has_parent = false;
    runtime.report_sink = .{ .context = null, .post_fn = postGone };
    try checkRefusalSentence(&problems, "the parent is gone", "no_parent", try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-10", null));
    runtime.report_sink = .{ .context = null, .post_fn = postFull };
    try checkRefusalSentence(&problems, "the parent's queue is full", "queue_full", try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-11", null));
    runtime.report_sink = sink;

    // A subagent that is being closed.
    try runtime.closing.append(alloc, .{ .id = try alloc.dupe(u8, child_id) });
    try checkRefusalSentence(&problems, "message to a closing subagent", "child_closing", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-12", null));
    alloc.free(runtime.closing.pop().?.id);

    // A working subagent whose turn the message cannot reach.
    runtime.managed.closed = true;
    try checkRefusalSentence(&problems, "the owner is closed", "state_unavailable", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-13", null));
    runtime.managed.closed = false;
    runtime.managed.slots.items[0].shutdown.store(true, .seq_cst);
    try checkRefusalSentence(&problems, "the turn is shutting down", "child_cancelled", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-14", null));
    runtime.managed.slots.items[0].shutdown.store(false, .seq_cst);

    // A working subagent that already holds as many waiting messages as it takes.
    for (0..Runtime.max_pending_per_child) |index| {
        _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "more" } }, try arena.print("fill-{d}", .{index}), null);
    }
    try checkRefusalSentence(&problems, "the subagent's queue is full", "queue_full", try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "one too many" } }, "call-15", null));

    _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-stop", null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqualStrings("", problems.items);
}

test "a refusal reaches the model as its code with the sentence that says what to do next" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-0", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "fixer", .message = "second" } }, "call-1", null);
    try waitForRuns(&fixture, 2);

    // The working subagent keeps its instructions and its conversation.
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"result\":\"The subagent is busy, and instructions can only be set while it is idle. Send the message again without instructions, or wait for its report and then send it with them.\",\"error_code\":\"child_busy\"}",
        try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again", .instructions = "New rules." } }, "call-2", null),
    );
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"result\":\"model, effort and profile are fixed when a subagent is created, so this one keeps its own: send the message again without them. To change them, close it and start a new one, which loses its conversation.\",\"error_code\":\"override_after_create\"}",
        try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again", .model = "other" } }, "call-3", null),
    );
    // A name no subagent bears gets the names that are open.
    const ghost = "{\"ok\":false,\"result\":\"No open subagent is named \\\"ghost\\\". Open subagents: reviewer, fixer.\",\"error_code\":\"child_unavailable\"}";
    try std.testing.expectEqualStrings(ghost, try callTool(runtime, arena, .{ .stop = .{ .agent = "ghost" } }, "call-4", null));
    try std.testing.expectEqualStrings(ghost, try callTool(runtime, arena, .{ .close = .{ .agent = "ghost" } }, "call-5", null));
    try std.testing.expectEqualStrings(ghost, try callTool(runtime, arena, .{ .status = .{ .agent = "ghost" } }, "call-6", null));
    // The refusals changed nothing: both subagents still work.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));

    // The two are closed so no thread outlives the test. Which of them the
    // list still names depends on when each turn ends, so nothing reads it.
    _ = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-7", null);
    _ = try callTool(runtime, arena, .{ .close = .{ .agent = "fixer" } }, "call-8", null);
    try waitUntilQuiet(runtime);
}

test "a parent queue that one subagent filled refuses another that sent nothing, and the sentence says whose messages it counts" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    // The parent's turn runs, so what its subagents send waits in its queue.
    var parent_worker = worker_runtime.WorkerRuntime{};
    defer parent_worker.deinit(alloc);
    parent_worker.worker_processing = true;
    parent_worker.active_turn_id = 9;
    runtime.report_sink = .{ .context = &parent_worker, .post_fn = postToWorker };

    // alpha sends as many messages as the queue takes.
    for (0..agent_frame.queue_cap) |index| {
        const sent = try callToolAs(runtime, arena, "alpha-1", .{ .message = .{ .agent = "parent", .message = "a note" } }, try arena.print("alpha-{d}", .{index}));
        try std.testing.expectStringStartsWith(sent, "{\"ok\":true");
    }
    const full =
        "{\"ok\":false,\"result\":\"Your parent already has 64 messages from its subagents waiting, the most it holds. Put the rest in your final reply.\",\"error_code\":\"queue_full\"}";
    // beta has sent none, and the queue is full for it all the same.
    try std.testing.expectEqualStrings(full, try callToolAs(runtime, arena, "beta-1", .{ .message = .{ .agent = "parent", .message = "a note" } }, "beta-0"));
    try std.testing.expectEqualStrings(full, try callToolAs(runtime, arena, "alpha-1", .{ .message = .{ .agent = "parent", .message = "a note" } }, "alpha-more"));
}

test "a name no subagent bears, with no subagent ever started, says there are none open" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const none_open = "{\"ok\":false,\"result\":\"No open subagent is named \\\"ghost\\\". You have no open subagents.\",\"error_code\":\"child_unavailable\"}";
    try std.testing.expectEqualStrings(none_open, try callTool(runtime, arena, .{ .stop = .{ .agent = "ghost" } }, "call-1", null));
    try std.testing.expectEqualStrings(none_open, try callTool(runtime, arena, .{ .close = .{ .agent = "ghost" } }, "call-2", null));
    try std.testing.expectEqualStrings(none_open, try callTool(runtime, arena, .{ .status = .{ .agent = "ghost" } }, "call-3", null));
}

test "a message that would start a subagent past the session's limit says what to close, and closing one lifts it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    // One subagent that really ran, and so can be messaged.
    const first = try callTool(runtime, arena, .{ .message = .{ .agent = "keeper", .message = "go" } }, "call-keeper", null);
    try std.testing.expectStringStartsWith(first, "{\"ok\":true");
    try waitUntilQuiet(runtime);
    // The rest of the limit is taken by subagents that only the registry knows.
    {
        var lock = runtime.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        while (registry.children.len < child_state.max_children) {
            const id = try session_store.generateSessionId(alloc);
            defer alloc.free(id);
            try registry.appendPersistent(alloc, id, try arena.print("worker-{d}", .{registry.children.len}), "", .{
                .id = @constCast("fill-work"),
                .message = @constCast("go"),
                .created_at_ms = 1,
            });
        }
        try runtime.managed.state_store.save(alloc, registry);
    }

    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"result\":\"This session already has 256 open subagents, the most it holds. Close one you are done with, or send a message to one that exists.\",\"error_code\":\"host_failure\"}",
        try callTool(runtime, arena, .{ .message = .{ .agent = "overflow", .message = "one too many" } }, "call-over", null),
    );
    // A message to one that exists still goes through.
    const existing = try callTool(runtime, arena, .{ .message = .{ .agent = "keeper", .message = "again" } }, "call-existing", null);
    try std.testing.expectStringStartsWith(existing, "{\"ok\":true");
    try waitUntilQuiet(runtime);

    // Closing one frees its place at once.
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "keeper" } }, "call-close", null);
    try std.testing.expectStringStartsWith(closed, "{\"ok\":true");
    const started = try callTool(runtime, arena, .{ .message = .{ .agent = "overflow", .message = "now it fits" } }, "call-fits", null);
    try std.testing.expectStringStartsWith(started, "{\"ok\":true");
    try waitUntilQuiet(runtime);
}

test "a quiet note for a child this host does not have posts nothing" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const Count = struct {
        posts: usize = 0,
        fn post(raw: ?*anyopaque, _: *Runtime, _: Delivery) PostReportError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.posts += 1;
        }
    };
    var count: Count = .{};
    runtime.report_sink = .{ .context = &count, .post_fn = Count.post };
    // A closed child is gone from the registry, as this one never was in it.
    runtime.noteChildQuiet("no-such-child", "ghost", .{ .command = "sleep 600", .quiet_ms = 120_000 });
    try std.testing.expectEqual(@as(usize, 0), count.posts);
}

test "a subagent's message to its parent carries what the user typed in the turn that sends it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const Capture = struct {
        posts: usize = 0,
        lines: std.ArrayList([]u8) = .empty,
        fn post(raw: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.posts += 1;
            for (self.lines.items) |line| std.testing.allocator.free(line);
            self.lines.clearRetainingCapacity();
            for (delivery.message.user_typed) |line| {
                const owned = try std.testing.allocator.dupe(u8, line);
                self.lines.append(std.testing.allocator, owned) catch |err| {
                    std.testing.allocator.free(owned);
                    return err;
                };
            }
        }
    };
    var capture: Capture = .{};
    defer {
        for (capture.lines.items) |line| alloc.free(line);
        capture.lines.deinit(alloc);
    }
    runtime.report_sink = .{ .context = &capture, .post_fn = Capture.post };

    // The sending turn's own worker, as helper's is when helper messages
    // lead: its lines, never another agent's.
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.active_turn_id = 3;
    worker.typed_turn_id = 3;
    try worker.typed_this_turn.append(alloc, try alloc.dupe(u8, "tell lead the schema changed"));
    for ([_]?*worker_runtime.WorkerRuntime{ &worker, null }) |caller_worker| {
        var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "parent", .message = "the user says the schema changed" } });
        defer request.deinit(alloc);
        const result = try runtime.executeManaged(arena, &request, .{
            .caller_id = "helper-1",
            .invocation_id = "call-1",
            .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
            .max_result_bytes = 4096,
            .timestamp_ms = 1,
            .caller_worker = caller_worker,
        });
        try std.testing.expect(std.mem.find(u8, result.body, "Sent to your parent") != null);
        if (caller_worker != null) {
            try std.testing.expectEqual(@as(usize, 1), capture.lines.items.len);
            try std.testing.expectEqualStrings("tell lead the schema changed", capture.lines.items[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), capture.lines.items.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), capture.posts);
}

test "a subagent's message its parent can't take says so, and keeps nothing of what the user typed" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const Full = struct {
        fn post(_: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
            if (delivery.message.user_typed.len == 0) return error.AgentGone;
            return error.QueueFull;
        }
    };
    runtime.report_sink = .{ .context = null, .post_fn = Full.post };
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.active_turn_id = 1;
    worker.typed_turn_id = 1;
    try worker.typed_this_turn.append(alloc, try alloc.dupe(u8, "tell main hi"));
    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "parent", .message = "hi from the user" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = "helper-1",
        .invocation_id = "call-1",
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .caller_worker = &worker,
    });
    try std.testing.expect(std.mem.find(u8, result.body, "queue_full") != null);
    // The worker still has the turn's lines for a later message.
    try std.testing.expectEqual(@as(usize, 1), worker.typed_this_turn.items.len);
}

/// Waits until `child_id`'s work in the parent's log is `work_id`.
fn waitForActiveWork(runtime: *Runtime, arena: Allocator, child_id: []const u8, work_id: []const u8) !void {
    for (0..5000) |_| {
        {
            var lock = runtime.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try runtime.managed.state_store.load(arena);
            if (registry.findById(child_id)) |child| if (child.active) |active| if (std.mem.eql(u8, active.id, work_id)) return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// Waits, in a test, until no child of `runtime` works and no message waits
/// for one. A close of a working child is not written by then: its slot
/// writes the close once the work has ended and stopped counting as working,
/// so a test that reads the registry after such a close waits with
/// `waitUntilClosed` too.
fn waitUntilQuiet(runtime: *Runtime) !void {
    for (0..5000) |_| {
        if (runtime.quiet()) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// Waits, in a test, until the registry no longer holds `child_id`, which is
/// when the close of a working child has been written.
fn waitUntilClosed(runtime: *Runtime, child_id: []const u8) !void {
    for (0..5000) |_| {
        {
            var lock = runtime.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try runtime.managed.state_store.load(std.testing.allocator);
            defer registry.deinit(std.testing.allocator);
            if (registry.findById(child_id) == null) return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// Waits until `worker` blocks on the user: a permission request or a
/// question.
fn waitForBlockedOnUser(worker: *worker_runtime.WorkerRuntime) !void {
    for (0..5000) |_| {
        worker.worker_mutex.lockUncancelable(io_mod.getIo());
        const blocked = worker.pending_permission_waiting or worker.pending_question_shared != null;
        worker.worker_mutex.unlock(io_mod.getIo());
        if (blocked) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

/// The user's decision on the permission request `worker` waits on.
fn decideWaitingPermission(worker: *worker_runtime.WorkerRuntime, decision: types.ToolPermissionDecision) !void {
    worker.worker_mutex.lockUncancelable(io_mod.getIo());
    const request_id = worker.pending_permission_request_shared.?.id;
    worker.worker_mutex.unlock(io_mod.getIo());
    const response = permission_request.OwnedPermissionResponse.init(std.testing.allocator, decision, null);
    try std.testing.expectEqual(worker_runtime.PermissionSubmissionResult.accepted, worker.submitPermissionResponse(request_id, response));
}

/// A host over one hosted subagent, as the app runs them, for a test where the
/// subagent waits for the user. `deinit` releases a wait that is still open, so
/// a test that fails does not hang the join in `Runtime.deinit`.
const HostedAskHost = struct {
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    hosted: worker_runtime.WorkerRuntime,
    fixture: MailboxFixture,
    runtime: *Runtime,

    /// In place, since the host points at the fields.
    fn init(self: *HostedAskHost, asks: @FieldType(MailboxFixture, "asks")) !void {
        const alloc = std.testing.allocator;
        self.arena_state = std.heap.ArenaAllocator.init(alloc);
        errdefer self.arena_state.deinit();
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        self.hosted = .{};
        errdefer self.hosted.deinit(alloc);
        self.fixture = .{ .asks = asks, .hosted = &self.hosted };
        errdefer self.fixture.deinit();
        self.runtime = try hostedMailboxRuntime(alloc, &self.fixture, &self.parent);
    }

    fn arena(self: *HostedAskHost) Allocator {
        return self.arena_state.allocator();
    }

    fn deinit(self: *HostedAskHost) void {
        self.hosted.requestStop();
        self.runtime.deinit();
        self.fixture.deinit();
        self.hosted.deinit(std.testing.allocator);
        self.parent.deinit();
        self.arena_state.deinit();
    }
};

const AskKind = enum { permission, question };

/// How a wait for the user, or the work around it, can end.
const AskEnd = union(enum) {
    answered,
    /// The user declines a permission request.
    declined,
    /// Esc on the child's own screen.
    escaped,
    quit,
    /// The host ends the child's turn.
    host: TurnEnd,
};

/// Fails, showing `needle` against `haystack`, when `haystack` lacks it.
fn expectHas(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) != null) return;
    try std.testing.expectEqualStrings(needle, haystack);
}

/// Fails, showing the text from where it says a subagent waits, when `text`
/// does.
fn expectNotWaiting(text: []const u8) !void {
    const at = std.mem.find(u8, text, "waiting for") orelse return;
    try std.testing.expectEqualStrings("", text[at..]);
}

fn expectNoWaitingLabel(runtime: *Runtime, arena: Allocator) !void {
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-status", null);
    try expectNotWaiting(status);
    const note = try runtime.teamNote(std.testing.allocator, 0);
    defer if (note) |text| std.testing.allocator.free(text);
    if (note) |text| try expectNotWaiting(text);
}

/// A hosted subagent blocks on the user as `kind` says, and `end` ends it.
/// While it waits, `status` and the team note say so, not "working"; once it
/// has ended, they do not.
fn expectAskEnds(kind: AskKind, end: AskEnd) !void {
    const alloc = std.testing.allocator;
    var host: HostedAskHost = undefined;
    try host.init(if (kind == .permission) .permission else .question);
    defer host.deinit();
    const runtime = host.runtime;
    const arena = host.arena();
    const hosted = &host.hosted;

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "ask" } }, "call-1", null);
    try waitForBlockedOnUser(hosted);
    const child_id = try reviewerId(runtime, arena);
    const label = switch (kind) {
        .permission => "reviewer: waiting for an approval, reports final",
        .question => "reviewer: waiting for the user's answer, reports final",
    };
    const waiting = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-2", null);
    try expectHas(waiting, label);
    const note = (try runtime.teamNote(alloc, 0)).?;
    defer alloc.free(note);
    try expectHas(note, label[0 .. label.len - ", reports final".len]);

    switch (end) {
        .answered => switch (kind) {
            .permission => try decideWaitingPermission(hosted, .once),
            .question => try hosted.submitQuestionBatchAnswer(alloc, &.{"Yes"}, null),
        },
        .declined => try decideWaitingPermission(hosted, .deny),
        .escaped => switch (kind) {
            .permission => hosted.cancelApprovalTurn(),
            .question => try hosted.submitQuestionBatchAnswer(alloc, null, null),
        },
        .host => |turn_end| switch (turn_end) {
            .parent_stop => _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null),
            .parent_close => _ = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null),
            .user_close => _ = (try runtime.closeChild(child_id, .user)).?,
        },
        .quit => {
            runtime.managed.noteQuitting();
            hosted.requestCancel();
            hosted.requestShutdown();
        },
    }
    try waitUntilQuiet(runtime);
    try expectNoWaitingLabel(runtime, arena);
}

test "status says a subagent waits for an approval, and not once the user allows it" {
    try expectAskEnds(.permission, .answered);
}

test "status says a subagent waits for an approval, and not once the user declines it" {
    try expectAskEnds(.permission, .declined);
}

test "status says a subagent waits for an approval, and not once the user presses Esc on its screen" {
    try expectAskEnds(.permission, .escaped);
}

test "status says a subagent waits for an approval, and not once main stops it" {
    try expectAskEnds(.permission, .{ .host = .parent_stop });
}

test "status says a subagent waits for an approval, and not once main closes it" {
    try expectAskEnds(.permission, .{ .host = .parent_close });
}

test "status says a subagent waits for an approval, and not once the user closes it" {
    try expectAskEnds(.permission, .{ .host = .user_close });
}

test "status says a subagent waits for an approval, and not once fx quits" {
    try expectAskEnds(.permission, .quit);
}

test "status says a subagent waits for the user's answer, and not once the user answers" {
    try expectAskEnds(.question, .answered);
}

test "status says a subagent waits for the user's answer, and not once the user presses Esc on its screen" {
    try expectAskEnds(.question, .escaped);
}

test "status says a subagent waits for the user's answer, and not once main stops it" {
    try expectAskEnds(.question, .{ .host = .parent_stop });
}

test "status says a subagent waits for the user's answer, and not once main closes it" {
    try expectAskEnds(.question, .{ .host = .parent_close });
}

test "status says a subagent waits for the user's answer, and not once the user closes it" {
    try expectAskEnds(.question, .{ .host = .user_close });
}

test "status says a subagent waits for the user's answer, and not once fx quits" {
    try expectAskEnds(.question, .quit);
}

test "only the subagent that waits for the user says so" {
    var host: HostedAskHost = undefined;
    try host.init(.permission);
    defer host.deinit();
    const runtime = host.runtime;
    const arena = host.arena();
    const hosted = &host.hosted;

    // builder finishes its work and is idle; reviewer then waits.
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "builder", .message = "work" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "ask" } }, "call-2", null);
    try waitForBlockedOnUser(hosted);
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-3", null);
    try expectHas(status, "builder: idle");
    try expectHas(status, "reviewer: waiting for an approval");
    try decideWaitingPermission(hosted, .once);
    try waitUntilQuiet(runtime);
}

fn askThread(worker: *worker_runtime.WorkerRuntime, returned: *std.Io.Event) void {
    defer returned.set(io_mod.getIo());
    var response = worker.requestPermissionBlocking(std.testing.allocator, .{ .label = "Run it?" }) catch return;
    response.deinit();
}

test "a turn the user typed on a hosted subagent's screen shows its wait too" {
    const alloc = std.testing.allocator;
    var host: HostedAskHost = undefined;
    try host.init(.nothing);
    defer host.deinit();
    const runtime = host.runtime;
    const arena = host.arena();
    const hosted = &host.hosted;

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);

    // The user types on the child's screen, and its tool call asks.
    try std.testing.expect(hosted.beginDirectProcessing(9));
    const work_id = runtime.beginUserWork(alloc, child_id, hosted).?;
    defer alloc.free(work_id);
    var returned: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, askThread, .{ hosted, &returned });
    try waitForBlockedOnUser(hosted);
    const waiting = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-2", null);
    try expectHas(waiting, "reviewer: waiting for an approval");
    try decideWaitingPermission(hosted, .once);
    // A wait that does not end is released, so the test fails instead of hanging.
    const asked = testing_event.setInTime(&returned);
    if (!asked) hosted.requestStop();
    thread.join();
    try std.testing.expect(asked);
    const answered = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-3", null);
    try expectHas(answered, "reviewer: working");
    runtime.endUserWork(child_id, work_id, .completed, "done");
    hosted.finishProcessing();
    try waitUntilQuiet(runtime);
    const ended = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-4", null);
    try expectHas(ended, "reviewer: idle");
}

/// The team note for rows in every state `Runtime.ChildState` has, as a note
/// of `kind` says them: a waiting row with no last outcome, one with an
/// outcome, then rows that do not wait, with the fourth past the limit.
fn teamNoteForEveryState(alloc: Allocator, kind: Runtime.NoteKind) ![]u8 {
    const State = Runtime.ChildState;
    return teamNoteText(alloc, &.{
        .{ .name = "writer", .state = State.awaiting_approval.noteLabel(kind), .purpose = "You write src/out.txt." },
        .{ .name = "asker", .state = State.awaiting_answer.noteLabel(kind), .outcome = "completed", .purpose = "You ask the user." },
        .{ .name = "runner", .state = State.working.noteLabel(kind) },
        .{ .name = "idler", .state = State.idle.noteLabel(kind), .outcome = "cancelled" },
    }, 3);
}

test "a row of a kept team note that waits says when the wait was true, and one of a fresh note does not" {
    const alloc = std.testing.allocator;
    const kept = try teamNoteForEveryState(alloc, .kept);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings(team_head ++
        "\n- writer: waiting for an approval when this turn started. For: You write src/out.txt." ++
        "\n- asker: waiting for the user's answer when this turn started, last work completed. For: You ask the user." ++
        "\n- runner: working." ++
        "\n- and 1 more; status lists every one.\n" ++ team_guidance, kept);

    const fresh = try teamNoteForEveryState(alloc, .fresh);
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings(team_head ++
        "\n- writer: waiting for an approval. For: You write src/out.txt." ++
        "\n- asker: waiting for the user's answer, last work completed. For: You ask the user." ++
        "\n- runner: working." ++
        "\n- and 1 more; status lists every one.\n" ++ team_guidance, fresh);

    // `status` names the state the same way for both kinds of note.
    try std.testing.expectEqualStrings("waiting for an approval", Runtime.ChildState.awaiting_approval.label());
    try std.testing.expectEqualStrings("waiting for the user's answer", Runtime.ChildState.awaiting_answer.label());
}

test "a kept team note says a subagent waited when the turn started after the wait ends, and the next turn's note does not" {
    const alloc = std.testing.allocator;
    var host: HostedAskHost = undefined;
    try host.init(.nothing);
    defer host.deinit();
    const runtime = host.runtime;
    const arena = host.arena();
    const hosted = &host.hosted;

    // A first work ends, so the row has a last outcome, and the second waits.
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    host.fixture.asks = .permission;
    // Only a message that starts with "ask" makes a run wait on the user.
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "ask again" } }, "call-2", null);
    try waitForBlockedOnUser(hosted);

    const turn = (try runtime.teamNote(alloc, 7)).?;
    defer alloc.free(turn);
    try expectHas(turn, "\n- reviewer: waiting for an approval when this turn started, last work completed.");
    const fresh = (try runtime.teamNote(alloc, 0)).?;
    defer alloc.free(fresh);
    try expectHas(fresh, "\n- reviewer: waiting for an approval, last work completed.");

    try decideWaitingPermission(hosted, .once);
    try waitUntilQuiet(runtime);
    // The wait is over, and `status` and a note built afresh say so. The note of
    // the turn that began with it still says what was true then, and says when.
    const status = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-3", null);
    try expectNotWaiting(status);
    try expectHas(status, "reviewer: idle");
    const later = (try runtime.teamNote(alloc, 7)).?;
    defer alloc.free(later);
    try std.testing.expectEqualStrings(turn, later);
    const next = (try runtime.teamNote(alloc, 8)).?;
    defer alloc.free(next);
    try expectNotWaiting(next);
    try expectHas(next, "\n- reviewer: idle, last work completed.");
}

/// How the host ends a hosted subagent's running turn: the parent's `stop`
/// or `close`, or the user's close from the agent list.
const TurnEnd = enum { parent_stop, parent_close, user_close };

/// A hosted subagent's turn blocks on the user as `kind` says, and the host
/// ends the turn as `end` says. The turn must end with the host going quiet.
fn expectTurnEnds(kind: AskKind, end: TurnEnd) !void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var hosted = worker_runtime.WorkerRuntime{};
    defer hosted.deinit(alloc);
    var fixture = MailboxFixture{ .asks = if (kind == .permission) .permission else .question, .hosted = &hosted };
    defer fixture.deinit();
    const runtime = try hostedMailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    // A wait still open when a test fails is released, so `deinit` can join.
    defer hosted.requestStop();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "ask" } }, "call-1", null);
    try waitForBlockedOnUser(&hosted);
    const child_id = try reviewerId(runtime, arena);
    switch (end) {
        .parent_stop => _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-2", null),
        .parent_close => _ = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-2", null),
        .user_close => _ = (try runtime.closeChild(child_id, .user)).?,
    }
    try waitUntilQuiet(runtime);
}

test "the parent's stop ends a hosted subagent's turn that waits for a permission answer" {
    try expectTurnEnds(.permission, .parent_stop);
}

test "the parent's stop ends a hosted subagent's turn that waits for a question's answer" {
    try expectTurnEnds(.question, .parent_stop);
}

test "the parent's close ends a hosted subagent's turn that waits for a permission answer" {
    try expectTurnEnds(.permission, .parent_close);
}

test "the parent's close ends a hosted subagent's turn that waits for a question's answer" {
    try expectTurnEnds(.question, .parent_close);
}

test "the user's close ends a hosted subagent's turn that waits for a permission answer" {
    try expectTurnEnds(.permission, .user_close);
}

test "the user's close ends a hosted subagent's turn that waits for a question's answer" {
    try expectTurnEnds(.question, .user_close);
}

fn askQuestionThread(worker: *worker_runtime.WorkerRuntime, returned: *std.Io.Event) void {
    defer returned.set(io_mod.getIo());
    const alloc = std.testing.allocator;
    const options = [_]types.QuestionOption{.{ .label = "Yes", .description = null }};
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};
    if (worker.requestQuestionBatchAnswerBlocking(alloc, &entries) catch null) |answers| {
        for (answers) |answer| alloc.free(answer);
        alloc.free(answers);
    }
}

test "the parent's stop ends a question that waits in a turn the user typed on a hosted subagent's screen" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var hosted = worker_runtime.WorkerRuntime{};
    defer hosted.deinit(alloc);
    var fixture = MailboxFixture{ .hosted = &hosted };
    defer fixture.deinit();
    const runtime = try hostedMailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    defer hosted.requestStop();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);

    // The user types on the child's screen, and its tool call asks.
    try std.testing.expect(hosted.beginDirectProcessing(9));
    const work_id = runtime.beginUserWork(alloc, child_id, &hosted).?;
    defer alloc.free(work_id);
    var returned: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, askQuestionThread, .{ &hosted, &returned });
    try waitForBlockedOnUser(&hosted);
    _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-2", null);
    const ended = testing_event.setInTime(&returned);
    // A wait that stayed open is released, so the test fails instead of hanging.
    if (!ended) hosted.requestStop();
    thread.join();
    try std.testing.expect(ended);
    runtime.endUserWork(child_id, work_id, .cancelled, "");
    hosted.finishProcessing();
    try waitUntilQuiet(runtime);
}

const OverrideResolverFixture = struct {
    runs: usize = 0,
    observed_model: ?[]u8 = null,
    catalog: []const []const u8 = &.{ "openai/gpt-5.6-terra", "openai/gpt-5.6-terra-fast", "openai/gpt-6-astra" },

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.runs += 1;
        var preferences = turn.child.?.currentPreferences(std.testing.allocator) catch return error.ProviderFailed;
        defer preferences.deinit(std.testing.allocator);
        self.observed_model = std.testing.allocator.dupe(u8, preferences.model) catch return error.ProviderFailed;
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = @constCast("CHILD_OK"),
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn resolveModel(raw: ?*anyopaque, alloc: Allocator, raw_model: []const u8) Allocator.Error!model_contract.ModelCatalogMatch {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return model_contract.matchCatalogModel(alloc, self.catalog, raw_model);
    }
};

fn overrideResolverFixtureRuntime(
    alloc: Allocator,
    fixture: *OverrideResolverFixture,
    parent: *child_state.TestParent,
) !*Runtime {
    return Runtime.create(alloc, &parent.children, .{ .resolve_fn = OverrideResolverFixture.resolve }, .{ .context = fixture, .run_fn = OverrideResolverFixture.run });
}

test "model override resolves against the catalog before child creation" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra-fast" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-resolve",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    // The message returns at once; the child runs on its own.
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.find(u8, result.body, "Sent to probe") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", fixture.observed_model.?);
}

test "unknown and ambiguous model overrides reject before any child session" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const options = ExecuteOptions{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-reject",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    };

    var unknown = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "skldjf" } });
    defer unknown.deinit(alloc);
    const unknown_result = try runtime.executeManaged(arena, &unknown, options);
    try std.testing.expect(!unknown_result.success);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "\"error_code\":\"unknown_model\"") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "skldjf") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "omit model to inherit") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "fx models ls --json") != null);

    var ambiguous = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra" } });
    defer ambiguous.deinit(alloc);
    const ambiguous_result = try runtime.executeManaged(arena, &ambiguous, options);
    try std.testing.expect(!ambiguous_result.success);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "\"error_code\":\"ambiguous_model\"") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra-fast") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "fx models ls --json") != null);

    // Rejections never created or ran a child.
    try std.testing.expectEqual(@as(usize, 0), fixture.runs);
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.children.len);
}

test "model override passes through for non-gateway providers" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "unknown-model" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-non-gateway",
        .defaults = .{ .provider = .codex, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    // The configured provider accepts arbitrary model IDs, so the raw override
    // reaches the child even though the gateway catalog lacks it.
    try std.testing.expect(result.success);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("unknown-model", fixture.observed_model.?);
}

fn formatFailedResult(alloc: Allocator, failure: ?[]const u8, partial: ?[]const u8) ![]u8 {
    const reason = failure orelse "failure reason unavailable";
    const text = partial orelse "";
    return alloc.print("Subagent failed: {s}. Earlier tool calls may have completed; their effects are not rolled back.{s}{s}", .{
        reason,
        if (text.len > 0) "\n\nPartial result:\n" else "",
        text,
    });
}

test "subagent failure result distinguishes runtime cause from retained partial text" {
    const alloc = std.testing.allocator;
    const text = try formatFailedResult(alloc, "agent_turn_failed: SessionCommitFailed", "one edit completed");
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "SessionCommitFailed") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Partial result:\none edit completed"));
    const legacy = try formatFailedResult(alloc, null, "");
    defer alloc.free(legacy);
    try std.testing.expect(std.mem.find(u8, legacy, "failure reason unavailable") != null);
    try std.testing.expect(std.mem.find(u8, legacy, "Partial result:") == null);
}

fn terminalResult(
    observation: managed_owner.Observation,
    result: ?[]const u8,
) model_contract.Result {
    return switch (observation.outcome orelse return .{
        .ok = false,
        .result = result,
        .error_code = "child_result_unavailable",
    }) {
        .completed => if (result != null) .{
            .ok = true,
            .result = result,
        } else .{
            .ok = false,
            .error_code = "child_result_unavailable",
        },
        .failed => .{
            .ok = false,
            .result = result,
            .error_code = "child_failed",
        },
        .cancelled => .{
            .ok = false,
            .result = result,
            .error_code = "child_cancelled",
        },
        .interrupted => .{
            .ok = false,
            .result = result,
            .error_code = "child_interrupted",
        },
        .lost => .{
            .ok = false,
            .result = result orelse lost_result,
            .error_code = "child_lost",
        },
    };
}

/// How often a message that waits for a starting work's turn asks again.
const start_wait_poll_ns = 5 * std.time.ns_per_ms;

/// One message waiting for its child's starting turn (`Runtime.start_waits`).
/// A child being closed for good (`Runtime.closing`).
const Closing = struct {
    id: []u8,
    /// Whether a thread is writing its close, so no other writes it too.
    settling: bool = false,
};

/// What names a close's work in the log; the child's id follows.
const close_work_prefix = "fxclose:";

const StartWait = struct {
    child_id: []const u8,
    closed: bool = false,
};
const sent_result_bytes = 256 + domain.max_agent_name_bytes;

/// `message`'s answer when the child takes it now.
fn sentResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "Sent to {s}, which works on it now. Its report arrives on its own when the work ends; keep working or end your turn.", .{agent}) catch "Sent.";
}

/// What decides whether a child is idle once its work's report goes
/// (`Runtime.idleAfterEnd`).
const IdleFacts = struct {
    /// The parent's messages the ended turn never took, which become its
    /// next work.
    leftovers: bool = false,
    /// The user closed the child, which ended the work.
    user_closed: bool = false,
    /// A close of the child is under way.
    closing: bool = false,
    /// A message from the parent waits to start the child's next turn.
    waiting: bool = false,
    /// A turn the parent didn't start waits to open.
    turn_waiting: bool = false,
    /// The child is still in the registry.
    open: bool = false,
    /// Every later message to the child fails the same way, as when its
    /// profile cannot be loaded, so there is nothing to keep it for.
    unusable: bool = false,

    fn idle(self: IdleFacts) bool {
        return self.open and !self.leftovers and !self.user_closed and !self.closing and !self.waiting and !self.turn_waiting and !self.unusable;
    }
};

test "a child is idle after its report only when nothing starts its next turn or ends it" {
    try std.testing.expect((IdleFacts{ .open = true }).idle());
    try std.testing.expect(!(IdleFacts{}).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .leftovers = true }).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .user_closed = true }).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .closing = true }).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .waiting = true }).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .turn_waiting = true }).idle());
    try std.testing.expect(!(IdleFacts{ .open = true, .unusable = true }).idle());
}

/// An idle subagent a new subagent's start names, with what it is for.
const IdleEntry = struct {
    name: []const u8,
    purpose: ?[]const u8 = null,
};

/// What the owner is told, after naming the idle subagents or listing all
/// of them: judgment, not a rule. A subagent's context is worth keeping
/// while related work may come; the owner closes one whose work is done,
/// and asks the user when only the user knows.
const manage_guidance =
    "Give related work to the one whose context fits instead of a new name. Keep or close each as its work requires, and ask the user when you cannot tell.";

/// `message`'s answer when it starts a new child: `sent`, then, when the
/// user closed the child that had its name or other subagents are idle,
/// that it starts with no history, and up to `Runtime.max_named_idle` of
/// the idle ones, each with what it is for, and a count of the rest. A
/// parent tends to start a new subagent for each task and leave the
/// finished ones idle; this keeps them in view at the moment it chooses.
/// Caller owns the result.
fn startedResult(alloc: Allocator, sent: []const u8, agent: []const u8, user_closed: bool, idle: []const IdleEntry) ![]const u8 {
    if (!user_closed and idle.len == 0) return alloc.dupe(u8, sent);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // An allocating writer fails only when it cannot grow.
    writeStarted(&out.writer, sent, agent, user_closed, idle) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeStarted(writer: *std.Io.Writer, sent: []const u8, agent: []const u8, user_closed: bool, idle: []const IdleEntry) std.Io.Writer.Error!void {
    if (user_closed) {
        try writer.print("{s} The user closed the earlier {s}, so this one starts with no history.", .{ sent, agent });
    } else {
        try writer.print("{s} {s} is new and starts with no history.", .{ sent, agent });
    }
    if (idle.len == 0) return;
    try writer.writeAll(" Idle subagents, each with its own context:");
    const named = @min(idle.len, Runtime.max_named_idle);
    for (idle[0..named]) |entry| {
        try writer.print("\n- {s}", .{entry.name});
        if (entry.purpose) |purpose| try writer.print(": {s}", .{purpose});
    }
    if (idle.len > named) try writer.print("\n- and {d} more", .{idle.len - named});
    try writer.print("\n{s}", .{manage_guidance});
}

test "a new subagent's answer names the idle ones with what each is for, up to a limit" {
    const alloc = std.testing.allocator;
    const sent = "Sent to tester, which works on it now. Its report arrives on its own when the work ends; keep working or end your turn.";
    const plain = try startedResult(alloc, sent, "tester", false, &.{});
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(sent, plain);

    const closed = try startedResult(alloc, sent, "tester", true, &.{});
    defer alloc.free(closed);
    try std.testing.expectEqualStrings(sent ++ " The user closed the earlier tester, so this one starts with no history.", closed);

    const one = try startedResult(alloc, sent, "tester", false, &.{.{ .name = "reviewer", .purpose = "Review src/stats.js." }});
    defer alloc.free(one);
    try std.testing.expectEqualStrings(sent ++ " tester is new and starts with no history. Idle subagents, each with its own context:\n- reviewer: Review src/stats.js.\n" ++ manage_guidance, one);

    const both = try startedResult(alloc, sent, "tester", true, &.{ .{ .name = "reviewer" }, .{ .name = "fixer", .purpose = "Fix it." } });
    defer alloc.free(both);
    try std.testing.expect(std.mem.find(u8, both, "The user closed the earlier tester, so this one starts with no history. Idle subagents, each with its own context:\n- reviewer\n- fixer: Fix it.\n") != null);

    var entries: [10]IdleEntry = undefined;
    const names = [_][]const u8{ "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10" };
    for (names, &entries) |name, *entry| entry.* = .{ .name = name };
    const many = try startedResult(alloc, sent, "tester", false, &entries);
    defer alloc.free(many);
    try std.testing.expect(std.mem.find(u8, many, "\n- a8\n- and 2 more\n") != null);
    try std.testing.expect(std.mem.find(u8, many, "- a9") == null);
    const eight = try startedResult(alloc, sent, "tester", false, entries[0..8]);
    defer alloc.free(eight);
    try std.testing.expect(std.mem.find(u8, eight, "\n- a8\n" ++ manage_guidance) != null);
    try std.testing.expect(std.mem.find(u8, eight, "more") == null);
}

/// One subagent in its owner's list (`Runtime.teamNote`).
const TeamRow = struct {
    name: []const u8,
    state: []const u8,
    outcome: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
};

const team_head = "Runtime context: your subagents. Each keeps its own conversation until you close it.";
const team_guidance =
    "Manage them with judgment, as a lead manages a team: give related work to an idle one that already has the context, keep one while related work is likely to follow, and close one whose work is done when nothing ahead needs its context. When you cannot tell which ones the user still needs, ask the user at a natural point, such as when your list grows or the task ends, with your suggestion for each. Do not close one only to shorten this list.";

/// Pure: the owner's list of `rows`, up to `max_listed` of them with a
/// count of the rest, and how to manage them. Caller owns the result.
fn teamNoteText(alloc: Allocator, rows: []const TeamRow, max_listed: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    writeTeam(&out.writer, rows, max_listed) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeTeam(writer: *std.Io.Writer, rows: []const TeamRow, max_listed: usize) std.Io.Writer.Error!void {
    try writer.writeAll(team_head);
    const listed = @min(rows.len, max_listed);
    for (rows[0..listed]) |row| {
        try writer.print("\n- {s}: {s}", .{ row.name, row.state });
        if (row.outcome) |outcome| try writer.print(", last work {s}", .{outcome});
        try writer.writeByte('.');
        if (row.purpose) |purpose| try writer.print(" For: {s}", .{purpose});
    }
    if (rows.len > listed) try writer.print("\n- and {d} more; status lists every one.", .{rows.len - listed});
    try writer.print("\n{s}", .{team_guidance});
}

test "the owner's list says what each subagent does and is for, up to a limit" {
    const alloc = std.testing.allocator;
    const two = try teamNoteText(alloc, &.{
        .{ .name = "builder", .state = "working", .purpose = "You build the parser fix." },
        .{ .name = "reviewer", .state = "idle", .outcome = "completed" },
    }, 20);
    defer alloc.free(two);
    try std.testing.expectEqualStrings(team_head ++ "\n- builder: working. For: You build the parser fix.\n- reviewer: idle, last work completed.\n" ++ team_guidance, two);

    var rows: [5]TeamRow = undefined;
    for (&rows, 0..) |*row, index| row.* = .{ .name = ([_][]const u8{ "a", "b", "c", "d", "e" })[index], .state = "idle" };
    const capped = try teamNoteText(alloc, &rows, 3);
    defer alloc.free(capped);
    try std.testing.expect(std.mem.find(u8, capped, "\n- c: idle.\n- and 2 more; status lists every one.\n") != null);
    try std.testing.expect(std.mem.find(u8, capped, "- d:") == null);
}

/// `message`'s refusal when the child's running turn already holds as many
/// unread messages as it takes.
fn capacityResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "{s} already has {d} unread messages from you. Its next step reads them; send this one again after that, or wait for its report.", .{ agent, managed_owner.max_unread_feedback }) catch "The subagent already has too many unread messages from you.";
}

/// `message`'s answer when the child is busy and the message waits.
fn queuedResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "{s} is busy, so the message waits and starts its next turn. Its report arrives on its own.", .{agent}) catch "Queued.";
}

/// What a cancelled work's report says about its end.
fn cancelledSentence(cause: ?child_state.Cause) []const u8 {
    const known = cause orelse return "Its turn was cancelled before it finished.";
    return switch (known) {
        .user_stop => "The user stopped its turn before it finished.",
        .fx_quit => "fx quit before it finished.",
        .user_close => "The user closed it before it finished. A later message to its name starts a new one.",
    };
}

/// `note`, then the text the subagent had written, when it wrote any.
fn withPartial(a: Allocator, note: []const u8, partial: ?[]const u8) ![]const u8 {
    const text = partial orelse return note;
    return a.print("{s}\n\nWhat it had written:\n{s}", .{ note, text });
}

/// A crash lost the work before the child started it (D33).
const lost_result = "fx stopped before this message reached the subagent, so it never ran. Send it again if it is still needed.";

test "terminal result projects every managed outcome without a lifecycle phase" {
    const completed = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, "done");
    try std.testing.expect(completed.ok);
    try std.testing.expectEqualStrings("done", completed.result.?);
    try std.testing.expect(completed.error_code == null);

    const cases = [_]struct {
        outcome: child_state.Outcome,
        error_code: []const u8,
    }{
        .{ .outcome = .failed, .error_code = "child_failed" },
        .{ .outcome = .cancelled, .error_code = "child_cancelled" },
        .{ .outcome = .interrupted, .error_code = "child_interrupted" },
        .{ .outcome = .lost, .error_code = "child_lost" },
    };
    for (cases) |case| {
        const projected = terminalResult(.{
            .phase = .interrupted,
            .outcome = case.outcome,
        }, "partial");
        try std.testing.expect(!projected.ok);
        try std.testing.expectEqualStrings("partial", projected.result.?);
        try std.testing.expectEqualStrings(case.error_code, projected.error_code.?);
    }

    // Work lost before the child started it says so, so the parent can
    // send it again (D33).
    const lost = terminalResult(.{ .phase = .interrupted, .outcome = .lost }, null);
    try std.testing.expect(!lost.ok);
    try std.testing.expectEqualStrings(lost_result, lost.result.?);

    const missing = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, null);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("child_result_unavailable", missing.error_code.?);
}

fn managedAdmissionReady(
    alloc: Allocator,
    child_id: []const u8,
    created: bool,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id), .created = created } };
}

fn managedAdmissionRejected(
    alloc: Allocator,
    child_id: ?[]const u8,
    why: refusal.Refusal,
) !Runtime.ManagedAdmission {
    return .{ .rejected = .{
        .child_id = if (child_id) |value| try alloc.dupe(u8, value) else null,
        .refusal = why,
    } };
}

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const message = request.message.message;
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const owned_message = try alloc.dupe(u8, message);
    errdefer alloc.free(owned_message);
    const root_context = if (options.root_user_intent_context.len == 0)
        &.{}
    else
        try alloc.dupe(u8, options.root_user_intent_context);
    errdefer if (root_context.len > 0) alloc.free(root_context);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .message = owned_message,
        .root_user_intent_context = @constCast(root_context),
        .root_user_messages = try cloneStrings(alloc, options.root_user_messages),
        .root_user_evidence_complete = options.root_user_evidence_complete,
        .permission_mode = options.parent_permission_mode,
        .created_at_ms = options.timestamp_ms,
    };
}

fn assistantTextForWork(
    history: []const types.HistoryTurn,
    work_id: []const u8,
) ?[]const u8 {
    return switch (turnForWork(history, work_id) orelse return null) {
        .assistant => |value| value.assistant,
        .interrupted => |value| value.assistant orelse "",
        .compacted_summary => null,
    };
}

/// The newest saved turn of work `work_id`.
fn turnForWork(history: []const types.HistoryTurn, work_id: []const u8) ?types.HistoryTurn {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const candidate_work_id = session.historyTurnWorkId(history[index]) orelse continue;
        if (std.mem.eql(u8, candidate_work_id, work_id)) return history[index];
    }
    return null;
}

/// The files `files` changed, each path once, as one list; null when none.
/// Only the file tools record changes, so a shell command's are not in it.
fn listChangedFiles(a: Allocator, files: []const types.FileEvidence) !?[]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        if (file.status != .success or !execution_memory.isMutationFileAction(file.action)) continue;
        for (paths.items) |known| {
            if (std.mem.eql(u8, known, file.path)) break;
        } else try paths.append(a, file.path);
    }
    if (paths.items.len == 0) return null;
    return try std.mem.join(a, ", ", paths.items);
}

/// Builds the parent-facing guidance for a rejected model override.
fn modelOverrideFailureMessage(
    alloc: Allocator,
    comptime kind: enum { ambiguous, unknown },
    raw_model: []const u8,
    candidates: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    switch (kind) {
        .ambiguous => {
            try writer.print("model override '{s}' matches multiple catalog models: ", .{raw_model});
            for (candidates, 0..) |candidate, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.writeAll(candidate);
            }
            try writer.writeAll(". Retry with an exact catalog model ID from `fx models ls --json`.");
        },
        .unknown => {
            try writer.print("unknown model override '{s}'", .{raw_model});
            if (candidates.len > 0) {
                try writer.writeAll(". Closest catalog matches: ");
                for (candidates, 0..) |candidate, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(candidate);
                }
                try writer.writeByte('.');
            } else {
                try writer.writeAll("; no catalog model names match it.");
            }
            try writer.writeAll(" Run `fx models ls --json` to list the exact IDs, or omit model to inherit the parent's model.");
        },
    }
    return out.toOwnedSlice();
}

/// Resolves the defaults used to seed a new child session. When the override
/// passed catalog resolution, `resolved_model` is the canonical catalog ID and
/// wins over the raw override text. The returned value borrows the override or
/// resolved model; the request, the resolved model, and the original defaults
/// must outlive the result.
fn effectiveDefaults(
    defaults: Defaults,
    override: model_contract.Override,
    resolved_model: ?[]const u8,
) Defaults {
    var resolved = defaults;
    if (override.model) |model| resolved.model = resolved_model orelse model;
    if (override.effort) |effort| resolved.effort = effort;
    return resolved;
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return admissionFrom(alloc, request, &snapshot);
}

/// A child's admission from its resolved authority and `request`'s saved
/// preferences.
fn admissionFrom(
    alloc: Allocator,
    request: execution.CaptureRequest,
    snapshot: *const authority.Snapshot,
) execution.ServiceError!domain.AdmissionSnapshot {
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .ultrafast_mode = request.preferences.ultrafast_mode,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
        .integration_names = snapshot.integrations,
        .authority_generation = if (snapshot.mcp_view) |view|
            mcp_access.authorityGeneration(view)
        else
            0,
        .mcp_view = snapshot.mcp_view,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

fn bindChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    const bind_fn = self.child_runner.bind_fn orelse return;
    return bind_fn(self.child_runner.context, turn, cancel);
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(
        self: ModePolicy,
        tool_set: tool_set_contract.ToolSet,
        tool_name: []const u8,
    ) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(
                tool_set,
                active.id,
                tool_name,
            ),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthorityWithMcpView(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    // toolbox's open and search are decided under the names of the tools
    // they replaced, so a child's profile can keep or drop each one.
    const has_toolbox = for (tool_names.items) |name| {
        if (std.mem.eql(u8, name, toolbox_core.tool_name)) break true;
    } else false;
    if (has_toolbox) for (toolbox_core.replaced) |name| {
        if (permissions.rulesDenyAllTargetsForTool(rules, name)) continue;
        try tool_names.append(alloc, name);
    };
    return authority.HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        tool_names.items,
        integration_names,
        rules,
        grants,
        permission_state,
        mcp_view,
    );
}

test "the root's authority names toolbox's open and search, less the ones a rule denies" {
    const alloc = std.testing.allocator;
    const builtin_tools = @import("../../builtins/tools.zig");
    const tools = [_]@import("../tooling/tool_dispatch.zig").Tool{ builtin_tools.read_file, builtin_tools.toolbox };
    const with_toolbox = tool_set_contract.ToolSet{ .registry = .{ .tools = &tools }, .order = &.{ "read_file", "toolbox" }, .read_only_tool_names = &.{} };
    var rules = [_]types.PermissionRule{.{ .permission = @constCast("skill"), .pattern = @constCast("*"), .action = .deny }};
    var root = try captureHostAuthorityWithMcpView(alloc, .{ .tool_set = with_toolbox, .mode = .full }, &.{}, .{ .rules = &rules }, &.{}, .{}, null);
    defer root.deinit(alloc);
    const contains = struct {
        fn in(names: []const []const u8, name: []const u8) bool {
            for (names) |entry| if (std.mem.eql(u8, entry, name)) return true;
            return false;
        }
    }.in;
    for ([_][]const u8{ "read_file", "toolbox", "capability_search", "mcp_select_tool" }) |name| {
        try std.testing.expect(contains(root.tools, name));
    }
    try std.testing.expect(!contains(root.tools, "skill"));

    // Without toolbox there is nothing to open or search through.
    const without = tool_set_contract.ToolSet{ .registry = .{ .tools = tools[0..1] }, .order = &.{"read_file"}, .read_only_tool_names = &.{} };
    var plain = try captureHostAuthorityWithMcpView(alloc, .{ .tool_set = without, .mode = .full }, &.{}, .{}, &.{}, .{}, null);
    defer plain.deinit(alloc);
    for (toolbox_core.replaced) |name| try std.testing.expect(!contains(plain.tools, name));
}

/// What each stop, close and quit test builds: a parent log, a fixture that
/// runs the children, and the host. Its parts point at each other, so it stays
/// where `init` built it. A test whose host a quit already tore down sets
/// `torn_down`, and `deinit` leaves the host alone.
const StopFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    fixture: MailboxFixture,
    runtime: *Runtime,
    torn_down: bool = false,

    fn init(self: *StopFixture, options: MailboxFixture) !void {
        const alloc = std.testing.allocator;
        self.arena_state = std.heap.ArenaAllocator.init(alloc);
        errdefer self.arena_state.deinit();
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        self.fixture = options;
        errdefer self.fixture.deinit();
        self.runtime = try mailboxRuntime(alloc, &self.fixture, &self.parent);
        self.torn_down = false;
    }

    fn deinit(self: *StopFixture) void {
        if (!self.torn_down) self.runtime.deinit();
        self.fixture.deinit();
        self.parent.deinit();
        self.arena_state.deinit();
    }

    fn arena(self: *StopFixture) Allocator {
        return self.arena_state.allocator();
    }
};

/// One hold of a slot at a point an inline test chose: the first slot that
/// reaches it waits until `release`, and the test learns it is there with
/// `waitHeld`. The controls' hooks in `end_test_controls.zig` and
/// `start_test_controls.zig` call `once`.
const TestHold = struct {
    held: std.Io.Event = .unset,
    go: std.Io.Event = .unset,
    calls: std.atomic.Value(u32) = .init(0),

    fn reset(self: *TestHold) void {
        self.held = .unset;
        self.go = .unset;
        self.calls.store(0, .seq_cst);
    }

    fn once(self: *TestHold) void {
        if (self.calls.fetchAdd(1, .seq_cst) != 0) return;
        self.held.set(io_mod.getIo());
        self.go.waitUncancelable(io_mod.getIo());
    }

    fn release(self: *TestHold) void {
        self.go.set(io_mod.getIo());
    }

    fn waitHeld(self: *TestHold) !void {
        self.held.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } }) catch return error.Timeout;
    }
};

/// A hold at the control `field` of `Controls`, whose hook takes the child's
/// id.
fn HeldAt(comptime Controls: type, comptime field: []const u8) type {
    return struct {
        var hold = TestHold{};

        fn at(_: []const u8) void {
            hold.once();
        }

        fn arm() void {
            hold.reset();
            @field(Controls, field) = at;
        }

        /// Stops holding. Call it once no slot thread runs any more, since a
        /// slot reads the hook when each of its works ends.
        fn clear() void {
            @field(Controls, field) = null;
        }

        fn release() void {
            hold.release();
        }

        fn waitHeld() !void {
            try hold.waitHeld();
        }
    };
}

/// The start of a work, before its worker attaches.
const HeldStart = HeldAt(start_test_controls, "test_hold");

/// A hold at `end_test_controls.test_hold_run`, which `recorded` picks: after a
/// work's turn ended, before the slot records its end (false), or after it
/// recorded the end, before the host's end hook runs (true).
fn HeldRun(comptime recorded: bool) type {
    return struct {
        var hold = TestHold{};

        fn at(_: []const u8, now_recorded: bool) void {
            if (now_recorded == recorded) hold.once();
        }

        fn arm() void {
            hold.reset();
            end_test_controls.test_hold_run = at;
        }

        /// Stops holding. Call it once no slot thread runs any more, since a
        /// slot reads the hook when each of its works ends.
        fn clear() void {
            end_test_controls.test_hold_run = null;
        }

        fn release() void {
            hold.release();
        }

        fn waitHeld() !void {
            try hold.waitHeld();
        }
    };
}

/// A work whose turn ended with the parent's messages unread, before the
/// slot records its end.
const HeldAfterRun = HeldRun(false);

/// A work whose end is recorded, before the host's end hook runs.
const HeldRecorded = HeldRun(true);

/// Waits for the slot of `child_id` to end its last work, which is the slot's
/// `done` event: the slot sets it after its end hook returned, so every write
/// that end makes is in by then, the close of a closing child included.
/// `waitUntilQuiet` is not enough for a test that reads that state: the host
/// stops counting a closing child as working (`endClosingWork`) before it
/// writes the close (`settleClose`).
fn waitForSlotEnd(runtime: *Runtime, child_id: []const u8) !void {
    _ = runtime.managed.wait(child_id, .{ .clock = .awake, .raw = .fromSeconds(30) }) catch |err| {
        // A closed child is gone from the registry once its slot ends.
        if (err != error.ChildUnavailable) return err;
    };
    try std.testing.expect(!runtime.managed.hasRunningChild(child_id));
}

/// Waits until the slot reaches `PublishHold`: its work ended and the host chose
/// what follows.
fn waitPublishHeld() !void {
    if (!testing_event.setInTime(&PublishHold.reached)) return error.Timeout;
}

const EndHooks = struct {
    /// The first work of "reviewer" ends with a message waiting, which its
    /// end hook installs as the next work; the slot stops in `PublishHold`
    /// until the test lets it go. Returns once it is there.
    fn endFirstWorkHoldingNext(runtime: *Runtime, fixture: *MailboxFixture, arena: Allocator) !void {
        _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
        try waitForRuns(fixture, 1);
        const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
        try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
        fixture.release.set(io_mod.getIo());
        try waitPublishHeld();
    }
};

const Leftovers = struct {
    /// The first work of "reviewer" takes no steering, and a second message
    /// joins its turn: the turn ends with that message unread, which the slot
    /// keeps for the host to queue. The slot ends the work once the test lets
    /// the hold go, so the caller arms a hold first.
    fn endFirstWorkUnread(runtime: *Runtime, fixture: *MailboxFixture, arena: Allocator) !void {
        _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
        try waitForRuns(fixture, 1);
        const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
        try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
        fixture.release.set(io_mod.getIo());
    }

    const dropped_stop = "Stopped reviewer: its turn ended, and the message waiting for it was dropped.";
    /// A stop after the end is recorded finds no turn to stop.
    const dropped_not_working = "reviewer was not working; the message waiting for it was dropped.";
};

test "a stop that lands as the next work is installed drops it, and it never begins" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    PublishHold.release();
    try waitForSlotEnd(runtime, child_id);
    // Only the first work's turn began, and the stop's answer says what it
    // dropped.
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
    // The first work's own report is the only one: the stop owes none.
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], "DONE first"));
    // The work that never began is finished, not left active.
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    const child = registry.findPersistent("reviewer").?;
    try std.testing.expect(child.active == null);
    try std.testing.expectEqual(child_state.Outcome.cancelled, child.last_outcome.?);
    try std.testing.expect(!child.last_report_owed);
}

test "a stop that lands as two waiting messages are installed as one work counts both" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "third" } }, "call-3", null);
    fixture.release.set(io_mod.getIo());
    try waitPublishHeld();
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    PublishHold.release();
    try waitForSlotEnd(runtime, try reviewerId(runtime, arena));
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the 2 messages waiting for it were dropped.") != null);
}

test "a stop that lands as the message a turn never took is installed counts it, and it never begins" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try waitPublishHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    PublishHold.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_stop) != null);
    // Only the first work's turn began.
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
}

test "a stop that lands as the user's turn ends and the waiting message starts drops it" {
    defer HeldStart.clear();
    var t: StopFixture = undefined;
    try t.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    HeldStart.arm();
    defer HeldStart.release();

    // The user's turn ends, and the message that waited for it becomes the
    // work of a new slot, held before its worker attaches.
    runtime.endUserWork(child_id, work_id, .completed, "");
    try HeldStart.waitHeld();
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    HeldStart.release();
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
}

test "a stop that lands between a turn's end and the slot finishing its work counts the message the turn never took" {
    HeldAfterRun.arm();
    defer HeldAfterRun.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldAfterRun.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldAfterRun.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    HeldAfterRun.release();
    try waitForSlotEnd(runtime, child_id);
    // The message the turn never took does not run, and the stop said so.
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_stop) != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.active == null);
}

/// The slot's end and the host's hold in a parent's stop or close
/// (`end_test_controls.test_hold_stop`): the slot waits after its turn ended and
/// before it records the end, and again once it has. From its hook the stop or
/// close lets the slot go and waits until the end is recorded, so the end runs
/// right after the owner stopped the turn.
const EndInStop = struct {
    var before = TestHold{};
    var after = TestHold{};

    fn heldAt(_: []const u8, recorded: bool) void {
        if (recorded) after.once() else before.once();
    }

    fn inStop(_: []const u8) void {
        before.release();
        after.waitHeld() catch std.debug.print("the slot's end was not recorded in time\n", .{});
    }

    fn arm() void {
        before.reset();
        after.reset();
        end_test_controls.test_hold_run = heldAt;
        end_test_controls.test_hold_stop = inStop;
    }

    fn clear() void {
        end_test_controls.test_hold_run = null;
        end_test_controls.test_hold_stop = null;
    }

    fn release() void {
        before.release();
        after.release();
    }
};

/// The same for a work the slot starts or the host chose, held before its
/// worker attaches: the hook lets the worker attach and waits until it has, so
/// the attach runs right after the owner stopped the work.
const AttachInStop = struct {
    fn inStop(_: []const u8) void {
        HeldStart.release();
        AttachedHold.first.waitHeld() catch std.debug.print("the work's worker did not attach in time\n", .{});
    }

    fn arm() void {
        HeldStart.arm();
        AttachedHold.arm(0);
        end_test_controls.test_hold_stop = inStop;
    }

    fn clear() void {
        HeldStart.clear();
        fixture_run_hook = null;
        end_test_controls.test_hold_stop = null;
    }

    fn release() void {
        HeldStart.release();
        AttachedHold.release();
    }
};

/// The same for a work the host chose that ends before its worker attaches: the
/// hook lets the slot go on and waits until the work's end is recorded.
const EndedInStop = struct {
    fn inStop(_: []const u8) void {
        PublishHeldTwice.first.release();
        HeldRecorded.waitHeld() catch std.debug.print("the work's end was not recorded in time\n", .{});
    }

    fn arm() void {
        HeldRecorded.arm();
        end_test_controls.test_hold_stop = inStop;
    }

    fn clear() void {
        end_test_controls.test_hold_run = null;
        end_test_controls.test_hold_stop = null;
    }
};

/// Fails with the answer in the output when it lacks `expected`.
fn expectAnswerHas(answer: []const u8, expected: []const u8) !void {
    if (std.mem.find(u8, answer, expected) != null) return;
    std.debug.print("expected the answer to hold: {s}\nthe answer: {s}\n", .{ expected, answer });
    return error.TestExpectedEqual;
}

const stopped_and_dropped = "Stopped reviewer: its turn ended, and the message waiting for it was dropped.";
const closed_and_dropped = "Closed reviewer, ending its turn. The message waiting for it was dropped. A later message to reviewer starts a new one.";

test "a stop whose turn's slot ends right after the owner stopped it counts the message the turn never took" {
    EndInStop.arm();
    defer EndInStop.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer EndInStop.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try EndInStop.before.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    // A second stop of the same end counts nothing more.
    const again = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    EndInStop.release();
    try waitForSlotEnd(runtime, child_id);
    try expectAnswerHas(stopped, stopped_and_dropped);
    try std.testing.expect(std.mem.find(u8, again, "dropped") == null);
    // The message never ran, and a stop owes no report.
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
}

test "the parent's close whose turn's slot ends right after the owner stopped it counts the message the turn never took" {
    EndInStop.arm();
    defer EndInStop.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer EndInStop.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try EndInStop.before.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    EndInStop.release();
    try waitForSlotEnd(runtime, child_id);
    try expectAnswerHas(closed, closed_and_dropped);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);
}

/// A work the host chose from the message that waited for the user's turn is
/// held before its worker attaches; the hook in the stop or close lets it
/// attach.
fn heldChosenWork(t: *StopFixture, child_id: *[]const u8, work_id: *[]u8) !void {
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    child_id.* = try reviewerId(runtime, arena);
    work_id.* = runtime.beginUserWork(alloc, child_id.*, null).?;
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    AttachInStop.arm();
    runtime.endUserWork(child_id.*, work_id.*, .completed, "");
    try HeldStart.waitHeld();
}

test "a stop whose chosen work attaches right after the owner stopped it counts the message that waited for it" {
    defer AttachInStop.clear();
    var t: StopFixture = undefined;
    try t.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;
    const runtime = t.runtime;
    const fixture = &t.fixture;
    var child_id: []const u8 = undefined;
    var work_id: []u8 = undefined;
    try heldChosenWork(&t, &child_id, &work_id);
    defer alloc.free(work_id);
    defer AttachInStop.release();

    const stopped = try callTool(runtime, t.arena(), .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    AttachInStop.release();
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try expectAnswerHas(stopped, stopped_and_dropped);
}

test "the parent's close whose chosen work attaches right after the owner stopped it counts the message that waited for it" {
    defer AttachInStop.clear();
    var t: StopFixture = undefined;
    try t.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;
    const runtime = t.runtime;
    const fixture = &t.fixture;
    var child_id: []const u8 = undefined;
    var work_id: []u8 = undefined;
    try heldChosenWork(&t, &child_id, &work_id);
    defer alloc.free(work_id);
    defer AttachInStop.release();

    const closed = try callTool(runtime, t.arena(), .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    AttachInStop.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try expectAnswerHas(closed, closed_and_dropped);
}

/// A parent's stop or close of a work the host chose, whose bind to its agent
/// then ends it before its worker attaches, the end recorded right after the
/// owner stopped the work.
fn expectCountedWhenChosenWorkEnds(actor: Actor, expected: []const u8) !void {
    defer EndedInStop.clear();
    var cell: AccountCell = undefined;
    try cell.init(.next_one_failed, true);
    defer cell.deinit();
    try cell.reach();
    EndedInStop.arm();
    defer HeldRecorded.release();
    try cell.act(actor, 1);
    HeldRecorded.release();
    try cell.finish();
    try expectAnswerHas(cell.answers.items[0], expected);
    // Only the first work's turn began.
    try std.testing.expectEqual(@as(usize, 1), cell.fixture.begun.load(.seq_cst));
}

test "a stop whose chosen work ends before it attaches right after the owner stopped it counts the message that waited for it" {
    try expectCountedWhenChosenWorkEnds(.parent_stop, stopped_and_dropped);
}

test "the parent's close whose chosen work ends before it attaches right after the owner stopped it counts the message that waited for it" {
    try expectCountedWhenChosenWorkEnds(.parent_close, closed_and_dropped);
}

test "the parent's close that lands as the next work is installed drops it, and it never begins" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    const child_id = try reviewerId(runtime, arena);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    PublishHold.release();
    // The close is written as the slot ends, after the host stops counting
    // the child as working.
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer, ending its turn. The message waiting for it was dropped.") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);
}

test "the parent's close that lands before the end hook runs counts the message the turn never took" {
    HeldRecorded.arm();
    defer HeldRecorded.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecorded.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecorded.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    HeldRecorded.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer. The message waiting for it was dropped. A later message to reviewer starts a new one.") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);
}

test "the user's close that lands as the next work is installed ends it, and its report says the user closed it" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    const child_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(child_id, .user)).?;
    PublishHold.release();
    try waitForSlotEnd(runtime, child_id);
    // The close ends the chosen work, so its message never runs. It counts
    // nothing of it, as before: the work's own report says the user closed it.
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expect(closed.stopped);
    try std.testing.expectEqual(@as(usize, 0), closed.dropped);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], "DONE first"));
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "The user closed it before it finished.") != null);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " dropped=") == null);
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_close }, fixture.ends.items[1]);
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "a message sent after a stop that landed before the end hook runs starts the next work once, and the dropped one does not" {
    HeldRecorded.arm();
    defer HeldRecorded.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecorded.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecorded.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    // The stopped work reads no more messages: this one waits for the next.
    const later = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "later" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, later, "waits") != null);
    HeldRecorded.release();
    try waitUntilQuiet(runtime);
    try waitForSlotEnd(runtime, child_id);
    // The first work, then "later" once: "also this" never ran.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed DONE later"));
    // The answer says the turn had ended, and the message was dropped.
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_not_working) != null);
}

test "a stop that lands after the slot finished its work and before its end hook runs counts the message the turn never took" {
    HeldRecorded.arm();
    defer HeldRecorded.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecorded.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecorded.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    // A second stop of the same end counts nothing more.
    const again = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    HeldRecorded.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    // The work ended before the stop, so its own report is the only one.
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], "DONE first"));
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.active == null);
    // The answer says the turn had ended and the message was dropped; a second
    // stop of the same end counts nothing more.
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_not_working) != null);
    try std.testing.expect(std.mem.find(u8, again, "dropped") == null);
}

test "the user's stop that lands after the slot finished its work and before its end hook runs leaves the message the turn never took to start the next work" {
    HeldRecorded.arm();
    defer HeldRecorded.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecorded.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecorded.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    // The user's stop ends no work and counts nothing of the kept message, as
    // before: the hook queues it, and it starts the next work.
    runtime.userStopped(child_id, 0);
    runtime.userStopped(child_id, 0);
    HeldRecorded.release();
    try waitUntilQuiet(runtime);
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed DONE also this"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "a stop after the run of a turn the user stopped returned counts the message that turn never took" {
    HeldAfterRun.arm();
    defer HeldAfterRun.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldAfterRun.release();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(fixture, 1);
    const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
    const child_id = try reviewerId(runtime, arena);
    // The user's stop of the running turn counts nothing, as on `main`: it
    // ends no work and sets no cancel. The turn ends with the message unread,
    // and the parent's stop that follows counts it, since nothing has.
    runtime.userStopped(child_id, 0);
    fixture.release.set(io_mod.getIo());
    try HeldAfterRun.waitHeld();
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    HeldAfterRun.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_stop) != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "a message counted by the parent's stop is not counted again by the user's close of the same turn" {
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true, .linger = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    // A lingering turn leaves only when released, as the test ends or fails.
    defer fixture.release.set(io_mod.getIo());

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_stop) != null);
    // The cancelled turn is still winding down, with that message queued: the
    // stop counted it, and the close counts nothing more.
    const closed = (try runtime.closeChild(child_id, .user)).?;
    try std.testing.expectEqual(@as(usize, 0), closed.dropped);
    fixture.release.set(io_mod.getIo());
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
}

/// A hold after each of the first two works recorded its end, before the host's
/// end hook runs: the slot's second end starts from what its first left.
const HeldRecordedTwice = struct {
    var first = TestHold{};
    var second = TestHold{};
    var ends = std.atomic.Value(u32).init(0);

    fn at(_: []const u8, recorded: bool) void {
        if (!recorded) return;
        switch (ends.fetchAdd(1, .seq_cst)) {
            0 => first.once(),
            1 => second.once(),
            else => {},
        }
    }

    fn arm() void {
        first.reset();
        second.reset();
        ends.store(0, .seq_cst);
        end_test_controls.test_hold_run = at;
    }

    fn clear() void {
        end_test_controls.test_hold_run = null;
    }

    fn releaseAll() void {
        first.release();
        second.release();
    }
};

/// The first work ends with a message unread, which a stop drops before the
/// end hook runs; the message that follows it starts a second work, which a
/// message joins and which ends with that one unread. Returns once the second
/// work's end is recorded.
fn endSecondWorkUnread(runtime: *Runtime, fixture: *MailboxFixture, arena: Allocator) !void {
    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecordedTwice.first.waitHeld();
    const first = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, first, Leftovers.dropped_not_working) != null);
    const later = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "later" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, later, "waits") != null);
    // The second work waits for its release, as the first did.
    fixture.release = .unset;
    HeldRecordedTwice.first.release();
    try waitForRuns(fixture, 2);
    const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
    fixture.release.set(io_mod.getIo());
    try HeldRecordedTwice.second.waitHeld();
}

test "a stop of a work's end counts what that work left unread after an earlier stop counted what its work left" {
    HeldRecordedTwice.arm();
    defer HeldRecordedTwice.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecordedTwice.releaseAll();

    try endSecondWorkUnread(runtime, fixture, arena);
    const second = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-6", null);
    try std.testing.expect(std.mem.find(u8, second, Leftovers.dropped_not_working) != null);
    HeldRecordedTwice.releaseAll();
    try waitForSlotEnd(runtime, try reviewerId(runtime, arena));
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
}

test "the message a work left unread runs as the next work after an earlier stop dropped what its work left" {
    HeldRecordedTwice.arm();
    defer HeldRecordedTwice.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecordedTwice.releaseAll();

    try endSecondWorkUnread(runtime, fixture, arena);
    HeldRecordedTwice.releaseAll();
    try waitUntilQuiet(runtime);
    try waitForSlotEnd(runtime, try reviewerId(runtime, arena));
    // The first work, "later", then "again", which the second work left unread.
    try std.testing.expectEqual(@as(usize, 3), fixture.runs.load(.seq_cst));
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[fixture.reportCount() - 1], " completed DONE again"));
}

test "a second stop of a turn that ended counts nothing the first stop counted" {
    HeldAfterRun.arm();
    defer HeldAfterRun.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldAfterRun.release();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(fixture, 1);
    const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
    const first = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, first, Leftovers.dropped_stop) != null);
    // The cancelled turn ends with that message unread, which its slot keeps;
    // a second stop meets it there and counts it no more.
    try HeldAfterRun.waitHeld();
    const second = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, second, "dropped") == null);
    HeldAfterRun.release();
    try waitForSlotEnd(runtime, try reviewerId(runtime, arena));
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
}

test "a close after a stop in the gap before the end hook counts nothing the stop counted" {
    HeldRecorded.arm();
    defer HeldRecorded.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true, .steerable = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer HeldRecorded.release();

    try Leftovers.endFirstWorkUnread(runtime, fixture, arena);
    try HeldRecorded.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-4", null);
    HeldRecorded.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, stopped, Leftovers.dropped_not_working) != null);
    try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer. A later message to reviewer starts a new one.") != null);
    try std.testing.expect(std.mem.find(u8, closed, "dropped") == null);
}

test "the user's stop that lands as the next work is installed counts nothing, and its work runs" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    const child_id = try reviewerId(runtime, arena);
    // The user's stop ends no work and cancels none (`Owner.noteUserStop`), so
    // the work the host chose runs, and it must not report its message as
    // dropped.
    runtime.userStopped(child_id, 0);
    PublishHold.release();
    try waitForSlotEnd(runtime, child_id);
    try std.testing.expectEqual(@as(usize, 2), fixture.begun.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], "DONE second"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "the user's stop that lands as the user's turn ends and the waiting message starts counts nothing, and its work runs" {
    defer HeldStart.clear();
    var t: StopFixture = undefined;
    try t.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    HeldStart.arm();
    defer HeldStart.release();

    runtime.endUserWork(child_id, work_id, .completed, "");
    try HeldStart.waitHeld();
    // The new slot has no worker yet; the user's stop cancels nothing there.
    runtime.userStopped(child_id, 0);
    HeldStart.release();
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.begun.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], "DONE after the user"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "a stop of the next work after the user's stop counted nothing counts its message once" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    const child_id = try reviewerId(runtime, arena);
    runtime.userStopped(child_id, 0);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    PublishHold.release();
    try waitForSlotEnd(runtime, child_id);
    // The parent's stop ends the work and counts its message, once, and the
    // user's stop before it left nothing for the report to repeat.
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

/// A close of `child_id` that lands as the user's turn ends and the waiting
/// message starts a new slot, held before its worker attaches.
fn expectCloseWhereWaitingMessageStarts(by: Runtime.CloseBy) !void {
    defer HeldStart.clear();
    var t: StopFixture = undefined;
    try t.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    HeldStart.arm();
    defer HeldStart.release();

    runtime.endUserWork(child_id, work_id, .completed, "");
    try HeldStart.waitHeld();
    const closed = (try runtime.closeChild(child_id, by)).?;
    HeldStart.release();
    try waitUntilQuiet(runtime);
    // The close ends that work, so its message never runs. The parent's close
    // counts it; the user's counts nothing, and the work's report says so.
    try std.testing.expect(closed.stopped);
    try std.testing.expectEqual(@as(usize, if (by == .parent) 1 else 0), closed.dropped);
    try std.testing.expectEqual(@as(usize, 1), fixture.begun.load(.seq_cst));
}

test "the parent's close that lands as the waiting message starts drops it, and it never runs" {
    try expectCloseWhereWaitingMessageStarts(.parent);
}

test "the user's close that lands as the waiting message starts ends it, and it never runs" {
    try expectCloseWhereWaitingMessageStarts(.user);
}

const AfterFailedBind = enum { parent_stop, parent_close, user_close };

/// The slot's first work ends and the host chooses the message that waited as
/// its second, which then fails to bind to its agent before its worker
/// attaches. A stop or close lands where that failed work's end is recorded
/// and the host's end hook has not run: its message is accounted for by its
/// failed report, so the stop or close counts none of it.
fn expectNothingCountedAfterFailedBind(action: AfterFailedBind) !void {
    const alloc = std.testing.allocator;
    HeldRecordedTwice.arm();
    defer HeldRecordedTwice.clear();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var hosted_worker = worker_runtime.WorkerRuntime{};
    defer hosted_worker.deinit(alloc);
    var fixture = MailboxFixture{ .hold = true, .hosted = &hosted_worker };
    defer fixture.deinit();
    const runtime = try hostedMailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    defer HeldRecordedTwice.releaseAll();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    fixture.bind_fails.store(true, .seq_cst);
    fixture.release.set(io_mod.getIo());
    // The first work's end is recorded; the hook installs the waiting message
    // as the next work, which fails to bind and ends at once.
    try HeldRecordedTwice.first.waitHeld();
    HeldRecordedTwice.first.release();
    try HeldRecordedTwice.second.waitHeld();
    const child_id = try reviewerId(runtime, arena);
    switch (action) {
        .parent_stop => {
            const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
            try std.testing.expect(std.mem.find(u8, stopped, "reviewer was not working.") != null);
            try std.testing.expect(std.mem.find(u8, stopped, "dropped") == null);
        },
        .parent_close => {
            const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
            try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer.") != null);
            try std.testing.expect(std.mem.find(u8, closed, "dropped") == null);
        },
        .user_close => {
            const closed = (try runtime.closeChild(child_id, .user)).?;
            try std.testing.expect(!closed.stopped);
            try std.testing.expectEqual(@as(usize, 0), closed.dropped);
        },
    }
    HeldRecordedTwice.releaseAll();
    try waitForSlotEnd(runtime, child_id);
    // The failed work's report is what main reads of its message, with no count.
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
    if (action == .parent_stop) {
        try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
        try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
        try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " dropped=") == null);
    }
}

test "a stop after a work that failed to bind ended counts none of its messages" {
    try expectNothingCountedAfterFailedBind(.parent_stop);
}

test "a close by the parent after a work that failed to bind ended counts none of its messages" {
    try expectNothingCountedAfterFailedBind(.parent_close);
}

test "a close by the user after a work that failed to bind ended counts none of its messages" {
    try expectNothingCountedAfterFailedBind(.user_close);
}

test "a stop after the next work began does not count its message" {
    PublishHold.arm();
    defer PublishHold.clear();
    var t: StopFixture = undefined;
    try t.init(.{ .hold = true });
    defer t.deinit();
    const arena = t.arena();
    const runtime = t.runtime;
    const fixture = &t.fixture;
    defer PublishHold.release();

    try EndHooks.endFirstWorkHoldingNext(runtime, fixture, arena);
    // The next work's run waits for a release of its own.
    fixture.release.reset();
    PublishHold.release();
    try waitForRuns(fixture, 2);
    try std.testing.expectEqual(@as(usize, 2), fixture.begun.load(.seq_cst));
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended.") != null);
    try std.testing.expect(std.mem.find(u8, stopped, "dropped") == null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
}

// ---------------------------------------------------------------------------
// The accounting table.
//
// The rule, for each message `m` that main sent to a subagent
// (`tests/tla/subagent/StopMessage.tla` NoSilentLoss and CountedNeverRead).
// An account of `m` is one of: (i) `m`'s turn began; (ii) a count includes `m`,
// the N of a stop's or close's answer or of a user's note; (iii) the report of
// `m`'s own work says the work failed or was cancelled.
//
//   R1, never false: if (ii) or (iii) holds for `m`, its turn never begins.
//   R2, never silent: if `m`'s turn never begins, (ii) or (iii) holds.
//   R3, once: `m` has exactly one account. A count beside the report of a work
//   that failed for another cause is two; so are two counts.
//
// Every cell below puts one subagent in one window of its slot, has one actor
// or two in a row act there, lets everything finish, and checks the three
// rules from what main reads and what ran. The cells that no key press or
// production caller reaches stay in the table as the host's contracts: the
// user's stop in any slot window (`Runtime.userStopped` is called only while
// the child's run is in flight or the user's own turn runs, and both have
// ended before the slot goes on), and a work cancelled before it attaches on
// its own (`Owner.cancel` has no production caller).

const Actor = enum { parent_stop, parent_close, user_close, user_stop };

/// One action, or two in a row, at one window.
const Plan = struct { first: Actor, second: ?Actor = null };

/// The pairs that end in a user's stop are not run: the app calls
/// `Runtime.userStopped` only while a turn runs, and no turn runs after a stop
/// or close.
const table_plans = [_]Plan{
    .{ .first = .parent_stop },
    .{ .first = .parent_close },
    .{ .first = .user_close },
    .{ .first = .user_stop },
    .{ .first = .parent_stop, .second = .user_close },
    .{ .first = .user_close, .second = .parent_stop },
    .{ .first = .parent_stop, .second = .parent_close },
    .{ .first = .parent_close, .second = .parent_stop },
    .{ .first = .parent_stop, .second = .parent_stop },
    .{ .first = .user_stop, .second = .parent_stop },
    .{ .first = .user_close, .second = .parent_close },
    .{ .first = .parent_close, .second = .user_close },
    .{ .first = .user_stop, .second = .parent_close },
    .{ .first = .parent_close, .second = .parent_close },
    .{ .first = .user_close, .second = .user_close },
    .{ .first = .user_stop, .second = .user_close },
};

const Scenario = enum {
    /// A turn is running and one message of the parent's joined it unread.
    running_unread,
    /// The first work's turn returned and its end is not recorded yet: nothing
    /// else waits (`_clean`), or a message joined its turn and is kept.
    returned_clean,
    returned_kept,
    /// The second work, chosen from a waiting message, ended before its worker
    /// attached, and its end is not recorded yet: its bind failed, or it was
    /// cancelled before it attached.
    returned_failed,
    returned_cancelled,
    /// The same, with the end recorded and the host's end hook not run yet; a
    /// message waits, which the hook installs as the next work.
    recorded_clean,
    recorded_kept,
    recorded_waiting,
    recorded_failed,
    recorded_cancelled,
    /// The hook returned and the slot has not gone on: nothing is next.
    gap_idle,
    gap_after_failed,
    gap_after_cancelled,
    /// The hook chose a next work of one message, or of two joined, which has
    /// no worker yet. It would run, its bind would fail, or it was cancelled.
    next_one,
    next_two,
    next_one_failed,
    next_two_failed,
    next_one_cancelled,
    next_two_cancelled,
    /// The user's turn ended and the waiting message, or two, started a new
    /// slot that has bound and not attached its worker.
    starting_one,
    starting_two,
    /// Two works in a row, each ending with a message unread, the first one's
    /// dropped by a stop before the second began.
    two_works_unread,
    /// The first work fails with a message kept: its end is recorded and the
    /// host's hook has not run.
    recorded_kept_failed_first,
    /// The first work fails with a message waiting, and the hook has chosen it.
    gap_next_failed_first,
    /// The first work's worker attached, and its turn has not begun.
    attached_not_begun,
    /// The same for the work the host chose from a waiting message.
    next_attached_not_begun,

    /// A hosted run binds to the child agent's own worker, as the app's do;
    /// the cells that make a work fail or cancel before it attaches need it.
    fn hosted(self: Scenario) bool {
        return switch (self) {
            .running_unread,
            .returned_failed,
            .returned_cancelled,
            .recorded_failed,
            .recorded_cancelled,
            .gap_after_failed,
            .gap_after_cancelled,
            .next_one_failed,
            .next_two_failed,
            .next_one_cancelled,
            .next_two_cancelled,
            => true,
            else => false,
        };
    }

    /// Whether the first work's run waits for a release.
    fn holdsFirstWork(self: Scenario) bool {
        return switch (self) {
            .returned_clean, .recorded_clean, .gap_idle, .starting_one, .starting_two, .attached_not_begun => false,
            else => true,
        };
    }

    fn steerable(self: Scenario) bool {
        return switch (self) {
            .running_unread, .returned_kept, .recorded_kept, .two_works_unread, .recorded_kept_failed_first => true,
            else => false,
        };
    }

    /// The groups of messages that share one fate, and the call of the first.
    fn units(self: Scenario) []const AccountUnit {
        return switch (self) {
            .returned_clean, .recorded_clean, .gap_idle, .attached_not_begun => &.{unit_first},
            .running_unread, .returned_kept, .recorded_kept, .recorded_kept_failed_first => &.{ unit_first, unit_unread },
            .next_two, .next_two_failed, .next_two_cancelled, .starting_two => &.{ unit_first, unit_joined },
            .two_works_unread => &.{ unit_first, unit_unread, unit_later, unit_again },
            else => &.{ unit_first, unit_second },
        };
    }
};

/// Messages that share one fate: they ran in one turn, or one work carried them.
const AccountUnit = struct { tokens: []const []const u8, call: []const u8 };
const unit_first = AccountUnit{ .tokens = &.{"first"}, .call = "call-1" };
const unit_second = AccountUnit{ .tokens = &.{"second"}, .call = "call-2" };
const unit_joined = AccountUnit{ .tokens = &.{ "second", "third" }, .call = "call-2" };
const unit_unread = AccountUnit{ .tokens = &.{"also this"}, .call = "call-2" };
const unit_later = AccountUnit{ .tokens = &.{"later"}, .call = "call-4" };
const unit_again = AccountUnit{ .tokens = &.{"again"}, .call = "call-5" };

/// The first and the second hold of each kind a cell uses: after a work's turn
/// returned (`recorded` false) or after its end is recorded (true), and after
/// the host's end hook returned.
fn HeldRunTwice(comptime recorded: bool) type {
    return struct {
        var first = TestHold{};
        var second = TestHold{};
        var calls = std.atomic.Value(u32).init(0);

        fn at(_: []const u8, now_recorded: bool) void {
            if (now_recorded != recorded) return;
            switch (calls.fetchAdd(1, .seq_cst)) {
                0 => first.once(),
                1 => second.once(),
                else => {},
            }
        }

        fn arm() void {
            first.reset();
            second.reset();
            calls.store(0, .seq_cst);
            end_test_controls.test_hold_run = at;
        }

        fn release() void {
            first.release();
            second.release();
        }
    };
}

const RunHeld = HeldRunTwice(false);
const RecordedHeld = HeldRunTwice(true);

/// The hold at the top of the fixture's `run`: a work's worker has attached
/// and its turn has not begun. It holds the run with the index `armed_for`:
/// 0 is the first work, 1 the one the host chooses next.
const AttachedHold = struct {
    var first = TestHold{};
    var calls = std.atomic.Value(u32).init(0);
    var armed_for: u32 = 0;

    fn at() void {
        if (calls.fetchAdd(1, .seq_cst) == armed_for) first.once();
    }

    fn arm(run_index: u32) void {
        first.reset();
        calls.store(0, .seq_cst);
        armed_for = run_index;
        fixture_run_hook = at;
    }

    fn release() void {
        first.release();
    }
};

/// Test builds run it at the top of `MailboxFixture.run`, before the run looks at
/// its cancel; null unless a cell holds the attached work.
var fixture_run_hook: ?*const fn () void = null;

const PublishHeldTwice = struct {
    var first = TestHold{};
    var second = TestHold{};
    var calls = std.atomic.Value(u32).init(0);

    fn at(_: []const u8) void {
        switch (calls.fetchAdd(1, .seq_cst)) {
            0 => first.once(),
            1 => second.once(),
            else => {},
        }
    }

    fn arm() void {
        first.reset();
        second.reset();
        calls.store(0, .seq_cst);
        publish_test_controls.test_hold = at;
    }

    fn release() void {
        first.release();
        second.release();
    }
};

/// One cell's subagent: a parent log, a fixture that runs its children, and
/// the host, which point at each other, so it stays where `init` built it.
const AccountCell = struct {
    alloc: Allocator,
    arena_state: std.heap.ArenaAllocator,
    parent: child_state.TestParent,
    hosted_worker: worker_runtime.WorkerRuntime,
    fixture: MailboxFixture,
    runtime: *Runtime,
    scenario: Scenario,
    child_id: []const u8 = "",
    user_work: ?[]u8 = null,
    /// What each stop's and close's answer said, in order.
    answers: std.ArrayList([]const u8) = .empty,

    fn init(self: *AccountCell, scenario: Scenario, hosted_path: bool) !void {
        const alloc = std.testing.allocator;
        const hosted = scenario.hosted() or hosted_path;
        self.* = .{
            .alloc = alloc,
            .arena_state = .init(alloc),
            .parent = undefined,
            .hosted_worker = .{},
            .fixture = .{
                .hold = scenario.holdsFirstWork(),
                .steerable = scenario.steerable(),
                .hosted = if (hosted) &self.hosted_worker else null,
                .bind_honors_cancel = hosted,
                .fail_first = scenario == .recorded_kept_failed_first or scenario == .gap_next_failed_first,
            },
            .runtime = undefined,
            .scenario = scenario,
        };
        errdefer self.arena_state.deinit();
        errdefer self.hosted_worker.deinit(alloc);
        try self.parent.init(alloc);
        errdefer self.parent.deinit();
        errdefer self.fixture.deinit();
        self.armHolds();
        errdefer clearAccountHooks();
        // A message to a work that has not taken steering yet waits for its
        // turn, 5 ms at a time, for up to 10 s (`message_waits_start`), which
        // is about half a second a cell. The cells only need it to wait for
        // the next turn, so they shorten the limit.
        start_test_controls.test_wait_limit_ms = 2;
        self.runtime = if (hosted)
            try hostedMailboxRuntime(alloc, &self.fixture, &self.parent)
        else
            try mailboxRuntime(alloc, &self.fixture, &self.parent);
    }

    /// Undone in reverse: every hold is let go, the slot's thread ends with the
    /// runtime, and only then are the hooks cleared.
    fn deinit(self: *AccountCell) void {
        self.releaseHolds();
        self.runtime.deinit();
        clearAccountHooks();
        if (self.user_work) |id| self.alloc.free(id);
        self.answers.deinit(self.alloc);
        self.fixture.deinit();
        self.hosted_worker.deinit(self.alloc);
        self.parent.deinit();
        self.arena_state.deinit();
    }

    fn armHolds(self: *AccountCell) void {
        switch (self.scenario) {
            .running_unread => {},
            .returned_clean, .returned_kept, .returned_failed => RunHeld.arm(),
            .returned_cancelled => {
                RunHeld.arm();
                PublishHeldTwice.arm();
            },
            .recorded_clean, .recorded_kept, .recorded_waiting, .recorded_failed, .two_works_unread => RecordedHeld.arm(),
            .recorded_cancelled => {
                RecordedHeld.arm();
                PublishHeldTwice.arm();
            },
            .gap_idle, .gap_after_failed, .gap_after_cancelled, .next_one, .next_two, .next_one_failed, .next_two_failed, .next_one_cancelled, .next_two_cancelled => PublishHeldTwice.arm(),
            // Armed once the first work has ended, so the hold meets the slot
            // the waiting message starts and not the first one.
            .starting_one, .starting_two => {},
            .recorded_kept_failed_first => RecordedHeld.arm(),
            .gap_next_failed_first => PublishHeldTwice.arm(),
            .attached_not_begun => AttachedHold.arm(0),
            .next_attached_not_begun => AttachedHold.arm(1),
        }
    }

    fn releaseHolds(_: *AccountCell) void {
        RunHeld.release();
        RecordedHeld.release();
        PublishHeldTwice.release();
        HeldStart.release();
        AttachedHold.release();
    }

    fn arena(self: *AccountCell) Allocator {
        return self.arena_state.allocator();
    }

    fn say(self: *AccountCell, text: []const u8, call: []const u8) ![]const u8 {
        return callTool(self.runtime, self.arena(), .{ .message = .{ .agent = "reviewer", .message = text } }, call, null);
    }

    /// A message the subagent has to hold: it is busy.
    fn sayWaiting(self: *AccountCell, text: []const u8, call: []const u8) !void {
        const answer = try self.say(text, call);
        try std.testing.expect(std.mem.find(u8, answer, "is busy") != null);
    }

    fn childId(self: *AccountCell) ![]const u8 {
        if (self.child_id.len == 0) self.child_id = try reviewerId(self.runtime, self.arena());
        return self.child_id;
    }

    /// The first work runs, and one message, or two, wait for it.
    fn firstWorkWithWaiting(self: *AccountCell, joined: bool) !void {
        _ = try self.say("first", "call-1");
        try waitForRuns(&self.fixture, 1);
        try self.sayWaiting("second", "call-2");
        if (joined) try self.sayWaiting("third", "call-3");
    }

    /// Brings the slot to its window.
    fn reach(self: *AccountCell) !void {
        const fixture = &self.fixture;
        switch (self.scenario) {
            .running_unread => {
                _ = try self.say("first", "call-1");
                try waitForRuns(fixture, 1);
                const joined = try self.say("also this", "call-2");
                try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
            },
            .returned_clean => {
                _ = try self.say("first", "call-1");
                try RunHeld.first.waitHeld();
            },
            .returned_kept => {
                try Leftovers.endFirstWorkUnread(self.runtime, fixture, self.arena());
                try RunHeld.first.waitHeld();
            },
            .returned_failed => {
                try self.firstWorkWithWaiting(false);
                fixture.bind_fails.store(true, .seq_cst);
                fixture.release.set(io_mod.getIo());
                try RunHeld.first.waitHeld();
                RunHeld.first.release();
                try RunHeld.second.waitHeld();
            },
            .returned_cancelled => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try RunHeld.first.waitHeld();
                RunHeld.first.release();
                try PublishHeldTwice.first.waitHeld();
                try self.runtime.managed.cancel(try self.childId());
                PublishHeldTwice.first.release();
                try RunHeld.second.waitHeld();
            },
            .recorded_clean => {
                _ = try self.say("first", "call-1");
                try RecordedHeld.first.waitHeld();
            },
            .recorded_kept => {
                try Leftovers.endFirstWorkUnread(self.runtime, fixture, self.arena());
                try RecordedHeld.first.waitHeld();
            },
            .recorded_waiting => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try RecordedHeld.first.waitHeld();
            },
            .recorded_failed => {
                try self.firstWorkWithWaiting(false);
                fixture.bind_fails.store(true, .seq_cst);
                fixture.release.set(io_mod.getIo());
                try RecordedHeld.first.waitHeld();
                RecordedHeld.first.release();
                try RecordedHeld.second.waitHeld();
            },
            .recorded_cancelled => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try RecordedHeld.first.waitHeld();
                RecordedHeld.first.release();
                try PublishHeldTwice.first.waitHeld();
                try self.runtime.managed.cancel(try self.childId());
                PublishHeldTwice.first.release();
                try RecordedHeld.second.waitHeld();
            },
            .gap_idle => {
                _ = try self.say("first", "call-1");
                try PublishHeldTwice.first.waitHeld();
            },
            .gap_after_failed => {
                try self.firstWorkWithWaiting(false);
                fixture.bind_fails.store(true, .seq_cst);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
                PublishHeldTwice.first.release();
                try PublishHeldTwice.second.waitHeld();
            },
            .gap_after_cancelled => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
                try self.runtime.managed.cancel(try self.childId());
                PublishHeldTwice.first.release();
                try PublishHeldTwice.second.waitHeld();
            },
            .next_one, .next_two => {
                try self.firstWorkWithWaiting(self.scenario == .next_two);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
            },
            .next_one_failed, .next_two_failed => {
                try self.firstWorkWithWaiting(self.scenario == .next_two_failed);
                fixture.bind_fails.store(true, .seq_cst);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
            },
            .next_one_cancelled, .next_two_cancelled => {
                try self.firstWorkWithWaiting(self.scenario == .next_two_cancelled);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
                try self.runtime.managed.cancel(try self.childId());
            },
            .starting_one, .starting_two => {
                _ = try self.say("first", "call-1");
                try waitUntilQuiet(self.runtime);
                const child_id = try self.childId();
                const work_id = self.runtime.beginUserWork(self.alloc, child_id, null).?;
                self.user_work = work_id;
                try self.sayWaiting("second", "call-2");
                if (self.scenario == .starting_two) try self.sayWaiting("third", "call-3");
                HeldStart.arm();
                self.runtime.endUserWork(child_id, work_id, .completed, "");
                try HeldStart.waitHeld();
            },
            .two_works_unread => {
                _ = try self.say("first", "call-1");
                try waitForRuns(fixture, 1);
                const joined = try self.say("also this", "call-2");
                try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
                fixture.release.set(io_mod.getIo());
                try RecordedHeld.first.waitHeld();
                // The first work's end is recorded with a message kept: a stop
                // drops it before the hook runs, and the next message starts
                // the second work, which a message joins and which ends with
                // that one unread.
                try self.answers.append(self.alloc, try callTool(self.runtime, self.arena(), .{ .stop = .{ .agent = "reviewer" } }, "call-3", null));
                try self.sayWaiting("later", "call-4");
                fixture.release = .unset;
                RecordedHeld.first.release();
                try waitForRuns(fixture, 2);
                const again = try self.say("again", "call-5");
                try std.testing.expect(std.mem.find(u8, again, "Sent into the subagent's running turn") != null);
                fixture.release.set(io_mod.getIo());
                try RecordedHeld.second.waitHeld();
            },
            .recorded_kept_failed_first => {
                try Leftovers.endFirstWorkUnread(self.runtime, fixture, self.arena());
                try RecordedHeld.first.waitHeld();
            },
            .gap_next_failed_first => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try PublishHeldTwice.first.waitHeld();
            },
            .attached_not_begun => {
                _ = try self.say("first", "call-1");
                try AttachedHold.first.waitHeld();
            },
            .next_attached_not_begun => {
                try self.firstWorkWithWaiting(false);
                fixture.release.set(io_mod.getIo());
                try AttachedHold.first.waitHeld();
            },
        }
    }

    fn act(self: *AccountCell, actor: Actor, step: usize) !void {
        const child_id = try self.childId();
        const call = try self.arena().print("call-act-{d}", .{step});
        switch (actor) {
            .parent_stop => try self.answers.append(self.alloc, try callTool(self.runtime, self.arena(), .{ .stop = .{ .agent = "reviewer" } }, call, null)),
            .parent_close => try self.answers.append(self.alloc, try callTool(self.runtime, self.arena(), .{ .close = .{ .agent = "reviewer" } }, call, null)),
            .user_close => {
                _ = try self.runtime.closeChild(child_id, .user);
            },
            .user_stop => {
                // The app's Esc drops the turn's queued messages and passes how
                // many were the parent's, then ends the turn on the child's own
                // worker (`AppAgentsRuntime.noteUserStop`).
                if (self.scenario == .running_unread) {
                    const drop = self.hosted_worker.dropAgentMessages(self.alloc);
                    self.runtime.userStopped(child_id, drop.from_parent);
                    try self.runtime.managed.cancel(child_id);
                } else {
                    self.runtime.userStopped(child_id, 0);
                }
            },
        }
    }

    /// Lets everything go and waits until the slot has ended its last work.
    fn finish(self: *AccountCell) !void {
        self.releaseHolds();
        try waitForSlotEnd(self.runtime, try self.childId());
        try waitUntilQuiet(self.runtime);
    }

    /// What each message of the cell came to, from what ran and what main read.
    fn tally(self: *AccountCell) AccountLedger {
        var ledger = AccountLedger{};
        const fixture = &self.fixture;
        fixture.mutex.lockUncancelable(io_mod.getIo());
        defer fixture.mutex.unlock(io_mod.getIo());
        for (self.scenario.units()) |unit| {
            const began = for (fixture.began_contents.items) |content| {
                const hit = for (unit.tokens) |token| {
                    if (std.mem.find(u8, content, token) != null) break true;
                } else false;
                if (hit) break true;
            } else false;
            if (began) {
                ledger.ran += unit.tokens.len;
                continue;
            }
            ledger.never_began += unit.tokens.len;
            for (fixture.reports.items) |line| {
                const fields = accountReportFields(line);
                if (!std.mem.eql(u8, fields.call, unit.call)) continue;
                const dropped = accountReportDropped(line);
                if (std.mem.eql(u8, fields.outcome, "failed")) {
                    ledger.by_report += unit.tokens.len;
                    if (dropped > 0) ledger.count_beside_failed_report = true;
                    break;
                }
                // A cancelled work's report says so; with a count of its own it
                // is the count that accounts for the messages, once.
                if (std.mem.eql(u8, fields.outcome, "cancelled") and dropped == 0) {
                    ledger.by_report += unit.tokens.len;
                    break;
                }
            }
        }
        for (self.answers.items) |answer| ledger.counted += accountAnswerDropped(answer);
        for (fixture.reports.items) |line| ledger.counted += accountReportDropped(line);
        for (self.runtime.user_dropped.items) |drop| ledger.counted += drop.count;
        return ledger;
    }

    fn print(self: *AccountCell, name: []const u8, ledger: AccountLedger, verdict: AccountVerdict) void {
        std.debug.print("\nTABLE {s}: {s}. Messages whose turn never began {d}; accounted by their own work's failed or cancelled report {d}; counted dropped {d}.\n", .{ name, @tagName(verdict), ledger.never_began, ledger.by_report, ledger.counted });
        for (self.answers.items, 0..) |answer, i| std.debug.print("TABLE   answer[{d}]: {s}\n", .{ i, answer });
        self.fixture.mutex.lockUncancelable(io_mod.getIo());
        defer self.fixture.mutex.unlock(io_mod.getIo());
        for (self.fixture.reports.items, 0..) |line, i| std.debug.print("TABLE   report[{d}]: {s}\n", .{ i, line });
        for (self.fixture.began_contents.items) |content| std.debug.print("TABLE   turn began on: {s}\n", .{content});
        for (self.runtime.user_dropped.items) |drop| std.debug.print("TABLE   user note still held: count={d}\n", .{drop.count});
    }
};

fn clearAccountHooks() void {
    fixture_run_hook = null;
    start_test_controls.test_wait_limit_ms = null;
    end_test_controls.test_hold_run = null;
    publish_test_controls.test_hold = null;
    start_test_controls.test_hold = null;
}

const AccountLedger = struct {
    ran: usize = 0,
    never_began: usize = 0,
    by_report: usize = 0,
    counted: usize = 0,
    count_beside_failed_report: bool = false,
};

const AccountVerdict = enum {
    ok,
    /// R2: a message whose turn never began has no account.
    silent,
    /// R1 or R3: more accounts than messages that never ran.
    over_counted,
    /// R3: a count beside the report of a work that failed.
    count_beside_failed_report,
    /// The case says it breaks R2 as `main` does, and it does not.
    wrongly_marked,
};

fn accountVerdict(ledger: AccountLedger, as_on_main: bool) AccountVerdict {
    if (ledger.count_beside_failed_report) return .count_beside_failed_report;
    const accounted = ledger.by_report + ledger.counted;
    if (accounted > ledger.never_began) return .over_counted;
    if (accounted < ledger.never_began) return if (as_on_main) .ok else .silent;
    return if (as_on_main) .wrongly_marked else .ok;
}

const AccountReportFields = struct { call: []const u8, outcome: []const u8 };

/// A fixture report is "agent call_id work_id outcome output[ dropped=N]".
fn accountReportFields(line: []const u8) AccountReportFields {
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    const call = parts.next() orelse "";
    _ = parts.next();
    const outcome = parts.next() orelse "";
    return .{ .call = call, .outcome = outcome };
}

fn accountReportDropped(line: []const u8) usize {
    const marker = " dropped=";
    const at = std.mem.findLast(u8, line, marker) orelse return 0;
    return std.fmt.parseInt(usize, line[at + marker.len ..], 10) catch 0;
}

/// How many messages a stop's or close's answer says it dropped.
fn accountAnswerDropped(answer: []const u8) usize {
    if (std.mem.find(u8, answer, "message waiting for it was dropped") != null) return 1;
    const tail = " messages waiting for it were dropped";
    const at = std.mem.find(u8, answer, tail) orelse return 0;
    var start = at;
    while (start > 0 and std.ascii.isDigit(answer[start - 1])) start -= 1;
    return std.fmt.parseInt(usize, answer[start..at], 10) catch 0;
}

/// Cells that break R2 as `main` does: no count names a message that was dropped.
/// A user's close of a turn with a message unread or kept, and the user's stop
/// before the end is recorded with one kept, drop it silently; so do a second
/// close, the parent's or the user's, after them, and the user's close after a
/// user's stop that left a message. A parent's stop that follows counts what
/// the user's left. On the hosted path, a parent's stop or close after the
/// work's worker attached and before its turn begins withdraws the turn (the
/// app's `postAndWait`) and counts nothing: `Slot.unstarted` is zeroed at the
/// attach. A change that counts these takes this list as its failing tests.
/// Every other cell holds R2.
fn accountAsOnMain(plan: Plan, scenario: Scenario, hosted_path: bool) bool {
    const attached = scenario == .attached_not_begun or scenario == .next_attached_not_begun;
    if (attached and (hosted_path or scenario.hosted())) {
        // The parent's stop owes no report, and nor does its close, unless the
        // user's close came first: its report stays and accounts.
        const parent_first = plan.first == .parent_stop or plan.first == .parent_close;
        return parent_first or plan.second == .parent_stop or (plan.second == .parent_close and plan.first != .user_close);
    }
    const user_close_silent = switch (scenario) {
        .running_unread, .returned_kept, .recorded_kept, .two_works_unread, .recorded_kept_failed_first => true,
        else => false,
    };
    return switch (plan.first) {
        .user_close => user_close_silent and (plan.second == null or plan.second == .parent_close or plan.second == .user_close),
        .user_stop => if (plan.second) |second| switch (second) {
            // The app's Esc on a running turn counts the unread message.
            .user_close => user_close_silent and scenario != .running_unread,
            else => false,
        } else scenario == .returned_kept,
        else => false,
    };
}

fn accountCellName(buf: []u8, scenario: Scenario, hosted_path: bool, plan: Plan, as_on_main: bool) []const u8 {
    return std.mem.print(buf, "{s}{s} / {s}{s}{s}{s}", .{
        @tagName(scenario),
        if (hosted_path and !scenario.hosted()) " (hosted)" else "",
        @tagName(plan.first),
        if (plan.second != null) " then " else "",
        if (plan.second) |second| @tagName(second) else "",
        if (as_on_main) " (as on main: R2)" else "",
    }) catch "?";
}

/// Runs one cell. False when it breaks a rule, after printing what main reads.
fn runAccountCell(scenario: Scenario, hosted_path: bool, plan: Plan) !bool {
    var cell: AccountCell = undefined;
    try cell.init(scenario, hosted_path);
    defer cell.deinit();
    try cell.reach();
    try cell.act(plan.first, 1);
    if (plan.second) |second| try cell.act(second, 2);
    try cell.finish();
    const as_on_main = accountAsOnMain(plan, scenario, hosted_path);
    const ledger = cell.tally();
    const verdict = accountVerdict(ledger, as_on_main);
    if (verdict == .ok) return true;
    var buf: [160]u8 = undefined;
    cell.print(accountCellName(&buf, scenario, hosted_path, plan, as_on_main), ledger, verdict);
    return false;
}

test "every message main sends has one account in every window of a subagent's slot, for each stop and close" {
    var broken: usize = 0;
    var cells: usize = 0;
    for (std.enums.values(Scenario)) |scenario| {
        // A window runs on the plain path, where the fixture's run saves a
        // reply, and on the hosted path, where the child's agent runs the turn
        // as the app's children do; a window that needs the hosted path only
        // runs there.
        const paths: []const bool = if (scenario.hosted()) &.{true} else &.{ false, true };
        for (paths) |hosted_path| {
            for (table_plans) |plan| {
                cells += 1;
                const held = runAccountCell(scenario, hosted_path, plan) catch |err| {
                    var buf: [160]u8 = undefined;
                    std.debug.print("\nTABLE {s}: the cell could not be driven ({s}); the rest of its window is skipped\n", .{ accountCellName(&buf, scenario, hosted_path, plan, false), @errorName(err) });
                    broken += 1;
                    break;
                };
                if (!held) broken += 1;
            }
        }
    }
    if (broken > 0) std.debug.print("\nTABLE {d} of {d} cells break the rule or could not be driven\n", .{ broken, cells });
    try std.testing.expectEqual(@as(usize, 0), broken);
}
