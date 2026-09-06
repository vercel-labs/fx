const std = @import("std");
const elicitation = @import("elicitation.zig");
const tool_subscription = @import("tool_subscription.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");

const Allocator = std.mem.Allocator;

pub const SourceState = enum { current, logout_fenced, stale };

pub const Waiter = struct {
    binding: elicitation.Binding,
    ids: []const []const u8,
    completed: []bool,
    signal: tool_mcp_runtime.LegacyUrlCompletionSignal = .{},
};

pub const WireCompletionIdentity = struct {
    server_name: []const u8,
    elicitation_id: []const u8,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
};

pub const EarlyCompletion = struct {
    server_name: []u8,
    elicitation_id: []u8,
    runtime_generation: u64,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
    window_generation: u64,
    deadline_ms: i64,
    logout_fenced: bool = false,

    pub fn deinit(self: *EarlyCompletion, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.elicitation_id);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    pub const Status = enum { issued, early, logout_fenced, handled };

    server_name: []u8,
    elicitation_id: []u8,
    runtime_generation: u64,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
    status: Status = .issued,

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.elicitation_id);
        self.* = undefined;
    }
};

pub const Publication = struct {
    sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    id: []u8,
};

pub const ReplayStep = union(enum) {
    done,
    progressed,
    publication: Publication,
};

pub const Window = struct {
    source: tool_subscription.NotificationSource,
    runtime_generation: u64,
    generation: u64,
};

pub fn candidateMatchesWire(candidate: Candidate, completion: WireCompletionIdentity) bool {
    return candidate.runtime_generation == completion.runtime_generation and
        candidate.connection_generation == completion.connection_generation and
        candidate.client_generation == completion.client_generation and
        candidate.auth_generation == completion.auth_generation and
        std.mem.eql(u8, candidate.server_name, completion.server_name) and
        std.mem.eql(u8, candidate.elicitation_id, completion.elicitation_id);
}

pub fn candidateMatchesWaiterId(candidate: Candidate, waiter: *const Waiter, id: []const u8) bool {
    return candidate.runtime_generation == waiter.binding.runtime_generation and
        candidate.connection_generation == waiter.binding.connection_generation and
        candidate.client_generation == waiter.binding.client_generation and
        candidate.auth_generation == waiter.binding.auth_generation and
        std.mem.eql(u8, candidate.server_name, waiter.binding.server_name) and
        std.mem.eql(u8, candidate.elicitation_id, id);
}

pub fn apply(
    waiter: *Waiter,
    completion: elicitation.LegacyUrlCompletionIdentity,
    now_ms: i64,
) bool {
    if (waiter.signal.status.load(.acquire) != .pending) return false;
    const transition = elicitation.decideLegacyUrlCompletion(
        waiter.binding,
        waiter.ids,
        waiter.completed,
        completion,
        now_ms,
        true,
    );
    switch (transition) {
        .record => |record| {
            waiter.completed[record.index] = true;
            if (record.all_complete) {
                waiter.signal.status.store(.completed, .release);
                waiter.signal.wake.store(true, .release);
            }
            return true;
        },
        .reject => return false,
    }
}

pub fn wireCompletionTargetsWaiter(waiter: *const Waiter, completion: WireCompletionIdentity) bool {
    if (!std.mem.eql(u8, waiter.binding.server_name, completion.server_name) or
        waiter.binding.runtime_generation != completion.runtime_generation or
        waiter.binding.connection_generation != completion.connection_generation or
        waiter.binding.client_generation != completion.client_generation or
        waiter.binding.auth_generation != completion.auth_generation)
    {
        return false;
    }
    for (waiter.ids) |id| {
        if (std.mem.eql(u8, id, completion.elicitation_id)) return true;
    }
    return false;
}

test "legacy URL completion records only a matching live identity" {
    var completed = [_]bool{false};
    const ids = [_][]const u8{"elicitation-1"};
    var waiter = Waiter{
        .binding = .{
            .server_name = "fixture",
            .scope = .{ .operation = .{ .tools_call = "echo" } },
            .runtime_generation = 1,
            .connection_generation = 2,
            .client_generation = 3,
            .catalog_generation = 4,
            .request_generation = 5,
            .auth_generation = 6,
            .deadline_ms = 100,
        },
        .ids = &ids,
        .completed = &completed,
    };
    try std.testing.expect(!apply(&waiter, .{
        .server_name = "other",
        .elicitation_id = "elicitation-1",
        .runtime_generation = 1,
        .connection_generation = 2,
        .client_generation = 3,
        .catalog_generation = 4,
        .auth_generation = 6,
    }, 50));
    try std.testing.expect(apply(&waiter, .{
        .server_name = "fixture",
        .elicitation_id = "elicitation-1",
        .runtime_generation = 1,
        .connection_generation = 2,
        .client_generation = 3,
        .catalog_generation = 4,
        .auth_generation = 6,
    }, 50));
    try std.testing.expect(completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        waiter.signal.status.load(.acquire),
    );
}

const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const LegacyUrlWaiter = Waiter;
const LegacyUrlWireCompletionIdentity = WireCompletionIdentity;
const LegacyUrlCompletionWindow = Window;
const LegacyUrlCompletionCandidate = Candidate;
const EarlyLegacyUrlCompletion = EarlyCompletion;
const legacyUrlCandidateMatchesWire = candidateMatchesWire;
const legacyUrlCandidateMatchesWaiterId = candidateMatchesWaiterId;
const legacyUrlWireCompletionTargetsWaiter = wireCompletionTargetsWaiter;
fn awakeMillis() i64 {
    return std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake).raw.toMilliseconds();
}
fn applyLegacyUrlCompletion(waiter: *Waiter, completion: elicitation.LegacyUrlCompletionIdentity) bool {
    return apply(waiter, completion, awakeMillis());
}
pub const max_pending_legacy_url_waiters: usize = 32;
pub const max_early_legacy_url_completions_per_window: usize = 64;
pub const max_legacy_url_completion_candidates: usize = 1024;
pub const max_legacy_url_completion_windows: usize = 32;
pub const early_legacy_url_completion_ttl_ms: i64 = 10 * 60 * 1000;

/// Owns bounded completion waiters and their notification journal.
/// Connection and authority checks remain with the caller before locked operations.
pub const State = struct {
    alloc: Allocator,
    runtime_generation: u64 = 0,
    sink: ?tool_mcp_runtime.LegacyUrlCompletionSink = null,
    legacy_url_waiter_mutex: std.Io.Mutex = .init,
    legacy_url_waiters: std.ArrayList(*LegacyUrlWaiter) = .empty,
    early_legacy_url_completions: std.ArrayList(EarlyLegacyUrlCompletion) = .empty,
    legacy_url_completion_candidates: std.ArrayList(LegacyUrlCompletionCandidate) = .empty,
    legacy_url_completion_windows: std.ArrayList(LegacyUrlCompletionWindow) = .empty,
    next_legacy_url_completion_window_generation: u64 = 1,

    pub fn beginWindowLocked(self: *State, source: tool_subscription.NotificationSource, runtime_generation: u64) !u64 {
        if (self.legacy_url_completion_windows.items.len >= max_legacy_url_completion_windows) {
            return error.McpInputRequiredLimitExceeded;
        }
        const generation = self.next_legacy_url_completion_window_generation;
        self.next_legacy_url_completion_window_generation = std.math.add(
            u64,
            generation,
            1,
        ) catch return error.McpRequestIdExhausted;
        try self.legacy_url_completion_windows.append(self.alloc, .{
            .source = source,
            .runtime_generation = runtime_generation,
            .generation = generation,
        });
        return generation;
    }

    pub fn registerCandidatesLocked(self: *State, source: tool_subscription.NotificationSource, runtime_generation: u64, window_generation: ?u64, ids: []const []const u8, source_state: SourceState, now_ms: i64) !void {
        if (source_state == .stale or
            (source_state == .logout_fenced and window_generation == null))
        {
            return error.Cancelled;
        }
        if (window_generation) |generation| {
            var window_current = false;
            for (self.legacy_url_completion_windows.items) |window| {
                if (window.generation == generation and
                    window.runtime_generation == runtime_generation and
                    window.source.connection_generation == source.connection_generation and
                    window.source.client_generation == source.client_generation and
                    window.source.auth_generation == source.auth_generation and
                    std.mem.eql(u8, window.source.server_name, source.server_name))
                {
                    window_current = true;
                    break;
                }
            }
            if (!window_current) return error.Cancelled;
        }
        for (ids, 0..) |id, index| {
            for (ids[0..index]) |previous| {
                if (std.mem.eql(u8, id, previous)) return error.McpDuplicateElicitationId;
            }
            for (self.legacy_url_completion_candidates.items) |candidate| {
                if (candidate.runtime_generation == runtime_generation and
                    candidate.connection_generation == source.connection_generation and
                    candidate.client_generation == source.client_generation and
                    candidate.auth_generation == source.auth_generation and
                    std.mem.eql(u8, candidate.server_name, source.server_name) and
                    std.mem.eql(u8, candidate.elicitation_id, id))
                {
                    return error.McpDuplicateElicitationId;
                }
            }
        }
        if (ids.len > max_legacy_url_completion_candidates -|
            self.legacy_url_completion_candidates.items.len)
        {
            return error.McpInputRequiredLimitExceeded;
        }
        const original_len = self.legacy_url_completion_candidates.items.len;
        errdefer while (self.legacy_url_completion_candidates.items.len > original_len) {
            var candidate = self.legacy_url_completion_candidates.pop().?;
            candidate.deinit(self.alloc);
        };
        for (ids) |id| {
            const server_name = try self.alloc.dupe(u8, source.server_name);
            errdefer self.alloc.free(server_name);
            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            try self.legacy_url_completion_candidates.append(self.alloc, .{
                .server_name = server_name,
                .elicitation_id = owned_id,
                .runtime_generation = runtime_generation,
                .connection_generation = source.connection_generation,
                .client_generation = source.client_generation,
                .auth_generation = source.auth_generation,
            });
        }
        self.pruneEarlyLegacyUrlCompletionsLocked(now_ms);
        var pending_index: usize = 0;
        while (pending_index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[pending_index];
            if (window_generation == null or
                pending.window_generation != window_generation.?)
            {
                pending_index += 1;
                continue;
            }
            var candidate_index: ?usize = null;
            for (self.legacy_url_completion_candidates.items[original_len..], original_len..) |candidate, index| {
                if (legacyUrlCandidateMatchesWire(candidate, .{
                    .server_name = pending.server_name,
                    .elicitation_id = pending.elicitation_id,
                    .runtime_generation = pending.runtime_generation,
                    .connection_generation = pending.connection_generation,
                    .client_generation = pending.client_generation,
                    .auth_generation = pending.auth_generation,
                })) {
                    candidate_index = index;
                    break;
                }
            }
            const matched_index = candidate_index orelse {
                pending_index += 1;
                continue;
            };
            self.legacy_url_completion_candidates.items[matched_index].status =
                if (pending.logout_fenced) .logout_fenced else .early;
            var matched = self.early_legacy_url_completions.swapRemove(pending_index);
            matched.deinit(self.alloc);
        }
    }

    pub fn init(alloc: Allocator) State {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *State) void {
        std.debug.assert(self.legacy_url_waiters.items.len == 0);
        self.legacy_url_waiters.deinit(self.alloc);
        for (self.early_legacy_url_completions.items) |*completion| {
            completion.deinit(self.alloc);
        }
        self.early_legacy_url_completions.deinit(self.alloc);
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            candidate.deinit(self.alloc);
        }
        self.legacy_url_completion_candidates.deinit(self.alloc);
        std.debug.assert(self.legacy_url_completion_windows.items.len == 0);
        self.legacy_url_completion_windows.deinit(self.alloc);
    }
    pub fn registerLegacyUrlWaiter(self: *State, waiter: *LegacyUrlWaiter) !void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        try self.registerLegacyUrlWaiterLocked(waiter);
        self.replayEarlyLegacyUrlCompletionsLocked(waiter);
    }

    pub fn legacyUrlWaiterAdmittedLocked(
        self: *State,
        waiter: *const LegacyUrlWaiter,
    ) bool {
        if (waiter.ids.len == 0) return false;
        for (waiter.ids) |id| {
            var admitted = false;
            for (self.legacy_url_completion_candidates.items) |candidate| {
                if (candidate.status == .handled or
                    !legacyUrlCandidateMatchesWaiterId(candidate, waiter, id)) continue;
                admitted = true;
                break;
            }
            if (!admitted) return false;
        }
        return true;
    }

    pub fn fenceEarlyLegacyUrlCompletionsLocked(
        self: *State,
        waiter: *const LegacyUrlWaiter,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.status != .early) continue;
            for (waiter.ids) |id| {
                if (!legacyUrlCandidateMatchesWaiterId(candidate.*, waiter, id)) continue;
                candidate.status = .logout_fenced;
                break;
            }
        }
    }

    pub fn registerLegacyUrlWaiterLocked(self: *State, waiter: *LegacyUrlWaiter) !void {
        if (self.legacy_url_waiters.items.len >= max_pending_legacy_url_waiters) {
            return error.McpInputRequiredLimitExceeded;
        }
        for (self.legacy_url_waiters.items) |pending| {
            if (!std.mem.eql(u8, pending.binding.server_name, waiter.binding.server_name) or
                pending.binding.connection_generation != waiter.binding.connection_generation)
            {
                continue;
            }
            for (pending.ids) |pending_id| for (waiter.ids) |id| {
                if (std.mem.eql(u8, pending_id, id)) return error.McpDuplicateElicitationId;
            };
        }
        try self.legacy_url_waiters.append(self.alloc, waiter);
    }

    pub fn unregisterLegacyUrlWaiter(self: *State, waiter: *LegacyUrlWaiter) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.legacy_url_waiters.items, 0..) |pending, index| {
            if (pending != waiter) continue;
            _ = self.legacy_url_waiters.swapRemove(index);
            return;
        }
    }

    pub fn recordLegacyUrlCompletion(
        self: *State,
        completion: elicitation.LegacyUrlCompletionIdentity,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        _ = self.recordLegacyUrlCompletionLocked(completion);
    }

    fn recordLegacyUrlCompletionLocked(
        self: *State,
        completion: elicitation.LegacyUrlCompletionIdentity,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (applyLegacyUrlCompletion(waiter, completion)) return true;
        }
        return false;
    }

    pub fn recordLegacyUrlCompletionFromWire(
        self: *State,
        completion: LegacyUrlWireCompletionIdentity,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        _ = self.recordLegacyUrlCompletionFromWireLocked(completion);
    }

    pub fn recordLegacyUrlCompletionFromWireLocked(
        self: *State,
        completion: LegacyUrlWireCompletionIdentity,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (!legacyUrlWireCompletionTargetsWaiter(waiter, completion)) continue;
            _ = applyLegacyUrlCompletion(waiter, .{
                .server_name = completion.server_name,
                .elicitation_id = completion.elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                // The notification has no catalog generation. The retained
                // originating snapshot is revalidated before retrying.
                .catalog_generation = waiter.binding.catalog_generation,
                .auth_generation = completion.auth_generation,
            });
            return true;
        }
        return false;
    }

    pub fn pruneEarlyLegacyUrlCompletionsLocked(self: *State, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            if (self.early_legacy_url_completions.items[index].deadline_ms >= now_ms) {
                index += 1;
                continue;
            }
            var expired = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=expired",
                .{ expired.server_name, expired.elicitation_id },
            );
            expired.deinit(self.alloc);
        }
    }

    fn legacyUrlCompletionWindowMatches(
        window: LegacyUrlCompletionWindow,
        completion: LegacyUrlWireCompletionIdentity,
    ) bool {
        return window.runtime_generation == completion.runtime_generation and
            window.source.connection_generation == completion.connection_generation and
            window.source.client_generation == completion.client_generation and
            window.source.auth_generation == completion.auth_generation and
            std.mem.eql(u8, window.source.server_name, completion.server_name);
    }

    pub fn endLegacyUrlCompletionWindow(
        self: *State,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
        window_generation: u64,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.legacy_url_completion_windows.items, 0..) |window, index| {
            if (window.generation != window_generation or
                window.runtime_generation != runtime_generation or
                window.source.connection_generation != source.connection_generation or
                window.source.client_generation != source.client_generation or
                window.source.auth_generation != source.auth_generation or
                !std.mem.eql(u8, window.source.server_name, source.server_name)) continue;
            _ = self.legacy_url_completion_windows.swapRemove(index);
            self.dropUnverifiedLegacyUrlCompletionsLocked(window_generation);
            return;
        }
        std.debug.assert(false);
    }

    fn dropUnverifiedLegacyUrlCompletionsLocked(
        self: *State,
        window_generation: u64,
    ) void {
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[index];
            if (pending.window_generation != window_generation) {
                index += 1;
                continue;
            }
            var dropped = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "ignored unmatched legacy URL completion server={s} elicitation_id={s} reason=no_candidate",
                .{ dropped.server_name, dropped.elicitation_id },
            );
            dropped.deinit(self.alloc);
        }
    }

    pub fn journalEarlyLegacyUrlCompletionLocked(
        self: *State,
        completion: LegacyUrlWireCompletionIdentity,
        logout_fenced: bool,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (!legacyUrlCandidateMatchesWire(candidate.*, completion)) continue;
            if (candidate.status == .issued) {
                candidate.status = if (logout_fenced) .logout_fenced else .early;
            }
            return;
        }
        var matched_window = false;
        const now_ms = awakeMillis();
        self.pruneEarlyLegacyUrlCompletionsLocked(now_ms);
        for (self.legacy_url_completion_windows.items) |window| {
            if (!legacyUrlCompletionWindowMatches(window, completion)) continue;
            matched_window = true;
            var already_recorded = false;
            var window_entries: usize = 0;
            var window_eviction_index: ?usize = null;
            for (self.early_legacy_url_completions.items, 0..) |pending, index| {
                if (pending.window_generation == window.generation) {
                    window_entries += 1;
                    if (window_eviction_index == null) window_eviction_index = index;
                }
                if (pending.window_generation == window.generation and
                    pending.runtime_generation == completion.runtime_generation and
                    pending.connection_generation == completion.connection_generation and
                    pending.client_generation == completion.client_generation and
                    pending.auth_generation == completion.auth_generation and
                    std.mem.eql(u8, pending.server_name, completion.server_name) and
                    std.mem.eql(u8, pending.elicitation_id, completion.elicitation_id))
                {
                    already_recorded = true;
                    break;
                }
            }
            if (already_recorded) continue;
            if (window_entries >= max_early_legacy_url_completions_per_window) {
                var evicted = self.early_legacy_url_completions.swapRemove(
                    window_eviction_index.?,
                );
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=capacity",
                    .{ evicted.server_name, evicted.elicitation_id },
                );
                evicted.deinit(self.alloc);
            }
            const server_name = self.alloc.dupe(u8, completion.server_name) catch {
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
            const elicitation_id = self.alloc.dupe(u8, completion.elicitation_id) catch {
                self.alloc.free(server_name);
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
            self.early_legacy_url_completions.append(self.alloc, .{
                .server_name = server_name,
                .elicitation_id = elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .auth_generation = completion.auth_generation,
                .window_generation = window.generation,
                .deadline_ms = std.math.add(
                    i64,
                    now_ms,
                    early_legacy_url_completion_ttl_ms,
                ) catch std.math.maxInt(i64),
                .logout_fenced = logout_fenced,
            }) catch {
                self.alloc.free(server_name);
                self.alloc.free(elicitation_id);
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
        }
        if (!matched_window) {
            debug_trace.logf(
                "mcp",
                "ignored unknown legacy URL completion server={s} elicitation_id={s}",
                .{ completion.server_name, completion.elicitation_id },
            );
        }
    }

    pub fn earlyLegacyUrlCompletionRecordedLocked(
        self: *State,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        for (self.legacy_url_completion_candidates.items) |candidate| {
            if ((candidate.status == .early or candidate.status == .logout_fenced) and
                candidate.runtime_generation == origin.runtime_generation and
                candidate.connection_generation == origin.connection_generation and
                candidate.client_generation == origin.client_generation and
                candidate.auth_generation == origin.auth_generation and
                std.mem.eql(u8, candidate.server_name, origin.server_name) and
                std.mem.eql(u8, candidate.elicitation_id, elicitation_id)) return true;
        }
        return false;
    }

    pub fn markWireLegacyUrlCompletionHandledLocked(
        self: *State,
        completion: LegacyUrlWireCompletionIdentity,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (!legacyUrlCandidateMatchesWire(candidate.*, completion)) continue;
            candidate.status = .handled;
            return;
        }
    }

    pub fn markLegacyUrlCompletionHandledLocked(
        self: *State,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.runtime_generation != origin.runtime_generation or
                candidate.connection_generation != origin.connection_generation or
                candidate.client_generation != origin.client_generation or
                candidate.auth_generation != origin.auth_generation or
                !std.mem.eql(u8, candidate.server_name, origin.server_name) or
                !std.mem.eql(u8, candidate.elicitation_id, elicitation_id)) continue;
            candidate.status = .handled;
            return;
        }
    }

    pub fn replayEarlyLegacyUrlCompletionsLocked(
        self: *State,
        waiter: *LegacyUrlWaiter,
    ) void {
        var index: usize = 0;
        while (index < self.legacy_url_completion_candidates.items.len) {
            const candidate = &self.legacy_url_completion_candidates.items[index];
            if ((candidate.status != .early and candidate.status != .logout_fenced) or
                candidate.runtime_generation != waiter.binding.runtime_generation or
                candidate.connection_generation != waiter.binding.connection_generation or
                candidate.client_generation != waiter.binding.client_generation or
                candidate.auth_generation != waiter.binding.auth_generation or
                !std.mem.eql(u8, candidate.server_name, waiter.binding.server_name))
            {
                index += 1;
                continue;
            }
            var id_matches = false;
            for (waiter.ids) |id| {
                if (std.mem.eql(u8, id, candidate.elicitation_id)) {
                    id_matches = true;
                    break;
                }
            }
            if (!id_matches) {
                index += 1;
                continue;
            }
            _ = applyLegacyUrlCompletion(waiter, .{
                .server_name = candidate.server_name,
                .elicitation_id = candidate.elicitation_id,
                .runtime_generation = candidate.runtime_generation,
                .connection_generation = candidate.connection_generation,
                .client_generation = candidate.client_generation,
                .catalog_generation = waiter.binding.catalog_generation,
                .auth_generation = candidate.auth_generation,
            });
            candidate.status = .handled;
            index += 1;
        }
    }

    pub fn legacyUrlCompletionRecorded(
        self: *State,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        return self.legacyUrlCompletionRecordedLocked(origin, elicitation_id);
    }

    pub fn legacyUrlCompletionRecordedLocked(
        self: *State,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (waiter.signal.status.load(.acquire) == .cancelled) continue;
            if (!std.mem.eql(u8, waiter.binding.server_name, origin.server_name) or
                waiter.binding.runtime_generation != origin.runtime_generation or
                waiter.binding.connection_generation != origin.connection_generation or
                waiter.binding.client_generation != origin.client_generation or
                waiter.binding.catalog_generation != origin.catalog_generation or
                waiter.binding.auth_generation != origin.auth_generation)
            {
                continue;
            }
            for (waiter.ids, waiter.completed) |id, completed| {
                if (completed and std.mem.eql(u8, id, elicitation_id)) return true;
            }
        }
        return false;
    }

    pub fn cancelLegacyUrlWaitersForServer(
        self: *State,
        server_name: []const u8,
        connection_generation: u64,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        self.cancelLegacyUrlWaitersForServerLocked(server_name, connection_generation);
    }

    pub fn cancelLegacyUrlWaitersForServerLocked(
        self: *State,
        server_name: []const u8,
        connection_generation: u64,
    ) void {
        for (self.legacy_url_waiters.items) |waiter| {
            if (!std.mem.eql(u8, waiter.binding.server_name, server_name) or
                waiter.binding.connection_generation != connection_generation)
            {
                continue;
            }
            waiter.signal.status.store(.cancelled, .release);
            waiter.signal.wake.store(true, .release);
        }
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[index];
            if (!std.mem.eql(u8, pending.server_name, server_name) or
                pending.connection_generation != connection_generation)
            {
                index += 1;
                continue;
            }
            var removed = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=source_invalidated",
                .{ removed.server_name, removed.elicitation_id },
            );
            removed.deinit(self.alloc);
        }
        index = 0;
        while (index < self.legacy_url_completion_candidates.items.len) {
            const candidate = &self.legacy_url_completion_candidates.items[index];
            if (!std.mem.eql(u8, candidate.server_name, server_name) or
                candidate.connection_generation != connection_generation)
            {
                index += 1;
                continue;
            }
            var removed = self.legacy_url_completion_candidates.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped legacy URL completion candidate server={s} elicitation_id={s} reason=source_invalidated",
                .{ removed.server_name, removed.elicitation_id },
            );
            removed.deinit(self.alloc);
        }
    }

    pub fn cancelAllLegacyUrlWaitersLocked(self: *State) void {
        for (self.legacy_url_waiters.items) |waiter| {
            waiter.signal.status.store(.cancelled, .release);
            waiter.signal.wake.store(true, .release);
        }
        for (self.early_legacy_url_completions.items) |*completion| {
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=runtime_retired",
                .{ completion.server_name, completion.elicitation_id },
            );
            completion.deinit(self.alloc);
        }
        self.early_legacy_url_completions.clearRetainingCapacity();
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            debug_trace.logf(
                "mcp",
                "dropped legacy URL completion candidate server={s} elicitation_id={s} reason=runtime_retired",
                .{ candidate.server_name, candidate.elicitation_id },
            );
            candidate.deinit(self.alloc);
        }
        self.legacy_url_completion_candidates.clearRetainingCapacity();
    }
};
