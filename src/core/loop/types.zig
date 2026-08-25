const std = @import("std");

const Allocator = std.mem.Allocator;

/// Maximum number of scheduled tasks allowed per session. Matches the product
/// contract shared with Claude Code and Grok Build.
pub const max_scheduled_tasks: usize = 50;

/// How long a recurring scheduled task lives before auto-expiry. Single source
/// of truth for the TTL: task construction stamps `expires_at`, and the slash
/// command preview and tool description should reference the same constant.
pub const recurring_task_ttl_days: i64 = 7;

/// Maximum prompt length accepted by a loop task.
pub const max_prompt_bytes: usize = 4_000;

/// Length of a scheduled task id (lowercase hex, no hyphens).
const task_id_len: usize = 12;

/// A scheduled loop task. Owns `prompt` and `id`.
pub const ScheduledTask = struct {
    id: []u8,
    interval_secs: u64,
    prompt: []u8,
    recurring: bool,
    created_at_ms: i64,
    last_fired_at_ms: ?i64 = null,
    retry_after_ms: ?i64 = null,
    admission_failure_count: u8 = 0,
    expires_at_ms: ?i64 = null,

    pub fn deinit(self: *ScheduledTask, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.prompt);
        self.* = undefined;
    }

    /// Generate a new 12-char lowercase hex task id from a seed. The caller
    /// supplies entropy and frees the returned bytes with `alloc`.
    fn generate_id(alloc: Allocator, seed: u64) ![]u8 {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var entropy: [6]u8 = undefined;
        random.bytes(&entropy);
        const hex = std.fmt.bytesToHex(entropy, .lower);
        return alloc.dupe(u8, &hex);
    }

    /// Construct a new task. `now_ms` is a monotonic in-process timestamp.
    /// The caller owns the returned task and must call `deinit`.
    pub fn create(
        alloc: Allocator,
        interval_secs: u64,
        prompt: []const u8,
        recurring: bool,
        now_ms: i64,
        seed: u64,
    ) !ScheduledTask {
        const id = try generate_id(alloc, seed);
        errdefer alloc.free(id);

        const prompt_copy = try alloc.dupe(u8, prompt);
        errdefer alloc.free(prompt_copy);

        const ttl_ms: i64 = recurring_task_ttl_days * 24 * 60 * 60 * 1_000;
        const expires_at_ms: ?i64 = if (recurring)
            std.math.add(i64, now_ms, ttl_ms) catch std.math.maxInt(i64)
        else
            null;

        return .{
            .id = id,
            .interval_secs = interval_secs,
            .prompt = prompt_copy,
            .recurring = recurring,
            .created_at_ms = now_ms,
            .expires_at_ms = expires_at_ms,
        };
    }

    /// Next fire time in milliseconds. Computed from `last_fired_at` if present,
    /// otherwise from `created_at`.
    pub fn next_fire_at_ms(self: ScheduledTask) i64 {
        const anchor = self.last_fired_at_ms orelse self.created_at_ms;
        const interval_ms_u64 = std.math.mul(u64, self.interval_secs, 1_000) catch
            std.math.maxInt(u64);
        const interval_ms = std.math.cast(i64, interval_ms_u64) orelse
            std.math.maxInt(i64);
        return std.math.add(i64, anchor, interval_ms) catch std.math.maxInt(i64);
    }

    /// Whether this task has expired (recurring tasks only).
    pub fn is_expired(self: ScheduledTask, now_ms: i64) bool {
        return self.expires_at_ms != null and now_ms > self.expires_at_ms.?;
    }

    /// The next run still to come; `null` for an expired task or a one-shot
    /// that already ran.
    pub fn pending_fire_at_ms(self: ScheduledTask, now_ms: i64) ?i64 {
        if (self.is_expired(now_ms)) return null;
        if (!self.recurring and self.last_fired_at_ms != null) return null;
        const scheduled_at_ms = self.next_fire_at_ms();
        if (self.retry_after_ms) |retry_after_ms| {
            return @max(scheduled_at_ms, retry_after_ms);
        }
        return scheduled_at_ms;
    }
};

test "new recurring task has TTL expiry" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "check deploy", true, 1_000_000, 1);
    defer task.deinit(alloc);

    try std.testing.expect(task.expires_at_ms != null);
    const expiry = task.expires_at_ms.?;
    const diff_days = @divFloor(expiry - task.created_at_ms, 24 * 60 * 60 * 1_000);
    try std.testing.expectEqual(recurring_task_ttl_days, diff_days);
}

test "new one-shot task has no expiry" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "check deploy", false, 1_000_000, 1);
    defer task.deinit(alloc);
    try std.testing.expect(task.expires_at_ms == null);
}

test "next_fire_at_ms uses created_at when never fired" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", true, 1_000_000, 1);
    defer task.deinit(alloc);

    const expected = task.created_at_ms + 300 * 1_000;
    try std.testing.expectEqual(expected, task.next_fire_at_ms());
}

test "next_fire_at_ms uses last_fired_at when present" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", true, 1_000_000, 1);
    defer task.deinit(alloc);

    const fired: i64 = 2_000_000;
    task.last_fired_at_ms = fired;
    const expected = fired + 300 * 1_000;
    try std.testing.expectEqual(expected, task.next_fire_at_ms());
}

test "next_fire_at_ms saturates oversized intervals" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(
        alloc,
        std.math.maxInt(u64),
        "test",
        true,
        std.math.maxInt(i64) - 1,
        1,
    );
    defer task.deinit(alloc);

    try std.testing.expectEqual(std.math.maxInt(i64), task.next_fire_at_ms());
}

test "is_expired returns true when past expiry" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", true, 1_000_000, 1);
    defer task.deinit(alloc);

    task.expires_at_ms = 500_000;
    try std.testing.expect(task.is_expired(600_000));
}

test "is_expired returns false when before expiry" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", true, 1_000_000, 1);
    defer task.deinit(alloc);
    try std.testing.expect(!task.is_expired(900_000));
}

test "is_expired returns false for one-shot" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", false, 1_000_000, 1);
    defer task.deinit(alloc);
    try std.testing.expect(!task.is_expired(999_999_999));
}

test "pending_fire_at_ms returns null for expired recurring task" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", true, 1_000_000, 1);
    defer task.deinit(alloc);

    task.expires_at_ms = 500_000;
    try std.testing.expect(task.pending_fire_at_ms(600_000) == null);
}

test "pending_fire_at_ms returns null for completed one-shot" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", false, 1_000_000, 1);
    defer task.deinit(alloc);

    task.last_fired_at_ms = 1_500_000;
    try std.testing.expect(task.pending_fire_at_ms(2_000_000) == null);
}

test "pending_fire_at_ms returns next fire for pending one-shot" {
    const alloc = std.testing.allocator;
    var task = try ScheduledTask.create(alloc, 300, "test", false, 1_000_000, 1);
    defer task.deinit(alloc);

    const expected = task.created_at_ms + 300 * 1_000;
    try std.testing.expectEqual(expected, task.pending_fire_at_ms(500_000).?);
}

test "generate_id produces 12-char lowercase hex" {
    const alloc = std.testing.allocator;
    const id = try ScheduledTask.generate_id(alloc, 1);
    defer alloc.free(id);

    try std.testing.expectEqual(@as(usize, task_id_len), id.len);
    for (id) |c| {
        try std.testing.expect(
            (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'),
        );
    }
}

test "generate_id produces unique ids" {
    const alloc = std.testing.allocator;
    const id1 = try ScheduledTask.generate_id(alloc, 1);
    defer alloc.free(id1);
    const id2 = try ScheduledTask.generate_id(alloc, 2);
    defer alloc.free(id2);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}
