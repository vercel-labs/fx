const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const ScheduleOptions = struct {
    interval_secs: u64,
    prompt: []const u8,
    recurring: bool = true,
    now_ms: i64,
    id_seed: u64,
};

/// Borrowed task selected for execution. The scheduler retains ownership of all
/// fields. Call `mark_fired` only after prompt admission succeeds.
pub const DueTask = struct {
    index: usize,
    id: []const u8,
    prompt: []const u8,
};

pub const TaskView = struct {
    id: []const u8,
    interval_secs: u64,
    prompt: []const u8,
    recurring: bool,
};

const admission_retry_base_ms: i64 = 5_000;
const admission_retry_max_ms: i64 = 5 * 60 * 1_000;

/// Session-owned scheduler state. It deliberately has no worker thread: the app
/// event loop calls `next_due` and performs prompt admission on its owning thread.
pub const Scheduler = struct {
    alloc: Allocator,
    tasks: std.ArrayList(types.ScheduledTask) = .empty,

    pub fn init(alloc: Allocator) Scheduler {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.tasks.items) |*task| task.deinit(self.alloc);
        self.tasks.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn reset(self: *Scheduler) void {
        for (self.tasks.items) |*task| task.deinit(self.alloc);
        self.tasks.clearRetainingCapacity();
    }

    pub fn count(self: *const Scheduler) usize {
        return self.tasks.items.len;
    }

    pub fn task_at(self: *const Scheduler, index: usize) ?TaskView {
        if (index >= self.tasks.items.len) return null;
        const task = self.tasks.items[index];
        return .{
            .id = task.id,
            .interval_secs = task.interval_secs,
            .prompt = task.prompt,
            .recurring = task.recurring,
        };
    }

    /// Adds a task and returns its borrowed ID. The slice remains valid until
    /// that task is canceled, pruned, reset, or the scheduler is deinitialized.
    pub fn schedule(self: *Scheduler, options: ScheduleOptions) ![]const u8 {
        const prompt = std.mem.trim(u8, options.prompt, " \t\r\n");
        if (prompt.len == 0 or prompt.len > types.max_prompt_bytes) {
            return error.InvalidPrompt;
        }
        if (options.interval_secs == 0) return error.InvalidInterval;
        const recurring_ttl_secs: u64 = @intCast(types.recurring_task_ttl_days * 24 * 60 * 60);
        if (options.recurring and options.interval_secs > recurring_ttl_secs) {
            return error.InvalidInterval;
        }
        if (self.tasks.items.len >= types.max_scheduled_tasks) {
            return error.TaskLimitReached;
        }

        var attempt: usize = 0;
        while (attempt <= self.tasks.items.len) : (attempt += 1) {
            const seed = options.id_seed +% @as(u64, @intCast(attempt));
            var task = try types.ScheduledTask.create(
                self.alloc,
                options.interval_secs,
                prompt,
                options.recurring,
                options.now_ms,
                seed,
            );
            if (self.find_index(task.id) != null) {
                task.deinit(self.alloc);
                continue;
            }
            errdefer task.deinit(self.alloc);
            try self.tasks.append(self.alloc, task);
            return self.tasks.items[self.tasks.items.len - 1].id;
        }
        return error.TaskIdUnavailable;
    }

    pub fn cancel(self: *Scheduler, id: []const u8) bool {
        const index = self.find_index(id) orelse return false;
        var removed = self.tasks.orderedRemove(index);
        removed.deinit(self.alloc);
        return true;
    }

    fn find(self: *Scheduler, id: []const u8) ?*types.ScheduledTask {
        const index = self.find_index(id) orelse return null;
        return &self.tasks.items[index];
    }

    /// Removes expired recurring tasks and completed one-shot tasks. Returns the
    /// number removed.
    pub fn prune(self: *Scheduler, now_ms: i64) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.tasks.items.len) {
            const task = self.tasks.items[index];
            const completed_one_shot = !task.recurring and task.last_fired_at_ms != null;
            if (!task.is_expired(now_ms) and !completed_one_shot) {
                index += 1;
                continue;
            }
            var discarded = self.tasks.orderedRemove(index);
            discarded.deinit(self.alloc);
            removed += 1;
        }
        return removed;
    }

    /// Returns the oldest due task. The caller should only ask while prompt
    /// admission is idle; this provides global no-overlap semantics and prevents
    /// recurring prompts from accumulating behind active work.
    pub fn next_due(self: *Scheduler, now_ms: i64) ?DueTask {
        var selected_index: ?usize = null;
        var selected_fire_ms: i64 = std.math.maxInt(i64);
        for (self.tasks.items, 0..) |task, index| {
            const fire_ms = task.pending_fire_at_ms(now_ms) orelse continue;
            if (fire_ms > now_ms or fire_ms >= selected_fire_ms) continue;
            selected_index = index;
            selected_fire_ms = fire_ms;
        }
        const index = selected_index orelse return null;
        const task = self.tasks.items[index];
        return .{
            .index = index,
            .id = task.id,
            .prompt = task.prompt,
        };
    }

    /// Records successful prompt admission. One-shot tasks remain until the next
    /// prune so callers can persist the terminal state atomically first.
    pub fn mark_fired(self: *Scheduler, due: DueTask, now_ms: i64) !void {
        const task = try self.due_task(due);
        task.last_fired_at_ms = now_ms;
        task.retry_after_ms = null;
        task.admission_failure_count = 0;
    }

    /// Preserve the pending run after admission fails while preventing retries on
    /// every UI frame.
    pub fn defer_failed_admission(self: *Scheduler, due: DueTask, now_ms: i64) !void {
        const task = try self.due_task(due);
        const shift: u6 = @intCast(@min(task.admission_failure_count, 6));
        const retry_delay_ms = @min(admission_retry_base_ms << shift, admission_retry_max_ms);
        task.retry_after_ms = std.math.add(i64, now_ms, retry_delay_ms) catch
            std.math.maxInt(i64);
        task.admission_failure_count +|= 1;
    }

    fn due_task(self: *Scheduler, due: DueTask) !*types.ScheduledTask {
        if (due.index >= self.tasks.items.len) return error.TaskNotFound;
        const task = &self.tasks.items[due.index];
        if (!std.mem.eql(u8, task.id, due.id)) return error.TaskNotFound;
        return task;
    }

    fn find_index(self: *const Scheduler, id: []const u8) ?usize {
        for (self.tasks.items, 0..) |task, index| {
            if (std.mem.eql(u8, task.id, id)) return index;
        }
        return null;
    }
};

fn schedule_for_test(scheduler: *Scheduler, interval_secs: u64, prompt: []const u8, recurring: bool, now_ms: i64, seed: u64) ![]const u8 {
    return scheduler.schedule(.{
        .interval_secs = interval_secs,
        .prompt = prompt,
        .recurring = recurring,
        .now_ms = now_ms,
        .id_seed = seed,
    });
}

test "schedule validates prompt and limit" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    try std.testing.expectError(error.InvalidPrompt, schedule_for_test(&scheduler, 60, " ", true, 0, 1));
    try std.testing.expectError(error.InvalidInterval, schedule_for_test(&scheduler, 0, "test", true, 0, 1));

    for (0..types.max_scheduled_tasks) |index| {
        _ = try schedule_for_test(&scheduler, 60, "test", true, 0, @intCast(index + 1));
    }
    try std.testing.expectError(error.TaskLimitReached, schedule_for_test(&scheduler, 60, "overflow", true, 0, 999));
}

test "recurring interval may fire at ttl boundary but cannot exceed ttl" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const ttl_secs: u64 = @intCast(types.recurring_task_ttl_days * 24 * 60 * 60);
    _ = try schedule_for_test(&scheduler, ttl_secs, "boundary", true, 0, 1);
    try std.testing.expect(scheduler.next_due(@intCast(ttl_secs * 1_000)) != null);
    try std.testing.expectError(
        error.InvalidInterval,
        schedule_for_test(&scheduler, ttl_secs + 1, "too late", true, 0, 2),
    );
}

test "next_due selects oldest task and mark_fired advances recurring cadence" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = try schedule_for_test(&scheduler, 120, "later", true, 1_000, 1);
    _ = try schedule_for_test(&scheduler, 60, "first", true, 1_000, 2);

    try std.testing.expect(scheduler.next_due(60_999) == null);
    const due = scheduler.next_due(61_000).?;
    try std.testing.expectEqualStrings("first", due.prompt);
    try scheduler.mark_fired(due, 61_000);
    try std.testing.expect(scheduler.next_due(61_000) == null);
    try std.testing.expectEqual(@as(i64, 121_000), scheduler.find(due.id).?.next_fire_at_ms());
}

test "failed admission defers without consuming the pending run" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = try schedule_for_test(&scheduler, 60, "retry me", false, 0, 1);
    const due = scheduler.next_due(60_000).?;
    try scheduler.defer_failed_admission(due, 60_000);

    try std.testing.expect(scheduler.next_due(64_999) == null);
    const retry = scheduler.next_due(65_000).?;
    try std.testing.expectEqualStrings(due.id, retry.id);
    try std.testing.expect(scheduler.find(due.id).?.last_fired_at_ms == null);

    try scheduler.defer_failed_admission(retry, 65_000);
    try std.testing.expect(scheduler.next_due(74_999) == null);
    try std.testing.expect(scheduler.next_due(75_000) != null);
}

test "schedule resolves duplicate id seeds" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const first = try std.testing.allocator.dupe(u8, try schedule_for_test(&scheduler, 60, "first", true, 0, 1));
    defer std.testing.allocator.free(first);
    const second = try schedule_for_test(&scheduler, 60, "second", true, 0, 1);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "task view is read only and reset clears session tasks" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = try schedule_for_test(&scheduler, 60, "inspect me", true, 0, 1);
    const view = scheduler.task_at(0).?;
    try std.testing.expectEqualStrings("inspect me", view.prompt);
    try std.testing.expect(scheduler.task_at(1) == null);

    scheduler.reset();
    try std.testing.expectEqual(@as(usize, 0), scheduler.count());
}

test "one-shot is removed after firing and prune" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    _ = try schedule_for_test(&scheduler, 60, "once", false, 0, 1);
    const due = scheduler.next_due(60_000).?;
    try scheduler.mark_fired(due, 60_000);
    try std.testing.expectEqual(@as(usize, 1), scheduler.prune(60_000));
    try std.testing.expectEqual(@as(usize, 0), scheduler.count());
}

test "prune removes expired recurring tasks" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const id = try schedule_for_test(&scheduler, 60, "expire", true, 0, 1);
    scheduler.find(id).?.expires_at_ms = 100;
    try std.testing.expectEqual(@as(usize, 0), scheduler.prune(100));
    try std.testing.expectEqual(@as(usize, 1), scheduler.prune(101));
}

test "cancel removes only matching task" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const first = try std.testing.allocator.dupe(u8, try schedule_for_test(&scheduler, 60, "first", true, 0, 1));
    defer std.testing.allocator.free(first);
    _ = try schedule_for_test(&scheduler, 60, "second", true, 0, 2);

    try std.testing.expect(scheduler.cancel(first));
    try std.testing.expect(!scheduler.cancel(first));
    try std.testing.expectEqual(@as(usize, 1), scheduler.count());
}
