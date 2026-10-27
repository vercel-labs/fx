//! Watches as jobs (D190), proto's monitors in proto-fx form. A watch is
//! job `watch_N`: it follows another job's output (`source`), or re-runs a
//! short command every `every_ms` (`poll`), and reports each matching line
//! or changed matching output as an event, until `max_events`, its
//! `timeout_ms`, or the end of its source. Events become messages in the
//! root's mailbox from `watch_N`, so they wake the root, or join its
//! running turn, exactly once, and a `jobs wait` with a mailbox selector
//! takes them (D189). The watch's own result, why it stopped, is delivered
//! once like any job's.
//!
//! A watch thread never touches the session: events wait here until the
//! supervisor's tick moves them into the mailbox (`takeEvents`).
const std = @import("std");
const jobs = @import("jobs.zig");
const io_mod = @import("../shared/io.zig");
// The stream rules engine reads the same JavaScript dialect as proto.
const watch_pattern = @import("../ttsr/regex.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_environment = @import("../execution/command_environment.zig");
const command_runner = @import("../execution/command_runner.zig");
const execution_router = @import("../execution/router.zig");
const Allocator = std.mem.Allocator;

const job_prefix = "watch_";
pub const max_running = 8;
pub const default_max_events: u32 = 10;
pub const max_max_events: u32 = 1000;
pub const min_interval_ms: u64 = 1000;
const source_poll_ms: u64 = 250;
const max_event_bytes = 1200;
const max_capture_bytes = 64 * 1024;
const poll_timeout_ms: u64 = 30_000;
/// Events not yet moved into the mailbox; the oldest go first past this.
const max_queued_events = 256;

pub const Spec = struct {
    /// A job to follow, such as `bg_3`; exclusive with `command`.
    source: ?[]const u8 = null,
    command: ?[]const u8 = null,
    every_ms: ?u64 = null,
    match: ?[]const u8 = null,
    max_events: ?u32 = null,
    timeout_ms: ?u64 = null,
    label: ?[]const u8 = null,
    /// What admitted `command`: the authority shell run would get for it
    /// (D210). A watch polls only the exact command, directory, and
    /// environment that authority names, on the shell tool's route.
    authority: ?command_admission.CommandExecutionAuthority = null,
};

pub const StartError = error{ OutOfMemory, InvalidWatch, TooManyWatches, UnknownJob, CommandNotApproved };

/// What a command watch was approved to run, owned by the watch.
const ApprovedCommand = struct {
    context: command_admission.CommandContext,
    source: ?command_admission.ShellAuthorizationSource,
    grant_epoch: ?u64,

    fn init(alloc: Allocator, command: []const u8, authority: command_admission.CommandExecutionAuthority) StartError!ApprovedCommand {
        const fingerprint, const source: ?command_admission.ShellAuthorizationSource, const grant_epoch: ?u64 = switch (authority) {
            .direct_only => |value| .{ value, null, null },
            .shell_allowed => |value| .{ value.fingerprint, value.source, value.grant_epoch },
        };
        // The command the model asked to watch must be the one approved.
        if (!std.mem.eql(u8, fingerprint.command, command) or fingerprint.execution_mode != .captured) return error.CommandNotApproved;
        const owned_command = try alloc.dupe(u8, fingerprint.command);
        errdefer alloc.free(owned_command);
        const cwd = try alloc.dupe(u8, fingerprint.resolved_cwd);
        errdefer alloc.free(cwd);
        const environment: command_environment.Environment = switch (fingerprint.environment) {
            .legacy => .legacy,
            .workspace_clean => .workspace_clean,
            .clean => |path| .{ .clean = try alloc.dupe(u8, path) },
            .user => |path| .{ .user = try alloc.dupe(u8, path) },
        };
        return .{
            .context = .{
                .command = owned_command,
                .resolved_cwd = cwd,
                .target_os = fingerprint.target_os,
                .environment = environment,
                .execution_mode = .captured,
            },
            .source = source,
            .grant_epoch = grant_epoch,
        };
    }

    fn deinit(self: ApprovedCommand, alloc: Allocator) void {
        alloc.free(self.context.command);
        alloc.free(self.context.resolved_cwd);
        switch (self.context.environment) {
            .clean, .user => |path| alloc.free(path),
            .legacy, .workspace_clean => {},
        }
    }

    fn executionAuthority(self: *const ApprovedCommand) command_admission.CommandExecutionAuthority {
        const fingerprint = command_admission.AdmissionFingerprint.init(self.context);
        return if (self.source) |source|
            .{ .shell_allowed = .{ .fingerprint = fingerprint, .source = source, .grant_epoch = self.grant_epoch } }
        else
            .{ .direct_only = fingerprint };
    }
};

pub const Mode = enum { source, poll };
pub const StopReason = enum { limit, exit, timeout, manual, @"error", session };

/// One event for the mailbox. Owned by the caller's arena.
pub const Event = struct { from: []const u8, label: []const u8, body: []const u8 };

const Delivery = enum { open, reserved, delivered };

const Watch = struct {
    id: []u8,
    label: []u8,
    mode: Mode,
    source_id: ?[]u8,
    command: ?ApprovedCommand,
    every_ms: u64,
    pattern: ?[]u8,
    matcher: ?watch_pattern.Regex,
    max_events: u32,
    deadline_ms: ?i64,
    started_ms: i64,
    // Guarded by the source's mutex.
    events: u32 = 0,
    ended_ms: ?i64 = null,
    stop_reason: ?StopReason = null,
    failure: ?[]u8 = null,
    delivery: Delivery = .open,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn free(watch: *Watch, alloc: Allocator) void {
        alloc.free(watch.id);
        alloc.free(watch.label);
        if (watch.source_id) |value| alloc.free(value);
        if (watch.command) |value| value.deinit(alloc);
        if (watch.pattern) |value| alloc.free(value);
        if (watch.matcher) |*matcher| matcher.deinit();
        if (watch.failure) |value| alloc.free(value);
        alloc.destroy(watch);
    }

    fn state(watch: *const Watch) jobs.State {
        const reason = watch.stop_reason orelse return .running;
        return switch (reason) {
            .manual, .session => .cancelled,
            .@"error" => .failed,
            .limit, .exit, .timeout => .completed,
        };
    }

    fn matches(watch: *const Watch, line: []const u8) bool {
        const matcher = watch.matcher orelse return true;
        return matcher.isMatch(line);
    }
};

const QueuedEvent = struct { from: []u8, label: []u8, body: []u8 };

pub const Source = struct {
    alloc: Allocator,
    /// The registry the watched jobs live in, for their output and state.
    registry: *jobs.Registry,
    mutex: std.Io.Mutex = .init,
    watches: std.ArrayList(*Watch) = .empty,
    queued: std.ArrayList(QueuedEvent) = .empty,
    next_number: u32 = 1,

    const vtable = jobs.Source.VTable{
        .kind = .watch,
        .owns = owns,
        .list = list,
        .reserve = reserve,
        .logs = logs,
        .cancel = cancel,
    };

    pub fn init(alloc: Allocator, registry: *jobs.Registry) Source {
        return .{ .alloc = alloc, .registry = registry };
    }

    /// Stops and joins every watch, then frees everything.
    pub fn deinit(self: *Source) void {
        self.stopAll(.session);
        for (self.watches.items) |watch| watch.free(self.alloc);
        self.watches.deinit(self.alloc);
        for (self.queued.items) |event| freeEvent(self.alloc, event);
        self.queued.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn source(self: *Source) jobs.Source {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn from(raw: *anyopaque) *Source {
        return @ptrCast(@alignCast(raw));
    }

    fn lock(self: *Source) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Source) void {
        self.mutex.unlock(io_mod.getIo());
    }

    /// Starts a watch and returns its job id, owned by `arena`.
    pub fn start(self: *Source, arena: Allocator, spec: Spec) StartError![]const u8 {
        const mode: Mode = if (spec.source != null) .source else .poll;
        if ((spec.source == null) == (spec.command == null)) return error.InvalidWatch;
        if (mode == .poll and (spec.every_ms orelse 0) < min_interval_ms) return error.InvalidWatch;
        if (mode == .source and spec.every_ms != null) return error.InvalidWatch;
        if (spec.timeout_ms) |timeout| if (timeout < min_interval_ms) return error.InvalidWatch;
        if (spec.command != null and spec.authority == null) return error.CommandNotApproved;
        const max_events = spec.max_events orelse default_max_events;
        if (max_events == 0 or max_events > max_max_events) return error.InvalidWatch;
        if (spec.source) |id| {
            if (owns(id)) return error.InvalidWatch;
            if ((self.registry.find(arena, id) catch return error.UnknownJob) == null) return error.UnknownJob;
        }
        var matcher: ?watch_pattern.Regex = if (spec.match) |pattern| watch_pattern.compile(self.alloc, pattern) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => return error.InvalidWatch,
        } else null;
        errdefer if (matcher) |*value| value.deinit();
        var approved: ?ApprovedCommand = if (spec.command) |command| try ApprovedCommand.init(self.alloc, command, spec.authority.?) else null;
        errdefer if (approved) |value| value.deinit(self.alloc);
        const watch = try self.alloc.create(Watch);
        errdefer self.alloc.destroy(watch);
        const now = io_mod.milliTimestamp();
        self.lock();
        defer self.unlock();
        var live: usize = 0;
        for (self.watches.items) |existing| {
            if (existing.stop_reason == null) live += 1;
        }
        if (live >= max_running) return error.TooManyWatches;
        const number = self.next_number;
        const id = try self.alloc.print(job_prefix ++ "{d}", .{number});
        errdefer self.alloc.free(id);
        const label = if (spec.label) |value|
            try self.alloc.dupe(u8, value)
        else if (spec.source) |job_id|
            try self.alloc.print("watch on {s}", .{job_id})
        else
            try self.alloc.print("watch on {s}", .{spec.command.?[0..@min(spec.command.?.len, 64)]});
        errdefer self.alloc.free(label);
        watch.* = .{
            .id = id,
            .label = label,
            .mode = mode,
            .source_id = if (spec.source) |value| try self.alloc.dupe(u8, value) else null,
            .command = approved,
            .every_ms = spec.every_ms orelse source_poll_ms,
            .pattern = if (spec.match) |value| try self.alloc.dupe(u8, value) else null,
            .matcher = matcher,
            .max_events = max_events,
            .deadline_ms = if (spec.timeout_ms) |timeout| now + @as(i64, @intCast(timeout)) else null,
            .started_ms = now,
        };
        matcher = null;
        approved = null;
        const out_id = try arena.dupe(u8, id);
        try self.watches.append(self.alloc, watch);
        self.next_number += 1;
        // From here the watch is listed: a thread that cannot start leaves
        // it failed rather than missing.
        watch.thread = std.Thread.spawn(.{}, run, .{ self, watch }) catch blk: {
            finishLocked(watch, .@"error");
            break :blk null;
        };
        return out_id;
    }

    /// Stops every running watch and joins its thread.
    pub fn stopAll(self: *Source, reason: StopReason) void {
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(self.alloc);
        {
            self.lock();
            defer self.unlock();
            for (self.watches.items) |watch| {
                if (watch.stop_reason == null) finishLocked(watch, reason);
                watch.stop.store(true, .seq_cst);
                if (watch.thread) |thread| {
                    threads.append(self.alloc, thread) catch {
                        thread.join();
                    };
                    watch.thread = null;
                }
            }
        }
        for (threads.items) |thread| thread.join();
    }

    /// Moves the events that wait into `arena`, oldest first.
    pub fn takeEvents(self: *Source, arena: Allocator) ![]Event {
        self.lock();
        defer self.unlock();
        const out = try arena.alloc(Event, self.queued.items.len);
        for (self.queued.items, out) |event, *copy| copy.* = .{
            .from = try arena.dupe(u8, event.from),
            .label = try arena.dupe(u8, event.label),
            .body = try arena.dupe(u8, event.body),
        };
        for (self.queued.items) |event| freeEvent(self.alloc, event);
        self.queued.clearRetainingCapacity();
        return out;
    }

    fn emit(self: *Source, watch: *Watch, body: []const u8) void {
        self.lock();
        defer self.unlock();
        if (watch.stop_reason != null) return;
        const clipped = clip(body, max_event_bytes);
        // The match leads, so a row's first line is what the watch saw.
        const text = self.alloc.print("{s}\n(watch {s} event {d} of at most {d})", .{ clipped, watch.id, watch.events + 1, watch.max_events }) catch return;
        const from_id = self.alloc.dupe(u8, watch.id) catch {
            self.alloc.free(text);
            return;
        };
        const label = self.alloc.dupe(u8, watch.label) catch {
            self.alloc.free(text);
            self.alloc.free(from_id);
            return;
        };
        if (self.queued.items.len >= max_queued_events) freeEvent(self.alloc, self.queued.orderedRemove(0));
        self.queued.append(self.alloc, .{ .from = from_id, .label = label, .body = text }) catch {
            freeEvent(self.alloc, .{ .from = from_id, .label = label, .body = text });
            return;
        };
        watch.events += 1;
        if (watch.events >= watch.max_events) finishLocked(watch, .limit);
    }

    fn finish(self: *Source, watch: *Watch, reason: StopReason, failure: ?[]const u8) void {
        self.lock();
        defer self.unlock();
        if (watch.stop_reason != null) return;
        finishLocked(watch, reason);
        if (failure) |text| watch.failure = self.alloc.dupe(u8, clip(text, 400)) catch null;
    }

    fn running(self: *Source, watch: *Watch) bool {
        if (watch.stop.load(.seq_cst)) return false;
        self.lock();
        defer self.unlock();
        if (watch.stop_reason != null) return false;
        if (watch.deadline_ms) |deadline| if (io_mod.milliTimestamp() >= deadline) {
            finishLocked(watch, .timeout);
            return false;
        };
        return true;
    }

    // -- the jobs registry's view -------------------------------------------

    fn owns(id: []const u8) bool {
        if (!std.mem.startsWith(u8, id, job_prefix)) return false;
        _ = std.fmt.parseUnsigned(u32, id[job_prefix.len..], 10) catch return false;
        return true;
    }

    fn list(raw: *anyopaque, arena: Allocator) anyerror![]jobs.Job {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        const out = try arena.alloc(jobs.Job, self.watches.items.len);
        for (self.watches.items, out) |watch, *job| job.* = try jobOf(arena, watch);
        return out;
    }

    fn reserve(raw: *anyopaque, arena: Allocator, id: []const u8) anyerror!?jobs.Settled {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        for (self.watches.items, 0..) |watch, index| {
            if (!std.mem.eql(u8, watch.id, id)) continue;
            if (watch.stop_reason == null or watch.delivery != .open) return null;
            watch.delivery = .reserved;
            return .{
                .job = try jobOf(arena, watch),
                .text = try resultText(arena, watch),
                .token = .{ .context = self, .identity = index, .commit_fn = commit, .cancel_fn = release },
            };
        }
        return null;
    }

    fn commit(raw: *anyopaque, index: u64) anyerror!void {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if (index >= self.watches.items.len or self.watches.items[index].delivery != .reserved) return error.UnknownReservation;
        self.watches.items[index].delivery = .delivered;
    }

    fn release(raw: *anyopaque, index: u64) void {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        if (index >= self.watches.items.len or self.watches.items[index].delivery != .reserved) return;
        self.watches.items[index].delivery = .open;
    }

    fn logs(raw: *anyopaque, arena: Allocator, id: []const u8, _: usize) anyerror!jobs.Logs {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        for (self.watches.items) |watch| if (std.mem.eql(u8, watch.id, id)) {
            const text = try resultText(arena, watch);
            return .{ .text = text, .retained_bytes = text.len, .total_bytes = text.len };
        };
        return error.UnknownJob;
    }

    fn cancel(raw: *anyopaque, arena: Allocator, id: []const u8, _: bool) anyerror!jobs.Cancelled {
        const self = from(raw);
        var thread: ?std.Thread = null;
        const status: jobs.CancelStatus = blk: {
            self.lock();
            defer self.unlock();
            for (self.watches.items) |watch| if (std.mem.eql(u8, watch.id, id)) {
                if (watch.stop_reason != null) break :blk .already_settled;
                finishLocked(watch, .manual);
                watch.stop.store(true, .seq_cst);
                thread = watch.thread;
                watch.thread = null;
                break :blk .settled;
            };
            return error.UnknownJob;
        };
        if (thread) |handle| handle.join();
        if (status == .already_settled) return .{ .status = status };
        // Cancelling consumes the result: the caller reads it now.
        const settled = try reserve(raw, arena, id);
        return .{ .status = .settled, .settled = settled };
    }
};

fn finishLocked(watch: *Watch, reason: StopReason) void {
    if (watch.stop_reason != null) return;
    watch.stop_reason = reason;
    watch.ended_ms = io_mod.milliTimestamp();
    watch.stop.store(true, .seq_cst);
}

fn jobOf(arena: Allocator, watch: *const Watch) !jobs.Job {
    return .{
        .id = try arena.dupe(u8, watch.id),
        .kind = .watch,
        .label = try arena.dupe(u8, watch.label),
        .state = watch.state(),
        .started_ms = watch.started_ms,
        .ended_ms = watch.ended_ms,
        .delivered = watch.delivery == .delivered,
    };
}

fn resultText(arena: Allocator, watch: *const Watch) ![]const u8 {
    const what = switch (watch.mode) {
        .source => try arena.print("following {s}", .{watch.source_id.?}),
        .poll => try arena.print("polling `{s}` every {d} ms", .{ watch.command.?.context.command, watch.every_ms }),
    };
    const match_text = if (watch.pattern) |pattern| try arena.print(" for /{s}/", .{pattern}) else "";
    const reason = if (watch.stop_reason) |stop| switch (stop) {
        .limit => "stopped: it reached max_events",
        .exit => "stopped: its source ended",
        .timeout => "stopped: its timeout passed",
        .manual => "was cancelled",
        .@"error" => "failed",
        .session => "stopped with the session",
    } else "is running";
    const failure = if (watch.failure) |text| try arena.print(" ({s})", .{text}) else "";
    return arena.print("Watch {s} ({s}), {s}{s}, {s}{s} after {d} event(s). Its events reached you as messages from {s}.", .{
        watch.id, watch.label, what, match_text, reason, failure, watch.events, watch.id,
    });
}

/// One poll's raw output, bounded like the shell tool's.
const Captured = struct {
    arena: Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    fn append(raw: *anyopaque, _: ?@import("../shared/types.zig").ToolLifecycleId, stream: command_runner.CommandOutputStream, chunk: []const u8) anyerror!void {
        const self: *Captured = @ptrCast(@alignCast(raw));
        const list = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        const room = max_capture_bytes -| list.items.len;
        try list.appendSlice(self.arena, chunk[0..@min(chunk.len, room)]);
    }
};

fn freeEvent(alloc: Allocator, event: QueuedEvent) void {
    alloc.free(event.from);
    alloc.free(event.label);
    alloc.free(event.body);
}

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn sleepWhile(self: *Source, watch: *Watch, ms: u64) void {
    var left = ms;
    while (left > 0 and !watch.stop.load(.seq_cst)) {
        const step: u64 = @min(left, 50);
        io_mod.sleep(step * std.time.ns_per_ms);
        left -= step;
    }
    _ = self;
}

fn run(self: *Source, watch: *Watch) void {
    switch (watch.mode) {
        .source => follow(self, watch),
        .poll => poll(self, watch),
    }
}

/// Follows a job's output: each complete line that matches is an event.
fn follow(self: *Source, watch: *Watch) void {
    var seen: usize = 0;
    var partial: std.ArrayList(u8) = .empty;
    defer partial.deinit(self.alloc);
    while (self.running(watch)) {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const job = (self.registry.find(arena, watch.source_id.?) catch null) orelse {
            self.finish(watch, .exit, "its source job is gone");
            return;
        };
        const output = self.registry.logs(arena, watch.source_id.?, max_capture_bytes) catch |err| {
            self.finish(watch, .@"error", @errorName(err));
            return;
        };
        if (output.total_bytes > seen) {
            const fresh = @min(output.total_bytes - seen, output.text.len);
            seen = output.total_bytes;
            partial.appendSlice(self.alloc, output.text[output.text.len - fresh ..]) catch {};
            var start: usize = 0;
            while (std.mem.findScalarPos(u8, partial.items, start, '\n')) |end| : (start = end + 1) {
                const line = std.mem.trimEnd(u8, partial.items[start..end], "\r");
                if (line.len > 0 and watch.matches(line)) self.emit(watch, line);
            }
            const rest = partial.items.len - start;
            @memmove(partial.items[0..rest], partial.items[start..]);
            partial.shrinkRetainingCapacity(rest);
            // A line longer than the window reports what it has.
            if (partial.items.len > max_capture_bytes) partial.clearRetainingCapacity();
        } else if (job.state.settled()) {
            if (partial.items.len > 0 and watch.matches(partial.items)) self.emit(watch, partial.items);
            self.finish(watch, .exit, null);
            return;
        }
        sleepWhile(self, watch, source_poll_ms);
    }
}

/// Re-runs a command: matching output that changed since the last report
/// is an event.
fn poll(self: *Source, watch: *Watch) void {
    const approved = &watch.command.?;
    var last: ?u64 = null;
    while (self.running(watch)) {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var captured: Captured = .{ .arena = arena };
        // The shell tool's route: the approved command only, re-planned and
        // checked against its approval on every poll.
        _ = execution_router.executePlannedCommand(.{
            .max_command_output_bytes = max_capture_bytes,
            .cancel_flag = &watch.stop,
            .accepted_output_chunk_ctx = &captured,
            .on_accepted_output_chunk = Captured.append,
            .callback_projection = .raw,
            .timeout_ms = poll_timeout_ms,
        }, arena, approved.context, approved.executionAuthority()) catch |err| {
            self.finish(watch, .@"error", @errorName(err));
            return;
        };
        var text: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, if (captured.stdout.items.len > 0) captured.stdout.items else captured.stderr.items, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0 or !watch.matches(line)) continue;
            if (text.items.len > 0) text.append(arena, '\n') catch break;
            text.appendSlice(arena, line) catch break;
        }
        if (text.items.len > 0) {
            const hash = std.hash.Wyhash.hash(0, text.items);
            if (last != hash) self.emit(watch, text.items);
            last = hash;
        } else last = null;
        sleepWhile(self, watch, watch.every_ms);
    }
}

test "a poll watch reports changed matching output and stops at its limit" {
    const alloc = std.testing.allocator;
    var registry = jobs.Registry.init(alloc);
    defer registry.deinit();
    var watches = Source.init(alloc, &registry);
    defer watches.deinit();
    registry.addSource(watches.source());
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidWatch, watches.start(arena, .{ .command = "true", .authority = testApproval("true") }));
    try std.testing.expectError(error.InvalidWatch, watches.start(arena, .{ .command = "true", .every_ms = 1000, .match = "(bad", .authority = testApproval("true") }));
    try std.testing.expectError(error.UnknownJob, watches.start(arena, .{ .source = "bg_9" }));
    const command = "od -An -N4 -tu4 /dev/urandom | tr -d ' '; echo ready";
    const id = try watches.start(arena, .{ .command = command, .every_ms = 1000, .match = "^\\d+$", .max_events = 2, .label = "clock", .authority = testApproval(command) });
    try std.testing.expectEqualStrings("watch_1", id);
    var events: usize = 0;
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        events += (try watches.takeEvents(arena)).len;
        const job = (try registry.find(arena, id)).?;
        if (job.state.settled()) break;
        io_mod.sleep(50 * std.time.ns_per_ms);
    }
    events += (try watches.takeEvents(arena)).len;
    try std.testing.expectEqual(@as(usize, 2), events);
    const settled = (try registry.takeDeliveries(arena));
    try std.testing.expectEqual(@as(usize, 1), settled.len);
    try std.testing.expect(std.mem.find(u8, settled[0].text, "reached max_events") != null);
    try settled[0].token.commit();
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
}

fn testApproval(command: []const u8) command_admission.CommandExecutionAuthority {
    return .{ .shell_allowed = .{
        .fingerprint = .init(.{ .command = command, .resolved_cwd = ".", .target_os = @import("builtin").target.os.tag }),
        .source = .interactive_once,
    } };
}

test "a command watch runs only the command its approval names" {
    const alloc = std.testing.allocator;
    var registry = jobs.Registry.init(alloc);
    defer registry.deinit();
    var watches = Source.init(alloc, &registry);
    defer watches.deinit();
    registry.addSource(watches.source());
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No approval, or an approval of another command, starts nothing.
    try std.testing.expectError(error.CommandNotApproved, watches.start(arena, .{ .command = "echo hi", .every_ms = 1000 }));
    try std.testing.expectError(error.CommandNotApproved, watches.start(arena, .{ .command = "rm -rf build", .every_ms = 1000, .authority = testApproval("echo hi") }));
    var tty_approval = testApproval("echo hi");
    tty_approval.shell_allowed.fingerprint.execution_mode = .tty;
    try std.testing.expectError(error.CommandNotApproved, watches.start(arena, .{ .command = "echo hi", .every_ms = 1000, .authority = tty_approval }));
    try std.testing.expectEqual(@as(usize, 0), (try registry.list(arena)).len);
    // A read-only approval that does not cover what the command does fails
    // the watch on its first poll instead of widening it.
    const direct: command_admission.CommandExecutionAuthority = .{ .direct_only = .init(.{ .command = "touch watched.txt", .resolved_cwd = ".", .target_os = @import("builtin").target.os.tag }) };
    const id = try watches.start(arena, .{ .command = "touch watched.txt", .every_ms = 1000, .authority = direct });
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        const job = (try registry.find(arena, id)).?;
        if (job.state.settled()) break;
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
    const job = (try registry.find(arena, id)).?;
    try std.testing.expectEqual(jobs.State.failed, job.state);
    const logs = try registry.logs(arena, id, 4096);
    try std.testing.expect(std.mem.find(u8, logs.text, "CommandAdmissionChanged") != null);
}
