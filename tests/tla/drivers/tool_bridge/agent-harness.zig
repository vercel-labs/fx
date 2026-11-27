//! A JSON-lines shell around the real `fx tool agent wait` path, for the Bun
//! driver in tests/tla/drivers/tool_bridge/agent-*.ts.
//!
//! The driver copies this file to the root of a work folder that holds a copy
//! of src/, so each import below is a real file of this tree. The program's
//! first call is managed_execution's `startCaptured` and its `wait_more` is
//! `waitOrYield`, both with the real `yield_hold` and the real steering yield.
//! The subagent wait is the host's `waitForMail` with a cancel flag, and the
//! child's mail goes through the host's real message path into the parent's
//! worker queue. The harness drives the wait directly, not through the bridge
//! handler, which unit and E2E tests cover, so three things are glue: the hold
//! is raised and lowered where bridge.zig raises it for a request, the cancel
//! flag is set as the bridge's watch sets it when the client is gone, and the
//! parent's turn takes the queued mail (`join`).
//!
//! Each input line is one event, {"event":"start_wait"}. The first output line
//! is the state after start, and each later line is the state after one event,
//! as {"state":{...},"out":[...]}. An event whose guard does not hold is
//! refused: the state does not change, and `out` says so. An event the code
//! answers late waits a bounded window, and the state shows what it did by then.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("src/core/shared/io.zig");
const managed = @import("src/core/execution/managed_execution.zig");
const command_runner = @import("src/core/execution/command_runner.zig");
const contract = @import("src/core/execution/managed_execution_contract.zig");
const command_admission = @import("src/core/permissions/command_admission.zig");
const tool_host = @import("src/core/subagent/tool_host.zig");
const child_state = @import("src/core/subagent/child_state.zig");
const authority = @import("src/core/subagent/authority.zig");
const execution = @import("src/core/subagent/execution.zig");
const domain = @import("src/core/subagent/domain.zig");
const model_contract = @import("src/core/subagent/model_contract.zig");
const worker_runtime = @import("src/core/agent/worker_runtime.zig");
const session = @import("src/core/session/session.zig");
const session_adapter = @import("src/core/session/session_adapter.zig");
const types = @import("src/core/shared/types.zig");

comptime {
    _ = @import("session_manager");
}

const Allocator = std.mem.Allocator;

const max_posts = 2;
const max_programs = 2;
const max_waits = 2;
/// How long a late answer may take before the state is read: a wait that the
/// model enables returns within this window, and a yield the model enables
/// lands within the bridge grace plus this window.
const answer_window_ms = 1500;
/// How long a wait that should still be waiting is watched before the state is
/// read. A wait that returns on its own in this time is reported as returned.
const still_waiting_probe_ms = 50;
/// How long a yield is watched while a bridge call holds the first call. The
/// held first call must not yield in that time, so a yield that does is seen.
const held_yield_probe_ms = 400;
/// How long the end of input waits for the calls to return, after the program ends.
const shutdown_limit_ms = 5000;
const admit_limit_ms = 2000;
const child_end_limit_ms = 2000;
const child_name = "reviewer";
const program_command = "sleep 30";

const Prog = enum { none, running, gone };
const Told = enum { none, mail, quiet, canceled, unavailable, other };

const Run = struct {
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    prepared: ?managed.PreparedSnapshot = null,
    err: ?anyerror = null,
};

const WaitCall = struct {
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    told: Told = .other,
    id: []const u8,
};

const Input = struct { event: []const u8 };

fn defaults() tool_host.Defaults {
    return .{
        .provider = .gateway,
        .model = "test",
        .effort = .auto,
        .conversation_language = session.ConversationLanguage.literal("en"),
    };
}

fn authorityFor(input: managed.StartCapturedInput) command_admission.CommandExecutionAuthority {
    const ctx = command_admission.CommandContext{
        .command = input.command,
        .resolved_cwd = input.cwd,
        .target_os = builtin.target.os.tag,
        .environment = input.environment,
    };
    return .{ .shell_allowed = .{ .fingerprint = .init(ctx), .source = .yolo } };
}

/// The text a wait's reply gives, as the model's `told` names it.
fn classify(body: []const u8) Told {
    if (std.mem.find(u8, body, "No subagent is working") != null or
        std.mem.find(u8, body, "turn ended without a report") != null) return .quiet;
    if (std.mem.find(u8, body, "message arrived") != null or
        std.mem.find(u8, body, "sent a message") != null) return .mail;
    return .other;
}

fn waitDone(flag: *std.atomic.Value(bool), limit_ms: i64) bool {
    const started = io_mod.milliTimestamp();
    while (!flag.load(.seq_cst)) {
        if (io_mod.milliTimestamp() - started >= limit_ms) return false;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return true;
}

fn firstMain(self: *Harness, run: *Run, id: []const u8) void {
    var input = managed.StartCapturedInput{
        .execution_id = id,
        .command = program_command,
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 4096,
        .timeout_ms = 60_000,
        .command_artifact_dir = null,
        .yield_time_ms = contract.max_yield_time_ms,
        .tool_yield_flag = &self.steer,
        .yield_hold = &self.hold,
        .cancel_flag = &run.cancel,
    };
    input.authority = authorityFor(input);
    run.prepared = self.managed.startCaptured(self.alloc, input) catch |err| blk: {
        run.err = err;
        break :blk null;
    };
    run.done.store(true, .seq_cst);
}

fn moreMain(self: *Harness, run: *Run, id: []const u8) void {
    run.prepared = self.managed.waitOrYield(self.alloc, id, contract.max_yield_time_ms, &run.cancel, &self.steer) catch null;
    run.done.store(true, .seq_cst);
}

fn waitMain(self: *Harness, call: *WaitCall) void {
    call.told = self.waitOnce(call);
    _ = self.hold.fetchSub(1, .acq_rel);
    self.hold_dropped_ms = io_mod.milliTimestamp();
    call.done.store(true, .seq_cst);
}

/// The child's work: it runs until the driver releases it, then ends with no
/// report, so the host nudges a waiting parent.
fn childRun(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Harness = @ptrCast(@alignCast(raw.?));
    while (!self.child_release.load(.seq_cst) and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
    if (cancel.load(.seq_cst)) return error.Cancelled;
    if (turn.isHosted()) return .completed;
    turn.commit(turn.active_work_id.?, .{ .assistant = .{
        .user = .{ .text = @constCast("work") },
        .assistant = "",
    } }) catch return error.ProviderFailed;
    return .completed;
}

/// The parent's report sink: a child's message joins the parent's queue as
/// mail from a child, which is what the parent's worker holds for its turn.
fn sinkPost(raw: ?*anyopaque, _: *tool_host.Runtime, delivery: tool_host.Delivery) tool_host.PostReportError!void {
    const self: *Harness = @ptrCast(@alignCast(raw.?));
    switch (delivery) {
        .report => return error.AgentGone,
        .message => |message| {
            const text = self.alloc.dupe(u8, message.text) catch return error.OutOfMemory;
            self.worker.postMail(self.alloc, .{
                .prompt = text,
                .images = &.{},
                .model = &.{},
                .api_key = &.{},
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
                .author = .child,
            }) catch return error.AgentGone;
            self.posted += 1;
        },
    }
}

fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
    return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
}

/// A saved parent session in `home`, built as `child_state.TestParent` builds
/// it for the subagent tests. That helper needs std.testing, which only test
/// builds have, so the harness does the same steps on a folder the driver made.
const Parent = struct {
    alloc: Allocator,
    home: []const u8,
    model: [10]u8 = "test-model".*,
    store: session_adapter.Store,
    parent: *session_adapter.Session,
    children: child_state.V2Children,

    fn init(self: *Parent, alloc: Allocator, home: []const u8) !void {
        self.* = .{ .alloc = alloc, .home = home, .store = undefined, .parent = undefined, .children = undefined };
        self.store = try session_adapter.Store.open(alloc, home);
        self.parent = try session_adapter.Session.create(alloc, &self.store, home, .ask, self.seed());
        try self.parent.commitTurn(.{ .assistant = .{
            .user = .{ .text = @constCast("delegate") },
            .assistant = @constCast("ok"),
        } }, types.ConversationLanguage.default());
        self.children = child_state.V2Children.init(alloc, self.parent, home);
    }

    fn seed(self: *Parent) session_adapter.Seed {
        return .{
            .preferences = .{ .model = &self.model, .effort = .auto, .fast_mode = false },
            .language = types.ConversationLanguage.default(),
            .permission_state = .{},
            .instructions = "",
        };
    }
};

const Harness = struct {
    alloc: Allocator,
    managed: *managed.Runtime,
    parent: *Parent,
    root: *tool_host.Runtime,
    worker: *worker_runtime.WorkerRuntime,
    hold: std.atomic.Value(u32) = .init(0),
    steer: std.atomic.Value(bool) = .init(false),
    child_release: std.atomic.Value(bool) = .init(false),
    /// When the last wait dropped its hold, read by the next yield's note. Zero
    /// once that yield has been noted.
    hold_dropped_ms: i64 = 0,
    first: ?*Run = null,
    more: ?*Run = null,
    call: ?*WaitCall = null,
    prog: Prog = .none,
    execution_id: []const u8 = "",
    programs: u32 = 0,
    waits: u32 = 0,
    posted: u32 = 0,
    joined: u32 = 0,
    told: Told = .none,
    serial: u32 = 0,
    notes: std.ArrayList([]const u8) = .empty,

    fn create(alloc: Allocator, home: []const u8) !*Harness {
        const managed_runtime = try alloc.create(managed.Runtime);
        managed_runtime.* = managed.Runtime.init(alloc);
        const parent = try alloc.create(Parent);
        try parent.init(alloc, home);
        const worker = try alloc.create(worker_runtime.WorkerRuntime);
        worker.* = .{};
        const self = try alloc.create(Harness);
        self.* = .{ .alloc = alloc, .managed = managed_runtime, .parent = parent, .root = undefined, .worker = worker };
        self.root = try tool_host.Runtime.create(alloc, &parent.children, .{ .resolve_fn = resolve }, .{
            .context = self,
            .run_fn = childRun,
        });
        self.root.report_sink = .{ .context = self, .post_fn = sinkPost };
        return self;
    }

    fn startChild(self: *Harness) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var request = try model_contract.validateRequest(self.alloc, .{ .message = .{ .agent = child_name, .message = "work" } });
        defer request.deinit(self.alloc);
        _ = try self.root.executeManaged(arena.allocator(), &request, .{
            .caller_id = self.root.root_id,
            .invocation_id = "start-child",
            .defaults = defaults(),
            .max_result_bytes = 4096,
            .timestamp_ms = 1,
            .caller_worker = self.worker,
        });
        const started = io_mod.milliTimestamp();
        while (!self.working() and io_mod.milliTimestamp() - started < admit_limit_ms) io_mod.sleep(std.time.ns_per_ms);
        if (!self.working()) return error.ChildNotWorking;
    }

    fn working(self: *Harness) bool {
        return !self.root.quiet();
    }

    fn invocation(self: *Harness, label: []const u8) ![]const u8 {
        self.serial += 1;
        return self.alloc.print("{s}-{d}", .{ label, self.serial });
    }

    /// The bash call as the model names it: idle, the first call running, the
    /// wait_more running, or yielded (a call returned while its program runs).
    fn bash(self: *const Harness) []const u8 {
        const active = self.more orelse self.first orelse return "idle";
        if (active.done.load(.seq_cst)) {
            if (active.prepared) |prepared| {
                if (prepared.snapshot.state == .running) return "yielded";
            }
        }
        return if (self.more != null) "more" else "first";
    }

    fn release(self: *Harness, call: *WaitCall) void {
        self.told = call.told;
        self.call = null;
    }

    /// At the end of input, the program ends and the calls it holds return, so
    /// the process does not exit while a call's threads still run.
    fn shutdown(self: *Harness) void {
        self.child_release.store(true, .seq_cst);
        if (self.prog == .running) {
            _ = self.managed.stop(self.alloc, self.execution_id, true) catch {};
        }
        if (self.call) |call| {
            call.cancel.store(true, .seq_cst);
            _ = waitDone(&call.done, shutdown_limit_ms);
        }
        if (self.more) |run| {
            run.cancel.store(true, .seq_cst);
            _ = waitDone(&run.done, shutdown_limit_ms);
        }
        if (self.first) |run| {
            run.cancel.store(true, .seq_cst);
            _ = waitDone(&run.done, shutdown_limit_ms);
        }
    }

    fn refuse(self: *Harness, event: []const u8) !void {
        try self.notes.append(self.alloc, try self.alloc.print("refused: {s}", .{event}));
    }

    fn note(self: *Harness, text: []const u8) !void {
        try self.notes.append(self.alloc, text);
    }

    fn awaitAdmitted(self: *Harness, id: []const u8) !bool {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < admit_limit_ms) {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const items = try self.managed.list(arena.allocator());
            for (items) |item| {
                if (std.mem.eql(u8, item.execution_id, id)) return true;
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        return false;
    }

    /// The model's Run: a program starts, and its first call begins.
    fn doRun(self: *Harness) !void {
        const bash_now = self.bash();
        const idle = std.mem.eql(u8, bash_now, "idle") or std.mem.eql(u8, bash_now, "yielded");
        if (self.prog == .running or self.call != null or self.programs >= max_programs or !idle) {
            return self.refuse("run");
        }
        self.serial += 1;
        const id = try self.alloc.print("agent-program-{d}", .{self.serial});
        const run = try self.alloc.create(Run);
        run.* = .{};
        self.first = run;
        self.more = null;
        self.execution_id = id;
        self.prog = .running;
        self.programs += 1;
        self.waits = 0;
        const thread = try std.Thread.spawn(.{}, firstMain, .{ self, run, id });
        thread.detach();
        if (!try self.awaitAdmitted(id)) try self.note("program was not admitted");
    }

    /// The model's WaitMore: the yielded program's next call waits for its yield.
    fn doWaitMore(self: *Harness) !void {
        if (!std.mem.eql(u8, self.bash(), "yielded")) return self.refuse("wait_more");
        const run = try self.alloc.create(Run);
        run.* = .{};
        self.more = run;
        const thread = try std.Thread.spawn(.{}, moreMain, .{ self, run, self.execution_id });
        thread.detach();
        // A program already gone answers its wait_more at once; a running one may wait for its yield.
        if (self.prog != .running) _ = waitDone(&run.done, answer_window_ms);
    }

    /// The model's Yield: the running call returns, as a steering yield does.
    /// While a bridge call holds it, the call must not return, so the window is
    /// short; without a bridge call the window covers the bridge grace. The
    /// note gives the time from the last hold drop to the yield, for the timed
    /// scenario in agent-timing.ts.
    fn doYield(self: *Harness) !void {
        const bash_now = self.bash();
        const in_bash = std.mem.eql(u8, bash_now, "first") or std.mem.eql(u8, bash_now, "more");
        if (!in_bash or self.prog != .running) return self.refuse("yield");
        const active = self.more orelse self.first orelse return self.refuse("yield");
        const window: i64 = if (self.call != null) held_yield_probe_ms else answer_window_ms;
        self.steer.store(true, .seq_cst);
        _ = waitDone(&active.done, window);
        self.steer.store(false, .seq_cst);
        if (self.hold_dropped_ms != 0) {
            try self.note(try self.alloc.print("yield {d} ms after the hold dropped", .{io_mod.milliTimestamp() - self.hold_dropped_ms}));
            self.hold_dropped_ms = 0;
        }
        if (active.done.load(.seq_cst)) {
            if (active.prepared) |prepared| {
                if (prepared.snapshot.state == .running) {
                    self.managed.commitDelivery(self.execution_id, prepared.reservation_id) catch |err| {
                        try self.note(try self.alloc.print("commit failed: {s}", .{@errorName(err)}));
                    };
                }
            }
        }
    }

    /// The model's Return: a bash call whose program is gone returns.
    fn doReturn(self: *Harness) !void {
        const active = self.more orelse self.first orelse return self.refuse("return");
        if (self.prog != .gone or self.call != null or !active.done.load(.seq_cst)) return self.refuse("return");
        if (active.prepared) |prepared| {
            if (prepared.snapshot.state == .running) return self.refuse("return");
        }
        self.first = null;
        self.more = null;
    }

    /// The model's Gone: the program is killed. The active call is canceled, as
    /// its client's cancel does: a first call that has not yielded returns once
    /// its program is killed, and a wait_more ends at its cancel. A call that
    /// returned the end of its program has killed it. Otherwise the program is
    /// stopped. Its wait stays open until Cancel.
    fn doGone(self: *Harness) !void {
        if (self.prog != .running) return self.refuse("gone");
        const active = self.more orelse self.first orelse return self.refuse("gone");
        active.cancel.store(true, .seq_cst);
        _ = waitDone(&active.done, answer_window_ms);
        if (active.done.load(.seq_cst)) {
            if (active.prepared) |prepared| {
                if (prepared.snapshot.state != .running) {
                    self.prog = .gone;
                    return;
                }
            }
        }
        const stopped = self.managed.stop(self.alloc, self.execution_id, true) catch |err| {
            return self.note(try self.alloc.print("stop failed: {s}", .{@errorName(err)}));
        };
        if (stopped.snapshot.state == .running) return self.note("the program still runs after stop");
        self.prog = .gone;
    }

    /// The model's StartWait: a bridge request starts the subagent wait. Once a
    /// call has yielded the bridge is gone, and the request is refused.
    fn doStartWait(self: *Harness) !void {
        if (self.prog != .running or self.call != null or self.waits >= max_waits) return self.refuse("start_wait");
        self.waits += 1;
        if (!std.mem.eql(u8, self.bash(), "first")) {
            self.told = .unavailable;
            return;
        }
        const call = try self.alloc.create(WaitCall);
        call.* = .{ .id = try self.invocation("agent-wait") };
        self.call = call;
        _ = self.hold.fetchAdd(1, .acq_rel);
        const thread = try std.Thread.spawn(.{}, waitMain, .{ self, call });
        thread.detach();
        const should_return = self.worker.queuedPromptCount() > 0 or !self.working();
        const window: i64 = if (should_return) answer_window_ms else still_waiting_probe_ms;
        if (waitDone(&call.done, window)) self.release(call);
    }

    fn waitOnce(self: *Harness, call: *WaitCall) Told {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var request = model_contract.validateRequest(self.alloc, .wait) catch return .other;
        defer request.deinit(self.alloc);
        const result = self.root.executeManaged(arena.allocator(), &request, .{
            .caller_id = self.root.root_id,
            .invocation_id = call.id,
            .defaults = defaults(),
            .max_result_bytes = 4096,
            .timestamp_ms = 1,
            .caller_worker = self.worker,
            .cancel_flag = &call.cancel,
        }) catch |err| return if (err == error.Cancelled) .canceled else .other;
        return classify(result.body);
    }

    /// The model's Post: the child sends a message to its parent while it works.
    fn doPost(self: *Harness) !void {
        if (!self.working() or self.posted >= max_posts) return self.refuse("post");
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var request = try model_contract.validateRequest(self.alloc, .{ .message = .{ .agent = "parent", .message = "a note from the child" } });
        defer request.deinit(self.alloc);
        const result = self.root.executeManaged(arena.allocator(), &request, .{
            .caller_id = child_name,
            .invocation_id = try self.invocation("agent-post"),
            .defaults = defaults(),
            .max_result_bytes = 4096,
            .timestamp_ms = 1,
            .caller_worker = null,
        }) catch |err| {
            return self.note(try self.alloc.print("post failed: {s}", .{@errorName(err)}));
        };
        if (std.mem.find(u8, result.body, "Sent to your parent") == null) try self.note("post was not sent");
        self.settleOpenWait();
    }

    /// The model's ChildEnds: the child's work ends with no report. A wait that
    /// is open ends with it.
    fn doChildEnds(self: *Harness) !void {
        if (!self.working()) return self.refuse("child_ends");
        self.child_release.store(true, .seq_cst);
        const started = io_mod.milliTimestamp();
        while (self.working() and io_mod.milliTimestamp() - started < child_end_limit_ms) io_mod.sleep(std.time.ns_per_ms);
        if (self.working()) try self.note("child is still working");
        self.settleOpenWait();
    }

    /// The post or the child's end ends an open wait at once, so its answer is
    /// read here, within the answer window. A wait still open after the window
    /// is left for the state to show.
    fn settleOpenWait(self: *Harness) void {
        const call = self.call orelse return;
        if (waitDone(&call.done, answer_window_ms)) self.release(call);
    }

    /// The model's Cancel: the bridge's watch cancels the wait of a program that
    /// is gone, and the wait returns.
    fn doCancel(self: *Harness) !void {
        const call = self.call orelse return self.refuse("cancel");
        if (self.prog != .gone) return self.refuse("cancel");
        call.cancel.store(true, .seq_cst);
        if (waitDone(&call.done, answer_window_ms)) self.release(call);
    }

    /// The model's Join: the parent's turn takes the queued mail. Glue: the
    /// parent takes mail only between its bash calls, as the model does.
    fn doJoin(self: *Harness) !void {
        const bash_now = self.bash();
        if (!(std.mem.eql(u8, bash_now, "idle") or std.mem.eql(u8, bash_now, "yielded"))) return self.refuse("join");
        const taken = self.worker.takeQueuedPrompt(self.alloc) orelse return self.refuse("join");
        worker_runtime.freeQueuedPrompt(self.alloc, taken);
        self.joined += 1;
    }

    fn perform(self: *Harness, event: []const u8) !void {
        if (std.mem.eql(u8, event, "run")) return self.doRun();
        if (std.mem.eql(u8, event, "wait_more")) return self.doWaitMore();
        if (std.mem.eql(u8, event, "yield")) return self.doYield();
        if (std.mem.eql(u8, event, "return")) return self.doReturn();
        if (std.mem.eql(u8, event, "gone")) return self.doGone();
        if (std.mem.eql(u8, event, "start_wait")) return self.doStartWait();
        if (std.mem.eql(u8, event, "post")) return self.doPost();
        if (std.mem.eql(u8, event, "child_ends")) return self.doChildEnds();
        if (std.mem.eql(u8, event, "cancel")) return self.doCancel();
        if (std.mem.eql(u8, event, "join")) return self.doJoin();
        try self.note(try self.alloc.print("unknown event: {s}", .{event}));
    }

    fn writeState(self: *Harness, out: *std.Io.Writer) !void {
        const queued = self.worker.queuedPromptCount();
        const lost = @as(i64, self.posted) - @as(i64, @intCast(queued)) - @as(i64, self.joined);
        try out.print(
            "{{\"state\":{{\"prog\":\"{s}\",\"programs\":{d},\"call\":\"{s}\",\"waits\":{d},\"bash\":\"{s}\",\"working\":{},\"posted\":{d},\"queued\":{d},\"joined\":{d},\"lost\":{d},\"told\":\"{s}\"}},\"out\":[",
            .{
                @tagName(self.prog),
                self.programs,
                if (self.call != null) "waiting" else "none",
                self.waits,
                self.bash(),
                self.working(),
                self.posted,
                queued,
                self.joined,
                lost,
                @tagName(self.told),
            },
        );
        for (self.notes.items, 0..) |text, index| {
            if (index > 0) try out.writeAll(",");
            try out.print("\"{s}\"", .{text});
        }
        try out.writeAll("]}\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_mod.setIo(io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.smp_allocator;
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());
    // A command's shell waits on this binary as its foreground session helper,
    // as fx's own binary is, so the helper request comes before anything else.
    if (command_runner.isForegroundSessionInvocation(args[1..])) {
        return command_runner.runForegroundSessionBootstrap(args[1..]);
    }
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--root")) return error.Usage;
    const self = try Harness.create(alloc, args[2]);
    try self.startChild();

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    try self.writeState(&stdout.interface);
    try stdout.interface.flush();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, arena_state.allocator(), text, .{ .ignore_unknown_fields = true });
        self.notes.clearRetainingCapacity();
        try self.perform(parsed.value.event);
        try self.writeState(&stdout.interface);
        try stdout.interface.flush();
        _ = arena_state.reset(.retain_capacity);
    }
    self.shutdown();
    // The product's threads can still run here. Returning from main would
    // tear down the environment map and io runtime that main installed, and
    // those threads read them. So the process ends here, as fx's own exit does
    // (src/main.zig exitFast).
    std.process.exit(0);
}
