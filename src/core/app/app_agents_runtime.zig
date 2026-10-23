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
const session_mod = @import("../session/session.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_process_runtime = @import("app_process_runtime.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
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
    /// always holds the one of the agent in context, as in a second fx
    /// (D36).
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
    bound: std.atomic.Value(u32) = .init(0),
    /// Whether this process has built the agent's notebook from its saved
    /// conversation (D1). Later turns append to it live (D20).
    view_built: bool = false,
    /// Whether this agent holds its own session, opened on its first run in
    /// this process and kept until main's session ends (D31).
    session_attached: bool = false,
    /// The host that started it: main's, or its parent subagent's own
    /// (D32). Its session opens through it, and its own subagents'
    /// authority comes from that host's resolver. Written on the main loop
    /// and read by resolvers on other threads, both under main's authority
    /// lock. Borrowed: that host outlives it (`ChildSession.tla`
    /// ParentOutlivesChildren).
    parent_host: ?*subagent_tool_host.Runtime = null,
    /// The name its parent gave it, such as `reviewer`, from its first run.
    /// Empty for a one-off. Owned.
    name: []u8 = &.{},
    /// Backs `footerLabel`.
    label_buf: [160]u8 = undefined,

    /// How fx names the agent to the user: its name, or its id without one.
    pub fn displayName(self: *const ChildAgent) []const u8 {
        return if (self.name.len > 0) self.name else self.id;
    }

    /// The footer's name for it on its own screen, marked done while none of
    /// its turns is going (D10). Valid until the next call; only the main
    /// loop paints.
    pub fn footerLabel(self: *ChildAgent) []const u8 {
        if (self.workGoing()) return self.displayName();
        return std.mem.print(&self.label_buf, "{s} · done", .{self.displayName()}) catch self.displayName();
    }

    /// Whether a turn of its is running, waiting to run, or finished with
    /// its events not yet applied: main's run, the user's, or steering left
    /// over from either. Its paced output is checked where its screen is;
    /// see `turnGoing`.
    pub fn workGoing(self: *ChildAgent) bool {
        if (self.agent.child_run) |*run| if (run.inFlight()) return true;
        return self.agent.worker.isProcessing() or
            self.agent.worker.queuedPromptCount() > 0 or
            self.agent.worker.hasPendingEvents();
    }
};

/// Slot threads and the main loop both use the mailbox's list.
const mailbox_alloc = std.heap.c_allocator;

/// Hand-offs from the subagent host's slot threads to the main loop. A slot
/// thread posts and waits; only the main loop takes, once each pass.
pub const Mailbox = struct {
    mutex: std.Io.Mutex = .init,
    /// Set when the app shuts down: nothing more is posted or taken, and
    /// every slot thread waiting for a hand-off is released.
    closed: bool = false,
    posts: std.ArrayList(*Post) = .empty,

    pub fn deinit(self: *Mailbox) void {
        self.posts.deinit(mailbox_alloc);
        self.* = .{};
    }
};

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

    pub const State = enum(u8) { posted, taken, failed, closed };
};

pub const PostError = error{ OutOfMemory, Cancelled, Failed };

/// Posts `post` and waits until the main loop takes it. Fails with
/// `Cancelled` when `cancel` is set first or the app shuts down.
pub fn postAndWait(mailbox: *Mailbox, post: *Post, cancel: *std.atomic.Value(bool)) PostError!void {
    {
        mailbox.mutex.lockUncancelable(io_mod.getIo());
        defer mailbox.mutex.unlock(io_mod.getIo());
        if (mailbox.closed) return error.Cancelled;
        try mailbox.posts.append(mailbox_alloc, post);
    }
    while (true) {
        switch (post.state.load(.acquire)) {
            .taken => return,
            .failed => return error.Failed,
            .closed => return error.Cancelled,
            .posted => {},
        }
        if (cancel.load(.seq_cst) and withdraw(mailbox, post)) return error.Cancelled;
        io_mod.sleep(2 * std.time.ns_per_ms);
    }
}

/// Takes `post` back if the loop has not taken it yet.
fn withdraw(mailbox: *Mailbox, post: *Post) bool {
    mailbox.mutex.lockUncancelable(io_mod.getIo());
    defer mailbox.mutex.unlock(io_mod.getIo());
    for (mailbox.posts.items, 0..) |item, index| if (item == post) {
        _ = mailbox.posts.orderedRemove(index);
        return true;
    };
    return false;
}

/// Waits until the main loop ends the run `completion` belongs to. A run
/// always ends: its turn finishes, or shutdown ends it after joining the
/// child's worker. While `cancel` is set, the turn on `worker` is cancelled
/// again every 25 ms: a worker clears its cancel flag when a turn begins, so
/// a cancel that lands before then would otherwise be lost.
pub fn waitForCompletion(
    completion: *agents.ChildRunCompletion,
    cancel: *std.atomic.Value(bool),
    worker: *worker_runtime.WorkerRuntime,
) agents.ChildRunCompletion.Outcome {
    var polls: usize = 0;
    while (true) : (polls += 1) {
        if (completion.result()) |outcome| return outcome;
        if (polls % 12 == 0 and cancel.load(.seq_cst)) worker.requestTurnCancel();
        io_mod.sleep(2 * std.time.ns_per_ms);
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

/// The app `agent` belongs to (D43). A subagent records its app when the app
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

/// The switch order (D48) over the first instance and `entries`, written to
/// `out` as positions: 0 for the first instance, k + 1 for `entries[k]`. The
/// instances come in launch order, each followed by the subagents in its
/// tree in the order they started. `out.len` is `entries.len + 1`, and every
/// subagent's root is the first instance or one in `entries`.
/// `tla/Host.tla` SwitchListOrder.
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
        /// own context, so it keeps working while another is on screen (D20):
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
        /// main always is (D31): its worker running and its own session
        /// attached. While none of its turns is going it gets a run admitted
        /// for the user's turn, so its profile and main's live permissions
        /// limit that turn as they limit main's runs. While one is going, the
        /// text steers or follows it under that turn's run, as typing does on
        /// main. A subagent never runs a turn without a run.
        pub fn prepareOwnTurn(app: *App, agent: *AppAgent) !void {
            const child = app.agent_on_screen orelse return;
            // An instance takes its own turns as the first one does (D45).
            if (child.agent.role == .instance) return;
            if (child.agent.worker_thread == null) _ = try ensureChild(app, child.id);
            if (!child.session_attached) try attachSession(app, agent, child);
            if (child.agent.child_run == null or !turnGoing(app, child)) try admitOwnTurn(app, agent, child);
            debug_trace.eventf("procesor", "input_routed", .{}, "agent={s}", .{child.id});
        }

        /// Gives `run` the user's earlier requests to the subagent in context,
        /// the verified evidence its permission reviewer weighs with the turn's
        /// own prompt: the turns the user typed, never the ones main sent,
        /// which carry main's work id (D31). A compacted conversation may have
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
            installChildRun(app, child, run);
            debug_trace.eventf("procesor", "own_turn_admitted", .{}, "agent={s} model={s} permission_mode={s}", .{
                child.id,
                child.agent.child_run.?.admission.model,
                @tagName(child.agent.child_run.?.admission.permission_mode),
            });
        }

        /// While main is on screen with no question or approval showing, a
        /// hidden subagent's question is lent to main's prompt, named for the
        /// subagent, so it shows on main's screen too (D23). It goes back
        /// before anything but the input that edits it touches it.
        pub fn lendQuestion(app: *App) void {
            if (app.agent_on_screen != null or app.question_lender != null) return;
            if (app.main_agent.question_prompt.isActive() or app.main_agent.approval_prompt.isActive()) return;
            for (app.child_agents.items) |child| {
                if (!lendsToMain(app, child)) continue;
                if (!child.agent.question_prompt.isActive()) continue;
                std.mem.swap(question_prompt.QuestionPrompt, &app.main_agent.question_prompt, &child.agent.question_prompt);
                app.main_agent.question_prompt.asker = child.displayName();
                app.question_lender = child;
                debug_trace.eventf("procesor", "question_lent", .{}, "agent={s}", .{child.id});
                app.shell.render_requests.request(.modal);
                return;
            }
        }

        /// Gives a question lent to main back to the subagent that asked it,
        /// and returns that subagent.
        pub fn returnQuestion(app: *App) ?*ChildAgent {
            const child = app.question_lender orelse return null;
            app.main_agent.question_prompt.asker = "";
            std.mem.swap(question_prompt.QuestionPrompt, &app.main_agent.question_prompt, &child.agent.question_prompt);
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
        /// whose question main's screen shows, so the answer reaches its
        /// worker and joins its conversation. False when main's question is
        /// its own.
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

        /// While main is on screen with no approval or question showing, a
        /// hidden subagent's approval is lent to main's prompt, so it shows on
        /// main's screen too (D18, D34). Its request comes from its own
        /// worker and stays labeled with its name. It goes back when the
        /// subagent is shown, main gets its own, or the subagent stops
        /// waiting (`keepLentApproval`). A rule a subagent's
        /// `/permissions remember` would save is its own, so it isn't lent.
        pub fn lendApproval(app: *App) void {
            if (app.agent_on_screen != null or app.approval_lender != null) return;
            if (app.main_agent.approval_prompt.isActive() or app.main_agent.question_prompt.isActive()) return;
            for (app.child_agents.items) |child| {
                if (!lendsToMain(app, child)) continue;
                const prompt = &child.agent.approval_prompt;
                if (!prompt.isActive() or prompt.rule_management != null) continue;
                std.mem.swap(@TypeOf(child.agent.approval_prompt), &app.main_agent.approval_prompt, prompt);
                app.approval_lender = child;
                debug_trace.eventf("procesor", "approval_lent", .{}, "agent={s}", .{child.id});
                app.shell.render_requests.request(.modal);
                return;
            }
        }

        /// Gives an approval lent to main back to the subagent it came from,
        /// and returns that subagent.
        pub fn returnApproval(app: *App) ?*ChildAgent {
            const child = app.approval_lender orelse return null;
            std.mem.swap(@TypeOf(child.agent.approval_prompt), &app.main_agent.approval_prompt, &child.agent.approval_prompt);
            app.approval_lender = null;
            app.shell.render_requests.request(.modal);
            return child;
        }

        /// Whether the agent in context keeps its approval prompt as it is
        /// this pass, because an approval is lent: main keeps the one it
        /// shows until its own request comes, and the subagent that lent it
        /// lets it be while its worker still asks the same thing. Otherwise
        /// the approval goes back first, and the caller syncs the prompt
        /// from the worker's `pending`.
        pub fn keepLentApproval(app: *App, agent: *AppAgent, pending: ?permission_request.PermissionRequest) bool {
            const lender = app.approval_lender orelse return false;
            if (agent == &app.main_agent) {
                if (pending == null) return true;
            } else if (agent == &lender.agent) {
                const lent = app.main_agent.approval_prompt.request orelse return false;
                if (pending) |request| if (request.id == lent.id) return true;
            } else return false;
            _ = returnApproval(app);
            return false;
        }

        /// The subagent whose approval main's prompt shows, while main is in
        /// context: an answer there goes to that subagent's worker.
        pub fn lentApproval(app: *App, agent: *AppAgent) ?*ChildAgent {
            if (agent != &app.main_agent) return null;
            return app.approval_lender;
        }

        /// Runs `body`, a cancel, in the context of the subagent whose
        /// approval main's screen shows, as its own screen would. False when
        /// main's approval is its own.
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

        /// Whether Alt+←/→ has another agent to switch to. Brings in the
        /// subagents main's session started before a restart first.
        pub fn canSwitch(app: *App) bool {
            syncChildList(app) catch |err| {
                debug_trace.logf("procesor", "child list sync failed err={s}", .{@errorName(err)});
            };
            return app.child_agents.items.len > 0;
        }

        /// Puts every subagent in the subagent host's registry in the switch
        /// list, in the order they started, so a subagent from before a
        /// restart can be shown too (D10, D12). One added here starts its
        /// worker on its first run.
        fn syncChildList(app: *App) !void {
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return;
            const listing = try host.listChildren(app.alloc);
            defer subagent_tool_host.Runtime.freeChildListing(app.alloc, listing);
            for (listing) |entry| {
                const child = findChild(app, entry.id) orelse try addChild(app, entry.id);
                if (child.name.len == 0 and entry.name.len > 0) child.name = try app.alloc.dupe(u8, entry.name);
                if (child.parent_host == null) setParentHost(app, child, host);
            }
            orderByListing(app.child_agents.items, listing);
        }

        /// Puts the next or previous agent on screen (D9). The list is main,
        /// then the subagents in the order they started, wrapping at both ends
        /// (D12), as `Procesor.tla` `SwitchWalksOrder` checks.
        pub fn switchAgent(app: *App, direction: input_action.SwitchDirection) !void {
            var list: std.ArrayList(?*ChildAgent) = .empty;
            defer list.deinit(app.alloc);
            try switchList(app, &list);
            const total = list.items.len;
            if (total <= 1) return;
            const current = for (list.items, 0..) |entry, position| {
                if (entry == app.agent_on_screen) break position;
            } else unreachable;
            const target = switch (direction) {
                .next => (current + 1) % total,
                .previous => (current + total - 1) % total,
            };
            try show(app, list.items[target]);
        }

        /// The order Alt+←/→ walks (D48): the instances in launch order,
        /// the first one as null, each followed by the subagents in its tree
        /// in the order they started. With one instance this is main, then
        /// every subagent in start order, as before instances existed.
        /// `tla/Host.tla` SwitchListOrder.
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

        /// Whether the first instance, kept in `main_agent`, still runs
        /// (D57).
        pub fn firstOpen(app: anytype) bool {
            if (comptime !@hasField(App, "instances")) return true;
            return app.instances.first_open;
        }

        /// The first instance still open: `main_agent` until it closes, then
        /// the earliest launched one still running (D57). Everything that
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

        /// The footer's name for the agent on screen: a subagent's own label,
        /// or an instance's place among the instances while there are
        /// several, the first one included (D45). Empty for a single
        /// instance, as before instances existed. Valid until the next call.
        pub fn footerLabelOnScreen(app: *App) []const u8 {
            if (app.agent_on_screen) |child| if (child.agent.role == .subagent) return child.footerLabel();
            var total: usize = if (firstOpen(app)) 1 else 0;
            var position: usize = 1;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                total += 1;
                if (app.agent_on_screen) |on_screen| if (on_screen == child) {
                    position = total;
                };
            }
            if (total == 1) return "";
            return std.mem.print(&app.instances.label_buf, "fx {d}/{d}", .{ position, total }) catch "";
        }

        /// The instance whose tree subagent `child` is in: the one that
        /// started it, or started the subagent that did (D46).
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

        /// A subagent's approval or question is lent to main's screen only
        /// when main's tree holds it: an instance's are its own (D45), and a
        /// subagent of another instance belongs to that instance.
        fn lendsToMain(app: *App, child: *const ChildAgent) bool {
            return child.agent.role == .subagent and rootInstance(app, child) == &app.main_agent;
        }

        /// Puts `target`, or main when null, on screen, then clears the
        /// terminal and redraws the arriving agent's conversation from the top
        /// (D22). Neither agent's work stops (`Procesor.tla` `SwitchKeepsWork`).
        pub fn show(app: *App, target: ?*ChildAgent) !void {
            const from = app.agent_on_screen;
            if (from == target) return;
            attach(app, target);
            if (target) |child| {
                if (!child.view_built) buildSavedView(app, agents.screenAgentOf(app), child);
                // Its own session, so what changes on its screen, such as its
                // model, is saved to it, as in a second fx (D31). Its worker
                // still starts with its first message (D30).
                if (!child.session_attached) attachSession(app, agents.screenAgentOf(app), child) catch |err| {
                    debug_trace.logf("procesor", "session not opened on show agent={s} err={s}", .{ child.id, @errorName(err) });
                };
            }
            debug_trace.eventf("procesor", "agent_switched", .{}, "agent={s} from={s}", .{ nameOf(target), nameOf(from) });
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
            debug_trace.eventf("procesor", "screen_reprinted", .{}, "agent={s} entries={d}", .{
                nameOf(target),
                app.shell.notebook.entries.items.len,
            });
        }

        /// Builds the view of a subagent shown before it has run in this
        /// process from its saved conversation (D1). Runs with it on screen.
        /// The first view of the subagent in context, as a second fx would
        /// open it: its saved conversation, as on resume, or fx's welcome when
        /// it has none yet, as on a fresh start (D31).
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
                    debug_trace.logf("procesor", "instance view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                };
                return;
            }
            const host = hostOf(app, child) orelse return;
            const history = host.childHistory(app.alloc, child.id) catch |err| {
                debug_trace.logf("procesor", "saved view unavailable agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            defer types.freeHistoryTurnSlice(app.alloc, history);
            buildView(app, agent, history) catch |err| {
                debug_trace.logf("procesor", "saved view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            debug_trace.eventf("procesor", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ child.id, history.len });
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

        fn nameOf(child: ?*ChildAgent) []const u8 {
            return if (child) |value| value.id else "main";
        }

        /// Stops every child agent and closes its session, each in its own
        /// context: its worker stops and is joined, its last finished turns are
        /// saved, its session closes, and its state is freed. Runs before main's
        /// persistence closes, because a child borrows main's session store.
        /// The list is in start order, so walking it backwards closes each
        /// subagent's own subagents before it (`ChildSession.tla`
        /// ParentOutlivesChildren).
        pub fn shutdownChildren(app: *App) void {
            attach(app, null);
            closeMailbox(app);
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
                while (child.bound.load(.acquire) > 0) io_mod.sleep(2 * std.time.ns_per_ms);
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
            closeMailbox(app);
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

        /// Closes the mailbox at shutdown, releasing every slot thread still
        /// waiting for a hand-off.
        fn closeMailbox(app: *App) void {
            app.child_mailbox.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_mailbox.mutex.unlock(io_mod.getIo());
            app.child_mailbox.closed = true;
            for (app.child_mailbox.posts.items) |post| post.state.store(.closed, .release);
            app.child_mailbox.posts.clearRetainingCapacity();
        }

        /// Takes every hand-off waiting in the mailbox. Runs on the main loop
        /// each pass, before the children's events are handled.
        pub fn takePosts(app: *App) void {
            var posts: std.ArrayList(*Post) = .empty;
            {
                app.child_mailbox.mutex.lockUncancelable(io_mod.getIo());
                defer app.child_mailbox.mutex.unlock(io_mod.getIo());
                if (app.child_mailbox.closed) return;
                std.mem.swap(std.ArrayList(*Post), &posts, &app.child_mailbox.posts);
            }
            defer posts.deinit(mailbox_alloc);
            var held: std.ArrayList(*Post) = .empty;
            defer held.deinit(mailbox_alloc);
            for (posts.items) |post| {
                // A run waits while a turn of its child's is going: the run
                // replaces the child's installed run, which that turn reads.
                if (post.run != null) if (findChild(app, post.turn.child_id orelse "")) |child| if (turnGoing(app, child)) {
                    held.append(mailbox_alloc, post) catch {
                        debug_trace.eventf("procesor", "child_handoff_failed", .{}, "agent={s} kind=run reason=OutOfMemory", .{child.id});
                        post.state.store(.failed, .release);
                        continue;
                    };
                    if (!post.held) debug_trace.eventf("procesor", "child_run_held", .{}, "agent={s} reason=turn_going", .{child.id});
                    post.held = true;
                    continue;
                };
                const kind = if (post.run == null) "bind" else "run";
                const taken = if (post.run == null) bindPost(app, post) else startPost(app, post);
                if (taken) |_| {
                    post.state.store(.taken, .release);
                } else |err| {
                    debug_trace.eventf("procesor", "child_handoff_failed", .{}, "agent={s} kind={s} reason={s}", .{ post.turn.child_id orelse "", kind, @errorName(err) });
                    post.state.store(.failed, .release);
                }
            }
            if (held.items.len == 0) return;
            // Back at the front, in order, to be offered again next pass.
            app.child_mailbox.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_mailbox.mutex.unlock(io_mod.getIo());
            if (app.child_mailbox.closed) {
                for (held.items) |post| post.state.store(.closed, .release);
            } else app.child_mailbox.posts.insertSlice(mailbox_alloc, 0, held.items) catch {
                for (held.items) |post| post.state.store(.failed, .release);
            };
        }

        /// Records the host that started `child`: main's, or its parent
        /// subagent's own (D32). Resolvers on other threads read it under
        /// main's authority lock.
        fn setParentHost(app: *App, child: *ChildAgent, host: *subagent_tool_host.Runtime) void {
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            child.parent_host = host;
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
        /// are: main's unless a subagent of main's started it (D32).
        fn hostOf(app: *App, child: *const ChildAgent) ?*subagent_tool_host.Runtime {
            return child.parent_host orelse app_session_runtime.Runtime(App).subagentHost(app);
        }

        /// Binds a run's turn to its child's agent, started on first use, so
        /// cancel, steering, and approvals reach that agent's worker.
        fn bindPost(app: *App, post: *Post) !void {
            const child = try ensureChild(app, post.turn.child_id orelse return error.ChildNotAttached);
            if (post.turn.live_authority) |resolver| if (hostWithResolver(app, resolver)) |host| setParentHost(app, child, host);
            _ = child.bound.fetchAdd(1, .acq_rel);
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
            debug_trace.eventf("procesor", "child_run_started", .{}, "agent={s} work_id={s}", .{ child.id, child.agent.child_run.?.work_id });
        }

        const Start = struct { post: *Post, child: *ChildAgent };

        /// Opens the child's session, with the same recovery as a run's
        /// open, and attaches it to the child's agent in context, which saves
        /// every later turn through it as main does (D31).
        /// `tla/ChildSession.tla` SingleWriter.
        fn attachSession(app: *App, agent: *AppAgent, child: *ChildAgent) !void {
            const host = hostOf(app, child) orelse return error.SubagentHostUnavailable;
            const session = try host.openChildSession(child.id);
            try app_session_runtime.Runtime(App).attachChildV2Session(app, agent, session);
            child.session_attached = true;
            debug_trace.eventf("procesor", "child_session_opened", .{}, "agent={s} turns={d}", .{ child.id, agent.session.agent.history.items.len });
        }

        fn startInContext(start: Start, app: *App, agent: *agents.Agent) anyerror!void {
            const post = start.post;
            if (!start.child.session_attached) try attachSession(app, agent, start.child);
            // The child's own session holds its conversation (D31). The first
            // run in this process shows it, after a restart too (D1).
            if (!start.child.view_built) {
                const history = agent.session.agent.history.items;
                try buildView(app, agent, history);
                start.child.view_built = true;
                debug_trace.eventf("procesor", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ start.child.id, history.len });
            }
            // The worker writes the message's card when its turn begins. The
            // turn carries main's work id, so it is saved with it (D31).
            agent.prompt_work_id = start.child.agent.child_run.?.work_id;
            defer agent.prompt_work_id = null;
            if (!try app.enqueuePrompt(agent, post.message)) return error.PromptNotAdmitted;
        }

        /// The agent for child session `id`, its worker started on first use.
        fn ensureChild(app: *App, id: []const u8) !*ChildAgent {
            const child = findChild(app, id) orelse try addChild(app, id);
            if (child.agent.worker_thread == null) {
                try app_process_runtime.Runtime(App).startAgentWorkerThread(app, &child.agent);
                debug_trace.eventf("procesor", "agent_started", .{}, "agent={s}", .{id});
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
                // Resolvers on other threads read the list (D31).
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                try app.child_agents.append(app.alloc, child);
            }
            // Registered here, with main as its parent, rather than by its
            // worker's first event.
            debug_trace.eventf("procesor", "agent_registered", .{}, "agent={s} parent=main", .{child.id});
            child.agent.worker.trace_agent = child.id;
            child.agent.worker.trace_registered = true;
            child.agent.worker.hands_back_leftover_feedback = true;
            return child;
        }

        /// Adds a new top-level instance, last among the hosted agents, with a
        /// placeholder id until its session names it (D45).
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
            debug_trace.eventf("procesor", "agent_registered", .{}, "agent={s} parent=host", .{child.id});
        }

        /// Closes instance `child` and every subagent in its tree: their
        /// workers stop, a run in flight ends cancelled, and their sessions
        /// are saved and closed, each subagent's before the agent that started
        /// it (`tla/ChildSession.tla` ParentOutlivesChildren). When one of
        /// them is on screen, the next instance is shown first. The rest of
        /// the host keeps running (`tla/Host.tla` Close).
        pub fn closeInstance(app: *App, child: *ChildAgent) !void {
            try closeTree(app, &child.agent, child, nextInstanceAfter(app, child), child.id);
            dropHosted(app, child);
        }

        /// Closes the first instance and every subagent in its tree, as
        /// `closeInstance` closes a launched one. The next instance in launch
        /// order takes over, the host keeps running, and the first's slot
        /// stays closed (D52, D57, `tla/Host.tla` Close). Call only while
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
        /// whose tree holds it, whose session is the one to resume (D57).
        pub fn liftResumeIntent(app: *App) void {
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent) continue;
                const intent = child.agent.session_persistence.resume_handoff_intent;
                if (intent == .none) continue;
                child.agent.session_persistence.resume_handoff_intent = .none;
                rootInstance(app, child).session_persistence.resume_handoff_intent = intent;
            }
        }

        /// Shows `next` when instance `root`, which `hosted` holds or null for
        /// the first, or a subagent of its tree is on screen, then stops and
        /// drops every subagent in the tree, each before the agent that
        /// started it (`tla/ChildSession.tla` ParentOutlivesChildren). The
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
            for (tree.items) |entry| {
                entry.agent.worker.requestCancel();
                entry.agent.worker.requestShutdown();
                entry.agent.managed_executions.shutdown();
            }
            for (tree.items) |entry| {
                if (entry.agent.worker_thread) |thread| thread.join();
                entry.agent.worker_thread = null;
                if (entry.agent.child_run) |*run| finishRun(run, .cancelled);
            }
            root.worker.requestCancel();
            debug_trace.eventf("procesor", "instance_closed", .{}, "agent={s} subagents={d}", .{ label, tree.items.len });
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
            while (child.bound.load(.acquire) > 0) io_mod.sleep(2 * std.time.ns_per_ms);
            {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                for (app.child_agents.items, 0..) |entry, index| if (entry == child) {
                    _ = app.child_agents.orderedRemove(index);
                    break;
                };
            }
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
        /// every turn to its own session, as main does (D31), so this runs
        /// after the save, on the main loop in the child's context. Only the
        /// turn carrying the run's work id ends it: the parent finds its
        /// answer by that id, and a turn the user started carries none.
        /// `tla/ChildSession.tla` TakenFindsTurn.
        pub fn commitChildTurn(_: *App, agent: *AppAgent, finished: types.FinishedPrompt) void {
            if (comptime !@hasField(App, "screen_owner")) return;
            if (agent.role != .subagent) return;
            // A subagent never runs a turn without a run installed.
            const run = if (agent.child_run) |*value| value else return;
            const saved_work = session_mod.historyTurnWorkId(finished.turn);
            debug_trace.eventf("procesor", "child_turn_saved", .{}, "agent={s} work_id={s}", .{ run.child_id, saved_work orelse "none" });
            if (!run.inFlight()) return;
            if (!std.mem.eql(u8, saved_work orelse return, run.work_id)) return;
            const outcome = finished.terminal_outcome orelse .completed;
            debug_trace.eventf("procesor", "child_turn_committed", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
            endRun(run, outcome);
        }

        /// Records how a child's turn ended. The finished turn can still be
        /// on its way, held by the pacer or not yet drained, so the run ends
        /// when it is saved, or in `settleChildRuns` once nothing is left.
        pub fn noteChildTurnFinished(app: *App, agent: *AppAgent, outcome: types.TurnPresentationOutcome) void {
            const run = runInFlight(app, agent) orelse return;
            run.ended_as = outcome;
        }

        /// Ends each child's run whose turn has finished and left nothing to
        /// save: its worker is idle, with no events left and nothing held by
        /// its pacer. A turn cancelled before it said anything ends here.
        /// Runs on the main loop each pass, after the children's events.
        pub fn settleChildRuns(app: *App) void {
            for (app.child_agents.items) |child| {
                const run = if (child.agent.child_run) |*value| value else continue;
                if (!run.inFlight()) continue;
                const outcome = run.ended_as orelse continue;
                if (hasPendingWork(child) or child.agent.worker.isProcessing()) continue;
                endRun(run, outcome);
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
            debug_trace.eventf("procesor", "child_run_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
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
                .interrupted, .paused => finishRun(run, .cancelled),
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
            // Its own fast mode, not main's (D36).
            settings.fast_mode = child.agent.worker.agent_turn_settings.fast_mode;
            settings.ultrafast_mode = settings.ultrafast_mode and run.admission.ultrafast_mode;
            child.agent.worker.agent_turn_settings = settings;
            child.agent.child_run = run;
        }

        /// Saves and closes `agent`'s session. When the user quit from this
        /// instance's screen, keeps the resume command it makes for the exit
        /// to print (D57).
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
            app.child_mailbox.deinit();
        }
    };
}

test "a slot thread's hand-off returns once the main loop takes it" {
    var mailbox: Mailbox = .{};
    defer mailbox.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    // The loop side never runs here, so the turn is never read.
    var post = Post{ .turn = undefined };
    const Loop = struct {
        fn take(box: *Mailbox) void {
            while (true) {
                box.mutex.lockUncancelable(io_mod.getIo());
                if (box.posts.pop()) |taken| {
                    taken.state.store(.taken, .release);
                    box.mutex.unlock(io_mod.getIo());
                    return;
                }
                box.mutex.unlock(io_mod.getIo());
                io_mod.sleep(std.time.ns_per_ms);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Loop.take, .{&mailbox});
    try postAndWait(&mailbox, &post, &cancel);
    thread.join();
    try std.testing.expectEqual(Post.State.taken, post.state.load(.acquire));
}

test "a hand-off withdrawn on cancel, or posted after shutdown, never reaches the main loop" {
    var mailbox: Mailbox = .{};
    defer mailbox.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    var post = Post{ .turn = undefined };
    try std.testing.expectError(error.Cancelled, postAndWait(&mailbox, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), mailbox.posts.items.len);

    mailbox.closed = true;
    cancel.store(false, .seq_cst);
    try std.testing.expectError(error.Cancelled, postAndWait(&mailbox, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), mailbox.posts.items.len);
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

/// Checks what `tla/Host.tla` SwitchListOrder asks of `order` over
/// `entries`: every agent once, the first instance first, the instances in
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
    try std.testing.fuzz({}, fuzzSwitchOrder, .{});
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
