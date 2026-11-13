//! The interactive app's agents besides main, and how the main loop works for
//! each one. A subagent runs main's own code on its own conversation, so the
//! loop handles its events exactly like main's: in that agent's context, with
//! its transcript and paced text on the screen, swapped back before anything
//! paints.

const std = @import("std");
const builtin = @import("builtin");
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
const provider_runtime = @import("provider_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const profiles = @import("../profiles/profiles.zig");
const worker_status = @import("../output/worker_status.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_reports = @import("../subagent/reports.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const io_mod = @import("../shared/io.zig");
const activity_status = @import("../output/activity_status.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const ascii_case = @import("../shared/ascii_case.zig");
const types = @import("../shared/types.zig");
const live_metrics = @import("../subagent/live_metrics.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");

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
    /// Last reply in a lazily restored child's saved history. Live turns use
    /// the agent's history; this cache avoids reading disk on every redraw.
    saved_reply_at_ms: i64 = 0,
    /// The host that started it: main's, or its parent subagent's own.
    /// Its session opens through it, and its own subagents'
    /// authority comes from that host's resolver. Written on the main loop
    /// and read by resolvers on other threads, both under main's authority
    /// lock. Borrowed: that host outlives it.
    parent_host: ?*subagent_tool_host.Runtime = null,
    /// The name its parent gave it, such as `reviewer`, from its first run.
    /// Empty for a one-off. Owned.
    name: []u8 = &.{},
    /// The profile it runs in, from its host's list. Empty until the list is
    /// read. Owned.
    profile: []u8 = &.{},
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

    /// Whether it has events for the loop to handle or assistant text left to
    /// pace out in `pacer`, the pacer that holds its text: its own slot's
    /// while it is hidden, the app's while it is on screen (`pacerOf`).
    fn hasUnapplied(self: *ChildAgent, pacer: *AssistantPacer) bool {
        return self.agent.worker.hasPendingEvents() or pacer.hasPending();
    }
};

/// An agent in the switch list, such as the row Delete closes or the row
/// above a closed agent: a subagent, or an instance with null for the first.
const ListedAgent = struct { agent: ?*ChildAgent };

/// The agent list ↓, Ctrl+X, and `/agents` open. Its rows are every open
/// agent in switch order, built each time it is drawn so each shows what it
/// is doing now. It opens on the agent on screen, and its highlight is a
/// preview: moving it shows the agent it lands on, Enter keeps that agent,
/// and Esc or Ctrl+X go back to `origin`. Up on the first row closes it with
/// the agent shown kept (`tests/tla/agents_menu/spec/AgentsMenu.tla`).
pub const AgentsMenu = struct {
    open: bool = false,
    /// The highlighted agent's place in the switch list, from 0, as
    /// `switchList` last found `highlight` there.
    selected: usize = 0,
    window_start: usize = 0,
    /// The highlighted agent while `open`, which is the agent on screen
    /// unless a search hides that one. It stays on its agent while rows
    /// start, reorder, and close around it.
    highlight: Highlight = .on_screen,
    /// The agent the list opened on, which Esc, Ctrl+X, and Ctrl+C show
    /// again, while `open`. Once it closed they keep the agent shown:
    /// `dropHosted` puts it back on `.on_screen`, and a closed first
    /// instance is no longer listed.
    origin: Highlight = .on_screen,
    /// The agent whose close the first Delete armed, until the second
    /// closes it or another key disarms it. Compared by address only.
    close_armed: ?ListedAgent = null,
    /// The draft of the agent on screen, set aside while the composer is
    /// the list's search box, and back in the composer once the list closes.
    draft: ?composer_stash.State = null,
    /// Backs the rows the last projection showed. Owned.
    rows: std.ArrayList(render_input.AgentsMenuRow) = .empty,
    /// Backs the instance names in `rows`, such as "fx 12". Owned.
    names: std.ArrayList(u8) = .empty,
    /// Backs each subagent row's current call and its state with the call's
    /// time, such as "working 12s". Owned.
    activities: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *AgentsMenu, alloc: Allocator) void {
        self.rows.deinit(alloc);
        self.names.deinit(alloc);
        self.activities.deinit(alloc);
        if (self.draft) |*draft| draft.deinit(alloc);
        self.* = .{};
    }

    /// One agent the list keeps, null for the first instance, compared by
    /// address only; or the agent on screen, once that agent closed.
    /// `dropHosted` puts the highlight and the origin back on the agent on
    /// screen before it frees the agent, so neither names a freed agent or
    /// one that took its address.
    pub const Highlight = union(enum) {
        on_screen,
        agent: ?*ChildAgent,
    };
};

/// Room for an instance's name in the agent list, such as "fx 12".
const instance_name_bytes = 24;
/// Room for a subagent row's current call, then its state with the call's
/// time, such as "working 59m59s".
const activity_bytes = live_metrics.max_label_bytes + 32;

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

    fn urgency(self: InstanceState) Urgency {
        return switch (self) {
            .needs_approval, .has_question, .needs_you => .attention,
            .working => .working,
            .finished, .idle => .idle,
        };
    }

    /// How bright the agent list draws it.
    fn tone(self: InstanceState) render_input.AgentStateTone {
        return switch (self) {
            .needs_approval, .has_question, .needs_you => .needs_user,
            .working, .finished => .active,
            .idle => .idle,
        };
    }
};

/// How soon an agent needs the user, which orders a fx's subagents in the
/// agent list: one waiting for the user first, then one working, then the rest.
const Urgency = enum(u2) {
    attention,
    working,
    idle,

    /// The more urgent of `self` and `other`.
    fn atLeast(self: Urgency, other: Urgency) Urgency {
        return if (@backingInt(other) < @backingInt(self)) other else self;
    }
};

/// What the busiest open agent is doing (`Runtime.busiest`), most urgent
/// first. A finished turn counts as idle.
pub const Busiest = enum { needs_approval, has_question, needs_you, working, idle };

/// An agent that restarting fx, as an upgrade does, would stop, and what it
/// is doing (`Runtime.busyAgentElsewhere`). `doing` is never `.idle`.
pub const BusyAgent = struct { name: []const u8, doing: Busiest };

/// One subagent as `/trace` shows it (`Runtime.traceRows`): what the agent
/// list says of it, and its status row. Every string but `status` borrows
/// from the app, so a row is read on the main loop before anything changes.
pub const TraceRow = struct {
    /// Its session ID, the name of its folder in the session store.
    id: []const u8,
    /// The name its parent gave it, or empty for a one-off.
    name: []const u8,
    profile: []const u8,
    title: []const u8,
    /// What it is doing, as the agent list says, such as `needs_you`.
    state: []const u8,
    model: []const u8,
    effort: []const u8,
    /// Its status row, such as a failed request that waits for the user, or
    /// empty. Owned by the allocator `traceRows` was given.
    status: []const u8,
    /// The host that started it, whose registry holds its work, or null
    /// before it is bound.
    host: ?*subagent_tool_host.Runtime,
};

/// What an agent in `state` is doing for a state that stands for others,
/// or null when it is idle. A finished turn counts as idle.
fn busyAs(state: InstanceState) ?Busiest {
    return switch (state) {
        .needs_approval => .needs_approval,
        .has_question => .has_question,
        .needs_you => .needs_you,
        .working => .working,
        .finished, .idle => null,
    };
}

/// The more urgent of `a` and `b`; `InstanceState` lists the most urgent
/// first.
fn moreUrgent(a: InstanceState, b: InstanceState) InstanceState {
    return if (@backingInt(a) <= @backingInt(b)) a else b;
}

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

/// Whether a request that waits for `need` is one a subagent's parent may
/// send again: a refused or a day-old one. A sign-in, credits, the content
/// filter, a request too long, or one that crashed fx twice is the user's.
fn parentMayResend(need: @FieldType(types.RouteRecoveryStatus, "need")) bool {
    return switch (need orelse return false) {
        .rejected, .stale => true,
        .sign_in, .quota, .content_filter, .too_long, .crash_loop => false,
    };
}

test "a subagent's parent may send again only a refused or a day-old request" {
    try std.testing.expect(parentMayResend(.rejected));
    try std.testing.expect(parentMayResend(.stale));
    for ([_]@FieldType(types.RouteRecoveryStatus, "need"){ null, .sign_in, .quota, .content_filter, .too_long, .crash_loop }) |need| {
        try std.testing.expect(!parentMayResend(need));
    }
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
    /// Who started a report's work and why it was cancelled.
    end: subagent_child_state.EndFacts = .{},
    /// Whether a report's child is idle once it goes.
    idle: bool = false,
    /// A message's lines the user typed in the turn that sent it.
    typed_lines: [][]u8 = &.{},

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
            .end = if (delivery == .report) delivery.report.end else .{},
            .idle = delivery == .report and delivery.report.idle,
        };
        if (delivery == .message) {
            // The others are freed by their own errdefers above.
            errdefer handoff_alloc.free(post.text);
            const typed = delivery.message.user_typed;
            const lines = try handoff_alloc.alloc([]u8, typed.len);
            var copied: usize = 0;
            errdefer {
                for (lines[0..copied]) |line| handoff_alloc.free(line);
                handoff_alloc.free(lines);
            }
            for (typed) |line| {
                lines[copied] = try handoff_alloc.dupe(u8, line);
                copied += 1;
            }
            post.typed_lines = lines;
        }
        return post;
    }

    fn destroy(self: *ReportPost) void {
        handoff_alloc.free(self.agent);
        handoff_alloc.free(self.child_id);
        handoff_alloc.free(self.work_id);
        handoff_alloc.free(self.text);
        for (self.typed_lines) |line| handoff_alloc.free(line);
        handoff_alloc.free(self.typed_lines);
        handoff_alloc.destroy(self);
    }
};

test "a message's hand-off keeps its own copy of what the user typed" {
    var host: subagent_tool_host.Runtime = undefined;
    var first = "tell main hi".*;
    var second = "and bye".*;
    const lines = [_][]const u8{ &first, &second };
    const post = try ReportPost.create(&host, .{ .message = .{ .to = .owner, .agent = "reviewer", .child_id = "c1", .text = "hi", .user_typed = &lines } });
    defer post.destroy();
    // The sender's buffers change once the post is made.
    @memset(&first, 'x');
    @memset(&second, 'x');
    try std.testing.expectEqual(@as(usize, 2), post.typed_lines.len);
    try std.testing.expectEqualStrings("tell main hi", post.typed_lines[0]);
    try std.testing.expectEqualStrings("and bye", post.typed_lines[1]);
}

test "a report's hand-off keeps the count a user's stop dropped, and who started and stopped its work" {
    // Only the host's address is kept, so any will do.
    var host: subagent_tool_host.Runtime = undefined;
    const end: subagent_child_state.EndFacts = .{ .started_by = .user, .cause = .user_stop };
    const post = try ReportPost.create(&host, .{ .report = .{ .agent = "reviewer", .child_id = "c1", .work_id = "w1", .outcome = .cancelled, .output = "", .dropped = 2, .end = end } });
    defer post.destroy();
    try std.testing.expectEqual(@as(usize, 2), post.dropped);
    try std.testing.expectEqual(subagent_child_state.Outcome.cancelled, post.outcome);
    try std.testing.expectEqual(end, post.end);
    try std.testing.expect(!post.idle);
    const idle = try ReportPost.create(&host, .{ .report = .{ .agent = "reviewer", .child_id = "c1", .work_id = "w2", .outcome = .completed, .output = "done", .idle = true } });
    defer idle.destroy();
    try std.testing.expect(idle.idle);
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

/// Test builds only: a test sets it to reach the timeout path at once.
pub var test_release_timeout_ms: if (builtin.is_test) ?i64 else void = if (builtin.is_test) null else {};

fn releaseTimeoutMs() i64 {
    if (builtin.is_test) return test_release_timeout_ms orelse release_timeout_ms;
    return release_timeout_ms;
}

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

/// The "waiting on N subagents" activity row and when its clock started, 0
/// without one. The label borrows `App.instances` until the next call.
pub const SubagentWait = struct {
    label: []const u8 = "",
    since_ms: i64 = 0,
};

/// One hosted agent as the switch order sees it: an instance, or a subagent
/// in the tree of instance `root`, where 0 is the first instance and k the
/// k-th later one in launch order.
const OrderEntry = struct {
    role: agents.Role,
    root: usize = 0,
    /// The switch position of the subagent that started this one; null when
    /// an instance did.
    parent: ?usize = null,
    /// Its own urgency, or its most urgent own subagent's (`raiseParents`),
    /// so an idle subagent whose child works sorts with the working ones.
    urgency: Urgency = .idle,
    reply_at_ms: i64 = 0,
};

/// Gives each subagent the urgency of its most urgent own subagent, so a
/// subagent whose child waits for the user moves up with it.
fn raiseParents(entries: []OrderEntry) void {
    for (entries) |entry| {
        var parent = entry.parent;
        while (parent) |position| : (parent = entries[position - 1].parent) {
            entries[position - 1].urgency = entries[position - 1].urgency.atLeast(entry.urgency);
        }
    }
}

/// The newest completed reply with a saved timestamp. Stops and failures do
/// not count as a new reply, nor does merely opening an agent's conversation.
fn latestReplyAt(history: []const types.HistoryTurn) i64 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        switch (history[index]) {
            .assistant => |entry| {
                if (entry.assistant.len == 0) continue;
                if (entry.execution.turn_summary) |summary| {
                    if (summary.completed_at_ms > 0) return summary.completed_at_ms;
                }
            },
            .interrupted, .compacted_summary => {},
        }
    }
    return 0;
}

/// When the agent's newest turn ended, from its saved turn summary, or 0
/// when that turn saved no end time, as a stopped or failed turn does. Unlike
/// `latestReplyAt`, it never falls back to an older turn, so a clock started
/// from it never counts time from before the newest turn.
fn newestTurnEndedAt(history: []const types.HistoryTurn) i64 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const summary = types.historyTurnSummary(history[index]) orelse switch (history[index]) {
            .compacted_summary => continue,
            .assistant, .interrupted => return 0,
        };
        return summary.completed_at_ms;
    }
    return 0;
}

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

/// Sorts each instance's subagents in switch order `order`: those waiting for
/// the user first, then the working ones, both in start order, then the rest
/// by newest reply. Instances stay put.
fn sortSubagentGroups(entries: []const OrderEntry, order: []usize) void {
    const Context = struct {
        entries: []const OrderEntry,

        fn isSubagent(ctx: @This(), position: usize) bool {
            return position != 0 and ctx.entries[position - 1].role == .subagent;
        }

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const left = ctx.entries[a - 1];
            const right = ctx.entries[b - 1];
            if (left.urgency != right.urgency) return @backingInt(left.urgency) < @backingInt(right.urgency);
            return left.urgency == .idle and left.reply_at_ms > right.reply_at_ms;
        }
    };
    const ctx: Context = .{ .entries = entries };
    var start: usize = 0;
    while (start < order.len) {
        var end = start;
        while (end < order.len and ctx.isSubagent(order[end])) end += 1;
        if (end == start) {
            start += 1;
            continue;
        }
        sort_utils.sort(usize, order[start..end], ctx, Context.lessThan);
        start = end;
    }
}

/// Puts each subagent's own subagents right under it, in the order `order`
/// already has them, so the list draws a tree. `scratch` is as long as
/// `order`.
fn nestSubagents(entries: []const OrderEntry, order: []usize, scratch: []usize) void {
    @memcpy(scratch, order);
    var next: usize = 0;
    for (scratch) |position| {
        if (position != 0 and entries[position - 1].parent != null) continue;
        next = placeWithChildren(entries, scratch, position, order, next);
    }
    std.debug.assert(next == order.len);
}

fn placeWithChildren(entries: []const OrderEntry, flat: []const usize, position: usize, out: []usize, next: usize) usize {
    out[next] = position;
    var at = next + 1;
    for (flat) |child| {
        if (child == 0) continue;
        const parent = entries[child - 1].parent orelse continue;
        if (parent == position) at = placeWithChildren(entries, flat, child, out, at);
    }
    return at;
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

        /// True when the hidden `child` has events for the loop to handle or
        /// assistant text left to pace out.
        pub fn hasPendingWork(child: *ChildAgent) bool {
            return child.hasUnapplied(&child.screen.pacer);
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
        /// main. A subagent never runs a turn without a run. True when it
        /// admitted a run, whose work `openOwnTurnWork` opens once the text
        /// is queued.
        pub fn prepareOwnTurn(app: *App, agent: *AppAgent) !bool {
            const child = app.agent_on_screen orelse return false;
            // An instance takes its own turns as the first one does.
            if (child.agent.role == .instance) return false;
            if (child.agent.worker_thread == null) _ = try ensureChild(app, child.id);
            if (!child.session_attached) try attachSession(app, agent, child);
            const admitted = child.agent.child_run == null or !turnGoing(app, child);
            if (admitted) try admitOwnTurn(app, agent, child);
            debug_trace.eventf("host", "input_routed", .{}, "agent={s}", .{child.id});
            return admitted;
        }

        /// Opens the work in the parent's log for the turn `prepareOwnTurn`
        /// admitted, once the user's text is queued for it. A submit that
        /// queues nothing, such as an empty Enter or a refused image, opens
        /// none, so no work waits for a turn that never comes.
        pub fn openOwnTurnWork(app: *App) void {
            const child = app.agent_on_screen orelse return;
            const run = if (child.agent.child_run) |*value| value else return;
            if (run.inFlight() or run.turn_work_id.len > 0) return;
            const host = hostOf(app, child) orelse return;
            if (host.beginUserWork(app.alloc, child.id, &child.agent.worker)) |work_id| run.turn_work_id = work_id;
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
            listRestoredSubagents(app);
            return openAgentCount(app) > 1;
        }

        /// Puts the subagents of every instance's session in the switch
        /// list, those started before a restart too (`syncChildList`).
        pub fn listRestoredSubagents(app: *App) void {
            syncChildList(app) catch |err| {
                debug_trace.logf("host", "child list sync failed err={s}", .{@errorName(err)});
            };
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
            // Every instance's tree, a restored one's too: the
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
                    const child = findChild(app, entry.id) orelse restored: {
                        const restored_child = try addChild(app, entry.id);
                        try showSavedTitle(app, host, restored_child);
                        const history = host.childHistory(app.alloc, entry.id) catch |err| {
                            debug_trace.logf("host", "saved reply time unavailable agent={s} err={s}", .{ entry.id, @errorName(err) });
                            break :restored restored_child;
                        };
                        defer types.freeHistoryTurnSlice(app.alloc, history);
                        restored_child.saved_reply_at_ms = latestReplyAt(history);
                        break :restored restored_child;
                    };
                    if (child.name.len == 0 and entry.name.len > 0) child.name = try app.alloc.dupe(u8, entry.name);
                    if (child.profile.len == 0) child.profile = try app.alloc.dupe(u8, entry.profile);
                    if (child.parent_host == null) setParentHost(app, child, host);
                    try order.append(app.alloc, .{ .id = entry.id });
                }
            }
            orderByListing(app.child_agents.items, order.items);
        }

        /// Gives a subagent restored from before a restart its saved title,
        /// so its row in the list names it before its conversation opens.
        fn showSavedTitle(app: *App, host: *subagent_tool_host.Runtime, child: *ChildAgent) !void {
            const title = host.childTitle(app.alloc, child.id) catch |err| {
                debug_trace.logf("host", "saved title unavailable agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            } orelse return;
            defer app.alloc.free(title);
            try app_session_runtime.Runtime(App).setCachedSessionTitle(app, &child.agent, title);
        }

        /// The switch order, with each instance's subagents sorted
        /// (`sortSubagentGroups`) and each subagent's own right under it
        /// (`nestSubagents`). While the agent list is open, only the agents
        /// its search matches, and the list's highlight is found among them.
        pub fn switchList(app: *App, out: *std.ArrayList(?*ChildAgent)) !void {
            const start = out.items.len;
            try fullSwitchList(app, out);
            if (!menuActive(app)) return;
            const menu = &app.instances.agents_menu;
            const search = searchText(app);
            if (search.len > 0) {
                var kept = start;
                for (out.items[start..]) |target| {
                    if (!matchesSearch(app, target, search)) continue;
                    out.items[kept] = target;
                    kept += 1;
                }
                out.shrinkRetainingCapacity(kept);
            }
            // Activity can change while the menu is open. Keep the highlighted
            // agent, not its previous row, for navigation, Enter, and Delete;
            // once it left the rows, the highlight moves to the agent on screen.
            const listed = out.items[start..];
            const at = switch (menu.highlight) {
                .on_screen => null,
                .agent => |agent| positionIn(listed, agent),
            };
            if (at) |position| {
                menu.selected = position;
            } else if (positionIn(listed, app.agent_on_screen)) |position| {
                menu.highlight = .on_screen;
                menu.selected = position;
            } else {
                // A search hides the agent on screen too: the first match
                // takes the highlight and keeps it while the rows change.
                menu.highlight = if (listed.len > 0) .{ .agent = listed[0] } else .on_screen;
                menu.selected = 0;
            }
        }

        /// Every open agent in switch order, whatever the agent list's search.
        fn fullSwitchList(app: *App, out: *std.ArrayList(?*ChildAgent)) !void {
            const hosted = app.child_agents.items;
            const entries = try app.alloc.alloc(OrderEntry, hosted.len);
            defer app.alloc.free(entries);
            for (hosted, entries) |child, *entry| entry.* = .{
                .role = child.agent.role,
                .root = if (child.agent.role == .subagent) instanceOrdinal(app, rootInstance(app, child)) else 0,
                .parent = if (parentSubagent(app, child)) |parent| (if (std.mem.findScalar(*ChildAgent, hosted, parent)) |index| index + 1 else null) else null,
                .urgency = stateOf(app, child).urgency(),
                .reply_at_ms = @max(child.saved_reply_at_ms, latestReplyAt(child.agent.session.agent.history.items)),
            };
            raiseParents(entries);
            const order = try app.alloc.alloc(usize, 2 * (hosted.len + 1));
            defer app.alloc.free(order);
            const switch_order = order[0 .. hosted.len + 1];
            switchOrder(entries, switch_order);
            sortSubagentGroups(entries, switch_order);
            nestSubagents(entries, switch_order, order[hosted.len + 1 ..]);
            try out.ensureUnusedCapacity(app.alloc, switch_order.len);
            for (switch_order) |position| {
                if (position == 0 and !firstOpen(app)) continue;
                out.appendAssumeCapacity(if (position == 0) null else hosted[position - 1]);
            }
        }

        /// What the user typed in the composer to search the open list.
        fn searchText(app: *App) []const u8 {
            if (!menuActive(app)) return "";
            return app.input_runtime.edit_state.input.items;
        }

        /// The agent on the row just above `target`'s in the full switch
        /// order, which takes `target`'s place on screen when it closes. A
        /// subagent's own subagents are listed under it, so the row is above
        /// its whole branch, as it is above an instance's subagents. Null when
        /// `target` is the first row, or not listed.
        fn rowAbove(app: *App, target: ?*ChildAgent) !?ListedAgent {
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try fullSwitchList(app, &order);
            const at = positionIn(order.items, target) orelse return null;
            if (at == 0) return null;
            return .{ .agent = order.items[at - 1] };
        }

        /// Whether agent `target`'s name or title has `search` in it, case aside.
        fn matchesSearch(app: *App, target: ?*ChildAgent, search: []const u8) bool {
            var buf: [instance_name_bytes]u8 = undefined;
            return ascii_case.containsIgnoreCase(noteName(app, target, &buf), search) or
                ascii_case.containsIgnoreCase(targetAgent(app, target).session_title.items, search);
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
        /// "reviewer needs approval", or "3 agents require attention" for
        /// several, or else the finished note, or empty. It waits on an approval, a question, or a
        /// request only the user can continue, such as one out of credits.
        /// The footer follows it with the agent indicator, which names the
        /// key that opens the agent list. fx never switches on its own.
        /// `buf` backs the returned text.
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
            if (count > 1) return std.mem.print(buf, "{d} agents require attention", .{count}) catch "";
            var name_buf: [32]u8 = undefined;
            return std.mem.print(buf, "{s} {s}", .{ noteName(app, first, &name_buf), state.label() }) catch "";
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

        /// Whether any agent has a turn running or waiting: the main
        /// agent's or a hosted agent's. Every agent uses the same MCP
        /// servers, so a reload of them waits until none has.
        pub fn anyWorkGoing(app: *App) bool {
            if (app.main_agent.worker.isProcessing() or app.main_agent.worker.queuedPromptCount() > 0) return true;
            for (app.child_agents.items) |child| if (child.workGoing()) return true;
            return false;
        }

        /// What the busiest open agent, instance or subagent, is doing, for
        /// a state that stands for the whole process, such as herdr's pane.
        /// Main loop only: it reads every agent's prompts.
        pub fn busiest(app: *App) Busiest {
            var most: InstanceState = .idle;
            if (firstOpen(app)) most = moreUrgent(most, stateOf(app, null));
            for (app.child_agents.items) |child| {
                most = moreUrgent(most, stateOf(app, child));
            }
            return busyAs(most) orelse .idle;
        }

        /// The first open agent other than the one on screen that is busy:
        /// a turn going or queued, an approval or a question open, or a
        /// request only the user can continue. Restarting fx would stop it.
        /// Null when every other agent is idle. Its name may use `buf`.
        /// Main loop only: it reads every agent's prompts.
        pub fn busyAgentElsewhere(app: *App, buf: []u8) ?BusyAgent {
            if (app.agent_on_screen != null and firstOpen(app)) {
                if (busyAs(stateOf(app, null))) |doing| {
                    return .{ .name = noteName(app, null, buf), .doing = doing };
                }
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                if (busyAs(stateOf(app, child))) |doing| {
                    return .{ .name = noteName(app, child, buf), .doing = doing };
                }
            }
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

        /// The footer note for hidden subagents that work, such as "1
        /// subagent working", so the agent on screen shows that work goes on
        /// elsewhere; empty when none does. One that waits for the user is
        /// in the waiting note, or on screen, instead.
        pub fn workingNote(app: *App, buf: []u8) []const u8 {
            var count: usize = 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent or child == app.agent_on_screen) continue;
                if (stateOf(app, child) == .working) count += 1;
            }
            if (count == 0) return "";
            return std.mem.print(buf, "{d} subagent{s} working", .{ count, if (count == 1) "" else "s" }) catch "";
        }

        /// How many of the agent on screen's own subagents have a turn going
        /// while its own turn has ended; 0 while it has a turn of its own. A
        /// subagent whose turn has ended but is not applied yet counts too,
        /// as `stateOf` shows it working in the list.
        pub fn subagentWaitCount(app: *App) usize {
            const screen = agents.screenAgentOf(app);
            if (turnInFlight(screen)) return 0;
            var count: usize = 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent) continue;
                if (ownerOf(app, hostOf(app, child)) != screen) continue;
                if (turnInFlight(&child.agent) or resultPending(app, child)) count += 1;
            }
            return count;
        }

        /// The activity row for an agent on screen whose turn ended while its
        /// own subagents still work, such as "• waiting on 3 subagents (12s)
        /// · ↓ to view", so an idle parent does not look stopped. The clock
        /// counts from when the agent's newest turn ended, and is left out
        /// when that turn saved no end time, such as a stopped or failed one.
        /// Empty label otherwise.
        pub fn subagentWaitStatus(app: *App) SubagentWait {
            const count = subagentWaitCount(app);
            if (count == 0) return .{};
            const screen = agents.screenAgentOf(app);
            const now_ms = io_mod.milliTimestamp();
            const ended_at = newestTurnEndedAt(screen.session.agent.history.items);
            const since_ms: i64 = if (ended_at > 0 and ended_at <= now_ms) ended_at else 0;
            var out: std.Io.Writer = .fixed(&app.instances.subagent_wait_buf);
            out.print("• waiting on {d} subagent{s}", .{ count, if (count == 1) "" else "s" }) catch return .{};
            if (since_ms > 0) {
                out.writeAll(" (") catch return .{};
                activity_status.writeElapsed(&out, @divTrunc(now_ms - since_ms, activity_status.activity_clock_ms_per_second)) catch return .{};
                out.writeByte(')') catch return .{};
            }
            out.print(" · {s} to view", .{switchKey(app)}) catch return .{};
            return .{ .label = out.buffered(), .since_ms = since_ms };
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
            listRestoredSubagents(app);
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const menu = &app.instances.agents_menu;
            menu.selected = positionIn(order.items, app.agent_on_screen) orelse 0;
            menu.window_start = 0;
            menu.highlight = .{ .agent = app.agent_on_screen };
            menu.origin = .{ .agent = app.agent_on_screen };
            menu.close_armed = null;
            setDraftAside(app);
            menu.open = true;
            debug_trace.eventf("host", "agents_menu_opened", .{}, "agents={d} position={d} agent={s}", .{
                order.items.len,
                menu.selected + 1,
                nameOf(app.agent_on_screen),
            });
            app.shell.render_requests.request(.footer);
        }

        /// Closes the list, keeping on screen the agent it shows. A paste and
        /// another surface taking the footer close it this way.
        pub fn closeMenu(app: *App) bool {
            if (!menuActive(app)) return false;
            endMenu(app);
            debug_trace.eventf("host", "agents_menu_closed", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        fn endMenu(app: *App) void {
            const menu = &app.instances.agents_menu;
            menu.open = false;
            menu.highlight = .on_screen;
            menu.origin = .on_screen;
            menu.close_armed = null;
            putDraftBack(app);
            app.shell.render_requests.request(.footer);
        }

        /// Sets the on-screen agent's draft aside, so the composer is the
        /// open list's search box.
        fn setDraftAside(app: *App) void {
            const menu = &app.instances.agents_menu;
            if (menu.draft != null) return;
            menu.draft = composer_stash.State.capture(app.input_runtime.composerStashView());
        }

        /// Gives the composer its draft back, dropping the search typed in it.
        fn putDraftBack(app: *App) void {
            const menu = &app.instances.agents_menu;
            if (menu.draft) |*draft| {
                const search_bytes = app.input_runtime.edit_state.input.items.len;
                if (search_bytes > 0) debug_trace.logf("host", "agent list search dropped bytes={d}", .{search_bytes});
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                draft.restore(app.alloc, app.input_runtime.composerStashView());
                menu.draft = null;
            }
        }

        /// The composer's search changed, so rows came or went: the list
        /// scrolls back to its top, a close the first Delete armed lapses,
        /// and when the highlight moved to another row the list shows its
        /// agent, as a move does.
        pub fn searchChanged(app: *App) void {
            if (!menuActive(app)) return;
            const menu = &app.instances.agents_menu;
            menu.close_armed = null;
            menu.window_start = 0;
            previewHighlight(app) catch |err| {
                debug_trace.logf("host", "agent list search preview failed err={s}; keeping agent={s}", .{ @errorName(err), nameOf(app.agent_on_screen) });
            };
            debug_trace.eventf("host", "agents_menu_search", .{}, "bytes={d} agent={s}", .{ searchText(app).len, nameOf(app.agent_on_screen) });
            app.shell.render_requests.request(.footer);
        }

        /// Shows the agent on the highlighted row when another is on screen,
        /// and keeps the highlight on it. After a search edit that is the
        /// agent on screen when it still matches, else the first match
        /// (`tests/tla/agents_menu/spec/AgentsMenu.tla` PreviewOnSearch).
        /// With no match there is no row, and the agent shown stays.
        fn previewHighlight(app: *App) !void {
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return;
            const menu = &app.instances.agents_menu;
            const target = order.items[@min(menu.selected, order.items.len - 1)];
            menu.highlight = .{ .agent = target };
            if (target != app.agent_on_screen) try show(app, target);
        }

        /// Esc, Ctrl+X, and Ctrl+C: closes the list and shows again the agent
        /// it opened on. If that agent closed meanwhile, the one shown stays
        /// (`tests/tla/agents_menu/spec/AgentsMenu.tla` BackToOrigin).
        pub fn backMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            const origin = app.instances.agents_menu.origin;
            endMenu(app);
            switch (origin) {
                .agent => |agent| {
                    var order: std.ArrayList(?*ChildAgent) = .empty;
                    defer order.deinit(app.alloc);
                    try switchList(app, &order);
                    if (positionIn(order.items, agent) != null) {
                        try show(app, agent);
                    } else {
                        debug_trace.logf("host", "agents menu origin closed; keeping agent={s}", .{nameOf(app.agent_on_screen)});
                    }
                },
                .on_screen => debug_trace.logf("host", "agents menu origin closed; keeping agent={s}", .{nameOf(app.agent_on_screen)}),
            }
            debug_trace.eventf("host", "agents_menu_back", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        /// Moves the list's highlight by `delta`, keeping it in view in
        /// `row_budget` rows, and shows the agent it lands on: the list
        /// previews by switching (`tests/tla/agents_menu/spec/AgentsMenu.tla`
        /// PreviewOnMove). Up on the first row has nothing above it, so it
        /// closes the list and keeps the agent shown (UpOnTopCloses); Down on
        /// the last row stays there.
        pub fn moveMenu(app: *App, delta: i32, row_budget: u16) !bool {
            if (!menuActive(app)) return false;
            disarmClose(app);
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return true;
            const menu = &app.instances.agents_menu;
            const current = @min(menu.selected, order.items.len - 1);
            if (delta < 0 and current == 0) {
                endMenu(app);
                debug_trace.eventf("host", "agents_menu_closed", .{}, "agent={s} reason=first_row", .{nameOf(app.agent_on_screen)});
                return true;
            }
            const last: i64 = @intCast(order.items.len - 1);
            menu.selected = @intCast(std.math.clamp(@as(i64, @intCast(current)) + delta, 0, last));
            const target = order.items[menu.selected];
            menu.highlight = .{ .agent = target };
            if (target != app.agent_on_screen) try show(app, target);
            menu.window_start = agents_menu_presentation.windowStart(menuProjection(app), row_budget);
            app.shell.render_requests.request(.footer);
            debug_trace.eventf("host", "agents_menu_previewed", .{}, "position={d} agent={s}", .{ menu.selected + 1, nameOf(target) });
            return true;
        }

        /// Enter: closes the list and keeps the highlighted agent on screen,
        /// which the preview already shows; a list that changed under it
        /// shows it now.
        pub fn submitMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const selected = app.instances.agents_menu.selected;
            endMenu(app);
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
            menu.names.clearRetainingCapacity();
            menu.names.ensureTotalCapacity(app.alloc, order.items.len * instance_name_bytes) catch return .{};
            menu.activities.clearRetainingCapacity();
            menu.activities.ensureTotalCapacity(app.alloc, order.items.len * activity_bytes) catch return .{};
            const now_ms = io_mod.milliTimestamp();
            for (order.items) |target| {
                const agent = targetAgent(app, target);
                const subagent: ?*ChildAgent = if (target) |child| (if (child.agent.role == .subagent) child else null) else null;
                const model = provider_runtime.modelOf(app, agent);
                const state = stateOf(app, target);
                const name = noteName(app, target, menu.names.addManyAsArrayAssumeCapacity(instance_name_bytes));
                const activity = rowActivity(app, subagent, state, now_ms, menu.activities.addManyAsArrayAssumeCapacity(activity_bytes));
                menu.rows.appendAssumeCapacity(.{
                    .name = name,
                    .subagent = subagent != null,
                    // A search lists its matches flat, since their parents may not match.
                    .nested = if (subagent) |child| searchText(app).len == 0 and parentSubagent(app, child) != null else false,
                    .title = agent.session_title.items,
                    // A subagent's own agent never loads its profile; its
                    // host's list says which one it runs in.
                    .profile = listedProfile(if (subagent) |child| child.profile else agent.profile.profile.name),
                    .state = activity.state orelse state.label(),
                    .state_tone = state.tone(),
                    .activity = activity.call,
                    .model = model,
                    .effort = effortLabel(app, agent, model),
                });
            }
            if (menu.selected >= menu.rows.items.len) menu.selected = menu.rows.items.len -| 1;
            if (order.items.len == 0) return .{ .rows = menu.rows.items, .search = searchText(app) };
            const chosen = order.items[@min(menu.selected, order.items.len - 1)];
            const closable = deleteCloses(app, chosen);
            return .{
                .rows = menu.rows.items,
                .selected = menu.selected,
                .window_start = menu.window_start,
                .selected_closable = closable,
                .selected_instance = isInstance(chosen),
                .close_armed = closable and armedFor(menu, chosen),
                .search = searchText(app),
            };
        }

        /// The profile the agent list names: none for the main one.
        fn listedProfile(name: []const u8) []const u8 {
            return if (std.mem.eql(u8, name, profiles.main_name)) "" else name;
        }

        /// Delete in the agent list: the first press on a row arms its close,
        /// and the second closes it: a subagent for good (`closeSubagent`), an
        /// instance as `/close` does (`closeInstanceFromMenu`). The last open
        /// instance stays, since closing it would end fx.
        pub fn pressCloseKey(app: *App) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return true;
            const menu = &app.instances.agents_menu;
            const target = order.items[@min(menu.selected, order.items.len - 1)];
            if (!deleteCloses(app, target)) return true;
            if (!armedFor(menu, target)) {
                menu.close_armed = .{ .agent = target };
                debug_trace.eventf("host", "agents_menu_close_armed", .{}, "agent={s}", .{if (target) |child| child.id else "first"});
                // Its warning shows now, not at the next frame something else asks for.
                app.shell.render_requests.request(.footer);
                return true;
            }
            menu.close_armed = null;
            if (isInstance(target)) {
                try closeInstanceFromMenu(app, target);
            } else {
                try closeSubagent(app, target.?);
            }
            return true;
        }

        /// Whether `target`'s row is an instance's, null being the first.
        fn isInstance(target: ?*ChildAgent) bool {
            const child = target orelse return true;
            return child.agent.role != .subagent;
        }

        /// Whether Delete closes `target`'s row: any subagent, and an instance
        /// while another stays open.
        fn deleteCloses(app: *App, target: ?*ChildAgent) bool {
            return !isInstance(target) or openInstanceCount(app) > 1;
        }

        fn armedFor(menu: *const AgentsMenu, target: ?*ChildAgent) bool {
            const armed = menu.close_armed orelse return false;
            return armed.agent == target;
        }

        /// Closes instance `target`, null for the first, and every subagent in
        /// its tree, as `/close` does on its screen. When one of them is on
        /// screen, the row above it takes its place, or the next instance
        /// when it is the first row, and the list stays open with the agent
        /// on screen highlighted. Call only while another instance runs.
        fn closeInstanceFromMenu(app: *App, target: ?*ChildAgent) !void {
            const menu = &app.instances.agents_menu;
            if (target) |child| try closeInstance(app, child) else try closeFirstInstance(app);
            if (menuActive(app)) {
                // The highlight was on `target`, so it moves to the agent on
                // screen.
                var order: std.ArrayList(?*ChildAgent) = .empty;
                defer order.deinit(app.alloc);
                try switchList(app, &order);
                menu.window_start = @min(menu.window_start, menu.selected);
                app.shell.render_requests.request(.footer);
            }
        }

        /// Any key but Delete disarms a close the first Delete armed, and its warning
        /// goes at once.
        pub fn disarmClose(app: *App) void {
            if (comptime !@hasField(App, "instances")) return;
            const menu = &app.instances.agents_menu;
            if (menu.close_armed == null) return;
            menu.close_armed = null;
            debug_trace.eventf("host", "agents_menu_close_disarmed", .{}, "reason=key", .{});
            app.shell.render_requests.request(.footer);
        }

        /// Closes subagent `child` for good, as the user's close from the
        /// agent list: its host stops its work and writes the close, and its
        /// agent, with every subagent it started, leaves the list at once.
        fn closeSubagent(app: *App, child: *ChildAgent) !void {
            const host = hostOf(app, child) orelse {
                debug_trace.logf("host", "close dropped agent={s} reason=no_host", .{child.id});
                return;
            };
            const id = try app.alloc.dupe(u8, child.id);
            defer app.alloc.free(id);
            const closed = host.closeChild(id, .user) catch |err| switch (err) {
                // Its host keeps it listed, so its agent stays too.
                error.CloseNotSaved => {
                    debug_trace.logf("host", "close not saved agent={s}", .{id});
                    return;
                },
                else => return err,
            };
            if (closed == null) {
                debug_trace.logf("host", "close found no child agent={s}", .{id});
                return;
            }
            _ = try dropClosedSubagents(app);
        }

        /// Drops the agents of the subagents their hosts closed, by their
        /// parent's `close` or from the agent list, each with every subagent
        /// it started (`closeBranch`). Cheap when none is. Returns whether it
        /// dropped any.
        pub fn dropClosedSubagents(app: *App) !bool {
            var dropped = false;
            // Dropping a branch can free hosts, so each pass looks afresh.
            while (try takeAnyClosed(app)) |ids| {
                defer {
                    for (ids) |id| app.alloc.free(id);
                    app.alloc.free(ids);
                }
                for (ids) |id| if (findChild(app, id)) |child| {
                    try closeBranch(app, child);
                    dropped = true;
                };
            }
            return dropped;
        }

        /// The children some host closed since it was last asked, or null.
        /// The caller owns them.
        fn takeAnyClosed(app: *App) !?[][]u8 {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return null;
            if (firstOpen(app)) if (app.main_agent.session_persistence.subagent_host) |host| {
                const ids = try host.takeClosed(app.alloc);
                if (ids.len > 0) return ids;
            };
            for (app.child_agents.items) |child| if (child.agent.session_persistence.subagent_host) |host| {
                const ids = try host.takeClosed(app.alloc);
                if (ids.len > 0) return ids;
            };
            return null;
        }

        /// Whether subagent `entry` was started by `ancestor`, or by a
        /// subagent `ancestor` started.
        fn descendsFrom(app: *App, entry: *const ChildAgent, ancestor: *const ChildAgent) bool {
            var current = entry;
            while (current.agent.role == .subagent) {
                const owner = ownerOf(app, hostOf(app, current)) orelse return false;
                const hosted = hostedOf(app, owner) orelse return false;
                if (hosted == ancestor) return true;
                current = hosted;
            }
            return false;
        }

        fn inBranch(branch: []const *ChildAgent, value: ?*ChildAgent) bool {
            const wanted = value orelse return false;
            return std.mem.findScalar(*ChildAgent, branch, wanted) != null;
        }

        /// Drops subagent `child`, which its host closed, and every subagent
        /// it started, each before the agent that started it, as `/close`
        /// drops an instance's tree. When one of them is on screen, the agent
        /// on the row above `child` takes its place, as it does for a closed
        /// instance (`tests/tla/agents_menu/spec/AgentsMenu.tla`
        /// CloseShowsRowAbove); the agent that started `child` does when
        /// `child` is not listed.
        fn closeBranch(app: *App, child: *ChildAgent) !void {
            var branch: std.ArrayList(*ChildAgent) = .empty;
            defer branch.deinit(app.alloc);
            try branch.append(app.alloc, child);
            for (app.child_agents.items) |entry| {
                if (entry != child and descendsFrom(app, entry, child)) try branch.append(app.alloc, entry);
            }
            const parent: ?*ChildAgent = if (ownerOf(app, hostOf(app, child))) |owner| hostedOf(app, owner) else null;
            if (inBranch(branch.items, app.agent_on_screen)) {
                const above = try rowAbove(app, child);
                try show(app, if (above) |row| row.agent else parent);
            }
            const menu = &app.instances.agents_menu;
            stopSet(app, branch.items, null);
            debug_trace.eventf("host", "subagent_closed", .{}, "agent={s} subagents={d}", .{ child.id, branch.items.len - 1 });
            dropSet(app, branch.items);
            // The list's highlight stays on its agent, not on whichever row
            // took the closed one's place, or moves to the agent on screen
            // when its agent closed.
            if (menuActive(app)) {
                var order: std.ArrayList(?*ChildAgent) = .empty;
                defer order.deinit(app.alloc);
                try switchList(app, &order);
                menu.window_start = @min(menu.window_start, menu.selected);
                app.shell.render_requests.request(.footer);
            }
        }

        /// Stops `set`, agents each listed after the agent that started
        /// them, as a close does: an armed close of one and their lent prompts
        /// go back, `first_host` and then their own hosts stop so no work the
        /// close ends owes a report into the set, and each turn ends
        /// cancelled. `dropSet` drops them after.
        fn stopSet(app: *App, set: []const *ChildAgent, first_host: ?*subagent_tool_host.Runtime) void {
            const menu = &app.instances.agents_menu;
            if (menu.close_armed) |armed| if (inBranch(set, armed.agent)) {
                menu.close_armed = null;
                debug_trace.eventf("host", "agents_menu_close_disarmed", .{}, "reason=closed", .{});
            };
            if (inBranch(set, app.approval_lender)) _ = returnApproval(app);
            if (inBranch(set, app.question_lender)) _ = returnQuestion(app);
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (first_host) |host| host.closeTree();
                for (set) |entry| if (entry.agent.session_persistence.subagent_host) |host| host.closeTree();
            }
            for (set) |entry| {
                entry.agent.worker.requestCancel();
                entry.agent.worker.requestShutdown();
                entry.agent.managed_executions.shutdown();
            }
            for (set) |entry| {
                if (entry.agent.worker_thread) |thread| thread.join();
                entry.agent.worker_thread = null;
                if (entry.agent.child_run) |*run| {
                    finishRun(run, .cancelled);
                    // A turn the user started ends with the close, owing nothing.
                    if (hostOf(app, entry)) |host| endUserWork(app.alloc, host, run, .cancelled, "");
                }
            }
        }

        /// Drops `set`, stopped by `stopSet`, each agent before the agent
        /// that started it.
        fn dropSet(app: *App, set: []const *ChildAgent) void {
            var index = set.len;
            while (index > 0) {
                index -= 1;
                dropHosted(app, set[index]);
            }
        }

        /// `agent`'s reasoning effort as the status line shows it beside
        /// `model`: its name when the model takes one and it is not the
        /// default, else empty. Borrows `agent`.
        fn effortLabel(app: *App, agent: *const AppAgent, model: []const u8) []const u8 {
            if (agent.effort.isDefault()) return "";
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (capabilities.reasoning_efforts.len == 0) return "";
            if (!model_capabilities.reasoningEffortSupported(capabilities, agent.effort)) return "";
            return agent.effort.displayLabel();
        }

        /// Applies every agent's finished title generation, shown or not, so
        /// the agent list names a hidden agent by its title as soon as it
        /// has one. Returns whether a title changed.
        pub fn pollSessionTitles(app: *App) !bool {
            const SessionRuntime = app_session_runtime.Runtime(App);
            var changed = false;
            if (firstOpen(app)) changed = try SessionRuntime.pollSessionTitleGeneration(app, &app.main_agent);
            for (app.child_agents.items) |child| {
                if (try SessionRuntime.pollSessionTitleGeneration(app, &child.agent)) changed = true;
            }
            return changed;
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

        /// The subagent that started subagent `child`; null when an instance
        /// did.
        fn parentSubagent(app: *App, child: *const ChildAgent) ?*ChildAgent {
            const owner = ownerOf(app, hostOf(app, child)) orelse return null;
            const hosted = hostedOf(app, owner) orelse return null;
            return if (hosted.agent.role == .subagent) hosted else null;
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
            // The tab names the agent on screen, as a second fx's would.
            app_session_runtime.Runtime(App).syncTerminalTitle(app, agents.screenAgentOf(app));
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
            // The open list's search box lends the composer: each agent keeps
            // its own draft, and the arriving one's is set aside in turn. The
            // search typed in the box, with its cursor and selection, goes on
            // with the list, which shows each agent it highlights by switching
            // to it.
            const searching = menuActive(app);
            var search: composer_stash.State = if (searching) composer_stash.State.capture(app.input_runtime.composerStashView()) else .{};
            if (searching) putDraftBack(app);
            leaving.draft = composer_stash.State.capture(app.input_runtime.composerStashView());
            app.shell.swapSlot(&leaving.transcript);
            TranscriptRuntime.slotLeftScreen(&leaving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &leaving.pacer);
            std.mem.swap(bool, &app.fast_mode, &leaving.fast_mode);
            app.shell.swapSlot(&arriving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &arriving.pacer);
            std.mem.swap(bool, &app.fast_mode, &arriving.fast_mode);
            arriving.draft.restore(app.alloc, app.input_runtime.composerStashView());
            if (searching) {
                setDraftAside(app);
                search.restore(app.alloc, app.input_runtime.composerStashView());
            }
            app.agent_on_screen = target;
            app.screen_owner = if (target) |child| &child.agent else null;
        }

        /// Whether a turn of `child`'s is going, its paced output included. A
        /// turn reads the run installed on the agent until its last event is
        /// applied, so nothing replaces that run before then.
        fn turnGoing(app: *App, child: *ChildAgent) bool {
            return child.workGoing() or pacerOf(app, child).hasPending();
        }

        /// The pacer that holds `child`'s assistant text: the app's while the
        /// child is on screen, its own slot's otherwise.
        fn pacerOf(app: *App, child: *ChildAgent) *AssistantPacer {
            return if (app.agent_on_screen == child) &app.pacer else &child.screen.pacer;
        }

        /// The app's subagents in the order they started, for `/trace`.
        /// Main loop only. `alloc` owns each row's `status`.
        pub fn traceRows(app: *App, alloc: Allocator, out: *std.ArrayList(TraceRow)) !void {
            for (app.child_agents.items) |child| {
                const agent = &child.agent;
                if (agent.role != .subagent) continue;
                const model = provider_runtime.modelOf(app, agent);
                try out.append(alloc, .{
                    .id = child.id,
                    .name = child.name,
                    .profile = if (child.profile.len > 0) child.profile else profiles.main_name,
                    .title = agent.session_title.items,
                    .state = @tagName(stateOf(app, child)),
                    .model = model,
                    .effort = effortLabel(app, agent, model),
                    .status = try statusText(app, child, alloc),
                    .host = child.parent_host,
                });
            }
        }

        /// A copy of the label on agent `target`'s status row, or empty.
        fn statusText(app: *App, target: ?*ChildAgent, alloc: Allocator) ![]const u8 {
            const state: *const worker_status.State = if (target == app.agent_on_screen) blk: {
                if (comptime !@hasDecl(@TypeOf(app.shell), "worker_status_state")) return "";
                break :blk app.shell.worker_status_state();
            } else &screenOf(app, target).transcript.notebook.worker_status;
            const projection = state.projection() orelse return "";
            return switch (projection) {
                .turn_thinking => |row| try alloc.dupe(u8, row.label),
                .none, .tool_slot => "",
            };
        }

        fn screenOf(app: *App, child: ?*ChildAgent) *ScreenSlot {
            return if (child) |value| &value.screen else &app.main_screen;
        }

        const RowActivity = struct { call: []const u8 = "", state: ?[]const u8 = null };

        /// A working subagent's current call and its state with that call's
        /// time, such as "working 12s", from its host, written into `buf`;
        /// nothing for any other row.
        fn rowActivity(app: *App, subagent: ?*ChildAgent, state: InstanceState, now_ms: i64, buf: *[activity_bytes]u8) RowActivity {
            if (state != .working) return .{};
            const child = subagent orelse return .{};
            const host = hostOf(app, child) orelse return .{};
            const call = host.childCall(child.id) orelse return .{};
            const label = call.label();
            @memcpy(buf[0..label.len], label);
            var writer = std.Io.Writer.fixed(buf[label.len..]);
            writer.print("{s} ", .{state.label()}) catch return .{ .call = buf[0..label.len] };
            activity_status.writeElapsed(&writer, @intCast(call.runningMs(now_ms) / std.time.ms_per_s)) catch return .{ .call = buf[0..label.len] };
            return .{ .call = buf[0..label.len], .state = writer.buffered() };
        }

        /// Whether the turn `child`'s worker has finished is still being
        /// applied: its events wait for the loop, or its pacer holds the
        /// finish while the reply is shown. Its reply reaches the history
        /// only after that.
        fn resultPending(app: *App, child: *ChildAgent) bool {
            return child.hasUnapplied(pacerOf(app, child));
        }

        /// What agent `target`, null for the first instance, waits for or
        /// does. A subagent whose approval or question its instance's screen
        /// shows for it still waits on it. A subagent whose turn has ended
        /// but is not applied yet is still working: the list places it by the
        /// newest reply in its history, so its state and its place change
        /// together, as `tests/tla/agents_menu/spec/RowOrder.tla`
        /// PlaceChangesWithLabel requires.
        fn stateOf(app: *App, target: ?*ChildAgent) InstanceState {
            if (target) |child| {
                if (app.approval_lender == child) return .needs_approval;
                if (app.question_lender == child) return .has_question;
            }
            const state = instanceState(targetAgent(app, target), requestWaitsForUser(app, target));
            const child = target orelse return state;
            if (child.agent.role != .subagent) return state;
            return switch (state) {
                .idle, .finished => if (resultPending(app, child)) .working else state,
                .working, .needs_approval, .has_question, .needs_you => state,
            };
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
            noteQuitting(app);
            attach(app, null);
            closeHandoffs(app);
            // A slot thread still reads its child's worker while it detaches,
            // so each worker is told to stop and each slot lets go before any
            // agent is freed, as `dropHosted` does for one. One whose slot
            // never lets go is closed but kept.
            for (app.child_agents.items) |child| {
                child.agent.worker.requestShutdown();
                child.agent.managed_executions.shutdown();
            }
            for (app.child_agents.items) |child| _ = child.bound.waitReleased(releaseTimeoutMs());
            var index = app.child_agents.items.len;
            while (index > 0) {
                index -= 1;
                const child = app.child_agents.items[index];
                const kept = child.bound.held();
                const closed = if (kept) visit(app, child, {}, closeInContext) else visit(app, child, {}, shutdownInContext);
                closed catch |err| {
                    app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
                };
                if (kept) noteKept(child, "shutdown");
            }
        }

        /// Logs `child`, kept allocated because a slot thread still holds its
        /// worker after `release_timeout_ms`: its finished turns are saved and
        /// its session is closed, but its agent and worker are not freed.
        fn noteKept(child: *const ChildAgent, at: []const u8) void {
            debug_trace.logf(
                "host",
                "child_release_timeout child={s} at={s} kept=agent,worker reason=slot_thread_holds_worker finished_prompts=settled session=closed",
                .{ child.id, at },
            );
        }

        /// Stops every child agent's worker and ends each run in flight. Runs
        /// before main's worker is joined, because main's worker can be
        /// waiting on a subagent call, which waits for its run to end. Each
        /// worker is joined before its run ends, so no worker still uses the
        /// run's turn context once the slot thread frees it.
        pub fn stopChildren(app: *App, comptime mode: enum { cooperative, force }) void {
            noteQuitting(app);
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
        /// call waits. `deliverReport` uses the
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
            const owner_child: ?*ChildAgent = if (message and post.from_owner) blk: {
                const owner = ownerOf(app, post.host) orelse return error.AgentGone;
                break :blk hostedOf(app, owner) orelse return error.AgentGone;
            } else null;
            const sender = if (owner_child) |child| (if (child.name.len > 0) child.name else child.id) else post.agent;
            // Who started the turn that sent a message, from the host that
            // runs the sender. That turn is still going: posts are taken
            // each pass before the children's events, its end among them.
            const started_by: ?subagent_reports.StartedBy = if (!message)
                null
            else if (owner_child) |child|
                if (hostOf(app, child)) |host| host.turnStartedBy(child.id) else null
            else
                post.host.turnStartedBy(post.child_id);
            const limit = target.worker.effectiveAgentTurnSettings().max_tool_result_bytes;
            const text = switch (post.kind) {
                .report => try subagent_reports.message(app.alloc, .{
                    .agent = sender,
                    .child_id = post.child_id,
                    .work_id = post.work_id,
                    .outcome = post.outcome,
                    .output = post.text,
                    .dropped = post.dropped,
                    .end = post.end,
                    .idle = post.idle,
                }, limit),
                .message => subagent_reports.messageText(app.alloc, sender, post.child_id, post.text, limit, started_by, post.typed_lines) catch |err| {
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

        /// Tells every subagent host that fx is quitting, before any child
        /// stops, so the works the quit cancels say so in their reports.
        fn noteQuitting(app: *App) void {
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| host.noteQuitting();
            for (app.child_agents.items) |child| {
                const host = child.agent.session_persistence.subagent_host orelse continue;
                host.noteQuitting();
            }
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
        /// it. When one of them is on screen, the row above `child` is shown
        /// first, or the next instance when `child` is the first row. The
        /// rest of the host keeps running.
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

        /// When instance `root`, which `hosted` holds or null for the first,
        /// or a subagent of its tree is on screen, shows the agent on the row
        /// above the instance's, as the agent list orders them, or `next`
        /// when it is the first row (`tests/tla/agents_menu/spec/AgentsMenu.tla`
        /// CloseShowsRowAbove). Then stops and drops every subagent in the
        /// tree, each before the agent that started it. The instance's own
        /// turn is cancelled; its teardown is the caller's.
        fn closeTree(app: *App, root: *AppAgent, hosted: ?*ChildAgent, next: ?*ChildAgent, label: []const u8) !void {
            var tree: std.ArrayList(*ChildAgent) = .empty;
            defer tree.deinit(app.alloc);
            for (app.child_agents.items) |entry| {
                if (entry.agent.role == .subagent and rootInstance(app, entry) == root) try tree.append(app.alloc, entry);
            }
            const on_screen = app.agent_on_screen;
            if (on_screen == hosted or inBranch(tree.items, on_screen)) {
                const above = try rowAbove(app, hosted);
                try show(app, if (above) |row| row.agent else next);
            }
            // The instance's own host stops first, so no work the close ends
            // owes a report into the tree.
            const root_host: ?*subagent_tool_host.Runtime = if (comptime agents.hasAgentField(App, "session_persistence")) root.session_persistence.subagent_host else null;
            stopSet(app, tree.items, root_host);
            root.worker.requestCancel();
            debug_trace.eventf("host", "instance_closed", .{}, "agent={s} subagents={d}", .{ label, tree.items.len });
            dropSet(app, tree.items);
        }

        /// Stops and drops the subagents in `root`'s tree before a session
        /// switch closes `root`'s session, as `/close` stops an instance's
        /// tree, so the subagent host never joins a slot thread that waits
        /// for this loop (`tests/tla/session_manager/Wiring.tla` SwitchEnds,
        /// D97). Nothing is closed for good: the session's log keeps them,
        /// so its next open lists them again, and only the work they had
        /// running ends, as cancelled, owing no report. When one of them is
        /// on screen, `root` takes its place. Returns how many had work
        /// running.
        pub fn stopSubagentsForSwitch(app: *App, root: *AppAgent) !usize {
            var tree: std.ArrayList(*ChildAgent) = .empty;
            defer tree.deinit(app.alloc);
            var working: usize = 0;
            for (app.child_agents.items) |entry| {
                if (entry.agent.role != .subagent or rootInstance(app, entry) != root) continue;
                try tree.append(app.alloc, entry);
                if (entry.agent.child_run) |*run| {
                    if (run.inFlight()) working += 1;
                }
            }
            if (tree.items.len == 0) return 0;
            const hosted = hostedOf(app, root);
            if (inBranch(tree.items, app.agent_on_screen)) try show(app, hosted);
            // The root's host stops first, so no work the switch ends owes
            // a report into the tree.
            const root_host: ?*subagent_tool_host.Runtime = if (comptime agents.hasAgentField(App, "session_persistence")) root.session_persistence.subagent_host else null;
            stopSet(app, tree.items, root_host);
            debug_trace.eventf("host", "switch_stopped_subagents", .{}, "subagents={d} working={d}", .{ tree.items.len, working });
            dropSet(app, tree.items);
            return working;
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
        /// run's slot thread lets go, and drops it from the list. The slot
        /// thread still reads the agent's worker while it detaches from it, so
        /// the worker is told to stop, the slot lets go, and only then is the
        /// agent freed. Its session closes either way.
        pub fn dropHosted(app: *App, child: *ChildAgent) void {
            child.agent.worker.requestShutdown();
            child.agent.managed_executions.shutdown();
            // A slot thread that never lets go leaves the agent allocated and
            // its worker whole, so it reads no freed memory, rather than
            // freezing the screen.
            const released = child.bound.waitReleased(releaseTimeoutMs());
            const closed = if (released) visit(app, child, {}, shutdownInContext) else visit(app, child, {}, closeInContext);
            closed catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
            };
            if (!released) noteKept(child, "drop");
            {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                for (app.child_agents.items, 0..) |entry, index| if (entry == child) {
                    _ = app.child_agents.orderedRemove(index);
                    break;
                };
            }
            if (comptime @hasField(App, "instances")) {
                const menu = &app.instances.agents_menu;
                if (menu.highlight == .agent and menu.highlight.agent == child) menu.highlight = .on_screen;
                if (menu.origin == .agent and menu.origin.agent == child) menu.origin = .on_screen;
            }
            if (!released) return;
            child.screen.deinit(app.alloc);
            if (child.name.len > 0) app.alloc.free(child.name);
            if (child.profile.len > 0) app.alloc.free(child.profile);
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
            if (saved_work == null and run.turn_work_id.len > 0) {
                const host = hostOf(app, hostedOf(app, agent) orelse return) orelse return;
                const reply = switch (finished.turn) {
                    .assistant => |value| value.assistant,
                    .interrupted => |value| value.assistant orelse "",
                    .compacted_summary => "",
                };
                endAndFollowUserWork(app.alloc, host, run, &agent.worker, userWorkOutcome(run, finished.terminal_outcome orelse .completed), reply);
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
            const run = runInFlight(app, agent) orelse userWorkRun(app, agent) orelse return;
            const child = hostedOf(app, agent) orelse return;
            const host = hostOf(app, child) orelse return;
            const drop = agent.worker.dropAgentMessages(std.heap.c_allocator);
            host.userStopped(run.child_id, drop.from_parent);
        }

        /// Opens the work for a turn `agent`'s worker began on a subagent with
        /// none going for it: the user's prompt it
        /// took after a hand-off, or a report from the subagent's own child.
        /// The parent's messages and the user's turns started on an idle
        /// subagent open theirs where they are admitted.
        pub fn noteChildTurnBegun(app: *App, agent: *AppAgent, author: types.MessageAuthor) void {
            if (runInFlight(app, agent) != null or userWorkRun(app, agent) != null) return;
            const child = hostedOf(app, agent) orelse return;
            if (child.agent.role != .subagent) return;
            const run = if (child.agent.child_run) |*value| value else return;
            const started_by: subagent_reports.StartedBy = switch (author) {
                .user => .user,
                .child => .child,
                else => return,
            };
            const host = hostOf(app, child) orelse return;
            if (host.beginTurnWork(app.alloc, child.id, started_by, &child.agent.worker)) |work_id| run.turn_work_id = work_id;
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
                if (run.turn_work_id.len > 0) {
                    const host = hostOf(app, child) orelse continue;
                    endAndFollowUserWork(app.alloc, host, run, &child.agent.worker, userWorkOutcome(run, outcome), "");
                    continue;
                }
                if (!run.inFlight()) continue;
                endRun(run, outcome);
            }
        }

        /// The run of a turn the parent didn't start, while the work it
        /// opened in the parent's log is open.
        fn userWorkRun(app: *App, agent: *AppAgent) ?*agents.ChildRun {
            if (agent == &app.main_agent) return null;
            const run = if (agent.child_run) |*value| value else return null;
            return if (run.turn_work_id.len > 0) run else null;
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
        fn endAndFollowUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, worker: *worker_runtime.WorkerRuntime, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            const handed_off = run.handed_off;
            endUserWork(alloc, host, run, outcome, reply);
            if (handed_off) if (host.beginUserWork(alloc, run.child_id, worker)) |work_id| {
                run.turn_work_id = work_id;
            };
        }

        /// Ends the work a user's turn opened, once.
        fn endUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            if (run.turn_work_id.len == 0) return;
            const work_id = run.turn_work_id;
            run.turn_work_id = &.{};
            run.ended_as = null;
            run.handed_off = false;
            defer alloc.free(work_id);
            debug_trace.eventf("host", "user_work_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, work_id, @tagName(outcome) });
            host.endUserWork(run.child_id, work_id, outcome, reply);
        }

        /// A subagent's request that starts waiting for the user waits for
        /// its parent too: the parent hears of it, and its message sends the
        /// request again (`noteChildWaiting`).
        pub fn noteChildWaiting(app: *App, agent: *AppAgent, status: types.RouteRecoveryStatus) void {
            if (agent.role != .subagent) return;
            const child = hostedOf(app, agent) orelse return;
            const host = hostOf(app, child) orelse return;
            const first = if (agent.child_run) |*run| first: {
                run.waits +|= 1;
                break :first run.waits == 1;
            } else false;
            const resend = first and parentMayResend(status.need);
            agent.worker.parent_may_continue.store(resend, .seq_cst);
            // The part the parent can use, without the keys for the user.
            const text = status.text.slice();
            host.noteChildWaiting(child.id, child.displayName(), if (std.mem.find(u8, text, " \u{b7} ")) |at| text[0..at] else text, resend);
        }

        /// A hosted subagent's tool events reach the app instead of its
        /// turn: its current call goes to its host, for status and the agent
        /// list, and a shell command that crossed the quiet limit is relayed
        /// to its parent (`noteChildQuiet`, `tests/tla/subagent/QuietRelay.tla`).
        pub fn noteChildToolLifecycle(app: *App, agent: *AppAgent, lifecycle: types.ToolLifecycleEvent) void {
            if (agent.role != .subagent) return;
            const child = hostedOf(app, agent) orelse return;
            const host = hostOf(app, child) orelse return;
            switch (lifecycle) {
                .authoritative_started => |started| {
                    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
                    defer arena_state.deinit();
                    const arena = arena_state.allocator();
                    const call: types.ToolCall = .{
                        .id = started.id.call_id,
                        .name = started.tool_name,
                        .arguments_json = started.arguments_json orelse "{}",
                    };
                    // The plain label, as fx ask names the call; the screen's
                    // own rows are styled.
                    const label = if (comptime @hasDecl(App, "toolRegistry") and @hasDecl(App, "resolveToolActionDisplayTarget")) label: {
                        const target = app.resolveToolActionDisplayTarget(agent, arena, call) catch null;
                        break :label tool_presentation.formatPlainAction(arena, .{
                            .tool_registry = app.toolRegistry(agent),
                            .call = call,
                            .display_target = target,
                        }) catch started.tool_name;
                    } else started.tool_name;
                    host.noteChildCall(child.id, started.id.call_id, label);
                },
                .terminal => |terminal| {
                    host.noteChildCall(child.id, terminal.id.call_id, null);
                    const memory = terminal.result_memory orelse return;
                    const crossing = memory.quiet_crossing orelse return;
                    host.noteChildQuiet(child.id, child.displayName(), crossing);
                },
                .provisional, .progress, .turn_finished => {},
            }
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

        fn shutdownInContext(context: void, app: *App, agent: *agents.Agent) anyerror!void {
            try closeInContext(context, app, agent);
            try freeInContext(context, app, agent);
        }

        /// Stops `agent` and closes its session: its worker stops and is
        /// joined, its finished turns are saved, and its session closes. It
        /// frees nothing a slot thread may still read, so it also runs for an
        /// agent whose slot thread has not let go.
        fn closeInContext(_: void, app: *App, agent: *agents.Agent) anyerror!void {
            agent.worker.requestShutdown();
            agent.managed_executions.shutdown();
            if (agent.worker_thread) |thread| thread.join();
            agent.worker_thread = null;
            app_worker_runtime.Runtime(App).settleFinishedPromptsForShutdown(app, agent) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(agent, err);
            };
            finalizeInstancePersistence(app, agent);
        }

        /// Frees `agent`'s state, once `closeInContext` closed it and no slot
        /// thread holds its worker.
        fn freeInContext(_: void, app: *App, agent: *agents.Agent) anyerror!void {
            agent.managed_executions.deinit();
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
        /// first. A child whose slot thread still holds its worker stays
        /// allocated, as `shutdownChildren` kept it.
        pub fn deinitChildren(app: *App) void {
            for (app.child_agents.items) |child| {
                if (child.bound.held()) {
                    debug_trace.logf("host", "child_kept child={s} at=deinit reason=slot_thread_holds_worker", .{child.id});
                    continue;
                }
                child.screen.deinit(app.alloc);
                if (child.name.len > 0) app.alloc.free(child.name);
                if (child.profile.len > 0) app.alloc.free(child.profile);
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

test "the cancel a run's wait repeats ends the question that run waits on" {
    const alloc = std.testing.allocator;
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var completion: agents.ChildRunCompletion = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const options = [_]types.QuestionOption{.{ .label = "Yes", .description = null }};
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};

    const Side = struct {
        fn ask(
            runtime: *worker_runtime.WorkerRuntime,
            batch: []const types.QuestionBatchEntry,
            answered: *std.atomic.Value(bool),
            returned: *std.Io.Event,
        ) void {
            defer returned.set(io_mod.getIo());
            const answers = (runtime.requestQuestionBatchAnswerBlocking(std.testing.allocator, batch) catch return) orelse return;
            for (answers) |answer| std.testing.allocator.free(answer);
            std.testing.allocator.free(answers);
            answered.store(true, .release);
        }

        fn wait(
            done: *agents.ChildRunCompletion,
            flag: *std.atomic.Value(bool),
            runtime: *worker_runtime.WorkerRuntime,
            outcome: *agents.ChildRunCompletion.Outcome,
        ) void {
            outcome.* = waitForCompletion(done, flag, runtime);
        }

        /// Whether the question opens within a bounded time. Nothing signals it, so
        /// it is polled; the end of the wait is waited for on an event.
        fn questionOpens(runtime: *worker_runtime.WorkerRuntime) bool {
            for (0..2000) |_| {
                var snapshot = runtime.snapshotPendingQuestionBatch(std.testing.allocator) catch return false;
                if (snapshot) |*batch| {
                    batch.deinit(std.testing.allocator);
                    return true;
                }
                io_mod.sleep(1 * std.time.ns_per_ms);
            }
            return false;
        }

        /// Whether the thread that asked has returned, so a question that does
        /// not end fails the test instead of hanging it.
        fn askerReturned(event: *std.Io.Event) bool {
            event.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(5000),
            } }) catch return false;
            return true;
        }
    };

    var answered = std.atomic.Value(bool).init(false);
    var returned: std.Io.Event = .unset;
    const asker = try std.Thread.spawn(.{}, Side.ask, .{ &worker, &entries, &answered, &returned });
    var outcome: agents.ChildRunCompletion.Outcome = .completed;
    const waiter = try std.Thread.spawn(.{}, Side.wait, .{ &completion, &cancel, &worker, &outcome });
    const opened = Side.questionOpens(&worker);
    cancel.store(true, .seq_cst);
    const ended = opened and Side.askerReturned(&returned);
    // A question that stayed open is released, so the test fails instead of hanging.
    if (!ended) worker.requestStop();
    completion.finish(.cancelled);
    waiter.join();
    asker.join();
    try std.testing.expect(opened);
    try std.testing.expect(ended);
    try std.testing.expect(!answered.load(.acquire));
    try std.testing.expectEqual(agents.ChildRunCompletion.Outcome.cancelled, outcome);
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

test "an instance's subagents waiting for the user come first, then the working ones, in the order they started, and the instance stays above them" {
    const entries = [_]OrderEntry{
        .{ .role = .subagent },
        .{ .role = .instance, .urgency = .working },
        .{ .role = .subagent, .root = 1, .urgency = .working },
        .{ .role = .subagent, .urgency = .working },
        .{ .role = .subagent, .urgency = .attention },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    // Start order: main, its three subagents, fx 2, its subagent.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5, 2, 3 }, &order);
    sortSubagentGroups(&entries, &order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 5, 4, 1, 2, 3 }, &order);
}

test "a subagent whose own subagent waits for the user moves up with it, above working and idle ones" {
    // Main started tester, then lead; lead started helper, which waits.
    var entries = [_]OrderEntry{
        .{ .role = .subagent, .urgency = .working },
        .{ .role = .subagent, .reply_at_ms = 5 },
        .{ .role = .subagent, .parent = 2, .urgency = .attention },
    };
    raiseParents(&entries);
    try std.testing.expectEqual(Urgency.attention, entries[1].urgency);
    var order: [entries.len + 1]usize = undefined;
    var scratch: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    sortSubagentGroups(&entries, &order);
    nestSubagents(&entries, &order, &scratch);
    // Main, lead, helper, tester.
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 1 }, &order);
}

test "an instance's other subagents sort by latest reply, ties keep their order, and each instance sorts its own" {
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .reply_at_ms = 100 },
        .{ .role = .subagent, .urgency = .working, .reply_at_ms = 1 },
        .{ .role = .subagent, .reply_at_ms = 300 },
        .{ .role = .subagent, .urgency = .working, .reply_at_ms = 900 },
        .{ .role = .subagent, .reply_at_ms = 300 },
        .{ .role = .subagent },
        // fx 2 replied last of all and stays below main's subagents.
        .{ .role = .instance, .reply_at_ms = 999 },
        .{ .role = .subagent, .root = 1, .reply_at_ms = 50 },
        .{ .role = .subagent, .root = 1, .urgency = .working },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    sortSubagentGroups(&entries, &order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 4, 3, 5, 1, 6, 7, 9, 8 }, &order);
}

test "sorting subagents keeps every instance in place and every subagent under its own instance" {
    var prng = std.Random.DefaultPrng.init(0x5eed_50f7);
    const random = prng.random();
    var buf: [24]OrderEntry = undefined;
    var order: [buf.len + 1]usize = undefined;
    var sorted: [buf.len + 1]usize = undefined;
    for (0..10_000) |_| {
        const entries = randomEntries(random, &buf);
        for (entries) |*entry| {
            entry.urgency = random.enumValue(Urgency);
            entry.reply_at_ms = random.uintAtMost(u8, 3);
        }
        const len = entries.len + 1;
        switchOrder(entries, order[0..len]);
        @memcpy(sorted[0..len], order[0..len]);
        sortSubagentGroups(entries, sorted[0..len]);
        var group_start: usize = 0;
        for (order[0..len], sorted[0..len], 0..) |before, after, index| {
            const instance = before == 0 or entries[before - 1].role == .instance;
            if (instance) {
                try std.testing.expectEqual(before, after);
                group_start = index + 1;
                continue;
            }
            try std.testing.expectEqual(entries[before - 1].root, entries[after - 1].root);
            try std.testing.expect(std.mem.findScalar(usize, sorted[group_start..len], before) != null);
            if (index == group_start) continue;
            const above = entries[sorted[index - 1] - 1];
            const here = entries[after - 1];
            try std.testing.expect(@backingInt(above.urgency) <= @backingInt(here.urgency));
            if (above.urgency == .idle) try std.testing.expect(above.reply_at_ms >= here.reply_at_ms);
        }
    }
}

test "a subagent's own subagents come right under it, in their sorted order" {
    // Main's lead works and started helper and checker; tester replied last.
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .urgency = .working },
        .{ .role = .subagent, .parent = 1, .reply_at_ms = 5 },
        .{ .role = .subagent, .reply_at_ms = 9 },
        .{ .role = .subagent, .parent = 1, .urgency = .working },
    };
    var order: [entries.len + 1]usize = undefined;
    var scratch: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    sortSubagentGroups(&entries, &order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 3, 2 }, &order);
    nestSubagents(&entries, &order, &scratch);
    // Main, lead, checker, helper, tester.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 2, 3 }, &order);
}

test "nesting keeps every agent and instance in place, and puts each subagent's own right under it, for random hosts" {
    var prng = std.Random.DefaultPrng.init(0x5eed_7e57);
    const random = prng.random();
    var buf: [24]OrderEntry = undefined;
    var sorted: [buf.len + 1]usize = undefined;
    var order: [buf.len + 1]usize = undefined;
    var scratch: [buf.len + 1]usize = undefined;
    for (0..10_000) |_| {
        const entries = randomEntries(random, &buf);
        for (entries, 0..) |*entry, index| {
            entry.urgency = random.enumValue(Urgency);
            entry.reply_at_ms = random.uintAtMost(u8, 3);
            if (entry.role != .subagent or index == 0 or random.boolean()) continue;
            // Two levels: a parent is one of the same tree's subagents that
            // an instance started.
            const candidate = random.uintLessThan(usize, index);
            const parent = entries[candidate];
            if (parent.role == .subagent and parent.root == entry.root and parent.parent == null) entry.parent = candidate + 1;
        }
        const len = entries.len + 1;
        switchOrder(entries, sorted[0..len]);
        sortSubagentGroups(entries, sorted[0..len]);
        @memcpy(order[0..len], sorted[0..len]);
        nestSubagents(entries, order[0..len], scratch[0..len]);
        for (sorted[0..len], order[0..len]) |before, after| {
            try std.testing.expect(std.mem.findScalar(usize, order[0..len], before) != null);
            if (before == 0 or entries[before - 1].role == .instance) try std.testing.expectEqual(before, after);
        }
        for (order[0..len], 0..) |position, at| {
            if (position == 0) continue;
            const parent = entries[position - 1].parent orelse continue;
            var back = at - 1;
            while (order[back] != parent) : (back -= 1) {
                try std.testing.expectEqual(@as(?usize, parent), entries[order[back] - 1].parent);
            }
        }
    }
}

test "latest reply timestamp ignores interrupted turns and empty or untimed replies" {
    const user: types.UserTurn = .{ .text = @constCast("task") };
    const history = [_]types.HistoryTurn{
        .{ .assistant = .{ .user = user, .assistant = @constCast("older"), .execution = .{ .turn_summary = .{ .completed_at_ms = 100 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast("newest reply"), .execution = .{ .turn_summary = .{ .completed_at_ms = 200 } } } },
        .{ .interrupted = .{ .user = user, .assistant = @constCast("stopped"), .execution = .{ .turn_summary = .{ .completed_at_ms = 900 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast(""), .execution = .{ .turn_summary = .{ .completed_at_ms = 1000 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast("no timestamp") } },
    };
    try std.testing.expectEqual(@as(i64, 200), latestReplyAt(&history));
    try std.testing.expectEqual(@as(i64, 0), latestReplyAt(&.{}));
    try std.testing.expectEqual(@as(i64, 0), latestReplyAt(history[2..]));
}

test "the newest turn's end time never falls back to an older turn" {
    const user: types.UserTurn = .{ .text = @constCast("task") };
    const compacted: types.HistoryTurn = .{ .compacted_summary = .{ .summary = @constCast("earlier"), .removed_turn_count = 1, .compaction_count = 1 } };
    const replied: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("reply"), .execution = .{ .turn_summary = .{ .completed_at_ms = 200 } } } };
    const tool_only: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast(""), .execution = .{ .turn_summary = .{ .completed_at_ms = 300 } } } };
    const stopped: types.HistoryTurn = .{ .interrupted = .{ .user = user } };
    const failed: types.HistoryTurn = .{ .interrupted = .{ .user = user, .terminal_reason = .failed } };
    const untimed: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("old session") } };

    try std.testing.expectEqual(@as(i64, 200), newestTurnEndedAt(&.{replied}));
    // A completed turn counts even when it ended without reply text.
    try std.testing.expectEqual(@as(i64, 300), newestTurnEndedAt(&.{ replied, tool_only }));
    // Compaction is not a turn: the turn before it still ended then.
    try std.testing.expectEqual(@as(i64, 200), newestTurnEndedAt(&.{ replied, compacted }));
    // A stopped or failed turn saves no end time, so there is no clock,
    // rather than one counting from the reply before it.
    try std.testing.expectEqual(@as(i64, 0), newestTurnEndedAt(&.{ replied, stopped }));
    try std.testing.expectEqual(@as(i64, 0), newestTurnEndedAt(&.{ replied, failed }));
    try std.testing.expectEqual(@as(i64, 0), newestTurnEndedAt(&.{ replied, untimed }));
    try std.testing.expectEqual(@as(i64, 0), newestTurnEndedAt(&.{compacted}));
    try std.testing.expectEqual(@as(i64, 0), newestTurnEndedAt(&.{}));
}
