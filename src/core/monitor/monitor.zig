//! Monitors: commands an agent starts once and hears from only when they
//! print. A monitor is a managed shell command (`managed_execution.zig`) the
//! agent started with the `monitor` tool. This module owns which commands are
//! monitors, what each one last told the agent, and the events' text and
//! pace (`event.zig`). The app's loop reads the commands' output and posts
//! the events (`src/core/app/app_monitor_runtime.zig`).

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const event_mod = @import("event.zig");

const Allocator = std.mem.Allocator;

pub const event = event_mod;
pub const saved = @import("saved.zig");
pub const output_log = @import("output_log.zig");

/// The most monitors one agent runs at once.
pub const max_monitors: usize = 16;

/// Messages from monitors the agent's queue holds at once. A monitor whose
/// agent has more waiting keeps its events itself (`pushHeld`), so a blocked
/// agent never has a queue of them to read later.
pub const max_queued_events: usize = 1;

/// The output of a monitor's command that the loop has not read yet, at most.
/// The loop reads about once a second, and a read can come two seconds late
/// near an event, so this bounds how fast a command can print and still reach
/// the file whole. A burst past it keeps its first and last halves.
pub const max_unread_output_bytes: usize = 1024 * 1024;

/// What a monitor keeps of its command's output between two events. The file
/// holds all of it (`output_log`), so what does not fit here only misses the
/// next event's words.
pub const max_pending_bytes: usize = 64 * 1024;

/// The least time between two events of one monitor. `FX_TEST_MONITOR_GAP_MS`
/// shortens it, to 100 ms at least, so a test need not wait ten seconds.
pub fn gapMs() i64 {
    const text = io_mod.getenv("FX_TEST_MONITOR_GAP_MS") orelse return event_mod.min_gap_ms;
    const ms = std.fmt.parseInt(i64, text, 10) catch return event_mod.min_gap_ms;
    return if (ms < 100) event_mod.min_gap_ms else ms;
}

/// How often the loop looks at its monitors: once a second, or as often as
/// the shortened event gap when a test shortens it.
pub fn pollGapMs() i64 {
    return @min(event_mod.poll_gap_ms, gapMs());
}

/// One running monitor. Strings are owned by the registry.
pub const Item = struct {
    /// The managed command's id, such as `shell-3`. It is also the id the
    /// agent stops the monitor with.
    id: []u8,
    label: []u8,
    command: []u8,
    last_event_ms: ?i64 = null,
    last_hash: ?u64 = null,
    /// Events the agent has not taken yet, oldest first, at most
    /// `event.max_held`.
    held: std.ArrayList(event_mod.Held) = .empty,
    /// Events dropped from `held` to make room for newer ones.
    dropped: u64 = 0,
    /// Output read since the last event, up to `max_pending_bytes`, for the
    /// next event to carry.
    pending: std.ArrayList(u8) = .empty,
    /// The command ended and its last event is in `held` or was posted.
    ended: bool = false,
};

/// A copy of what the loop needs about one monitor.
pub const Seen = struct {
    id: []u8,
    label: []u8,
    last_event_ms: ?i64,
    last_hash: ?u64,
    ended: bool,

    pub fn deinit(self: Seen, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.label);
    }
};

/// One agent's monitors. The tool adds and removes on the agent's worker
/// thread; the main loop reads, marks, and removes. Every call takes the
/// registry's lock and releases it before returning.
pub const Registry = struct {
    alloc: Allocator = std.heap.c_allocator,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Item) = .empty,
    last_poll_ms: i64 = 0,
    /// Counts each add and remove, so the loop saves the record only when it
    /// changed (`takeChange`).
    version: u64 = 0,
    saved_version: u64 = 0,
    /// What the agent reads after a restart that ended its monitors, until the
    /// loop posts it. Owned.
    restart_note: ?[]u8 = null,
    last_note_ms: i64 = 0,
    last_save_ms: i64 = 0,
    /// The session whose monitors these are, so a switch to another session
    /// (`/new`, `/resume`) is noticed (`followSession`). Owned.
    session: ?[]u8 = null,

    pub const AddError = error{ TooManyMonitors, OutOfMemory };

    pub fn deinit(self: *Registry) void {
        for (self.items.items) |item| freeItem(self.alloc, item);
        self.items.deinit(self.alloc);
        if (self.restart_note) |text| self.alloc.free(text);
        if (self.session) |id| self.alloc.free(id);
    }

    pub fn add(self: *Registry, id: []const u8, label: []const u8, command: []const u8) AddError!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len >= max_monitors) return error.TooManyMonitors;
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id);
        const owned_label = try self.alloc.dupe(u8, label);
        errdefer self.alloc.free(owned_label);
        const owned_command = try self.alloc.dupe(u8, command);
        errdefer self.alloc.free(owned_command);
        try self.items.append(self.alloc, .{ .id = owned_id, .label = owned_label, .command = owned_command });
        self.version += 1;
    }

    /// Takes `id` out. Returns false when it is not a monitor.
    pub fn remove(self: *Registry, id: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            freeItem(self.alloc, self.items.orderedRemove(index));
            self.version += 1;
            return true;
        }
        return false;
    }

    /// Takes `id` out and gives its words back, so a stop that fails can put
    /// the monitor back with `restore`. Caller frees them with `freeCopy`.
    pub fn removeKeeping(self: *Registry, id: []const u8) ?saved.Entry {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            const label = self.alloc.dupe(u8, item.label) catch return null;
            const command = self.alloc.dupe(u8, item.command) catch {
                self.alloc.free(label);
                return null;
            };
            freeItem(self.alloc, self.items.orderedRemove(index));
            self.version += 1;
            return .{ .label = label, .command = command };
        }
        return null;
    }

    /// Puts a monitor `removeKeeping` took back, and frees the copy.
    pub fn restore(self: *Registry, id: []const u8, kept: saved.Entry) void {
        defer self.freeCopy(kept);
        self.add(id, kept.label, kept.command) catch |err| {
            debug_trace.logf("monitor", "event=restore_failed id={s} err={s}", .{ id, @errorName(err) });
        };
    }

    pub fn freeCopy(self: *Registry, kept: saved.Entry) void {
        self.alloc.free(kept.label);
        self.alloc.free(kept.command);
    }

    pub fn contains(self: *Registry, id: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |item| if (std.mem.eql(u8, item.id, id)) return true;
        return false;
    }

    pub fn count(self: *Registry) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.items.items.len;
    }

    /// Copies every monitor's loop facts. Caller frees each with `deinit`
    /// and the slice with `alloc`.
    pub fn seen(self: *Registry, alloc: Allocator) Allocator.Error![]Seen {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(Seen) = .empty;
        errdefer {
            for (out.items) |copy| copy.deinit(alloc);
            out.deinit(alloc);
        }
        for (self.items.items) |item| {
            const id = try alloc.dupe(u8, item.id);
            errdefer alloc.free(id);
            const label = try alloc.dupe(u8, item.label);
            errdefer alloc.free(label);
            try out.append(alloc, .{ .id = id, .label = label, .last_event_ms = item.last_event_ms, .last_hash = item.last_hash, .ended = item.ended });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Keeps an event `id` could not post. Past `event.max_held` the oldest
    /// goes and is counted. Returns how many events are dropped since the
    /// last post, or null when `id` is not listed.
    pub fn pushHeld(self: *Registry, id: []const u8, text: []const u8, at_ms: i64, command_ended: bool) Allocator.Error!?u64 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            const owned = try self.alloc.dupe(u8, text);
            errdefer self.alloc.free(owned);
            try item.held.append(self.alloc, .{ .text = owned, .at_ms = at_ms });
            if (item.held.items.len > event_mod.max_held) {
                self.alloc.free(item.held.items[0].text);
                _ = item.held.orderedRemove(0);
                item.dropped += 1;
            }
            if (command_ended) item.ended = true;
            return item.dropped;
        }
        return null;
    }

    /// Keeps `bytes` the command printed since the last event, up to
    /// `max_pending_bytes`. Returns false when `id` is not listed.
    pub fn appendPending(self: *Registry, id: []const u8, bytes: []const u8) Allocator.Error!bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            const room = max_pending_bytes -| item.pending.items.len;
            try item.pending.appendSlice(self.alloc, bytes[0..@min(bytes.len, room)]);
            return true;
        }
        return false;
    }

    /// Whether `id` keeps output for its next event.
    pub fn hasPending(self: *Registry, id: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.id, id)) return item.pending.items.len > 0;
        }
        return false;
    }

    /// A copy of `id`'s pending output, or null when it has none. Caller
    /// frees it. The output stays until `clearPending`, so an event that
    /// fails to form loses none of it.
    pub fn copyPending(self: *Registry, alloc: Allocator, id: []const u8) Allocator.Error!?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (item.pending.items.len == 0) return null;
            return try alloc.dupe(u8, item.pending.items);
        }
        return null;
    }

    /// Forgets `id`'s pending output, once an event has carried it.
    pub fn clearPending(self: *Registry, id: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item.pending.clearRetainingCapacity();
        }
    }

    /// Whether `id` holds events.
    pub fn hasHeld(self: *Registry, id: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.id, id)) return item.held.items.len > 0;
        }
        return false;
    }

    /// Moves `id`'s held events out. Free with `freeBatch`, or give back with
    /// `restoreHeld` when the post fails.
    pub fn takeHeld(self: *Registry, id: []const u8) Allocator.Error!?Batch {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (item.held.items.len == 0) return null;
            const events = try item.held.toOwnedSlice(self.alloc);
            const batch: Batch = .{ .events = events, .dropped = item.dropped, .ended = item.ended };
            item.dropped = 0;
            return batch;
        }
        return null;
    }

    /// Puts a batch a failed post did not deliver back in front of what was
    /// held since. The oldest events past the cap are dropped and counted.
    pub fn restoreHeld(self: *Registry, id: []const u8, batch: Batch) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            var merged: std.ArrayList(event_mod.Held) = .empty;
            merged.appendSlice(self.alloc, batch.events) catch return self.dropBatch(batch, item);
            merged.appendSlice(self.alloc, item.held.items) catch {
                merged.deinit(self.alloc);
                return self.dropBatch(batch, item);
            };
            self.alloc.free(batch.events);
            item.held.deinit(self.alloc);
            item.held = merged;
            item.dropped += batch.dropped;
            while (item.held.items.len > event_mod.max_held) {
                self.alloc.free(item.held.items[0].text);
                _ = item.held.orderedRemove(0);
                item.dropped += 1;
            }
            return;
        }
        freeBatch(self.alloc, batch);
    }

    /// Out of memory while giving a batch back: its events are dropped, and
    /// the count says so.
    fn dropBatch(self: *Registry, batch: Batch, item: *Item) void {
        item.dropped += batch.dropped + batch.events.len;
        freeBatch(self.alloc, batch);
    }

    /// Records that `id` told the agent something at `now_ms`.
    pub fn markEvent(self: *Registry, id: []const u8, now_ms: i64, hash: u64) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            item.last_event_ms = now_ms;
            item.last_hash = hash;
            return;
        }
    }

    /// The monitors to save when they changed since the last save, copied, or
    /// null when the record is current. An empty slice means the record goes.
    /// Free each entry's strings and the slice with `alloc`.
    pub fn takeChange(self: *Registry, alloc: Allocator) Allocator.Error!?[]saved.Entry {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.version == self.saved_version) return null;
        var out: std.ArrayList(saved.Entry) = .empty;
        errdefer {
            freeEntries(alloc, out.items);
            out.deinit(alloc);
        }
        for (self.items.items) |item| {
            const label = try alloc.dupe(u8, item.label);
            errdefer alloc.free(label);
            const command = try alloc.dupe(u8, item.command);
            errdefer alloc.free(command);
            try out.append(alloc, .{ .label = label, .command = command });
        }
        self.saved_version = self.version;
        return try out.toOwnedSlice(alloc);
    }

    /// Whether the record is out of date, read without copying anything.
    pub fn hasUnsaved(self: *Registry) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.version != self.saved_version;
    }

    /// Keeps `text` for the loop to post, and frees the one it replaces.
    pub fn setRestartNote(self: *Registry, text: []u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.restart_note) |old| self.alloc.free(old);
        self.restart_note = text;
    }

    /// The restart note, once, and at most one try a poll gap, so a post that
    /// keeps failing does not spin the loop. Caller frees it with `alloc`.
    pub fn takeRestartNote(self: *Registry, now_ms: i64) ?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const text = self.restart_note orelse return null;
        if (!event_mod.pollDue(now_ms, self.last_note_ms, event_mod.poll_gap_ms)) return null;
        self.last_note_ms = now_ms;
        self.restart_note = null;
        return text;
    }

    /// Whether a save may be tried now: at most once a poll gap, so a record
    /// that cannot be written is retried slowly.
    pub fn saveDue(self: *Registry, now_ms: i64) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!event_mod.pollDue(now_ms, self.last_save_ms, event_mod.poll_gap_ms)) return false;
        self.last_save_ms = now_ms;
        return true;
    }

    /// A save failed: the record is out of date again.
    pub fn markUnsaved(self: *Registry) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.saved_version = self.version -% 1;
    }

    /// Monitors of a session that is no longer open. Free with `freeDeparted`.
    pub const Departed = struct { session: []u8, ids: [][]u8 };

    pub fn freeDeparted(self: *Registry, departed: Departed) void {
        self.alloc.free(departed.session);
        for (departed.ids) |id| self.alloc.free(id);
        self.alloc.free(departed.ids);
    }

    /// Records `id` as the open session. When monitors of another session
    /// are still listed, takes them all out and gives them back, so the loop
    /// stops them: they belong to a conversation that is gone.
    pub fn followSession(self: *Registry, id: ?[]const u8) Allocator.Error!?Departed {
        const open = id orelse return null;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.session) |known| if (std.mem.eql(u8, known, open)) return null;
        const replacement = try self.alloc.dupe(u8, open);
        errdefer self.alloc.free(replacement);
        var departed: ?Departed = null;
        if (self.session != null and self.items.items.len > 0) {
            const old = try self.alloc.dupe(u8, self.session.?);
            errdefer self.alloc.free(old);
            const ids = try self.alloc.alloc([]u8, self.items.items.len);
            var copied: usize = 0;
            errdefer {
                for (ids[0..copied]) |copy| self.alloc.free(copy);
                self.alloc.free(ids);
            }
            for (self.items.items) |item| {
                ids[copied] = try self.alloc.dupe(u8, item.id);
                copied += 1;
            }
            for (self.items.items) |item| freeItem(self.alloc, item);
            self.items.clearRetainingCapacity();
            self.version += 1;
            departed = .{ .session = old, .ids = ids };
        }
        if (self.session) |old| self.alloc.free(old);
        self.session = replacement;
        return departed;
    }

    /// Whether the loop looks now, and records the look when it does.
    pub fn takePoll(self: *Registry, now_ms: i64) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) return false;
        if (!event_mod.pollDue(now_ms, self.last_poll_ms, pollGapMs())) return false;
        self.last_poll_ms = now_ms;
        return true;
    }

    /// The `list` answer: one line per monitor, or a sentence when there is
    /// none. Caller owns the result.
    pub fn listText(self: *Registry, alloc: Allocator) Allocator.Error![]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) return alloc.dupe(u8, "No monitors are running.");
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        for (self.items.items) |item| {
            out.writer.print("{s}\t{s}\t{s}\n", .{ item.id, item.label, item.command }) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }
};

/// Frees the strings of entries `takeChange` copied, not the slice.
pub fn freeEntries(alloc: Allocator, entries: []const saved.Entry) void {
    for (entries) |entry| {
        alloc.free(entry.label);
        alloc.free(entry.command);
    }
}

fn freeItem(alloc: Allocator, item: Item) void {
    alloc.free(item.id);
    alloc.free(item.label);
    alloc.free(item.command);
    var held = item.held;
    for (held.items) |entry| alloc.free(entry.text);
    held.deinit(alloc);
    var pending = item.pending;
    pending.deinit(alloc);
}

/// Events a monitor held, moved out for one post.
pub const Batch = struct {
    events: []event_mod.Held,
    dropped: u64,
    /// The command ended, so this batch holds its last event.
    ended: bool,
};

pub fn freeBatch(alloc: Allocator, batch: Batch) void {
    for (batch.events) |entry| alloc.free(entry.text);
    alloc.free(batch.events);
}

test "a registry adds, finds, marks, and removes a monitor" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "gh pr checks 1 --watch");
    try std.testing.expect(registry.contains("shell-1"));
    try std.testing.expect(!registry.contains("shell-2"));
    registry.markEvent("shell-1", 5_000, 7);
    const seen = try registry.seen(std.testing.allocator);
    defer {
        for (seen) |copy| copy.deinit(std.testing.allocator);
        std.testing.allocator.free(seen);
    }
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(@as(?i64, 5_000), seen[0].last_event_ms);
    try std.testing.expectEqual(@as(?u64, 7), seen[0].last_hash);
    try std.testing.expect(registry.remove("shell-1"));
    try std.testing.expect(!registry.remove("shell-1"));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "the record is taken only when the monitors changed" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try std.testing.expect((try registry.takeChange(std.testing.allocator)) == null);
    try registry.add("shell-1", "ci", "true");
    const first = (try registry.takeChange(std.testing.allocator)).?;
    defer std.testing.allocator.free(first);
    defer freeEntries(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("ci", first[0].label);
    try std.testing.expect((try registry.takeChange(std.testing.allocator)) == null);
    // Marking an event is no change to the record.
    registry.markEvent("shell-1", 1, 1);
    try std.testing.expect((try registry.takeChange(std.testing.allocator)) == null);
    try std.testing.expect(registry.remove("shell-1"));
    const none = (try registry.takeChange(std.testing.allocator)).?;
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "the restart note is kept once and replaced by a newer one" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try std.testing.expect(registry.takeRestartNote(10_000) == null);
    registry.setRestartNote(try std.testing.allocator.dupe(u8, "one"));
    registry.setRestartNote(try std.testing.allocator.dupe(u8, "two"));
    const text = registry.takeRestartNote(10_000).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("two", text);
    try std.testing.expect(registry.takeRestartNote(20_000) == null);
}

test "a monitor taken out for a stop goes back when the stop fails" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "gh pr checks 1 --watch");
    const kept = registry.removeKeeping("shell-1").?;
    try std.testing.expect(!registry.contains("shell-1"));
    try std.testing.expect(registry.removeKeeping("shell-1") == null);
    registry.restore("shell-1", kept);
    try std.testing.expect(registry.contains("shell-1"));
    const text = try registry.listText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("shell-1\tci\tgh pr checks 1 --watch\n", text);
}

test "a note that was put back waits a poll gap before the next try" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    registry.setRestartNote(try std.testing.allocator.dupe(u8, "note"));
    const first = registry.takeRestartNote(10_000).?;
    registry.setRestartNote(first);
    try std.testing.expect(registry.takeRestartNote(10_500) == null);
    const again = registry.takeRestartNote(11_000).?;
    std.testing.allocator.free(again);
}

test "a save that failed is tried again, at most once a gap" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "m", "true");
    try std.testing.expect(registry.saveDue(10_000));
    const taken = (try registry.takeChange(std.testing.allocator)).?;
    defer std.testing.allocator.free(taken);
    defer freeEntries(std.testing.allocator, taken);
    try std.testing.expect(!registry.hasUnsaved());
    registry.markUnsaved();
    try std.testing.expect(registry.hasUnsaved());
    try std.testing.expect(!registry.saveDue(10_200));
    try std.testing.expect(registry.saveDue(11_000));
}

test "a switch to another session hands back the monitors of the old one" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try std.testing.expect((try registry.followSession(null)) == null);
    try std.testing.expect((try registry.followSession("one")) == null);
    try registry.add("shell-1", "ci", "true");
    try registry.add("shell-2", "log", "true");
    try std.testing.expect((try registry.followSession("one")) == null);
    const departed = (try registry.followSession("two")).?;
    defer registry.freeDeparted(departed);
    try std.testing.expectEqualStrings("one", departed.session);
    try std.testing.expectEqual(@as(usize, 2), departed.ids.len);
    try std.testing.expectEqualStrings("shell-1", departed.ids[0]);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    // With none listed, a switch hands back nothing.
    try std.testing.expect((try registry.followSession("three")) == null);
}

test "a monitor keeps the output between two events, up to its cap" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "true");
    try std.testing.expect(!registry.hasPending("shell-1"));
    try std.testing.expect((try registry.copyPending(std.testing.allocator, "shell-1")) == null);
    try std.testing.expect(!(try registry.appendPending("shell-9", "x")));
    try std.testing.expect(try registry.appendPending("shell-1", "one\n"));
    try std.testing.expect(try registry.appendPending("shell-1", "two\n"));
    const copied = (try registry.copyPending(std.testing.allocator, "shell-1")).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("one\ntwo\n", copied);
    // A copy leaves the output in place until it is cleared.
    try std.testing.expect(registry.hasPending("shell-1"));
    registry.clearPending("shell-1");
    try std.testing.expect(!registry.hasPending("shell-1"));
    // Past the cap the rest is left out, and the first words stay.
    const big = try std.testing.allocator.alloc(u8, max_pending_bytes + 100);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try std.testing.expect(try registry.appendPending("shell-1", big));
    try std.testing.expect(try registry.appendPending("shell-1", "tail"));
    const capped = (try registry.copyPending(std.testing.allocator, "shell-1")).?;
    defer std.testing.allocator.free(capped);
    try std.testing.expectEqual(max_pending_bytes, capped.len);
}

test "events a monitor cannot post are held, the newest twenty, and the older ones counted" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "true");
    try std.testing.expect(!registry.hasHeld("shell-1"));
    var buffer: [16]u8 = undefined;
    for (0..25) |index| {
        const text = try std.mem.print(&buffer, "event {d}", .{index});
        _ = try registry.pushHeld("shell-1", text, @intCast(index), false);
    }
    try std.testing.expect((try registry.pushHeld("shell-9", "x", 0, false)) == null);
    const batch = (try registry.takeHeld("shell-1")).?;
    defer freeBatch(std.testing.allocator, batch);
    try std.testing.expectEqual(@as(usize, 20), batch.events.len);
    try std.testing.expectEqual(@as(u64, 5), batch.dropped);
    try std.testing.expectEqualStrings("event 5", batch.events[0].text);
    try std.testing.expectEqualStrings("event 24", batch.events[19].text);
    try std.testing.expect(!batch.ended);
    try std.testing.expect((try registry.takeHeld("shell-1")) == null);
}

test "a batch a post did not take goes back in front of what came since" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "true");
    _ = try registry.pushHeld("shell-1", "old", 1, false);
    const batch = (try registry.takeHeld("shell-1")).?;
    _ = try registry.pushHeld("shell-1", "new", 2, true);
    registry.restoreHeld("shell-1", batch);
    const again = (try registry.takeHeld("shell-1")).?;
    defer freeBatch(std.testing.allocator, again);
    try std.testing.expectEqual(@as(usize, 2), again.events.len);
    try std.testing.expectEqualStrings("old", again.events[0].text);
    try std.testing.expectEqualStrings("new", again.events[1].text);
    try std.testing.expect(again.ended);
}

test "a batch for a monitor that is gone is freed" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-1", "ci", "true");
    _ = try registry.pushHeld("shell-1", "old", 1, false);
    const batch = (try registry.takeHeld("shell-1")).?;
    try std.testing.expect(registry.remove("shell-1"));
    registry.restoreHeld("shell-1", batch);
}

test "a registry refuses monitors past the cap" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    var buffer: [16]u8 = undefined;
    for (0..max_monitors) |index| {
        const id = try std.mem.print(&buffer, "shell-{d}", .{index});
        try registry.add(id, "m", "true");
    }
    try std.testing.expectError(error.TooManyMonitors, registry.add("shell-x", "m", "true"));
}

test "a registry polls at most once a gap, and never with no monitor" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try std.testing.expect(!registry.takePoll(10_000));
    try registry.add("shell-1", "m", "true");
    try std.testing.expect(registry.takePoll(10_000));
    try std.testing.expect(!registry.takePoll(10_500));
    try std.testing.expect(registry.takePoll(11_000));
}

test "the list names each monitor, and says so when none run" {
    var registry: Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    const none = try registry.listText(std.testing.allocator);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("No monitors are running.", none);
    try registry.add("shell-4", "ci", "gh pr checks 9 --watch");
    const one = try registry.listText(std.testing.allocator);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("shell-4\tci\tgh pr checks 9 --watch\n", one);
}

test {
    _ = event_mod;
    _ = saved;
    _ = output_log;
}
