const std = @import("std");
const managed_execution = @import("../execution/managed_execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const action_executor = @import("action_executor.zig");
const client = @import("client.zig");
const contracts = @import("contracts.zig");
const identity = @import("identity.zig");
const operation = @import("operation.zig");
const store = @import("store.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    alloc: Allocator,
    lifecycle_allocator: Allocator,
    terminal_client: *client.Runtime,
    managed_runtime: *managed_execution.Runtime,
    owner: *session_child_store.SessionChildCapability,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: contracts.TransportRole,
    max_output_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const Observation = struct {
    state: managed_execution.SnapshotState,
    output: []u8,
    replay_output: []u8,
    next_cursor: managed_execution.TtyCursor,
    output_incomplete: bool,
    timed_out: bool,

    pub fn deinit(self: *Observation, alloc: Allocator) void {
        alloc.free(self.output);
        alloc.free(self.replay_output);
        self.* = undefined;
    }
};

pub fn refreshAll(ctx: Context) !void {
    try syncOwned(ctx);
    const items = try ctx.managed_runtime.list(ctx.alloc);
    defer {
        for (items) |*item| item.deinit(ctx.alloc);
        ctx.alloc.free(items);
    }
    for (items) |item| {
        if (item.backend != .tty) continue;
        refresh(ctx, item.execution_id, item.command) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (isDefinitiveLoss(err)) {
                ctx.managed_runtime.observeTtyState(item.execution_id, .lost);
            }
            debug_trace.logf(
                "terminal",
                "managed TTY refresh skipped session={s} err={s}",
                .{ item.execution_id, @errorName(err) },
            );
            continue;
        };
    }
}

pub fn refresh(
    ctx: Context,
    execution_id: []const u8,
    command: []const u8,
) !void {
    const state = ctx.managed_runtime.stateFor(execution_id) orelse
        return error.ExecutionNotFound;
    var observed = observe(
        ctx,
        execution_id,
        state,
        ctx.managed_runtime.ttyCursorFor(execution_id),
    ) catch |err| {
        if (isDefinitiveLoss(err)) {
            ctx.managed_runtime.observeTtyState(execution_id, .lost);
        }
        return err;
    };
    defer observed.deinit(ctx.alloc);
    try ctx.managed_runtime.refreshTty(.{
        .execution_id = execution_id,
        .command = command,
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_output_bytes,
        .published_running = true,
    });
}

pub fn observe(
    ctx: Context,
    session_id: []const u8,
    current_state: managed_execution.SnapshotState,
    previous_cursor: ?managed_execution.TtyCursor,
) !Observation {
    var authority = try reloadAuthority(ctx, session_id);
    defer authority.deinit();
    var inspected = try execute(ctx, .{ .inspect = .{
        .session_id = session_id,
        .authority = authority.view(),
    } });
    defer inspected.deinit(ctx.alloc);
    const facts = switch (inspected.view()) {
        .failure => |failure| return mapTerminalFailure(failure.code),
        .success => |success| switch (success) {
            .inspect => |value| value.session,
            else => return error.InvalidTerminalResult,
        },
    };

    var output_incomplete = false;
    var cursor = if (previous_cursor) |value|
        contracts.RawCursor{
            .segment = value.segment,
            .offset = value.offset,
        }
    else if (facts.raw_gap) |gap| blk: {
        output_incomplete = true;
        break :blk gap.available_from;
    } else if (facts.unread_range) |range|
        range.start
    else
        facts.output_cursor;
    if (facts.raw_gap) |gap| {
        if (contracts.compare_raw_cursors(cursor, gap.available_from) == .lt) {
            cursor = gap.available_from;
            output_incomplete = true;
        }
    }

    const target = facts.output_cursor;
    var observed_state = snapshotState(facts, null);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(ctx.alloc);
    while (contracts.compare_raw_cursors(cursor, target) == .lt) {
        const page = blk: {
            var read = try execute(ctx, .{ .read = .{
                .session_id = session_id,
                .cursor = cursor,
                .authority = authority.view(),
            } });
            defer read.deinit(ctx.alloc);
            const result = switch (read.view()) {
                .failure => |failure| return mapTerminalFailure(failure.code),
                .success => |success| switch (success) {
                    .read => |value| value,
                    else => return error.InvalidTerminalResult,
                },
            };
            try raw.appendSlice(ctx.alloc, result.output);
            break :blk .{
                .state = snapshotState(result.session, null),
                .next = if (result.raw_range) |range|
                    range.end
                else
                    result.session.output_cursor,
            };
        };
        observed_state = page.state;
        if (contracts.compare_raw_cursors(page.next, cursor) != .gt) {
            return error.TerminalReadDidNotAdvance;
        }
        cursor = page.next;
    }

    observed_state = try resolveCompletedStatus(
        ctx,
        session_id,
        observed_state,
        authority.view(),
    );

    const replay_output = try raw.toOwnedSlice(ctx.alloc);
    errdefer ctx.alloc.free(replay_output);
    const projected_output = if (std.mem.findScalar(u8, replay_output, 0x1b) != null)
        try currentScreenText(ctx, session_id, authority.view())
    else
        try ctx.alloc.dupe(u8, replay_output);
    return .{
        .state = reconcileObservedState(current_state, observed_state),
        .output = projected_output,
        .replay_output = replay_output,
        .next_cursor = .{
            .segment = cursor.segment,
            .offset = cursor.offset,
        },
        .output_incomplete = output_incomplete,
        .timed_out = facts.timed_out,
    };
}

pub fn syncOwned(ctx: Context) !void {
    var catalog_authority = try reloadOwnerCatalogAuthority(ctx);
    defer catalog_authority.deinit();
    var listed = try execute(ctx, .{ .list = .{
        .owner_authority = catalog_authority.view(),
    } });
    defer listed.deinit(ctx.alloc);
    const sessions = switch (listed.view()) {
        .failure => |failure| return mapTerminalFailure(failure.code),
        .success => |success| switch (success) {
            .list => |value| value.sessions,
            else => return error.InvalidTerminalResult,
        },
    };
    for (sessions) |facts| {
        if (facts.lifecycle == .closed or
            ctx.managed_runtime.backendFor(facts.session_id) != null)
        {
            continue;
        }
        var authority = try reloadAuthority(ctx, facts.session_id);
        defer authority.deinit();
        var inspected = try execute(ctx, .{ .inspect = .{
            .session_id = facts.session_id,
            .authority = authority.view(),
        } });
        defer inspected.deinit(ctx.alloc);
        const inspect = switch (inspected.view()) {
            .failure => |failure| return mapTerminalFailure(failure.code),
            .success => |success| switch (success) {
                .inspect => |value| value,
                else => return error.InvalidTerminalResult,
            },
        };
        const command = inspect.command orelse continue;
        var observed = try observe(
            ctx,
            facts.session_id,
            snapshotState(facts, null),
            null,
        );
        defer observed.deinit(ctx.alloc);
        var prepared = try ctx.managed_runtime.registerTty(ctx.alloc, .{
            .execution_id = facts.session_id,
            .command = command,
            .cwd = inspect.cwd,
            .state = observed.state,
            .output = observed.output,
            .replay_output = observed.replay_output,
            .next_cursor = observed.next_cursor,
            .output_incomplete = observed.output_incomplete,
            .error_name = if (observed.timed_out) "TimeoutExpired" else null,
            .max_output_bytes = ctx.max_output_bytes,
            .published_running = true,
            .replay_capability = ctx.owner,
        });
        defer prepared.deinit(ctx.alloc);
        try ctx.managed_runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        );
    }
}

fn resolveCompletedStatus(
    ctx: Context,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
    authority: contracts.AuthorityClaim,
) !managed_execution.SnapshotState {
    const status = switch (state) {
        .completed => |value| value,
        .running, .stopped, .lost => return state,
    };
    if (status != .finished) return state;

    var waited = try execute(ctx, .{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = 1,
        .authority = authority,
    } });
    defer waited.deinit(ctx.alloc);
    return switch (waited.view()) {
        .failure => state,
        .success => |success| switch (success) {
            .wait => |value| snapshotState(value.session, value.outcome),
            else => error.InvalidTerminalResult,
        },
    };
}

pub fn snapshotState(
    facts: contracts.SessionFacts,
    outcome: ?contracts.ReturnOutcome,
) managed_execution.SnapshotState {
    return switch (facts.lifecycle) {
        .starting, .running => if (outcome) |value|
            if (statusFromOutcome(value)) |status| .{ .completed = status } else .running
        else
            .running,
        .exited => .{ .completed = if (outcome) |value|
            statusFromOutcome(value) orelse .finished
        else
            .finished },
        .lost => .lost,
        .closed => .{ .stopped = if (outcome) |value| statusFromOutcome(value) else null },
    };
}

fn reconcileObservedState(
    current: managed_execution.SnapshotState,
    observed: managed_execution.SnapshotState,
) managed_execution.SnapshotState {
    return switch (current) {
        .running => observed,
        .completed => |status| if (status == .finished) switch (observed) {
            .completed => |refined| if (refined == .finished) current else observed,
            .running, .stopped, .lost => current,
        } else current,
        .stopped, .lost => current,
    };
}

fn statusFromOutcome(outcome: contracts.ReturnOutcome) ?@import("../execution/command_contract.zig").CommandStatus {
    return switch (outcome) {
        .exited => |code| .{ .exit_code = code },
        .signal => |signal| .{ .signal = signal },
        .started, .condition_met, .safety_ceiling, .cancelled => null,
    };
}

fn currentScreenText(
    ctx: Context,
    session_id: []const u8,
    authority: contracts.AuthorityClaim,
) ![]u8 {
    var screen = try execute(ctx, .{ .screen = .{
        .session_id = session_id,
        .authority = authority,
    } });
    defer screen.deinit(ctx.alloc);
    const snapshot = switch (screen.view()) {
        .failure => |failure| return mapTerminalFailure(failure.code),
        .success => |success| switch (success) {
            .screen => |value| value.snapshot,
            else => return error.InvalidTerminalResult,
        },
    };
    return renderScreenText(ctx.alloc, snapshot);
}

fn renderScreenText(
    alloc: Allocator,
    snapshot: contracts.RenderSnapshot,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const columns: usize = snapshot.dimensions.columns;
    const rows: usize = snapshot.dimensions.rows;
    var last_nonempty_row: ?usize = null;
    for (0..rows) |row| {
        const cells = snapshot.cells[row * columns ..][0..columns];
        for (cells) |cell| switch (cell.kind) {
            .single, .wide => last_nonempty_row = row,
            .blank, .continuation => {},
        };
    }
    const last = last_nonempty_row orelse return alloc.dupe(u8, "");
    for (0..last + 1) |row| {
        const cells = snapshot.cells[row * columns ..][0..columns];
        var last_column: usize = 0;
        for (cells, 0..) |cell, column| switch (cell.kind) {
            .single, .wide => last_column = column + 1,
            .blank, .continuation => {},
        };
        if (row != 0) try out.writer.writeByte('\n');
        for (cells[0..last_column]) |cell| switch (cell.kind) {
            .blank => try out.writer.writeByte(' '),
            .single, .wide => try out.writer.writeAll(cell.text),
            .continuation => {},
        };
    }
    return out.toOwnedSlice();
}

fn execute(ctx: Context, request: contracts.ActionRequest) !contracts.OwnedResult {
    return action_executor.execute(.{
        .alloc = ctx.alloc,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .runtime = ctx.terminal_client,
        .cancel_flag = ctx.cancel_flag,
    }, request);
}

fn reloadAuthority(
    ctx: Context,
    session_id: []const u8,
) !operation.OwnedAuthorityClaim {
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = identity.profileUser(&profile_user_buffer) orelse
        return error.TerminalAuthorityUnavailable;
    return store.reloadOwnerAuthorityClaim(ctx.alloc, ctx.owner, .{
        .terminal_session_id = session_id,
        .profile_user = profile_user,
        .durable_session_id = ctx.durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.transport_role,
        .actor = .agent,
    });
}

fn reloadOwnerCatalogAuthority(
    ctx: Context,
) !operation.OwnedOwnerCatalogClaim {
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = identity.profileUser(&profile_user_buffer) orelse
        return error.TerminalAuthorityUnavailable;
    return store.loadOrCreateOwnerCatalogClaim(ctx.alloc, ctx.owner, .{
        .profile_user = profile_user,
        .durable_session_id = ctx.durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.transport_role,
        .actor = .agent,
    });
}

fn mapTerminalFailure(code: contracts.StructuredErrorCode) anyerror {
    return switch (code) {
        .session_not_found => error.TerminalSessionNotFound,
        .session_lost => error.TerminalSessionLost,
        .authority_denied, .authority_retired => error.TerminalAuthorityLost,
        .cancelled => error.Cancelled,
        else => error.TerminalObservationFailed,
    };
}

fn isDefinitiveLoss(err: anyerror) bool {
    return err == error.TerminalSessionNotFound or
        err == error.TerminalSessionLost or
        err == error.TerminalAuthorityLost;
}

test "screen projection collapses blank repaint rows" {
    const cells = [_]contracts.RenderCell{
        .{},                               .{}, .{},                               .{},
        .{ .kind = .single, .text = "A" }, .{}, .{ .kind = .single, .text = "B" }, .{},
        .{},                               .{}, .{},                               .{},
    };
    const text = try renderScreenText(std.testing.allocator, .{
        .dimensions = .{ .rows = 3, .columns = 4 },
        .cursor = .{ .row = 1, .column = 3 },
        .cells = &cells,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\nA B", text);
}

test "observed status refines only an unknown completed state" {
    try std.testing.expectEqual(
        managed_execution.SnapshotState{ .completed = .{ .exit_code = 0 } },
        reconcileObservedState(
            .{ .completed = .finished },
            .{ .completed = .{ .exit_code = 0 } },
        ),
    );
    try std.testing.expectEqual(
        managed_execution.SnapshotState{ .completed = .{ .exit_code = 1 } },
        reconcileObservedState(
            .{ .completed = .{ .exit_code = 1 } },
            .{ .completed = .{ .exit_code = 0 } },
        ),
    );
    try std.testing.expectEqual(
        managed_execution.SnapshotState{ .completed = .finished },
        reconcileObservedState(.{ .completed = .finished }, .running),
    );
    try std.testing.expectEqual(
        managed_execution.SnapshotState{ .stopped = null },
        reconcileObservedState(
            .{ .stopped = null },
            .{ .completed = .{ .exit_code = 0 } },
        ),
    );
}
