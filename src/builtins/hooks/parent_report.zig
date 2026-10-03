//! Reports this fx's state to the fx that launched it, when it runs in a
//! sub-engine terminal: ready or working, its session, each submitted
//! message, each turn's end with the final reply, and each prompt it shows.
//! It also applies the parent's answers to those prompts.
//!
//! Reports are lines on the report channel the terminal hands down, and the
//! parent's answers arrive on the same channel. One lock
//! orders the UI and worker threads: a submit holds it from queueing the
//! message until the message is reported, and a turn end holds it from
//! checking the queue until the turn end is reported. So once the parent has
//! applied every line, it says idle exactly when no turn runs and nothing is
//! queued. The UI's tick reports prompts under the same lock; a prompt's
//! close restores the activity last reported.
//!
//! Best effort: a failed report is logged and turns reporting off, so the
//! session never fails or waits long because of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sub_engine = @import("sub_engine");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const labels = @import("../../core/child_agents/labels.zig");
const diff = @import("../../core/output/diff.zig");
const input_approval_runtime = @import("../../core/app/input_approval_runtime.zig");
const input_question_runtime = @import("../../core/app/input_question_runtime.zig");
const types = @import("../../core/shared/types.zig");

/// How long one report waits for room in the channel before reporting stops.
const write_timeout_ms = 1000;

// A line the parent drops would lose a report, so the longest one fits:
// escaping grows text at most six times, plus the event's own fields.
comptime {
    std.debug.assert(6 * labels.max_text + 256 <= sub_engine.max_report_line);
    // A permission prompt carries a request fx already bounded.
    std.debug.assert(6 * diff.max_request_projection_bytes + 4096 <= sub_engine.max_report_line);
}

pub const Client = struct {
    fd: ?std.posix.fd_t = null,
    mutex: std.Io.Mutex = .init,
    /// The session last reported.
    session: [128]u8 = undefined,
    session_len: usize = 0,
    /// The activity last reported, which a prompt's close restores.
    activity: labels.Activity = .idle,
    prompts: labels.PromptTracker = .{},
    /// Frames the parent's answers. Used by the UI thread only.
    answers: sub_engine.Lines = .{ .limit = sub_engine.max_reply_line },

    /// Says whether a waiting message keeps the child working after a turn.
    /// Runs under the lock.
    pub const Queued = struct {
        ctx: *anyopaque,
        any: *const fn (ctx: *anyopaque) bool,
    };

    /// Turns reporting on when the environment names a report channel that
    /// this process still holds.
    pub fn initFromEnv(self: *Client) void {
        if (comptime host_target.is_wasm) return;
        const value = io_mod.getenv(sub_engine.report_env_name) orelse return;
        const fd = sub_engine.inheritedReportFd(value) orelse {
            debug_trace.logf("parent_report", "disabled: {s} names no inherited pipe value={s}", .{ sub_engine.report_env_name, value });
            return;
        };
        // Programs this fx starts must not inherit the channel, and a parent
        // that stops reading must not block a report for good.
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0 or
            flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0)
        {
            debug_trace.logf("parent_report", "disabled: could not set up fd={d}", .{fd});
            return;
        }
        self.fd = fd;
        debug_trace.logf("parent_report", "enabled fd={d}", .{fd});
    }

    pub fn enabled(self: *const Client) bool {
        return self.fd != null;
    }

    /// Frees the answer framing. The fd belongs to the process.
    pub fn deinit(self: *Client) void {
        self.answers.deinit(std.heap.c_allocator);
    }

    pub fn reportSession(self: *Client, session_id: []const u8) void {
        if (!self.enabled() or session_id.len == 0) return;
        self.lock();
        defer self.unlock();
        if (std.mem.eql(u8, self.session[0..self.session_len], session_id)) return;
        self.send(.{ .session = session_id });
        if (session_id.len <= self.session.len) {
            @memcpy(self.session[0..session_id.len], session_id);
            self.session_len = session_id.len;
        }
    }

    pub fn reportState(self: *Client, state: labels.Activity) void {
        if (!self.enabled()) return;
        self.lock();
        defer self.unlock();
        self.send(.{ .state = state });
    }

    /// A paste reached the composer.
    pub fn reportPasted(self: *Client) void {
        if (!self.enabled()) return;
        self.lock();
        defer self.unlock();
        self.send(.pasted);
    }

    /// A prompt this fx shows: what tells it apart, and what the parent shows.
    pub const Shown = struct {
        key: labels.PromptTracker.Key,
        reason: labels.BlockedReason,
        body: @FieldType(labels.Prompt, "body"),
    };

    /// This fx shows `shown` now, or no prompt. Reports a change: the old
    /// prompt's close, then the new prompt.
    pub fn reportPrompt(self: *Client, shown: ?Shown) void {
        if (!self.enabled()) return;
        self.lock();
        defer self.unlock();
        const change = self.prompts.observe(if (shown) |prompt| prompt.key else null);
        if (change.closed) |number| self.send(.{ .prompt_closed = .{ .number = number, .next = self.activity } });
        if (change.opened) |number| self.send(.{ .prompt = .{
            .number = number,
            .reason = shown.?.reason,
            .body = shown.?.body,
        } });
    }

    /// Applies one answer to the open prompt it is for.
    pub const Apply = struct {
        ctx: *anyopaque,
        apply: *const fn (ctx: *anyopaque, key: labels.PromptTracker.Key, answer: labels.Answer) void,
    };

    /// Reads the parent's answers without blocking. Each answer for the
    /// prompt still open with its number goes to `apply`, outside the lock;
    /// the rest are dropped. Lines are parsed into `arena`.
    pub fn takeAnswers(self: *Client, arena: Allocator, apply: Apply) void {
        const fd = self.fd orelse return;
        var lines: std.ArrayList([]const u8) = .empty;
        const Collect = struct {
            arena: Allocator,
            lines: *std.ArrayList([]const u8),
            fn line(ctx: *anyopaque, bytes: []const u8) void {
                const collect: *@This() = @ptrCast(@alignCast(ctx));
                const copy = collect.arena.dupe(u8, bytes) catch return;
                collect.lines.append(collect.arena, copy) catch {};
            }
        };
        var collect: Collect = .{ .arena = arena, .lines = &lines };
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = std.c.read(fd, &buf, buf.len);
            if (rc > 0) {
                self.answers.feed(std.heap.c_allocator, buf[0..@intCast(rc)], .{ .ctx = &collect, .line = Collect.line });
                continue;
            }
            if (rc < 0 and std.c.errno(rc) == .INTR) continue;
            break;
        }
        for (lines.items) |line| {
            const answer = labels.parseAnswer(arena, line) catch |err| {
                debug_trace.logf("parent_report", "answer ignored bytes={d} err={s}", .{ line.len, @errorName(err) });
                continue;
            };
            const key = blk: {
                self.lock();
                defer self.unlock();
                break :blk self.prompts.take(answer.prompt);
            } orelse {
                debug_trace.logf("parent_report", "answer dropped prompt={d} reason=not_open", .{answer.prompt});
                continue;
            };
            apply.apply(apply.ctx, key, answer);
        }
    }

    /// Reports a turn's end with its final reply, or null when the turn did
    /// not complete.
    pub fn reportTurnEnd(self: *Client, final: ?[]const u8, queued: Queued) void {
        if (!self.enabled()) return;
        self.lock();
        defer self.unlock();
        const next: labels.Activity = if (queued.any(queued.ctx)) .working else .idle;
        self.send(.{ .turn_end = .{ .final = final, .next = next } });
    }

    /// Starts a submit. The lock is held until `Submit.reported`,
    /// `Submit.working` or `Submit.end`; queue the message in between.
    pub fn beginSubmit(self: *Client) Submit {
        if (!self.enabled()) return .{ .client = null };
        self.lock();
        return .{ .client = self };
    }

    pub const Submit = struct {
        client: ?*Client,

        /// The message is queued: report it.
        pub fn reported(self: *Submit, message: []const u8) void {
            const client = self.client orelse return;
            client.send(.{ .message = message });
            self.release();
        }

        /// Earlier work is queued again: report the child working.
        pub fn working(self: *Submit) void {
            const client = self.client orelse return;
            client.send(.{ .state = .working });
            self.release();
        }

        /// Ends the submit, releasing the lock if nothing was reported. Safe
        /// to call after `reported` or `working`.
        pub fn end(self: *Submit) void {
            self.release();
        }

        fn release(self: *Submit) void {
            const client = self.client orelse return;
            self.client = null;
            client.unlock();
        }
    };

    fn lock(self: *Client) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Client) void {
        self.mutex.unlock(io_mod.getIo());
    }

    /// Writes one report. Called with the lock held.
    fn send(self: *Client, event: labels.Event) void {
        switch (event) {
            .state => |state| self.activity = state,
            .message => self.activity = .working,
            .turn_end => |end| self.activity = end.next,
            .session, .pasted, .prompt, .prompt_closed => {},
        }
        const fd = self.fd orelse return;
        const line = labels.encode(std.heap.c_allocator, event) catch {
            debug_trace.logf("parent_report", "dropped report kind={s} err=OutOfMemory", .{@tagName(event)});
            return;
        };
        defer std.heap.c_allocator.free(line);
        writeAll(fd, line) catch |err| {
            // A partial line would corrupt the next one, so stop for good.
            self.fd = null;
            debug_trace.logf("parent_report", "disabled: report failed kind={s} err={s}", .{ @tagName(event), @errorName(err) });
        };
    }
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) error{ Timeout, WriteFailed }!void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = std.c.write(fd, rest.ptr, rest.len);
        if (rc > 0) {
            rest = rest[@intCast(rc)..];
            continue;
        }
        switch (std.c.errno(rc)) {
            .INTR => {},
            .AGAIN => {
                var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
                const ready = std.c.poll(&fds, 1, write_timeout_ms);
                if (ready == 0) return error.Timeout;
                if (ready < 0 and std.c.errno(ready) != .INTR) return error.WriteFailed;
            },
            // EPIPE: the parent is gone.
            else => return error.WriteFailed,
        }
    }
}

/// The parent-report provider: registers its lifecycle hooks and reports
/// submits for an `App` with `parent_report`, `lifecycle_runtime` and
/// `worker` fields.
pub fn Runtime(comptime App: type) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen. Does nothing
        /// unless `Client.initFromEnv` claimed a report channel.
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            if (!app.parent_report.enabled()) return;
            if (active_session_id) |session_id| app.parent_report.reportSession(session_id);
            app.parent_report.reportState(.idle);
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.parent_report.turn_end",
                .ctx = app,
                .run = postTurnEnd,
            });
        }

        fn postTurnEnd(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            if (input.invocation.scope.session_id) |session_id| app.parent_report.reportSession(session_id);
            app.parent_report.reportTurnEnd(input.final_text, .{ .ctx = app, .any = anyQueued });
        }

        fn anyQueued(raw: *anyopaque) bool {
            const app: *App = @ptrCast(@alignCast(raw));
            return app.worker.queuedPromptCount() > 0;
        }

        /// Every loop tick, after the worker's: reports the prompt this fx
        /// shows when it changes, and applies the parent's answers to it.
        /// Needs what the approval and question input runtimes need.
        pub fn tick(app: *App) void {
            if (!app.parent_report.enabled()) return;
            var arena_state = std.heap.ArenaAllocator.init(app.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            app.parent_report.reportPrompt(shownPrompt(app, arena));
            app.parent_report.takeAnswers(arena, .{ .ctx = app, .apply = applyAnswer });
        }

        /// The prompt this fx shows. A permission rule confirmation stays
        /// local: its answer does not go to the worker.
        fn shownPrompt(app: *App, arena: Allocator) ?Client.Shown {
            if (app.approval_prompt.request) |*request| {
                if (app.approval_prompt.rule_management != null) return null;
                return .{ .key = .{ .permission = request.id }, .reason = .permission, .body = .{ .permission = request.view() } };
            }
            if (!app.question_prompt.isActive()) return null;
            const batch = (app.worker.snapshotPendingQuestionBatch(arena) catch return null) orelse return null;
            return .{
                .key = .{ .questions = hashQuestions(batch.entries) },
                .reason = if (batch.source == .route_recovery) .recovery else .question,
                .body = .{ .questions = batch.entries },
            };
        }

        /// Applies a parent's answer through the same paths as an answer
        /// given on this fx's own screen, so the transcript and the turn
        /// end up the same either way.
        fn applyAnswer(raw: *anyopaque, key: labels.PromptTracker.Key, answer: labels.Answer) void {
            const app: *App = @ptrCast(@alignCast(raw));
            switch (key) {
                .permission => |request_id| {
                    const permission = switch (answer.reply) {
                        .permission => |permission| permission,
                        .questions => return debug_trace.logf("parent_report", "answer dropped prompt={d} reason=wrong_kind", .{answer.prompt}),
                    };
                    const decision: types.ToolPermissionDecision = switch (permission.decision) {
                        .once => .once,
                        .always => .always,
                        .deny => .deny,
                    };
                    const applied = input_approval_runtime.ApprovalRuntime(App).submitParentPermission(
                        app,
                        request_id,
                        decision,
                        permission.feedback,
                    ) catch |err| {
                        return debug_trace.logf("parent_report", "permission answer failed prompt={d} err={s}", .{ answer.prompt, @errorName(err) });
                    };
                    debug_trace.logf("parent_report", "permission answered prompt={d} decision={s} applied={}", .{ answer.prompt, @tagName(decision), applied });
                },
                .questions => |hash| {
                    const answers = switch (answer.reply) {
                        .questions => |answers| answers,
                        .permission => return debug_trace.logf("parent_report", "answer dropped prompt={d} reason=wrong_kind", .{answer.prompt}),
                    };
                    const batch = (app.worker.snapshotPendingQuestionBatch(app.alloc) catch null) orelse {
                        return debug_trace.logf("parent_report", "answer dropped prompt={d} reason=no_batch", .{answer.prompt});
                    };
                    defer batch.deinit(app.alloc);
                    const entries = app.question_prompt.entries.items.len;
                    const matches = hashQuestions(batch.entries) == hash and app.question_prompt.isActive() and
                        (if (answers) |list| list.len == entries else true);
                    if (!matches) return debug_trace.logf("parent_report", "answer dropped prompt={d} reason=batch_mismatch", .{answer.prompt});
                    const question_runtime = input_question_runtime.QuestionRuntime(App);
                    const result = if (answers) |list| question_runtime.submitQuestionAnswers(app, list) else question_runtime.cancelQuestionPrompt(app);
                    result catch |err| {
                        return debug_trace.logf("parent_report", "question answer failed prompt={d} err={s}", .{ answer.prompt, @errorName(err) });
                    };
                    debug_trace.logf("parent_report", "questions answered prompt={d} cancelled={}", .{ answer.prompt, answers == null });
                },
            }
        }
    };
}

/// Tells question batches apart: they have no id.
fn hashQuestions(entries: []const types.QuestionBatchEntry) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (entries) |entry| {
        hasher.update(entry.question);
        hasher.update(&.{0});
        for (entry.options) |option| {
            hasher.update(option.label);
            hasher.update(&.{0});
        }
        hasher.update(&.{ 1, @intFromEnum(entry.submission) });
    }
    return hasher.final();
}

const testing = std.testing;

/// A pipe whose write end the client reports on.
const TestPipe = struct {
    fds: [2]std.posix.fd_t,

    fn open() !TestPipe {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        return .{ .fds = fds };
    }

    fn close(self: TestPipe) void {
        _ = std.c.close(self.fds[0]);
        _ = std.c.close(self.fds[1]);
    }

    /// Applies every line written so far to `store`.
    fn applyTo(self: TestPipe, store: *labels.Labels) !void {
        const flags = std.c.fcntl(self.fds[0], std.c.F.GETFL, @as(c_int, 0));
        const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
        _ = std.c.fcntl(self.fds[0], std.c.F.SETFL, flags | nonblock);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = std.c.read(self.fds[0], &buf, buf.len);
            if (rc <= 0) break;
            try bytes.appendSlice(testing.allocator, buf[0..@intCast(rc)]);
        }
        var lines = std.mem.splitScalar(u8, bytes.items, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) try store.apply(testing.allocator, line);
        }
    }
};

const TestApp = struct {
    lifecycle_runtime: hooks.Runtime,
    parent_report: Client = .{},
    worker: struct {
        queued: std.atomic.Value(usize) = .init(0),

        fn queuedPromptCount(self: *@This()) usize {
            return self.queued.load(.acquire);
        }
    } = .{},
};

fn testInvocation(kind: hooks.ScopeKind) hooks.Invocation {
    return .{ .scope = .{ .kind = kind, .workspace_root = "/tmp/workspace", .session_id = "session-7" }, .turn_id = 1 };
}

test "a child's lifecycle reaches the parent's labels" {
    const pipe = try TestPipe.open();
    defer pipe.close();
    var app: TestApp = .{ .lifecycle_runtime = hooks.Runtime.init(testing.allocator) };
    defer app.lifecycle_runtime.deinit();
    app.parent_report.fd = pipe.fds[1];
    const Provider = Runtime(TestApp);
    try Provider.configure(&app, null);
    const view = app.lifecycle_runtime.freeze();

    var submit = app.parent_report.beginSubmit();
    app.worker.queued.store(1, .release);
    submit.reported("fix the tests");
    app.worker.queued.store(0, .release);
    view.runAttentionRequired(.{ .invocation = testInvocation(.interactive), .kind = .permission });
    // Turns outside the interactive scope are not this child's.
    view.runPostTurnEnd(.{ .invocation = testInvocation(.ask), .outcome = .completed, .final_text = "other" });
    view.runPostTurnEnd(.{ .invocation = testInvocation(.interactive), .outcome = .completed, .final_text = "Fixed." });

    var store: labels.Labels = .{};
    defer store.deinit(testing.allocator);
    try pipe.applyTo(&store);
    try testing.expectEqual(labels.State.idle, store.state);
    try testing.expectEqualStrings("session-7", store.session_id.?);
    try testing.expectEqualStrings("Fixed.", store.final.?);
    try testing.expectEqual(@as(u64, 1), store.turns_ended);
    try testing.expectEqualStrings("fix the tests", store.messages.items[0].text);
}

test "a turn end waits for a submit in progress and stays working" {
    const pipe = try TestPipe.open();
    defer pipe.close();
    var app: TestApp = .{ .lifecycle_runtime = hooks.Runtime.init(testing.allocator) };
    defer app.lifecycle_runtime.deinit();
    app.parent_report.fd = pipe.fds[1];
    const Provider = Runtime(TestApp);

    // The submit holds the lock while its message is queued, so the turn
    // end, started meanwhile, sees the queue only after the message.
    var submit = app.parent_report.beginSubmit();
    const turn_end = try std.Thread.spawn(.{}, struct {
        fn run(target: *TestApp) void {
            target.parent_report.reportTurnEnd("First.", .{ .ctx = target, .any = Provider.anyQueued });
        }
    }.run, .{&app});
    var none: [0]std.c.pollfd = .{};
    _ = std.c.poll(&none, 0, 50);
    app.worker.queued.store(1, .release);
    submit.reported("next");
    turn_end.join();

    var store: labels.Labels = .{};
    defer store.deinit(testing.allocator);
    try pipe.applyTo(&store);
    try testing.expectEqual(labels.State.working, store.state);
    try testing.expectEqual(@as(u64, 1), store.messages_total);
    try testing.expectEqualStrings("First.", store.final.?);
}

test "a failed report turns reporting off" {
    const pipe = try TestPipe.open();
    var client: Client = .{ .fd = pipe.fds[1] };
    pipe.close();
    client.reportState(.idle);
    try testing.expect(!client.enabled());
    // Later reports and submits do nothing.
    client.reportState(.working);
    var submit = client.beginSubmit();
    submit.reported("ignored");
}
