//! `/loop` on the app thread: the command's notices, and the glue between an
//! agent's `loops.Loops` and the worker that runs each loop's prompt. Every
//! function runs on the main loop, the only thread that touches `Loops`.

const std = @import("std");
const loops = @import("../loops/loops.zig");
const agents = @import("../agents/agents.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

/// Longest prompt excerpt a notice shows, after terminal-safe encoding.
const max_prompt_display_bytes: usize = 200;

/// The wait between runs that tests set with `FX_TEST_LOOP_INTERVAL_MS`, so
/// an E2E test sees runs without waiting the 1m minimum. Bounded so a typo
/// cannot hot-loop; null outside that range or when unset.
fn testWaitMs() ?u64 {
    const text = io_mod.getenv("FX_TEST_LOOP_INTERVAL_MS") orelse return null;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return null;
    if (parsed < 100 or parsed > loops.min_interval_ms) return null;
    return parsed;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Runs `/loop <payload>` for `agent`, the agent on screen.
        pub fn handleCommand(app: *App, agent: anytype, payload: []const u8) !void {
            const command = loops.parseCommand(payload) catch |err| return writeParseError(app, err, payload);
            switch (command) {
                .list => try writeList(app, agent),
                .arm => |arm| try armLoop(app, agent, arm.interval_ms, arm.prompt),
                .stop => |target| try stopLoops(app, agent, target),
                .resume_loop => |id| try resumeLoop(app, agent, id),
            }
        }

        /// Starts the run of every loop that is due on an idle instance. Runs
        /// on each main-loop pass; a run that cannot be queued counts as a
        /// failure and waits an interval, so no error leaves this function.
        pub fn tick(app: *App) void {
            if (comptime !agents.hasAgentField(App, "loops")) return;
            const now_ms = app_permission_runtime.monotonicMillis();
            if (app_agents_runtime.Runtime(App).firstOpen(app)) tickAgent(app, &app.main_agent, now_ms);
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                tickAgent(app, &child.agent, now_ms);
            }
        }

        fn tickAgent(app: *App, agent: *agents.Agent, now_ms: i64) void {
            if (agent.loops.count() == 0 or !agentIdle(agent)) return;
            const loop = agent.loops.nextDue(now_ms) orelse return;
            // Only the agent on screen has the transcript a notice draws in.
            // A hidden instance still shows the run's prompt as a user card.
            if (agents.screenAgentOf(app) == agent) writeRunMarker(app, loop.*) catch |err| debug_trace.logf("loop", "event=marker_failed id={d} err={s}", .{ loop.id, @errorName(err) });
            const turn_id = debug_trace.nextTurnId();
            app.queueLoopRun(agent, loop.prompt, turn_id) catch |err| {
                const finished = agent.loops.noteAdmissionFailed(loop, now_ms);
                debug_trace.logf("loop", "event=admission_failed id={d} err={s} failures={d}", .{ loop.id, @errorName(err), finished.failures });
                if (agents.screenAgentOf(app) == agent) {
                    writeCouldNotStart(app, loop.*, err) catch {};
                    if (finished.paused) writeFailure(app, finished) catch {};
                }
                return;
            };
            agent.loops.markStarted(loop, turn_id);
            debug_trace.logf("loop", "event=run_started id={d} turn={d}", .{ loop.id, turn_id });
        }

        /// Records how a loop's run ended, so the loop waits an interval
        /// from now before its next run, and says when a run failed or the
        /// loop paused.
        pub fn noteTurnFinished(app: *App, agent: anytype, finished: types.TurnFinished) !void {
            const outcome: loops.Outcome = switch (finished.outcome) {
                .completed => .completed,
                .interrupted => .interrupted,
                .failed => .failed,
                .paused => .paused,
            };
            const result = agent.loops.noteTurnFinished(finished.turn_id, outcome, app_permission_runtime.monotonicMillis()) orelse return;
            debug_trace.logf("loop", "event=run_finished id={d} outcome={s} failures={d}", .{ result.id, @tagName(outcome), result.failures });
            if (!result.failed or agents.screenAgentOf(app) != agent) return;
            try writeFailure(app, result);
        }

        /// The failure notice, or the pause notice once the loop paused.
        fn writeFailure(app: *App, result: loops.Finished) !void {
            if (result.paused) {
                debug_trace.logf("loop", "event=paused id={d}", .{result.id});
                return writeNotice(app, .warning, "Loop {d} paused after {d} failed runs. Fix the cause, then run /loop resume {d}.", .{ result.id, loops.pause_after_failures, result.id });
            }
            try writeNotice(app, .warning, "Loop {d} failed ({d} of {d} before it pauses).", .{ result.id, result.failures, loops.pause_after_failures });
        }

        /// The `/compact` busy check (`input_submit_runtime.zig`) negated: no
        /// prompt waiting to be sent, no turn running or queued, and no
        /// compaction, so a message the user just sent always goes first.
        fn agentIdle(agent: *agents.Agent) bool {
            return agent.submission.pending == null and !agent.worker.isProcessing() and
                agent.worker.queuedPromptCount() == 0 and agent.worker.contextCompactionStatus() == .idle;
        }

        fn writeRunMarker(app: *App, loop: loops.Loop) !void {
            var shown = try text_utils.encodeTerminalSafe(app.alloc, loop.prompt, max_prompt_display_bytes);
            defer shown.deinit(app.alloc);
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .neutral, "loop {d} · every {s} · {s}", .{ loop.id, formatInterval(&interval_buf, loop.interval_ms), shown.bytes });
        }

        fn writeCouldNotStart(app: *App, loop: loops.Loop, err: anyerror) !void {
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .warning, "Loop {d} could not start: {s}. Next try in {s} (failure {d} of {d}).", .{
                loop.id,
                @errorName(err),
                formatInterval(&interval_buf, loop.interval_ms),
                loop.consecutive_failures,
                loops.pause_after_failures,
            });
        }

        fn armLoop(app: *App, agent: anytype, interval_ms: u64, prompt: []const u8) !void {
            agent.loops.wait_override_ms = testWaitMs();
            const id = agent.loops.arm(app.alloc, interval_ms, prompt, app_permission_runtime.monotonicMillis()) catch |err| switch (err) {
                error.TooManyLoops => return writeNotice(app, .warning, "A conversation holds at most {d} loops. Stop one with /loop stop <id>.", .{loops.max_loops}),
                error.OutOfMemory => return err,
            };
            debug_trace.logf("loop", "event=armed id={d} interval_ms={d}", .{ id, interval_ms });
            var shown = try text_utils.encodeTerminalSafe(app.alloc, prompt, max_prompt_display_bytes);
            defer shown.deinit(app.alloc);
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .neutral, "Loop {d} runs every {s} until you stop it or fx exits: {s}", .{ id, formatInterval(&interval_buf, interval_ms), shown.bytes });
        }

        fn writeList(app: *App, agent: anytype) !void {
            if (agent.loops.count() == 0) return writeNotice(app, .neutral, "No active loops. Start one with /loop <interval> <prompt>.", .{});
            const now_ms = app_permission_runtime.monotonicMillis();
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(app.alloc);
            for (agent.loops.items.items, 0..) |loop, index| {
                if (index > 0) try body.append(app.alloc, '\n');
                var interval_buf: [32]u8 = undefined;
                var when_buf: [64]u8 = undefined;
                const when = switch (loop.state) {
                    .paused => try std.mem.print(&when_buf, "paused · /loop resume {d}", .{loop.id}),
                    .running => "running now",
                    .waiting => try std.mem.print(&when_buf, "next in {s}", .{formatRemaining(&interval_buf, loop.next_due_ms - now_ms)}),
                };
                var every_buf: [32]u8 = undefined;
                var shown = try text_utils.encodeTerminalSafe(app.alloc, loop.prompt, max_prompt_display_bytes);
                defer shown.deinit(app.alloc);
                const row = try app.alloc.print("{d}  every {s}  {s}  runs {d}  failures {d}/{d}  {s}", .{
                    loop.id,
                    formatInterval(&every_buf, loop.interval_ms),
                    when,
                    loop.runs,
                    loop.consecutive_failures,
                    loops.pause_after_failures,
                    shown.bytes,
                });
                defer app.alloc.free(row);
                try body.appendSlice(app.alloc, row);
            }
            try app.writeDomainNotice(.{ .topic = "loop", .tone = .neutral, .body = body.items }, true);
        }

        fn stopLoops(app: *App, agent: anytype, target: loops.Target) !void {
            switch (target) {
                .id => |id| {
                    _ = agent.loops.stop(app.alloc, target) catch return writeUnknownLoop(app, id);
                    debug_trace.logf("loop", "event=stopped id={d}", .{id});
                    try writeNotice(app, .neutral, "Stopped loop {d}.", .{id});
                },
                .all => {
                    if (agent.loops.count() == 0) return writeNotice(app, .neutral, "No active loops.", .{});
                    const ids = try idList(app, agent);
                    defer app.alloc.free(ids);
                    const stopped = agent.loops.endAll(app.alloc);
                    debug_trace.logf("loop", "event=stopped ids={s}", .{ids});
                    try writeNotice(app, .neutral, "Stopped {s} {s}.", .{ loopWord(stopped), ids });
                },
            }
        }

        fn resumeLoop(app: *App, agent: anytype, id: u32) !void {
            agent.loops.resumeLoop(id, app_permission_runtime.monotonicMillis()) catch |err| switch (err) {
                error.UnknownLoop => return writeUnknownLoop(app, id),
                error.NotPaused => return writeNotice(app, .neutral, "Loop {d} is not paused.", .{id}),
            };
            debug_trace.logf("loop", "event=resumed id={d}", .{id});
            const loop = for (agent.loops.items.items) |item| {
                if (item.id == id) break item;
            } else unreachable;
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .neutral, "Resumed loop {d}. Next run in {s}.", .{ id, formatInterval(&interval_buf, loop.interval_ms) });
        }

        fn writeUnknownLoop(app: *App, id: u32) !void {
            try writeNotice(app, .warning, "No loop {d}. /loop lists active loops.", .{id});
        }

        fn writeParseError(app: *App, err: loops.ParseError, payload: []const u8) !void {
            const text = std.mem.trim(u8, payload, " \t");
            const token = text[0 .. std.mem.findAny(u8, text, " \t") orelse text.len];
            var shown = try text_utils.encodeTerminalSafe(app.alloc, token, 64);
            defer shown.deinit(app.alloc);
            switch (err) {
                error.IntervalTooShort => try writeNotice(app, .warning, "{s} is shorter than the 1m minimum.", .{shown.bytes}),
                error.IntervalTooLong => try writeNotice(app, .warning, "{s} is longer than the 365d maximum.", .{shown.bytes}),
                error.InvalidInterval => try writeNotice(app, .warning, "{s} is not an interval. Use one such as 5m, 2h, or 1d.", .{shown.bytes}),
                error.MissingPrompt => try writeNotice(app, .warning, "Usage: /loop <interval> <prompt>", .{}),
                error.PromptTooLong => try writeNotice(app, .warning, "A loop prompt holds at most {d} bytes.", .{loops.max_prompt_bytes}),
                error.InvalidId => try writeNotice(app, .warning, "Usage: /loop stop <id|all> or /loop resume <id>", .{}),
            }
        }

        fn writeNotice(app: *App, tone: anytype, comptime fmt: []const u8, args: anytype) !void {
            const body = try app.alloc.print(fmt, args);
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "loop", .tone = tone, .body = body }, true);
        }

        /// The ids of `agent`'s loops as `1, 2, 3`. Caller frees.
        fn idList(app: *App, agent: anytype) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(app.alloc);
            for (agent.loops.items.items, 0..) |loop, index| {
                if (index > 0) try out.appendSlice(app.alloc, ", ");
                var buf: [16]u8 = undefined;
                try out.appendSlice(app.alloc, try std.mem.print(&buf, "{d}", .{loop.id}));
            }
            return out.toOwnedSlice(app.alloc);
        }
    };
}

fn loopWord(count: usize) []const u8 {
    return if (count == 1) "loop" else "loops";
}

/// `interval_ms` in the largest unit that divides it: `1h`, `90s`, `2d`.
fn formatInterval(buf: []u8, interval_ms: u64) []const u8 {
    const units = [_]struct { ms: u64, suffix: u8 }{
        .{ .ms = 24 * 60 * 60_000, .suffix = 'd' },
        .{ .ms = 60 * 60_000, .suffix = 'h' },
        .{ .ms = 60_000, .suffix = 'm' },
    };
    for (units) |unit| {
        if (interval_ms % unit.ms == 0) return std.mem.print(buf, "{d}{c}", .{ interval_ms / unit.ms, unit.suffix }) catch "?";
    }
    return std.mem.print(buf, "{d}s", .{interval_ms / 1_000}) catch "?";
}

/// Time left until a run, rounded down: `30s`, `42m`, `2h 5m`, `3d 4h`.
fn formatRemaining(buf: []u8, remaining_ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(remaining_ms, 0) / 1_000);
    if (secs < 60) return std.mem.print(buf, "{d}s", .{secs}) catch "?";
    if (secs < 60 * 60) return std.mem.print(buf, "{d}m", .{secs / 60}) catch "?";
    if (secs < 24 * 60 * 60) return std.mem.print(buf, "{d}h {d}m", .{ secs / 3600, secs % 3600 / 60 }) catch "?";
    return std.mem.print(buf, "{d}d {d}h", .{ secs / 86_400, secs % 86_400 / 3600 }) catch "?";
}

test "formatInterval picks the largest exact unit" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1h", formatInterval(&buf, 60 * 60_000));
    try std.testing.expectEqualStrings("90m", formatInterval(&buf, 90 * 60_000));
    try std.testing.expectEqualStrings("2d", formatInterval(&buf, 2 * 24 * 60 * 60_000));
    try std.testing.expectEqualStrings("90s", formatInterval(&buf, 90_000));
}

test "formatRemaining rounds down to the largest units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatRemaining(&buf, -5));
    try std.testing.expectEqualStrings("59m", formatRemaining(&buf, 60 * 60_000 - 1));
    try std.testing.expectEqualStrings("2h 5m", formatRemaining(&buf, (2 * 60 + 5) * 60_000));
    try std.testing.expectEqualStrings("3d 4h", formatRemaining(&buf, (3 * 24 + 4) * 60 * 60_000));
}

test "noteTurnFinished reports each failed run, then the pause" {
    const FakeAgent = struct { loops: loops.Loops = .{} };
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        main_agent: FakeAgent = .{},
        notices: std.ArrayList([]u8) = .empty,

        pub fn agent(self: *@This()) *FakeAgent {
            return &self.main_agent;
        }

        pub fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, record: bool) !void {
            _ = record;
            try self.notices.append(self.alloc, try self.alloc.dupe(u8, notice.body));
        }
    };
    var app: FakeApp = .{ .alloc = std.testing.allocator };
    defer {
        for (app.notices.items) |notice| app.alloc.free(notice);
        app.notices.deinit(app.alloc);
        app.main_agent.loops.deinit(app.alloc);
    }
    _ = try app.main_agent.loops.arm(app.alloc, 60_000, "p", 0);
    for (1..loops.pause_after_failures + 1) |turn| {
        app.main_agent.loops.markStarted(&app.main_agent.loops.items.items[0], turn);
        try Runtime(FakeApp).noteTurnFinished(&app, &app.main_agent, .{ .turn_id = turn, .outcome = .failed });
    }
    try std.testing.expectEqual(@as(usize, 3), app.notices.items.len);
    try std.testing.expectEqualStrings("Loop 1 failed (1 of 3 before it pauses).", app.notices.items[0]);
    try std.testing.expectEqualStrings("Loop 1 failed (2 of 3 before it pauses).", app.notices.items[1]);
    try std.testing.expectEqualStrings("Loop 1 paused after 3 failed runs. Fix the cause, then run /loop resume 1.", app.notices.items[2]);
}
