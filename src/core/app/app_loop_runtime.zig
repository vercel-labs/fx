const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const loop_command = @import("../loop/command.zig");
const loop_interval = @import("../loop/interval.zig");
const loop_scheduler = @import("../loop/scheduler.zig");
const loop_types = @import("../loop/types.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        fn scheduler(app: *App) *loop_scheduler.Scheduler {
            if (app.loops == null) {
                app.loops = loop_scheduler.Scheduler.init(app.alloc);
            }
            return &app.loops.?;
        }

        pub fn reset(app: *App) void {
            scheduler(app).reset();
        }

        pub fn handle_command(app: *App, payload: []const u8) !void {
            const action = loop_command.parse(payload) catch |err| {
                try write_parse_error(app, err);
                return;
            };
            switch (action) {
                .list => try write_list(app),
                .stop => |id| try stop(app, id),
                .create => |create| try schedule(app, create),
            }
        }

        /// Called from the owning app event loop. Prompt admission remains on the
        /// app thread because it snapshots session, context, credentials, and UI
        /// state that background threads must not mutate.
        pub fn tick(app: *App, now_ms: i64) !void {
            const pruned = scheduler(app).prune(now_ms);
            if (pruned > 0) {
                debug_trace.logf("loop", "pruned tasks count={d}", .{pruned});
            }
            if (scheduler(app).count() == 0) return;
            if (comptime @hasField(App, "pacer")) {
                if (app.pacer.hasPending()) return;
            }
            if (!app.worker.is_idle_for_prompt_admission()) return;

            const due = scheduler(app).next_due(now_ms) orelse return;
            const accepted = app.enqueuePrompt(due.prompt) catch |err| {
                try scheduler(app).defer_failed_admission(due, now_ms);
                debug_trace.logf(
                    "loop",
                    "prompt admission failed task_id={s} err={s}",
                    .{ due.id, @errorName(err) },
                );
                const body = try std.fmt.allocPrint(
                    app.alloc,
                    "Scheduled task {s} could not start: {s}",
                    .{ due.id, @errorName(err) },
                );
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{
                    .topic = "loop",
                    .tone = .warning,
                    .body = body,
                }, true);
                return;
            };
            if (!accepted) {
                try scheduler(app).defer_failed_admission(due, now_ms);
                return;
            }
            try scheduler(app).mark_fired(due, now_ms);
            debug_trace.logf("loop", "prompt admitted task_id={s}", .{due.id});
        }

        fn schedule(app: *App, create: loop_command.Create) !void {
            const now_ms = io_mod.monotonic_milli_timestamp();
            var seed: u64 = undefined;
            io_mod.getIo().random(std.mem.asBytes(&seed));
            const id = scheduler(app).schedule(.{
                .interval_secs = create.interval_secs,
                .prompt = create.prompt,
                .recurring = create.recurring,
                .now_ms = now_ms,
                .id_seed = seed,
            }) catch |err| {
                switch (err) {
                    error.TaskLimitReached, error.InvalidPrompt, error.InvalidInterval => {
                        try write_schedule_error(app, err);
                        return;
                    },
                    else => return err,
                }
            };

            const cadence = try loop_interval.interval_to_human_alloc(app.alloc, create.interval_secs);
            defer app.alloc.free(cadence);
            const body = if (create.recurring)
                try std.fmt.allocPrint(
                    app.alloc,
                    "Scheduled task {s} {s} for up to {d} days.",
                    .{ id, cadence, loop_types.recurring_task_ttl_days },
                )
            else
                try std.fmt.allocPrint(
                    app.alloc,
                    "Scheduled task {s} once after the interval.",
                    .{id},
                );
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "loop",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn stop(app: *App, id: []const u8) !void {
            if (!scheduler(app).cancel(id)) {
                var display_id = try text_utils.encodeTerminalSafe(app.alloc, id, 512);
                defer display_id.deinit(app.alloc);
                const body = try std.fmt.allocPrint(app.alloc, "No scheduled task found with id {s}.", .{display_id.bytes});
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{
                    .topic = "loop",
                    .tone = .warning,
                    .body = body,
                }, true);
                return;
            }
            const body = try std.fmt.allocPrint(app.alloc, "Stopped scheduled task {s}.", .{id});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "loop",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn write_list(app: *App) !void {
            if (scheduler(app).count() == 0) {
                try app.writeDomainNotice(.{
                    .topic = "loop",
                    .tone = .neutral,
                    .body = "No scheduled tasks. Use /loop 5m <prompt> to add one.",
                }, true);
                return;
            }

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.writeAll("Scheduled tasks:\n");
            const loop_scheduler_state = scheduler(app);
            for (0..loop_scheduler_state.count()) |index| {
                const task = loop_scheduler_state.task_at(index).?;
                const cadence = try loop_interval.interval_to_human_alloc(app.alloc, task.interval_secs);
                defer app.alloc.free(cadence);
                var display_prompt = try text_utils.encodeTerminalSafe(
                    app.alloc,
                    task.prompt,
                    loop_types.max_prompt_bytes * 12 + 3,
                );
                defer display_prompt.deinit(app.alloc);
                try out.writer.print("{s}  {s}  {s}\n", .{
                    task.id,
                    if (task.recurring) cadence else "once",
                    display_prompt.bytes,
                });
            }
            const body = try out.toOwnedSlice();
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "loop",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn write_schedule_error(app: *App, err: anyerror) !void {
            const body = switch (err) {
                error.TaskLimitReached => try std.fmt.allocPrint(
                    app.alloc,
                    "Scheduled task limit reached ({d}). Stop a task before adding another.",
                    .{loop_types.max_scheduled_tasks},
                ),
                error.InvalidPrompt => try std.fmt.allocPrint(
                    app.alloc,
                    "A scheduled prompt must contain between 1 and {d} bytes.",
                    .{loop_types.max_prompt_bytes},
                ),
                error.InvalidInterval => try app.alloc.dupe(u8, "Use an interval such as 5m, 2h, or 1d."),
                else => return err,
            };
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "loop",
                .tone = .warning,
                .body = body,
            }, true);
        }

        fn write_parse_error(app: *App, err: loop_command.ParseError) !void {
            if (err == error.PromptTooLong) {
                const body = try std.fmt.allocPrint(
                    app.alloc,
                    "Scheduled prompts are limited to {d} bytes.",
                    .{loop_types.max_prompt_bytes},
                );
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{
                    .topic = "loop",
                    .tone = .warning,
                    .body = body,
                }, true);
                return;
            }
            const body = switch (err) {
                error.InvalidInterval => "Invalid interval. Use a value such as 5m, 2h, or 1d.",
                error.MissingPrompt => "Usage: /loop [once] [5m|2h|1d] <prompt>",
                error.MissingTaskId => "Usage: /loop stop <task-id>",
                error.PromptTooLong => unreachable,
            };
            try app.writeDomainNotice(.{
                .topic = "loop",
                .tone = .warning,
                .body = body,
            }, true);
        }
    };
}

const TestAdmission = enum { accept, reject, fail };

const TestPacer = struct {
    pending: bool = false,

    fn hasPending(self: *const TestPacer) bool {
        return self.pending;
    }
};

const TestWorker = struct {
    processing: bool = false,
    queued: usize = 0,
    idle_check_count: usize = 0,

    fn is_idle_for_prompt_admission(self: *TestWorker) bool {
        self.idle_check_count += 1;
        return !self.processing and self.queued == 0;
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    loops: ?loop_scheduler.Scheduler,
    worker: TestWorker = .{},
    pacer: TestPacer = .{},
    admission: TestAdmission = .accept,
    admission_count: usize = 0,
    notice_count: usize = 0,

    fn init(alloc: std.mem.Allocator) TestApp {
        return .{
            .alloc = alloc,
            .loops = loop_scheduler.Scheduler.init(alloc),
        };
    }

    fn deinit(self: *TestApp) void {
        if (self.loops) |*loops| loops.deinit();
    }

    fn enqueuePrompt(self: *TestApp, _: []const u8) !bool {
        self.admission_count += 1;
        return switch (self.admission) {
            .accept => true,
            .reject => false,
            .fail => error.TestAdmissionFailed,
        };
    }

    fn writeDomainNotice(self: *TestApp, _: anytype, _: bool) !void {
        self.notice_count += 1;
    }
};

fn schedule_test_task(app: *TestApp, recurring: bool) !void {
    _ = try app.loops.?.schedule(.{
        .interval_secs = 60,
        .prompt = "scheduled prompt",
        .recurring = recurring,
        .now_ms = 0,
        .id_seed = 1,
    });
}

test "tick skips worker locking when no tasks exist" {
    var app = TestApp.init(std.testing.allocator);
    defer app.deinit();

    try Runtime(TestApp).tick(&app, 60_000);
    try std.testing.expectEqual(@as(usize, 0), app.worker.idle_check_count);
}

test "tick waits for paced output before admitting a due task" {
    var app = TestApp.init(std.testing.allocator);
    defer app.deinit();
    app.pacer.pending = true;
    try schedule_test_task(&app, false);

    try Runtime(TestApp).tick(&app, 60_000);
    try std.testing.expectEqual(@as(usize, 0), app.admission_count);
    app.pacer.pending = false;
    try Runtime(TestApp).tick(&app, 60_000);
    try std.testing.expectEqual(@as(usize, 1), app.admission_count);
}

test "failed admission defers a one-shot instead of consuming it" {
    var app = TestApp.init(std.testing.allocator);
    defer app.deinit();
    app.admission = .fail;
    try schedule_test_task(&app, false);

    try Runtime(TestApp).tick(&app, 60_000);
    try std.testing.expectEqual(@as(usize, 1), app.admission_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqual(@as(usize, 1), app.loops.?.count());
    try std.testing.expect(app.loops.?.task_at(0) != null);

    try Runtime(TestApp).tick(&app, 64_999);
    try std.testing.expectEqual(@as(usize, 1), app.admission_count);
    try Runtime(TestApp).tick(&app, 65_000);
    try std.testing.expectEqual(@as(usize, 2), app.admission_count);
}

test "rejected admission retries and successful one-shot is pruned" {
    var app = TestApp.init(std.testing.allocator);
    defer app.deinit();
    app.admission = .reject;
    try schedule_test_task(&app, false);

    try Runtime(TestApp).tick(&app, 60_000);
    try std.testing.expectEqual(@as(usize, 1), app.loops.?.count());
    app.admission = .accept;
    try Runtime(TestApp).tick(&app, 65_000);
    try Runtime(TestApp).tick(&app, 65_001);
    try std.testing.expectEqual(@as(usize, 0), app.loops.?.count());
}

test "reset clears session-owned tasks" {
    var app = TestApp.init(std.testing.allocator);
    defer app.deinit();
    try schedule_test_task(&app, true);

    Runtime(TestApp).reset(&app);
    try std.testing.expectEqual(@as(usize, 0), app.loops.?.count());
}
