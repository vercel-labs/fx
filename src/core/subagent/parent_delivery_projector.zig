const std = @import("std");
const runtime_deps = @import("../agent/runtime/deps.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const communication_store = @import("communication_store.zig");
const domain = @import("domain.zig");
const relationship_index = @import("relationship_index.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("../session/session_store.zig");

const Allocator = std.mem.Allocator;

pub const consumer_id = "parent-model";
const parent_turn_limit: usize = communication.max_delivery_page;
const parent_relationship_scan_limit =
    relationship_index.max_candidate_reads -
    session_store.relationship_migration_candidate_limit;

pub const Error = error{OutOfMemory};

const PrepareLimits = struct {
    turn: usize = parent_turn_limit,
    relationship_scan: usize = parent_relationship_scan_limit,
};

const PrepareCounters = struct {
    discovery_session_ids: usize = 0,
    discovery_control_reads: usize = 0,
    discovery_owned_ids: usize = 0,
    child_pages: usize = 0,
    delivery_candidates: usize = 0,
    accepted_deliveries: usize = 0,
    render_attempts: usize = 0,
};

pub fn prepare(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
) Error!?runtime_deps.PreparedParentTurnContext {
    return prepareWithCounters(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        null,
    );
}

fn prepareWithCounters(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
    counters: ?*PrepareCounters,
) Error!?runtime_deps.PreparedParentTurnContext {
    return prepareWithLimits(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        counters,
        .{},
    );
}

fn prepareWithLimits(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
    counters: ?*PrepareCounters,
    limits: PrepareLimits,
) Error!?runtime_deps.PreparedParentTurnContext {
    std.debug.assert(limits.turn > 0 and limits.turn <= parent_turn_limit);
    std.debug.assert(
        limits.relationship_scan > 0 and
            limits.relationship_scan <= parent_relationship_scan_limit,
    );
    domain.validateId(parent_session_id) catch return null;
    relationship_index.recoverForQuery(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            traceDiscoveryFailure(parent_session_id, err);
            return null;
        },
    };
    const migration = relationship_index.migrateLegacyPage(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            traceMigrationFailure(parent_session_id, err);
            break :blk relationship_index.MigrationStats{};
        },
    };
    if (counters) |stats| {
        stats.discovery_session_ids += migration.candidate_reads;
        stats.discovery_control_reads += migration.candidate_reads;
        stats.discovery_owned_ids += migration.candidate_reads;
    }
    var child_page = relationship_index.deliveryPage(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        limits.turn,
        limits.relationship_scan,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (err == error.InvalidIndex) {
                relationship_index.repairForQuery(
                    alloc,
                    sessions,
                    parent_session_id,
                    child_store_options,
                ) catch |repair_err| switch (repair_err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => traceDiscoveryFailure(
                        parent_session_id,
                        repair_err,
                    ),
                };
            }
            traceDiscoveryFailure(parent_session_id, err);
            return null;
        },
    };
    defer child_page.deinit(alloc);
    if (counters) |stats| {
        stats.discovery_session_ids += child_page.slots_read;
        stats.discovery_owned_ids += child_page.candidates.len;
    }
    sortRelationshipCandidates(child_page.candidates);

    var delivery_manager = communication_manager.Manager{
        .sessions = sessions,
        .child_store_options = child_store_options,
    };
    var deliveries: std.ArrayList(communication.ParentDeliveryPart) = .empty;
    defer freeDeliveries(alloc, &deliveries);
    var prepared_context: ?[]u8 = null;
    errdefer if (prepared_context) |context| alloc.free(context);

    var deferred_offset: ?u64 = null;
    var delivery_candidates: usize = 0;
    for (child_page.candidates, 0..) |candidate, candidate_index| {
        const remaining = limits.turn - delivery_candidates;
        if (remaining == 0) {
            for (child_page.candidates[candidate_index..]) |unprocessed| {
                noteDeferredOffset(
                    &deferred_offset,
                    unprocessed.slot,
                    child_page.start_offset,
                    child_page.high_watermark,
                );
            }
            break;
        }
        if (counters) |stats| stats.discovery_control_reads += 1;
        const later_candidates = child_page.candidates.len - candidate_index - 1;
        const reserved = @min(later_candidates, remaining - 1);
        const child_limit = remaining - reserved;
        // One bounded read gives this child its fair share of the remaining
        // global budget. Unread communication remains durable while relationship
        // discovery advances independently and returns after a full rotation.
        var page = delivery_manager.prepareParentBoundaryPage(
            alloc,
            candidate.child_id,
            consumer_id,
            parent_session_id,
            .turn_boundary,
            null,
            child_limit,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                tracePrepareSkip(candidate.child_id, parent_session_id, err);
                continue;
            },
        };
        defer page.deinit(alloc);
        delivery_candidates += page.deliveries.len;
        if (counters) |stats| {
            stats.child_pages += 1;
            stats.delivery_candidates += page.deliveries.len;
        }
        for (page.deliveries) |delivery| {
            var cloned = try delivery.clone(alloc);
            var appended = false;
            errdefer if (!appended) cloned.deinit(alloc);
            try deliveries.append(alloc, cloned);
            appended = true;
            const updated_context = communication.renderTrustedContext(
                alloc,
                deliveries.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TrustedContextTooLarge => {
                    var omitted = deliveries.items[deliveries.items.len - 1];
                    deliveries.items.len -= 1;
                    omitted.deinit(alloc);
                    noteDeferredOffset(
                        &deferred_offset,
                        candidate.slot,
                        child_page.start_offset,
                        child_page.high_watermark,
                    );
                    break;
                },
            };
            if (counters) |stats| {
                stats.accepted_deliveries += 1;
                stats.render_attempts += 1;
            }
            if (prepared_context) |previous| alloc.free(previous);
            prepared_context = updated_context;
        }
    }
    const next_delivery_offset = deferred_offset orelse child_page.next_offset;
    if (deliveries.items.len == 0) {
        relationship_index.advanceDelivery(
            alloc,
            sessions,
            parent_session_id,
            child_store_options,
            child_page.start_offset,
            next_delivery_offset,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => traceDiscoveryAdvanceFailure(parent_session_id, err),
        };
        return null;
    }

    const context = prepared_context orelse return null;
    prepared_context = null;
    errdefer alloc.free(context);
    const acknowledgements = try buildAcknowledgements(
        alloc,
        deliveries.items,
        child_page.start_offset,
        next_delivery_offset,
    );
    return .{
        .content = context,
        .acknowledgements = acknowledgements,
    };
}

pub fn acknowledge(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options,
    acknowledgements: []const runtime_deps.ParentTurnDeliveryAck,
) void {
    _ = acknowledgeWithRetirementSignal(
        alloc,
        sessions,
        child_store_options,
        acknowledgements,
    );
}

pub fn acknowledgeWithRetirementSignal(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options,
    acknowledgements: []const runtime_deps.ParentTurnDeliveryAck,
) bool {
    var delivery_manager = communication_manager.Manager{
        .sessions = sessions,
        .child_store_options = child_store_options,
    };
    var discovery_parent_id: ?[]const u8 = null;
    var discovery_start_offset: ?u64 = null;
    var discovery_next_offset: ?u64 = null;
    var all_acknowledged = true;
    var final_result_acknowledged = false;
    for (acknowledgements) |ack| {
        const signals_retirement = delivery_manager
            .acknowledgeParentBoundaryWithFinalResultSignal(
            alloc,
            ack.child_id,
            consumer_id,
            ack.target_session_id,
            .{
                .sequence = ack.through_sequence,
                .delivery_id = ack.delivery_id,
                .start_offset = ack.start_offset,
                .end_offset = ack.end_offset,
                .total_bytes = ack.total_bytes,
            },
        ) catch |err| {
            all_acknowledged = false;
            debug_trace.logf(
                "subagent",
                "parent delivery acknowledgement failed child_id={s} parent_id={s} sequence={d} outcome={s}",
                .{ ack.child_id, ack.target_session_id, ack.through_sequence, @errorName(err) },
            );
            continue;
        };
        final_result_acknowledged = signals_retirement or final_result_acknowledged;
        if (signals_retirement) {
            debug_trace.logf(
                "subagent",
                "final result acknowledgement committed child_id={s} parent_id={s}",
                .{ ack.child_id, ack.target_session_id },
            );
        }
        const start = ack.discovery_start_offset orelse {
            all_acknowledged = false;
            continue;
        };
        const next = ack.discovery_next_offset orelse {
            all_acknowledged = false;
            continue;
        };
        if (discovery_parent_id) |parent_id| {
            if (!std.mem.eql(u8, parent_id, ack.target_session_id) or
                discovery_start_offset.? != start or
                discovery_next_offset.? != next)
            {
                all_acknowledged = false;
            }
        } else {
            discovery_parent_id = ack.target_session_id;
            discovery_start_offset = start;
            discovery_next_offset = next;
        }
    }
    if (all_acknowledged) {
        relationship_index.advanceDelivery(
            alloc,
            sessions,
            discovery_parent_id orelse return final_result_acknowledged,
            child_store_options,
            discovery_start_offset orelse return final_result_acknowledged,
            discovery_next_offset orelse return final_result_acknowledged,
        ) catch |err| traceDiscoveryAdvanceFailure(
            discovery_parent_id orelse return final_result_acknowledged,
            err,
        );
    }
    return final_result_acknowledged;
}

pub fn deinitPrepared(
    alloc: Allocator,
    prepared: *runtime_deps.PreparedParentTurnContext,
) void {
    alloc.free(prepared.content);
    for (prepared.acknowledgements) |ack| {
        alloc.free(ack.child_id);
        alloc.free(ack.target_session_id);
        alloc.free(ack.delivery_id);
    }
    alloc.free(prepared.acknowledgements);
    prepared.* = undefined;
}

fn buildAcknowledgements(
    alloc: Allocator,
    deliveries: []const communication.ParentDeliveryPart,
    discovery_start_offset: u64,
    discovery_next_offset: u64,
) Error![]runtime_deps.ParentTurnDeliveryAck {
    var acknowledgements: std.ArrayList(runtime_deps.ParentTurnDeliveryAck) = .empty;
    errdefer {
        for (acknowledgements.items) |ack| {
            alloc.free(ack.child_id);
            alloc.free(ack.target_session_id);
            alloc.free(ack.delivery_id);
        }
        acknowledgements.deinit(alloc);
    }
    for (deliveries) |delivery| {
        const child_id = try alloc.dupe(u8, delivery.source_id);
        errdefer alloc.free(child_id);
        const target_session_id = try alloc.dupe(u8, delivery.target_id);
        errdefer alloc.free(target_session_id);
        const delivery_id = try alloc.dupe(u8, delivery.id);
        errdefer alloc.free(delivery_id);
        try acknowledgements.append(alloc, .{
            .child_id = child_id,
            .target_session_id = target_session_id,
            .through_sequence = delivery.sequence,
            .delivery_id = delivery_id,
            .start_offset = switch (delivery.payload) {
                .message => |message| message.offset,
                else => 0,
            },
            .end_offset = switch (delivery.payload) {
                .message => |message| message.end_offset,
                else => 0,
            },
            .total_bytes = switch (delivery.payload) {
                .message => |message| message.total_bytes,
                else => 0,
            },
            .discovery_start_offset = discovery_start_offset,
            .discovery_next_offset = discovery_next_offset,
        });
    }
    return acknowledgements.toOwnedSlice(alloc);
}

fn freeDeliveries(
    alloc: Allocator,
    deliveries: *std.ArrayList(communication.ParentDeliveryPart),
) void {
    for (deliveries.items) |*delivery| delivery.deinit(alloc);
    deliveries.deinit(alloc);
}

fn sortRelationshipCandidates(candidates: []relationship_index.Candidate) void {
    var index: usize = 1;
    while (index < candidates.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and
            std.mem.order(
                u8,
                candidates[cursor - 1].child_id,
                candidates[cursor].child_id,
            ) == .gt) : (cursor -= 1)
        {
            std.mem.swap(
                relationship_index.Candidate,
                &candidates[cursor - 1],
                &candidates[cursor],
            );
        }
    }
}

fn noteDeferredOffset(
    current: *?u64,
    candidate: u64,
    start: u64,
    high_watermark: u64,
) void {
    const selected = current.* orelse {
        current.* = candidate;
        return;
    };
    if (circularSlotDistance(candidate, start, high_watermark) <
        circularSlotDistance(selected, start, high_watermark))
    {
        current.* = candidate;
    }
}

fn circularSlotDistance(slot: u64, start: u64, high_watermark: u64) u64 {
    return if (slot >= start)
        slot - start
    else
        high_watermark - start + slot;
}

fn traceDiscoveryFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery child discovery failed parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn traceMigrationFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery relationship migration deferred parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn traceDiscoveryAdvanceFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery discovery cursor advance deferred parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn tracePrepareSkip(child_id: []const u8, parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery projection skipped child_id={s} parent_id={s} outcome={s}",
        .{ child_id, parent_id, @errorName(err) },
    );
}

fn testState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    const model = try alloc.dupe(u8, "test/model");
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{ .model = model, .effort = types.ReasoningEffort.literal("high"), .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const TestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !TestEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *TestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        var state = try testState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }

    fn indexSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        try self.commitSession(alloc, id, 2);
    }

    fn commitSession(
        self: *TestEnvironment,
        alloc: Allocator,
        id: []const u8,
        timestamp_ms: i64,
    ) !void {
        var loaded = try self.store.resumeForWrite(alloc, id);
        defer loaded.deinit(alloc);
        const user_text = try alloc.dupe(u8, "index migration candidate");
        const assistant = try alloc.dupe(u8, "indexed");
        const turn: session.HistoryTurn = .{ .assistant = .{
            .user = .{ .text = user_text },
            .assistant = assistant,
        } };
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = loaded.state.conversation_language,
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = turn,
            } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        );
        _ = loaded.publishCommitLifecycle(alloc);
        var page = try self.store.listResumablePage(alloc, null, null);
        page.deinit(alloc);
    }
};

const FailSyncFileAt = struct {
    calls: usize = 0,
    fail_at: usize,

    fn syncFile(raw: ?*anyopaque, _: std.Io.File) anyerror!void {
        const self: *FailSyncFileAt = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedSyncFailure;
    }
};

fn validateCreate(alloc: Allocator, name: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
    } });
}

fn validateSend(alloc: Allocator, id: []const u8, content: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = id,
        .content = content,
    } } });
}

fn validateDetach(alloc: Allocator, id: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = id,
    } });
}

fn preparePersistentChild(
    alloc: Allocator,
    env: *TestEnvironment,
    parent_id: []const u8,
    child_id: []const u8,
    name: []const u8,
) !void {
    try env.createSession(alloc, child_id);
    var manager = @import("manager.zig").Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, name);
    defer create.deinit(alloc);
    var result = try manager.execute(alloc, create, .{
        .actor_id = parent_id,
        .operation_id = name,
        .created_child_id = child_id,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
}

fn sendFromChild(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    parent_id: []const u8,
    operation_id: []const u8,
    content: []const u8,
) !void {
    var manager = @import("manager.zig").Manager{ .sessions = &env.store };
    var send = try validateSend(alloc, parent_id, content);
    defer send.deinit(alloc);
    var result = try manager.execute(alloc, send, .{
        .actor_id = child_id,
        .operation_id = operation_id,
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
}

fn expectNoPrepared(
    alloc: Allocator,
    env: *TestEnvironment,
    parent_id: []const u8,
) !void {
    const prepared = try prepare(alloc, &env.store, parent_id, .{});
    try std.testing.expect(prepared == null);
}

test "parent delivery projector prepares one trusted envelope and acknowledges after insertion" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    try sendFromChild(alloc, &env, "child", "parent", "op-message", "child status");

    var first = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &first);
    try std.testing.expect(std.mem.find(u8, first.content, "<subagent_deliveries") != null);
    try std.testing.expect(std.mem.find(u8, first.content, "child status") != null);
    try std.testing.expectEqual(@as(usize, 1), first.acknowledgements.len);
    try std.testing.expectEqualStrings("child", first.acknowledgements[0].child_id);
    try std.testing.expectEqualStrings("parent", first.acknowledgements[0].target_session_id);

    var repeated = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &repeated);
    try std.testing.expectEqualStrings(first.content, repeated.content);

    acknowledge(alloc, &env.store, .{}, first.acknowledgements);
    acknowledge(alloc, &env.store, .{}, first.acknowledgements);
    try expectNoPrepared(alloc, &env, "parent");

    var query = communication_manager.Manager{ .sessions = &env.store };
    var human_page = try query.page(alloc, "child", "human", "parent", null, 10);
    defer human_page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), human_page.deliveries.len);
    try std.testing.expectEqualStrings("child status", human_page.deliveries[0].payload.message);

    var loaded_parent = try env.store.loadReadOnly(alloc, "parent");
    defer loaded_parent.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded_parent.history.len);
}

test "parent delivery acknowledgement reports stable final result" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child",
        .{},
    );
    defer capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "child",
    };
    try std.testing.expect(try communication_manager.reconcileFinalResultLocked(
        alloc,
        communication_state,
        .{
            .child_id = "child",
            .parent_id = "parent",
            .work_id = "work",
            .timestamp_ms = 2,
            .content = "final result",
        },
    ));

    var prepared = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(acknowledgeWithRetirementSignal(
        alloc,
        &env.store,
        .{},
        prepared.acknowledgements,
    ));
    try expectNoPrepared(alloc, &env, "parent");
}

test "parent delivery projector acknowledges bounded approval before later delivery" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    const label = try alloc.alloc(u8, 4 * 1024);
    defer alloc.free(label);
    @memset(label, 0x01);

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "child",
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "child",
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var ledger = try communication.Ledger.init(alloc, "child");
        defer ledger.deinit(alloc);
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = "escape-heavy-approval",
            .source_id = "child",
            .target_id = "parent",
            .work_id = "approval-work",
            .operation_id = "approval-operation",
            .timestamp_ms = 1,
            .payload = .{ .approval = label },
        });
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = "delivery-after-approval",
            .source_id = "child",
            .target_id = "parent",
            .timestamp_ms = 2,
            .payload = .{ .message = "progress after bounded approval" },
        });
        try store.save(alloc, ledger);
    }

    var approval = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &approval);
    try std.testing.expect(approval.content.len <= communication.max_trusted_context_bytes);
    try std.testing.expectEqual(@as(usize, 1), approval.acknowledgements.len);
    try std.testing.expectEqualStrings(
        "escape-heavy-approval",
        approval.acknowledgements[0].delivery_id,
    );
    try std.testing.expect(std.mem.find(u8, approval.content, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"total_bytes\":4096") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"source_id\":\"child\"") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"target_id\":\"parent\"") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"work_id\":\"approval-work\"") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"operation_id\":\"approval-operation\"") != null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"status\"") == null);
    try std.testing.expect(std.mem.find(u8, approval.content, "\"grants\"") == null);
    try std.testing.expect(std.mem.find(u8, approval.content, "delivery-after-approval") == null);
    acknowledge(alloc, &env.store, .{}, approval.acknowledgements);

    var query = communication_manager.Manager{
        .sessions = &env.store,
        .child_store_options = .{},
    };
    var human = try query.page(alloc, "child", "human", "parent", null, 1);
    defer human.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), human.deliveries.len);
    try std.testing.expectEqualStrings("escape-heavy-approval", human.deliveries[0].id);

    var progress = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &progress);
    try std.testing.expectEqual(@as(usize, 1), progress.acknowledgements.len);
    try std.testing.expectEqualStrings(
        "delivery-after-approval",
        progress.acknowledgements[0].delivery_id,
    );
    try std.testing.expect(
        std.mem.find(u8, progress.content, "progress after bounded approval") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, progress.content, "escape-heavy-approval") == null,
    );
    acknowledge(alloc, &env.store, .{}, progress.acknowledgements);
    try expectNoPrepared(alloc, &env, "parent");
}

test "parent delivery projector acknowledges retention gap then resumes after restart" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child",
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "child",
    };
    {
        var lock = try store.acquireLock();
        defer lock.release();
        var ledger = try communication.Ledger.init(alloc, "child");
        defer ledger.deinit(alloc);
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = "evicted-parent-message",
            .source_id = "child",
            .target_id = "parent",
            .timestamp_ms = 1,
            .payload = .{ .message = "evicted" },
        });
        for (0..communication.max_deliveries) |index| {
            var id_buffer: [64]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buffer, "other-target-{d}", .{index});
            _ = try communication.appendDelivery(alloc, &ledger, .{
                .id = id,
                .source_id = "child",
                .target_id = "other-parent",
                .timestamp_ms = @intCast(index + 2),
                .payload = .{ .interval = .{
                    .state = .running,
                    .coalesced_ticks = 1,
                } },
            });
        }
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = "retained-parent-terminal",
            .source_id = "child",
            .target_id = "parent",
            .timestamp_ms = @intCast(communication.max_deliveries + 2),
            .payload = .{ .terminal = .completed },
        });
        try store.save(alloc, ledger);
    }

    var gap = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &gap);
    try std.testing.expectEqual(@as(usize, 1), gap.acknowledgements.len);
    try std.testing.expect(
        std.mem.find(u8, gap.content, "\"retention_gap\"") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, gap.content, "retained-parent-terminal") == null,
    );
    acknowledge(alloc, &env.store, .{}, gap.acknowledgements);

    var restarted = try session_store.Store.initFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer restarted.deinit(alloc);
    var terminal = (try prepare(alloc, &restarted, "parent", .{})).?;
    defer deinitPrepared(alloc, &terminal);
    try std.testing.expect(
        std.mem.find(u8, terminal.content, "retained-parent-terminal") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, terminal.content, "\"retention_gap\"") == null,
    );
}

test "parent delivery projector prepares and acknowledges two ordered deliveries from one child" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    try sendFromChild(alloc, &env, "child", "parent", "op-first", "first update");
    try sendFromChild(alloc, &env, "child", "parent", "op-second", "second update");

    var prepared = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expectEqual(@as(usize, 2), prepared.acknowledgements.len);
    try std.testing.expectEqualStrings(
        "op-first",
        prepared.acknowledgements[0].delivery_id,
    );
    try std.testing.expectEqualStrings(
        "op-second",
        prepared.acknowledgements[1].delivery_id,
    );
    const first_index = std.mem.find(u8, prepared.content, "first update") orelse
        return error.TestExpectedEqual;
    const second_index = std.mem.find(u8, prepared.content, "second update") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(first_index < second_index);

    var replay = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &replay);
    try std.testing.expectEqualStrings(prepared.content, replay.content);
    try std.testing.expectEqual(
        prepared.acknowledgements[0].through_sequence,
        replay.acknowledgements[0].through_sequence,
    );
    try std.testing.expectEqual(
        prepared.acknowledgements[1].through_sequence,
        replay.acknowledgements[1].through_sequence,
    );

    acknowledge(alloc, &env.store, .{}, prepared.acknowledgements);
    try expectNoPrepared(alloc, &env, "parent");
}

test "parent delivery projector skips one non-fitting child delivery without starving another child" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child-a", "child-a");
    try preparePersistentChild(alloc, &env, "parent", "child-b", "child-b");
    const large_a = try alloc.alloc(u8, 9 * 1024);
    defer alloc.free(large_a);
    @memset(large_a, 'a');
    const large_b = try alloc.alloc(u8, 9 * 1024);
    defer alloc.free(large_b);
    @memset(large_b, 'b');
    try sendFromChild(alloc, &env, "child-a", "parent", "op-a-first", large_a);
    try sendFromChild(alloc, &env, "child-a", "parent", "op-a-second", large_b);
    try sendFromChild(
        alloc,
        &env,
        "child-b",
        "parent",
        "op-b",
        "fair child update",
    );

    var counters = PrepareCounters{};
    var prepared = (try prepareWithCounters(
        alloc,
        &env.store,
        "parent",
        .{},
        &counters,
    )).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(prepared.content.len <= communication.max_trusted_context_bytes);
    try std.testing.expectEqual(@as(usize, 3), counters.delivery_candidates);
    try std.testing.expectEqual(@as(usize, 2), prepared.acknowledgements.len);
    try std.testing.expectEqualStrings(
        "op-a-first",
        prepared.acknowledgements[0].delivery_id,
    );
    try std.testing.expectEqualStrings(
        "op-b",
        prepared.acknowledgements[1].delivery_id,
    );
    try std.testing.expect(std.mem.find(u8, prepared.content, "fair child update") != null);
    try std.testing.expect(std.mem.find(u8, prepared.content, "op-a-second") == null);

    acknowledge(alloc, &env.store, .{}, prepared.acknowledgements);
    var deferred = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &deferred);
    try std.testing.expectEqual(@as(usize, 1), deferred.acknowledgements.len);
    try std.testing.expectEqualStrings(
        "op-a-second",
        deferred.acknowledgements[0].delivery_id,
    );
}

test "parent delivery projector persists and resumes exact message parts" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    const content = try alloc.alloc(u8, domain.max_message_bytes);
    defer alloc.free(content);
    @memset(content, 'x');
    try sendFromChild(
        alloc,
        &env,
        "child",
        "parent",
        "op-large-message",
        content,
    );

    var first = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &first);
    try std.testing.expectEqual(@as(usize, 1), first.acknowledgements.len);
    try std.testing.expect(first.content.len <= communication.max_trusted_context_bytes);
    try std.testing.expectEqual(@as(u64, 0), first.acknowledgements[0].start_offset);
    try std.testing.expect(
        first.acknowledgements[0].end_offset <
            first.acknowledgements[0].total_bytes,
    );

    var replay = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &replay);
    try std.testing.expectEqualStrings(first.content, replay.content);
    try std.testing.expectEqual(
        first.acknowledgements[0].end_offset,
        replay.acknowledgements[0].end_offset,
    );

    {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            "child",
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "child",
        };
        var before_ack = try store.load(alloc);
        defer before_ack.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), before_ack.cursors.len);
    }

    acknowledge(alloc, &env.store, .{}, first.acknowledgements);
    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "child",
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "child",
    };
    var persisted = try store.load(alloc);
    defer persisted.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), persisted.cursors.len);
    try std.testing.expectEqual(
        first.acknowledgements[0].through_sequence,
        persisted.cursors[0].partial_message_sequence,
    );
    try std.testing.expectEqual(
        first.acknowledgements[0].end_offset,
        persisted.cursors[0].partial_message_offset,
    );

    var expected_offset = first.acknowledgements[0].end_offset;
    var part_count: usize = 1;
    while (true) {
        var next = (try prepare(alloc, &env.store, "parent", .{})) orelse break;
        defer deinitPrepared(alloc, &next);
        try std.testing.expectEqual(@as(usize, 1), next.acknowledgements.len);
        try std.testing.expectEqual(
            expected_offset,
            next.acknowledgements[0].start_offset,
        );
        expected_offset = next.acknowledgements[0].end_offset;
        acknowledge(alloc, &env.store, .{}, next.acknowledgements);
        part_count += 1;
    }
    try std.testing.expect(part_count > 1);
    try std.testing.expectEqual(@as(u64, content.len), expected_offset);

    var query = communication_manager.Manager{ .sessions = &env.store };
    var human = try query.page(alloc, "child", "human", "parent", null, 1);
    defer human.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        content,
        human.deliveries[0].payload.message,
    );
}

test "parent delivery projector aggregates direct children deterministically within the trusted bound" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child-b", "child-b");
    try preparePersistentChild(alloc, &env, "parent", "child-a", "child-a");
    try sendFromChild(alloc, &env, "child-b", "parent", "op-b", "from child b");
    try sendFromChild(alloc, &env, "child-a", "parent", "op-a", "from child a");

    var prepared = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(prepared.content.len <= communication.max_trusted_context_bytes);
    const index_a = std.mem.find(u8, prepared.content, "from child a") orelse
        return error.TestExpectedEqual;
    const index_b = std.mem.find(u8, prepared.content, "from child b") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(index_a < index_b);
    try std.testing.expectEqual(@as(usize, 2), prepared.acknowledgements.len);
    try std.testing.expectEqualStrings("child-a", prepared.acknowledgements[0].child_id);
    try std.testing.expectEqualStrings("child-b", prepared.acknowledgements[1].child_id);
}

test "parent delivery projector bounds direct children before acknowledgement" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    const child_count = communication.max_delivery_page + 1;
    for (0..child_count) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "child-{d:0>3}", .{index});
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(&operation_buffer, "op-{d:0>3}", .{index});
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buffer, "payload-{d:0>3}", .{index});
        try preparePersistentChild(alloc, &env, "parent", child_id, child_id);
        try sendFromChild(alloc, &env, child_id, "parent", operation_id, payload);
    }

    var counters = PrepareCounters{};
    var prepared = (try prepareWithCounters(
        alloc,
        &env.store,
        "parent",
        .{},
        &counters,
    )).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(prepared.content.len <= communication.max_trusted_context_bytes);
    try std.testing.expect(prepared.acknowledgements.len > 0);
    try std.testing.expect(prepared.acknowledgements.len <= communication.max_delivery_page);
    try std.testing.expect(counters.delivery_candidates <= communication.max_delivery_page);
    try std.testing.expectEqual(prepared.acknowledgements.len, counters.accepted_deliveries);
    try std.testing.expect(counters.child_pages <= counters.delivery_candidates + 1);
    try std.testing.expect(std.mem.find(u8, prepared.content, "payload-000") != null);
    const last_included_index = prepared.acknowledgements.len - 1;
    const first_excluded_index = prepared.acknowledgements.len;
    const last_included_payload = try std.fmt.allocPrint(
        alloc,
        "payload-{d:0>3}",
        .{last_included_index},
    );
    defer alloc.free(last_included_payload);
    const first_excluded_payload = try std.fmt.allocPrint(
        alloc,
        "payload-{d:0>3}",
        .{first_excluded_index},
    );
    defer alloc.free(first_excluded_payload);
    const last_included_child = try std.fmt.allocPrint(
        alloc,
        "child-{d:0>3}",
        .{last_included_index},
    );
    defer alloc.free(last_included_child);
    const first_excluded_child = try std.fmt.allocPrint(
        alloc,
        "child-{d:0>3}",
        .{first_excluded_index},
    );
    defer alloc.free(first_excluded_child);
    try std.testing.expect(std.mem.find(u8, prepared.content, last_included_payload) != null);
    try std.testing.expect(std.mem.find(u8, prepared.content, first_excluded_payload) == null);
    try std.testing.expectEqualStrings("child-000", prepared.acknowledgements[0].child_id);
    try std.testing.expectEqualStrings(
        last_included_child,
        prepared.acknowledgements[prepared.acknowledgements.len - 1].child_id,
    );

    var exact_replay = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &exact_replay);
    try std.testing.expectEqualStrings(prepared.content, exact_replay.content);
    try std.testing.expectEqual(
        prepared.acknowledgements.len,
        exact_replay.acknowledgements.len,
    );

    acknowledge(alloc, &env.store, .{}, prepared.acknowledgements);
    var next = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &next);
    try std.testing.expect(next.content.len <= communication.max_trusted_context_bytes);
    try std.testing.expect(std.mem.find(u8, next.content, "payload-000") == null);
    try std.testing.expect(std.mem.find(u8, next.content, first_excluded_payload) != null);
    try std.testing.expectEqualStrings(first_excluded_child, next.acknowledgements[0].child_id);
}

test "parent delivery projector bounds discovery before output pagination" {
    const alloc = std.testing.allocator;
    const limits = PrepareLimits{ .turn = 8, .relationship_scan = 8 };
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    try sendFromChild(alloc, &env, "child", "parent", "op-message", "bounded");

    for (0..limits.relationship_scan + 1) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "ordinary-{d:0>4}", .{index});
        try env.createSession(alloc, id);
    }

    var counters = PrepareCounters{};
    var prepared = (try prepareWithLimits(
        alloc,
        &env.store,
        "parent",
        .{},
        &counters,
        limits,
    )).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(counters.discovery_session_ids <= limits.relationship_scan);
    try std.testing.expect(counters.discovery_control_reads <= limits.relationship_scan);
    try std.testing.expect(counters.discovery_owned_ids <= limits.relationship_scan * 2);
}

test "parent delivery projector resumes bounded child discovery fairly after restart" {
    const alloc = std.testing.allocator;
    const limits = PrepareLimits{ .turn = 8, .relationship_scan = 8 };
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    const child_count = limits.relationship_scan + 1;
    for (0..child_count) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "child-{d:0>3}", .{index});
        try preparePersistentChild(alloc, &env, "parent", child_id, child_id);
    }
    var late_child_buffer: [32]u8 = undefined;
    const late_child_id = try std.fmt.bufPrint(
        &late_child_buffer,
        "child-{d:0>3}",
        .{child_count - 1},
    );
    try sendFromChild(
        alloc,
        &env,
        late_child_id,
        "parent",
        "late-message",
        "late bounded delivery",
    );

    for (0..2) |turn| {
        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer restarted.deinit(alloc);
        var counters = PrepareCounters{};
        var prepared = try prepareWithLimits(
            alloc,
            &restarted,
            "parent",
            .{},
            &counters,
            limits,
        );
        defer if (prepared) |*value| deinitPrepared(alloc, value);
        try std.testing.expect(
            counters.discovery_session_ids <= limits.relationship_scan,
        );
        try std.testing.expect(
            counters.discovery_control_reads <= limits.relationship_scan,
        );
        if (turn == 0) {
            try std.testing.expect(prepared == null);
        } else {
            try std.testing.expect(prepared != null);
            try std.testing.expect(std.mem.find(
                u8,
                prepared.?.content,
                "late bounded delivery",
            ) != null);
        }
    }
}

test "parent delivery projector rotates past a backlogged first-page child across restarts" {
    const alloc = std.testing.allocator;
    const limits = PrepareLimits{ .turn = 8, .relationship_scan = 8 };
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");

    const child_count = limits.turn + 1;
    for (0..child_count) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "child-{d:0>3}", .{index});
        try preparePersistentChild(alloc, &env, "parent", child_id, child_id);
    }
    for (0..4) |index| {
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(
            &operation_buffer,
            "early-operation-{d:0>2}",
            .{index},
        );
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(
            &payload_buffer,
            "early-backlog-{d:0>2}",
            .{index},
        );
        try sendFromChild(
            alloc,
            &env,
            "child-000",
            "parent",
            operation_id,
            payload,
        );
    }
    try sendFromChild(
        alloc,
        &env,
        "child-008",
        "parent",
        "late-operation",
        "late-page-delivery",
    );

    const relationship_page_limit =
        @min(limits.turn, limits.relationship_scan);
    const rotation_bound =
        (child_count + relationship_page_limit - 1) /
        relationship_page_limit;
    var late_seen = false;
    for (0..rotation_bound) |turn| {
        {
            var restarted = try session_store.Store.initFromHome(
                alloc,
                env.home,
                env.workspace,
            );
            defer restarted.deinit(alloc);
            var delivery_manager = communication_manager.Manager{
                .sessions = &restarted,
            };
            var early_page = try delivery_manager.prepareParentBoundaryPage(
                alloc,
                "child-000",
                consumer_id,
                "parent",
                .turn_boundary,
                null,
                1,
            );
            defer early_page.deinit(alloc);
            try std.testing.expect(early_page.has_more);
        }
        var prepared = blk: {
            var restarted = try session_store.Store.initFromHome(
                alloc,
                env.home,
                env.workspace,
            );
            defer restarted.deinit(alloc);
            break :blk (try prepareWithLimits(
                alloc,
                &restarted,
                "parent",
                .{},
                null,
                limits,
            )).?;
        };
        defer deinitPrepared(alloc, &prepared);
        try std.testing.expect(std.mem.find(
            u8,
            prepared.content,
            "<subagent_deliveries",
        ) != null);

        var replay = blk: {
            var restarted = try session_store.Store.initFromHome(
                alloc,
                env.home,
                env.workspace,
            );
            defer restarted.deinit(alloc);
            break :blk (try prepareWithLimits(
                alloc,
                &restarted,
                "parent",
                .{},
                null,
                limits,
            )).?;
        };
        defer deinitPrepared(alloc, &replay);
        try std.testing.expectEqualStrings(prepared.content, replay.content);
        try std.testing.expectEqual(
            prepared.acknowledgements.len,
            replay.acknowledgements.len,
        );
        for (prepared.acknowledgements, replay.acknowledgements) |expected, actual| {
            try std.testing.expectEqualStrings(
                expected.delivery_id,
                actual.delivery_id,
            );
            try std.testing.expectEqual(
                expected.through_sequence,
                actual.through_sequence,
            );
        }
        late_seen = late_seen or
            std.mem.find(u8, replay.content, "late-page-delivery") != null;

        {
            var restarted = try session_store.Store.initFromHome(
                alloc,
                env.home,
                env.workspace,
            );
            defer restarted.deinit(alloc);
            if (turn == 0) {
                try std.testing.expectEqual(
                    @as(usize, 1),
                    prepared.acknowledgements.len,
                );
                var partial_acknowledgement = prepared.acknowledgements[0];
                partial_acknowledgement.discovery_next_offset = null;
                acknowledge(
                    alloc,
                    &restarted,
                    .{},
                    &.{partial_acknowledgement},
                );
                var retained_relationship_page =
                    try relationship_index.deliveryPage(
                        alloc,
                        &restarted,
                        "parent",
                        .{},
                        limits.turn,
                        limits.relationship_scan,
                    );
                defer retained_relationship_page.deinit(alloc);
                try std.testing.expectEqual(
                    @as(u64, 0),
                    retained_relationship_page.start_offset,
                );
            }
            acknowledge(
                alloc,
                &restarted,
                .{},
                replay.acknowledgements,
            );
            if (turn == 0) {
                var next_relationship_page = try relationship_index.deliveryPage(
                    alloc,
                    &restarted,
                    "parent",
                    .{},
                    limits.turn,
                    limits.relationship_scan,
                );
                defer next_relationship_page.deinit(alloc);
                try std.testing.expect(next_relationship_page.start_offset != 0);
            }
        }
        if (late_seen) break;
    }
    try std.testing.expect(late_seen);

    var deferred = blk: {
        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer restarted.deinit(alloc);
        break :blk (try prepareWithLimits(
            alloc,
            &restarted,
            "parent",
            .{},
            null,
            limits,
        )).?;
    };
    defer deinitPrepared(alloc, &deferred);
    try std.testing.expect(deferred.acknowledgements.len > 0);
    try std.testing.expectEqualStrings(
        "child-000",
        deferred.acknowledgements[0].child_id,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        deferred.acknowledgements[0].delivery_id,
        "early-operation-",
    ));
}

test "parent delivery projector migrates a legacy control edge in one bounded page" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "legacy-child", "legacy-child");
    try env.indexSession(alloc, "legacy-child");
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "parent",
        "legacy-child",
        .{},
    ));
    try sendFromChild(
        alloc,
        &env,
        "legacy-child",
        "parent",
        "legacy-message",
        "legacy edge recovered",
    );

    var counters = PrepareCounters{};
    var prepared = (try prepareWithCounters(
        alloc,
        &env.store,
        "parent",
        .{},
        &counters,
    )).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(std.mem.find(
        u8,
        prepared.content,
        "legacy edge recovered",
    ) != null);
    try std.testing.expect(counters.discovery_session_ids <=
        relationship_index.max_candidate_reads);
    try std.testing.expect(counters.discovery_control_reads <=
        relationship_index.max_candidate_reads);
}

test "parent delivery query recovers every pending allocate boundary exactly once" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);

    for (2..5) |fail_at| {
        var parent_buffer: [32]u8 = undefined;
        const parent_id = try std.fmt.bufPrint(
            &parent_buffer,
            "recover-parent-{d}",
            .{fail_at},
        );
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(
            &child_buffer,
            "recover-child-{d}",
            .{fail_at},
        );
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(
            &operation_buffer,
            "recover-message-{d}",
            .{fail_at},
        );
        try env.createSession(alloc, parent_id);
        try preparePersistentChild(
            alloc,
            &env,
            parent_id,
            child_id,
            child_id,
        );
        try sendFromChild(
            alloc,
            &env,
            child_id,
            parent_id,
            operation_id,
            "recover pending allocate",
        );
        try std.testing.expect(try relationship_index.removeChild(
            alloc,
            &env.store,
            parent_id,
            child_id,
            .{},
        ));

        var failure = FailSyncFileAt{ .fail_at = fail_at };
        try std.testing.expectError(
            error.StoreUnavailable,
            relationship_index.ensureChild(
                alloc,
                &env.store,
                parent_id,
                child_id,
                .{ .replace_ops = .{
                    .ctx = &failure,
                    .sync_file = FailSyncFileAt.syncFile,
                } },
            ),
        );

        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer restarted.deinit(alloc);
        var prepared = (try prepare(
            alloc,
            &restarted,
            parent_id,
            .{},
        )).?;
        defer deinitPrepared(alloc, &prepared);
        try std.testing.expect(std.mem.find(
            u8,
            prepared.content,
            "recover pending allocate",
        ) != null);
        acknowledge(alloc, &restarted, .{}, prepared.acknowledgements);
        const after_ack = try prepare(alloc, &restarted, parent_id, .{});
        try std.testing.expect(after_ack == null);
    }
}

test "parent delivery legacy migration survives index republication and restart" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "migration-parent");
    try preparePersistentChild(
        alloc,
        &env,
        "migration-parent",
        "legacy-child",
        "legacy-child",
    );
    try env.indexSession(alloc, "legacy-child");
    for (0..64) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(
            &id_buffer,
            "ordinary-{d:0>3}",
            .{index},
        );
        try env.createSession(alloc, id);
        try env.indexSession(alloc, id);
    }
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "migration-parent",
        "legacy-child",
        .{},
    ));
    try sendFromChild(
        alloc,
        &env,
        "legacy-child",
        "migration-parent",
        "legacy-late-message",
        "legacy child beyond stable pages",
    );

    var discovered = false;
    for (0..8) |turn| {
        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        var prepared = try prepare(
            alloc,
            &restarted,
            "migration-parent",
            .{},
        );
        if (prepared) |*value| {
            defer deinitPrepared(alloc, value);
            discovered = std.mem.find(
                u8,
                value.content,
                "legacy child beyond stable pages",
            ) != null;
        }
        restarted.deinit(alloc);
        if (discovered) break;
        try env.commitSession(
            alloc,
            "migration-parent",
            100 + @as(i64, @intCast(turn)),
        );
    }
    try std.testing.expect(discovered);
}

test "parent delivery projector ignores detached children without acknowledging them" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    try sendFromChild(alloc, &env, "child", "parent", "op-message", "private payload");

    var manager = @import("manager.zig").Manager{ .sessions = &env.store };
    var detach = try validateDetach(alloc, "child");
    defer detach.deinit(alloc);
    var detached = try manager.execute(alloc, detach, .{
        .actor_id = "parent",
        .operation_id = "op-detach",
        .timestamp_ms = 3,
    });
    defer detached.deinit(alloc);
    try std.testing.expect(detached == .receipt);

    try expectNoPrepared(alloc, &env, "parent");

    var query = communication_manager.Manager{ .sessions = &env.store };
    try std.testing.expectError(
        error.InvalidRequest,
        query.page(alloc, "child", "human", "parent", null, 10),
    );
}

test "parent delivery projector OOM leaves delivery available for a later turn" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try preparePersistentChild(alloc, &env, "parent", "child", "child");
    try sendFromChild(alloc, &env, "child", "parent", "op-message", "retry me");
    try sendFromChild(
        alloc,
        &env,
        "child",
        "parent",
        "op-message-two",
        "retry me too",
    );

    var observed_oom = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        var maybe_prepared = prepare(failing.allocator(), &env.store, "parent", .{}) catch |err| switch (err) {
            error.OutOfMemory => {
                observed_oom = true;
                continue;
            },
        };
        if (maybe_prepared) |*prepared| {
            deinitPrepared(failing.allocator(), prepared);
        }
    }
    try std.testing.expect(observed_oom);

    var prepared = (try prepare(alloc, &env.store, "parent", .{})).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(std.mem.find(u8, prepared.content, "retry me") != null);
    try std.testing.expect(std.mem.find(u8, prepared.content, "retry me too") != null);
    try std.testing.expectEqual(@as(usize, 2), prepared.acknowledgements.len);
}

test "parent delivery projector delivers grandchild messages to nested child turns" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root");
    try preparePersistentChild(alloc, &env, "root", "child", "child");
    try preparePersistentChild(alloc, &env, "child", "grandchild", "grandchild");
    try sendFromChild(
        alloc,
        &env,
        "grandchild",
        "child",
        "op-grandchild-message",
        "grandchild report",
    );

    var prepared = (try prepare(alloc, &env.store, "child", .{})).?;
    defer deinitPrepared(alloc, &prepared);
    try std.testing.expect(std.mem.find(u8, prepared.content, "grandchild report") != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.acknowledgements.len);
    try std.testing.expectEqualStrings("grandchild", prepared.acknowledgements[0].child_id);
    try std.testing.expectEqualStrings("child", prepared.acknowledgements[0].target_session_id);
}
