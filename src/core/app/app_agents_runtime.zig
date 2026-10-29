//! The interactive app's agents besides main, and how the main loop works for
//! each one. A subagent runs main's own code on its own conversation, so the
//! loop handles its events exactly like main's: in that agent's context, with
//! its transcript and paced text on the screen, swapped back before anything
//! paints.

const std = @import("std");
const agents = @import("../agents/agents.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const composer_stash = @import("../input/composer_stash.zig");
const input_action = @import("../input/input_action.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agent_runtime = @import("app_agent_runtime.zig");
const ui_render = @import("../../ui/render.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const agents_menu_presentation = @import("../../ui/footer/agents_menu_presentation.zig");
const session_mod = @import("../session/session.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_process_runtime = @import("app_process_runtime.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_reports = @import("../subagent/reports.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const AssistantPacer = assistant_pacer.AssistantPacer;

/// What the screen holds for an agent while another agent is on it: the
/// agent's transcript, the assistant text still waiting to be paced out, and
/// the composer's unsent draft. The agent on screen keeps an empty one.
pub const ScreenSlot = struct {
    transcript: transcript_runtime.TranscriptSlot = .{},
    pacer: AssistantPacer = .{},
    draft: composer_stash.State = .{},
    /// The agent's fast mode while it is out of context: `App.fast_mode`
    /// always holds the one of the agent in context, as in a second fx.
    fast_mode: bool = false,

    pub fn deinit(self: *ScreenSlot, alloc: Allocator) void {
        TranscriptRuntime.deinitSlot(&self.transcript, alloc);
        self.pacer.deinit(alloc);
        self.draft.deinit(alloc);
        self.* = undefined;
    }
};

/// A subagent the app runs as a full agent. Heap-allocated, so its address
/// stays fixed for its worker thread and for the loop's context pointer.
pub const ChildAgent = struct {
    /// The child's session id. Owned.
    id: []u8,
    agent: agents.Agent = .{},
    screen: ScreenSlot = .{},
    /// Slot-thread turns bound to this agent's worker. The agent is freed
    /// only once none is left.
    bound: subagent_execution.HostedRelease = .{},
    /// Whether this process has built the agent's notebook from its saved
    /// conversation. Later turns append to it live.
    view_built: bool = false,
    /// Whether this agent holds its own session, opened on its first run in
    /// this process and kept until main's session ends.
    session_attached: bool = false,
    /// The host that started it: main's, or its parent subagent's own.
    /// Its session opens through it, and its own subagents'
    /// authority comes from that host's resolver. Written on the main loop
    /// and read by resolvers on other threads, both under main's authority
    /// lock. Borrowed: that host outlives it.
    parent_host: ?*subagent_tool_host.Runtime = null,
    /// The name its parent gave it, such as `reviewer`, from its first run.
    /// Empty for a one-off. Owned.
    name: []u8 = &.{},
    /// Where its current approval and question come in the order its tree's
    /// prompts were asked (`App.prompt_order`), so the instance's screen
    /// shows the oldest first. Meaningful only while that prompt is active.
    /// Main loop only.
    approval_asked: u64 = 0,
    question_asked: u64 = 0,
    /// Backs `footerLabel`.
    label_buf: [160]u8 = undefined,

    /// How fx names the agent to the user: its name, or its id without one.
    pub fn displayName(self: *const ChildAgent) []const u8 {
        return if (self.name.len > 0) self.name else self.id;
    }

    /// The footer's name for it on its own screen, marked done while none of
    /// its turns is going. Valid until the next call; only the main
    /// loop paints.
    fn footerLabel(self: *ChildAgent) []const u8 {
        if (self.workGoing()) return self.displayName();
        return std.mem.print(&self.label_buf, "{s} · done", .{self.displayName()}) catch self.displayName();
    }

    /// Whether a turn of its is running, waiting to run, or finished with
    /// its events not yet applied: main's run, the user's, or steering left
    /// over from either. Its paced output is checked where its screen is;
    /// see `turnGoing`.
    fn workGoing(self: *ChildAgent) bool {
        if (self.agent.child_run) |*run| if (run.inFlight()) return true;
        return turnInFlight(&self.agent) or self.agent.worker.hasPendingEvents();
    }
};

/// The agent list ↓, Ctrl+X, and `/agents` open. Its rows are every open
/// agent in switch order, built each time it is drawn so each shows what it
/// is doing now. The highlighted row's agent is the one on screen: moving
/// through the list previews each agent, Enter keeps the one shown, and Esc
/// or Ctrl+X go back to `origin`.
pub const AgentsMenu = struct {
    open: bool = false,
    /// The selected agent's place in the switch list, from 0.
    selected: usize = 0,
    window_start: usize = 0,
    /// The agent on screen when the list opened, null for the first
    /// instance. Compared by address only, so it is never read after its
    /// agent closes. Meaningful while `open`.
    origin: ?*ChildAgent = null,
    /// Backs the rows the last projection showed. Owned.
    rows: std.ArrayList(render_input.AgentsMenuRow) = .empty,

    pub fn deinit(self: *AgentsMenu, alloc: Allocator) void {
        self.rows.deinit(alloc);
        self.* = .{};
    }
};

/// What an instance is doing, as the instance list shows it, most urgent
/// first.
const InstanceState = enum {
    needs_approval,
    has_question,
    /// A request only the user can continue, such as one out of credits.
    needs_you,
    working,
    finished,
    idle,

    pub fn label(self: InstanceState) []const u8 {
        return switch (self) {
            .needs_approval => "needs approval",
            .has_question => "has a question",
            .needs_you => "needs you",
            .working => "working",
            .finished => "finished",
            .idle => "idle",
        };
    }
};

/// `request_waits` is whether the agent's status row shows a request that
/// waits for the user.
fn instanceState(agent: *agents.Agent, request_waits: bool) InstanceState {
    if (agent.approval_prompt.isActive()) return .needs_approval;
    if (agent.question_prompt.isActive()) return .has_question;
    if (request_waits) return .needs_you;
    if (turnInFlight(agent)) return .working;
    if (agent.finished_unseen) return .finished;
    return .idle;
}

/// Whether one of `agent`'s turns is going or queued.
fn turnInFlight(agent: *agents.Agent) bool {
    return agent.worker.isProcessing() or agent.worker.queuedPromptCount() > 0;
}

/// Slot threads and the main loop both use the hand-off list.
const handoff_alloc = std.heap.c_allocator;

/// Hand-offs from the subagent host's slot threads to the main loop. A slot
/// thread posts and waits; only the main loop takes, once each pass.
pub const Handoffs = struct {
    mutex: std.Io.Mutex = .init,
    /// Set when the app shuts down: nothing more is posted or taken, and
    /// every slot thread waiting for a hand-off is released.
    closed: bool = false,
    posts: std.ArrayList(*Post) = .empty,
    /// Children's reports for the agents that own their hosts, in the order
    /// they were posted.
    reports: std.ArrayList(*ReportPost) = .empty,

    pub fn deinit(self: *Handoffs) void {
        self.posts.deinit(handoff_alloc);
        self.reports.deinit(handoff_alloc);
        self.* = .{};
    }
};

/// A host's delivery on its way to the main loop: a child's report for the
/// agent that owns `host`, or a subagent's message to its parent. It owns
/// copies of what it carries, so the poster never waits: a slot thread that
/// waited on the loop could deadlock with a `/close` that joins it.
pub const ReportPost = struct {
    host: *subagent_tool_host.Runtime,
    kind: enum { report, message },
    /// For a message: whether the host's owner sent it, so it goes to the
    /// owner's own parent.
    from_owner: bool = false,
    agent: []u8,
    child_id: []u8,
    work_id: []u8,
    outcome: subagent_child_state.Outcome = .completed,
    /// The report's output, or the message's text.
    text: []u8,
    /// A report's count of the parent's messages a user's stop dropped.
    dropped: usize = 0,

    fn create(host: *subagent_tool_host.Runtime, delivery: subagent_tool_host.Delivery) !*ReportPost {
        const post = try handoff_alloc.create(ReportPost);
        errdefer handoff_alloc.destroy(post);
        const agent, const child_id, const work_id, const text = switch (delivery) {
            .report => |report| .{ report.agent, report.child_id, report.work_id, report.output },
            .message => |message| .{ message.agent, message.child_id, "", message.text },
        };
        const owned_agent = try handoff_alloc.dupe(u8, agent);
        errdefer handoff_alloc.free(owned_agent);
        const owned_child = try handoff_alloc.dupe(u8, child_id);
        errdefer handoff_alloc.free(owned_child);
        const owned_work = try handoff_alloc.dupe(u8, work_id);
        errdefer handoff_alloc.free(owned_work);
        post.* = .{
            .host = host,
            .kind = if (delivery == .report) .report else .message,
            .from_owner = delivery == .message and delivery.message.to == .owners_parent,
            .agent = owned_agent,
            .child_id = owned_child,
            .work_id = owned_work,
            .outcome = if (delivery == .report) delivery.report.outcome else .completed,
            .text = try handoff_alloc.dupe(u8, text),
            .dropped = if (delivery == .report) delivery.report.dropped else 0,
        };
        return post;
    }

    fn destroy(self: *ReportPost) void {
        handoff_alloc.free(self.agent);
        handoff_alloc.free(self.child_id);
        handoff_alloc.free(self.work_id);
        handoff_alloc.free(self.text);
        handoff_alloc.destroy(self);
    }
};

test "a report's hand-off keeps the count of messages a user's stop dropped" {
    // Only the host's address is kept, so any will do.
    var host: subagent_tool_host.Runtime = undefined;
    const post = try ReportPost.create(&host, .{ .report = .{ .agent = "reviewer", .child_id = "c1", .work_id = "w1", .outcome = .cancelled, .output = "", .dropped = 2 } });
    defer post.destroy();
    try std.testing.expectEqual(@as(usize, 2), post.dropped);
    try std.testing.expectEqual(subagent_child_state.Outcome.cancelled, post.outcome);
}

/// Queues a host's delivery for the main loop, without waiting.
/// `AgentGone` once the app is shutting down; a report then stays owed.
pub fn postDelivery(handoffs: *Handoffs, host: *subagent_tool_host.Runtime, delivery: subagent_tool_host.Delivery) subagent_tool_host.PostReportError!void {
    const post = try ReportPost.create(host, delivery);
    handoffs.mutex.lockUncancelable(io_mod.getIo());
    defer handoffs.mutex.unlock(io_mod.getIo());
    if (handoffs.closed) {
        post.destroy();
        return error.AgentGone;
    }
    handoffs.reports.append(handoff_alloc, post) catch {
        post.destroy();
        return error.OutOfMemory;
    };
}

/// One hand-off, on the posting slot thread's stack until the loop takes it.
pub const Post = struct {
    /// The run's turn context. Its child id names the agent. Borrowed.
    turn: *subagent_execution.TurnContext,
    /// Null to bind `turn` to its child agent's worker; otherwise the run to
    /// start there, moved to the agent when the loop takes it.
    run: ?agents.ChildRun = null,
    /// The message, sent to the agent as if typed. Borrowed.
    message: []const u8 = "",
    state: std.atomic.Value(State) = .init(.posted),
    /// Set once the main loop holds the run back while a turn of its child's
    /// is going. Only the main loop reads or writes it.
    held: bool = false,

    /// Set when the main loop settles the post, to wake the slot thread.
    settled: std.Io.Event = .unset,

    pub const State = enum(u8) { posted, taken, failed, closed };

    /// Settles the post. Wakes the slot thread before the store: once it
    /// sees the new state it may return and free the post, so nothing
    /// touches the post afterwards.
    pub fn settle(self: *Post, state: State) void {
        self.settled.set(io_mod.getIo());
        self.state.store(state, .release);
    }
};

pub const PostError = error{ OutOfMemory, Cancelled, Failed };

/// Posts `post` and waits until the main loop takes it. Fails with
/// `Cancelled` when `cancel` is set first or the app shuts down.
pub fn postAndWait(handoffs: *Handoffs, post: *Post, cancel: *std.atomic.Value(bool)) PostError!void {
    {
        handoffs.mutex.lockUncancelable(io_mod.getIo());
        defer handoffs.mutex.unlock(io_mod.getIo());
        if (handoffs.closed) return error.Cancelled;
        try handoffs.posts.append(handoff_alloc, post);
    }
    while (true) {
        switch (post.state.load(.acquire)) {
            .taken => return,
            .failed => return error.Failed,
            .closed => return error.Cancelled,
            .posted => {},
        }
        if (cancel.load(.seq_cst) and withdraw(handoffs, post)) return error.Cancelled;
        // Settling wakes this at once; the timeout only rechecks `cancel`,
        // which its setter does not signal.
        post.settled.waitTimeout(io_mod.getIo(), wake_check) catch {};
    }
}

/// How long a slot thread sleeps before it rechecks a cancel no one signals.
const wake_check: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

/// How long the main loop waits for slot threads to let go of a child agent
/// before it gives up on freeing it.
const release_timeout_ms: i64 = 5_000;

/// Takes `post` back if the loop has not taken it yet.
fn withdraw(handoffs: *Handoffs, post: *Post) bool {
    handoffs.mutex.lockUncancelable(io_mod.getIo());
    defer handoffs.mutex.unlock(io_mod.getIo());
    for (handoffs.posts.items, 0..) |item, index| if (item == post) {
        _ = handoffs.posts.orderedRemove(index);
        return true;
    };
    return false;
}

/// Waits until the main loop ends the run `completion` belongs to. A run
/// always ends: its turn finishes, or shutdown ends it after joining the
/// child's worker. The end wakes this at once. While `cancel` is set, each
/// wake also cancels the turn on `worker` again: a worker clears its cancel
/// flag when a turn begins, the same worker code main's Esc uses, so a
/// cancel that lands before then would otherwise be lost.
pub fn waitForCompletion(
    completion: *agents.ChildRunCompletion,
    cancel: *std.atomic.Value(bool),
    worker: *worker_runtime.WorkerRuntime,
) agents.ChildRunCompletion.Outcome {
    while (true) {
        if (completion.result()) |outcome| return outcome;
        if (cancel.load(.seq_cst)) worker.requestTurnCancel();
        completion.done.waitTimeout(io_mod.getIo(), wake_check) catch {};
    }
}

/// Puts `children` in the order of `listing`, the registry's start order.
/// One the listing doesn't name keeps its relative place after them.
fn orderByListing(children: []*ChildAgent, listing: anytype) void {
    var next: usize = 0;
    for (listing) |entry| {
        for (children[next..], next..) |child, index| {
            if (!std.mem.eql(u8, child.id, entry.id)) continue;
            std.mem.rotate(*ChildAgent, children[next .. index + 1], index - next);
            next += 1;
            break;
        }
    }
}

/// The app `agent` belongs to. A subagent records its app when the app
/// creates it; main is the app's `main_agent` field, so it needs no record.
pub fn appOf(comptime App: type, agent: *@FieldType(App, "main_agent")) *App {
    if (comptime @hasField(@FieldType(App, "main_agent"), "app")) {
        if (agent.app) |owner| return @ptrCast(@alignCast(owner));
    }
    return @alignCast(@fieldParentPtr("main_agent", agent));
}

/// One hosted agent as the switch order sees it: an instance, or a subagent
/// in the tree of instance `root`, where 0 is the first instance and k the
/// k-th later one in launch order.
const OrderEntry = struct { role: agents.Role, root: usize = 0 };

/// The switch order over the first instance and `entries`, written to
/// `out` as positions: 0 for the first instance, k + 1 for `entries[k]`. The
/// instances come in launch order, each followed by the subagents in its
/// tree in the order they started. `out.len` is `entries.len + 1`, and every
/// subagent's root is the first instance or one in `entries`.
fn switchOrder(entries: []const OrderEntry, out: []usize) void {
    std.debug.assert(out.len == entries.len + 1);
    var next: usize = 0;
    out[next] = 0;
    next += 1;
    appendGroup(entries, 0, out, &next);
    var ordinal: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.role != .instance) continue;
        ordinal += 1;
        out[next] = index + 1;
        next += 1;
        appendGroup(entries, ordinal, out, &next);
    }
    std.debug.assert(next == out.len);
}

fn appendGroup(entries: []const OrderEntry, root: usize, out: []usize, next: *usize) void {
    for (entries, 0..) |entry, index| {
        if (entry.role != .subagent or entry.root != root) continue;
        out[next.*] = index + 1;
        next.* += 1;
    }
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        /// Runs `body` in `child`'s context: the loop's agent in context is
        /// `child`, and its transcript and pacer are on the screen. Both are
        /// put back before this returns, so nothing paints in between.
        pub fn visit(
            app: *App,
            child: *ChildAgent,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            try visitScreen(app, &child.agent, &child.screen, context, body);
        }

        /// Runs `body` for a hidden agent, main or a subagent, with `agent` in
        /// context and `screen`'s transcript and pacer on the screen.
        fn visitScreen(
            app: *App,
            agent: *agents.Agent,
            screen: *ScreenSlot,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            const previous = app.screen_owner;
            app.screen_owner = agent;
            app.shell.swapSlot(&screen.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &screen.pacer);
            std.mem.swap(bool, &app.fast_mode, &screen.fast_mode);
            defer {
                std.mem.swap(bool, &app.fast_mode, &screen.fast_mode);
                std.mem.swap(AssistantPacer, &app.pacer, &screen.pacer);
                app.shell.swapSlot(&screen.transcript);
                app.screen_owner = previous;
            }
            try body(context, app, agent);
        }

        /// True when `child` has events for the loop to handle or assistant
        /// text left to pace out.
        pub fn hasPendingWork(child: *ChildAgent) bool {
            return child.agent.worker.hasPendingEvents() or child.screen.pacer.hasPending();
        }

        /// Handles the work of every hidden agent that has any, each in its
        /// own context, so it keeps working while another is on screen:
        /// main while a subagent is on screen, and every subagent but the one
        /// on screen. The agent on screen is handled in the loop's own context.
        pub fn tickChildren(
            app: *App,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            if (app.agent_on_screen != null and
                (app.main_agent.worker.hasPendingEvents() or app.main_screen.pacer.hasPending() or
                    approvalOutOfDate(&app.main_agent, false)))
            {
                try visitScreen(app, &app.main_agent, &app.main_screen, context, body);
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                if (!hasPendingWork(child) and !approvalOutOfDate(&child.agent, app.approval_lender == child)) continue;
                try visit(app, child, context, body);
            }
        }

        /// Whether `agent`'s approval prompt no longer matches its worker: the
        /// worker waits on a decision the prompt doesn't show, or the prompt
        /// shows one the worker stopped waiting on. A waiting worker queues no
        /// event, so a hidden agent is visited for this too. `lent` counts
        /// its prompt as shown while main's screen holds it. A
        /// `/permissions remember` prompt isn't the worker's, so it doesn't
        /// count.
        fn approvalOutOfDate(agent: *agents.Agent, lent: bool) bool {
            const prompt = &agent.approval_prompt;
            const shown = lent or (prompt.isActive() and prompt.rule_management == null);
            return agent.worker.awaitsPermissionDecision() != shown;
        }

        /// Readies the subagent on screen for a turn the user starts there, as
        /// main always is: its worker running and its own session
        /// attached. While none of its turns is going it gets a run admitted
        /// for the user's turn, so its profile and main's live permissions
        /// limit that turn as they limit main's runs. While one is going, the
        /// text steers or follows it under that turn's run, as typing does on
        /// main. A subagent never runs a turn without a run.
        pub fn prepareOwnTurn(app: *App, agent: *AppAgent) !void {
            const child = app.agent_on_screen orelse return;
            // An instance takes its own turns as the first one does.
            if (child.agent.role == .instance) return;
            if (child.agent.worker_thread == null) _ = try ensureChild(app, child.id);
            if (!child.session_attached) try attachSession(app, agent, child);
            if (child.agent.child_run == null or !turnGoing(app, child)) try admitOwnTurn(app, agent, child);
            debug_trace.eventf("host", "input_routed", .{}, "agent={s}", .{child.id});
        }

        /// Gives `run` the user's earlier requests to the subagent in context,
        /// the verified evidence its permission reviewer weighs with the turn's
        /// own prompt: the turns the user typed, never the ones main sent,
        /// which carry main's work id. A compacted conversation may have
        /// dropped some, so its evidence is then incomplete.
        fn setUserRequests(app: *App, agent: *AppAgent, run: *agents.ChildRun) !void {
            var requests: std.ArrayList([]u8) = .empty;
            errdefer {
                for (requests.items) |text| app.alloc.free(text);
                requests.deinit(app.alloc);
            }
            var complete = true;
            for (agent.session.agent.history.items) |turn| {
                const user = switch (turn) {
                    .compacted_summary => {
                        complete = false;
                        continue;
                    },
                    .assistant => |entry| entry.user,
                    .interrupted => |entry| entry.user,
                };
                if (user.work_id != null) continue;
                try requests.append(app.alloc, try app.alloc.dupe(u8, user.text));
            }
            for (run.root_user_messages) |text| app.alloc.free(text);
            app.alloc.free(run.root_user_messages);
            run.root_user_messages = try requests.toOwnedSlice(app.alloc);
            run.root_user_evidence_complete = complete;
        }

        /// Installs a run admitted for a turn the user starts on `child`'s
        /// screen. None of `child`'s turns may be going: the new run replaces
        /// the one installed.
        fn admitOwnTurn(app: *App, agent: *AppAgent, child: *ChildAgent) !void {
            const host = hostOf(app, child) orelse return error.SubagentHostUnavailable;
            var admitted = try host.admitUserTurn(app.alloc, child.id, app_permission_runtime.Runtime(App).livePermissionSnapshot(app, &child.agent).mode);
            defer admitted.deinit(app.alloc);
            var run = try app_agent_runtime.Runtime(App).prepareOwnTurnRun(app, child.id, host.authorityResolver(), admitted.instructions, admitted.admission);
            errdefer run.deinit(app.alloc);
            try setUserRequests(app, agent, &run);
            // A user turn the last run opened and never saw end ends now.
            if (child.agent.child_run) |*previous| endUserWork(app.alloc, host, previous, .cancelled, "");
            // The turn is a work in the parent's log, as every child turn is.
            if (host.beginUserWork(app.alloc, child.id)) |work_id| run.user_work_id = work_id;
            installChildRun(app, child, run);
            debug_trace.eventf("host", "own_turn_admitted", .{}, "agent={s} model={s} permission_mode={s}", .{
                child.id,
                child.agent.child_run.?.admission.model,
                @tagName(child.agent.child_run.?.admission.permission_mode),
            });
        }

        /// The instance on screen, the first or a launched one, which the
        /// subagents of its tree lend their prompts to. Null while a subagent
        /// is on screen.
        fn instanceOnScreen(app: *App) ?*AppAgent {
            const on_screen = app.agent_on_screen orelse return &app.main_agent;
            return if (on_screen.agent.role == .instance) &on_screen.agent else null;
        }

        pub const PromptKind = enum { approval, question };

        /// Notes that subagent `agent`'s approval or question just showed,
        /// so its tree's prompts reach the instance's screen in the order
        /// they were asked.
        pub fn notePromptAsked(app: *App, agent: *const agents.Agent, kind: PromptKind) void {
            const child = for (app.child_agents.items) |child| {
                if (&child.agent == agent) break child;
            } else return;
            app.prompt_order += 1;
            switch (kind) {
                .approval => child.approval_asked = app.prompt_order,
                .question => child.question_asked = app.prompt_order,
            }
        }

        /// While an instance is on screen with no approval or question
        /// showing, the oldest one waiting in its tree, approval or
        /// question, is lent to the instance's prompt, so it shows on the
        /// instance's screen too. One is lent at a time, so the next shows
        /// once that one is answered or goes back. A rule a subagent's
        /// `/permissions remember` would save is its own, so it isn't lent.
        pub fn lendPrompt(app: *App) void {
            if (app.approval_lender != null or app.question_lender != null) return;
            const borrower = instanceOnScreen(app) orelse return;
            if (borrower.approval_prompt.isActive() or borrower.question_prompt.isActive()) return;
            var oldest: ?struct { child: *ChildAgent, kind: PromptKind, asked: u64 } = null;
            for (app.child_agents.items) |child| {
                if (!lendsTo(app, child, borrower)) continue;
                const approval = &child.agent.approval_prompt;
                if (approval.isActive() and approval.rule_management == null) {
                    if (oldest == null or child.approval_asked < oldest.?.asked) oldest = .{ .child = child, .kind = .approval, .asked = child.approval_asked };
                }
                if (child.agent.question_prompt.isActive()) {
                    if (oldest == null or child.question_asked < oldest.?.asked) oldest = .{ .child = child, .kind = .question, .asked = child.question_asked };
                }
            }
            const lent = oldest orelse return;
            switch (lent.kind) {
                .approval => lendApproval(app, borrower, lent.child),
                .question => lendQuestion(app, borrower, lent.child),
            }
            app.shell.render_requests.request(.modal);
        }

        /// Lends `child`'s question to `borrower`'s prompt, named for the
        /// subagent. It goes back before anything but the input that edits
        /// it touches it.
        fn lendQuestion(app: *App, borrower: *AppAgent, child: *ChildAgent) void {
            std.mem.swap(question_prompt.QuestionPrompt, &borrower.question_prompt, &child.agent.question_prompt);
            borrower.question_prompt.asker = child.displayName();
            app.question_lender = child;
            debug_trace.eventf("host", "question_lent", .{}, "agent={s}", .{child.id});
        }

        /// Gives a lent question back to the subagent that asked it, and
        /// returns that subagent.
        pub fn returnQuestion(app: *App) ?*ChildAgent {
            const child = app.question_lender orelse return null;
            const borrower = rootInstance(app, child);
            borrower.question_prompt.asker = "";
            std.mem.swap(question_prompt.QuestionPrompt, &borrower.question_prompt, &child.agent.question_prompt);
            app.question_lender = null;
            app.shell.render_requests.request(.modal);
            return child;
        }

        /// Ends a lent question its subagent no longer waits on, for
        /// example because its turn was cancelled.
        pub fn settleLentQuestion(app: *App) void {
            const child = app.question_lender orelse return;
            if (child.agent.worker.hasPendingQuestionBatch()) return;
            _ = returnQuestion(app);
            child.agent.question_prompt.discard(app.alloc, "owner_cleared");
        }

        /// Runs `body`, an answer or a cancel, in the context of the subagent
        /// whose question the instance's screen shows, so the answer reaches
        /// its worker and joins its conversation. False when the question is
        /// the instance's own.
        pub fn answerLentQuestion(app: *App, comptime body: fn (*App, *AppAgent) anyerror!void) !bool {
            const child = returnQuestion(app) orelse return false;
            const Answer = struct {
                fn run(_: void, a: *App, lender: *agents.Agent) anyerror!void {
                    try body(a, lender);
                }
            };
            try visit(app, child, {}, Answer.run);
            return true;
        }

        /// Lends `child`'s approval to `borrower`'s prompt. Its request comes
        /// from the subagent's own worker and stays labeled with its name.
        /// It goes back when the subagent is shown, the instance gets its
        /// own, or the subagent stops waiting (`keepLentApproval`).
        fn lendApproval(app: *App, borrower: *AppAgent, child: *ChildAgent) void {
            std.mem.swap(@TypeOf(child.agent.approval_prompt), &borrower.approval_prompt, &child.agent.approval_prompt);
            app.approval_lender = child;
            debug_trace.eventf("host", "approval_lent", .{}, "agent={s}", .{child.id});
        }

        /// Gives a lent approval back to the subagent it came from, and
        /// returns that subagent.
        pub fn returnApproval(app: *App) ?*ChildAgent {
            const child = app.approval_lender orelse return null;
            const borrower = rootInstance(app, child);
            std.mem.swap(@TypeOf(child.agent.approval_prompt), &borrower.approval_prompt, &child.agent.approval_prompt);
            app.approval_lender = null;
            app.shell.render_requests.request(.modal);
            return child;
        }

        /// Whether the agent in context keeps its approval prompt as it is
        /// this pass, because an approval is lent: the instance keeps the one
        /// it shows until its own request comes, and the subagent that lent
        /// it lets it be while its worker still asks the same thing.
        /// Otherwise the approval goes back first, and the caller syncs the
        /// prompt from the worker's `pending`. That includes an approval
        /// answered on the instance's screen, whose prompt is already
        /// cleared, so the next one of the tree can be lent.
        pub fn keepLentApproval(app: *App, agent: *AppAgent, pending: ?permission_request.PermissionRequest) bool {
            const lender = app.approval_lender orelse return false;
            const borrower = rootInstance(app, lender);
            if (agent == borrower) {
                if (pending == null) return true;
            } else if (agent == &lender.agent) {
                if (borrower.approval_prompt.request) |lent| {
                    if (pending) |request| if (request.id == lent.id) return true;
                }
            } else return false;
            _ = returnApproval(app);
            return false;
        }

        /// The subagent whose approval `agent`'s prompt shows, while that
        /// instance is in context: an answer there goes to that subagent's
        /// worker.
        pub fn lentApproval(app: *App, agent: *AppAgent) ?*ChildAgent {
            const lender = app.approval_lender orelse return null;
            if (agent != rootInstance(app, lender)) return null;
            return lender;
        }

        /// Runs `body`, a cancel, in the context of the subagent whose
        /// approval the instance's screen shows, as its own screen would.
        /// False when the approval is the instance's own.
        pub fn answerLentApproval(app: *App, agent: *AppAgent, comptime body: fn (*App, *AppAgent) anyerror!void) !bool {
            if (lentApproval(app, agent) == null) return false;
            const child = returnApproval(app).?;
            const Answer = struct {
                fn run(_: void, a: *App, lender: *agents.Agent) anyerror!void {
                    try body(a, lender);
                }
            };
            try visit(app, child, {}, Answer.run);
            return true;
        }

        /// Whether the agent list has an agent to switch to besides the one on
        /// screen. Brings in the subagents main's session started before a
        /// restart first.
        pub fn hasAnotherAgent(app: *App) bool {
            syncChildList(app) catch |err| {
                debug_trace.logf("host", "child list sync failed err={s}", .{@errorName(err)});
            };
            return openAgentCount(app) > 1;
        }

        /// How many agents are open: the instances, the first one included,
        /// and every subagent the app hosts.
        fn openAgentCount(app: *App) usize {
            return @as(usize, if (firstOpen(app)) 1 else 0) + app.child_agents.items.len;
        }

        /// Puts every subagent in the subagent host's registry in the switch
        /// list, in the order they started, so a subagent from before a
        /// restart can be shown too. One added here starts its
        /// worker on its first run.
        fn syncChildList(app: *App) !void {
            // Every instance's tree, a restored one's too (decision 20): the
            // first instance's host, then each later instance's own. Taken
            // first, since adding a child grows the list.
            var hosts: std.ArrayList(*subagent_tool_host.Runtime) = .empty;
            defer hosts.deinit(app.alloc);
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| try hosts.append(app.alloc, host);
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                for (app.child_agents.items) |hosted| {
                    if (hosted.agent.role != .instance) continue;
                    if (hosted.agent.session_persistence.subagent_host) |host| try hosts.append(app.alloc, host);
                }
            }
            const Listed = struct { id: []const u8 };
            var order: std.ArrayList(Listed) = .empty;
            defer order.deinit(app.alloc);
            var listings: std.ArrayList([]subagent_tool_host.Runtime.ChildListing) = .empty;
            defer {
                for (listings.items) |listing| subagent_tool_host.Runtime.freeChildListing(app.alloc, listing);
                listings.deinit(app.alloc);
            }
            for (hosts.items) |host| {
                const listing = try host.listChildren(app.alloc);
                listings.append(app.alloc, listing) catch |err| {
                    subagent_tool_host.Runtime.freeChildListing(app.alloc, listing);
                    return err;
                };
                for (listing) |entry| {
                    const child = findChild(app, entry.id) orelse try addChild(app, entry.id);
                    if (child.name.len == 0 and entry.name.len > 0) child.name = try app.alloc.dupe(u8, entry.name);
                    if (child.parent_host == null) setParentHost(app, child, host);
                    try order.append(app.alloc, .{ .id = entry.id });
                }
            }
            orderByListing(app.child_agents.items, order.items);
        }

        /// The agent list's rows, in order: the instances in launch order,
        /// the first one as null, each followed by the subagents in its tree
        /// in the order they started. With one instance this is main, then
        /// every subagent in start order, as before instances existed.
        pub fn switchList(app: *App, out: *std.ArrayList(?*ChildAgent)) !void {
            const hosted = app.child_agents.items;
            const entries = try app.alloc.alloc(OrderEntry, hosted.len);
            defer app.alloc.free(entries);
            for (hosted, entries) |child, *entry| entry.* = switch (child.agent.role) {
                .instance => .{ .role = .instance },
                .subagent => .{ .role = .subagent, .root = instanceOrdinal(app, rootInstance(app, child)) },
            };
            const order = try app.alloc.alloc(usize, hosted.len + 1);
            defer app.alloc.free(order);
            switchOrder(entries, order);
            try out.ensureUnusedCapacity(app.alloc, order.len);
            for (order) |position| {
                if (position == 0 and !firstOpen(app)) continue;
                out.appendAssumeCapacity(if (position == 0) null else hosted[position - 1]);
            }
        }

        /// How the waiting note names agent `child`, null for the first
        /// instance: an instance by its place, "fx 3", while several are
        /// open, else "main"; a subagent by its own name. May use `buf`.
        pub fn noteName(app: *App, child: ?*ChildAgent, buf: []u8) []const u8 {
            if (child) |value| if (value.agent.role == .subagent) return value.displayName();
            if (openInstanceCount(app) <= 1) return "main";
            const number = instanceNumber(app, child) orelse return "fx";
            return std.mem.print(buf, "fx {d}", .{number}) catch "fx";
        }

        /// Instance `child`'s place among the open instances, from 1, as
        /// the footer counts them; null `child` is the first instance.
        pub fn instanceNumber(app: *App, child: ?*ChildAgent) ?usize {
            var number: usize = 0;
            if (firstOpen(app)) {
                number += 1;
                if (child == null) return number;
            }
            for (app.child_agents.items) |value| {
                if (value.agent.role != .instance) continue;
                number += 1;
                if (value == child) return number;
            }
            return null;
        }

        /// Where a notice on a subagent's screen sends the user back to: the
        /// instance whose tree holds it, by the name the waiting note uses,
        /// and the key that opens the agent list to pick it. Null off a
        /// subagent's screen.
        pub const Home = struct { name: []const u8, key: []const u8 };

        pub fn homeOfScreen(app: *App, name_buf: []u8) ?Home {
            const child = app.agent_on_screen orelse return null;
            if (child.agent.role != .subagent) return null;
            return .{ .name = noteName(app, screenInstance(app), name_buf), .key = switchKey(app) };
        }

        /// The instance on screen, or the one whose tree holds the subagent
        /// on screen; null for the first instance.
        fn screenInstance(app: *App) ?*ChildAgent {
            const child = app.agent_on_screen orelse return null;
            if (child.agent.role != .subagent) return child;
            const root = rootInstance(app, child);
            if (root == &app.main_agent) return null;
            for (app.child_agents.items) |entry| if (&entry.agent == root) return entry;
            return null;
        }

        /// The footer note for a hidden agent waiting on the user, such as
        /// "reviewer needs approval", or the finished note, or empty. It
        /// waits on an approval, a question, or a request only the user can
        /// continue, such as one out of credits. The footer follows it with
        /// the agent indicator, which names the key that opens the agent
        /// list. fx never switches on its own. `buf` backs the returned text.
        pub fn waitingNote(app: *App, buf: []u8) []const u8 {
            // The first waiting agent the note names, null for the first
            // instance, which `main_agent` holds.
            var first: ?*ChildAgent = null;
            var found = false;
            var state: InstanceState = .needs_approval;
            var count: usize = 0;
            if (app.agent_on_screen != null and firstOpen(app)) {
                // Main's own request, not a subagent's that main also shows.
                const main_waiting = if (app.main_agent.approval_prompt.request) |request|
                    request.origin == .active_session
                else
                    false;
                const asks = app.main_agent.question_prompt.isActive();
                if (main_waiting or asks or requestWaitsForUser(app, null)) {
                    found = true;
                    state = if (main_waiting) .needs_approval else if (asks) .has_question else .needs_you;
                    count += 1;
                }
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                const approval = child.agent.approval_prompt.isActive();
                const asks = child.agent.question_prompt.isActive();
                if (!approval and !asks and !requestWaitsForUser(app, child)) continue;
                if (!found) {
                    first = child;
                    found = true;
                    state = if (approval) .needs_approval else if (asks) .has_question else .needs_you;
                }
                count += 1;
            }
            if (!found) return finishedNote(app, buf);
            var name_buf: [32]u8 = undefined;
            const name = noteName(app, first, &name_buf);
            return if (count > 1)
                std.mem.print(buf, "{s} and {d} more need you", .{ name, count - 1 }) catch ""
            else
                std.mem.print(buf, "{s} {s}", .{ name, state.label() }) catch "";
        }

        /// The key that opens the agent list from the composer as it is now:
        /// ↓ while it is idle, else Ctrl+X.
        pub fn switchKey(app: *App) []const u8 {
            return if (composerIdle(app)) "↓" else "ctrl+x";
        }

        /// Whether ↓ in the composer opens the agent list: nothing typed,
        /// pasted, or attached, and no prompt recalled from history, where ↓
        /// moves forward through history instead.
        pub fn composerIdle(app: *App) bool {
            if (comptime !@hasField(App, "input_runtime")) return true;
            const input = &app.input_runtime;
            if (input.edit_state.input.items.len > 0) return false;
            if (input.entities.pasted_blocks.items.len > 0) return false;
            if (agents.screenAgentOf(app).pending_images.items.len > 0) return false;
            return input.composer_history.activeIndex() == null;
        }

        fn positionIn(order: []const ?*ChildAgent, agent: ?*ChildAgent) ?usize {
            for (order, 0..) |value, index| if (value == agent) return index;
            return null;
        }

        fn targetAgent(app: *App, target: ?*ChildAgent) *AppAgent {
            return if (target) |child| &child.agent else &app.main_agent;
        }

        /// Notes, after each tick, every instance one of whose turns ended
        /// while it wasn't on screen, until it is shown. Redraws the footer
        /// when one starts or ends a turn, for its note and the list.
        pub fn noteFinishedTurns(app: *App) void {
            var changed = false;
            if (firstOpen(app)) changed = noteFinished(&app.main_agent, app.agent_on_screen == null) or changed;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                changed = noteFinished(&child.agent, child == app.agent_on_screen) or changed;
            }
            if (changed) app.shell.render_requests.request(.footer);
        }

        /// Updates `agent`'s marks; whether either changed.
        fn noteFinished(agent: *AppAgent, on_screen: bool) bool {
            const going = turnInFlight(agent);
            const finished = if (on_screen) false else agent.finished_unseen or (agent.was_working and !going);
            const changed = going != agent.was_working or finished != agent.finished_unseen;
            agent.was_working = going;
            agent.finished_unseen = finished;
            return changed;
        }

        /// The footer note for hidden instances whose turns ended since they
        /// were last shown, such as "fx 7 finished", or empty. Only while
        /// several instances are open.
        pub fn finishedNote(app: *App, buf: []u8) []const u8 {
            if (openInstanceCount(app) <= 1) return "";
            var first: ?*ChildAgent = null;
            var found = false;
            var count: usize = 0;
            if (firstOpen(app) and app.agent_on_screen != null and app.main_agent.finished_unseen) {
                found = true;
                count += 1;
            }
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance or child == app.agent_on_screen or !child.agent.finished_unseen) continue;
                if (!found) first = child;
                found = true;
                count += 1;
            }
            if (!found) return "";
            var name_buf: [32]u8 = undefined;
            const name = noteName(app, first, &name_buf);
            return if (count > 1)
                std.mem.print(buf, "{s} and {d} more finished", .{ name, count - 1 }) catch ""
            else
                std.mem.print(buf, "{s} finished", .{name}) catch "";
        }

        pub fn menuActive(app: *App) bool {
            if (comptime !@hasField(App, "instances")) return false;
            return app.instances.agents_menu.open;
        }

        /// Opens the agent list on the agent on screen, which Esc and Ctrl+X
        /// go back to.
        pub fn openMenu(app: *App) !void {
            if (comptime !@hasField(App, "instances")) return;
            syncChildList(app) catch |err| {
                debug_trace.logf("host", "child list sync failed err={s}", .{@errorName(err)});
            };
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const menu = &app.instances.agents_menu;
            menu.selected = positionIn(order.items, app.agent_on_screen) orelse 0;
            menu.window_start = 0;
            menu.origin = app.agent_on_screen;
            menu.open = true;
            debug_trace.eventf("host", "agents_menu_opened", .{}, "agents={d} position={d} agent={s}", .{
                order.items.len,
                menu.selected + 1,
                nameOf(app.agent_on_screen),
            });
            app.shell.render_requests.request(.footer);
        }

        /// Closes the list, keeping on screen the agent it shows. Another
        /// surface taking the footer closes it this way.
        pub fn closeMenu(app: *App) bool {
            if (!menuActive(app)) return false;
            endMenu(app);
            debug_trace.eventf("host", "agents_menu_closed", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        fn endMenu(app: *App) void {
            const menu = &app.instances.agents_menu;
            menu.open = false;
            menu.origin = null;
            app.shell.render_requests.request(.footer);
        }

        /// Esc and Ctrl+X: closes the list and puts back the agent it opened
        /// on. If that agent closed meanwhile, the one shown stays.
        pub fn backMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            const origin = app.instances.agents_menu.origin;
            endMenu(app);
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (positionIn(order.items, origin) != null) {
                try show(app, origin);
            } else {
                debug_trace.logf("host", "agents menu origin closed; keeping agent={s}", .{nameOf(app.agent_on_screen)});
            }
            debug_trace.eventf("host", "agents_menu_back", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        /// Moves the list's selection by `delta`, keeping it in view in
        /// `row_budget` rows, and shows the agent it lands on: the list
        /// previews by switching.
        pub fn moveMenu(app: *App, delta: i32, row_budget: u16) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return true;
            const menu = &app.instances.agents_menu;
            const last: i64 = @intCast(order.items.len - 1);
            const current: i64 = @intCast(@min(menu.selected, order.items.len - 1));
            menu.selected = @intCast(std.math.clamp(current + delta, 0, last));
            menu.window_start = agents_menu_presentation.windowStart(menuProjection(app), row_budget);
            app.shell.render_requests.request(.footer);
            const target = order.items[menu.selected];
            if (target == app.agent_on_screen) return true;
            try show(app, target);
            debug_trace.eventf("host", "agents_menu_previewed", .{}, "position={d} agent={s}", .{ menu.selected + 1, nameOf(target) });
            return true;
        }

        /// Enter: closes the list, keeping the agent it shows.
        pub fn submitMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const selected = app.instances.agents_menu.selected;
            endMenu(app);
            // The preview already shows the selected agent; a list that
            // changed under it shows it now.
            if (order.items.len > 0) {
                const chosen = order.items[@min(selected, order.items.len - 1)];
                if (chosen != app.agent_on_screen) try show(app, chosen);
            }
            debug_trace.eventf("host", "agents_menu_chosen", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        /// The agent list as the footer draws it now, or an inactive one.
        pub fn menuProjection(app: *App) render_input.AgentsMenuProjection {
            if (!menuActive(app)) return .{};
            const menu = &app.instances.agents_menu;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            switchList(app, &order) catch return .{};
            menu.rows.clearRetainingCapacity();
            menu.rows.ensureTotalCapacity(app.alloc, order.items.len) catch return .{};
            // Instances come in launch order, so each one's number is the
            // count of instance rows so far.
            var number: usize = 0;
            for (order.items) |target| {
                const agent = targetAgent(app, target);
                const subagent: ?*ChildAgent = if (target) |child| (if (child.agent.role == .subagent) child else null) else null;
                if (subagent == null) number += 1;
                menu.rows.appendAssumeCapacity(.{
                    .number = if (subagent == null) number else 0,
                    .subagent_name = if (subagent) |child| child.displayName() else "",
                    .title = agent.session_title.items,
                    .profile = agent.profile.profile.name,
                    .state = instanceState(agent, requestWaitsForUser(app, target)).label(),
                    .on_screen = target == menu.origin,
                });
            }
            if (menu.selected >= menu.rows.items.len) menu.selected = menu.rows.items.len -| 1;
            return .{ .rows = menu.rows.items, .selected = menu.selected, .window_start = menu.window_start };
        }

        /// Whether the first instance, kept in `main_agent`, still runs.
        pub fn firstOpen(app: anytype) bool {
            if (comptime !@hasField(App, "instances")) return true;
            return app.instances.first_open;
        }

        /// The first instance still open: `main_agent` until it closes, then
        /// the earliest launched one still running. Everything that
        /// means "the first instance" asks here. Null only once every
        /// instance has closed, while the host ends.
        pub fn firstInstance(app: anytype) ?*AppAgent {
            if (firstOpen(app)) return &app.main_agent;
            for (app.child_agents.items) |child| if (child.agent.role == .instance) return &child.agent;
            return null;
        }

        /// How many instances are open, the first one included.
        pub fn openInstanceCount(app: *App) usize {
            var count: usize = if (firstOpen(app)) 1 else 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role == .instance) count += 1;
            }
            return count;
        }

        /// Instance `agent`'s place in launch order: 0 for the first.
        fn instanceOrdinal(app: *App, agent: *const AppAgent) usize {
            var ordinal: usize = 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                ordinal += 1;
                if (&child.agent == agent) return ordinal;
            }
            return 0;
        }

        /// The footer's agent indicator, on its right: the agent on screen
        /// and the key that opens the agent list, such as "fx 2/3 ↓", or
        /// "fx 2/3 · ctrl+x" while the composer holds a draft. A subagent
        /// shows its own label, and the first instance alone with subagents
        /// shows "main". Empty with a single agent, as before instances
        /// existed. Valid until the next call.
        pub fn footerIndicator(app: *App) []const u8 {
            if (openAgentCount(app) <= 1) return "";
            var name_buf: [32]u8 = undefined;
            const name = footerName(app, &name_buf);
            const key = switchKey(app);
            const separator = if (composerIdle(app)) " " else " · ";
            return std.mem.print(&app.instances.label_buf, "{s}{s}{s}", .{ name, separator, key }) catch key;
        }

        /// The agent on screen as the indicator names it: a subagent's own
        /// label, else the instance's place among the instances while
        /// there are several, else "main". May use `buf`.
        fn footerName(app: *App, buf: []u8) []const u8 {
            if (app.agent_on_screen) |child| if (child.agent.role == .subagent) return child.footerLabel();
            const total = openInstanceCount(app);
            if (total <= 1) return "main";
            const position = instanceNumber(app, app.agent_on_screen) orelse 1;
            return std.mem.print(buf, "fx {d}/{d}", .{ position, total }) catch "fx";
        }

        /// The instance whose tree subagent `child` is in: the one that
        /// started it, or started the subagent that did.
        pub fn rootInstance(app: *App, child: *const ChildAgent) *AppAgent {
            var current = child;
            while (true) {
                const owner = ownerOf(app, hostOf(app, current)) orelse return &app.main_agent;
                if (owner == &app.main_agent) return owner;
                const hosted = hostedOf(app, owner) orelse return &app.main_agent;
                if (hosted.agent.role == .instance) return owner;
                current = hosted;
            }
        }

        /// The agent whose own subagent host is `host`.
        fn ownerOf(app: *App, host: ?*subagent_tool_host.Runtime) ?*AppAgent {
            const wanted = host orelse return null;
            if (app_session_runtime.Runtime(App).ownSubagentHost(&app.main_agent) == wanted) return &app.main_agent;
            for (app.child_agents.items) |child| {
                if (app_session_runtime.Runtime(App).ownSubagentHost(&child.agent) == wanted) return &child.agent;
            }
            return null;
        }

        fn hostedOf(app: *App, agent: *const AppAgent) ?*ChildAgent {
            for (app.child_agents.items) |child| if (&child.agent == agent) return child;
            return null;
        }

        /// A subagent's approval or question is lent to an instance's screen
        /// only when that instance's tree holds it: an instance's are its
        /// own, and a subagent of another instance belongs to that one.
        fn lendsTo(app: *App, child: *const ChildAgent, borrower: *const AppAgent) bool {
            return child.agent.role == .subagent and rootInstance(app, child) == borrower;
        }

        /// Puts `target`, or main when null, on screen, then clears the
        /// terminal and redraws the arriving agent's conversation from the top.
        /// Neither agent's work stops.
        pub fn show(app: *App, target: ?*ChildAgent) !void {
            const from = app.agent_on_screen;
            if (from == target) return;
            attach(app, target);
            if (target) |child| {
                if (!child.view_built) buildSavedView(app, agents.screenAgentOf(app), child);
                // Its own session, so what changes on its screen, such as its
                // model, is saved to it, as in a second fx. Its worker
                // still starts with its first message.
                if (!child.session_attached) attachSession(app, agents.screenAgentOf(app), child) catch |err| {
                    debug_trace.logf("host", "session not opened on show agent={s} err={s}", .{ child.id, @errorName(err) });
                };
            }
            debug_trace.eventf("host", "agent_switched", .{}, "agent={s} from={s}", .{ nameOf(target), nameOf(from) });
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
            debug_trace.eventf("host", "screen_reprinted", .{}, "agent={s} entries={d}", .{
                nameOf(target),
                app.shell.notebook.entries.items.len,
            });
        }

        /// Builds the view of a subagent shown before it has run in this
        /// process from its saved conversation. Runs with it on screen.
        /// The first view of the subagent in context, as a second fx would
        /// open it: its saved conversation, as on resume, or fx's welcome when
        /// it has none yet, as on a fresh start.
        fn buildView(app: *App, agent: *AppAgent, history: []const types.HistoryTurn) !void {
            if (history.len > 0) return app_session_runtime.Runtime(App).rebuildChildView(app, agent, history);
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);
            try app.writeTranscriptClassified(welcome, true, .welcome);
        }

        fn buildSavedView(app: *App, agent: *AppAgent, child: *ChildAgent) void {
            child.view_built = true;
            // An instance holds its own conversation, as the first one does,
            // so its first view comes from it. Only a subagent's is read from
            // the host that started it.
            if (child.agent.role == .instance) {
                buildView(app, agent, child.agent.session.agent.history.items) catch |err| {
                    debug_trace.logf("host", "instance view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                };
                return;
            }
            const host = hostOf(app, child) orelse return;
            const history = host.childHistory(app.alloc, child.id) catch |err| {
                debug_trace.logf("host", "saved view unavailable agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            defer types.freeHistoryTurnSlice(app.alloc, history);
            buildView(app, agent, history) catch |err| {
                debug_trace.logf("host", "saved view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            debug_trace.eventf("host", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ child.id, history.len });
        }

        /// Moves the composer's draft and the screen's transcript and paced
        /// text back to the agent leaving, takes the arriving agent's out of
        /// its slot, and makes it the loop's agent in context. Paints nothing.
        fn attach(app: *App, target: ?*ChildAgent) void {
            // A question or approval lent to main goes back first, to show on
            // its own subagent's screen.
            _ = returnQuestion(app);
            _ = returnApproval(app);
            const leaving = screenOf(app, app.agent_on_screen);
            const arriving = screenOf(app, target);
            if (leaving == arriving) return;
            leaving.draft = composer_stash.State.capture(app.input_runtime.composerStashView());
            app.shell.swapSlot(&leaving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &leaving.pacer);
            std.mem.swap(bool, &app.fast_mode, &leaving.fast_mode);
            app.shell.swapSlot(&arriving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &arriving.pacer);
            std.mem.swap(bool, &app.fast_mode, &arriving.fast_mode);
            arriving.draft.restore(app.alloc, app.input_runtime.composerStashView());
            app.agent_on_screen = target;
            app.screen_owner = if (target) |child| &child.agent else null;
        }

        /// Whether a turn of `child`'s is going, its paced output included. A
        /// turn reads the run installed on the agent until its last event is
        /// applied, so nothing replaces that run before then.
        fn turnGoing(app: *App, child: *ChildAgent) bool {
            const pacer = if (app.agent_on_screen == child) &app.pacer else &child.screen.pacer;
            return child.workGoing() or pacer.hasPending();
        }

        fn screenOf(app: *App, child: ?*ChildAgent) *ScreenSlot {
            return if (child) |value| &value.screen else &app.main_screen;
        }

        /// Whether agent `target`'s status row, null for the first instance,
        /// shows a request that waits for the user: the screen's row for the
        /// agent on it, the one kept with its transcript for a hidden one.
        fn requestWaitsForUser(app: *App, target: ?*ChildAgent) bool {
            if (target == app.agent_on_screen) {
                if (comptime !@hasDecl(@TypeOf(app.shell), "worker_status_state")) return false;
                return app.shell.worker_status_state().waitsForUser();
            }
            return screenOf(app, target).transcript.notebook.worker_status.waitsForUser();
        }

        fn nameOf(child: ?*ChildAgent) []const u8 {
            return if (child) |value| value.id else "main";
        }

        /// Stops every child agent and closes its session, each in its own
        /// context: its worker stops and is joined, its last finished turns are
        /// saved, its session closes, and its state is freed. Runs before main's
        /// persistence closes, because a child borrows main's session store.
        /// The list is in start order, so walking it backwards closes each
        /// subagent's own subagents before it.
        pub fn shutdownChildren(app: *App) void {
            attach(app, null);
            closeHandoffs(app);
            var index = app.child_agents.items.len;
            while (index > 0) {
                index -= 1;
                const child = app.child_agents.items[index];
                visit(app, child, {}, shutdownInContext) catch |err| {
                    app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
                };
            }
            // Each run still in flight ended once its worker was joined; its
            // slot thread holds the worker until it frees the turn context.
            for (app.child_agents.items) |child| {
                if (!child.bound.waitReleased(release_timeout_ms)) {
                    debug_trace.logf("host", "child_release_timeout child={s} at=shutdown", .{child.id});
                }
            }
        }

        /// Stops every child agent's worker and ends each run in flight. Runs
        /// before main's worker is joined, because main's worker can be
        /// waiting on a subagent call, which waits for its run to end. Each
        /// worker is joined before its run ends, so no worker still uses the
        /// run's turn context once the slot thread frees it.
        pub fn stopChildren(app: *App, comptime mode: enum { cooperative, force }) void {
            // Main's own shutdown writes to its transcript, so it goes back on
            // screen first.
            attach(app, null);
            closeHandoffs(app);
            for (app.child_agents.items) |child| {
                child.agent.worker.requestCancel();
                child.agent.worker.requestShutdown();
                switch (mode) {
                    .cooperative => child.agent.managed_executions.shutdown(),
                    .force => child.agent.managed_executions.terminateForProcessExit(),
                }
            }
            for (app.child_agents.items) |child| {
                if (child.agent.worker_thread) |thread| thread.join();
                child.agent.worker_thread = null;
                if (child.agent.child_run) |*run| finishRun(run, .cancelled);
            }
        }

        /// Closes the hand-offs at shutdown, releasing every slot thread still
        /// waiting for a hand-off.
        fn closeHandoffs(app: *App) void {
            app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_handoffs.mutex.unlock(io_mod.getIo());
            app.child_handoffs.closed = true;
            for (app.child_handoffs.posts.items) |post| post.settle(.closed);
            app.child_handoffs.posts.clearRetainingCapacity();
            for (app.child_handoffs.reports.items) |post| {
                debug_trace.eventf("host", "child_delivery_dropped", .{}, "child={s} work_id={s} reason=shutdown", .{ post.child_id, post.work_id });
                post.destroy();
            }
            app.child_handoffs.reports.clearRetainingCapacity();
        }

        /// Gives each posted delivery to its agent, in the order they were
        /// posted (`App.postAgentMessage`). One whose agent is gone is
        /// dropped; a report stays owed in the log.
        fn deliverReports(app: *App) void {
            var posted: std.ArrayList(*ReportPost) = .empty;
            {
                app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
                defer app.child_handoffs.mutex.unlock(io_mod.getIo());
                if (app.child_handoffs.closed) return;
                std.mem.swap(std.ArrayList(*ReportPost), &posted, &app.child_handoffs.reports);
            }
            defer posted.deinit(handoff_alloc);
            for (posted.items) |post| {
                defer post.destroy();
                deliverReport(app, post) catch |err| {
                    debug_trace.eventf("host", "child_delivery_dropped", .{}, "child={s} work_id={s} kind={s} reason={s}", .{ post.child_id, post.work_id, @tagName(post.kind), @errorName(err) });
                };
            }
        }

        /// The agent a subagent's delivery from `host` goes to: the host's
        /// owner, or with `from_owner` that owner's own parent. Call with
        /// `authority_mutex` held, or on the main loop.
        fn receiverOf(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) ?*AppAgent {
            const owner = ownerOf(app, host) orelse return null;
            if (!from_owner) return owner;
            const child = hostedOf(app, owner) orelse return null;
            return ownerOf(app, hostOf(app, child));
        }

        /// Holds a place for a subagent's message in the queue it goes to,
        /// on the subagent's thread, so a full queue refuses it while its
        /// call waits (`Mailbox.tla` `Refuse`). `deliverReport` uses the
        /// place; `releaseMessagePlace` gives it back.
        pub fn reserveMessagePlace(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) subagent_tool_host.PostReportError!void {
            const receiver = blk: {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                break :blk receiverOf(app, host, from_owner) orelse return error.AgentGone;
            };
            // The receiver outlives the sender's call: a tree closes its
            // subagents' threads before the agents that started them.
            if (!receiver.worker.reserveAgentMessage()) return error.QueueFull;
        }

        pub fn releaseMessagePlace(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) void {
            const receiver = blk: {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                break :blk receiverOf(app, host, from_owner) orelse return;
            };
            receiver.worker.releaseAgentMessage();
        }

        fn deliverReport(app: *App, post: *ReportPost) !void {
            const message = post.kind == .message;
            const target = receiverOf(app, post.host, message and post.from_owner) orelse return error.AgentGone;
            // A message sent by the owner names the owner, its own subagent.
            const sender = if (message and post.from_owner) blk: {
                const owner = ownerOf(app, post.host) orelse return error.AgentGone;
                const child = hostedOf(app, owner) orelse return error.AgentGone;
                break :blk if (child.name.len > 0) child.name else child.id;
            } else post.agent;
            const limit = target.worker.effectiveAgentTurnSettings().max_tool_result_bytes;
            const text = switch (post.kind) {
                .report => try subagent_reports.message(app.alloc, .{
                    .agent = sender,
                    .child_id = post.child_id,
                    .work_id = post.work_id,
                    .outcome = post.outcome,
                    .output = post.text,
                    .dropped = post.dropped,
                }, limit),
                .message => subagent_reports.messageText(app.alloc, sender, post.child_id, post.text, limit) catch |err| {
                    target.worker.releaseAgentMessage();
                    return err;
                },
            };
            defer app.alloc.free(text);
            try app.postAgentMessage(target, text, .child, if (message) .message else .report);
            debug_trace.eventf("host", "child_delivery_posted", .{}, "child={s} work_id={s} kind={s}", .{ post.child_id, post.work_id, @tagName(post.kind) });
        }

        /// Takes every waiting hand-off. Runs on the main loop each pass,
        /// before the children's events are handled.
        pub fn takePosts(app: *App) void {
            deliverReports(app);
            var posts: std.ArrayList(*Post) = .empty;
            {
                app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
                defer app.child_handoffs.mutex.unlock(io_mod.getIo());
                if (app.child_handoffs.closed) return;
                std.mem.swap(std.ArrayList(*Post), &posts, &app.child_handoffs.posts);
            }
            defer posts.deinit(handoff_alloc);
            var held: std.ArrayList(*Post) = .empty;
            defer held.deinit(handoff_alloc);
            for (posts.items) |post| {
                // A run waits while a turn of its child's is going: the run
                // replaces the child's installed run, which that turn reads.
                if (post.run != null) if (findChild(app, post.turn.child_id orelse "")) |child| if (turnGoing(app, child)) {
                    held.append(handoff_alloc, post) catch {
                        debug_trace.eventf("host", "child_handoff_failed", .{}, "agent={s} kind=run reason=OutOfMemory", .{child.id});
                        post.settle(.failed);
                        continue;
                    };
                    if (!post.held) debug_trace.eventf("host", "child_run_held", .{}, "agent={s} reason=turn_going", .{child.id});
                    post.held = true;
                    continue;
                };
                const kind = if (post.run == null) "bind" else "run";
                const taken = if (post.run == null) bindPost(app, post) else startPost(app, post);
                if (taken) |_| {
                    post.settle(.taken);
                } else |err| {
                    debug_trace.eventf("host", "child_handoff_failed", .{}, "agent={s} kind={s} reason={s}", .{ post.turn.child_id orelse "", kind, @errorName(err) });
                    post.settle(.failed);
                }
            }
            if (held.items.len == 0) return;
            // Back at the front, in order, to be offered again next pass.
            app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_handoffs.mutex.unlock(io_mod.getIo());
            if (app.child_handoffs.closed) {
                for (held.items) |post| post.settle(.closed);
            } else app.child_handoffs.posts.insertSlice(handoff_alloc, 0, held.items) catch {
                for (held.items) |post| post.settle(.failed);
            };
        }

        /// Records the host that started `child`: an instance's, or its
        /// parent subagent's own, and the instance at the top of its tree.
        /// Resolvers on other threads read both under main's authority lock.
        fn setParentHost(app: *App, child: *ChildAgent, host: *subagent_tool_host.Runtime) void {
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            child.parent_host = host;
            if (child.agent.root_instance == null) child.agent.root_instance = rootInstance(app, child);
        }

        /// The host whose resolver is `resolver`: main's, or one of the
        /// subagents' own.
        fn hostWithResolver(app: *App, resolver: *subagent_authority.Resolver) ?*subagent_tool_host.Runtime {
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| if (host.authorityResolver() == resolver) return host;
            for (app.child_agents.items) |child| {
                const host = child.agent.session_persistence.subagent_host orelse continue;
                if (host.authorityResolver() == resolver) return host;
            }
            return null;
        }

        /// The host that started `child`, where its session and history
        /// are: main's unless a subagent of main's started it.
        fn hostOf(app: *App, child: *const ChildAgent) ?*subagent_tool_host.Runtime {
            return child.parent_host orelse app_session_runtime.Runtime(App).subagentHost(app);
        }

        /// Binds a run's turn to its child's agent, started on first use, so
        /// cancel, steering, and approvals reach that agent's worker.
        fn bindPost(app: *App, post: *Post) !void {
            const child = try ensureChild(app, post.turn.child_id orelse return error.ChildNotAttached);
            if (post.turn.live_authority) |resolver| if (hostWithResolver(app, resolver)) |host| setParentHost(app, child, host);
            child.bound.hold();
            post.turn.hosted_worker = &child.agent.worker;
            post.turn.hosted_release = &child.bound;
        }

        /// Starts a bound run on its child's agent: the agent takes the run,
        /// its conversation is restored from the child's log, and the message
        /// is sent as if typed.
        fn startPost(app: *App, post: *Post) !void {
            const child = findChild(app, post.turn.child_id orelse return error.ChildNotAttached) orelse
                return error.ChildNotAttached;
            if (child.agent.child_run) |*run| if (run.inFlight()) return error.ChildBusy;
            if (child.name.len == 0) if (post.turn.child_name) |name| {
                child.name = try app.alloc.dupe(u8, name);
            };
            installChildRun(app, child, post.run.?);
            post.run = null;
            const start: Start = .{ .post = post, .child = child };
            visit(app, child, start, startInContext) catch |err| {
                finishRun(&child.agent.child_run.?, .failed);
                return err;
            };
            debug_trace.eventf("host", "child_run_started", .{}, "agent={s} work_id={s}", .{ child.id, child.agent.child_run.?.work_id });
        }

        const Start = struct { post: *Post, child: *ChildAgent };

        /// Opens the child's session, with the same recovery as a run's
        /// open, and attaches it to the child's agent in context, which saves
        /// every later turn through it as main does.
        fn attachSession(app: *App, agent: *AppAgent, child: *ChildAgent) !void {
            // A cooperative host starts no subagents (`startAgentWorkerThread`).
            if (comptime app_process_runtime.cooperativeHost(App)) return error.SubagentHostUnavailable;
            const host = hostOf(app, child) orelse return error.SubagentHostUnavailable;
            const session = try host.openChildSession(child.id);
            try app_session_runtime.Runtime(App).attachChildV2Session(app, agent, session);
            child.session_attached = true;
            debug_trace.eventf("host", "child_session_opened", .{}, "agent={s} turns={d}", .{ child.id, agent.session.agent.history.items.len });
        }

        fn startInContext(start: Start, app: *App, agent: *agents.Agent) anyerror!void {
            const post = start.post;
            if (!start.child.session_attached) try attachSession(app, agent, start.child);
            // The child's own session holds its conversation. The first
            // run in this process shows it, after a restart too.
            if (!start.child.view_built) {
                const history = agent.session.agent.history.items;
                try buildView(app, agent, history);
                start.child.view_built = true;
                debug_trace.eventf("host", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ start.child.id, history.len });
            }
            // The worker writes the message's card when its turn begins. The
            // turn carries main's work id, so it is saved with it.
            agent.prompt_work_id = start.child.agent.child_run.?.work_id;
            defer agent.prompt_work_id = null;
            if (!try app.enqueuePrompt(agent, post.message)) return error.PromptNotAdmitted;
        }

        /// The agent for child session `id`, its worker started on first use.
        fn ensureChild(app: *App, id: []const u8) !*ChildAgent {
            const child = findChild(app, id) orelse try addChild(app, id);
            if (child.agent.worker_thread == null) {
                try app_process_runtime.Runtime(App).startAgentWorkerThread(app, &child.agent);
                debug_trace.eventf("host", "agent_started", .{}, "agent={s}", .{id});
            }
            return child;
        }

        /// Adds the agent for child session `id` to the end of the list,
        /// with no worker yet.
        fn addChild(app: *App, id: []const u8) !*ChildAgent {
            const child = try app.alloc.create(ChildAgent);
            errdefer app.alloc.destroy(child);
            child.* = .{ .id = try app.alloc.dupe(u8, id), .agent = .{ .app = @ptrCast(app), .role = .subagent } };
            errdefer app.alloc.free(child.id);
            {
                // Resolvers on other threads read the list.
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                try app.child_agents.append(app.alloc, child);
            }
            // Registered here, with main as its parent, rather than by its
            // worker's first event.
            debug_trace.eventf("host", "agent_registered", .{}, "agent={s} parent=main", .{child.id});
            child.agent.worker.trace_agent = child.id;
            child.agent.worker.trace_registered = true;
            child.agent.worker.hands_back_leftover_feedback = true;
            return child;
        }

        /// Adds a new top-level instance, last among the hosted agents, with a
        /// placeholder id until its session names it.
        pub fn addInstance(app: *App) !*ChildAgent {
            const child = try app.alloc.create(ChildAgent);
            errdefer app.alloc.destroy(child);
            child.* = .{ .id = try app.alloc.dupe(u8, "instance"), .agent = .{ .app = @ptrCast(app), .role = .instance } };
            errdefer app.alloc.free(child.id);
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            try app.child_agents.append(app.alloc, child);
            return child;
        }

        /// Names instance `child` by its session's id and registers it in the
        /// trace, with the host as its parent.
        pub fn nameInstance(app: *App, child: *ChildAgent, session_id: ?[]const u8) !void {
            const id = try app.alloc.dupe(u8, session_id orelse "instance");
            app.alloc.free(child.id);
            child.id = id;
            child.agent.worker.trace_agent = child.id;
            child.agent.worker.trace_registered = true;
            debug_trace.eventf("host", "agent_registered", .{}, "agent={s} parent=host", .{child.id});
        }

        /// Closes instance `child` and every subagent in its tree: their
        /// workers stop, a run in flight ends cancelled, and their sessions
        /// are saved and closed, each subagent's before the agent that started
        /// it. When one of
        /// them is on screen, the next instance is shown first. The rest of
        /// the host keeps running.
        pub fn closeInstance(app: *App, child: *ChildAgent) !void {
            try closeTree(app, &child.agent, child, nextInstanceAfter(app, child), child.id);
            dropHosted(app, child);
        }

        /// Closes the first instance and every subagent in its tree, as
        /// `closeInstance` closes a launched one. The next instance in launch
        /// order takes over, the host keeps running, and the first's slot
        /// stays closed. Call only while
        /// another instance runs.
        pub fn closeFirstInstance(app: *App) !void {
            const next = instanceAfterFirst(app) orelse return error.LastInstance;
            const first = &app.main_agent;
            try closeTree(app, first, null, next, "first");
            visitScreen(app, first, &app.main_screen, {}, shutdownInContext) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(&next.agent, err);
            };
            app.main_screen.deinit(app.alloc);
            app.main_screen = .{};
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            app.instances.first_open = false;
            app.permission_state.authority_mutex.unlock(io_mod.getIo());
        }

        /// Moves a resume request made on a subagent's screen to the instance
        /// whose tree holds it, whose session is the one to resume. A plain
        /// request on an instance that has saved nothing moves on to the
        /// first open instance that has, because resuming any session of
        /// the host brings its whole group back.
        pub fn liftResumeIntent(app: *App) void {
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent) continue;
                const intent = child.agent.session_persistence.resume_handoff_intent;
                if (intent == .none) continue;
                child.agent.session_persistence.resume_handoff_intent = .none;
                rootInstance(app, child).session_persistence.resume_handoff_intent = intent;
            }
            var holder: ?*AppAgent = null;
            var saved: ?*AppAgent = null;
            if (firstOpen(app)) noteResumeCandidate(&app.main_agent, &holder, &saved);
            for (app.child_agents.items) |child| {
                if (child.agent.role == .instance) noteResumeCandidate(&child.agent, &holder, &saved);
            }
            const from = holder orelse return;
            const to = saved orelse return;
            if (from == to or app_session_runtime.Runtime(App).savedSessionId(from) != null) return;
            from.session_persistence.resume_handoff_intent = .none;
            to.session_persistence.resume_handoff_intent = .requested;
            debug_trace.logf("host", "resume_intent_moved reason=unsaved_instance", .{});
        }

        fn noteResumeCandidate(agent: *AppAgent, holder: *?*AppAgent, saved: *?*AppAgent) void {
            if (holder.* == null and agent.session_persistence.resume_handoff_intent == .requested) holder.* = agent;
            if (saved.* == null and app_session_runtime.Runtime(App).savedSessionId(agent) != null) saved.* = agent;
        }

        /// Shows `next` when instance `root`, which `hosted` holds or null for
        /// the first, or a subagent of its tree is on screen, then stops and
        /// drops every subagent in the tree, each before the agent that
        /// started it. The
        /// instance's own turn is cancelled; its teardown is the caller's.
        fn closeTree(app: *App, root: *AppAgent, hosted: ?*ChildAgent, next: ?*ChildAgent, label: []const u8) !void {
            var tree: std.ArrayList(*ChildAgent) = .empty;
            defer tree.deinit(app.alloc);
            for (app.child_agents.items) |entry| {
                if (entry.agent.role == .subagent and rootInstance(app, entry) == root) try tree.append(app.alloc, entry);
            }
            const on_screen = app.agent_on_screen;
            const root_on_screen = on_screen == hosted;
            const tree_on_screen = if (on_screen) |value| std.mem.findScalar(*ChildAgent, tree.items, value) != null else false;
            if (root_on_screen or tree_on_screen) try show(app, next);
            if (app.approval_lender) |lender| if (std.mem.findScalar(*ChildAgent, tree.items, lender) != null) {
                _ = returnApproval(app);
            };
            if (app.question_lender) |lender| if (std.mem.findScalar(*ChildAgent, tree.items, lender) != null) {
                _ = returnQuestion(app);
            };
            // First, so no work the close ends owes a report into the tree.
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (root.session_persistence.subagent_host) |host| host.closeTree();
                for (tree.items) |entry| if (entry.agent.session_persistence.subagent_host) |host| host.closeTree();
            }
            for (tree.items) |entry| {
                entry.agent.worker.requestCancel();
                entry.agent.worker.requestShutdown();
                entry.agent.managed_executions.shutdown();
            }
            for (tree.items) |entry| {
                if (entry.agent.worker_thread) |thread| thread.join();
                entry.agent.worker_thread = null;
                if (entry.agent.child_run) |*run| {
                    finishRun(run, .cancelled);
                    // A turn the user started ends with the tree, owing nothing.
                    if (hostOf(app, entry)) |host| endUserWork(app.alloc, host, run, .cancelled, "");
                }
            }
            root.worker.requestCancel();
            debug_trace.eventf("host", "instance_closed", .{}, "agent={s} subagents={d}", .{ label, tree.items.len });
            var index = tree.items.len;
            while (index > 0) {
                index -= 1;
                dropHosted(app, tree.items[index]);
            }
        }

        /// The open instance after `child` in launch order, wrapping to the
        /// first open one; null is the first instance in `main_agent`.
        fn nextInstanceAfter(app: *App, child: *const ChildAgent) ?*ChildAgent {
            var seen = false;
            for (app.child_agents.items) |entry| {
                if (entry.agent.role != .instance) continue;
                if (seen) return entry;
                if (entry == child) seen = true;
            }
            if (firstOpen(app)) return null;
            for (app.child_agents.items) |entry| {
                if (entry.agent.role == .instance and entry != child) return entry;
            }
            return null;
        }

        /// The open instance after the first one in `main_agent`.
        fn instanceAfterFirst(app: *App) ?*ChildAgent {
            for (app.child_agents.items) |entry| if (entry.agent.role == .instance) return entry;
            return null;
        }

        /// Tears down hosted agent `child`, which no one else holds once its
        /// run's slot thread lets go, and drops it from the list.
        pub fn dropHosted(app: *App, child: *ChildAgent) void {
            visit(app, child, {}, shutdownInContext) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
            };
            // A slot thread that never lets go leaves the agent allocated, so
            // it reads no freed memory, rather than freezing the screen.
            const released = child.bound.waitReleased(release_timeout_ms);
            if (!released) debug_trace.logf("host", "child_release_timeout child={s} at=drop kept_allocated=true", .{child.id});
            {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                for (app.child_agents.items, 0..) |entry, index| if (entry == child) {
                    _ = app.child_agents.orderedRemove(index);
                    break;
                };
            }
            if (!released) return;
            child.screen.deinit(app.alloc);
            if (child.name.len > 0) app.alloc.free(child.name);
            app.alloc.free(child.id);
            app.alloc.destroy(child);
        }

        pub fn findChild(app: *App, id: []const u8) ?*ChildAgent {
            for (app.child_agents.items) |child| if (std.mem.eql(u8, child.id, id)) return child;
            return null;
        }

        /// The run in flight on `agent`, when it is a child's.
        fn runInFlight(app: *App, agent: *AppAgent) ?*agents.ChildRun {
            if (comptime !@hasField(App, "screen_owner")) return null;
            if (agent == &app.main_agent) return null;
            const run = if (agent.child_run) |*value| value else return null;
            return if (run.inFlight()) run else null;
        }

        /// Ends the run once its turn is saved. The child's own agent saves
        /// every turn to its own session, as main does, so this runs
        /// after the save, on the main loop in the child's context. Only the
        /// turn carrying the run's work id ends it: the parent finds its
        /// answer by that id, and a turn the user started carries none.
        pub fn commitChildTurn(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) void {
            if (comptime !@hasField(App, "screen_owner")) return;
            if (agent.role != .subagent) return;
            // A subagent never runs a turn without a run installed.
            const run = if (agent.child_run) |*value| value else return;
            const saved_work = session_mod.historyTurnWorkId(finished.turn);
            debug_trace.eventf("host", "child_turn_saved", .{}, "agent={s} work_id={s}", .{ run.child_id, saved_work orelse "none" });
            if (saved_work == null and run.user_work_id.len > 0) {
                const host = hostOf(app, hostedOf(app, agent) orelse return) orelse return;
                const reply = switch (finished.turn) {
                    .assistant => |value| value.assistant,
                    .interrupted => |value| value.assistant orelse "",
                    .compacted_summary => "",
                };
                endAndFollowUserWork(app.alloc, host, run, userWorkOutcome(run, finished.terminal_outcome orelse .completed), reply);
                return;
            }
            if (!run.inFlight()) return;
            if (!std.mem.eql(u8, saved_work orelse return, run.work_id)) return;
            const outcome = finished.terminal_outcome orelse .completed;
            debug_trace.eventf("host", "child_turn_committed", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
            endRun(run, outcome);
        }

        /// The user stops a subagent's turn on its own screen (Esc, or
        /// cancelling its approval or question) while it works for its
        /// parent: the other agents' messages waiting in its queue are
        /// dropped, and its parent's host drops those waiting there
        /// (`subagent_tool_host.Runtime.userStopped`). A turn the user
        /// started there has no parent's messages behind it.
        pub fn noteUserStop(app: *App, agent: *AppAgent) void {
            const run = runInFlight(app, agent) orelse return;
            const child = hostedOf(app, agent) orelse return;
            const host = hostOf(app, child) orelse return;
            const drop = agent.worker.dropAgentMessages(std.heap.c_allocator);
            host.userStopped(run.child_id, drop.from_parent);
        }

        /// Records how a child's turn ended. The finished turn can still be
        /// on its way, held by the pacer or not yet drained, so the run ends
        /// when it is saved, or in `settleChildRuns` once nothing is left.
        pub fn noteChildTurnFinished(app: *App, agent: *AppAgent, finished: types.TurnFinished) void {
            const run = runInFlight(app, agent) orelse userWorkRun(app, agent) orelse return;
            run.ended_as = finished.outcome;
            if (finished.outcome == .interrupted and agent.worker.handedOff(finished.turn_id)) {
                run.handed_off = true;
                debug_trace.eventf("host", "child_turn_handed_off", .{}, "agent={s} work_id={s} turn_id={d}", .{ run.child_id, run.work_id, finished.turn_id });
            }
        }

        /// Ends each child's run whose turn has finished and left nothing to
        /// save: its worker is idle, with no events left and nothing held by
        /// its pacer. A turn cancelled before it said anything ends here.
        /// Runs on the main loop each pass, after the children's events.
        pub fn settleChildRuns(app: *App) void {
            for (app.child_agents.items) |child| {
                const run = if (child.agent.child_run) |*value| value else continue;
                const outcome = run.ended_as orelse continue;
                if (hasPendingWork(child) or child.agent.worker.isProcessing()) continue;
                if (run.user_work_id.len > 0) {
                    const host = hostOf(app, child) orelse continue;
                    endAndFollowUserWork(app.alloc, host, run, userWorkOutcome(run, outcome), "");
                    continue;
                }
                if (!run.inFlight()) continue;
                endRun(run, outcome);
            }
        }

        /// The run of a turn the user started on a subagent's screen, while
        /// the work it opened in the parent's log is open.
        fn userWorkRun(app: *App, agent: *AppAgent) ?*agents.ChildRun {
            if (agent == &app.main_agent) return null;
            const run = if (agent.child_run) |*value| value else return null;
            return if (run.user_work_id.len > 0) run else null;
        }

        fn userWorkOutcome(run: *const agents.ChildRun, outcome: types.TurnPresentationOutcome) subagent_child_state.Outcome {
            return switch (outcome) {
                .completed => .completed,
                .failed => .failed,
                .interrupted => if (run.handed_off) .completed else .cancelled,
                .paused => .cancelled,
            };
        }

        /// Ends a user's turn's work. When the turn handed off to the user's
        /// image or `$skill`, that prompt runs next as the user's own turn,
        /// so it opens the next work.
        fn endAndFollowUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            const handed_off = run.handed_off;
            endUserWork(alloc, host, run, outcome, reply);
            if (handed_off) if (host.beginUserWork(alloc, run.child_id)) |work_id| {
                run.user_work_id = work_id;
            };
        }

        /// Ends the work a user's turn opened, once.
        fn endUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            if (run.user_work_id.len == 0) return;
            const work_id = run.user_work_id;
            run.user_work_id = &.{};
            run.ended_as = null;
            run.handed_off = false;
            defer alloc.free(work_id);
            debug_trace.eventf("host", "user_work_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, work_id, @tagName(outcome) });
            host.endUserWork(run.child_id, work_id, outcome, reply);
        }

        /// Keeps a child's terminal provider error for the parent.
        pub fn noteChildFailure(app: *App, agent: *AppAgent, status: types.RouteRecoveryStatus) void {
            if (status.kind != .terminal_provider_error) return;
            const run = runInFlight(app, agent) orelse return;
            run.failure = status.diagnostic orelse return;
        }

        /// Ends `run` and releases its slot thread, tracing how it ended.
        fn finishRun(run: *agents.ChildRun, outcome: agents.ChildRunCompletion.Outcome) void {
            if (!run.inFlight()) return;
            debug_trace.eventf("host", "child_run_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
            run.finish(outcome);
        }

        fn endRun(run: *agents.ChildRun, outcome: types.TurnPresentationOutcome) void {
            switch (outcome) {
                .completed => finishRun(run, .completed),
                .failed => {
                    // Keeps the provider's own error when the worker set one.
                    if (run.turn) |turn| if (turn.failureDiagnostic() == null) {
                        turn.failure_diagnostic = run.failure orelse
                            types.ModelFailureDiagnostic.init("agent_turn_failed");
                    };
                    finishRun(run, .failed);
                },
                // Handed off to the user's image or `$skill`: the work is done.
                .interrupted => finishRun(run, if (run.handed_off) .completed else .cancelled),
                .paused => finishRun(run, .cancelled),
            }
        }

        /// Gives a child agent its next run, replacing the last one, and takes
        /// ownership of `run`, which `app.alloc` owns. The child's turns take
        /// their effort from the admission and use ultrafast only when both main
        /// and the admission have it; every other setting follows main's. Call
        /// on the main loop while the child is idle.
        pub fn installChildRun(app: *App, child: *ChildAgent, run: agents.ChildRun) void {
            if (child.agent.child_run) |*previous| previous.deinit(app.alloc);
            var settings = (firstInstance(app) orelse &app.main_agent).worker.agent_turn_settings;
            settings.effort = run.admission.effort;
            // Its own fast mode, not main's.
            settings.fast_mode = child.agent.worker.agent_turn_settings.fast_mode;
            settings.ultrafast_mode = settings.ultrafast_mode and run.admission.ultrafast_mode;
            child.agent.worker.agent_turn_settings = settings;
            var owned = run;
            // Its tool calls and hooks name it, as a subagent turn's do.
            if (owned.subagent_id == 0) owned.subagent_id = debug_trace.nextSubagentId();
            child.agent.child_run = owned;
        }

        /// Saves and closes `agent`'s session. When the user quit from this
        /// instance's screen, keeps the resume command it makes for the exit
        /// to print.
        fn finalizeInstancePersistence(app: *App, agent: *agents.Agent) void {
            const Session = app_session_runtime.Runtime(App);
            if (comptime @hasField(App, "instances")) {
                if (agent.role == .instance and agent.session_persistence.resume_handoff_intent != .none) {
                    const handoff = Session.finalizePersistenceWithResumeHandoff(app, agent);
                    if (app.instances.exit_handoff == null) {
                        app.instances.exit_handoff = handoff;
                    } else if (handoff) |value| {
                        var owned = value;
                        owned.deinit(app.alloc);
                    }
                    return;
                }
            }
            Session.finalizePersistence(app, agent);
        }

        fn shutdownInContext(_: void, app: *App, agent: *agents.Agent) anyerror!void {
            agent.worker.requestShutdown();
            agent.managed_executions.shutdown();
            if (agent.worker_thread) |thread| thread.join();
            agent.worker_thread = null;
            app_worker_runtime.Runtime(App).settleFinishedPromptsForShutdown(app, agent) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(agent, err);
            };
            agent.managed_executions.deinit();
            finalizeInstancePersistence(app, agent);
            agent.worker.deinit(std.heap.c_allocator);
            app.clearPendingImages(agent);
            agent.pending_images.deinit(app.alloc);
            agent.session_title.deinit(app.alloc);
            app_session_runtime.Runtime(App).deinitPersistence(app, agent);
            agent.session.deinit(app.alloc);
            agent.approval_prompt.deinit(app.alloc);
            agent.question_prompt.deinit(app.alloc);
            app_permission_runtime.Runtime(App).deinitSessionGrants(app, agent);
            agent.change_tracker.deinit(std.heap.c_allocator);
            for (agent.diff_entries.items) |*entry| entry.deinit(std.heap.c_allocator);
            agent.diff_entries.deinit(std.heap.c_allocator);
            agent.context_snapshot.deinit(app.alloc);
            if (agent.child_run) |*run| run.deinit(app.alloc);
            agent.profile.deinit();
            agent.* = .{};
        }

        /// Frees every child agent's screen and storage. Call `shutdownChildren`
        /// first.
        pub fn deinitChildren(app: *App) void {
            for (app.child_agents.items) |child| {
                child.screen.deinit(app.alloc);
                if (child.name.len > 0) app.alloc.free(child.name);
                app.alloc.free(child.id);
                app.alloc.destroy(child);
            }
            app.child_agents.deinit(app.alloc);
            app.child_agents = .empty;
            app.main_screen.deinit(app.alloc);
            app.main_screen = .{};
            app.child_handoffs.deinit();
        }
    };
}

test "a slot thread's hand-off returns once the main loop takes it" {
    var handoffs: Handoffs = .{};
    defer handoffs.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    // The loop side never runs here, so the turn is never read.
    var post = Post{ .turn = undefined };
    const Loop = struct {
        fn take(box: *Handoffs) void {
            while (true) {
                box.mutex.lockUncancelable(io_mod.getIo());
                if (box.posts.pop()) |taken| {
                    taken.settle(.taken);
                    box.mutex.unlock(io_mod.getIo());
                    return;
                }
                box.mutex.unlock(io_mod.getIo());
                io_mod.sleep(std.time.ns_per_ms);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Loop.take, .{&handoffs});
    try postAndWait(&handoffs, &post, &cancel);
    thread.join();
    try std.testing.expectEqual(Post.State.taken, post.state.load(.acquire));
}

test "a hand-off withdrawn on cancel, or posted after shutdown, never reaches the main loop" {
    var handoffs: Handoffs = .{};
    defer handoffs.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    var post = Post{ .turn = undefined };
    try std.testing.expectError(error.Cancelled, postAndWait(&handoffs, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), handoffs.posts.items.len);

    handoffs.closed = true;
    cancel.store(false, .seq_cst);
    try std.testing.expectError(error.Cancelled, postAndWait(&handoffs, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), handoffs.posts.items.len);
}

test "the switch list follows the registry's start order, with an unlisted agent kept after it" {
    const ids = [_][]u8{ @constCast("new"), @constCast("second"), @constCast("first"), @constCast("stray") };
    var agents_storage: [4]ChildAgent = undefined;
    var children: [4]*ChildAgent = undefined;
    for (&agents_storage, &children, ids) |*agent, *slot, id| {
        agent.* = .{ .id = id };
        slot.* = agent;
    }
    // "new" started in this process; "first" and "second" before a restart.
    const Entry = struct { id: []const u8 };
    const listing = [_]Entry{ .{ .id = "first" }, .{ .id = "second" }, .{ .id = "new" } };
    orderByListing(&children, &listing);
    var order: [4][]const u8 = undefined;
    for (children, &order) |child, *name| name.* = child.id;
    try std.testing.expectEqualDeep([4][]const u8{ "first", "second", "new", "stray" }, order);
}

/// Checks the switch order `order` over `entries`: every agent once, the
/// first instance first, the instances in
/// launch order, and each subagent in its own instance's group, after the
/// ones of that group that started before it.
fn expectSwitchOrder(entries: []const OrderEntry, order: []const usize) !void {
    try std.testing.expectEqual(entries.len + 1, order.len);
    var seen = try std.testing.allocator.alloc(bool, order.len);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    for (order) |position| {
        try std.testing.expect(position < order.len);
        try std.testing.expect(!seen[position]);
        seen[position] = true;
    }
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    var group: usize = 0;
    var last_instance: ?usize = null;
    var last_in_group: ?usize = null;
    for (order[1..]) |position| {
        const index = position - 1;
        switch (entries[index].role) {
            .instance => {
                if (last_instance) |previous| try std.testing.expect(previous < index);
                last_instance = index;
                group += 1;
                last_in_group = null;
            },
            .subagent => {
                try std.testing.expectEqual(group, entries[index].root);
                if (last_in_group) |previous| try std.testing.expect(previous < index);
                last_in_group = index;
            },
        }
    }
}

/// A host built from random choices: each new agent is an instance or a
/// subagent of the first instance or one launched before it.
fn randomEntries(random: std.Random, buf: []OrderEntry) []OrderEntry {
    const len = random.uintAtMost(usize, buf.len);
    var instances: usize = 0;
    for (buf[0..len]) |*entry| {
        if (random.boolean()) {
            entry.* = .{ .role = .instance };
            instances += 1;
        } else entry.* = .{ .role = .subagent, .root = random.uintAtMost(usize, instances) };
    }
    return buf[0..len];
}

test "the switch order lists instances in launch order, each with its own subagents" {
    // In start order: A (the first's), fx 2, B (fx 2's), C (the first's),
    // fx 3, D (fx 3's).
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .root = 0 },
        .{ .role = .instance },
        .{ .role = .subagent, .root = 1 },
        .{ .role = .subagent, .root = 0 },
        .{ .role = .instance },
        .{ .role = .subagent, .root = 2 },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    // The first, A, C, fx 2, B, fx 3, D.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 2, 3, 5, 6 }, &order);
    try expectSwitchOrder(&entries, &order);
}

test "the switch order holds for random hosts" {
    var prng = std.Random.DefaultPrng.init(0x5eed_4057);
    var buf: [24]OrderEntry = undefined;
    var order: [buf.len + 1]usize = undefined;
    for (0..10_000) |_| {
        const entries = randomEntries(prng.random(), &buf);
        switchOrder(entries, order[0 .. entries.len + 1]);
        try expectSwitchOrder(entries, order[0 .. entries.len + 1]);
    }
}

test "the switch order holds for fuzzed hosts" {
    try std.testing.fuzz({}, fuzzSwitchOrder, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").switch_order.*),
    });
}

fn fuzzSwitchOrder(_: void, smith: *std.testing.Smith) !void {
    var buf: [24]OrderEntry = undefined;
    var len: usize = 0;
    var instances: usize = 0;
    while (len < buf.len and !smith.eos()) : (len += 1) {
        if (smith.boolWeighted(1, 1)) {
            buf[len] = .{ .role = .instance };
            instances += 1;
        } else buf[len] = .{ .role = .subagent, .root = smith.valueRangeAtMost(u8, 0, @intCast(instances)) };
    }
    var order: [buf.len + 1]usize = undefined;
    switchOrder(buf[0..len], order[0 .. len + 1]);
    try expectSwitchOrder(buf[0..len], order[0 .. len + 1]);
}
