const std = @import("std");
const approval_persistence = @import("approval_persistence.zig");
const authority = @import("authority.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const communication = @import("communication.zig");
const communication_manager_mod = @import("communication_manager.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const tool_result = @import("tool_result.zig");
const work_events = @import("work_events.zig");
const io_mod = @import("../shared/io.zig");
const relationship_index = @import("relationship_index.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const max_ancestry_depth: usize = 1024;
const max_inspected_history_text_bytes: usize = 32 * 1024;
const max_inspected_history_field_bytes: usize = 16 * 1024;

const BootstrapError = error{
    OutOfMemory,
    SessionNotFound,
    SessionPathUnsafe,
    StoreFailure,
};

const RelationshipDiscoveryError = error{
    OutOfMemory,
    RelationshipCycle,
    GraphTooDeep,
    SessionNotFound,
    ControlRecordInvalid,
    ControlRecordTooLarge,
    ControlPathUnsafe,
    StoreFailure,
};

pub const FailureCode = enum {
    caller_unavailable,
    child_unavailable,
    control_not_found,
    operation_id_required,
    invalid_operation_id,
    operation_conflict,
    operation_replay_expired,
    stale_generation,
    invalid_state,
    relationship_authorization_required,
    relationship_cycle,
    relationship_already_parented,
    relationship_missing_parent,
    one_off_not_messageable,
    milestone_requires_active_work,
    invalid_milestone_caller,
    no_active_work,
    undeclared_milestone,
    control_lock_busy,
    control_lock_unsupported,
    control_record_invalid,
    control_record_too_large,
    communication_capacity_exceeded,
    control_path_unsafe,
    control_commit_indeterminate,
    session_not_found,
    graph_changed,
    graph_too_deep,
    invalid_snapshot_query,
    generation_exhausted,
    store_failure,
};

pub const Failure = struct {
    code: FailureCode,
    retryable: bool = false,
};

pub const InspectedHistoryKind = enum {
    conversation,
    background_command,
    interrupted,
    compacted_summary,
};

pub const InspectedHistoryTurn = struct {
    kind: InspectedHistoryKind,
    work_id: ?[]u8 = null,
    user: ?[]u8 = null,
    assistant: ?[]u8 = null,
    user_truncated: bool = false,
    assistant_truncated: bool = false,

    pub fn deinit(self: *InspectedHistoryTurn, alloc: Allocator) void {
        if (self.work_id) |value| alloc.free(value);
        if (self.user) |value| alloc.free(value);
        if (self.assistant) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const InspectionSourceError = enum {
    not_found,
    invalid,
    unavailable,
};

pub const InspectedToolActivity = struct {
    sequence: u64,
    revision: u64,
    timestamp_ms: i64,
    work_id: ?[]u8 = null,
    tool_name: []u8,
    phase: communication.ToolActivityPhase,

    pub fn deinit(self: *InspectedToolActivity, alloc: Allocator) void {
        if (self.work_id) |value| alloc.free(value);
        alloc.free(self.tool_name);
        self.* = undefined;
    }
};

pub const WorkFailure = struct {
    work_item_id: []const u8,
    reason: []const u8,
};

pub fn latestWorkFailure(events: []const domain.Event) ?WorkFailure {
    var index = events.len;
    while (index > 0) {
        index -= 1;
        switch (events[index].kind) {
            .work_transition => |transition| {
                return switch (transition.current) {
                    .failed => .{
                        .work_item_id = transition.work_item_id,
                        .reason = transition.reason orelse continue,
                    },
                    .completed, .cancelled, .interrupted => null,
                    .pending, .running, .awaiting_approval => continue,
                };
            },
            else => {},
        }
    }
    return null;
}

test "latest work failure is superseded by a later terminal success" {
    const events = [_]domain.Event{
        .{
            .sequence = 1,
            .revision = 1,
            .id = @constCast("failed"),
            .timestamp_ms = 1,
            .kind = .{ .work_transition = .{
                .work_item_id = @constCast("work-1"),
                .previous = .running,
                .current = .failed,
                .reason = @constCast("read failed"),
            } },
        },
        .{
            .sequence = 2,
            .revision = 2,
            .id = @constCast("completed"),
            .timestamp_ms = 2,
            .kind = .{ .work_transition = .{
                .work_item_id = @constCast("work-2"),
                .previous = .running,
                .current = .completed,
                .reason = null,
            } },
        },
    };
    try std.testing.expect(latestWorkFailure(&events) == null);
    try std.testing.expectEqualStrings(
        "read failed",
        latestWorkFailure(events[0..1]).?.reason,
    );
}

pub const Inspection = struct {
    child_id: []u8,
    generation: u64,
    restart_required: bool = false,
    status: ?domain.State = null,
    configuration: ?domain.Configuration = null,
    relationship_selected: bool = false,
    parent_id: ?[]u8 = null,
    messages: []domain.QueuedMessage,
    history: []InspectedHistoryTurn,
    history_len: ?usize = null,
    history_truncated: bool = false,
    history_error: ?InspectionSourceError = null,
    events: []domain.Event,
    tool_activity_selected: bool = false,
    tool_activity: []InspectedToolActivity,
    tool_activity_truncated: bool = false,
    tool_activity_error: ?InspectionSourceError = null,
    failure_work_id: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
    next_cursor: ?[]u8 = null,

    pub fn deinit(self: *Inspection, alloc: Allocator) void {
        alloc.free(self.child_id);
        if (self.configuration) |*configuration| configuration.deinit(alloc);
        if (self.parent_id) |id| alloc.free(id);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        for (self.history) |*turn| turn.deinit(alloc);
        alloc.free(self.history);
        for (self.events) |*event| event.deinit(alloc);
        alloc.free(self.events);
        for (self.tool_activity) |*activity| activity.deinit(alloc);
        alloc.free(self.tool_activity);
        if (self.failure_work_id) |id| alloc.free(id);
        if (self.failure_reason) |reason| alloc.free(reason);
        if (self.next_cursor) |cursor| alloc.free(cursor);
        self.* = undefined;
    }
};

const HistoryProjection = struct {
    turns: []InspectedHistoryTurn,
    history_len: ?usize = null,
    truncated: bool = false,
    source_error: ?InspectionSourceError = null,

    fn deinit(self: *HistoryProjection, alloc: Allocator) void {
        for (self.turns) |*turn| turn.deinit(alloc);
        alloc.free(self.turns);
        self.* = undefined;
    }
};

const ToolActivityProjection = struct {
    activity: []InspectedToolActivity,
    truncated: bool = false,
    source_error: ?InspectionSourceError = null,

    fn deinit(self: *ToolActivityProjection, alloc: Allocator) void {
        for (self.activity) |*value| value.deinit(alloc);
        alloc.free(self.activity);
        self.* = undefined;
    }
};

const FailureProjection = struct {
    work_id: ?[]u8 = null,
    reason: ?[]u8 = null,
};

const HistoryTurnView = struct {
    kind: InspectedHistoryKind,
    work_id: ?[]const u8 = null,
    user: ?[]const u8 = null,
    assistant: ?[]const u8 = null,
};

pub const TreeRelationshipIssue = enum {
    missing_parent,
};

pub const TreeDiagnosticCode = enum {
    session_unavailable,
    control_record_invalid,
    control_record_too_large,
    control_path_unsafe,
    relationship_cycle,
    graph_too_deep,
    store_failure,
};

pub const TreeDiagnostic = struct {
    session_id: []u8,
    parent_id: ?[]u8 = null,
    code: TreeDiagnosticCode,

    pub fn deinit(self: *TreeDiagnostic, alloc: Allocator) void {
        alloc.free(self.session_id);
        if (self.parent_id) |parent_id| alloc.free(parent_id);
        self.* = undefined;
    }
};

pub const TreeQuery = struct {
    root_id: []const u8,
    cursor: ?[]const u8 = null,
    anchor_id: ?[]const u8 = null,
    limit: usize = domain.default_page_limit,
    hide_terminal_one_off: bool = false,
};

pub const TreeNode = struct {
    child_id: []u8,
    parent_id: []u8,
    name: []u8,
    mode: domain.Mode,
    state: domain.State,
    generation: u64,
    depth: usize,
    relationship_issue: ?TreeRelationshipIssue = null,

    pub fn deinit(self: *TreeNode, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.parent_id);
        alloc.free(self.name);
        self.* = undefined;
    }
};

pub const TreeSnapshot = struct {
    root_id: []u8,
    revision: u64,
    restart_required: bool = false,
    nodes: []TreeNode,
    page_cursor: ?[]u8 = null,
    next_cursor: ?[]u8 = null,
    diagnostics: []TreeDiagnostic,
    diagnostics_truncated: bool = false,

    pub fn deinit(self: *TreeSnapshot, alloc: Allocator) void {
        alloc.free(self.root_id);
        for (self.nodes) |*node| node.deinit(alloc);
        alloc.free(self.nodes);
        if (self.page_cursor) |cursor| alloc.free(cursor);
        if (self.next_cursor) |cursor| alloc.free(cursor);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
        alloc.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const SnapshotResult = union(enum) {
    snapshot: TreeSnapshot,
    failure: Failure,

    pub fn deinit(self: *SnapshotResult, alloc: Allocator) void {
        switch (self.*) {
            .snapshot => |*snapshot_value| snapshot_value.deinit(alloc),
            .failure => {},
        }
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    receipt: domain.OperationReceipt,
    inspection: Inspection,
    failure: Failure,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .receipt => |*receipt| receipt.deinit(alloc),
            .inspection => |*inspection| inspection.deinit(alloc),
            .failure => {},
        }
        self.* = undefined;
    }
};

pub const RelationshipAuthorization = union(enum) {
    none,
    direct,
    approval: []const u8,
};

const TargetAuthorization = union(enum) {
    none,
    attached_to_root: []const u8,
};

pub const Context = struct {
    actor_id: []const u8,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    operation_id: ?[]const u8 = null,
    operation_identity_source: ?domain.OperationIdentitySource = null,
    operation_identity_epoch: ?u64 = null,
    operation_identity_admitted: bool = false,
    created_child_id: ?[]const u8 = null,
    expected_generation: ?u64 = null,
    relationship_authorization: RelationshipAuthorization = .none,
    target_authorization: TargetAuthorization = .none,
    timestamp_ms: i64,
};

pub const Publisher = struct {
    context: ?*anyopaque = null,
    publish_fn: *const fn (?*anyopaque, control_store.Record) void,

    fn publish(self: Publisher, record: control_store.Record) void {
        self.publish_fn(self.context, record);
    }
};

pub const Options = struct {
    child_store: session_child_store.Options = .{},
    publisher: ?Publisher = null,
};

pub const ExecuteError = error{OutOfMemory};

const SnapshotCounters = struct {
    discovery_session_ids: usize = 0,
    relationship_reads: usize = 0,
    control_reads: usize = 0,
    candidates_owned: usize = 0,
};

const max_snapshot_relationship_reads = relationship_index.max_candidate_reads;
const max_snapshot_migration_pages: usize = 4;
const max_tree_cursor_bytes: usize = 64 * 1024;

const TreeCursorFrame = struct {
    generation: u64,
    next_offset: u64,
};

const ParsedTreeCursor = struct {
    frames: []TreeCursorFrame,

    fn deinit(self: *ParsedTreeCursor, alloc: Allocator) void {
        alloc.free(self.frames);
        self.* = undefined;
    }
};

const TraversalFrame = struct {
    parent_id: []u8,
    generation: u64,
    next_offset: u64,
    high_watermark: u64,

    fn deinit(self: *TraversalFrame, alloc: Allocator) void {
        alloc.free(self.parent_id);
        self.* = undefined;
    }
};

const TreeTraversal = struct {
    frames: std.ArrayList(TraversalFrame) = .empty,
    root_generation: u64 = 0,
    anchored: bool = false,

    fn deinit(self: *TreeTraversal, alloc: Allocator) void {
        for (self.frames.items) |*frame| frame.deinit(alloc);
        self.frames.deinit(alloc);
        self.* = undefined;
    }
};

const TraversalError = error{
    OutOfMemory,
    InvalidCursor,
    StaleCursor,
    RelationshipCycle,
    GraphTooDeep,
    StoreFailure,
};

pub const Manager = struct {
    sessions: *session_store.Store,
    options: Options = .{},

    /// Returns an allocator-owned, bounded page of the canonical child tree.
    pub fn snapshot(
        self: *Manager,
        alloc: Allocator,
        query: TreeQuery,
    ) ExecuteError!SnapshotResult {
        return self.snapshotWithCounters(alloc, query, null);
    }

    fn snapshotWithCounters(
        self: *Manager,
        alloc: Allocator,
        query: TreeQuery,
        counters: ?*SnapshotCounters,
    ) ExecuteError!SnapshotResult {
        return self.snapshotWithDepthLimit(
            alloc,
            query,
            counters,
            max_ancestry_depth,
        );
    }

    fn snapshotWithDepthLimit(
        self: *Manager,
        alloc: Allocator,
        query: TreeQuery,
        counters: ?*SnapshotCounters,
        depth_limit: usize,
    ) ExecuteError!SnapshotResult {
        std.debug.assert(depth_limit > 0 and depth_limit <= max_ancestry_depth);
        domain.validateId(query.root_id) catch return snapshotFailure(.invalid_snapshot_query);
        if (query.anchor_id) |anchor_id| {
            domain.validateId(anchor_id) catch return snapshotFailure(.invalid_snapshot_query);
        }
        if (query.limit == 0 or query.limit > domain.max_page_limit) {
            return snapshotFailure(.invalid_snapshot_query);
        }
        relationship_index.recoverForQuery(
            alloc,
            self.sessions,
            query.root_id,
            self.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => snapshotFailure(.store_failure),
        };
        var migration_pages: usize = 0;
        const root_migration = relationship_index.migrateLegacyPage(
            alloc,
            self.sessions,
            query.root_id,
            self.options.child_store,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => relationship_index.MigrationStats{},
        };
        migration_pages += 1;
        if (counters) |stats| {
            stats.discovery_session_ids += root_migration.candidate_reads;
            stats.control_reads += root_migration.candidate_reads;
            stats.candidates_owned += root_migration.candidate_reads;
        }
        var traversal = self.initializeTreeTraversal(
            alloc,
            query.root_id,
            query.cursor,
            if (query.cursor == null) query.anchor_id else null,
            counters,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidCursor => snapshotFailure(.invalid_snapshot_query),
            error.RelationshipCycle => snapshotFailure(.relationship_cycle),
            error.GraphTooDeep => snapshotFailure(.graph_too_deep),
            error.StaleCursor => try restartSnapshot(alloc, query.root_id, 0),
            error.StoreFailure => snapshotFailure(.store_failure),
        };
        defer traversal.deinit(alloc);

        const page_cursor = if (query.cursor) |raw|
            try alloc.dupe(u8, raw)
        else if (traversal.anchored)
            try encodeTreeCursor(alloc, traversal.frames.items)
        else
            null;
        errdefer if (page_cursor) |cursor| alloc.free(cursor);

        var nodes: std.ArrayList(TreeNode) = .empty;
        errdefer {
            for (nodes.items) |*node| node.deinit(alloc);
            nodes.deinit(alloc);
        }
        var diagnostics: std.ArrayList(TreeDiagnostic) = .empty;
        errdefer {
            for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
            diagnostics.deinit(alloc);
        }
        var diagnostics_truncated = false;
        var slots_read: usize = 0;
        while (nodes.items.len < query.limit and
            slots_read < max_snapshot_relationship_reads)
        {
            while (traversal.frames.items.len != 0) {
                const last = traversal.frames.items.len - 1;
                const frame = traversal.frames.items[last];
                if (frame.next_offset < frame.high_watermark) break;
                var finished = traversal.frames.pop().?;
                finished.deinit(alloc);
            }
            if (traversal.frames.items.len == 0) break;

            const frame_index = traversal.frames.items.len - 1;
            const remaining_reads = max_snapshot_relationship_reads - slots_read;
            var candidate_page = relationship_index.page(
                alloc,
                self.sessions,
                traversal.frames.items[frame_index].parent_id,
                self.options.child_store,
                .{
                    .generation = traversal.frames.items[frame_index].generation,
                    .offset = traversal.frames.items[frame_index].next_offset,
                },
                1,
                remaining_reads,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.StaleCursor or
                    err == error.CommitIndeterminate)
                {
                    const restart = try restartSnapshot(
                        alloc,
                        query.root_id,
                        traversal.root_generation,
                    );
                    deinitPartialTreePage(
                        alloc,
                        &nodes,
                        &diagnostics,
                        page_cursor,
                    );
                    return restart;
                }
                if (err == error.InvalidIndex) {
                    relationship_index.repairForQuery(
                        alloc,
                        self.sessions,
                        traversal.frames.items[frame_index].parent_id,
                        self.options.child_store,
                    ) catch |repair_err| {
                        if (repair_err == error.OutOfMemory) {
                            return error.OutOfMemory;
                        }
                    };
                    const restart = try restartSnapshot(
                        alloc,
                        query.root_id,
                        traversal.root_generation,
                    );
                    deinitPartialTreePage(
                        alloc,
                        &nodes,
                        &diagnostics,
                        page_cursor,
                    );
                    return restart;
                }
                deinitPartialTreePage(
                    alloc,
                    &nodes,
                    &diagnostics,
                    page_cursor,
                );
                return snapshotFailure(.store_failure);
            };
            defer candidate_page.deinit(alloc);
            slots_read += candidate_page.slots_read;
            if (counters) |stats| {
                stats.discovery_session_ids += candidate_page.slots_read;
                stats.relationship_reads += 1;
                stats.candidates_owned += candidate_page.candidates.len;
            }
            traversal.frames.items[frame_index].next_offset = candidate_page.next_offset;
            traversal.frames.items[frame_index].high_watermark = candidate_page.high_watermark;
            if (candidate_page.candidates.len == 0) continue;

            const candidate = candidate_page.candidates[0];
            if (treePathContains(traversal.frames.items, candidate.child_id)) {
                deinitPartialTreePage(alloc, &nodes, &diagnostics, page_cursor);
                return snapshotFailure(.relationship_cycle);
            }
            const depth = traversal.frames.items.len - 1;
            if (depth == depth_limit - 1) {
                deinitPartialTreePage(alloc, &nodes, &diagnostics, page_cursor);
                return snapshotFailure(.graph_too_deep);
            }
            if (counters) |stats| stats.control_reads += 1;
            var record = self.loadIndexedTreeRecord(
                alloc,
                candidate.child_id,
                traversal.frames.items[frame_index].parent_id,
                &diagnostics,
                &diagnostics_truncated,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
            defer if (record) |*value| value.deinit(alloc);
            const value = record orelse continue;
            const canonical_parent = value.parent_id orelse continue;
            if (!std.mem.eql(
                u8,
                canonical_parent,
                traversal.frames.items[frame_index].parent_id,
            )) continue;

            if (!query.hide_terminal_one_off or
                !isTerminalOneOff(value.mode, value.state))
            {
                var node = try treeNodeFromRecord(alloc, value, depth);
                var node_appended = false;
                errdefer if (!node_appended) node.deinit(alloc);
                try nodes.append(alloc, node);
                node_appended = true;
            }

            if (migration_pages < max_snapshot_migration_pages) {
                relationship_index.recoverForQuery(
                    alloc,
                    self.sessions,
                    candidate.child_id,
                    self.options.child_store,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        deinitPartialTreePage(
                            alloc,
                            &nodes,
                            &diagnostics,
                            page_cursor,
                        );
                        return snapshotFailure(.store_failure);
                    },
                };
                const migration = relationship_index.migrateLegacyPage(
                    alloc,
                    self.sessions,
                    candidate.child_id,
                    self.options.child_store,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => relationship_index.MigrationStats{},
                };
                migration_pages += 1;
                if (counters) |stats| {
                    stats.discovery_session_ids += migration.candidate_reads;
                    stats.control_reads += migration.candidate_reads;
                    stats.candidates_owned += migration.candidate_reads;
                }
            }
            const child_state = self.relationshipStateForQuery(
                alloc,
                candidate.child_id,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.StaleCursor) {
                    const restart = try restartSnapshot(
                        alloc,
                        query.root_id,
                        traversal.root_generation,
                    );
                    deinitPartialTreePage(
                        alloc,
                        &nodes,
                        &diagnostics,
                        page_cursor,
                    );
                    return restart;
                }
                deinitPartialTreePage(
                    alloc,
                    &nodes,
                    &diagnostics,
                    page_cursor,
                );
                return snapshotFailure(.store_failure);
            };
            if (counters) |stats| stats.relationship_reads += 1;
            if (child_state.high_watermark != 0) {
                const owned_child = try alloc.dupe(u8, candidate.child_id);
                errdefer alloc.free(owned_child);
                try traversal.frames.append(alloc, .{
                    .parent_id = owned_child,
                    .generation = child_state.generation,
                    .next_offset = 0,
                    .high_watermark = child_state.high_watermark,
                });
            }
        }

        while (traversal.frames.items.len != 0) {
            const last = traversal.frames.items.len - 1;
            const frame = traversal.frames.items[last];
            if (frame.next_offset < frame.high_watermark) break;
            var finished = traversal.frames.pop().?;
            finished.deinit(alloc);
        }
        const next_cursor = if (traversal.frames.items.len == 0)
            null
        else
            try encodeTreeCursor(alloc, traversal.frames.items);
        errdefer if (next_cursor) |cursor| alloc.free(cursor);
        const root_id = try alloc.dupe(u8, query.root_id);
        errdefer alloc.free(root_id);
        const owned_nodes = try nodes.toOwnedSlice(alloc);
        errdefer {
            for (owned_nodes) |*node| node.deinit(alloc);
            alloc.free(owned_nodes);
        }
        const owned_diagnostics = try diagnostics.toOwnedSlice(alloc);
        return .{ .snapshot = .{
            .root_id = root_id,
            .revision = traversal.root_generation,
            .nodes = owned_nodes,
            .page_cursor = page_cursor,
            .next_cursor = next_cursor,
            .diagnostics = owned_diagnostics,
            .diagnostics_truncated = diagnostics_truncated,
        } };
    }

    fn initializeTreeTraversal(
        self: *Manager,
        alloc: Allocator,
        root_id: []const u8,
        raw_cursor: ?[]const u8,
        anchor_id: ?[]const u8,
        counters: ?*SnapshotCounters,
    ) TraversalError!TreeTraversal {
        if (raw_cursor) |raw| {
            var parsed = try parseTreeCursor(alloc, raw);
            defer parsed.deinit(alloc);
            return self.reconstructTreeTraversal(
                alloc,
                root_id,
                parsed.frames,
                counters,
            );
        }
        if (anchor_id) |anchor| {
            if (!std.mem.eql(u8, anchor, root_id)) {
                if (try self.anchorTreeTraversal(
                    alloc,
                    root_id,
                    anchor,
                    counters,
                )) |traversal| return traversal;
            }
        }
        const root_state = try self.relationshipStateForQuery(alloc, root_id);
        if (counters) |stats| stats.relationship_reads += 1;
        var traversal = TreeTraversal{ .root_generation = root_state.generation };
        errdefer traversal.deinit(alloc);
        try appendTraversalFrame(
            alloc,
            &traversal.frames,
            root_id,
            root_state.generation,
            0,
            root_state.high_watermark,
        );
        return traversal;
    }

    fn reconstructTreeTraversal(
        self: *Manager,
        alloc: Allocator,
        root_id: []const u8,
        cursor_frames: []const TreeCursorFrame,
        counters: ?*SnapshotCounters,
    ) TraversalError!TreeTraversal {
        if (cursor_frames.len == 0 or
            cursor_frames.len > max_ancestry_depth + 1)
        {
            return error.InvalidCursor;
        }
        const root_state = try self.relationshipStateForQuery(alloc, root_id);
        if (counters) |stats| stats.relationship_reads += 1;
        if (root_state.generation != cursor_frames[0].generation or
            cursor_frames[0].next_offset > root_state.high_watermark)
        {
            return error.StaleCursor;
        }
        var traversal = TreeTraversal{ .root_generation = root_state.generation };
        errdefer traversal.deinit(alloc);
        try appendTraversalFrame(
            alloc,
            &traversal.frames,
            root_id,
            root_state.generation,
            cursor_frames[0].next_offset,
            root_state.high_watermark,
        );
        for (cursor_frames[1..], 1..) |cursor_frame, index| {
            const previous = traversal.frames.items[index - 1];
            if (previous.next_offset == 0) return error.InvalidCursor;
            var candidate = (relationship_index.candidateAt(
                alloc,
                self.sessions,
                previous.parent_id,
                self.options.child_store,
                previous.generation,
                previous.next_offset - 1,
            ) catch |err| return mapIndexTraversalError(err)) orelse
                return error.StaleCursor;
            defer candidate.deinit(alloc);
            if (counters) |stats| {
                stats.relationship_reads += 1;
                stats.candidates_owned += 1;
                stats.control_reads += 1;
            }
            if (treePathContains(traversal.frames.items, candidate.child_id)) {
                return error.StaleCursor;
            }
            const parent = try self.readTreeParent(alloc, candidate.child_id);
            defer if (parent) |value| alloc.free(value);
            if (parent == null or
                !std.mem.eql(u8, parent.?, previous.parent_id))
            {
                return error.StaleCursor;
            }
            const state = try self.relationshipStateForQuery(
                alloc,
                candidate.child_id,
            );
            if (counters) |stats| stats.relationship_reads += 1;
            if (state.generation != cursor_frame.generation or
                cursor_frame.next_offset > state.high_watermark)
            {
                return error.StaleCursor;
            }
            try appendTraversalFrame(
                alloc,
                &traversal.frames,
                candidate.child_id,
                state.generation,
                cursor_frame.next_offset,
                state.high_watermark,
            );
        }
        return traversal;
    }

    fn anchorTreeTraversal(
        self: *Manager,
        alloc: Allocator,
        root_id: []const u8,
        anchor_id: []const u8,
        counters: ?*SnapshotCounters,
    ) TraversalError!?TreeTraversal {
        var reverse_path: std.ArrayList([]u8) = .empty;
        defer freeIds(alloc, &reverse_path);
        var current = try alloc.dupe(u8, anchor_id);
        defer alloc.free(current);
        var reaches_root = false;
        while (true) {
            if (containsId(reverse_path.items, current)) return null;
            if (reverse_path.items.len == max_ancestry_depth) return null;
            try reverse_path.append(alloc, try alloc.dupe(u8, current));
            const parent = try self.readTreeParent(alloc, current);
            if (counters) |stats| stats.control_reads += 1;
            if (parent == null) break;
            if (std.mem.eql(u8, parent.?, root_id)) {
                alloc.free(parent.?);
                reaches_root = true;
                break;
            }
            alloc.free(current);
            current = parent.?;
        }
        if (!reaches_root) return null;

        const root_state = try self.relationshipStateForQuery(alloc, root_id);
        if (counters) |stats| stats.relationship_reads += 1;
        var traversal = TreeTraversal{
            .root_generation = root_state.generation,
            .anchored = true,
        };
        errdefer traversal.deinit(alloc);
        try appendTraversalFrame(
            alloc,
            &traversal.frames,
            root_id,
            root_state.generation,
            0,
            root_state.high_watermark,
        );

        var reverse_index = reverse_path.items.len;
        while (reverse_index != 0) {
            reverse_index -= 1;
            const child_id = reverse_path.items[reverse_index];
            const frame_index = traversal.frames.items.len - 1;
            const parent_frame = traversal.frames.items[frame_index];
            const lookup = (relationship_index.lookupSlot(
                alloc,
                self.sessions,
                parent_frame.parent_id,
                child_id,
                self.options.child_store,
            ) catch |err| return mapIndexTraversalError(err)) orelse return null;
            if (counters) |stats| stats.relationship_reads += 1;
            if (lookup.generation != parent_frame.generation) {
                return error.StaleCursor;
            }
            if (reverse_index == 0) {
                traversal.frames.items[frame_index].next_offset = lookup.slot;
                return traversal;
            }
            traversal.frames.items[frame_index].next_offset = lookup.slot + 1;
            const child_state = try self.relationshipStateForQuery(
                alloc,
                child_id,
            );
            if (counters) |stats| stats.relationship_reads += 1;
            try appendTraversalFrame(
                alloc,
                &traversal.frames,
                child_id,
                child_state.generation,
                0,
                child_state.high_watermark,
            );
        }
        return null;
    }

    fn relationshipStateForQuery(
        self: *Manager,
        alloc: Allocator,
        parent_id: []const u8,
    ) TraversalError!relationship_index.State {
        relationship_index.recoverForQuery(
            alloc,
            self.sessions,
            parent_id,
            self.options.child_store,
        ) catch |err| return mapIndexTraversalError(err);
        return relationship_index.state(
            alloc,
            self.sessions,
            parent_id,
            self.options.child_store,
        ) catch |err| return mapIndexTraversalError(err);
    }

    fn readTreeParent(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
    ) TraversalError!?[]u8 {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId, error.SessionNotFound => null,
            else => error.StoreFailure,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = store.loadOptional(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreFailure,
        };
        defer if (record) |*value| value.deinit(alloc);
        return if (record) |value|
            if (value.parent_id) |parent| try alloc.dupe(u8, parent) else null
        else
            null;
    }

    fn loadIndexedTreeRecord(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        parent_id: []const u8,
        diagnostics: *std.ArrayList(TreeDiagnostic),
        diagnostics_truncated: *bool,
    ) error{OutOfMemory}!?control_store.Record {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.options.child_store,
        ) catch |err| {
            const code: TreeDiagnosticCode = switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSessionId, error.SessionNotFound => .session_unavailable,
                error.SessionPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => .control_path_unsafe,
                error.SessionStoreUnavailable,
                error.SessionChildStoreFailed,
                => .store_failure,
            };
            try appendTreeDiagnostic(
                alloc,
                diagnostics,
                diagnostics_truncated,
                child_id,
                if (err == error.SessionNotFound) parent_id else null,
                code,
            );
            return null;
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        return store.loadOptional(alloc) catch |err| {
            const code: TreeDiagnosticCode = switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidControlRecord,
                error.UnsupportedControlSchema,
                => .control_record_invalid,
                error.ControlRecordTooLarge => .control_record_too_large,
                error.ControlPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => .control_path_unsafe,
                error.ControlNotFound, error.ControlStoreFailed => .store_failure,
            };
            try appendTreeDiagnostic(
                alloc,
                diagnostics,
                diagnostics_truncated,
                child_id,
                null,
                code,
            );
            return null;
        };
    }

    pub fn execute(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        context: Context,
    ) ExecuteError!Result {
        domain.validateId(context.actor_id) catch return failure(.store_failure);
        switch (command) {
            .inspect => |inspect_command| return self.inspect(
                alloc,
                inspect_command,
                context,
            ),
            .message => |message| switch (message) {
                .milestone => |milestone| return self.emitMilestone(
                    alloc,
                    command,
                    milestone.name,
                    context,
                ),
                .send => |send| {
                    if (try self.sendToParent(
                        alloc,
                        command,
                        send.id,
                        send.content,
                        context,
                    )) |result| {
                        return result;
                    }
                    return self.mutateOne(
                        alloc,
                        send.id,
                        command,
                        context,
                        null,
                    );
                },
            },
            .create => {
                const child_id = context.created_child_id orelse
                    return failure(.session_not_found);
                domain.validateId(child_id) catch return failure(.session_not_found);
                return self.mutateCreate(
                    alloc,
                    child_id,
                    command,
                    context,
                );
            },
            .relationship => |relationship| {
                if (relationship.action == .detach) {
                    return self.mutateDetach(alloc, command, context);
                }
                return self.mutateRelationship(alloc, command, context);
            },
            .configure => |configure| return self.mutateOne(
                alloc,
                configure.id,
                command,
                context,
                null,
            ),
            .lifecycle => |lifecycle| return self.mutateOne(
                alloc,
                lifecycle.id,
                command,
                context,
                null,
            ),
        }
    }

    /// Reads the caller's canonical direct relationship. Presentation paging
    /// is deliberately not involved in authorization decisions.
    pub fn isDirectParent(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        candidate_parent_id: []const u8,
    ) ExecuteError!bool {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = (store.loadOptional(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        }) orelse return false;
        defer record.deinit(alloc);
        const parent_id = record.parent_id orelse return false;
        return std.mem.eql(u8, parent_id, candidate_parent_id);
    }

    fn sendToParent(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        target_id: []const u8,
        content: []const u8,
        context: Context,
    ) ExecuteError!?Result {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            context.actor_id,
            self.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId, error.SessionNotFound => null,
            error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            => failure(.control_path_unsafe),
            error.SessionStoreUnavailable,
            error.SessionChildStoreFailed,
            => failure(.store_failure),
        };
        defer capability.deinit();
        var control = control_store.Store{
            .capability = &capability,
            .expected_child_id = context.actor_id,
        };
        var lock = control.acquireLock() catch |err| return try mapControlLockError(err);
        defer lock.release();
        var record = control.loadOptional(alloc) catch |err|
            return try mapControlLoadError(err);
        defer if (record) |*value| value.deinit(alloc);
        const child = record orelse return null;
        const parent_id = child.parent_id orelse return null;
        if (!std.mem.eql(u8, parent_id, target_id)) return null;
        const operation_id = context.operation_id orelse
            return failure(.operation_id_required);
        domain.validateOperationId(operation_id) catch
            return failure(.invalid_operation_id);
        const fingerprints = resolvedOperationFingerprints(
            command,
            context,
            target_id,
            null,
        );
        const communication_state = communication_store.Store{
            .capability = &capability,
            .expected_session_id = context.actor_id,
        };
        const existing = communication_state.loadOptional(alloc) catch
            return failure(.control_record_invalid);
        var ledger = if (existing) |value|
            value
        else
            communication.Ledger.init(alloc, context.actor_id) catch
                return error.OutOfMemory;
        defer ledger.deinit(alloc);
        const appended = communication.appendDelivery(alloc, &ledger, .{
            .id = operation_id,
            .source_id = context.actor_id,
            .target_id = parent_id,
            .operation_id = operation_id,
            .operation_identity_admitted = context.operation_identity_admitted,
            .timestamp_ms = context.timestamp_ms,
            .payload = .{ .message = content },
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidDelivery => failure(.operation_conflict),
            error.ReplayExpired => failure(.operation_replay_expired),
            error.CapacityExceeded => failure(.communication_capacity_exceeded),
            else => failure(.control_record_invalid),
        };
        if (appended == .appended) {
            communication_state.save(alloc, ledger) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CommunicationCapacityExceeded => failure(.communication_capacity_exceeded),
                error.CommunicationCommitIndeterminate => failure(.control_commit_indeterminate),
                else => failure(.control_record_invalid),
            };
        }
        const sequence = switch (appended) {
            .appended => |value| value,
            .duplicate => |value| value,
        };
        const delivery = findDeliveryBySequence(ledger.deliveries, sequence) orelse
            return failure(.control_record_invalid);
        return .{ .receipt = try makeReceipt(
            alloc,
            operation_id,
            fingerprints,
            .message_queued,
            parent_id,
            delivery.revision,
            delivery.sequence,
        ) };
    }

    fn emitMilestone(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        name: []const u8,
        context: Context,
    ) ExecuteError!Result {
        const operation_id = context.operation_id orelse
            return failure(.operation_id_required);
        domain.validateOperationId(operation_id) catch
            return failure(.invalid_operation_id);
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            context.actor_id,
            self.options.child_store,
        ) catch |err| return try mapOpenControlError(err);
        defer capability.deinit();
        var control = control_store.Store{
            .capability = &capability,
            .expected_child_id = context.actor_id,
        };
        var communications = communication_store.Store{
            .capability = &capability,
            .expected_session_id = context.actor_id,
        };
        var lock = control.acquireLock() catch |err| return try mapControlLockError(err);
        defer lock.release();
        var current = control.loadOptional(alloc) catch |err|
            return try mapControlLoadError(err);
        defer if (current) |*record| record.deinit(alloc);
        if (current == null) return failure(.invalid_milestone_caller);
        const existing_ledger = communications.loadOptional(alloc) catch
            return failure(.control_record_invalid);
        var ledger = if (existing_ledger) |value|
            value
        else
            communication.Ledger.init(alloc, context.actor_id) catch
                return error.OutOfMemory;
        defer ledger.deinit(alloc);
        var decision = try reduceMilestone(
            alloc,
            current.?,
            ledger,
            command,
            name,
            context,
            operation_id,
        );
        defer decision.deinit(alloc);
        var result = try self.commitDecision(alloc, control, &decision);
        errdefer result.deinit(alloc);
        switch (result) {
            .receipt => |receipt| {
                var observed = control.load(alloc) catch
                    return failure(.control_record_invalid);
                defer observed.deinit(alloc);
                const event = milestoneEventForReceipt(observed, receipt) orelse
                    findMilestoneEvent(observed.events, name, null) orelse
                    return failure(.control_record_invalid);
                _ = communication.appendDelivery(alloc, &ledger, .{
                    .id = event.operation_id,
                    .source_id = event.source_child_id,
                    .target_id = event.target_parent_id,
                    .work_id = event.work_item_id,
                    .operation_id = event.operation_id,
                    .operation_identity_admitted = context.operation_identity_admitted,
                    .timestamp_ms = event.timestamp_ms,
                    .payload = .{ .milestone = event.name },
                }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.CapacityExceeded => failure(.communication_capacity_exceeded),
                    else => failure(.control_record_invalid),
                };
                communications.save(alloc, ledger) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.CommunicationCapacityExceeded => failure(.communication_capacity_exceeded),
                    error.CommunicationCommitIndeterminate => failure(.control_commit_indeterminate),
                    else => failure(.control_record_invalid),
                };
            },
            .failure, .inspection => {},
        }
        return result;
    }

    fn mutateOne(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
        command: domain.Command,
        context: Context,
        bootstrap: ?domain.Configuration,
    ) ExecuteError!Result {
        return switch (context.target_authorization) {
            .none => self.mutateOneUnrestricted(
                alloc,
                target_id,
                command,
                context,
                bootstrap,
            ),
            .attached_to_root => |root_id| self.mutateOneAuthorized(
                alloc,
                target_id,
                command,
                context,
                bootstrap,
                root_id,
            ),
        };
    }

    fn mutateOneUnrestricted(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
        command: domain.Command,
        context: Context,
        bootstrap: ?domain.Configuration,
    ) ExecuteError!Result {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            target_id,
            self.options.child_store,
        ) catch |err| return try mapOpenControlError(err);
        defer capability.deinit();
        var store = control_store.Store{
            .capability = &capability,
            .expected_child_id = target_id,
        };
        var lock = store.acquireLock() catch |err| return try mapControlLockError(err);
        defer lock.release();

        var current = store.loadOptional(alloc) catch |err| return try mapControlLoadError(err);
        defer if (current) |*record| record.deinit(alloc);
        var decision = try reduce(alloc, current, command, context, target_id, bootstrap);
        defer decision.deinit(alloc);
        if (try preflightMessageCommit(
            alloc,
            &capability,
            target_id,
            command,
            decision,
        )) |result| return result;
        var projection_root: ?[]u8 = null;
        defer if (projection_root) |root| alloc.free(root);
        if (decision == .commit) {
            if (decision.commit.record.parent_id) |parent| {
                var ancestry = self.discoverRelationshipLockIds(
                    alloc,
                    target_id,
                    parent,
                ) catch null;
                if (ancestry) |*ids| {
                    defer freeIds(alloc, ids);
                    projection_root = try alloc.dupe(
                        u8,
                        ids.items[ids.items.len - 1],
                    );
                }
            }
        }
        var result = try self.commitDecision(alloc, store, &decision);
        errdefer result.deinit(alloc);
        reconcileLifecycleCancellationLocked(
            alloc,
            &capability,
            target_id,
            command,
            &result,
        );
        if (projection_root) |root| {
            _ = relationship_index.bumpGeneration(
                alloc,
                self.sessions,
                root,
                .{},
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "relationship root generation update deferred root_id={s} child_id={s} outcome={s}",
                    .{ root, target_id, @errorName(err) },
                );
            };
        }
        return result;
    }

    fn mutateOneAuthorized(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
        command: domain.Command,
        context: Context,
        bootstrap: ?domain.Configuration,
        root_id: []const u8,
    ) ExecuteError!Result {
        for (0..2) |_| {
            if (try self.mutateOneAuthorizedAttempt(
                alloc,
                target_id,
                command,
                context,
                bootstrap,
                root_id,
            )) |result| return result;
        }
        return failure(.graph_changed);
    }

    fn mutateOneAuthorizedAttempt(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
        command: domain.Command,
        context: Context,
        bootstrap: ?domain.Configuration,
        root_id: []const u8,
    ) ExecuteError!?Result {
        var lock_ids = self.discoverTargetAuthorizationLockIds(
            alloc,
            target_id,
        ) catch |err| return @as(?Result, try mapRelationshipDiscoveryError(err));
        defer freeIds(alloc, &lock_ids);
        sortIds(lock_ids.items);

        var locked = LockedSet.acquire(
            alloc,
            self.sessions,
            lock_ids.items,
            self.options.child_store,
        ) catch |err| return @as(?Result, try mapLockedAcquireError(err));
        defer locked.deinit(alloc);
        var graph = loadLockedGraph(alloc, &locked) catch |err|
            return @as(?Result, try mapControlLoadError(err));
        defer graph.deinit(alloc);
        switch (targetAuthorizationDecision(
            graph.edges.items,
            target_id,
            context.actor_id,
            root_id,
        )) {
            .authorized => {},
            .unauthorized => return failure(.child_unavailable),
            .graph_changed => return null,
        }

        const target = locked.find(target_id) orelse return failure(.graph_changed);
        const store = control_store.Store{
            .capability = &target.capability,
            .expected_child_id = target_id,
        };
        var current = store.loadOptional(alloc) catch |err|
            return @as(?Result, try mapControlLoadError(err));
        defer if (current) |*record| record.deinit(alloc);
        var decision = try reduce(alloc, current, command, context, target_id, bootstrap);
        defer decision.deinit(alloc);
        if (try preflightMessageCommit(
            alloc,
            &target.capability,
            target_id,
            command,
            decision,
        )) |result| return result;
        const projection_root = if (decision == .commit)
            relationshipRootId(graph.edges.items, target_id)
        else
            null;
        var result = try self.commitDecision(alloc, store, &decision);
        errdefer result.deinit(alloc);
        reconcileLifecycleCancellationLocked(
            alloc,
            &target.capability,
            target_id,
            command,
            &result,
        );
        if (projection_root) |root| {
            _ = relationship_index.bumpGeneration(
                alloc,
                self.sessions,
                root,
                self.options.child_store,
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "relationship root generation update deferred root_id={s} child_id={s} outcome={s}",
                    .{ root, target_id, @errorName(err) },
                );
            };
        }
        return result;
    }

    fn reconcileLifecycleCancellationLocked(
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        target_id: []const u8,
        command: domain.Command,
        result: *const Result,
    ) void {
        if (result.* != .receipt or
            command != .lifecycle or
            command.lifecycle.action != .cancel)
        {
            return;
        }

        const control = control_store.Store{
            .capability = capability,
            .expected_child_id = target_id,
        };
        var record = control.load(alloc) catch |err| {
            debug_trace.logf(
                "subagent",
                "terminal reconciliation deferred child_id={s} outcome={s}",
                .{ target_id, @errorName(err) },
            );
            return;
        };
        defer record.deinit(alloc);
        const communication_state = communication_store.Store{
            .capability = capability,
            .expected_session_id = target_id,
        };
        _ = communication_manager_mod.reconcileTerminalsLocked(
            alloc,
            communication_state,
            record,
        ) catch |err| debug_trace.logf(
            "subagent",
            "terminal reconciliation deferred child_id={s} outcome={s}",
            .{ target_id, @errorName(err) },
        );
    }

    fn mutateCreate(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
        command: domain.Command,
        context: Context,
    ) ExecuteError!Result {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            target_id,
            self.options.child_store,
        ) catch |err| return try mapOpenControlError(err);
        defer capability.deinit();
        var store = control_store.Store{
            .capability = &capability,
            .expected_child_id = target_id,
        };
        var lock = store.acquireLock() catch |err| return try mapControlLockError(err);
        defer lock.release();

        var current = store.loadOptional(alloc) catch |err|
            return try mapControlLoadError(err);
        defer if (current) |*record| record.deinit(alloc);
        var decision = try reduce(alloc, current, command, context, target_id, null);
        defer decision.deinit(alloc);
        const parent_id = switch (decision) {
            .commit => |commit| commit.record.parent_id,
            .replay => if (current) |record| record.parent_id else null,
            .reject => null,
        };
        if (parent_id) |parent| {
            var ancestry = self.discoverRelationshipLockIds(
                alloc,
                target_id,
                parent,
            ) catch |err| return mapRelationshipDiscoveryError(err);
            defer freeIds(alloc, &ancestry);
            const indexed = relationship_index.ensureChild(
                alloc,
                self.sessions,
                parent,
                target_id,
                self.options.child_store,
            ) catch |err| return mapRelationshipIndexError(err);
            const root = ancestry.items[ancestry.items.len - 1];
            if (indexed.changed and !std.mem.eql(u8, root, parent)) {
                _ = relationship_index.bumpGeneration(
                    alloc,
                    self.sessions,
                    root,
                    self.options.child_store,
                ) catch |err| return mapRelationshipIndexError(err);
            }
        }
        var result = try self.commitDecision(alloc, store, &decision);
        if (result == .failure and parent_id != null) {
            if (try self.rollbackPrepublishedRelationshipIfUncommitted(
                alloc,
                store,
                parent_id.?,
                target_id,
            )) |repair_failure| {
                result.deinit(alloc);
                return repair_failure;
            }
        } else if (result == .receipt and parent_id != null) {
            if (try self.invalidateResumableIndex(alloc, target_id)) |repair_failure| {
                result.deinit(alloc);
                return repair_failure;
            }
        }
        return result;
    }

    fn mutateRelationship(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        context: Context,
    ) ExecuteError!Result {
        const relationship = command.relationship;
        if (try self.probeRelationshipReplay(alloc, command, context)) |result| {
            return result;
        }
        if (relationship.action != .detach and
            context.relationship_authorization == .none)
        {
            return failure(.relationship_authorization_required);
        }
        const observed_parent = try self.readCanonicalParent(
            alloc,
            relationship.id,
        );
        defer if (observed_parent) |parent| alloc.free(parent);
        const parent_id = switch (relationship.action) {
            .attach => relationship.parent_id orelse context.actor_id,
            .detach => observed_parent orelse return failure(.relationship_missing_parent),
            .reparent => relationship.parent_id.?,
        };
        var bootstrap: ?domain.Configuration = if (relationship.action == .attach)
            self.loadBootstrapConfiguration(
                alloc,
                relationship.id,
            ) catch |err| return mapBootstrapError(err)
        else
            null;
        defer if (bootstrap) |*configuration| configuration.deinit(alloc);

        var lock_ids = self.discoverRelationshipLockIds(
            alloc,
            relationship.id,
            parent_id,
        ) catch |err| return mapRelationshipDiscoveryError(err);
        defer freeIds(alloc, &lock_ids);
        sortIds(lock_ids.items);

        var locked = LockedSet.acquire(
            alloc,
            self.sessions,
            lock_ids.items,
            self.options.child_store,
        ) catch |err| return mapLockedAcquireError(err);
        defer locked.deinit(alloc);
        var graph = loadLockedGraph(alloc, &locked) catch |err|
            return mapControlLoadError(err);
        defer graph.deinit(alloc);
        const graph_failure = validateAncestry(
            graph.edges.items,
            relationship.id,
            parent_id,
        );
        if (graph_failure) |code| return failure(code);

        const target = locked.find(relationship.id) orelse
            return failure(.graph_changed);
        var target_store = control_store.Store{
            .capability = &target.capability,
            .expected_child_id = relationship.id,
        };
        const operation_id = context.operation_id orelse
            return failure(.operation_id_required);
        if (context.relationship_authorization == .approval) {
            const approval_id = context.relationship_authorization.approval;
            const root_id = relationshipRootId(
                graph.edges.items,
                parent_id,
            ) orelse return failure(.graph_changed);
            const approval_failure = self.validateRelationshipApprovalLocked(
                alloc,
                &target.capability,
                command.relationship,
                operation_id,
                parent_id,
                root_id,
                approval_id,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
            if (approval_failure) |code| return failure(code);
        }
        var current = target_store.loadOptional(alloc) catch |err|
            return mapControlLoadError(err);
        defer if (current) |*record| record.deinit(alloc);
        var decision = try reduce(
            alloc,
            current,
            command,
            context,
            relationship.id,
            bootstrap,
        );
        defer decision.deinit(alloc);
        const previous_parent = if (current) |record|
            if (record.parent_id) |parent| try alloc.dupe(u8, parent) else null
        else
            null;
        defer if (previous_parent) |parent| alloc.free(parent);
        const next_parent = switch (decision) {
            .commit => |commit| commit.record.parent_id,
            .replay => if (current) |record| record.parent_id else null,
            .reject => null,
        };
        const next_root = if (next_parent) |parent|
            relationshipRootId(graph.edges.items, parent)
        else
            null;
        const previous_root = if (previous_parent) |parent|
            relationshipRootId(graph.edges.items, parent)
        else
            null;
        const relationship_changes = decision == .commit;
        if (next_parent) |parent| {
            _ = relationship_index.ensureChild(
                alloc,
                self.sessions,
                parent,
                relationship.id,
                self.options.child_store,
            ) catch |err| return mapRelationshipIndexError(err);
        }
        var bumped_root: ?[]const u8 = null;
        if (relationship_changes) if (next_root) |root| {
            if (next_parent == null or !std.mem.eql(u8, root, next_parent.?)) {
                _ = relationship_index.bumpGeneration(
                    alloc,
                    self.sessions,
                    root,
                    self.options.child_store,
                ) catch |err| return mapRelationshipIndexError(err);
                bumped_root = root;
            }
        };
        if (relationship_changes) if (previous_root) |root| {
            const parent = previous_parent.?;
            const edge_changes = next_parent == null or
                !std.mem.eql(u8, parent, next_parent.?);
            const already_bumped = if (bumped_root) |value|
                std.mem.eql(u8, value, root)
            else
                false;
            if (edge_changes and !std.mem.eql(u8, root, parent) and
                !already_bumped)
            {
                _ = relationship_index.bumpGeneration(
                    alloc,
                    self.sessions,
                    root,
                    self.options.child_store,
                ) catch |err| return mapRelationshipIndexError(err);
            }
        };
        var result = try self.commitDecision(alloc, target_store, &decision);
        if (result == .receipt) {
            var committed = target_store.loadOptional(alloc) catch |err| {
                result.deinit(alloc);
                return self.relationshipProjectionRepairFailure(
                    relationship.id,
                    err,
                );
            };
            defer if (committed) |*record| record.deinit(alloc);
            const record = committed orelse {
                result.deinit(alloc);
                return failure(.control_commit_indeterminate);
            };
            if (try self.repairCommittedRelationshipProjection(
                alloc,
                relationship.id,
                record,
                result.receipt,
            )) |repair_failure| {
                result.deinit(alloc);
                return repair_failure;
            }
        } else if (next_parent) |parent| {
            if (try self.rollbackPrepublishedRelationshipIfUncommitted(
                alloc,
                target_store,
                parent,
                relationship.id,
            )) |repair_failure| {
                result.deinit(alloc);
                return repair_failure;
            }
        }
        if (result == .receipt and context.relationship_authorization == .approval) {
            self.consumeRelationshipApprovalLocked(
                alloc,
                &target.capability,
                relationship.id,
                context.relationship_authorization.approval,
                operation_id,
            );
        }
        return result;
    }

    fn invalidateResumableIndex(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
    ) ExecuteError!?Result {
        self.sessions.invalidateResumableIndex(alloc) catch |err| {
            return @as(
                ?Result,
                try self.relationshipProjectionRepairFailure(target_id, err),
            );
        };
        return null;
    }

    fn repairCommittedRelationshipProjection(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        record: control_store.Record,
        receipt: domain.OperationReceipt,
    ) ExecuteError!?Result {
        const event = eventForSequence(record, receipt.event_sequence) orelse
            return failure(.control_commit_indeterminate);
        switch (event.kind) {
            .relationship_changed => {},
            else => return failure(.control_commit_indeterminate),
        }
        if (record.parent_id) |parent| {
            _ = relationship_index.ensureChild(
                alloc,
                self.sessions,
                parent,
                child_id,
                self.options.child_store,
            ) catch |err| return @as(
                ?Result,
                try self.relationshipProjectionRepairFailure(child_id, err),
            );
        }
        for (record.events) |candidate| switch (candidate.kind) {
            .relationship_changed => |relationship| {
                if (relationship.parent_id) |parent| {
                    if (try self.removeStaleRelationshipProjection(
                        alloc,
                        child_id,
                        record.parent_id,
                        parent,
                    )) |repair_failure| return repair_failure;
                }
                if (relationship.previous_parent_id) |previous| {
                    if (try self.removeStaleRelationshipProjection(
                        alloc,
                        child_id,
                        record.parent_id,
                        previous,
                    )) |repair_failure| return repair_failure;
                }
            },
            else => {},
        };
        return self.invalidateResumableIndex(alloc, child_id);
    }

    fn removeStaleRelationshipProjection(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        current_parent: ?[]const u8,
        candidate_parent: []const u8,
    ) ExecuteError!?Result {
        if (current_parent) |parent| {
            if (std.mem.eql(u8, parent, candidate_parent)) return null;
        }
        _ = relationship_index.removeChild(
            alloc,
            self.sessions,
            candidate_parent,
            child_id,
            self.options.child_store,
        ) catch |err| switch (err) {
            error.SessionNotFound => return null,
            else => return @as(
                ?Result,
                try self.relationshipProjectionRepairFailure(child_id, err),
            ),
        };
        return null;
    }

    fn relationshipProjectionRepairFailure(
        self: *Manager,
        child_id: []const u8,
        err: anyerror,
    ) ExecuteError!Result {
        _ = self;
        debug_trace.logf(
            "subagent",
            "relationship projection repair pending child_id={s} outcome={s}",
            .{ child_id, @errorName(err) },
        );
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => failure(.control_commit_indeterminate),
        };
    }

    fn rollbackPrepublishedRelationshipIfUncommitted(
        self: *Manager,
        alloc: Allocator,
        store: control_store.Store,
        parent_id: []const u8,
        child_id: []const u8,
    ) ExecuteError!?Result {
        var observed = store.loadOptional(alloc) catch |err| {
            return @as(
                ?Result,
                try self.relationshipProjectionRepairFailure(child_id, err),
            );
        };
        defer if (observed) |*record| record.deinit(alloc);
        const committed = if (observed) |record|
            if (record.parent_id) |canonical_parent|
                std.mem.eql(u8, canonical_parent, parent_id)
            else
                false
        else
            false;
        if (committed) return null;
        const removed = relationship_index.removeChild(
            alloc,
            self.sessions,
            parent_id,
            child_id,
            self.options.child_store,
        ) catch |err| switch (err) {
            error.SessionNotFound => return null,
            else => return @as(
                ?Result,
                try self.relationshipProjectionRepairFailure(child_id, err),
            ),
        };
        if (!removed) return null;
        return self.invalidateResumableIndex(alloc, child_id);
    }

    fn mutateDetach(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        context: Context,
    ) ExecuteError!Result {
        const child_id = command.relationship.id;
        const previous_parent = try self.readCanonicalParent(alloc, child_id);
        defer if (previous_parent) |parent| alloc.free(parent);
        var previous_root: ?[]u8 = null;
        defer if (previous_root) |root| alloc.free(root);
        if (previous_parent) |parent| {
            var ancestry = self.discoverRelationshipLockIds(
                alloc,
                child_id,
                parent,
            ) catch null;
            if (ancestry) |*ids| {
                defer freeIds(alloc, ids);
                if (ids.items.len != 0) {
                    previous_root = try alloc.dupe(u8, ids.items[ids.items.len - 1]);
                }
            }
        }

        var result = try self.mutateOne(
            alloc,
            child_id,
            command,
            context,
            null,
        );
        if (result != .receipt) return result;
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.options.child_store,
        ) catch |err| {
            result.deinit(alloc);
            return self.relationshipProjectionRepairFailure(child_id, err);
        };
        defer capability.deinit();
        var store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = store.acquireLock() catch |err| {
            result.deinit(alloc);
            return self.relationshipProjectionRepairFailure(child_id, err);
        };
        defer lock.release();
        var committed = store.loadOptional(alloc) catch |err| {
            result.deinit(alloc);
            return self.relationshipProjectionRepairFailure(child_id, err);
        };
        defer if (committed) |*record| record.deinit(alloc);
        const record = committed orelse {
            result.deinit(alloc);
            return failure(.control_commit_indeterminate);
        };
        if (try self.repairCommittedRelationshipProjection(
            alloc,
            child_id,
            record,
            result.receipt,
        )) |repair_failure| {
            result.deinit(alloc);
            return repair_failure;
        }
        if (previous_parent) |parent| {
            if (previous_root) |root| {
                if (!std.mem.eql(u8, root, parent)) {
                    _ = relationship_index.bumpGeneration(
                        alloc,
                        self.sessions,
                        root,
                        self.options.child_store,
                    ) catch |err| {
                        debug_trace.logf(
                            "subagent",
                            "relationship root generation cleanup deferred root_id={s} outcome={s}",
                            .{ root, @errorName(err) },
                        );
                    };
                }
            }
        }
        return result;
    }

    fn readCanonicalParent(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
    ) ExecuteError!?[]u8 {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId,
            error.SessionNotFound,
            error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            error.SessionStoreUnavailable,
            error.SessionChildStoreFailed,
            => null,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = store.loadOptional(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
        defer if (record) |*value| value.deinit(alloc);
        return if (record) |value|
            if (value.parent_id) |parent| try alloc.dupe(u8, parent) else null
        else
            null;
    }

    fn probeRelationshipReplay(
        self: *Manager,
        alloc: Allocator,
        command: domain.Command,
        context: Context,
    ) ExecuteError!?Result {
        const relationship = command.relationship;
        const operation_id = context.operation_id orelse
            return failure(.operation_id_required);
        domain.validateOperationId(operation_id) catch
            return failure(.invalid_operation_id);
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            relationship.id,
            self.options.child_store,
        ) catch |err| return try mapOpenControlError(err);
        defer capability.deinit();
        var store = control_store.Store{
            .capability = &capability,
            .expected_child_id = relationship.id,
        };
        var lock = store.acquireLock() catch |err| return try mapControlLockError(err);
        defer lock.release();
        var current = store.loadOptional(alloc) catch |err| return try mapControlLoadError(err);
        defer if (current) |*record| record.deinit(alloc);
        const request_fingerprint = resolvedOperationFingerprints(
            command,
            context,
            relationship.id,
            null,
        ).request;
        const identity = trustedOperationIdentity(operation_id, context) orelse
            return failure(.invalid_operation_id);
        return switch (try existingOperation(
            alloc,
            current,
            operation_id,
            request_fingerprint,
            null,
            identity,
        )) {
            .absent => null,
            .conflict => failure(.operation_conflict),
            .expired => failure(.operation_replay_expired),
            .replay => |receipt_value| blk: {
                var receipt = receipt_value;
                if (current == null) {
                    receipt.deinit(alloc);
                    break :blk failure(.control_commit_indeterminate);
                }
                if (try self.repairCommittedRelationshipProjection(
                    alloc,
                    relationship.id,
                    current.?,
                    receipt,
                )) |repair_failure| {
                    receipt.deinit(alloc);
                    break :blk repair_failure;
                }
                if (context.relationship_authorization == .approval) {
                    self.consumeRelationshipApprovalLocked(
                        alloc,
                        &capability,
                        relationship.id,
                        context.relationship_authorization.approval,
                        operation_id,
                    );
                }
                break :blk .{ .receipt = receipt };
            },
        };
    }

    fn validateRelationshipApprovalLocked(
        self: *Manager,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        command: domain.RelationshipCommand,
        operation_id: []const u8,
        parent_id: []const u8,
        root_id: []const u8,
        approval_id: []const u8,
    ) error{OutOfMemory}!?FailureCode {
        _ = self;
        const store = communication_store.Store{
            .capability = capability,
            .expected_session_id = command.id,
        };
        var ledger = store.load(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CommunicationNotFound => .relationship_authorization_required,
            error.InvalidCommunicationRecord,
            error.UnsupportedCommunicationSchema,
            error.CommunicationRecordTooLarge,
            => .control_record_invalid,
            error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            error.CommunicationStoreFailed,
            => .store_failure,
        };
        defer ledger.deinit(alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            approval_id,
        ) orelse return .relationship_authorization_required;
        if (!relationshipApprovalMatches(
            approval.*,
            command,
            operation_id,
            parent_id,
            root_id,
        )) return .operation_conflict;
        return switch (approval.status) {
            .allowed_once => null,
            .pending => .relationship_authorization_required,
            .allowed_always,
            .denied,
            .cancelled,
            .stale,
            .consumed,
            => .operation_conflict,
        };
    }

    fn consumeRelationshipApprovalLocked(
        self: *Manager,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        child_id: []const u8,
        approval_id: []const u8,
        operation_id: []const u8,
    ) void {
        _ = self;
        const store = communication_store.Store{
            .capability = capability,
            .expected_session_id = child_id,
        };
        var ledger = store.load(alloc) catch |err| {
            traceRelationshipApprovalLag(approval_id, operation_id, err);
            return;
        };
        defer ledger.deinit(alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            approval_id,
        ) orelse {
            traceRelationshipApprovalLag(approval_id, operation_id, error.ApprovalMissing);
            return;
        };
        const relationship = approval.relationship orelse {
            traceRelationshipApprovalLag(approval_id, operation_id, error.ApprovalIdentityMismatch);
            return;
        };
        if (!std.mem.eql(u8, relationship.operation_id, operation_id)) {
            traceRelationshipApprovalLag(approval_id, operation_id, error.ApprovalIdentityMismatch);
            return;
        }
        if (approval.status == .consumed) return;
        if (approval.status != .allowed_once) {
            traceRelationshipApprovalLag(approval_id, operation_id, error.ApprovalNotConsumable);
            return;
        }
        const revision = std.math.add(u64, ledger.generation, 1) catch {
            traceRelationshipApprovalLag(approval_id, operation_id, error.GenerationExhausted);
            return;
        };
        approval.status = .consumed;
        approval.resolved_revision = revision;
        ledger.generation = revision;
        store.save(alloc, ledger) catch |err| {
            if (err == error.CommunicationCommitIndeterminate) {
                var observed = store.load(alloc) catch |load_err| {
                    traceRelationshipApprovalLag(approval_id, operation_id, load_err);
                    return;
                };
                defer observed.deinit(alloc);
                const stored = communication.findApproval(
                    observed.approvals,
                    approval_id,
                ) orelse {
                    traceRelationshipApprovalLag(approval_id, operation_id, err);
                    return;
                };
                if (stored.status == .consumed) return;
            }
            traceRelationshipApprovalLag(approval_id, operation_id, err);
        };
    }

    fn commitDecision(
        self: *Manager,
        alloc: Allocator,
        store: control_store.Store,
        decision: *Decision,
    ) ExecuteError!Result {
        return switch (decision.*) {
            .reject => |code| failure(code),
            .replay => |*maybe_receipt| blk: {
                const moved = maybe_receipt.*.?;
                maybe_receipt.* = null;
                break :blk .{ .receipt = moved };
            },
            .commit => |*commit| blk: {
                control_store.prepareForSave(alloc, &commit.record) catch |err| {
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.ControlRecordTooLarge => failure(.control_record_too_large),
                    };
                };
                store.save(alloc, commit.record) catch |err| {
                    if (err != error.ControlCommitIndeterminate) {
                        return mapControlSaveError(err);
                    }
                    var observed = store.load(alloc) catch |load_err| {
                        return switch (load_err) {
                            error.OutOfMemory => error.OutOfMemory,
                            error.ControlNotFound,
                            error.InvalidControlRecord,
                            error.UnsupportedControlSchema,
                            error.ControlRecordTooLarge,
                            error.ControlPathUnsafe,
                            error.PrivateStatePermissionsUnsupported,
                            error.ControlStoreFailed,
                            => failure(.control_commit_indeterminate),
                        };
                    };
                    defer observed.deinit(alloc);
                    if (!recordContainsReceipt(observed, commit.receipt.?)) {
                        return failure(.control_commit_indeterminate);
                    }
                    store.save(alloc, commit.record) catch |retry_err| {
                        return mapControlSaveError(retry_err);
                    };
                };
                if (self.options.publisher) |publisher| publisher.publish(commit.record);
                const moved = commit.receipt.?;
                commit.receipt = null;
                break :blk .{ .receipt = moved };
            },
        };
    }

    fn inspect(
        self: *Manager,
        alloc: Allocator,
        command: domain.InspectCommand,
        context: Context,
    ) ExecuteError!Result {
        return switch (context.target_authorization) {
            .none => self.inspectUnrestricted(alloc, command),
            .attached_to_root => |root_id| self.inspectAuthorized(
                alloc,
                command,
                context.actor_id,
                root_id,
            ),
        };
    }

    fn inspectUnrestricted(
        self: *Manager,
        alloc: Allocator,
        command: domain.InspectCommand,
    ) ExecuteError!Result {
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            command.id,
            self.options.child_store,
        ) catch |err| return mapOpenControlError(err);
        defer capability.deinit();
        return self.inspectWithCapability(alloc, command, &capability);
    }

    fn inspectAuthorized(
        self: *Manager,
        alloc: Allocator,
        command: domain.InspectCommand,
        actor_id: []const u8,
        root_id: []const u8,
    ) ExecuteError!Result {
        for (0..2) |_| {
            if (try self.inspectAuthorizedAttempt(
                alloc,
                command,
                actor_id,
                root_id,
            )) |result| return result;
        }
        return failure(.graph_changed);
    }

    fn inspectAuthorizedAttempt(
        self: *Manager,
        alloc: Allocator,
        command: domain.InspectCommand,
        actor_id: []const u8,
        root_id: []const u8,
    ) ExecuteError!?Result {
        var lock_ids = self.discoverTargetAuthorizationLockIds(
            alloc,
            command.id,
        ) catch |err| return @as(?Result, try mapRelationshipDiscoveryError(err));
        defer freeIds(alloc, &lock_ids);
        sortIds(lock_ids.items);

        var locked = LockedSet.acquire(
            alloc,
            self.sessions,
            lock_ids.items,
            self.options.child_store,
        ) catch |err| return @as(?Result, try mapLockedAcquireError(err));
        defer locked.deinit(alloc);
        var graph = loadLockedGraph(alloc, &locked) catch |err|
            return @as(?Result, try mapControlLoadError(err));
        defer graph.deinit(alloc);
        switch (targetAuthorizationDecision(
            graph.edges.items,
            command.id,
            actor_id,
            root_id,
        )) {
            .authorized => {},
            .unauthorized => return failure(.child_unavailable),
            .graph_changed => return null,
        }

        const target = locked.find(command.id) orelse return failure(.graph_changed);
        return @as(
            ?Result,
            try self.inspectWithCapability(alloc, command, &target.capability),
        );
    }

    fn inspectWithCapability(
        self: *Manager,
        alloc: Allocator,
        command: domain.InspectCommand,
        capability: *session_child_store.SessionChildCapability,
    ) ExecuteError!Result {
        var store = control_store.Store{
            .capability = capability,
            .expected_child_id = command.id,
        };
        var record = store.load(alloc) catch |err| return mapControlLoadError(err);
        defer record.deinit(alloc);

        const cursor = if (command.cursor) |raw|
            domain.parseCursor(raw) catch return failure(.control_record_invalid)
        else
            null;
        const includes_messages = hasSection(command.sections, .messages);
        const includes_events = hasSection(command.sections, .events);
        const total = (if (includes_messages) record.queue.len else 0) +
            (if (includes_events) record.events.len else 0);
        const page = domain.decidePage(
            total,
            record.generation,
            cursor,
            command.limit,
        ) catch return failure(.control_record_invalid);
        if (page == .stale_cursor) {
            const child_id = try alloc.dupe(u8, record.child_id);
            errdefer alloc.free(child_id);
            const messages = try alloc.alloc(domain.QueuedMessage, 0);
            errdefer alloc.free(messages);
            const history = try alloc.alloc(InspectedHistoryTurn, 0);
            errdefer alloc.free(history);
            const events = try alloc.alloc(domain.Event, 0);
            errdefer alloc.free(events);
            const tool_activity = try alloc.alloc(InspectedToolActivity, 0);
            return .{ .inspection = .{
                .child_id = child_id,
                .generation = record.generation,
                .restart_required = true,
                .messages = messages,
                .history = history,
                .events = events,
                .tool_activity = tool_activity,
            } };
        }

        const window = page.page;
        var messages: std.ArrayList(domain.QueuedMessage) = .empty;
        errdefer {
            for (messages.items) |*message| message.deinit(alloc);
            messages.deinit(alloc);
        }
        var events: std.ArrayList(domain.Event) = .empty;
        errdefer {
            for (events.items) |*event| event.deinit(alloc);
            events.deinit(alloc);
        }
        var combined_index: usize = 0;
        if (includes_messages) {
            for (record.queue) |message| {
                if (combined_index >= window.start and combined_index < window.end) {
                    var cloned = try message.clone(alloc);
                    errdefer cloned.deinit(alloc);
                    try messages.append(alloc, cloned);
                }
                combined_index += 1;
            }
        }
        if (includes_events) {
            for (record.events) |event| {
                if (combined_index >= window.start and combined_index < window.end) {
                    var cloned = try event.clone(alloc);
                    errdefer cloned.deinit(alloc);
                    try events.append(alloc, cloned);
                }
                combined_index += 1;
            }
        }

        const child_id = try alloc.dupe(u8, record.child_id);
        errdefer alloc.free(child_id);
        var configuration = if (hasSection(command.sections, .configuration))
            try record.configuration.clone(alloc)
        else
            null;
        errdefer if (configuration) |*value| value.deinit(alloc);
        const parent_id = if (hasSection(command.sections, .relationship))
            if (record.parent_id) |id| try alloc.dupe(u8, id) else null
        else
            null;
        errdefer if (parent_id) |id| alloc.free(id);
        const owned_messages = try messages.toOwnedSlice(alloc);
        errdefer freeMessages(alloc, owned_messages);
        const owned_events = try events.toOwnedSlice(alloc);
        errdefer freeEventSlice(alloc, owned_events);
        var history_projection = if (includes_messages and cursor == null)
            try self.loadInspectedHistory(alloc, record.child_id, command.limit)
        else
            HistoryProjection{ .turns = try alloc.alloc(InspectedHistoryTurn, 0) };
        errdefer history_projection.deinit(alloc);
        var tool_activity_projection = if (hasSection(command.sections, .tool_activity) and
            cursor == null)
            try loadInspectedToolActivity(
                alloc,
                capability,
                record.child_id,
                command.limit,
            )
        else
            ToolActivityProjection{ .activity = try alloc.alloc(InspectedToolActivity, 0) };
        errdefer tool_activity_projection.deinit(alloc);
        const failure_projection = if ((hasSection(command.sections, .status) or includes_messages) and
            cursor == null)
            try cloneLatestFailure(alloc, record.events)
        else
            FailureProjection{};
        errdefer {
            if (failure_projection.work_id) |id| alloc.free(id);
            if (failure_projection.reason) |reason| alloc.free(reason);
        }
        const next_cursor = if (window.has_more)
            try domain.encodeCursor(alloc, .{
                .generation = record.generation,
                .offset = window.end,
            })
        else
            null;
        return .{ .inspection = .{
            .child_id = child_id,
            .generation = record.generation,
            .restart_required = record.events_evicted_through != 0 or record.queue_evicted,
            .status = if (hasSection(command.sections, .status)) record.state else null,
            .configuration = configuration,
            .relationship_selected = hasSection(command.sections, .relationship),
            .parent_id = parent_id,
            .messages = owned_messages,
            .history = history_projection.turns,
            .history_len = history_projection.history_len,
            .history_truncated = history_projection.truncated,
            .history_error = history_projection.source_error,
            .events = owned_events,
            .tool_activity_selected = hasSection(command.sections, .tool_activity),
            .tool_activity = tool_activity_projection.activity,
            .tool_activity_truncated = tool_activity_projection.truncated,
            .tool_activity_error = tool_activity_projection.source_error,
            .failure_work_id = failure_projection.work_id,
            .failure_reason = failure_projection.reason,
            .next_cursor = next_cursor,
        } };
    }

    fn loadInspectedHistory(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        limit: usize,
    ) Allocator.Error!HistoryProjection {
        var page = self.sessions.loadHistoryPage(
            alloc,
            child_id,
            null,
            limit,
        ) catch |err| {
            const turns = try alloc.alloc(InspectedHistoryTurn, 0);
            return .{
                .turns = turns,
                .source_error = switch (err) {
                    error.SessionNotFound => .not_found,
                    error.InvalidSessionId,
                    error.InvalidHistoryPageLimit,
                    error.InvalidHistoryPageCursor,
                    error.StaleHistoryPageCursor,
                    error.UnsupportedSessionFormat,
                    error.CorruptSession,
                    => .invalid,
                    error.SessionPathUnsafe,
                    error.SessionStoreUnavailable,
                    => .unavailable,
                    error.OutOfMemory => return error.OutOfMemory,
                },
            };
        };
        defer page.deinit(alloc);

        var projected: std.ArrayList(InspectedHistoryTurn) = .empty;
        errdefer {
            for (projected.items) |*turn| turn.deinit(alloc);
            projected.deinit(alloc);
        }
        var remaining = max_inspected_history_text_bytes;
        var index = page.turns.len;
        while (index > 0 and projected.items.len < limit) {
            index -= 1;
            const view = historyTurnView(page.turns[index]);
            if (remaining == 0 and (view.user != null or view.assistant != null)) break;

            var turn = InspectedHistoryTurn{ .kind = view.kind };
            errdefer turn.deinit(alloc);
            if (view.work_id) |work_id| turn.work_id = try alloc.dupe(u8, work_id);
            if (view.assistant) |assistant| {
                const retained = text_utils.utf8PrefixByBytes(
                    assistant,
                    @min(remaining, max_inspected_history_field_bytes),
                );
                turn.assistant = try alloc.dupe(u8, retained);
                turn.assistant_truncated = retained.len != assistant.len;
                remaining -= retained.len;
            }
            if (view.user) |user| {
                const retained = text_utils.utf8PrefixByBytes(
                    user,
                    @min(remaining, max_inspected_history_field_bytes),
                );
                turn.user = try alloc.dupe(u8, retained);
                turn.user_truncated = retained.len != user.len;
                remaining -= retained.len;
            }
            try projected.append(alloc, turn);
        }
        std.mem.reverse(InspectedHistoryTurn, projected.items);
        return .{
            .turns = try projected.toOwnedSlice(alloc),
            .history_len = page.history_len,
            .truncated = page.next_cursor != null or index != 0,
        };
    }

    fn loadBootstrapConfiguration(
        self: *Manager,
        alloc: Allocator,
        session_id: []const u8,
    ) BootstrapError!domain.Configuration {
        var metadata = self.sessions.loadSubagentBootstrapMetadata(
            alloc,
            session_id,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SessionNotFound, error.InvalidSessionId => error.SessionNotFound,
                error.SessionPathUnsafe => error.SessionPathUnsafe,
                error.SessionMetadataUnavailable => error.StoreFailure,
            };
        };
        defer metadata.deinit(alloc);
        const name = try alloc.dupe(u8, metadata.name);
        errdefer alloc.free(name);
        const model = try alloc.dupe(u8, metadata.preferences.model);
        errdefer alloc.free(model);
        return .{
            .name = name,
            .model = model,
            .effort = metadata.preferences.effort,
            .notifications = domain.validateNotificationPolicy(alloc, .{}) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.StoreFailure,
                };
            },
        };
    }

    fn discoverRelationshipLockIds(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        parent_id: []const u8,
    ) RelationshipDiscoveryError!std.ArrayList([]u8) {
        var ids: std.ArrayList([]u8) = .empty;
        errdefer freeIds(alloc, &ids);
        try appendUniqueId(alloc, &ids, child_id);
        try self.appendAncestryLockIds(alloc, &ids, parent_id);
        return ids;
    }

    fn discoverTargetAuthorizationLockIds(
        self: *Manager,
        alloc: Allocator,
        target_id: []const u8,
    ) RelationshipDiscoveryError!std.ArrayList([]u8) {
        var ids: std.ArrayList([]u8) = .empty;
        errdefer freeIds(alloc, &ids);
        try self.appendAncestryLockIds(alloc, &ids, target_id);
        return ids;
    }

    fn appendAncestryLockIds(
        self: *Manager,
        alloc: Allocator,
        ids: *std.ArrayList([]u8),
        start_id: []const u8,
    ) RelationshipDiscoveryError!void {
        var cursor: ?[]u8 = try alloc.dupe(u8, start_id);
        defer if (cursor) |id| alloc.free(id);
        var depth: usize = 0;
        while (cursor) |id| {
            if (depth == max_ancestry_depth) return error.GraphTooDeep;
            depth += 1;
            if (containsId(ids.items, id)) return error.RelationshipCycle;
            try appendUniqueId(alloc, ids, id);
            var capability = self.sessions.openSubagentControlCapabilityReadOnly(
                alloc,
                id,
                self.options.child_store,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSessionId, error.SessionNotFound => error.SessionNotFound,
                error.SessionPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => error.ControlPathUnsafe,
                error.SessionStoreUnavailable,
                error.SessionChildStoreFailed,
                => error.StoreFailure,
            };
            defer capability.deinit();
            const store = control_store.Store{
                .capability = &capability,
                .expected_child_id = id,
            };
            var record = store.loadOptional(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidControlRecord,
                error.UnsupportedControlSchema,
                => error.ControlRecordInvalid,
                error.ControlRecordTooLarge => error.ControlRecordTooLarge,
                error.ControlPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => error.ControlPathUnsafe,
                error.ControlNotFound, error.ControlStoreFailed => error.StoreFailure,
            };
            defer if (record) |*value| value.deinit(alloc);
            const next = if (record) |value|
                if (value.parent_id) |parent_id| try alloc.dupe(u8, parent_id) else null
            else
                null;
            alloc.free(id);
            cursor = next;
        }
    }
};

const max_snapshot_diagnostics = domain.max_page_limit;

fn recordContainsReceipt(
    record: control_store.Record,
    expected: domain.OperationReceipt,
) bool {
    if (record.generation != expected.generation) return false;
    for (record.operations) |operation| {
        if (!std.mem.eql(u8, operation.id, expected.id)) continue;
        return std.mem.eql(
            u8,
            &operation.request_fingerprint,
            &expected.request_fingerprint,
        ) and
            std.mem.eql(u8, &operation.fingerprint, &expected.fingerprint) and
            operation.code == expected.code and
            std.mem.eql(u8, operation.target_id, expected.target_id) and
            operation.generation == expected.generation and
            operation.event_sequence == expected.event_sequence and
            operation.identity_source == expected.identity_source and
            operation.identity_epoch == expected.identity_epoch;
    }
    return false;
}

const Decision = union(enum) {
    reject: FailureCode,
    replay: ?domain.OperationReceipt,
    commit: struct {
        record: control_store.Record,
        receipt: ?domain.OperationReceipt,
    },

    fn deinit(self: *Decision, alloc: Allocator) void {
        switch (self.*) {
            .reject => {},
            .replay => |*receipt| if (receipt.*) |*value| value.deinit(alloc),
            .commit => |*commit| {
                commit.record.deinit(alloc);
                if (commit.receipt) |*receipt| receipt.deinit(alloc);
            },
        }
        self.* = undefined;
    }
};

fn reduce(
    alloc: Allocator,
    current: ?control_store.Record,
    command: domain.Command,
    context: Context,
    target_id: []const u8,
    bootstrap: ?domain.Configuration,
) ExecuteError!Decision {
    const operation_id = context.operation_id orelse
        return .{ .reject = .operation_id_required };
    domain.validateOperationId(operation_id) catch
        return .{ .reject = .invalid_operation_id };
    const identity = trustedOperationIdentity(operation_id, context) orelse
        return .{ .reject = .invalid_operation_id };
    const fingerprints = resolvedOperationFingerprints(command, context, target_id, bootstrap);
    switch (try existingOperation(
        alloc,
        current,
        operation_id,
        fingerprints.request,
        fingerprints.legacy_request,
        identity,
    )) {
        .absent => {},
        .conflict => return .{ .reject = .operation_conflict },
        .expired => return .{ .reject = .operation_replay_expired },
        .replay => |receipt| return .{ .replay = receipt },
    }
    const current_generation = if (current) |record| record.generation else 0;
    if (context.expected_generation) |expected| {
        if (expected != current_generation) return .{ .reject = .stale_generation };
    }
    if (current_generation == std.math.maxInt(u64)) {
        return .{ .reject = .generation_exhausted };
    }

    return switch (command) {
        .create => |create| reduceCreate(
            alloc,
            current,
            create,
            context,
            target_id,
            operation_id,
            fingerprints,
        ),
        .message => |message| switch (message) {
            .send => |send| reduceSend(
                alloc,
                current,
                send.id,
                send.content,
                context,
                operation_id,
                fingerprints,
            ),
            .milestone => .{ .reject = .milestone_requires_active_work },
        },
        .relationship => |relationship| reduceRelationship(
            alloc,
            current,
            relationship,
            context,
            operation_id,
            fingerprints,
            bootstrap,
        ),
        .configure => |configure| reduceConfigure(
            alloc,
            current,
            configure,
            context,
            operation_id,
            fingerprints,
        ),
        .lifecycle => |lifecycle| reduceLifecycle(
            alloc,
            current,
            lifecycle,
            context,
            operation_id,
            fingerprints,
        ),
        .inspect => .{ .reject = .store_failure },
    };
}

fn reduceMilestone(
    alloc: Allocator,
    current: control_store.Record,
    ledger: communication.Ledger,
    command: domain.Command,
    name: []const u8,
    context: Context,
    operation_id: []const u8,
) ExecuteError!Decision {
    if (!std.mem.eql(u8, current.child_id, context.actor_id) or
        current.parent_id == null)
    {
        return .{ .reject = .invalid_milestone_caller };
    }
    const fingerprints = resolvedOperationFingerprints(
        command,
        context,
        current.child_id,
        null,
    );
    const identity = trustedOperationIdentity(operation_id, context) orelse
        return .{ .reject = .invalid_operation_id };
    switch (try existingOperation(
        alloc,
        current,
        operation_id,
        fingerprints.request,
        null,
        identity,
    )) {
        .absent => {},
        .conflict => return .{ .reject = .operation_conflict },
        .expired => return .{ .reject = .operation_replay_expired },
        .replay => |receipt| return .{ .replay = receipt },
    }
    if (context.expected_generation) |expected| {
        if (expected != current.generation) return .{ .reject = .stale_generation };
    }
    var active: ?domain.QueuedMessage = null;
    for (current.queue) |message| {
        if (message.status == .running) {
            active = message;
            break;
        }
    }
    const work = active orelse return .{ .reject = .no_active_work };
    const notification = communication.findWorkNotification(
        ledger.work_notifications,
        work.id,
    ) orelse return .{ .reject = .undeclared_milestone };
    if (!communication.milestoneDeclared(notification.*, name)) {
        return .{ .reject = .undeclared_milestone };
    }
    if (findMilestoneEvent(current.events, name, work.id)) |existing| {
        for (current.operations) |receipt| {
            const event = eventForSequence(current, receipt.event_sequence) orelse continue;
            if (event.kind != .milestone_emitted) continue;
            if (std.mem.eql(u8, event.id, existing.operation_id)) {
                return .{ .replay = try receipt.clone(alloc) };
            }
        }
        return .{ .reject = .invalid_state };
    }
    var next: ?control_store.Record = try current.clone(alloc);
    errdefer if (next) |*record| record.deinit(alloc);
    var owned_operation_id: ?[]u8 = try alloc.dupe(u8, operation_id);
    errdefer if (owned_operation_id) |value| alloc.free(value);
    var source_child_id: ?[]u8 = try alloc.dupe(u8, current.child_id);
    errdefer if (source_child_id) |value| alloc.free(value);
    var target_parent_id: ?[]u8 = try alloc.dupe(u8, current.parent_id.?);
    errdefer if (target_parent_id) |value| alloc.free(value);
    var work_item_id: ?[]u8 = try alloc.dupe(u8, work.id);
    errdefer if (work_item_id) |value| alloc.free(value);
    var owned_name: ?[]u8 = try alloc.dupe(u8, name);
    errdefer if (owned_name) |value| alloc.free(value);
    const event_kind: domain.EventKind = .{ .milestone_emitted = .{
        .operation_id = owned_operation_id.?,
        .source_child_id = source_child_id.?,
        .target_parent_id = target_parent_id.?,
        .work_item_id = work_item_id.?,
        .name = owned_name.?,
    } };
    owned_operation_id = null;
    source_child_id = null;
    target_parent_id = null;
    work_item_id = null;
    owned_name = null;
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .milestone_emitted,
        event_kind,
        context.timestamp_ms,
    );
}

const MilestoneView = struct {
    operation_id: []const u8,
    source_child_id: []const u8,
    target_parent_id: []const u8,
    work_item_id: []const u8,
    name: []const u8,
    timestamp_ms: i64,
};

fn findMilestoneEvent(
    events: []const domain.Event,
    name: []const u8,
    work_id: ?[]const u8,
) ?MilestoneView {
    for (events) |event| switch (event.kind) {
        .milestone_emitted => |milestone| {
            if (!std.mem.eql(u8, milestone.name, name)) continue;
            if (work_id) |id| {
                if (!std.mem.eql(u8, milestone.work_item_id, id)) continue;
            }
            return .{
                .operation_id = milestone.operation_id,
                .source_child_id = milestone.source_child_id,
                .target_parent_id = milestone.target_parent_id,
                .work_item_id = milestone.work_item_id,
                .name = milestone.name,
                .timestamp_ms = event.timestamp_ms,
            };
        },
        else => {},
    };
    return null;
}

fn milestoneEventForReceipt(
    record: control_store.Record,
    receipt: domain.OperationReceipt,
) ?MilestoneView {
    const event = eventForSequence(record, receipt.event_sequence) orelse return null;
    if (event.kind != .milestone_emitted) return null;
    const milestone = event.kind.milestone_emitted;
    return .{
        .operation_id = milestone.operation_id,
        .source_child_id = milestone.source_child_id,
        .target_parent_id = milestone.target_parent_id,
        .work_item_id = milestone.work_item_id,
        .name = milestone.name,
        .timestamp_ms = event.timestamp_ms,
    };
}

fn eventForSequence(
    record: control_store.Record,
    sequence: u64,
) ?domain.Event {
    if (sequence <= record.events_evicted_through or
        sequence >= record.next_event_sequence)
    {
        return null;
    }
    const index = sequence - record.events_evicted_through - 1;
    if (index >= record.events.len) return null;
    return record.events[@intCast(index)];
}

const OperationFingerprints = struct {
    request: [32]u8,
    legacy_request: ?[32]u8,
    effect: [32]u8,
};

const ExistingOperation = union(enum) {
    absent,
    conflict,
    expired,
    replay: domain.OperationReceipt,
};

const TrustedOperationIdentity = union(enum) {
    legacy,
    bound: struct {
        identity: domain.BoundOperationIdentity,
        admitted: bool,
    },
};

fn trustedOperationIdentity(
    operation_id: []const u8,
    context: Context,
) ?TrustedOperationIdentity {
    const parsed = tool_result.parseBoundOperationId(operation_id);
    if (context.operation_identity_source == null or
        context.operation_identity_epoch == null)
    {
        if (context.operation_identity_source != null or
            context.operation_identity_epoch != null or parsed != null)
        {
            return null;
        }
        return .legacy;
    }
    const bound = parsed orelse return null;
    if (bound.source != context.operation_identity_source.? or
        bound.epoch != context.operation_identity_epoch.?)
    {
        return null;
    }
    return .{ .bound = .{
        .identity = bound,
        .admitted = context.operation_identity_admitted,
    } };
}

fn existingOperation(
    alloc: Allocator,
    current: ?control_store.Record,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    legacy_request_fingerprint: ?[32]u8,
    identity: TrustedOperationIdentity,
) ExecuteError!ExistingOperation {
    const record = current orelse return switch (identity) {
        .legacy => .absent,
        .bound => |bound| switch (bound.identity.authority) {
            .process_local => .expired,
            .manager => if (bound.admitted) .absent else .expired,
        },
    };
    for (record.operations) |operation| {
        if (!std.mem.eql(u8, operation.id, operation_id) or
            !receiptIdentityMatches(operation, identity)) continue;
        if (!std.mem.eql(
            u8,
            &operation.request_fingerprint,
            &request_fingerprint,
        ) and (legacy_request_fingerprint == null or !std.mem.eql(
            u8,
            &operation.request_fingerprint,
            &legacy_request_fingerprint.?,
        ))) return .conflict;
        return .{ .replay = try operation.clone(alloc) };
    }
    return switch (identity) {
        .legacy => if (record.legacy_replay_closed) .expired else .absent,
        .bound => |bound| switch (bound.identity.authority) {
            .process_local => .expired,
            .manager => if (bound.identity.epoch < switch (bound.identity.source) {
                .model => record.model_replay_floor,
                .human => record.human_replay_floor,
            } or !bound.admitted)
                .expired
            else
                .absent,
        },
    };
}

fn receiptIdentityMatches(
    receipt: domain.OperationReceipt,
    identity: TrustedOperationIdentity,
) bool {
    return switch (identity) {
        .legacy => receipt.identity_source == null and receipt.identity_epoch == null,
        .bound => |bound| receipt.identity_source == bound.identity.source and
            receipt.identity_epoch == bound.identity.epoch,
    };
}

fn resolvedOperationFingerprints(
    command: domain.Command,
    context: Context,
    target_id: []const u8,
    bootstrap: ?domain.Configuration,
) OperationFingerprints {
    const source_id: ?[]const u8 = switch (command) {
        .create => |create| if (create.prompt != null) context.actor_id else null,
        .message => |message| switch (message) {
            .send => context.actor_id,
            .milestone => context.actor_id,
        },
        .inspect, .relationship, .configure, .lifecycle => null,
    };
    const effective_parent_id: ?[]const u8 = switch (command) {
        .create => context.actor_id,
        .relationship => |relationship| switch (relationship.action) {
            .attach => relationship.parent_id orelse context.actor_id,
            .detach => null,
            .reparent => relationship.parent_id.?,
        },
        .inspect, .message, .configure, .lifecycle => null,
    };
    const request = domain.OperationRequestFingerprintInput{
        .command = command,
        .actor_id = context.actor_id,
        .target_id = target_id,
        .source_id = source_id,
        .effective_parent_id = effective_parent_id,
    };
    const request_fingerprint = domain.operationRequestFingerprint(request);
    return .{
        .request = switch (command) {
            .relationship => relationshipRequestFingerprint(
                request_fingerprint,
                context.relationship_authorization,
            ),
            .create, .inspect, .message, .configure, .lifecycle => request_fingerprint,
        },
        .legacy_request = domain.legacyImplicitAutoCreateRequestFingerprint(
            request,
        ),
        .effect = domain.operationFingerprint(.{
            .command = command,
            .actor_id = context.actor_id,
            .target_id = target_id,
            .source_id = source_id,
            .effective_parent_id = effective_parent_id,
            .bootstrap_configuration = switch (command) {
                .relationship => |relationship| if (relationship.action == .attach)
                    bootstrap
                else
                    null,
                .create, .inspect, .message, .configure, .lifecycle => null,
            },
        }),
    };
}

fn relationshipRequestFingerprint(
    command_fingerprint: [32]u8,
    authorization: RelationshipAuthorization,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.relationship-request.v1\x00");
    hash.update(&command_fingerprint);
    switch (authorization) {
        .none => hash.update("none\x00"),
        .direct => hash.update("direct\x00"),
        .approval => |approval_id| {
            hash.update("approval\x00");
            hash.update(approval_id);
            hash.update("\x00");
        },
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn reduceCreate(
    alloc: Allocator,
    current: ?control_store.Record,
    command: domain.CreateCommand,
    context: Context,
    target_id: []const u8,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
) ExecuteError!Decision {
    if (current != null) return .{ .reject = .invalid_state };
    if (command.prompt != null and context.root_user_intent_context.len > 0 and
        !auto_classifier_context.isCanonicalRootUserContext(
            context.root_user_intent_context,
        ))
    {
        return .{ .reject = .store_failure };
    }
    var next: ?control_store.Record = try buildCreateRecord(
        alloc,
        command,
        context,
        target_id,
        operation_id,
    );
    errdefer if (next) |*record| record.deinit(alloc);
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .created,
        .created,
        context.timestamp_ms,
    );
}

fn buildCreateRecord(
    alloc: Allocator,
    command: domain.CreateCommand,
    context: Context,
    target_id: []const u8,
    operation_id: []const u8,
) !control_store.Record {
    const child_id = try alloc.dupe(u8, target_id);
    errdefer alloc.free(child_id);
    const parent_id = try alloc.dupe(u8, context.actor_id);
    errdefer alloc.free(parent_id);
    var configuration = try command.configuration.clone(alloc);
    errdefer configuration.deinit(alloc);
    const queue = if (command.prompt) |prompt| blk: {
        var message = try makeQueuedMessage(
            alloc,
            operation_id,
            context.actor_id,
            prompt,
            context.root_user_intent_context,
            context.root_user_messages,
            context.root_user_evidence_complete,
            context.timestamp_ms,
        );
        errdefer message.deinit(alloc);
        const messages = try alloc.alloc(domain.QueuedMessage, 1);
        messages[0] = message;
        break :blk messages;
    } else try alloc.alloc(domain.QueuedMessage, 0);
    errdefer freeMessages(alloc, queue);
    const events = try alloc.alloc(domain.Event, 0);
    errdefer alloc.free(events);
    const operations = try alloc.alloc(domain.OperationReceipt, 0);
    return .{
        .child_id = child_id,
        .generation = 0,
        .parent_id = parent_id,
        .mode = command.mode,
        .configuration = configuration,
        .state = if (command.prompt != null) .queued else .idle,
        .queue = queue,
        .events = events,
        .operations = operations,
        .next_event_sequence = 1,
        .notification_cursor = 0,
        .created_at_ms = context.timestamp_ms,
        .updated_at_ms = context.timestamp_ms,
    };
}

fn reduceSend(
    alloc: Allocator,
    current: ?control_store.Record,
    target_id: []const u8,
    content: []const u8,
    context: Context,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
) ExecuteError!Decision {
    const source = current orelse return .{ .reject = .control_not_found };
    if (!std.mem.eql(u8, source.child_id, target_id)) return .{ .reject = .store_failure };
    const direct_parent = source.parent_id != null and
        std.mem.eql(u8, source.parent_id.?, context.actor_id);
    const authorized_root = switch (context.target_authorization) {
        .none => false,
        .attached_to_root => |root_id| std.mem.eql(
            u8,
            root_id,
            context.actor_id,
        ),
    };
    if (!direct_parent and !authorized_root) {
        return .{ .reject = .invalid_state };
    }
    if (source.mode == .one_off) return .{ .reject = .one_off_not_messageable };
    if (source.state == .archived or source.state == .completed or
        source.state == .failed or source.state == .cancelled)
    {
        return .{ .reject = .invalid_state };
    }
    if (context.root_user_intent_context.len > 0 and
        !auto_classifier_context.isCanonicalRootUserContext(
            context.root_user_intent_context,
        ))
    {
        return .{ .reject = .store_failure };
    }
    var next: ?control_store.Record = try source.clone(alloc);
    errdefer if (next) |*record| record.deinit(alloc);
    var message: ?domain.QueuedMessage = try makeQueuedMessage(
        alloc,
        operation_id,
        context.actor_id,
        content,
        context.root_user_intent_context,
        context.root_user_messages,
        context.root_user_evidence_complete,
        context.timestamp_ms,
    );
    errdefer if (message) |*value| value.deinit(alloc);
    try appendMessage(alloc, &next.?, &message.?);
    message = null;
    if (next.?.state == .idle) next.?.state = .queued;
    const message_id = try alloc.dupe(u8, operation_id);
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .message_queued,
        .{ .message_queued = .{ .message_id = message_id } },
        context.timestamp_ms,
    );
}

fn reduceRelationship(
    alloc: Allocator,
    current: ?control_store.Record,
    command: domain.RelationshipCommand,
    context: Context,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
    bootstrap: ?domain.Configuration,
) ExecuteError!Decision {
    if ((command.action == .attach or command.action == .reparent) and
        context.relationship_authorization == .none)
    {
        return .{ .reject = .relationship_authorization_required };
    }
    var next: ?control_store.Record = if (current) |record|
        try record.clone(alloc)
    else blk: {
        const configuration = bootstrap orelse return .{ .reject = .control_not_found };
        break :blk try detachedRecord(
            alloc,
            command.id,
            configuration,
            context.timestamp_ms,
        );
    };
    defer if (next) |*record| record.deinit(alloc);
    if (!canMutateRelationship(next.?.mode, command.action)) {
        return .{ .reject = .invalid_state };
    }
    for (next.?.queue) |work| switch (work.status) {
        .running, .awaiting_approval => return .{ .reject = .invalid_state },
        else => {},
    };
    var previous_parent = if (next.?.parent_id) |id| try alloc.dupe(u8, id) else null;
    defer if (previous_parent) |id| alloc.free(id);
    const proposed_parent = switch (command.action) {
        .attach => command.parent_id orelse context.actor_id,
        .detach => null,
        .reparent => command.parent_id.?,
    };
    switch (command.action) {
        .attach => if (next.?.parent_id != null) {
            return .{ .reject = .relationship_already_parented };
        },
        .detach => if (next.?.parent_id == null) {
            return .{ .reject = .relationship_missing_parent };
        },
        .reparent => if (next.?.parent_id == null) {
            return .{ .reject = .relationship_missing_parent };
        },
    }
    const replacement_parent = if (proposed_parent) |id|
        try alloc.dupe(u8, id)
    else
        null;
    if (next.?.parent_id) |old| alloc.free(old);
    next.?.parent_id = replacement_parent;
    const event_parent = if (proposed_parent) |id| try alloc.dupe(u8, id) else null;
    const event_kind: domain.EventKind = .{ .relationship_changed = .{
        .previous_parent_id = previous_parent,
        .parent_id = event_parent,
    } };
    previous_parent = null;
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .relationship_changed,
        event_kind,
        context.timestamp_ms,
    );
}

fn canMutateRelationship(
    target_mode: domain.Mode,
    action: domain.RelationshipAction,
) bool {
    return target_mode != .one_off or
        (action != .detach and action != .reparent);
}

fn isTerminalOneOff(mode: domain.Mode, state: domain.State) bool {
    if (mode != .one_off) return false;
    return switch (state) {
        .completed, .failed, .cancelled => true,
        .idle,
        .queued,
        .running,
        .awaiting_approval,
        .interrupted,
        .archived,
        => false,
    };
}

fn reduceConfigure(
    alloc: Allocator,
    current: ?control_store.Record,
    command: domain.ConfigureCommand,
    context: Context,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
) ExecuteError!Decision {
    const source = current orelse return .{ .reject = .control_not_found };
    if (source.state != .idle) return .{ .reject = .invalid_state };
    var next: ?control_store.Record = try source.clone(alloc);
    errdefer if (next) |*record| record.deinit(alloc);
    if (command.name) |name| {
        const replacement = try alloc.dupe(u8, name);
        alloc.free(next.?.configuration.name);
        next.?.configuration.name = replacement;
    }
    if (command.model) |model| {
        const replacement = try alloc.dupe(u8, model);
        if (next.?.configuration.model) |old| alloc.free(old);
        next.?.configuration.model = replacement;
    }
    if (command.effort) |effort| next.?.configuration.effort = effort;
    if (command.permission_mode) |permission_mode| {
        next.?.configuration.permission_mode = permission_mode;
    }
    if (command.notifications) |notifications| {
        const replacement = try notifications.clone(alloc);
        next.?.configuration.notifications.deinit(alloc);
        next.?.configuration.notifications = replacement;
    }
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .configured,
        .configured,
        context.timestamp_ms,
    );
}

fn reduceLifecycle(
    alloc: Allocator,
    current: ?control_store.Record,
    command: domain.LifecycleCommand,
    context: Context,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
) ExecuteError!Decision {
    const source = current orelse return .{ .reject = .control_not_found };
    var next: ?control_store.Record = try source.clone(alloc);
    errdefer if (next) |*record| record.deinit(alloc);
    const previous = next.?.state;
    const has_pending = if (command.action == .@"resume")
        hasResumableMessages(next.?.queue)
    else
        hasPendingMessages(next.?.queue);
    const next_state = domain.nextLifecycleState(
        next.?.mode,
        next.?.state,
        command.action,
        has_pending,
        next.?.archived_from,
    ) catch return .{ .reject = .invalid_state };
    if (command.action == .cancel or command.action == .close) {
        try cancelPendingMessages(alloc, next.?.queue);
    }
    if (command.action == .close) {
        next.?.archived_from = switch (previous) {
            .queued, .running, .awaiting_approval => if (next.?.mode == .persistent)
                .idle
            else
                .cancelled,
            else => previous,
        };
    }
    if (command.action == .reopen) next.?.archived_from = null;
    next.?.state = next_state;
    return finishOwnedMutation(
        alloc,
        &next,
        operation_id,
        fingerprints,
        .lifecycle_changed,
        .{ .lifecycle_changed = .{ .previous = previous, .current = next_state } },
        context.timestamp_ms,
    );
}

fn finishMutation(
    alloc: Allocator,
    next_value: control_store.Record,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
    code: domain.OutcomeCode,
    event_kind: domain.EventKind,
    timestamp_ms: i64,
) ExecuteError!Decision {
    var next = next_value;
    errdefer next.deinit(alloc);
    var pending_kind: ?domain.EventKind = event_kind;
    errdefer if (pending_kind) |*kind| kind.deinit(alloc);
    const sequence = next.next_event_sequence;
    const revision = std.math.add(u64, next.generation, 1) catch {
        return .{ .reject = .generation_exhausted };
    };
    var event: ?domain.Event = .{
        .sequence = sequence,
        .revision = revision,
        .id = try alloc.dupe(u8, operation_id),
        .timestamp_ms = timestamp_ms,
        .kind = pending_kind.?,
    };
    pending_kind = null;
    errdefer if (event) |*value| value.deinit(alloc);
    try appendEvent(alloc, &next, &event.?);
    event = null;
    next.next_event_sequence += 1;
    if (code == .created or code == .message_queued) {
        if (findQueuedMessage(next.queue, operation_id)) |message| {
            work_events.appendAtRevision(
                alloc,
                &next,
                revision,
                .{
                    .work_item_id = message.id,
                    .previous = null,
                    .current = .pending,
                },
                timestamp_ms,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.GenerationExhausted => .{ .reject = .generation_exhausted },
            };
        }
    }
    for (next.queue) |message| {
        const previous = lastWorkStatus(next.events, message.id);
        if (previous == message.status) continue;
        work_events.appendAtRevision(
            alloc,
            &next,
            revision,
            .{
                .work_item_id = message.id,
                .previous = previous,
                .current = message.status,
                .reason = message.cancellation_reason,
            },
            timestamp_ms,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.GenerationExhausted => .{ .reject = .generation_exhausted },
        };
    }
    next.generation = revision;
    next.updated_at_ms = timestamp_ms;

    var receipt = try makeReceipt(
        alloc,
        operation_id,
        fingerprints,
        code,
        next.child_id,
        next.generation,
        sequence,
    );
    errdefer receipt.deinit(alloc);
    var stored_receipt: ?domain.OperationReceipt = try receipt.clone(alloc);
    errdefer if (stored_receipt) |*value| value.deinit(alloc);
    try appendOperation(alloc, &next, &stored_receipt.?);
    stored_receipt = null;
    noteAcceptedIdentity(&next, receipt);
    return .{ .commit = .{ .record = next, .receipt = receipt } };
}

fn noteAcceptedIdentity(
    record: *control_store.Record,
    receipt: domain.OperationReceipt,
) void {
    const source = receipt.identity_source orelse return;
    const epoch = receipt.identity_epoch.?;
    record.legacy_replay_closed = true;
    const identity = tool_result.parseBoundOperationId(receipt.id) orelse return;
    if (identity.authority != .manager) return;
    switch (source) {
        .model => record.model_epoch_high = @max(record.model_epoch_high, epoch),
        .human => record.human_epoch_high = @max(record.human_epoch_high, epoch),
    }
}

pub const WorkTransitionInput = work_events.TransitionInput;
pub const appendWorkRevision = work_events.appendRevision;

fn findQueuedMessage(
    queue: []const domain.QueuedMessage,
    id: []const u8,
) ?domain.QueuedMessage {
    for (queue) |message| if (std.mem.eql(u8, message.id, id)) return message;
    return null;
}

fn findDeliveryBySequence(
    deliveries: []const communication.Delivery,
    sequence: u64,
) ?communication.Delivery {
    for (deliveries) |delivery| {
        if (delivery.sequence == sequence) return delivery;
    }
    return null;
}

fn lastWorkStatus(
    events: []const domain.Event,
    work_item_id: []const u8,
) ?domain.QueueStatus {
    var index = events.len;
    while (index > 0) {
        index -= 1;
        switch (events[index].kind) {
            .work_transition => |transition| if (std.mem.eql(
                u8,
                transition.work_item_id,
                work_item_id,
            )) return transition.current,
            else => {},
        }
    }
    return null;
}

fn makeReceipt(
    alloc: Allocator,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
    code: domain.OutcomeCode,
    target_id: []const u8,
    generation: u64,
    event_sequence: u64,
) !domain.OperationReceipt {
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const identity = tool_result.parseBoundOperationId(operation_id);
    return .{
        .id = id,
        .request_fingerprint = fingerprints.request,
        .fingerprint = fingerprints.effect,
        .code = code,
        .target_id = try alloc.dupe(u8, target_id),
        .generation = generation,
        .event_sequence = event_sequence,
        .identity_source = if (identity) |value| value.source else null,
        .identity_epoch = if (identity) |value| value.epoch else null,
    };
}

fn finishOwnedMutation(
    alloc: Allocator,
    next: *?control_store.Record,
    operation_id: []const u8,
    fingerprints: OperationFingerprints,
    code: domain.OutcomeCode,
    event_kind: domain.EventKind,
    timestamp_ms: i64,
) ExecuteError!Decision {
    const owned = next.*.?;
    next.* = null;
    return finishMutation(
        alloc,
        owned,
        operation_id,
        fingerprints,
        code,
        event_kind,
        timestamp_ms,
    );
}

fn detachedRecord(
    alloc: Allocator,
    child_id_source: []const u8,
    configuration_source: domain.Configuration,
    timestamp_ms: i64,
) !control_store.Record {
    const child_id = try alloc.dupe(u8, child_id_source);
    errdefer alloc.free(child_id);
    var configuration = try configuration_source.clone(alloc);
    errdefer configuration.deinit(alloc);
    const queue = try alloc.alloc(domain.QueuedMessage, 0);
    errdefer alloc.free(queue);
    const events = try alloc.alloc(domain.Event, 0);
    errdefer alloc.free(events);
    const operations = try alloc.alloc(domain.OperationReceipt, 0);
    return .{
        .child_id = child_id,
        .generation = 0,
        .parent_id = null,
        .mode = .persistent,
        .configuration = configuration,
        .state = .idle,
        .queue = queue,
        .events = events,
        .operations = operations,
        .next_event_sequence = 1,
        .notification_cursor = 0,
        .created_at_ms = timestamp_ms,
        .updated_at_ms = timestamp_ms,
    };
}

fn makeQueuedMessage(
    alloc: Allocator,
    operation_id: []const u8,
    source_id: []const u8,
    content: []const u8,
    root_user_intent_context: []const u8,
    root_user_messages: []const []const u8,
    root_user_evidence_complete: bool,
    timestamp_ms: i64,
) !domain.QueuedMessage {
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const source = try alloc.dupe(u8, source_id);
    errdefer alloc.free(source);
    const owned_content = try alloc.dupe(u8, content);
    errdefer alloc.free(owned_content);
    const owned_root_user_intent_context = try alloc.dupe(
        u8,
        root_user_intent_context,
    );
    errdefer if (owned_root_user_intent_context.len > 0) {
        alloc.free(owned_root_user_intent_context);
    };
    const evidence_complete = rootUserEvidenceFits(
        root_user_messages,
        root_user_evidence_complete,
    );
    const owned_root_user_messages = if (evidence_complete)
        try dupeRootUserMessages(alloc, root_user_messages)
    else
        try alloc.alloc([]u8, 0);
    errdefer freeRootUserMessages(alloc, owned_root_user_messages);
    return .{
        .id = id,
        .source_id = source,
        .content = owned_content,
        .root_user_intent_context = owned_root_user_intent_context,
        .root_user_messages = owned_root_user_messages,
        .root_user_evidence_complete = evidence_complete,
        .created_at_ms = timestamp_ms,
    };
}

fn rootUserEvidenceFits(
    messages: []const []const u8,
    claimed_complete: bool,
) bool {
    if (!claimed_complete or messages.len == 0) return false;
    var total_bytes: usize = 0;
    for (messages) |message| {
        if (message.len == 0) return false;
        total_bytes = std.math.add(usize, total_bytes, message.len) catch return false;
        if (total_bytes > domain.max_root_user_evidence_bytes) return false;
    }
    return true;
}

fn dupeRootUserMessages(
    alloc: Allocator,
    messages: []const []const u8,
) ![][]u8 {
    const owned = try alloc.alloc([]u8, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |message| alloc.free(message);
        alloc.free(owned);
    }
    for (messages) |message| {
        owned[initialized] = try alloc.dupe(u8, message);
        initialized += 1;
    }
    return owned;
}

fn freeRootUserMessages(alloc: Allocator, messages: [][]u8) void {
    for (messages) |message| alloc.free(message);
    alloc.free(messages);
}

fn freeMessages(alloc: Allocator, messages: []domain.QueuedMessage) void {
    for (messages) |*message| message.deinit(alloc);
    alloc.free(messages);
}

fn freeEventSlice(alloc: Allocator, events: []domain.Event) void {
    for (events) |*event| event.deinit(alloc);
    alloc.free(events);
}

fn historyTurnView(turn: types.HistoryTurn) HistoryTurnView {
    return switch (turn) {
        .assistant => |value| .{
            .kind = .conversation,
            .work_id = value.user.work_id,
            .user = value.user.text,
            .assistant = value.assistant,
        },
        .background_command => |value| .{
            .kind = .background_command,
            .work_id = value.user.work_id,
            .user = value.user.text,
            .assistant = value.assistant,
        },
        .interrupted => |value| .{
            .kind = .interrupted,
            .work_id = value.user.work_id,
            .user = value.user.text,
            .assistant = value.assistant,
        },
        .compacted_summary => |value| .{
            .kind = .compacted_summary,
            .assistant = value.summary,
        },
    };
}

fn loadInspectedToolActivity(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    child_id: []const u8,
    limit: usize,
) Allocator.Error!ToolActivityProjection {
    const store = communication_store.Store{
        .capability = capability,
        .expected_session_id = child_id,
    };
    var ledger = (store.loadOptional(alloc) catch |err| {
        const activity = try alloc.alloc(InspectedToolActivity, 0);
        return .{
            .activity = activity,
            .source_error = switch (err) {
                error.CommunicationNotFound => .not_found,
                error.InvalidCommunicationRecord,
                error.UnsupportedCommunicationSchema,
                error.CommunicationRecordTooLarge,
                => .invalid,
                error.CommunicationPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                error.CommunicationStoreFailed,
                => .unavailable,
                error.OutOfMemory => return error.OutOfMemory,
            },
        };
    }) orelse return .{ .activity = try alloc.alloc(InspectedToolActivity, 0) };
    defer ledger.deinit(alloc);

    var total: usize = 0;
    for (ledger.deliveries) |delivery| {
        if (delivery.payload != .tool_activity or
            !std.mem.eql(u8, delivery.source_id, child_id))
        {
            continue;
        }
        total += 1;
    }
    const first = total -| limit;
    var seen: usize = 0;
    var activity: std.ArrayList(InspectedToolActivity) = .empty;
    errdefer {
        for (activity.items) |*value| value.deinit(alloc);
        activity.deinit(alloc);
    }
    for (ledger.deliveries) |delivery| {
        if (delivery.payload != .tool_activity or
            !std.mem.eql(u8, delivery.source_id, child_id))
        {
            continue;
        }
        defer seen += 1;
        if (seen < first) continue;
        const tool = delivery.payload.tool_activity;
        const work_id = if (delivery.work_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (work_id) |value| alloc.free(value);
        const tool_name = try alloc.dupe(u8, tool.tool_name);
        errdefer alloc.free(tool_name);
        try activity.append(alloc, .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .timestamp_ms = delivery.timestamp_ms,
            .work_id = work_id,
            .tool_name = tool_name,
            .phase = tool.phase,
        });
    }
    return .{
        .activity = try activity.toOwnedSlice(alloc),
        .truncated = total > limit,
    };
}

fn cloneLatestFailure(
    alloc: Allocator,
    events: []const domain.Event,
) Allocator.Error!FailureProjection {
    const failure_detail = latestWorkFailure(events) orelse return .{};
    const work_id = try alloc.dupe(u8, failure_detail.work_item_id);
    errdefer alloc.free(work_id);
    return .{
        .work_id = work_id,
        .reason = try alloc.dupe(u8, failure_detail.reason),
    };
}

fn appendMessage(
    alloc: Allocator,
    record: *control_store.Record,
    message: *domain.QueuedMessage,
) !void {
    const replacement = try alloc.alloc(domain.QueuedMessage, record.queue.len + 1);
    @memcpy(replacement[0..record.queue.len], record.queue);
    replacement[record.queue.len] = message.*;
    alloc.free(record.queue);
    record.queue = replacement;
    message.* = undefined;
}

fn appendEvent(
    alloc: Allocator,
    record: *control_store.Record,
    event: *domain.Event,
) !void {
    const replacement = try alloc.alloc(domain.Event, record.events.len + 1);
    @memcpy(replacement[0..record.events.len], record.events);
    replacement[record.events.len] = event.*;
    alloc.free(record.events);
    record.events = replacement;
    event.* = undefined;
}

fn appendOperation(
    alloc: Allocator,
    record: *control_store.Record,
    operation: *domain.OperationReceipt,
) !void {
    const replacement = try alloc.alloc(domain.OperationReceipt, record.operations.len + 1);
    @memcpy(replacement[0..record.operations.len], record.operations);
    replacement[record.operations.len] = operation.*;
    alloc.free(record.operations);
    record.operations = replacement;
    operation.* = undefined;
}

fn cancelPendingMessages(alloc: Allocator, messages: []domain.QueuedMessage) !void {
    for (messages) |*message| {
        if (message.status != .pending and message.status != .running and
            message.status != .awaiting_approval and message.status != .interrupted)
        {
            continue;
        }
        const reason = try alloc.dupe(u8, "cancelled by lifecycle command");
        if (message.cancellation_reason) |old| alloc.free(old);
        message.cancellation_reason = reason;
        message.status = .cancelled;
    }
}

fn hasPendingMessages(messages: []const domain.QueuedMessage) bool {
    for (messages) |message| if (message.status == .pending) return true;
    return false;
}

fn hasResumableMessages(messages: []const domain.QueuedMessage) bool {
    for (messages) |message| {
        if (message.status == .pending or message.status == .interrupted) return true;
    }
    return false;
}

const LockedControl = struct {
    id: []u8,
    capability: session_child_store.SessionChildCapability,
    lock: io_mod.TimedAdvisoryLock,

    fn deinit(self: *LockedControl, alloc: Allocator) void {
        self.lock.release();
        self.capability.deinit();
        alloc.free(self.id);
        self.* = undefined;
    }
};

const LockedSet = struct {
    items: std.ArrayList(LockedControl) = .empty,

    fn acquire(
        alloc: Allocator,
        sessions: *session_store.Store,
        ids: []const []u8,
        options: session_child_store.Options,
    ) LockedAcquireError!LockedSet {
        var result = LockedSet{};
        errdefer result.deinit(alloc);
        for (ids) |id| {
            var capability = sessions.openSubagentControlCapabilityWritable(
                alloc,
                id,
                options,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SessionNotFound, error.InvalidSessionId => error.SessionNotFound,
                error.SessionPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => error.ControlPathUnsafe,
                error.SessionStoreUnavailable,
                error.SessionChildStoreFailed,
                => error.StoreFailure,
            };
            errdefer capability.deinit();
            var store = control_store.Store{
                .capability = &capability,
                .expected_child_id = id,
            };
            var lock = store.acquireLock() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ControlLockBusy => error.ControlLockBusy,
                error.ControlLockUnsupported => error.ControlLockUnsupported,
                error.ControlPathUnsafe,
                error.PrivateStatePermissionsUnsupported,
                => error.ControlPathUnsafe,
                error.ControlStoreFailed => error.StoreFailure,
            };
            errdefer lock.release();
            const owned_id = try alloc.dupe(u8, id);
            errdefer alloc.free(owned_id);
            try result.items.append(alloc, .{
                .id = owned_id,
                .capability = capability,
                .lock = lock,
            });
            capability = undefined;
            lock = undefined;
        }
        return result;
    }

    fn deinit(self: *LockedSet, alloc: Allocator) void {
        var index = self.items.items.len;
        while (index > 0) {
            index -= 1;
            self.items.items[index].deinit(alloc);
        }
        self.items.deinit(alloc);
        self.* = undefined;
    }

    fn find(self: *LockedSet, id: []const u8) ?*LockedControl {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }
};

const LockedAcquireError = error{
    OutOfMemory,
    SessionNotFound,
    ControlLockBusy,
    ControlLockUnsupported,
    ControlPathUnsafe,
    StoreFailure,
};

const ParentEdge = struct {
    child_id: []const u8,
    parent_id: ?[]u8,
};

const LockedGraph = struct {
    edges: std.ArrayList(ParentEdge) = .empty,

    fn deinit(self: *LockedGraph, alloc: Allocator) void {
        for (self.edges.items) |edge| if (edge.parent_id) |id| alloc.free(id);
        self.edges.deinit(alloc);
        self.* = undefined;
    }
};

fn loadLockedGraph(
    alloc: Allocator,
    locked: *LockedSet,
) control_store.LoadError!LockedGraph {
    var graph = LockedGraph{};
    errdefer graph.deinit(alloc);
    for (locked.items.items) |*entry| {
        var store = control_store.Store{
            .capability = &entry.capability,
            .expected_child_id = entry.id,
        };
        var record = try store.loadOptional(alloc);
        defer if (record) |*value| value.deinit(alloc);
        const parent_id = if (record) |value|
            if (value.parent_id) |id| try alloc.dupe(u8, id) else null
        else
            null;
        errdefer if (parent_id) |id| alloc.free(id);
        try graph.edges.append(alloc, .{
            .child_id = entry.id,
            .parent_id = parent_id,
        });
    }
    return graph;
}

fn validateAncestry(
    edges: []const ParentEdge,
    child_id: []const u8,
    parent_id: []const u8,
) ?FailureCode {
    var cursor: ?[]const u8 = parent_id;
    var depth: usize = 0;
    while (cursor) |id| {
        if (depth == max_ancestry_depth) return .graph_too_deep;
        if (depth > edges.len) return .relationship_cycle;
        depth += 1;
        if (std.mem.eql(u8, id, child_id)) return .relationship_cycle;
        const edge = findParentEdge(edges, id) orelse return .graph_changed;
        cursor = edge.parent_id;
    }
    return null;
}

fn relationshipRootId(
    edges: []const ParentEdge,
    parent_id: []const u8,
) ?[]const u8 {
    var current = parent_id;
    var depth: usize = 0;
    while (depth <= edges.len and depth < max_ancestry_depth) : (depth += 1) {
        const edge = findParentEdge(edges, current) orelse return null;
        const next = edge.parent_id orelse return current;
        current = next;
    }
    return null;
}

const TargetAuthorizationDecision = enum {
    authorized,
    unauthorized,
    graph_changed,
};

fn targetAuthorizationDecision(
    edges: []const ParentEdge,
    target_id: []const u8,
    actor_id: []const u8,
    root_id: []const u8,
) TargetAuthorizationDecision {
    var cursor: ?[]const u8 = target_id;
    var actor_seen = false;
    var depth: usize = 0;
    while (cursor) |id| {
        if (depth > edges.len or depth == max_ancestry_depth) {
            return .graph_changed;
        }
        depth += 1;
        actor_seen = actor_seen or std.mem.eql(u8, id, actor_id);
        if (std.mem.eql(u8, id, root_id)) {
            return if (actor_seen) .authorized else .unauthorized;
        }
        const edge = findParentEdge(edges, id) orelse return .graph_changed;
        cursor = edge.parent_id;
    }
    return .unauthorized;
}

test "target authorization distinguishes incomplete graphs from detached targets" {
    const incomplete = [_]ParentEdge{
        .{ .child_id = "target", .parent_id = @constCast("new-parent") },
    };
    try std.testing.expectEqual(
        TargetAuthorizationDecision.graph_changed,
        targetAuthorizationDecision(&incomplete, "target", "actor", "root"),
    );

    const attached = [_]ParentEdge{
        .{ .child_id = "target", .parent_id = @constCast("new-parent") },
        .{ .child_id = "new-parent", .parent_id = @constCast("actor") },
        .{ .child_id = "actor", .parent_id = @constCast("root") },
        .{ .child_id = "root", .parent_id = null },
    };
    try std.testing.expectEqual(
        TargetAuthorizationDecision.authorized,
        targetAuthorizationDecision(&attached, "target", "actor", "root"),
    );

    const detached = [_]ParentEdge{
        .{ .child_id = "target", .parent_id = null },
    };
    try std.testing.expectEqual(
        TargetAuthorizationDecision.unauthorized,
        targetAuthorizationDecision(&detached, "target", "actor", "root"),
    );
}

fn relationshipApprovalMatches(
    approval: communication.Approval,
    command: domain.RelationshipCommand,
    operation_id: []const u8,
    parent_id: []const u8,
    root_id: []const u8,
) bool {
    if (approval.kind != .relationship or
        !std.mem.eql(u8, approval.child_id, command.id) or
        !std.mem.eql(u8, approval.root_id, root_id)) return false;
    const relationship = approval.relationship orelse return false;
    if (relationship.action != command.action or
        !std.mem.eql(u8, relationship.prospective_parent_id, parent_id) or
        !std.mem.eql(u8, relationship.operation_id, operation_id)) return false;
    const prepared = communication.relationshipPreparedFingerprint(
        command.action,
        command.id,
        parent_id,
        operation_id,
    );
    return std.mem.eql(
        u8,
        &approval.prepared_fingerprint,
        &prepared,
    );
}

fn traceRelationshipApprovalLag(
    approval_id: []const u8,
    operation_id: []const u8,
    err: anyerror,
) void {
    debug_trace.logf(
        "subagent",
        "relationship approval projection lag approval_id={s} operation_id={s} outcome={s}",
        .{ approval_id, operation_id, @errorName(err) },
    );
}

fn findParentEdge(edges: []const ParentEdge, id: []const u8) ?ParentEdge {
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.child_id, id)) return edge;
    }
    return null;
}

fn appendUniqueId(
    alloc: Allocator,
    ids: *std.ArrayList([]u8),
    id: []const u8,
) !void {
    if (containsId(ids.items, id)) return;
    const owned = try alloc.dupe(u8, id);
    errdefer alloc.free(owned);
    try ids.append(alloc, owned);
}

fn containsId(ids: []const []u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn freeIds(alloc: Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| alloc.free(id);
    ids.deinit(alloc);
}

fn sortIds(ids: [][]u8) void {
    var index: usize = 1;
    while (index < ids.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, ids[cursor - 1], ids[cursor]) == .gt) : (cursor -= 1) {
            std.mem.swap([]u8, &ids[cursor - 1], &ids[cursor]);
        }
    }
}

fn hasSection(sections: []const domain.InspectSection, expected: domain.InspectSection) bool {
    for (sections) |section| if (section == expected) return true;
    return false;
}

fn failure(code: FailureCode) Result {
    return .{ .failure = .{
        .code = code,
        .retryable = code == .control_lock_busy or code == .graph_changed or
            code == .control_commit_indeterminate or code == .stale_generation,
    } };
}

fn snapshotFailure(code: FailureCode) SnapshotResult {
    return .{ .failure = .{
        .code = code,
        .retryable = code == .graph_changed,
    } };
}

fn restartSnapshot(
    alloc: Allocator,
    root_id: []const u8,
    revision: u64,
) Allocator.Error!SnapshotResult {
    const owned_root = try alloc.dupe(u8, root_id);
    errdefer alloc.free(owned_root);
    const nodes = try alloc.alloc(TreeNode, 0);
    errdefer alloc.free(nodes);
    const diagnostics = try alloc.alloc(TreeDiagnostic, 0);
    return .{ .snapshot = .{
        .root_id = owned_root,
        .revision = revision,
        .restart_required = true,
        .nodes = nodes,
        .diagnostics = diagnostics,
    } };
}

fn deinitPartialTreePage(
    alloc: Allocator,
    nodes: *std.ArrayList(TreeNode),
    diagnostics: *std.ArrayList(TreeDiagnostic),
    page_cursor: ?[]u8,
) void {
    for (nodes.items) |*node| node.deinit(alloc);
    nodes.deinit(alloc);
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
    diagnostics.deinit(alloc);
    if (page_cursor) |cursor| alloc.free(cursor);
}

fn parseTreeCursor(
    alloc: Allocator,
    raw: []const u8,
) TraversalError!ParsedTreeCursor {
    if (raw.len > max_tree_cursor_bytes or
        !std.mem.startsWith(u8, raw, "v2:"))
    {
        return error.InvalidCursor;
    }
    var frames: std.ArrayList(TreeCursorFrame) = .empty;
    errdefer frames.deinit(alloc);
    var parts = std.mem.splitScalar(u8, raw[3..], ',');
    while (parts.next()) |part| {
        if (part.len != 33 or part[16] != ':') return error.InvalidCursor;
        if (frames.items.len == max_ancestry_depth + 1) {
            return error.InvalidCursor;
        }
        try frames.append(alloc, .{
            .generation = std.fmt.parseUnsigned(u64, part[0..16], 16) catch
                return error.InvalidCursor,
            .next_offset = std.fmt.parseUnsigned(u64, part[17..33], 16) catch
                return error.InvalidCursor,
        });
    }
    if (frames.items.len == 0) return error.InvalidCursor;
    return .{ .frames = try frames.toOwnedSlice(alloc) };
}

fn encodeTreeCursor(
    alloc: Allocator,
    frames: []const TraversalFrame,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("v2:") catch return error.OutOfMemory;
    for (frames, 0..) |frame, index| {
        if (index != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.print(
            "{x:0>16}:{x:0>16}",
            .{ frame.generation, frame.next_offset },
        ) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn mapIndexTraversalError(err: relationship_index.Error) TraversalError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCursor => error.InvalidCursor,
        error.StaleCursor => error.StaleCursor,
        error.CommitIndeterminate => error.StaleCursor,
        error.InvalidIndex,
        error.LockBusy,
        error.LockUnsupported,
        error.PathUnsafe,
        error.SessionNotFound,
        error.StoreUnavailable,
        error.RecoveryRequired,
        error.GenerationExhausted,
        error.SlotExhausted,
        => error.StoreFailure,
    };
}

fn treePathContains(frames: []const TraversalFrame, child_id: []const u8) bool {
    for (frames) |frame| {
        if (std.mem.eql(u8, frame.parent_id, child_id)) return true;
    }
    return false;
}

fn appendTraversalFrame(
    alloc: Allocator,
    frames: *std.ArrayList(TraversalFrame),
    parent_id: []const u8,
    generation: u64,
    next_offset: u64,
    high_watermark: u64,
) Allocator.Error!void {
    const owned_parent = try alloc.dupe(u8, parent_id);
    errdefer alloc.free(owned_parent);
    try frames.append(alloc, .{
        .parent_id = owned_parent,
        .generation = generation,
        .next_offset = next_offset,
        .high_watermark = high_watermark,
    });
}

fn appendTreeDiagnostic(
    alloc: Allocator,
    diagnostics: *std.ArrayList(TreeDiagnostic),
    truncated: *bool,
    session_id: []const u8,
    parent_id: ?[]const u8,
    code: TreeDiagnosticCode,
) Allocator.Error!void {
    if (diagnostics.items.len == max_snapshot_diagnostics) {
        truncated.* = true;
        return;
    }
    const owned_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_id);
    const owned_parent = if (parent_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_parent) |value| alloc.free(value);
    try diagnostics.append(alloc, .{
        .session_id = owned_id,
        .parent_id = owned_parent,
        .code = code,
    });
}

fn treeNodeFromRecord(
    alloc: Allocator,
    record: control_store.Record,
    depth: usize,
) Allocator.Error!TreeNode {
    const child_id = try alloc.dupe(u8, record.child_id);
    errdefer alloc.free(child_id);
    const parent_id = try alloc.dupe(u8, record.parent_id.?);
    errdefer alloc.free(parent_id);
    return .{
        .child_id = child_id,
        .parent_id = parent_id,
        .name = try alloc.dupe(u8, record.configuration.name),
        .mode = record.mode,
        .state = record.state,
        .generation = record.generation,
        .depth = depth,
    };
}

fn mapOpenControlError(err: session_store.OpenSubagentControlError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId, error.SessionNotFound => failure(.session_not_found),
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => failure(.control_path_unsafe),
        error.SessionStoreUnavailable,
        error.SessionChildStoreFailed,
        => failure(.store_failure),
    };
}

fn mapControlLoadError(err: control_store.LoadError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlNotFound => failure(.control_not_found),
        error.InvalidControlRecord,
        error.UnsupportedControlSchema,
        => failure(.control_record_invalid),
        error.ControlRecordTooLarge => failure(.control_record_too_large),
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => failure(.control_path_unsafe),
        error.ControlStoreFailed => failure(.store_failure),
    };
}

fn mapControlSaveError(err: control_store.SaveError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlIdentityMismatch => failure(.control_record_invalid),
        error.ControlRecordTooLarge => failure(.control_record_too_large),
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => failure(.control_path_unsafe),
        error.ControlCommitIndeterminate => failure(.control_commit_indeterminate),
        error.ControlStoreFailed => failure(.store_failure),
    };
}

fn preflightMessageCommit(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    target_id: []const u8,
    command: domain.Command,
    decision: Decision,
) ExecuteError!?Result {
    if (decision != .commit) return null;
    switch (command) {
        .message => |message| if (message != .send) return null,
        else => return null,
    }
    const store = communication_store.Store{
        .capability = capability,
        .expected_session_id = target_id,
    };
    var ledger = store.loadOptional(alloc) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCommunicationRecord,
        error.UnsupportedCommunicationSchema,
        => failure(.control_record_invalid),
        error.CommunicationRecordTooLarge => failure(.control_record_too_large),
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => failure(.control_path_unsafe),
        error.CommunicationNotFound,
        error.CommunicationStoreFailed,
        => failure(.store_failure),
    };
    defer if (ledger) |*value| value.deinit(alloc);
    return null;
}

fn mapControlLockError(err: control_store.LockError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlLockBusy => failure(.control_lock_busy),
        error.ControlLockUnsupported => failure(.control_lock_unsupported),
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => failure(.control_path_unsafe),
        error.ControlStoreFailed => failure(.store_failure),
    };
}

fn mapBootstrapError(err: BootstrapError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionNotFound => failure(.session_not_found),
        error.SessionPathUnsafe => failure(.control_path_unsafe),
        error.StoreFailure => failure(.store_failure),
    };
}

fn mapRelationshipDiscoveryError(err: RelationshipDiscoveryError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RelationshipCycle => failure(.relationship_cycle),
        error.GraphTooDeep => failure(.graph_too_deep),
        error.SessionNotFound => failure(.session_not_found),
        error.ControlRecordInvalid => failure(.control_record_invalid),
        error.ControlRecordTooLarge => failure(.control_record_too_large),
        error.ControlPathUnsafe => failure(.control_path_unsafe),
        error.StoreFailure => failure(.store_failure),
    };
}

fn mapRelationshipIndexError(err: relationship_index.Error) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LockBusy => failure(.control_lock_busy),
        error.LockUnsupported => failure(.control_lock_unsupported),
        error.PathUnsafe => failure(.control_path_unsafe),
        error.CommitIndeterminate => failure(.control_commit_indeterminate),
        error.SessionNotFound => failure(.session_not_found),
        error.GenerationExhausted => failure(.generation_exhausted),
        error.StaleCursor => failure(.graph_changed),
        error.InvalidCursor,
        error.InvalidIndex,
        error.SlotExhausted,
        error.StoreUnavailable,
        error.RecoveryRequired,
        => failure(.store_failure),
    };
}

fn mapLockedAcquireError(err: LockedAcquireError) ExecuteError!Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionNotFound => failure(.session_not_found),
        error.ControlLockBusy => failure(.control_lock_busy),
        error.ControlLockUnsupported => failure(.control_lock_unsupported),
        error.ControlPathUnsafe => failure(.control_path_unsafe),
        error.StoreFailure => failure(.store_failure),
    };
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

    fn loadControl(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
    ) !control_store.Record {
        var capability = try self.store.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        return store.load(alloc);
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

    fn createLargeSession(
        self: *TestEnvironment,
        alloc: Allocator,
        id: []const u8,
        assistant_bytes: usize,
    ) !void {
        var state = try testState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        defer loaded.deinit(alloc);
        const user_text = try alloc.dupe(u8, "large transcript prompt");
        const assistant = alloc.alloc(u8, assistant_bytes) catch |err| {
            alloc.free(user_text);
            return err;
        };
        @memset(assistant, 'x');
        const turn: session.HistoryTurn = .{ .assistant = .{
            .user = .{ .text = user_text },
            .assistant = assistant,
        } };
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = state.conversation_language,
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = turn,
            } },
            2,
            .retry_expected_tail,
            .{},
        );
    }
};

noinline fn validateCreate(alloc: Allocator, name: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
    } });
}

noinline fn validateSend(alloc: Allocator, id: []const u8, content: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = id,
        .content = content,
    } } });
}

fn markFailedForInspectionTest(
    alloc: Allocator,
    record: *control_store.Record,
    reason: []const u8,
) !void {
    const work_id = record.queue[0].id;
    record.queue[0].status = .running;
    record.state = .running;
    try appendWorkRevision(alloc, record, &.{.{
        .work_item_id = work_id,
        .previous = .pending,
        .current = .running,
    }}, 2);
    record.queue[0].status = .failed;
    record.state = .failed;
    try appendWorkRevision(alloc, record, &.{.{
        .work_item_id = work_id,
        .previous = .running,
        .current = .failed,
        .reason = reason,
    }}, 3);
}

fn executeRelationshipForTest(
    alloc: Allocator,
    manager: *Manager,
    actor_id: []const u8,
    operation_id: []const u8,
    action: domain.RelationshipAction,
    child_id: []const u8,
    parent_id: ?[]const u8,
) !void {
    var command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = action,
        .id = child_id,
        .parent_id = parent_id,
    } });
    defer command.deinit(alloc);
    var result = try manager.execute(alloc, command, .{
        .actor_id = actor_id,
        .operation_id = operation_id,
        .relationship_authorization = if (action == .detach) .none else .direct,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, result.receipt.code);
}

fn writeCanonicalParentForTest(
    alloc: Allocator,
    env: *TestEnvironment,
    configuration: domain.Configuration,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    var record = try detachedRecord(alloc, child_id, configuration, 1);
    defer record.deinit(alloc);
    record.parent_id = try alloc.dupe(u8, parent_id);
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    var store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try store.acquireLock();
    defer lock.release();
    try store.save(alloc, record);
    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        parent_id,
        child_id,
        .{},
    );
}

fn clearCanonicalParentForTest(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
) !void {
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    var store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try store.acquireLock();
    defer lock.release();
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    if (record.parent_id) |parent_id| alloc.free(parent_id);
    record.parent_id = null;
    try store.save(alloc, record);
}

test "manager create reload send and inspect are durable" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "research",
        .mode = .persistent,
        .prompt = "inspect storage",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 10,
    });
    defer created.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.created, created.receipt.code);

    var send = try validateSend(alloc, "child-id", "continue");
    defer send.deinit(alloc);
    var queued = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "op-send",
        .timestamp_ms = 11,
    });
    defer queued.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, queued.receipt.code);

    {
        var loaded = try env.store.resumeForWrite(alloc, "child-id");
        defer loaded.deinit(alloc);
        const user_text = try alloc.dupe(u8, "inspect storage");
        const work_id = try alloc.dupe(u8, "op-create");
        const assistant = try alloc.dupe(u8, "The durable child response.");
        const turn: session.HistoryTurn = .{ .assistant = .{
            .user = .{ .text = user_text, .work_id = work_id },
            .assistant = assistant,
        } };
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = loaded.state.conversation_language,
                .total_input_tokens = 2,
                .total_output_tokens = 3,
                .work_id = work_id,
                .turn = turn,
            } },
            12,
            .retry_expected_tail,
            .{},
        );
        _ = loaded.publishCommitLifecycle(alloc);
    }
    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "child-id",
            .{},
        );
        defer capability.deinit();
        const activity_store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "child-id",
        };
        var ledger = try communication.Ledger.init(alloc, "child-id");
        defer ledger.deinit(alloc);
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = "tool-started",
            .source_id = "child-id",
            .target_id = "parent-id",
            .work_id = "op-create",
            .timestamp_ms = 12,
            .payload = .{ .tool_activity = .{
                .tool_name = "read_file",
                .phase = .started,
            } },
        });
        try activity_store.save(alloc, ledger);
    }

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{ .status, .messages, .tool_activity, .events, .configuration, .relationship },
        .limit = 20,
    } });
    defer inspect.deinit(alloc);
    var inspected = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 12,
    });
    defer inspected.deinit(alloc);
    try std.testing.expectEqual(domain.State.queued, inspected.inspection.status.?);
    try std.testing.expectEqual(@as(usize, 2), inspected.inspection.messages.len);
    try std.testing.expectEqual(@as(usize, 4), inspected.inspection.events.len);
    try std.testing.expect(inspected.inspection.events[0].kind == .created);
    try std.testing.expect(inspected.inspection.events[1].kind == .work_transition);
    try std.testing.expect(inspected.inspection.events[2].kind == .message_queued);
    try std.testing.expect(inspected.inspection.events[3].kind == .work_transition);
    try std.testing.expectEqualStrings("parent-id", inspected.inspection.parent_id.?);
    try std.testing.expectEqual(@as(?usize, 1), inspected.inspection.history_len);
    try std.testing.expectEqual(@as(usize, 1), inspected.inspection.history.len);
    try std.testing.expectEqualStrings(
        "The durable child response.",
        inspected.inspection.history[0].assistant.?,
    );
    try std.testing.expectEqualStrings(
        "op-create",
        inspected.inspection.history[0].work_id.?,
    );
    try std.testing.expectEqual(@as(usize, 1), inspected.inspection.tool_activity.len);
    try std.testing.expectEqualStrings(
        "read_file",
        inspected.inspection.tool_activity[0].tool_name,
    );
    try std.testing.expectEqual(
        communication.ToolActivityPhase.started,
        inspected.inspection.tool_activity[0].phase,
    );

    var second_store = try session_store.Store.initFromHome(alloc, env.home, env.workspace);
    defer second_store.deinit(alloc);
    var reloaded_manager = Manager{ .sessions = &second_store };
    var reloaded = try reloaded_manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 13,
    });
    defer reloaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), reloaded.inspection.messages.len);
    try std.testing.expectEqualStrings(
        "The durable child response.",
        reloaded.inspection.history[0].assistant.?,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        reloaded.inspection.tool_activity[0].tool_name,
    );
}

test "message admission rejects corrupt communication before control mutation" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };

    var create = try validateCreate(alloc, "worker");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var first_send = try validateSend(alloc, "child-id", "first message");
    defer first_send.deinit(alloc);
    var first = try manager.execute(alloc, first_send, .{
        .actor_id = "parent-id",
        .operation_id = "op-first",
        .timestamp_ms = 2,
    });
    defer first.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, first.receipt.code);

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "child-id",
            .{},
        );
        defer capability.deinit();
        var replaced = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "communication.json",
            "{",
        );
        replaced.deinit(alloc);
    }

    var replay = try manager.execute(alloc, first_send, .{
        .actor_id = "parent-id",
        .operation_id = "op-first",
        .timestamp_ms = 3,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(first.receipt.code, replay.receipt.code);
    try std.testing.expectEqual(first.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqual(first.receipt.event_sequence, replay.receipt.event_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &first.receipt.fingerprint,
        &replay.receipt.fingerprint,
    );

    var before = try env.loadControl(alloc, "child-id");
    defer before.deinit(alloc);
    var corrupt_send = try validateSend(alloc, "child-id", "must not queue");
    defer corrupt_send.deinit(alloc);
    var unrestricted = try manager.execute(alloc, corrupt_send, .{
        .actor_id = "parent-id",
        .operation_id = "op-corrupt-unrestricted",
        .timestamp_ms = 4,
    });
    defer unrestricted.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_record_invalid,
        unrestricted.failure.code,
    );
    try std.testing.expect(!unrestricted.failure.retryable);

    var authorized = try manager.execute(alloc, corrupt_send, .{
        .actor_id = "parent-id",
        .operation_id = "op-corrupt-authorized",
        .target_authorization = .{ .attached_to_root = "parent-id" },
        .timestamp_ms = 5,
    });
    defer authorized.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_record_invalid,
        authorized.failure.code,
    );
    try std.testing.expect(!authorized.failure.retryable);

    var after = try env.loadControl(alloc, "child-id");
    defer after.deinit(alloc);
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqual(before.queue.len, after.queue.len);
    try std.testing.expectEqual(before.operations.len, after.operations.len);
    try std.testing.expectEqualStrings(before.queue[0].id, after.queue[0].id);
    try std.testing.expectEqualStrings(
        before.operations[before.operations.len - 1].id,
        after.operations[after.operations.len - 1].id,
    );

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "child-id",
            .{},
        );
        defer capability.deinit();
        var file = try capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "communication.json",
        );
        const preserved = try file.readToEnd(alloc, 16);
        file.deinit();
        defer alloc.free(preserved);
        try std.testing.expectEqualStrings("{", preserved);
        try capability.delete(.subagent_control, "communication.json");
    }

    var missing_send = try validateSend(alloc, "child-id", "bootstrap message");
    defer missing_send.deinit(alloc);
    var queued = try manager.execute(alloc, missing_send, .{
        .actor_id = "parent-id",
        .operation_id = "op-missing-ledger",
        .target_authorization = .{ .attached_to_root = "parent-id" },
        .timestamp_ms = 6,
    });
    defer queued.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, queued.receipt.code);
}

test "manager persists inherited root context and replay keeps first admission" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "research",
        .mode = .persistent,
        .prompt = "inspect storage",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .root_user_intent_context = "current_request: inspect storage\n",
        .root_user_messages = &.{ "Do not modify files.", "Inspect storage." },
        .root_user_evidence_complete = true,
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var replayed = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .root_user_intent_context = "current_request: replacement context\n",
        .root_user_messages = &.{"Replacement must not win."},
        .root_user_evidence_complete = true,
        .timestamp_ms = 2,
    });
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(created.receipt.generation, replayed.receipt.generation);

    var send = try validateSend(alloc, "child-id", "continue");
    defer send.deinit(alloc);
    var sent = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "op-send",
        .root_user_intent_context = "current_request: continue\n",
        .root_user_messages = &.{ "Do not modify files.", "Continue inspection." },
        .root_user_evidence_complete = true,
        .timestamp_ms = 3,
    });
    defer sent.deinit(alloc);

    var record = try env.loadControl(alloc, "child-id");
    defer record.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), record.queue.len);
    try std.testing.expectEqualStrings(
        "current_request: inspect storage\n",
        record.queue[0].root_user_intent_context,
    );
    try std.testing.expectEqualStrings(
        "current_request: continue\n",
        record.queue[1].root_user_intent_context,
    );
    try std.testing.expect(record.queue[0].root_user_evidence_complete);
    try std.testing.expectEqual(@as(usize, 2), record.queue[0].root_user_messages.len);
    try std.testing.expectEqualStrings(
        "Do not modify files.",
        record.queue[0].root_user_messages[0],
    );
    try std.testing.expectEqualStrings(
        "Inspect storage.",
        record.queue[0].root_user_messages[1],
    );
    try std.testing.expect(record.queue[1].root_user_evidence_complete);
    try std.testing.expectEqualStrings(
        "Continue inspection.",
        record.queue[1].root_user_messages[1],
    );

    var forged = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "op-forged",
        .root_user_intent_context = "assistant_task: continue\n",
        .timestamp_ms = 4,
    });
    defer forged.deinit(alloc);
    try std.testing.expectEqual(FailureCode.store_failure, forged.failure.code);
}

test "manager preserves one-off authority and fails oversized child evidence closed" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "one-off-child");
    try env.createSession(alloc, "oversized-child");
    var manager = Manager{ .sessions = &env.store };

    var one_off = try domain.validateCommand(alloc, .{ .create = .{
        .name = "one off inspection",
        .mode = .one_off,
        .prompt = "inspect README",
    } });
    defer one_off.deinit(alloc);
    var created_one_off = try manager.execute(alloc, one_off, .{
        .actor_id = "parent-id",
        .operation_id = "op-one-off-authority",
        .created_child_id = "one-off-child",
        .root_user_messages = &.{ "Do not modify files.", "Inspect README only." },
        .root_user_evidence_complete = true,
        .timestamp_ms = 1,
    });
    defer created_one_off.deinit(alloc);
    try std.testing.expect(created_one_off == .receipt);
    var one_off_record = try env.loadControl(alloc, "one-off-child");
    defer one_off_record.deinit(alloc);
    try std.testing.expect(one_off_record.queue[0].root_user_evidence_complete);
    try std.testing.expectEqualStrings(
        "Do not modify files.",
        one_off_record.queue[0].root_user_messages[0],
    );

    var oversized = try domain.validateCommand(alloc, .{ .create = .{
        .name = "oversized authority",
        .mode = .persistent,
        .prompt = "continue safely",
    } });
    defer oversized.deinit(alloc);
    const oversized_message = "x" ** (domain.max_root_user_evidence_bytes + 1);
    var created_oversized = try manager.execute(alloc, oversized, .{
        .actor_id = "parent-id",
        .operation_id = "op-oversized-authority",
        .created_child_id = "oversized-child",
        .root_user_messages = &.{oversized_message},
        .root_user_evidence_complete = true,
        .timestamp_ms = 2,
    });
    defer created_oversized.deinit(alloc);
    try std.testing.expect(created_oversized == .receipt);
    var oversized_record = try env.loadControl(alloc, "oversized-child");
    defer oversized_record.deinit(alloc);
    try std.testing.expect(!oversized_record.queue[0].root_user_evidence_complete);
    try std.testing.expectEqual(
        @as(usize, 0),
        oversized_record.queue[0].root_user_messages.len,
    );
}

test "manager inspection preserves a bounded child failure reason" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "failed-child");
    var manager = Manager{ .sessions = &env.store };

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "failing worker",
        .mode = .one_off,
        .prompt = "fail safely",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-failed-child",
        .created_child_id = "failed-child",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "failed-child",
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = "failed-child",
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        try markFailedForInspectionTest(
            alloc,
            &record,
            "provider_http_error: API request failed · HTTP 502",
        );
        try store.save(alloc, record);
    }

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "failed-child",
        .sections = &.{ .status, .messages },
        .limit = 10,
    } });
    defer inspect.deinit(alloc);
    var inspected = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 4,
    });
    defer inspected.deinit(alloc);
    try std.testing.expectEqual(domain.State.failed, inspected.inspection.status.?);
    try std.testing.expectEqualStrings(
        "op-failed-child",
        inspected.inspection.failure_work_id.?,
    );
    try std.testing.expectEqualStrings(
        "provider_http_error: API request failed · HTTP 502",
        inspected.inspection.failure_reason.?,
    );

    var restarted_store = try session_store.Store.initFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer restarted_store.deinit(alloc);
    var restarted_manager = Manager{ .sessions = &restarted_store };
    var restarted = try restarted_manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 5,
    });
    defer restarted.deinit(alloc);
    try std.testing.expectEqualStrings(
        inspected.inspection.failure_reason.?,
        restarted.inspection.failure_reason.?,
    );
}

test "authenticated milestone uses captured work contract and deduplicates by work name" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
        .prompt = "do work",
        .notifications = .{ .milestones = &.{"halfway"} },
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    var control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var lock = try control.acquireLock();
    {
        defer lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        var ledger = try communication.Ledger.init(alloc, "child-id");
        defer ledger.deinit(alloc);
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            record.queue[0].id,
            record.configuration.notifications,
            2,
        );
        const communication_state = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "child-id",
        };
        try communication_state.save(alloc, ledger);
        record.queue[0].status = .running;
        record.state = .running;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .pending,
            .current = .running,
        }}, 2);
        try control.save(alloc, record);
    }

    var milestone = try domain.validateCommand(alloc, .{ .message = .{
        .milestone = .{ .name = "halfway" },
    } });
    defer milestone.deinit(alloc);
    var first = try manager.execute(alloc, milestone, .{
        .actor_id = "child-id",
        .operation_id = "op-milestone",
        .timestamp_ms = 3,
    });
    defer first.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.milestone_emitted, first.receipt.code);
    const original_sequence = first.receipt.event_sequence;

    var replay = try manager.execute(alloc, milestone, .{
        .actor_id = "child-id",
        .operation_id = "op-milestone",
        .timestamp_ms = 4,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(original_sequence, replay.receipt.event_sequence);

    var same_name = try manager.execute(alloc, milestone, .{
        .actor_id = "child-id",
        .operation_id = "op-milestone-other",
        .timestamp_ms = 5,
    });
    defer same_name.deinit(alloc);
    try std.testing.expectEqual(original_sequence, same_name.receipt.event_sequence);

    var undeclared = try domain.validateCommand(alloc, .{ .message = .{
        .milestone = .{ .name = "done-ish" },
    } });
    defer undeclared.deinit(alloc);
    var rejected = try manager.execute(alloc, undeclared, .{
        .actor_id = "child-id",
        .operation_id = "op-undeclared",
        .timestamp_ms = 6,
    });
    defer rejected.deinit(alloc);
    try std.testing.expectEqual(FailureCode.undeclared_milestone, rejected.failure.code);

    var root_rejected = try manager.execute(alloc, milestone, .{
        .actor_id = "parent-id",
        .operation_id = "op-root-milestone",
        .timestamp_ms = 7,
    });
    defer root_rejected.deinit(alloc);
    try std.testing.expectEqual(FailureCode.invalid_milestone_caller, root_rejected.failure.code);

    try env.createSession(alloc, "idle-child-id");
    var create_idle = try domain.validateCommand(alloc, .{ .create = .{
        .name = "idle-worker",
        .mode = .persistent,
    } });
    defer create_idle.deinit(alloc);
    var idle_created = try manager.execute(alloc, create_idle, .{
        .actor_id = "parent-id",
        .operation_id = "op-create-idle",
        .created_child_id = "idle-child-id",
        .timestamp_ms = 8,
    });
    defer idle_created.deinit(alloc);
    var no_work = try manager.execute(alloc, milestone, .{
        .actor_id = "idle-child-id",
        .operation_id = "op-no-active-work",
        .timestamp_ms = 9,
    });
    defer no_work.deinit(alloc);
    try std.testing.expectEqual(FailureCode.no_active_work, no_work.failure.code);
}

test "child to parent message delivery replays without transcript mutation" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var send = try validateSend(alloc, "parent-id", "child status");
    defer send.deinit(alloc);
    var first = try manager.execute(alloc, send, .{
        .actor_id = "child-id",
        .operation_id = "op-child-message",
        .timestamp_ms = 2,
    });
    defer first.deinit(alloc);
    var replay = try manager.execute(alloc, send, .{
        .actor_id = "child-id",
        .operation_id = "op-child-message",
        .timestamp_ms = 99,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(first.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqual(first.receipt.event_sequence, replay.receipt.event_sequence);

    var changed = try validateSend(alloc, "parent-id", "changed status");
    defer changed.deinit(alloc);
    var conflict = try manager.execute(alloc, changed, .{
        .actor_id = "child-id",
        .operation_id = "op-child-message",
        .timestamp_ms = 3,
    });
    defer conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, conflict.failure.code);

    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    var running_boundary = try communication_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .running,
        null,
    );
    defer running_boundary.deinit(alloc);
    try std.testing.expect(running_boundary == .wait);
    var page = try communication_manager.page(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
    try std.testing.expectEqualStrings("parent-id", page.deliveries[0].target_id);
    try std.testing.expectEqualStrings("child status", page.deliveries[0].payload.message);
    var boundary = try communication_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer boundary.deinit(alloc);
    try std.testing.expect(boundary == .inject);
    try std.testing.expect(std.mem.indexOf(
        u8,
        boundary.inject.context,
        "child status",
    ) != null);
    try communication_manager.acknowledgeParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .{
            .sequence = boundary.inject.through_sequence,
            .delivery_id = boundary.inject.delivery_id,
            .start_offset = boundary.inject.start_offset,
            .end_offset = boundary.inject.end_offset,
            .total_bytes = boundary.inject.total_bytes,
        },
    );
    var empty_boundary = try communication_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer empty_boundary.deinit(alloc);
    try std.testing.expect(empty_boundary == .wait);
    var human_unread = try communication_manager.page(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        null,
        10,
    );
    defer human_unread.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), human_unread.deliveries.len);
}

test "parent continuation acknowledgement survives indeterminate and concurrent exact retries" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "worker");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    const content = try alloc.alloc(u8, domain.max_message_bytes);
    defer alloc.free(content);
    @memset(content, 'x');
    var send = try validateSend(alloc, "parent-id", content);
    defer send.deinit(alloc);
    var sent = try manager.execute(alloc, send, .{
        .actor_id = "child-id",
        .operation_id = "op-large-message",
        .timestamp_ms = 2,
    });
    defer sent.deinit(alloc);
    try std.testing.expect(sent == .receipt);
    var exact_retry = try manager.execute(alloc, send, .{
        .actor_id = "child-id",
        .operation_id = "op-large-message",
        .timestamp_ms = 3,
    });
    defer exact_retry.deinit(alloc);
    try std.testing.expectEqual(
        sent.receipt.generation,
        exact_retry.receipt.generation,
    );
    content[content.len - 1] = 'y';
    var changed_send = try validateSend(alloc, "parent-id", content);
    defer changed_send.deinit(alloc);
    var conflict = try manager.execute(alloc, changed_send, .{
        .actor_id = "child-id",
        .operation_id = "op-large-message",
        .timestamp_ms = 4,
    });
    defer conflict.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.operation_conflict,
        conflict.failure.code,
    );

    var delivery_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    var first = try delivery_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer first.deinit(alloc);
    try std.testing.expect(first == .inject);
    const first_ack: communication.ParentAcknowledgement = .{
        .sequence = first.inject.through_sequence,
        .delivery_id = first.inject.delivery_id,
        .start_offset = first.inject.start_offset,
        .end_offset = first.inject.end_offset,
        .total_bytes = first.inject.total_bytes,
    };
    var sync_failure = CommitSyncFailure{};
    var indeterminate = communication_manager_mod.Manager{
        .sessions = &env.store,
        .child_store_options = .{ .replace_ops = .{
            .ctx = &sync_failure,
            .sync_dir = CommitSyncFailure.syncDir,
        } },
    };
    try std.testing.expectError(
        error.CommitIndeterminate,
        indeterminate.acknowledgeParentBoundary(
            alloc,
            "child-id",
            "parent-model",
            "parent-id",
            first_ack,
        ),
    );
    try delivery_manager.acknowledgeParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        first_ack,
    );

    var second = try delivery_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer second.deinit(alloc);
    try std.testing.expect(second == .inject);
    try std.testing.expectEqual(first.inject.end_offset, second.inject.start_offset);
    const second_ack: communication.ParentAcknowledgement = .{
        .sequence = second.inject.through_sequence,
        .delivery_id = second.inject.delivery_id,
        .start_offset = second.inject.start_offset,
        .end_offset = second.inject.end_offset,
        .total_bytes = second.inject.total_bytes,
    };

    const Worker = struct {
        home: []const u8,
        workspace: []const u8,
        acknowledgement: communication.ParentAcknowledgement,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            const thread_alloc = std.heap.c_allocator;
            var store = session_store.Store.initFromHome(
                thread_alloc,
                self.home,
                self.workspace,
            ) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer store.deinit(thread_alloc);
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            var thread_manager = communication_manager_mod.Manager{
                .sessions = &store,
            };
            thread_manager.acknowledgeParentBoundary(
                thread_alloc,
                "child-id",
                "parent-model",
                "parent-id",
                self.acknowledgement,
            ) catch {
                self.failed.store(true, .seq_cst);
            };
        }
    };
    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    const workers = [_]Worker{
        .{
            .home = env.home,
            .workspace = env.workspace,
            .acknowledgement = second_ack,
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        },
        .{
            .home = env.home,
            .workspace = env.workspace,
            .acknowledgement = second_ack,
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        },
    };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, workers) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    while (ready.load(.seq_cst) != workers.len) std.atomic.spinLoopHint();
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.seq_cst));

    var third = try delivery_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer third.deinit(alloc);
    try std.testing.expect(third == .inject);
    try std.testing.expectEqual(second.inject.end_offset, third.inject.start_offset);
    try delivery_manager.acknowledgeParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        second_ack,
    );
    var repeated = try delivery_manager.prepareParentBoundary(
        alloc,
        "child-id",
        "parent-model",
        "parent-id",
        .turn_boundary,
        null,
    );
    defer repeated.deinit(alloc);
    try std.testing.expectEqual(third.inject.generation, repeated.inject.generation);
    try std.testing.expectEqualStrings(third.inject.context, repeated.inject.context);
}

test "durable delivery authorization follows detach and reparent without cross-target acknowledgement" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-a");
    try env.createSession(alloc, "parent-b");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-a",
        .operation_id = "create-child",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var to_a = try validateSend(alloc, "parent-a", "for a");
    defer to_a.deinit(alloc);
    var sent_a = try manager.execute(alloc, to_a, .{
        .actor_id = "child-id",
        .operation_id = "send-a",
        .timestamp_ms = 2,
    });
    defer sent_a.deinit(alloc);

    var communication_manager = communication_manager_mod.Manager{ .sessions = &env.store };
    var page_a = try communication_manager.page(
        alloc,
        "child-id",
        "parent-model",
        "parent-a",
        null,
        1,
    );
    defer page_a.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page_a.deliveries.len);

    try executeRelationshipForTest(
        alloc,
        &manager,
        "parent-a",
        "detach-child",
        .detach,
        "child-id",
        null,
    );
    try std.testing.expectError(
        error.InvalidRequest,
        communication_manager.page(
            alloc,
            "child-id",
            "parent-model",
            "parent-a",
            null,
            1,
        ),
    );
    try executeRelationshipForTest(
        alloc,
        &manager,
        "parent-b",
        "attach-child-b",
        .attach,
        "child-id",
        "parent-b",
    );
    var to_b = try validateSend(alloc, "parent-b", "for b");
    defer to_b.deinit(alloc);
    var sent_b = try manager.execute(alloc, to_b, .{
        .actor_id = "child-id",
        .operation_id = "send-b",
        .timestamp_ms = 3,
    });
    defer sent_b.deinit(alloc);

    var restarted = communication_manager_mod.Manager{ .sessions = &env.store };
    var page_b = try restarted.page(
        alloc,
        "child-id",
        "parent-model",
        "parent-b",
        null,
        1,
    );
    defer page_b.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page_b.deliveries.len);
    try std.testing.expectEqualStrings("for b", page_b.deliveries[0].payload.message);
    try std.testing.expectError(
        error.InvalidRequest,
        restarted.acknowledge(
            alloc,
            "child-id",
            "parent-model",
            "parent-b",
            page_a.through_sequence,
        ),
    );
    try restarted.acknowledge(
        alloc,
        "child-id",
        "parent-model",
        "parent-b",
        page_b.through_sequence,
    );
}

test "delivery page and parent boundary revalidate relationship under ordered locks" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-a");
    try env.createSession(alloc, "parent-b");
    try env.createSession(alloc, "race-child");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "race",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-a",
        .operation_id = "create-race-child",
        .created_child_id = "race-child",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var message = try validateSend(alloc, "parent-a", "before relationship change");
    defer message.deinit(alloc);
    var sent = try manager.execute(alloc, message, .{
        .actor_id = "race-child",
        .operation_id = "race-delivery",
        .timestamp_ms = 2,
    });
    defer sent.deinit(alloc);

    const Query = struct {
        sessions: *session_store.Store,
        target_id: []const u8,
        boundary: bool,
        lock_ops: io_mod.LockOps,
        finished: *std.atomic.Value(bool),
        outcome: union(enum) {
            pending,
            authorized,
            err: communication_manager_mod.Error,
        } = .pending,

        fn run(self: *@This()) void {
            defer self.finished.store(true, .seq_cst);
            var communication_manager = communication_manager_mod.Manager{
                .sessions = self.sessions,
                .child_store_options = .{ .lock_ops = self.lock_ops },
            };
            if (self.boundary) {
                var result = communication_manager.prepareParentBoundary(
                    std.testing.allocator,
                    "race-child",
                    "parent-model",
                    self.target_id,
                    .turn_boundary,
                    null,
                ) catch |err| {
                    self.outcome = .{ .err = err };
                    return;
                };
                defer result.deinit(std.testing.allocator);
                self.outcome = if (result == .inject) .authorized else .pending;
            } else {
                var result = communication_manager.page(
                    std.testing.allocator,
                    "race-child",
                    "human-surface",
                    self.target_id,
                    null,
                    10,
                ) catch |err| {
                    self.outcome = .{ .err = err };
                    return;
                };
                defer result.deinit(std.testing.allocator);
                self.outcome = if (result.deliveries.len != 0) .authorized else .pending;
            }
        }
    };

    const LockProbe = struct {
        contended: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn tryLock(raw: ?*anyopaque, file: std.Io.File) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const locked = try file.tryLock(io_mod.getIo(), .exclusive);
            if (!locked) self.contended.store(true, .seq_cst);
            return locked;
        }

        fn now(_: ?*anyopaque) i64 {
            return 0;
        }

        fn yield(_: ?*anyopaque, _: u64) void {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }

        fn ops(self: *@This()) io_mod.LockOps {
            return .{
                .ctx = self,
                .try_lock = tryLock,
                .now_ms = now,
                .sleep_ms = yield,
            };
        }
    };

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "race-child",
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "race-child",
    };
    var first_lock = try control.acquireLock();
    var page_probe = LockProbe{};
    var page_finished = std.atomic.Value(bool).init(false);
    var page_query = Query{
        .sessions = &env.store,
        .target_id = "parent-a",
        .boundary = false,
        .lock_ops = page_probe.ops(),
        .finished = &page_finished,
    };
    const page_thread = try std.Thread.spawn(.{}, Query.run, .{&page_query});
    while (!page_probe.contended.load(.seq_cst) and
        !page_finished.load(.seq_cst))
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    if (!page_probe.contended.load(.seq_cst)) {
        first_lock.release();
        page_thread.join();
        return error.TestExpectedContestedLock;
    }
    var record = try control.load(alloc);
    alloc.free(record.parent_id.?);
    record.parent_id = try alloc.dupe(u8, "parent-b");
    try control.save(alloc, record);
    record.deinit(alloc);
    first_lock.release();
    page_thread.join();
    switch (page_query.outcome) {
        .err => |err| try std.testing.expectEqual(error.InvalidRequest, err),
        .pending, .authorized => return error.TestExpectedInvalidRequest,
    }

    var second_lock = try control.acquireLock();
    var boundary_probe = LockProbe{};
    var boundary_finished = std.atomic.Value(bool).init(false);
    var boundary_query = Query{
        .sessions = &env.store,
        .target_id = "parent-b",
        .boundary = true,
        .lock_ops = boundary_probe.ops(),
        .finished = &boundary_finished,
    };
    const boundary_thread = try std.Thread.spawn(.{}, Query.run, .{&boundary_query});
    while (!boundary_probe.contended.load(.seq_cst) and
        !boundary_finished.load(.seq_cst))
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    if (!boundary_probe.contended.load(.seq_cst)) {
        second_lock.release();
        boundary_thread.join();
        return error.TestExpectedContestedLock;
    }
    var reparented = try control.load(alloc);
    alloc.free(reparented.parent_id.?);
    reparented.parent_id = null;
    try control.save(alloc, reparented);
    reparented.deinit(alloc);
    second_lock.release();
    boundary_thread.join();
    switch (boundary_query.outcome) {
        .err => |err| try std.testing.expectEqual(error.InvalidRequest, err),
        .pending, .authorized => return error.TestExpectedInvalidRequest,
    }
}

test "detach and reparent reject running or approval-blocked work" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-a");
    try env.createSession(alloc, "parent-b");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
        .prompt = "work",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-a",
        .operation_id = "create-active",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(alloc, "child-id", .{});
    defer capability.deinit();
    var store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var lock = try store.acquireLock();
    {
        defer lock.release();
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .pending,
            .current = .running,
        }}, 2);
        record.queue[0].status = .running;
        record.state = .running;
        try store.save(alloc, record);
    }
    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "child-id",
    } });
    defer detach.deinit(alloc);
    var running_rejected = try manager.execute(alloc, detach, .{
        .actor_id = "parent-a",
        .operation_id = "detach-running",
        .timestamp_ms = 3,
    });
    defer running_rejected.deinit(alloc);
    try std.testing.expectEqual(FailureCode.invalid_state, running_rejected.failure.code);

    var approval_lock = try store.acquireLock();
    {
        defer approval_lock.release();
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        try std.testing.expectEqual(
            work_events.ApprovalTransition.changed,
            try work_events.awaitApproval(alloc, &record, record.queue[0].id, 4),
        );
        try store.save(alloc, record);
    }
    var reparent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "child-id",
        .parent_id = "parent-b",
    } });
    defer reparent.deinit(alloc);
    var approval_rejected = try manager.execute(alloc, reparent, .{
        .actor_id = "parent-a",
        .operation_id = "reparent-awaiting",
        .relationship_authorization = .direct,
        .timestamp_ms = 5,
    });
    defer approval_rejected.deinit(alloc);
    try std.testing.expectEqual(FailureCode.invalid_state, approval_rejected.failure.code);
}

test "detach and reparent reject canonical one off targets" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-a");
    try env.createSession(alloc, "parent-b");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "temporary worker",
        .mode = .one_off,
        .prompt = "temporary work",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-a",
        .operation_id = "create-one-off",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    try std.testing.expect(created == .receipt);

    for ([_]struct {
        action: domain.RelationshipAction,
        operation_id: []const u8,
        parent_id: ?[]const u8,
    }{
        .{ .action = .detach, .operation_id = "detach-one-off", .parent_id = null },
        .{ .action = .reparent, .operation_id = "reparent-one-off", .parent_id = "parent-b" },
    }) |case| {
        var command = try domain.validateCommand(alloc, .{ .relationship = .{
            .action = case.action,
            .id = "child-id",
            .parent_id = case.parent_id,
        } });
        defer command.deinit(alloc);
        var rejected = try manager.execute(alloc, command, .{
            .actor_id = "parent-a",
            .operation_id = case.operation_id,
            .relationship_authorization = if (case.action == .detach) .none else .direct,
            .timestamp_ms = 2,
        });
        defer rejected.deinit(alloc);
        try std.testing.expect(rejected == .failure);
        try std.testing.expectEqual(FailureCode.invalid_state, rejected.failure.code);
    }

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqualStrings("parent-a", record.parent_id.?);
    try std.testing.expect((try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "parent-a",
        "child-id",
        .{},
    )) != null);
}

test "stored snapshot polling uses fake clock coalesces ticks and stops without model work" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
        .prompt = "work",
        .notifications = .{
            .report_interval_ms = 100,
            .report_duration_ms = 350,
            .stop_conditions = &.{ .terminal, .duration_elapsed },
        },
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 0,
    });
    defer created.deinit(alloc);
    var comm = communication_manager_mod.Manager{ .sessions = &env.store };
    try std.testing.expectEqual(@as(?i64, 100), try comm.captureWorkPolicy(
        alloc,
        "child-id",
        "op-create",
        create.create.configuration.notifications,
        0,
    ));
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    var control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var lock = try control.acquireLock();
    {
        defer lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        record.queue[0].status = .running;
        record.state = .running;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .pending,
            .current = .running,
        }}, 1);
        try control.save(alloc, record);
    }
    try std.testing.expectEqual(@as(i64, 100), (try comm.poll(
        alloc,
        "child-id",
        "op-create",
        99,
    )).pending);
    const first_poll = (try comm.poll(
        alloc,
        "child-id",
        "op-create",
        100,
    )).emitted;
    try std.testing.expectEqual(@as(u32, 1), first_poll.coalesced_ticks);
    try std.testing.expectEqual(@as(?i64, 200), first_poll.next_check_ms);
    var restarted_store = try session_store.Store.initFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer restarted_store.deinit(alloc);
    var restarted_comm = communication_manager_mod.Manager{
        .sessions = &restarted_store,
    };
    const coalesced_poll = (try restarted_comm.poll(
        alloc,
        "child-id",
        "op-create",
        320,
    )).emitted;
    try std.testing.expectEqual(@as(u32, 2), coalesced_poll.coalesced_ticks);
    try std.testing.expectEqual(@as(?i64, 350), coalesced_poll.next_check_ms);
    try std.testing.expect((try restarted_comm.poll(
        alloc,
        "child-id",
        "op-create",
        350,
    )) == .stopped);
    try std.testing.expect((try restarted_comm.poll(
        alloc,
        "child-id",
        "op-create",
        900,
    )) == .inactive);
    var communication_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "child-id",
        .{},
    );
    defer communication_capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &communication_capability,
        .expected_session_id = "child-id",
    };
    var compacted = try communication_state.load(alloc);
    defer compacted.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), compacted.work_notifications.len);
    var page = try comm.page(
        alloc,
        "child-id",
        "parent-ui",
        "parent-id",
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page.deliveries.len);
    try std.testing.expectEqual(@as(u32, 2), page.deliveries[1].payload.interval.coalesced_ticks);
    const first_id = communication.stableIntervalDeliveryId("child-id", "op-create", 100);
    const coalesced_id = communication.stableIntervalDeliveryId("child-id", "op-create", 200);
    try std.testing.expectEqualStrings(&first_id, page.deliveries[0].id);
    try std.testing.expectEqualStrings(&coalesced_id, page.deliveries[1].id);
}

fn seedCapacityPolicyLedger(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
) !void {
    var capability = try sessions.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try communication.Ledger.init(alloc, child_id);
    defer ledger.deinit(alloc);
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 1,
    });
    defer policy.deinit(alloc);
    for (0..communication.max_active_work_notifications - 1) |index| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(
            &id_buffer,
            "capacity-seed-{d}",
            .{index},
        );
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            id,
            policy,
            @intCast(index),
        );
    }
    try store.save(alloc, ledger);
}

fn admitCapacityPolicy(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    work_id: []const u8,
) !void {
    var capability = try sessions.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var lock = try store.acquireLock();
    defer lock.release();
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 1,
    });
    defer policy.deinit(alloc);
    try communication.upsertWorkNotification(
        alloc,
        &ledger,
        work_id,
        policy,
        10,
    );
    try store.save(alloc, ledger);
}

test "competing thread policy admissions cannot cross the capacity budget" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "thread-capacity-child");
    try seedCapacityPolicyLedger(alloc, &env.store, "thread-capacity-child");

    const Worker = struct {
        sessions: *session_store.Store,
        work_id: []const u8,
        admitted: *std.atomic.Value(usize),
        rejected: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            admitCapacityPolicy(
                std.testing.allocator,
                self.sessions,
                "thread-capacity-child",
                self.work_id,
            ) catch |err| {
                if (err == error.CapacityExceeded) {
                    _ = self.rejected.fetchAdd(1, .seq_cst);
                } else {
                    self.failed.store(true, .seq_cst);
                }
                return;
            };
            _ = self.admitted.fetchAdd(1, .seq_cst);
        }
    };
    var admitted = std.atomic.Value(usize).init(0);
    var rejected = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);
    var first = Worker{
        .sessions = &env.store,
        .work_id = "thread-capacity-a",
        .admitted = &admitted,
        .rejected = &rejected,
        .failed = &failed,
    };
    var second = Worker{
        .sessions = &env.store,
        .work_id = "thread-capacity-b",
        .admitted = &admitted,
        .rejected = &rejected,
        .failed = &failed,
    };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), admitted.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), rejected.load(.seq_cst));
    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "thread-capacity-child",
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "thread-capacity-child",
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.max_active_work_notifications,
        ledger.work_notifications.len,
    );
}

fn setupRunningIntervalWork(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    work_id: []const u8,
) !void {
    try env.createSession(alloc, "interval-parent");
    try env.createSession(alloc, child_id);
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "interval-worker",
        .mode = .persistent,
        .prompt = "work",
        .notifications = .{ .report_interval_ms = 100 },
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "interval-parent",
        .operation_id = work_id,
        .created_child_id = child_id,
        .timestamp_ms = 0,
    });
    defer created.deinit(alloc);
    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    try std.testing.expectEqual(@as(?i64, 100), try communication_manager.captureWorkPolicy(
        alloc,
        child_id,
        work_id,
        create.create.configuration.notifications,
        0,
    ));
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try control.acquireLock();
    defer lock.release();
    var record = try control.load(alloc);
    defer record.deinit(alloc);
    record.queue[0].status = .running;
    record.state = .running;
    try appendWorkRevision(alloc, &record, &.{.{
        .work_item_id = record.queue[0].id,
        .previous = .pending,
        .current = .running,
    }}, 1);
    try control.save(alloc, record);
}

test "competing thread interval polls append one durable delivery" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try setupRunningIntervalWork(alloc, &env, "thread-poll-child", "thread-work");

    const PollWorker = struct {
        home: []const u8,
        workspace: []const u8,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        outcome: *u8,

        fn run(self: @This()) void {
            const thread_alloc = std.heap.c_allocator;
            var store = session_store.Store.initFromHome(
                thread_alloc,
                self.home,
                self.workspace,
            ) catch {
                self.outcome.* = 3;
                return;
            };
            defer store.deinit(thread_alloc);
            var manager = communication_manager_mod.Manager{ .sessions = &store };
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            const result = manager.poll(
                thread_alloc,
                "thread-poll-child",
                "thread-work",
                100,
            ) catch {
                self.outcome.* = 3;
                return;
            };
            self.outcome.* = switch (result) {
                .emitted => 1,
                .pending => 2,
                .inactive, .stopped => 3,
            };
        }
    };

    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var outcomes = [_]u8{ 0, 0 };
    const workers = [_]PollWorker{
        .{
            .home = env.home,
            .workspace = env.workspace,
            .ready = &ready,
            .start = &start,
            .outcome = &outcomes[0],
        },
        .{
            .home = env.home,
            .workspace = env.workspace,
            .ready = &ready,
            .start = &start,
            .outcome = &outcomes[1],
        },
    };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, workers) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, PollWorker.run, .{worker});
    }
    while (ready.load(.seq_cst) != workers.len) std.atomic.spinLoopHint();
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();
    std.mem.sort(u8, &outcomes, {}, std.sort.asc(u8));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &outcomes);

    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    var page = try communication_manager.page(
        alloc,
        "thread-poll-child",
        "thread-human",
        "interval-parent",
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
}

test "durable interval poll stops and compacts a terminal work policy" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try setupRunningIntervalWork(alloc, &env, "terminal-poll-child", "terminal-work");

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "terminal-poll-child",
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "terminal-poll-child",
    };
    var lock = try control.acquireLock();
    {
        defer lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        record.queue[0].status = .completed;
        record.state = .idle;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .running,
            .current = .completed,
        }}, 50);
        try control.save(alloc, record);
    }

    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    try std.testing.expect((try communication_manager.poll(
        alloc,
        "terminal-poll-child",
        "terminal-work",
        100,
    )) == .stopped);
    try std.testing.expect((try communication_manager.poll(
        alloc,
        "terminal-poll-child",
        "terminal-work",
        101,
    )) == .inactive);

    var read_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "terminal-poll-child",
        .{},
    );
    defer read_capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &read_capability,
        .expected_session_id = "terminal-poll-child",
    };
    var ledger = try communication_state.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), ledger.work_notifications.len);
}

test "durable interval poll compacts policy after authoritative work eviction" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try setupRunningIntervalWork(alloc, &env, "evicted-poll-child", "evicted-work");

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "evicted-poll-child",
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "evicted-poll-child",
    };
    var lock = try control.acquireLock();
    {
        defer lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        record.queue[0].status = .completed;
        record.state = .idle;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .running,
            .current = .completed,
        }}, 50);
        for (record.queue) |*message| message.deinit(alloc);
        alloc.free(record.queue);
        record.queue = try alloc.alloc(domain.QueuedMessage, 0);
        record.queue_evicted = true;
        try control.save(alloc, record);
    }

    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    try std.testing.expect((try communication_manager.poll(
        alloc,
        "evicted-poll-child",
        "evicted-work",
        100,
    )) == .stopped);
    try std.testing.expect((try communication_manager.poll(
        alloc,
        "evicted-poll-child",
        "evicted-work",
        101,
    )) == .inactive);

    var read_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "evicted-poll-child",
        .{},
    );
    defer read_capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &read_capability,
        .expected_session_id = "evicted-poll-child",
    };
    var ledger = try communication_state.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), ledger.work_notifications.len);
    try std.testing.expectEqual(@as(usize, 0), ledger.deliveries.len);
}

test "interval poll lock contention and indeterminate commit retry do not lose or duplicate" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try setupRunningIntervalWork(alloc, &env, "retry-poll-child", "retry-work");

    var lock_clock = LockFailureClock{};
    var busy_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
        .child_store_options = .{ .lock_ops = .{
            .ctx = &lock_clock,
            .try_lock = alwaysBusy,
            .now_ms = lockNow,
            .sleep_ms = lockSleep,
        } },
    };
    try std.testing.expectError(
        error.LockBusy,
        busy_manager.poll(alloc, "retry-poll-child", "retry-work", 100),
    );

    var sync_failure = CommitSyncFailure{};
    var indeterminate_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
        .child_store_options = .{ .replace_ops = .{
            .ctx = &sync_failure,
            .sync_dir = CommitSyncFailure.syncDir,
        } },
    };
    try std.testing.expectError(
        error.CommitIndeterminate,
        indeterminate_manager.poll(alloc, "retry-poll-child", "retry-work", 100),
    );

    var retry_manager = communication_manager_mod.Manager{ .sessions = &env.store };
    try std.testing.expectEqual(@as(i64, 200), (try retry_manager.poll(
        alloc,
        "retry-poll-child",
        "retry-work",
        100,
    )).pending);
    var page = try retry_manager.page(
        alloc,
        "retry-poll-child",
        "retry-human",
        "interval-parent",
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
    const expected_id = communication.stableIntervalDeliveryId(
        "retry-poll-child",
        "retry-work",
        100,
    );
    try std.testing.expectEqualStrings(&expected_id, page.deliveries[0].id);
}

test "communication admission indeterminate retry is exact and does not double admit" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "retry-admission-child");
    const input: communication.DeliveryInput = .{
        .id = "retry-admission-delivery",
        .source_id = "retry-admission-child",
        .target_id = "parent-id",
        .timestamp_ms = 1,
        .payload = .{ .message = "exactly once" },
    };
    var sync_failure = CommitSyncFailure{};
    var indeterminate = communication_manager_mod.Manager{
        .sessions = &env.store,
        .child_store_options = .{ .replace_ops = .{
            .ctx = &sync_failure,
            .sync_dir = CommitSyncFailure.syncDir,
        } },
    };
    try std.testing.expectError(
        error.CommitIndeterminate,
        indeterminate.publish(
            alloc,
            "retry-admission-child",
            input,
        ),
    );

    var retry = communication_manager_mod.Manager{ .sessions = &env.store };
    try std.testing.expectEqual(
        communication.AppendResult{ .duplicate = 1 },
        try retry.publish(alloc, "retry-admission-child", input),
    );
    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "retry-admission-child",
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "retry-admission-child",
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), ledger.deliveries.len);
    try std.testing.expectEqual(@as(u64, 1), ledger.generation);
    try std.testing.expectEqual(@as(u64, 2), ledger.next_sequence);
}

test "durable approval registry commits root grant before resolving child request" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
        .prompt = "do work",
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var child_capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer child_capability.deinit();
    var child_control = control_store.Store{
        .capability = &child_capability,
        .expected_child_id = "child-id",
    };
    var child_lock = try child_control.acquireLock();
    {
        defer child_lock.release();
        var record = try child_control.load(alloc);
        defer record.deinit(alloc);
        record.queue[0].status = .running;
        record.state = .running;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[0].id,
            .previous = .pending,
            .current = .running,
        }}, 2);
        try std.testing.expectEqual(
            work_events.ApprovalTransition.changed,
            try work_events.awaitApproval(
                alloc,
                &record,
                record.queue[0].id,
                3,
            ),
        );
        try child_control.save(alloc, record);
    }

    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    const persistence = durable.interface();
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("bash"),
        .target_path = @constCast("git status"),
    }};
    const prepared = [_]u8{9} ** 32;
    const tool_approval: communication.ApprovalInput = .{
        .id = "approval-tool",
        .kind = .tool,
        .child_id = "child-id",
        .root_id = "parent-id",
        .work_id = "op-create",
        .prepared_fingerprint = prepared,
        .label = "run git status",
        .explanation = "requires human review",
        .grants = &grants,
        .created_at_ms = 3,
    };
    try persistence.register_fn(persistence.context, tool_approval);
    var retry_approval = tool_approval;
    retry_approval.created_at_ms = 30;
    try persistence.register_fn(persistence.context, retry_approval);
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "approval-tool",
        .child_id = "child-id",
        .decision = .always,
        .timestamp_ms = 4,
    }, communication.approvalIdentityFingerprint(tool_approval));

    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "parent-id",
        .{},
    );
    defer root_capability.deinit();
    const root_store = communication_store.Store{
        .capability = &root_capability,
        .expected_session_id = "parent-id",
    };
    var root_ledger = try root_store.load(alloc);
    defer root_ledger.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), root_ledger.authority_generation);
    try std.testing.expectEqual(@as(usize, 1), root_ledger.authority_grants.len);
    try std.testing.expectEqualStrings("git status", root_ledger.authority_grants[0].target_path);

    const once_approval: communication.ApprovalInput = .{
        .id = "approval-once",
        .kind = .tool,
        .child_id = "child-id",
        .root_id = "parent-id",
        .work_id = "op-create",
        .prepared_fingerprint = [_]u8{8} ** 32,
        .label = "run once",
        .explanation = null,
        .grants = &grants,
        .created_at_ms = 5,
    };
    try persistence.register_fn(persistence.context, once_approval);
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "approval-once",
        .child_id = "child-id",
        .decision = .once,
        .timestamp_ms = 6,
    }, communication.approvalIdentityFingerprint(once_approval));
    var root_after_once = try root_store.load(alloc);
    defer root_after_once.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), root_after_once.authority_generation);
    try std.testing.expectEqual(@as(usize, 1), root_after_once.authority_grants.len);

    var child_read = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "child-id",
        .{},
    );
    defer child_read.deinit();
    const child_store = communication_store.Store{
        .capability = &child_read,
        .expected_session_id = "child-id",
    };
    var child_ledger = try child_store.load(alloc);
    defer child_ledger.deinit(alloc);
    const approval = communication.findApproval(
        child_ledger.approvals,
        "approval-tool",
    ).?;
    try std.testing.expectEqual(communication.ApprovalStatus.allowed_always, approval.status);
    var resumed_control = try child_control.load(alloc);
    defer resumed_control.deinit(alloc);
    try std.testing.expectEqual(domain.State.running, resumed_control.state);
    try std.testing.expectEqual(domain.QueueStatus.running, resumed_control.queue[0].status);
    const resumed_event = resumed_control.events[resumed_control.events.len - 1];
    try std.testing.expectEqual(
        domain.QueueStatus.running,
        resumed_event.kind.work_transition.current,
    );

    const relationship_approval: communication.ApprovalInput = .{
        .id = "approval-relationship",
        .kind = .relationship,
        .child_id = "child-id",
        .root_id = "parent-id",
        .work_id = null,
        .relationship = .{
            .action = .reparent,
            .prospective_parent_id = "parent-id",
            .operation_id = "relationship-operation",
        },
        .prepared_fingerprint = communication.relationshipPreparedFingerprint(
            .reparent,
            "child-id",
            "parent-id",
            "relationship-operation",
        ),
        .label = "attach child",
        .explanation = null,
        .grants = &.{},
        .created_at_ms = 7,
    };
    try persistence.register_fn(persistence.context, relationship_approval);
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "approval-relationship",
        .child_id = "child-id",
        .decision = .once,
        .timestamp_ms = 8,
    }, communication.approvalIdentityFingerprint(relationship_approval));

    var partial_lock = try child_control.acquireLock();
    {
        defer partial_lock.release();
        const writable_child_store = communication_store.Store{
            .capability = &child_capability,
            .expected_session_id = "child-id",
        };
        var record = try child_control.load(alloc);
        defer record.deinit(alloc);
        try std.testing.expectEqual(
            work_events.ApprovalTransition.changed,
            try work_events.awaitApproval(
                alloc,
                &record,
                record.queue[0].id,
                9,
            ),
        );
        try child_control.save(alloc, record);
        var ledger = try writable_child_store.load(alloc);
        defer ledger.deinit(alloc);
        try std.testing.expectEqual(
            communication.RegisterApprovalResult.registered,
            try communication.registerApproval(alloc, &ledger, .{
                .id = "approval-partial",
                .kind = .tool,
                .child_id = "child-id",
                .root_id = "parent-id",
                .work_id = "op-create",
                .prepared_fingerprint = [_]u8{6} ** 32,
                .label = "partially committed response",
                .explanation = null,
                .grants = &.{},
                .created_at_ms = 9,
            }),
        );
        const partial = communication.findApproval(
            ledger.approvals,
            "approval-partial",
        ).?;
        const revision = ledger.generation + 1;
        try communication.applyApprovalDecision(partial, .accept_once, 10, revision);
        ledger.generation = revision;
        try writable_child_store.save(alloc, ledger);
    }
    var partial_ledger = try (communication_store.Store{
        .capability = &child_capability,
        .expected_session_id = "child-id",
    }).load(alloc);
    defer partial_ledger.deinit(alloc);
    const partial_fingerprint = communication.findApproval(
        partial_ledger.approvals,
        "approval-partial",
    ).?.identity_fingerprint;
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "approval-partial",
        .child_id = "child-id",
        .decision = .once,
        .timestamp_ms = 11,
    }, partial_fingerprint);
    var reconciled = try child_control.load(alloc);
    defer reconciled.deinit(alloc);
    try std.testing.expectEqual(domain.State.running, reconciled.state);
    try std.testing.expectEqual(domain.QueueStatus.running, reconciled.queue[0].status);
}

test "relationship approval remains distinct and can authorize a detached chat" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "other-parent-id");
    try env.createSession(alloc, "detached-child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "detached",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create-detached",
        .created_child_id = "detached-child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "detached-child-id",
    } });
    defer detach.deinit(alloc);
    var detached = try manager.execute(alloc, detach, .{
        .actor_id = "parent-id",
        .operation_id = "op-detach",
        .timestamp_ms = 2,
    });
    defer detached.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, detached.receipt.code);

    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    const persistence = durable.interface();
    const fingerprint = communication.relationshipPreparedFingerprint(
        .attach,
        "detached-child-id",
        "parent-id",
        "op-approved-attach",
    );
    const attach_approval: communication.ApprovalInput = .{
        .id = "relationship-attach-approval",
        .kind = .relationship,
        .child_id = "detached-child-id",
        .root_id = "parent-id",
        .work_id = null,
        .relationship = .{
            .action = .attach,
            .prospective_parent_id = "parent-id",
            .operation_id = "op-approved-attach",
        },
        .prepared_fingerprint = fingerprint,
        .label = "attach detached chat",
        .explanation = null,
        .grants = &.{},
        .created_at_ms = 3,
    };
    try persistence.register_fn(persistence.context, attach_approval);
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "relationship-attach-approval",
        .child_id = "detached-child-id",
        .decision = .once,
        .timestamp_ms = 4,
    }, communication.approvalIdentityFingerprint(attach_approval));
    {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            "detached-child-id",
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "detached-child-id",
        };
        var ledger = try store.load(alloc);
        defer ledger.deinit(alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            "relationship-attach-approval",
        ).?;
        try std.testing.expectEqual(communication.ApprovalKind.relationship, approval.kind);
        try std.testing.expectEqual(communication.ApprovalStatus.allowed_once, approval.status);
    }

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "detached-child-id",
        .parent_id = "parent-id",
    } });
    defer attach.deinit(alloc);
    var attached = try manager.execute(alloc, attach, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-attach",
        .relationship_authorization = .{ .approval = "relationship-attach-approval" },
        .timestamp_ms = 5,
    });
    defer attached.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, attached.receipt.code);

    var replay = try manager.execute(alloc, attach, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-attach",
        .relationship_authorization = .{ .approval = "relationship-attach-approval" },
        .timestamp_ms = 6,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(attached.receipt.event_sequence, replay.receipt.event_sequence);

    var changed_approval = try manager.execute(alloc, attach, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-attach",
        .relationship_authorization = .{ .approval = "different-approval" },
        .timestamp_ms = 6,
    });
    defer changed_approval.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, changed_approval.failure.code);

    var reused = try manager.execute(alloc, attach, .{
        .actor_id = "parent-id",
        .operation_id = "op-reuse-approval",
        .relationship_authorization = .{ .approval = "relationship-attach-approval" },
        .timestamp_ms = 7,
    });
    defer reused.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, reused.failure.code);

    var changed_parent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "detached-child-id",
        .parent_id = "other-parent-id",
    } });
    defer changed_parent.deinit(alloc);
    var conflict = try manager.execute(alloc, changed_parent, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-attach",
        .relationship_authorization = .{ .approval = "relationship-attach-approval" },
        .timestamp_ms = 8,
    });
    defer conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, conflict.failure.code);

    var consumed_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "detached-child-id",
        .{},
    );
    defer consumed_capability.deinit();
    const consumed_store = communication_store.Store{
        .capability = &consumed_capability,
        .expected_session_id = "detached-child-id",
    };
    var consumed_ledger = try consumed_store.load(alloc);
    defer consumed_ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.consumed,
        communication.findApproval(
            consumed_ledger.approvals,
            "relationship-attach-approval",
        ).?.status,
    );

    const reparent_approval: communication.ApprovalInput = .{
        .id = "relationship-reparent-approval",
        .kind = .relationship,
        .child_id = "detached-child-id",
        .root_id = "other-parent-id",
        .work_id = null,
        .relationship = .{
            .action = .reparent,
            .prospective_parent_id = "other-parent-id",
            .operation_id = "op-approved-reparent",
        },
        .prepared_fingerprint = communication.relationshipPreparedFingerprint(
            .reparent,
            "detached-child-id",
            "other-parent-id",
            "op-approved-reparent",
        ),
        .label = "reparent detached chat",
        .explanation = null,
        .grants = &.{},
        .created_at_ms = 9,
    };
    try persistence.register_fn(persistence.context, reparent_approval);
    try persistence.commit_response_fn(persistence.context, .{
        .request_id = "relationship-reparent-approval",
        .child_id = "detached-child-id",
        .decision = .once,
        .timestamp_ms = 10,
    }, communication.approvalIdentityFingerprint(reparent_approval));
    var reparent_command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "detached-child-id",
        .parent_id = "other-parent-id",
    } });
    defer reparent_command.deinit(alloc);
    var sync_failure = CommitSyncFailure{};
    var indeterminate_manager = Manager{
        .sessions = &env.store,
        .options = .{ .child_store = .{ .replace_ops = .{
            .ctx = &sync_failure,
            .sync_dir = CommitSyncFailure.syncDir,
        } } },
    };
    var reparented = try indeterminate_manager.execute(alloc, reparent_command, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-reparent",
        .relationship_authorization = .{ .approval = "relationship-reparent-approval" },
        .timestamp_ms = 11,
    });
    defer reparented.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, reparented.receipt.code);

    var restarted_store = try session_store.Store.initFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer restarted_store.deinit(alloc);
    var restarted_manager = Manager{ .sessions = &restarted_store };
    var restarted_replay = try restarted_manager.execute(alloc, reparent_command, .{
        .actor_id = "parent-id",
        .operation_id = "op-approved-reparent",
        .relationship_authorization = .{ .approval = "relationship-reparent-approval" },
        .timestamp_ms = 12,
    });
    defer restarted_replay.deinit(alloc);
    try std.testing.expectEqual(
        reparented.receipt.event_sequence,
        restarted_replay.receipt.event_sequence,
    );
    var restarted_capability = try restarted_store.openSubagentControlCapabilityReadOnly(
        alloc,
        "detached-child-id",
        .{},
    );
    defer restarted_capability.deinit();
    const restarted_communication = communication_store.Store{
        .capability = &restarted_capability,
        .expected_session_id = "detached-child-id",
    };
    var restarted_ledger = try restarted_communication.load(alloc);
    defer restarted_ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.consumed,
        communication.findApproval(
            restarted_ledger.approvals,
            "relationship-reparent-approval",
        ).?.status,
    );
}

test "live authority resolver refreshes deny rules before the next child action" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    try env.createSession(alloc, "sibling-id");
    try env.createSession(alloc, "other-root-id");
    try env.createSession(alloc, "other-child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
        .prompt = "inspect",
        .permission_mode = .auto,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "op-create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var create_sibling = try domain.validateCommand(alloc, .{ .create = .{
        .name = "sibling",
        .mode = .persistent,
        .permission_mode = .auto,
    } });
    defer create_sibling.deinit(alloc);
    var sibling_created = try manager.execute(alloc, create_sibling, .{
        .actor_id = "parent-id",
        .operation_id = "op-create-sibling",
        .created_child_id = "sibling-id",
        .timestamp_ms = 1,
    });
    defer sibling_created.deinit(alloc);
    var create_other = try domain.validateCommand(alloc, .{ .create = .{
        .name = "other",
        .mode = .persistent,
        .permission_mode = .auto,
    } });
    defer create_other.deinit(alloc);
    var other_created = try manager.execute(alloc, create_other, .{
        .actor_id = "other-root-id",
        .operation_id = "op-create-other",
        .created_child_id = "other-child-id",
        .timestamp_ms = 1,
    });
    defer other_created.deinit(alloc);

    const FakeHost = struct {
        generation: u64 = 1,
        deny: bool = false,
        calls: usize = 0,

        fn resolve(raw: ?*anyopaque, output_alloc: Allocator, root_id: []const u8) !authority.HostAuthority {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            _ = root_id;
            const tools = try output_alloc.alloc([]u8, 1);
            errdefer output_alloc.free(tools);
            tools[0] = try output_alloc.dupe(u8, "run_command");
            errdefer output_alloc.free(tools[0]);
            const integrations = try output_alloc.alloc([]u8, 1);
            errdefer output_alloc.free(integrations);
            integrations[0] = try output_alloc.dupe(u8, "mcp:test");
            errdefer output_alloc.free(integrations[0]);
            const rules = try output_alloc.alloc(types.PermissionRule, 1);
            errdefer output_alloc.free(rules);
            const permission = try output_alloc.dupe(u8, "bash");
            errdefer output_alloc.free(permission);
            const pattern = try output_alloc.dupe(u8, "git status");
            errdefer output_alloc.free(pattern);
            rules[0] = .{
                .permission = permission,
                .pattern = pattern,
                .action = if (self.deny) .deny else .ask,
            };
            return .{
                .generation = self.generation,
                .tools = tools,
                .integrations = integrations,
                .rules = .{ .rules = rules },
                .grants = try output_alloc.alloc(types.PermissionGrant, 0),
            };
        }
    };
    var fake = FakeHost{};
    var root_capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "parent-id",
        .{},
    );
    defer root_capability.deinit();
    const root_store = communication_store.Store{
        .capability = &root_capability,
        .expected_session_id = "parent-id",
    };
    var root_lock = try root_store.acquireLock();
    {
        defer root_lock.release();
        var root_ledger = try communication.Ledger.init(alloc, "parent-id");
        defer root_ledger.deinit(alloc);
        const inherited_grants = [_]types.PermissionGrant{.{
            .tool_name = @constCast("run_command"),
            .target_path = @constCast("git status"),
        }};
        try std.testing.expect(try communication.applyAlwaysGrants(
            alloc,
            &root_ledger,
            &inherited_grants,
        ));
        try root_store.save(alloc, root_ledger);
    }
    var resolver = authority.Resolver{
        .sessions = &env.store,
        .host = .{ .context = &fake, .resolve_fn = FakeHost.resolve },
    };
    var first = try resolver.resolve(alloc, "child-id");
    defer first.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.auto, first.permission_mode);
    try std.testing.expectEqualStrings("run_command", first.tools[0]);
    try std.testing.expectEqualStrings("mcp:test", first.integrations[0]);
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.allow,
        try communication.decideToolAuthority(
            alloc,
            first.view(),
            env.workspace,
            "run_command",
            "git status",
            .none,
        ),
    );
    var sibling = try resolver.resolve(alloc, "sibling-id");
    defer sibling.deinit(alloc);
    try std.testing.expectEqualStrings("parent-id", sibling.root_id);
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.allow,
        try communication.decideToolAuthority(
            alloc,
            sibling.view(),
            env.workspace,
            "run_command",
            "git status",
            .none,
        ),
    );
    var unrelated = try resolver.resolve(alloc, "other-child-id");
    defer unrelated.deinit(alloc);
    try std.testing.expectEqualStrings("other-root-id", unrelated.root_id);
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.ask,
        try communication.decideToolAuthority(
            alloc,
            unrelated.view(),
            env.workspace,
            "run_command",
            "git status",
            .none,
        ),
    );
    var reparent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "sibling-id",
        .parent_id = "other-root-id",
    } });
    defer reparent.deinit(alloc);
    var reparented = try manager.execute(alloc, reparent, .{
        .actor_id = "parent-id",
        .operation_id = "op-reparent-sibling",
        .relationship_authorization = .direct,
        .timestamp_ms = 2,
    });
    defer reparented.deinit(alloc);
    var moved = try resolver.resolve(alloc, "sibling-id");
    defer moved.deinit(alloc);
    try std.testing.expectEqualStrings("other-root-id", moved.root_id);
    try std.testing.expect(sibling.generation != moved.generation);
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.ask,
        try communication.decideToolAuthority(
            alloc,
            moved.view(),
            env.workspace,
            "run_command",
            "git status",
            .none,
        ),
    );

    fake.generation = 2;
    fake.deny = true;
    var refreshed = try resolver.resolve(alloc, "child-id");
    defer refreshed.deinit(alloc);
    try std.testing.expect(first.generation != refreshed.generation);
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.deny,
        try communication.decideToolAuthority(
            alloc,
            refreshed.view(),
            env.workspace,
            "run_command",
            "git status",
            .none,
        ),
    );
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
}

test "control access remains available when transcript replay exhausts its allocator" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "healthy-root");
    try env.createLargeSession(alloc, "large-child", 2 * 1024 * 1024);
    var manager = Manager{ .sessions = &env.store };
    var bounded_memory: [512 * 1024]u8 = undefined;

    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        try std.testing.expectError(
            error.SessionReplayResourceExhausted,
            env.store.loadReadOnlyDetail(bounded.allocator(), "large-child", .{}),
        );
    }

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "large-child",
        .parent_id = "parent-id",
    } });
    defer attach.deinit(alloc);
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var attached = try manager.execute(bounded.allocator(), attach, .{
            .actor_id = "parent-id",
            .operation_id = "attach-large-child",
            .relationship_authorization = .direct,
            .timestamp_ms = 1,
        });
        defer attached.deinit(bounded.allocator());
        try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, attached.receipt.code);
    }

    var read_only_store = try session_store.Store.initReadOnlyFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer read_only_store.deinit(alloc);
    var read_only_manager = Manager{ .sessions = &read_only_store };
    var inspect_command = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "large-child",
        .sections = &.{ .status, .relationship, .configuration },
    } });
    defer inspect_command.deinit(alloc);
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var inspected = try read_only_manager.execute(bounded.allocator(), inspect_command, .{
            .actor_id = "parent-id",
            .timestamp_ms = 2,
        });
        defer inspected.deinit(bounded.allocator());
        try std.testing.expectEqualStrings("large-child", inspected.inspection.child_id);
        try std.testing.expectEqualStrings("parent-id", inspected.inspection.parent_id.?);
    }
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var snapshot = try read_only_manager.snapshot(bounded.allocator(), .{
            .root_id = "healthy-root",
        });
        defer snapshot.deinit(bounded.allocator());
        try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.nodes.len);
        try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.diagnostics.len);
    }

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = "large-child",
        .name = "large child renamed",
    } });
    defer configure.deinit(alloc);
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var configured = try manager.execute(bounded.allocator(), configure, .{
            .actor_id = "parent-id",
            .operation_id = "configure-large-child",
            .timestamp_ms = 3,
        });
        defer configured.deinit(bounded.allocator());
        try std.testing.expectEqual(domain.OutcomeCode.configured, configured.receipt.code);
    }

    var send = try validateSend(alloc, "large-child", "queued without replay");
    defer send.deinit(alloc);
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var queued = try manager.execute(bounded.allocator(), send, .{
            .actor_id = "parent-id",
            .operation_id = "send-large-child",
            .timestamp_ms = 4,
        });
        defer queued.deinit(bounded.allocator());
        try std.testing.expectEqual(domain.OutcomeCode.message_queued, queued.receipt.code);
    }

    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "large-child",
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    {
        var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
        var cancelled = try manager.execute(bounded.allocator(), cancel, .{
            .actor_id = "parent-id",
            .operation_id = "cancel-large-child",
            .timestamp_ms = 5,
        });
        defer cancelled.deinit(bounded.allocator());
        try std.testing.expectEqual(domain.OutcomeCode.lifecycle_changed, cancelled.receipt.code);
    }
}

test "manager snapshot owns bounded empty and nested tree pages" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");
    try env.createSession(alloc, "child-c");
    var manager = Manager{ .sessions = &env.store };

    var empty = try manager.snapshot(alloc, .{ .root_id = "root-id", .limit = 2 });
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.snapshot.nodes.len);
    try std.testing.expect(empty.snapshot.next_cursor == null);

    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-a",
        .attach,
        "child-a",
        "root-id",
    );
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-b",
        .attach,
        "child-b",
        "child-a",
    );
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-c",
        .attach,
        "child-c",
        "root-id",
    );

    var first = try manager.snapshot(alloc, .{ .root_id = "root-id", .limit = 2 });
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.snapshot.nodes.len);
    try std.testing.expectEqualStrings("child-a", first.snapshot.nodes[0].child_id);
    try std.testing.expectEqual(@as(usize, 0), first.snapshot.nodes[0].depth);
    try std.testing.expectEqualStrings("child-b", first.snapshot.nodes[1].child_id);
    try std.testing.expectEqual(@as(usize, 1), first.snapshot.nodes[1].depth);
    try std.testing.expect(first.snapshot.next_cursor != null);

    var second = try manager.snapshot(alloc, .{
        .root_id = "root-id",
        .cursor = first.snapshot.next_cursor,
        .limit = 2,
    });
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), second.snapshot.nodes.len);
    try std.testing.expectEqualStrings("child-c", second.snapshot.nodes[0].child_id);
    try std.testing.expectEqual(@as(usize, 0), second.snapshot.nodes[0].depth);
    try std.testing.expect(second.snapshot.page_cursor != null);

    var anchored = try manager.snapshot(alloc, .{
        .root_id = "root-id",
        .anchor_id = "child-c",
        .limit = 2,
    });
    defer anchored.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), anchored.snapshot.nodes.len);
    try std.testing.expectEqualStrings("child-c", anchored.snapshot.nodes[0].child_id);
    try std.testing.expect(anchored.snapshot.page_cursor != null);

    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "reparent-b",
        .reparent,
        "child-b",
        "child-c",
    );
    var stale = try manager.snapshot(alloc, .{
        .root_id = "root-id",
        .cursor = first.snapshot.next_cursor,
        .limit = 2,
    });
    defer stale.deinit(alloc);
    try std.testing.expect(stale.snapshot.restart_required);
    try std.testing.expectEqual(@as(usize, 0), stale.snapshot.nodes.len);

    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "detach-a",
        .detach,
        "child-a",
        null,
    );
    var updated = try manager.snapshot(alloc, .{ .root_id = "root-id", .limit = 10 });
    defer updated.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), updated.snapshot.nodes.len);
    try std.testing.expectEqualStrings("child-c", updated.snapshot.nodes[0].child_id);
    try std.testing.expectEqualStrings("child-b", updated.snapshot.nodes[1].child_id);
    try std.testing.expectEqual(@as(usize, 1), updated.snapshot.nodes[1].depth);
}

test "manager snapshot bounds discovery before tree pagination" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    var manager = Manager{ .sessions = &env.store };
    const relationship_count = relationship_index.max_candidate_reads + 1;

    for (0..relationship_count) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "child-{d:0>4}", .{index});
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(&operation_buffer, "attach-{d:0>4}", .{index});
        try env.createSession(alloc, child_id);
        try executeRelationshipForTest(
            alloc,
            &manager,
            "root-id",
            operation_id,
            .attach,
            child_id,
            "root-id",
        );
    }
    for (0..session_store.relationship_migration_candidate_limit + 1) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "ordinary-{d:0>4}", .{index});
        try env.createSession(alloc, id);
    }

    var counters = SnapshotCounters{};
    var snapshot = try manager.snapshotWithCounters(
        alloc,
        .{ .root_id = "root-id", .limit = 25 },
        &counters,
    );
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 25), snapshot.snapshot.nodes.len);
    try std.testing.expect(counters.discovery_session_ids <= 128);
    try std.testing.expect(counters.relationship_reads <= 128);
    try std.testing.expect(counters.control_reads <= 128);
    try std.testing.expect(counters.candidates_owned <= 128);
    for (snapshot.snapshot.nodes, 0..) |node, index| {
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "child-{d:0>4}",
            .{index},
        );
        try std.testing.expectEqualStrings(expected, node.child_id);
    }

    const cursor = try alloc.dupe(u8, snapshot.snapshot.next_cursor.?);
    defer alloc.free(cursor);
    var expected_index: usize = 25;
    var page_counters = SnapshotCounters{};
    var page = try manager.snapshotWithCounters(
        alloc,
        .{ .root_id = "root-id", .cursor = cursor, .limit = 25 },
        &page_counters,
    );
    defer page.deinit(alloc);
    try std.testing.expect(page == .snapshot);
    try std.testing.expect(page_counters.discovery_session_ids <= 128);
    try std.testing.expect(page_counters.relationship_reads <= 128);
    try std.testing.expect(page_counters.control_reads <= 128);
    try std.testing.expect(page_counters.candidates_owned <= 128);
    for (page.snapshot.nodes) |node| {
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buffer,
            "child-{d:0>4}",
            .{expected_index},
        );
        try std.testing.expectEqualStrings(expected, node.child_id);
        expected_index += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), expected_index);

    var last_child_buffer: [32]u8 = undefined;
    const last_child_id = try std.fmt.bufPrint(
        &last_child_buffer,
        "child-{d:0>4}",
        .{relationship_count - 1},
    );
    var anchored_counters = SnapshotCounters{};
    var anchored = try manager.snapshotWithCounters(
        alloc,
        .{
            .root_id = "root-id",
            .anchor_id = last_child_id,
            .limit = 1,
        },
        &anchored_counters,
    );
    defer anchored.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), anchored.snapshot.nodes.len);
    try std.testing.expectEqualStrings(
        last_child_id,
        anchored.snapshot.nodes[0].child_id,
    );
    try std.testing.expect(
        anchored_counters.discovery_session_ids <= 128,
    );
    try std.testing.expect(anchored_counters.relationship_reads <= 128);
    try std.testing.expect(anchored_counters.control_reads <= 128);
    try std.testing.expect(anchored_counters.candidates_owned <= 128);
}

test "manager snapshot migrates legacy control edges without global discovery" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "legacy-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "legacy-attach",
        .attach,
        "legacy-child",
        "root-id",
    );
    try env.indexSession(alloc, "legacy-child");
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "root-id",
        "legacy-child",
        .{},
    ));

    var counters = SnapshotCounters{};
    var snapshot = try manager.snapshotWithCounters(
        alloc,
        .{ .root_id = "root-id" },
        &counters,
    );
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.snapshot.nodes.len);
    try std.testing.expectEqualStrings(
        "legacy-child",
        snapshot.snapshot.nodes[0].child_id,
    );
    try std.testing.expect(counters.discovery_session_ids <=
        relationship_index.max_candidate_reads +
            session_store.relationship_migration_candidate_limit *
                (max_snapshot_migration_pages - 1));
}

test "descendant count remains unknown until legacy migration completes" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "legacy-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "legacy-attach",
        .attach,
        "legacy-child",
        "root-id",
    );
    try env.commitSession(alloc, "legacy-child", 2);
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "root-id",
        "legacy-child",
        .{},
    ));

    for (0..session_store.relationship_migration_candidate_limit + 1) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "newer-{d:0>3}", .{index});
        try env.createSession(alloc, id);
        try env.commitSession(alloc, id, @intCast(100 + index));
    }

    try std.testing.expect((try relationship_index.activeCountIfMigrationComplete(
        alloc,
        &env.store,
        "root-id",
        .{},
    )) == null);
    _ = try relationship_index.migrateLegacyPage(alloc, &env.store, "root-id", .{});
    try std.testing.expect((try relationship_index.activeCountIfMigrationComplete(
        alloc,
        &env.store,
        "root-id",
        .{},
    )) == null);

    var active_count: ?u64 = null;
    for (0..8) |_| {
        _ = try relationship_index.migrateLegacyPage(alloc, &env.store, "root-id", .{});
        active_count = try relationship_index.activeCountIfMigrationComplete(
            alloc,
            &env.store,
            "root-id",
            .{},
        );
        if (active_count != null) break;
    }
    try std.testing.expectEqual(@as(?u64, 1), active_count);
}

test "legacy migration participates in the parent control lock boundary" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.indexSession(alloc, "root-id");
    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "root-id",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "root-id",
    };
    var lock = try store.acquireLock();
    defer lock.release();

    try std.testing.expectError(
        error.LockBusy,
        relationship_index.migrateLegacyPage(
            alloc,
            &env.store,
            "root-id",
            .{},
        ),
    );
}

test "missing child diagnostic retains the exact stale parent edge" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "missing-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-missing",
        .attach,
        "missing-child",
        "root-id",
    );
    var writer = try env.store.resumeForWrite(alloc, "missing-child");
    try std.testing.expectEqual(
        session_store.PristineDiscardDisposition.discarded,
        env.store.deleteCommittedSession(alloc, &writer),
    );

    var snapshot = try manager.snapshot(alloc, .{ .root_id = "root-id" });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.snapshot.diagnostics.len);
    const diagnostic = snapshot.snapshot.diagnostics[0];
    try std.testing.expectEqual(TreeDiagnosticCode.session_unavailable, diagnostic.code);
    try std.testing.expectEqualStrings("missing-child", diagnostic.session_id);
    try std.testing.expectEqualStrings("root-id", diagnostic.parent_id.?);
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        diagnostic.parent_id.?,
        diagnostic.session_id,
        .{},
    ));
    try std.testing.expect((try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "root-id",
        "missing-child",
        .{},
    )) == null);
}

test "manager snapshot recovers every pending free boundary without exposing the edge" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);

    for (2..4) |fail_at| {
        var root_buffer: [32]u8 = undefined;
        const root_id = try std.fmt.bufPrint(
            &root_buffer,
            "free-root-{d}",
            .{fail_at},
        );
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(
            &child_buffer,
            "free-child-{d}",
            .{fail_at},
        );
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(
            &operation_buffer,
            "free-attach-{d}",
            .{fail_at},
        );
        try env.createSession(alloc, root_id);
        try env.createSession(alloc, child_id);
        var manager = Manager{ .sessions = &env.store };
        try executeRelationshipForTest(
            alloc,
            &manager,
            root_id,
            operation_id,
            .attach,
            child_id,
            root_id,
        );
        try clearCanonicalParentForTest(alloc, &env, child_id);

        var sync_failure = FailSyncFileAt{ .fail_at = fail_at };
        try std.testing.expectError(
            error.StoreUnavailable,
            relationship_index.removeChild(
                alloc,
                &env.store,
                root_id,
                child_id,
                .{ .replace_ops = .{
                    .ctx = &sync_failure,
                    .sync_file = FailSyncFileAt.syncFile,
                } },
            ),
        );
        try std.testing.expectError(
            error.CommitIndeterminate,
            relationship_index.state(
                alloc,
                &env.store,
                root_id,
                .{},
            ),
        );
        var pending_read_only = try session_store.Store.initReadOnlyFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer pending_read_only.deinit(alloc);
        try std.testing.expectError(
            error.RecoveryRequired,
            relationship_index.recoverForQuery(
                alloc,
                &pending_read_only,
                root_id,
                .{},
            ),
        );

        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer restarted.deinit(alloc);
        var restarted_manager = Manager{ .sessions = &restarted };
        var snapshot = try restarted_manager.snapshot(
            alloc,
            .{ .root_id = root_id },
        );
        defer snapshot.deinit(alloc);
        try std.testing.expect(snapshot == .snapshot);
        try std.testing.expect(!snapshot.snapshot.restart_required);
        try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.nodes.len);

        var read_only = try session_store.Store.initReadOnlyFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        defer read_only.deinit(alloc);
        const recovered_state = try relationship_index.state(
            alloc,
            &read_only,
            root_id,
            .{},
        );
        try std.testing.expectEqual(@as(u64, 1), recovered_state.high_watermark);
    }
}

test "manager legacy migration survives index republication and restart" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "migration-root");
    try env.createSession(alloc, "legacy-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "migration-root",
        "legacy-attach",
        .attach,
        "legacy-child",
        "migration-root",
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
        "migration-root",
        "legacy-child",
        .{},
    ));

    var discovered = false;
    for (0..8) |turn| {
        var restarted = try session_store.Store.initFromHome(
            alloc,
            env.home,
            env.workspace,
        );
        var restarted_manager = Manager{ .sessions = &restarted };
        var snapshot = try restarted_manager.snapshot(
            alloc,
            .{ .root_id = "migration-root" },
        );
        if (snapshot == .snapshot and snapshot.snapshot.nodes.len == 1) {
            discovered = std.mem.eql(
                u8,
                snapshot.snapshot.nodes[0].child_id,
                "legacy-child",
            );
        }
        snapshot.deinit(alloc);
        restarted.deinit(alloc);
        if (discovered) break;
        try env.commitSession(
            alloc,
            "migration-root",
            100 + @as(i64, @intCast(turn)),
        );
    }
    try std.testing.expect(discovered);
}

test "malformed relationship header degrades without erasing recovery evidence" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "repair-root");
    try env.createSession(alloc, "repair-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "repair-root",
        "repair-attach",
        .attach,
        "repair-child",
        "repair-root",
    );
    try env.indexSession(alloc, "repair-child");

    const original_header = blk: {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            "repair-root",
            .{},
        );
        defer capability.deinit();
        var file = try capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "relationship-index.bin",
        );
        defer file.deinit();
        break :blk try file.readToEnd(alloc, 1024);
    };
    defer alloc.free(original_header);

    const malformed = "malformed";
    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "repair-root",
            .{},
        );
        defer capability.deinit();
        var replaced = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "relationship-index.bin",
            malformed,
        );
        replaced.deinit(alloc);
    }

    for (0..2) |_| {
        var snapshot = try manager.snapshot(
            alloc,
            .{ .root_id = "repair-root" },
        );
        defer snapshot.deinit(alloc);
        try std.testing.expect(snapshot == .failure);
        try std.testing.expectEqual(FailureCode.store_failure, snapshot.failure.code);
    }

    {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            "repair-root",
            .{},
        );
        defer capability.deinit();
        var file = try capability.openFileReadOnly(
            alloc,
            .subagent_control,
            "relationship-index.bin",
        );
        defer file.deinit();
        const preserved = try file.readToEnd(alloc, 1024);
        defer alloc.free(preserved);
        try std.testing.expectEqualStrings(malformed, preserved);
    }

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "repair-root",
            .{},
        );
        defer capability.deinit();
        var replaced = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "relationship-index.bin",
            original_header,
        );
        replaced.deinit(alloc);
    }

    var restored = try manager.snapshot(
        alloc,
        .{ .root_id = "repair-root" },
    );
    defer restored.deinit(alloc);
    try std.testing.expect(restored == .snapshot);
    try std.testing.expectEqual(@as(usize, 1), restored.snapshot.nodes.len);
    try std.testing.expectEqualStrings(
        "repair-child",
        restored.snapshot.nodes[0].child_id,
    );
}

test "malformed relationship page recovers through bounded canonical migration" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "repair-root");
    try env.createSession(alloc, "repair-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "repair-root",
        "repair-attach",
        .attach,
        "repair-child",
        "repair-root",
    );
    try env.indexSession(alloc, "repair-child");

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "repair-root",
            .{},
        );
        defer capability.deinit();
        var replaced = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "relationship-page-0000000000000000.bin",
            "malformed",
        );
        replaced.deinit(alloc);
    }

    var recovered_page = false;
    for (0..4) |_| {
        var snapshot = try manager.snapshot(
            alloc,
            .{ .root_id = "repair-root" },
        );
        if (snapshot == .snapshot and snapshot.snapshot.nodes.len == 1) {
            recovered_page = std.mem.eql(
                u8,
                snapshot.snapshot.nodes[0].child_id,
                "repair-child",
            );
        }
        snapshot.deinit(alloc);
        if (recovered_page) break;
    }
    try std.testing.expect(recovered_page);
}

test "manager tree cursor decoder rejects malformed and fuzzed continuations" {
    const alloc = std.testing.allocator;
    const frames = [_]TraversalFrame{.{
        .parent_id = @constCast("root-id"),
        .generation = 7,
        .next_offset = 11,
        .high_watermark = 12,
    }};
    const encoded = try encodeTreeCursor(alloc, &frames);
    defer alloc.free(encoded);
    var parsed = try parseTreeCursor(alloc, encoded);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), parsed.frames.len);
    try std.testing.expectEqual(@as(u64, 7), parsed.frames[0].generation);
    try std.testing.expectEqual(@as(u64, 11), parsed.frames[0].next_offset);
    try std.testing.expectError(error.InvalidCursor, parseTreeCursor(alloc, "v2:"));
    try std.testing.fuzz({}, fuzzTreeCursor, .{ .corpus = &.{
        "",
        "v1:0:0",
        "v2:0000000000000000:0000000000000000",
    } });
}

fn fuzzTreeCursor(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var parsed = parseTreeCursor(std.testing.allocator, buffer[0..len]) catch return;
    parsed.deinit(std.testing.allocator);
}

test "manager snapshot revalidates stale edges and diagnoses relevant corrupt records" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-child",
        .attach,
        "child-id",
        "root-id",
    );

    var capability = try env.store.openSubagentControlCapabilityWritable(alloc, "child-id", .{});
    defer capability.deinit();
    var store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var lock = try store.acquireLock();
    defer lock.release();
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    alloc.free(record.parent_id.?);
    record.parent_id = try alloc.dupe(u8, "missing-root");
    try store.save(alloc, record);

    var stale = try manager.snapshot(alloc, .{ .root_id = "root-id" });
    defer stale.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), stale.snapshot.nodes.len);

    var replaced = try capability.atomicReplace(
        alloc,
        .subagent_control,
        "control.json",
        "{\"schema_version\":1",
    );
    replaced.deinit(alloc);
    var corrupt = try manager.snapshot(alloc, .{ .root_id = "root-id" });
    defer corrupt.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), corrupt.snapshot.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), corrupt.snapshot.diagnostics.len);
    try std.testing.expectEqualStrings(
        "child-id",
        corrupt.snapshot.diagnostics[0].session_id,
    );
    try std.testing.expectEqual(
        TreeDiagnosticCode.control_record_invalid,
        corrupt.snapshot.diagnostics[0].code,
    );
}

test "unrelated corrupt control metadata does not poison a healthy root snapshot" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "healthy-root");
    try env.createSession(alloc, "healthy-child");
    try env.createSession(alloc, "corrupt-chat");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "healthy-root",
        "attach-healthy-child",
        .attach,
        "healthy-child",
        "healthy-root",
    );

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "corrupt-chat",
            .{},
        );
        defer capability.deinit();
        var store = control_store.Store{
            .capability = &capability,
            .expected_child_id = "corrupt-chat",
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var replaced = try capability.atomicReplace(
            alloc,
            .subagent_control,
            "control.json",
            "{\"schema_version\":1",
        );
        replaced.deinit(alloc);
    }

    var snapshot = try manager.snapshot(alloc, .{ .root_id = "healthy-root" });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.snapshot.nodes.len);
    try std.testing.expectEqualStrings(
        "healthy-child",
        snapshot.snapshot.nodes[0].child_id,
    );
    try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.diagnostics.len);
    try std.testing.expect(!snapshot.snapshot.diagnostics_truncated);

    var ids = try env.store.listSubagentControlSessionIds(alloc);
    defer freeIds(alloc, &ids);
    try std.testing.expect(containsId(ids.items, "corrupt-chat"));
    var resumed = try env.store.resumeForWrite(alloc, "corrupt-chat");
    resumed.deinit(alloc);
}

test "unrelated canonical cycle is isolated from a healthy root snapshot" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "healthy-root");
    try env.createSession(alloc, "healthy-child");
    try env.createSession(alloc, "cycle-a");
    try env.createSession(alloc, "cycle-b");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "healthy-root",
        "attach-healthy-child",
        .attach,
        "healthy-child",
        "healthy-root",
    );
    var template = try validateCreate(alloc, "cycle fixture");
    defer template.deinit(alloc);
    try writeCanonicalParentForTest(
        alloc,
        &env,
        template.create.configuration,
        "cycle-a",
        "cycle-b",
    );
    try writeCanonicalParentForTest(
        alloc,
        &env,
        template.create.configuration,
        "cycle-b",
        "cycle-a",
    );

    var healthy = try manager.snapshot(alloc, .{ .root_id = "healthy-root" });
    defer healthy.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), healthy.snapshot.nodes.len);
    try std.testing.expectEqualStrings("healthy-child", healthy.snapshot.nodes[0].child_id);
    try std.testing.expectEqual(@as(usize, 0), healthy.snapshot.diagnostics.len);
    try std.testing.expect(!healthy.snapshot.diagnostics_truncated);

    var cyclic = try manager.snapshot(alloc, .{ .root_id = "cycle-a" });
    defer cyclic.deinit(alloc);
    try std.testing.expectEqual(FailureCode.relationship_cycle, cyclic.failure.code);

    var ids = try env.store.listSubagentControlSessionIds(alloc);
    defer freeIds(alloc, &ids);
    try std.testing.expect(containsId(ids.items, "cycle-a"));
    try std.testing.expect(containsId(ids.items, "cycle-b"));
    var resumed_a = try env.store.resumeForWrite(alloc, "cycle-a");
    resumed_a.deinit(alloc);
    var resumed_b = try env.store.resumeForWrite(alloc, "cycle-b");
    resumed_b.deinit(alloc);
}

test "unrelated over-depth component is isolated from a healthy root snapshot" {
    const alloc = std.testing.allocator;

    const test_depth_limit: usize = 8;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "healthy-root");
    try env.createSession(alloc, "healthy-child");
    try env.createSession(alloc, "deep-root");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "healthy-root",
        "attach-healthy-child",
        .attach,
        "healthy-child",
        "healthy-root",
    );
    var template = try validateCreate(alloc, "depth fixture");
    defer template.deinit(alloc);
    var index: usize = 0;
    while (index < test_depth_limit) : (index += 1) {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "deep-{d:0>4}", .{index});
        var parent_buffer: [32]u8 = undefined;
        const parent_id = if (index == 0)
            "deep-root"
        else
            try std.fmt.bufPrint(&parent_buffer, "deep-{d:0>4}", .{index - 1});
        try env.createSession(alloc, child_id);
        try writeCanonicalParentForTest(
            alloc,
            &env,
            template.create.configuration,
            child_id,
            parent_id,
        );
    }

    var healthy = try manager.snapshotWithDepthLimit(
        alloc,
        .{ .root_id = "healthy-root" },
        null,
        test_depth_limit,
    );
    defer healthy.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), healthy.snapshot.nodes.len);
    try std.testing.expectEqualStrings("healthy-child", healthy.snapshot.nodes[0].child_id);
    try std.testing.expectEqual(@as(usize, 0), healthy.snapshot.diagnostics.len);
    try std.testing.expect(!healthy.snapshot.diagnostics_truncated);

    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        var page = try manager.snapshotWithDepthLimit(
            alloc,
            .{
                .root_id = "deep-root",
                .cursor = cursor,
            },
            null,
            test_depth_limit,
        );
        defer page.deinit(alloc);
        if (page == .failure) {
            try std.testing.expectEqual(FailureCode.graph_too_deep, page.failure.code);
            break;
        }
        const next = page.snapshot.next_cursor orelse return error.TestUnexpectedResult;
        if (cursor) |value| alloc.free(value);
        cursor = try alloc.dupe(u8, next);
    }

    var ids = try env.store.listSubagentControlSessionIds(alloc);
    defer freeIds(alloc, &ids);
    try std.testing.expect(containsId(ids.items, "deep-0000"));
    try std.testing.expect(containsId(ids.items, "deep-0007"));
    var resumed = try env.store.resumeForWrite(alloc, "deep-0007");
    resumed.deinit(alloc);
}

test "bounded relationship pages and snapshots free every failing allocation" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-id",
        "attach-child",
        .attach,
        "child-id",
        "root-id",
    );

    var page_succeeded = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var result = relationship_index.page(
            failing.allocator(),
            &env.store,
            "root-id",
            .{},
            null,
            10,
            relationship_index.max_candidate_reads,
        );
        if (result) |*page_value| {
            page_value.deinit(failing.allocator());
            page_succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(page_succeeded);

    var snapshot_succeeded = false;
    for (0..1024) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var result = manager.snapshot(
            failing.allocator(),
            .{ .root_id = "root-id" },
        );
        if (result) |*snapshot| {
            snapshot.deinit(failing.allocator());
            snapshot_succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(snapshot_succeeded);
}

test "relationship recovery and candidate snapshot remain retryable across allocation and commit failures" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "retry-root");
    try env.createSession(alloc, "retry-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "retry-root",
        "retry-attach",
        .attach,
        "retry-child",
        "retry-root",
    );
    try env.indexSession(alloc, "retry-child");
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "retry-root",
        "retry-child",
        .{},
    ));
    var seed_failure = FailSyncFileAt{ .fail_at = 2 };
    try std.testing.expectError(
        error.StoreUnavailable,
        relationship_index.ensureChild(
            alloc,
            &env.store,
            "retry-root",
            "retry-child",
            .{ .replace_ops = .{
                .ctx = &seed_failure,
                .sync_file = FailSyncFileAt.syncFile,
            } },
        ),
    );

    var observed_oom = false;
    var recovered = false;
    for (0..256) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        relationship_index.recoverForQuery(
            failing.allocator(),
            &env.store,
            "retry-root",
            .{},
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            observed_oom = true;
            continue;
        };
        recovered = true;
        break;
    }
    try std.testing.expect(observed_oom);
    try std.testing.expect(recovered);

    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "retry-root",
        "retry-child",
        .{},
    ));
    seed_failure = .{ .fail_at = 2 };
    try std.testing.expectError(
        error.StoreUnavailable,
        relationship_index.ensureChild(
            alloc,
            &env.store,
            "retry-root",
            "retry-child",
            .{ .replace_ops = .{
                .ctx = &seed_failure,
                .sync_file = FailSyncFileAt.syncFile,
            } },
        ),
    );
    var commit_failure = CommitSyncFailure{};
    try std.testing.expectError(
        error.CommitIndeterminate,
        relationship_index.recoverForQuery(
            alloc,
            &env.store,
            "retry-root",
            .{ .replace_ops = .{
                .ctx = &commit_failure,
                .sync_dir = CommitSyncFailure.syncDir,
            } },
        ),
    );
    try relationship_index.recoverForQuery(
        alloc,
        &env.store,
        "retry-root",
        .{},
    );

    var snapshot_succeeded = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var page = env.store.listRelationshipMigrationCandidates(
            failing.allocator(),
            .{},
        );
        if (page) |*value| {
            value.deinit(failing.allocator());
            snapshot_succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(snapshot_succeeded);
}

test "writable migration query repairs malformed candidate input for later read-only use" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "candidate-session");
    try env.indexSession(alloc, "candidate-session");
    var first = try env.store.listRelationshipMigrationCandidates(
        alloc,
        .{},
    );
    first.deinit(alloc);

    var sessions = env.store.canonical_root.sessions orelse
        return error.TestUnexpectedResult;
    try io_mod.durableReplaceVerified(
        alloc,
        &sessions,
        "relationship-migration-index.json",
        "malformed",
    );
    var read_only = try session_store.Store.initReadOnlyFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer read_only.deinit(alloc);
    try std.testing.expectError(
        error.SessionStoreUnavailable,
        read_only.listRelationshipMigrationCandidates(alloc, .{}),
    );

    var repaired = try env.store.listRelationshipMigrationCandidates(
        alloc,
        .{},
    );
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired.ids.items.len);
    try std.testing.expectEqualStrings(
        "candidate-session",
        repaired.ids.items[0],
    );
    var read_only_page = try read_only.listRelationshipMigrationCandidates(
        alloc,
        .{},
    );
    defer read_only_page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), read_only_page.ids.items.len);
}

test "manager configure and lifecycle changes are durable" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = "child-id",
        .name = "renamed",
        .model = "test/other-model",
        .effort = types.ReasoningEffort.literal("low"),
        .permission_mode = .ask,
    } });
    defer configure.deinit(alloc);
    var configured = try manager.execute(alloc, configure, .{
        .actor_id = "parent-id",
        .operation_id = "configure",
        .timestamp_ms = 2,
    });
    defer configured.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.configured, configured.receipt.code);

    var close = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "child-id",
        .action = .close,
    } });
    defer close.deinit(alloc);
    var closed = try manager.execute(alloc, close, .{
        .actor_id = "parent-id",
        .operation_id = "close",
        .timestamp_ms = 3,
    });
    defer closed.deinit(alloc);

    var reopen = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "child-id",
        .action = .reopen,
    } });
    defer reopen.deinit(alloc);
    var reopened = try manager.execute(alloc, reopen, .{
        .actor_id = "parent-id",
        .operation_id = "reopen",
        .timestamp_ms = 4,
    });
    defer reopened.deinit(alloc);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{ .status, .configuration },
    } });
    defer inspect.deinit(alloc);
    var result = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 5,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(domain.State.idle, result.inspection.status.?);
    try std.testing.expectEqualStrings("renamed", result.inspection.configuration.?.name);
    try std.testing.expectEqualStrings(
        "test/other-model",
        result.inspection.configuration.?.model.?,
    );
    try std.testing.expectEqual(
        types.PermissionMode.ask,
        result.inspection.configuration.?.permission_mode,
    );
}

test "manager operations are idempotent and conflicting operation reuse fails" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "other-parent");
    try env.createSession(alloc, "child-id");
    try env.createSession(alloc, "attach-child");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);

    var first = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "same-op",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer first.deinit(alloc);
    var replay = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "same-op",
        .created_child_id = "child-id",
        .expected_generation = 0,
        .timestamp_ms = 2,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(first.receipt.generation, replay.receipt.generation);

    var actor_conflict = try manager.execute(alloc, create, .{
        .actor_id = "other-parent",
        .operation_id = "same-op",
        .created_child_id = "child-id",
        .timestamp_ms = 2,
    });
    defer actor_conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, actor_conflict.failure.code);

    var send = try validateSend(alloc, "child-id", "different");
    defer send.deinit(alloc);
    var conflict = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "same-op",
        .timestamp_ms = 3,
    });
    defer conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, conflict.failure.code);

    var stale = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "new-operation",
        .expected_generation = 0,
        .timestamp_ms = 4,
    });
    defer stale.deinit(alloc);
    try std.testing.expectEqual(FailureCode.stale_generation, stale.failure.code);

    var source_send = try validateSend(alloc, "child-id", "same content");
    defer source_send.deinit(alloc);
    var source_first = try manager.execute(alloc, source_send, .{
        .actor_id = "parent-id",
        .operation_id = "source-operation",
        .timestamp_ms = 5,
    });
    defer source_first.deinit(alloc);
    var source_conflict = try manager.execute(alloc, source_send, .{
        .actor_id = "other-parent",
        .operation_id = "source-operation",
        .timestamp_ms = 6,
    });
    defer source_conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, source_conflict.failure.code);

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "attach-child",
    } });
    defer attach.deinit(alloc);
    var attached = try manager.execute(alloc, attach, .{
        .actor_id = "parent-id",
        .operation_id = "effective-parent-operation",
        .relationship_authorization = .direct,
        .timestamp_ms = 7,
    });
    defer attached.deinit(alloc);
    var parent_conflict = try manager.execute(alloc, attach, .{
        .actor_id = "other-parent",
        .operation_id = "effective-parent-operation",
        .relationship_authorization = .direct,
        .timestamp_ms = 8,
    });
    defer parent_conflict.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, parent_conflict.failure.code);
}

test "bounded replay identity classifies retained expired and new without effects" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var capture = PublishCapture{};
    var manager = Manager{
        .sessions = &env.store,
        .options = .{ .publisher = .{
            .context = &capture,
            .publish_fn = PublishCapture.publish,
        } },
    };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    const create_id = try tool_result.boundOperationIdAlloc(alloc, "create-call", .model, 4);
    defer alloc.free(create_id);
    const create_context: Context = .{
        .actor_id = "parent-id",
        .operation_id = create_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 4,
        .operation_identity_admitted = true,
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    };
    var first = try manager.execute(alloc, create, create_context);
    defer first.deinit(alloc);
    var replay = try manager.execute(alloc, create, create_context);
    defer replay.deinit(alloc);
    try std.testing.expectEqual(first.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var record = try store.load(alloc);
    const older_id = try tool_result.boundOperationIdAlloc(alloc, "late-old-call", .model, 3);
    defer alloc.free(older_id);
    switch (try existingOperation(
        alloc,
        record,
        older_id,
        [_]u8{0} ** 32,
        null,
        .{ .bound = .{
            .identity = tool_result.parseBoundOperationId(older_id).?,
            .admitted = true,
        } },
    )) {
        .absent => {},
        else => return error.TestExpectedEqual,
    }
    switch (try existingOperation(
        alloc,
        null,
        older_id,
        [_]u8{0} ** 32,
        null,
        .{ .bound = .{
            .identity = tool_result.parseBoundOperationId(older_id).?,
            .admitted = false,
        } },
    )) {
        .expired => {},
        else => return error.TestExpectedEqual,
    }
    for (record.operations) |*operation| operation.deinit(alloc);
    alloc.free(record.operations);
    record.operations = try alloc.alloc(domain.OperationReceipt, 0);
    for (record.events) |*event| event.deinit(alloc);
    alloc.free(record.events);
    record.events = try alloc.alloc(domain.Event, 0);
    record.events_evicted_through = record.next_event_sequence - 1;
    record.notification_cursor = record.events_evicted_through;
    record.model_replay_floor = 5;
    try store.save(alloc, record);
    record.deinit(alloc);

    capture.calls = 0;
    var expired_context = create_context;
    expired_context.operation_identity_admitted = false;
    var expired = try manager.execute(alloc, create, expired_context);
    defer expired.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_replay_expired, expired.failure.code);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    var observed = try store.load(alloc);
    defer observed.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), observed.generation);
    try std.testing.expectEqual(@as(usize, 0), observed.operations.len);

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = "child-id",
        .name = "new generation",
    } });
    defer configure.deinit(alloc);
    const configure_id = try tool_result.boundOperationIdAlloc(alloc, "configure-call", .model, 5);
    defer alloc.free(configure_id);
    var accepted = try manager.execute(alloc, configure, .{
        .actor_id = "parent-id",
        .operation_id = configure_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 5,
        .operation_identity_admitted = true,
        .timestamp_ms = 2,
    });
    defer accepted.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.configured, accepted.receipt.code);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "canonical byte compaction preserves active work and continued control operations" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "byte-horizon-child");
    defer create.deinit(alloc);
    const create_id = try tool_result.boundOperationIdAlloc(alloc, "byte-create", .model, 0);
    defer alloc.free(create_id);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = create_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 0,
        .operation_identity_admitted = true,
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    const content = try alloc.alloc(u8, domain.max_message_bytes);
    defer alloc.free(content);
    @memset(content, 'x');

    for (1..10) |epoch| {
        var invocation_buffer: [64]u8 = undefined;
        const invocation = try std.fmt.bufPrint(&invocation_buffer, "byte-send-{d}", .{epoch});
        const operation_id = try tool_result.boundOperationIdAlloc(alloc, invocation, .model, epoch);
        defer alloc.free(operation_id);
        var send = try validateSend(alloc, "child-id", content);
        defer send.deinit(alloc);
        var queued = try manager.execute(alloc, send, .{
            .actor_id = "parent-id",
            .operation_id = operation_id,
            .operation_identity_source = .model,
            .operation_identity_epoch = epoch,
            .operation_identity_admitted = true,
            .timestamp_ms = @intCast(epoch * 3),
        });
        defer queued.deinit(alloc);
        try std.testing.expect(queued == .receipt);

        var lock = try store.acquireLock();
        var record = try store.load(alloc);
        const index = record.queue.len - 1;
        try std.testing.expectEqual(domain.QueueStatus.pending, record.queue[index].status);
        record.queue[index].status = .running;
        record.state = .running;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[index].id,
            .previous = .pending,
            .current = .running,
        }}, @intCast(epoch * 3 + 1));
        record.queue[index].status = .completed;
        record.state = .idle;
        try appendWorkRevision(alloc, &record, &.{.{
            .work_item_id = record.queue[index].id,
            .previous = .running,
            .current = .completed,
        }}, @intCast(epoch * 3 + 2));
        try store.save(alloc, record);
        record.deinit(alloc);
        lock.release();
    }

    var compacted = try store.load(alloc);
    defer compacted.deinit(alloc);
    try std.testing.expect(compacted.queue_evicted);

    var final_send = try validateSend(alloc, "child-id", content);
    defer final_send.deinit(alloc);
    const final_id = try tool_result.boundOperationIdAlloc(alloc, "active-send", .model, 10);
    defer alloc.free(final_id);
    var active = try manager.execute(alloc, final_send, .{
        .actor_id = "parent-id",
        .operation_id = final_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 10,
        .operation_identity_admitted = true,
        .timestamp_ms = 200,
    });
    defer active.deinit(alloc);
    try std.testing.expect(active == .receipt);
    var active_record = try store.load(alloc);
    defer active_record.deinit(alloc);
    try std.testing.expect(active_record.queue.len != 0);
    const retained_active = active_record.queue[active_record.queue.len - 1];
    try std.testing.expectEqual(domain.QueueStatus.pending, retained_active.status);
    try std.testing.expectEqualStrings(content, retained_active.content);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{ .messages, .events },
    } });
    defer inspect.deinit(alloc);
    var inspected = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 201,
    });
    defer inspected.deinit(alloc);
    try std.testing.expect(inspected.inspection.restart_required);

    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "child-id",
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    const cancel_id = try tool_result.boundOperationIdAlloc(alloc, "byte-cancel", .model, 11);
    defer alloc.free(cancel_id);
    const cancel_context: Context = .{
        .actor_id = "parent-id",
        .operation_id = cancel_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 11,
        .operation_identity_admitted = true,
        .timestamp_ms = 203,
    };
    var cancelled = try manager.execute(alloc, cancel, cancel_context);
    defer cancelled.deinit(alloc);
    try std.testing.expect(cancelled == .receipt);
    var replay = try manager.execute(alloc, cancel, cancel_context);
    defer replay.deinit(alloc);
    try std.testing.expectEqual(cancelled.receipt.generation, replay.receipt.generation);
    var reloaded = try store.load(alloc);
    defer reloaded.deinit(alloc);
    try std.testing.expectEqual(domain.State.idle, reloaded.state);
}

test "committed relationship replay precedes later graph preconditions" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");
    try env.createSession(alloc, "other-parent");
    var manager = Manager{ .sessions = &env.store };

    var original_command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-a",
        .parent_id = "child-b",
    } });
    defer original_command.deinit(alloc);
    var original = try manager.execute(alloc, original_command, .{
        .actor_id = "root-actor",
        .operation_id = "original-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 1,
    });
    defer original.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, original.receipt.code);

    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-actor",
        "detach-child-a",
        .detach,
        "child-a",
        null,
    );
    try executeRelationshipForTest(
        alloc,
        &manager,
        "root-actor",
        "attach-child-b-to-a",
        .attach,
        "child-b",
        "child-a",
    );
    try std.testing.expect(try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "child-b",
        "child-a",
        .{},
    ) == null);
    try std.testing.expect(try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "child-a",
        "child-b",
        .{},
    ) != null);

    var replay = try manager.execute(alloc, original_command, .{
        .actor_id = "root-actor",
        .operation_id = "original-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 9,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, replay.receipt.code);
    try std.testing.expectEqual(original.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqual(original.receipt.event_sequence, replay.receipt.event_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &original.receipt.request_fingerprint,
        &replay.receipt.request_fingerprint,
    );
    try std.testing.expectEqualSlices(
        u8,
        &original.receipt.fingerprint,
        &replay.receipt.fingerprint,
    );
    try std.testing.expect(try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "child-b",
        "child-a",
        .{},
    ) == null);
    try std.testing.expect(try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "child-a",
        "child-b",
        .{},
    ) != null);
    var resumable = try env.store.listResumablePage(alloc, null, null);
    defer resumable.deinit(alloc);
    try std.testing.expect(resumablePageContains(resumable, "child-a"));
    try std.testing.expect(!resumablePageContains(resumable, "child-b"));

    var changed_actor = try manager.execute(alloc, original_command, .{
        .actor_id = "different-actor",
        .operation_id = "original-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 10,
    });
    defer changed_actor.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, changed_actor.failure.code);

    var changed_parent_command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-a",
        .parent_id = "other-parent",
    } });
    defer changed_parent_command.deinit(alloc);
    var changed_parent = try manager.execute(alloc, changed_parent_command, .{
        .actor_id = "root-actor",
        .operation_id = "original-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 11,
    });
    defer changed_parent.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, changed_parent.failure.code);

    var changed_command_value = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "child-a",
        .parent_id = "child-b",
    } });
    defer changed_command_value.deinit(alloc);
    var changed_command = try manager.execute(alloc, changed_command_value, .{
        .actor_id = "root-actor",
        .operation_id = "original-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 12,
    });
    defer changed_command.deinit(alloc);
    try std.testing.expectEqual(FailureCode.operation_conflict, changed_command.failure.code);
}

test "prepublished relationship rollback invalidates the resume projection" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "rollback-parent");
    try env.createSession(alloc, "rollback-child");
    var manager = Manager{ .sessions = &env.store };

    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        "rollback-parent",
        "rollback-child",
        .{},
    );
    try env.store.invalidateResumableIndex(alloc);
    var prepublished = try env.store.listResumablePage(alloc, null, null);
    defer prepublished.deinit(alloc);
    try std.testing.expect(resumablePageContains(prepublished, "rollback-parent"));

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "rollback-child",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "rollback-child",
    };
    try std.testing.expect(try manager.rollbackPrepublishedRelationshipIfUncommitted(
        alloc,
        store,
        "rollback-parent",
        "rollback-child",
    ) == null);

    var repaired = try env.store.listResumablePage(alloc, null, null);
    defer repaired.deinit(alloc);
    try std.testing.expect(!resumablePageContains(repaired, "rollback-parent"));
}

test "committed attach replay ignores later bootstrap preference changes" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-id",
        .parent_id = "parent-id",
    } });
    defer command.deinit(alloc);
    var original = try manager.execute(alloc, command, .{
        .actor_id = "parent-id",
        .operation_id = "stable-bootstrap-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 1,
    });
    defer original.deinit(alloc);

    var child_session = try env.store.resumeForWrite(alloc, "child-id");
    _ = try child_session.appendEvent(
        alloc,
        .{ .preferences_changed = .{
            .model = @constCast("changed/model"),
            .effort = types.ReasoningEffort.literal("low"),
        } },
        2,
        .retry_expected_tail,
        .{},
    );
    child_session.deinit(alloc);

    var replay = try manager.execute(alloc, command, .{
        .actor_id = "parent-id",
        .operation_id = "stable-bootstrap-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 3,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, replay.receipt.code);
    try std.testing.expectEqual(original.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqualSlices(
        u8,
        &original.receipt.fingerprint,
        &replay.receipt.fingerprint,
    );
}

test "persistent cancel preserves queued messages as cancelled and one-off rejects send" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "persistent-id");
    try env.createSession(alloc, "one-off-id");
    var manager = Manager{ .sessions = &env.store };

    var persistent_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "persistent",
        .mode = .persistent,
        .prompt = "queued work",
    } });
    defer persistent_create.deinit(alloc);
    var persistent_created = try manager.execute(alloc, persistent_create, .{
        .actor_id = "parent-id",
        .operation_id = "persistent-create",
        .created_child_id = "persistent-id",
        .timestamp_ms = 1,
    });
    defer persistent_created.deinit(alloc);
    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "persistent-id",
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    var cancelled = try manager.execute(alloc, cancel, .{
        .actor_id = "parent-id",
        .operation_id = "cancel",
        .timestamp_ms = 2,
    });
    defer cancelled.deinit(alloc);
    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "persistent-id",
        .sections = &.{ .status, .messages },
    } });
    defer inspect.deinit(alloc);
    var inspected = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 3,
    });
    defer inspected.deinit(alloc);
    try std.testing.expectEqual(domain.State.idle, inspected.inspection.status.?);
    try std.testing.expectEqual(domain.QueueStatus.cancelled, inspected.inspection.messages[0].status);
    try std.testing.expect(inspected.inspection.messages[0].cancellation_reason != null);

    var one_off_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "one off",
        .mode = .one_off,
        .prompt = "single task",
    } });
    defer one_off_create.deinit(alloc);
    var one_off_created = try manager.execute(alloc, one_off_create, .{
        .actor_id = "parent-id",
        .operation_id = "one-off-create",
        .created_child_id = "one-off-id",
        .timestamp_ms = 4,
    });
    defer one_off_created.deinit(alloc);
    var send = try validateSend(alloc, "one-off-id", "not allowed");
    defer send.deinit(alloc);
    var rejected = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "one-off-send",
        .timestamp_ms = 5,
    });
    defer rejected.deinit(alloc);
    try std.testing.expectEqual(FailureCode.one_off_not_messageable, rejected.failure.code);
}

test "manager pagination returns restart on stale cursor" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    const stale_cursor = try domain.encodeCursor(alloc, .{ .generation = 0, .offset = 0 });
    defer alloc.free(stale_cursor);
    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{.events},
        .cursor = stale_cursor,
        .limit = 1,
    } });
    defer inspect.deinit(alloc);
    var result = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result.inspection.restart_required);
}

test "resume projection follows current occupied relationships after detach and reparent" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    inline for (.{ "root-a", "root-b", "child-a", "child-b" }) |id| {
        try env.createSession(alloc, id);
    }
    var manager = Manager{ .sessions = &env.store };

    var create_a = try validateCreate(alloc, "child-a");
    defer create_a.deinit(alloc);
    var created_a = try manager.execute(alloc, create_a, .{
        .actor_id = "root-a",
        .operation_id = "resume-create-a",
        .created_child_id = "child-a",
        .timestamp_ms = 1,
    });
    defer created_a.deinit(alloc);
    try std.testing.expect(created_a == .receipt);

    var create_b = try validateCreate(alloc, "child-b");
    defer create_b.deinit(alloc);
    var created_b = try manager.execute(alloc, create_b, .{
        .actor_id = "root-a",
        .operation_id = "resume-create-b",
        .created_child_id = "child-b",
        .timestamp_ms = 2,
    });
    defer created_b.deinit(alloc);
    try std.testing.expect(created_b == .receipt);

    var both = try env.store.listResumablePage(alloc, null, null);
    defer both.deinit(alloc);
    try std.testing.expect(resumablePageContains(both, "root-a"));
    try std.testing.expect(!resumablePageContains(both, "root-b"));

    var detach_a = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "child-a",
    } });
    defer detach_a.deinit(alloc);
    var detached_a = try manager.execute(alloc, detach_a, .{
        .actor_id = "root-a",
        .operation_id = "resume-detach-a",
        .timestamp_ms = 3,
    });
    defer detached_a.deinit(alloc);
    try std.testing.expect(detached_a == .receipt);
    var one = try env.store.listResumablePage(alloc, null, null);
    defer one.deinit(alloc);
    try std.testing.expect(resumablePageContains(one, "root-a"));

    var reparent_b = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "child-b",
        .parent_id = "root-b",
    } });
    defer reparent_b.deinit(alloc);
    var reparented_b = try manager.execute(alloc, reparent_b, .{
        .actor_id = "root-a",
        .operation_id = "resume-reparent-b",
        .relationship_authorization = .direct,
        .timestamp_ms = 4,
    });
    defer reparented_b.deinit(alloc);
    try std.testing.expect(reparented_b == .receipt);

    var moved = try env.store.listResumablePage(alloc, null, null);
    defer moved.deinit(alloc);
    try std.testing.expect(!resumablePageContains(moved, "root-a"));
    try std.testing.expect(resumablePageContains(moved, "root-b"));

    var read_only = try session_store.Store.initReadOnlyFromHome(
        alloc,
        env.home,
        env.workspace,
    );
    defer read_only.deinit(alloc);
    var restarted = try read_only.listResumablePage(alloc, null, null);
    defer restarted.deinit(alloc);
    try std.testing.expect(!resumablePageContains(restarted, "root-a"));
    try std.testing.expect(resumablePageContains(restarted, "root-b"));
}

test "exact relationship replay repairs a failed resume-index marker" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "marker-parent");
    try env.createSession(alloc, "marker-parent-b");
    try env.createSession(alloc, "marker-child");
    var initial = try env.store.listResumablePage(alloc, null, null);
    initial.deinit(alloc);

    var sessions = &(env.store.canonical_root.sessions orelse
        return error.TestExpectedEqual);
    try sessions.dir.createDir(
        io_mod.getIo(),
        "index.pending",
        io_mod.permissionsFromMode(0o700),
    );
    var blocker_present = true;
    defer if (blocker_present) {
        sessions.dir.deleteTree(io_mod.getIo(), "index.pending") catch {};
    };

    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "marker-child");
    defer create.deinit(alloc);
    const context: Context = .{
        .actor_id = "marker-parent",
        .operation_id = "marker-create",
        .created_child_id = "marker-child",
        .timestamp_ms = 1,
    };
    var failed = try manager.execute(alloc, create, context);
    defer failed.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_commit_indeterminate,
        failed.failure.code,
    );

    var committed = try env.loadControl(alloc, "marker-child");
    defer committed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), committed.operations.len);
    try std.testing.expectEqualStrings("marker-parent", committed.parent_id.?);

    try sessions.dir.deleteTree(io_mod.getIo(), "index.pending");
    blocker_present = false;
    var replayed = try manager.execute(alloc, create, context);
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.created, replayed.receipt.code);
    try std.testing.expectEqualStrings("marker-create", replayed.receipt.id);

    var repaired = try env.store.listResumablePage(alloc, null, null);
    defer repaired.deinit(alloc);
    try std.testing.expect(resumablePageContains(repaired, "marker-parent"));
    var observed = try env.loadControl(alloc, "marker-child");
    defer observed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), observed.operations.len);

    try sessions.dir.createDir(
        io_mod.getIo(),
        "index.pending",
        io_mod.permissionsFromMode(0o700),
    );
    blocker_present = true;
    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "marker-child",
    } });
    defer detach.deinit(alloc);
    const detach_context: Context = .{
        .actor_id = "marker-parent",
        .operation_id = "marker-detach",
        .timestamp_ms = 2,
    };
    var detach_failed = try manager.execute(alloc, detach, detach_context);
    defer detach_failed.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_commit_indeterminate,
        detach_failed.failure.code,
    );
    try sessions.dir.deleteTree(io_mod.getIo(), "index.pending");
    blocker_present = false;
    var detach_replayed = try manager.execute(alloc, detach, detach_context);
    defer detach_replayed.deinit(alloc);
    try std.testing.expectEqual(
        domain.OutcomeCode.relationship_changed,
        detach_replayed.receipt.code,
    );
    var after_detach = try env.store.listResumablePage(alloc, null, null);
    defer after_detach.deinit(alloc);
    try std.testing.expect(!resumablePageContains(after_detach, "marker-parent"));

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "marker-child",
        .parent_id = "marker-parent-b",
    } });
    defer attach.deinit(alloc);
    var attached = try manager.execute(alloc, attach, .{
        .actor_id = "marker-parent-b",
        .operation_id = "marker-attach",
        .relationship_authorization = .direct,
        .timestamp_ms = 3,
    });
    defer attached.deinit(alloc);
    try std.testing.expect(attached == .receipt);
    var after_attach = try env.store.listResumablePage(alloc, null, null);
    after_attach.deinit(alloc);

    try sessions.dir.createDir(
        io_mod.getIo(),
        "index.pending",
        io_mod.permissionsFromMode(0o700),
    );
    blocker_present = true;
    var reparent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "marker-child",
        .parent_id = "marker-parent",
    } });
    defer reparent.deinit(alloc);
    const reparent_context: Context = .{
        .actor_id = "marker-parent-b",
        .operation_id = "marker-reparent",
        .relationship_authorization = .direct,
        .timestamp_ms = 4,
    };
    var reparent_failed = try manager.execute(alloc, reparent, reparent_context);
    defer reparent_failed.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_commit_indeterminate,
        reparent_failed.failure.code,
    );
    try sessions.dir.deleteTree(io_mod.getIo(), "index.pending");
    blocker_present = false;
    var reparent_replayed = try manager.execute(alloc, reparent, reparent_context);
    defer reparent_replayed.deinit(alloc);
    try std.testing.expectEqual(
        domain.OutcomeCode.relationship_changed,
        reparent_replayed.receipt.code,
    );
    var after_reparent = try env.store.listResumablePage(alloc, null, null);
    defer after_reparent.deinit(alloc);
    try std.testing.expect(resumablePageContains(after_reparent, "marker-parent"));
    try std.testing.expect(!resumablePageContains(after_reparent, "marker-parent-b"));
    var final_record = try env.loadControl(alloc, "marker-child");
    defer final_record.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), final_record.operations.len);
}

noinline fn resumablePageContains(
    page: session_store.ResumableSessionPage,
    session_id: []const u8,
) bool {
    for (page.summaries.items) |summary| {
        if (std.mem.eql(u8, summary.id, session_id)) return true;
    }
    return false;
}

test "control queue admission remains available while another process owns session lock" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    const session_lock_path = try std.fs.path.join(
        alloc,
        &.{ env.store.sessions_dir, "child-id", "session.lock" },
    );
    defer alloc.free(session_lock_path);
    const locker_script =
        \\import fcntl, os, sys
        \\lock_file = open(sys.argv[1], "a+b")
        \\fcntl.flock(lock_file, fcntl.LOCK_EX)
        \\os.write(1, b"R")
        \\os.read(0, 1)
    ;
    const argv = [_][]const u8{
        "/usr/bin/env",
        "python3",
        "-c",
        locker_script,
        session_lock_path,
    };
    var locker = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var locker_reaped = false;
    defer if (!locker_reaped) {
        if (locker.stdin) |stdin_file| stdin_file.writeStreamingAll(
            io_mod.getIo(),
            "X",
        ) catch {};
        _ = locker.wait(io_mod.getIo()) catch {};
    };
    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try std.posix.read(locker.stdout.?.handle, &ready),
    );
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);
    const child_session_path = try std.fs.path.join(
        alloc,
        &.{ env.store.sessions_dir, "child-id" },
    );
    defer alloc.free(child_session_path);
    const child_session_dir = try std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        child_session_path,
        .{ .iterate = true },
    );
    var verified_child_dir = io_mod.VerifiedDir{ .dir = child_session_dir };
    defer verified_child_dir.close();
    try std.testing.expectError(
        error.LockBusy,
        io_mod.acquireTimedAdvisoryLock(&verified_child_dir, "session.lock", 0),
    );

    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var send = try validateSend(alloc, "child-id", "queued under transcript owner");
    defer send.deinit(alloc);
    var result = try manager.execute(alloc, send, .{
        .actor_id = "parent-id",
        .operation_id = "send",
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, result.receipt.code);
    try locker.stdin.?.writeStreamingAll(io_mod.getIo(), "X");
    const term = try locker.wait(io_mod.getIo());
    locker_reaped = true;
    try std.testing.expect(term == .exited and term.exited == 0);
}

const LockFailureClock = struct { now_ms: i64 = 0 };

fn alwaysBusy(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return false;
}

fn unsupportedLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

fn lockNow(raw: ?*anyopaque) i64 {
    const clock: *LockFailureClock = @ptrCast(@alignCast(raw.?));
    return clock.now_ms;
}

fn lockSleep(raw: ?*anyopaque, millis: u64) void {
    const clock: *LockFailureClock = @ptrCast(@alignCast(raw.?));
    clock.now_ms += @intCast(millis);
}

const CommitSyncFailure = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *CommitSyncFailure = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

const FailAtSync = struct {
    calls: usize = 0,
    fail_at: usize,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailAtSync = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedSyncFailure;
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

const PublishCapture = struct {
    calls: usize = 0,
    generation: u64 = 0,

    fn publish(raw: ?*anyopaque, record: control_store.Record) void {
        const self: *PublishCapture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.generation = record.generation;
    }
};

test "indeterminate control replacement is reconciled before publication" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var sync_failure = CommitSyncFailure{};
    var capture = PublishCapture{};
    var manager = Manager{
        .sessions = &env.store,
        .options = .{
            .child_store = .{ .replace_ops = .{
                .ctx = &sync_failure,
                .sync_dir = CommitSyncFailure.syncDir,
            } },
            .publisher = .{
                .context = &capture,
                .publish_fn = PublishCapture.publish,
            },
        },
    };
    var command = try validateCreate(alloc, "child");
    defer command.deinit(alloc);
    var result = try manager.execute(alloc, command, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.created, result.receipt.code);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(result.receipt.generation, capture.generation);
    try std.testing.expect(sync_failure.calls >= 2);
}

test "indeterminate relationship projection never exposes a half committed edge" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-id");
    var sync_failure = FailAtSync{ .fail_at = 2 };
    var failing_manager = Manager{
        .sessions = &env.store,
        .options = .{ .child_store = .{ .replace_ops = .{
            .ctx = &sync_failure,
            .sync_dir = FailAtSync.syncDir,
        } } },
    };
    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-id",
        .parent_id = "root-id",
    } });
    defer attach.deinit(alloc);
    var result = try failing_manager.execute(alloc, attach, .{
        .actor_id = "root-id",
        .operation_id = "half-edge",
        .relationship_authorization = .direct,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_commit_indeterminate,
        result.failure.code,
    );

    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        "root-id",
        "child-id",
        .{},
    );
    var manager = Manager{ .sessions = &env.store };
    var snapshot = try manager.snapshot(alloc, .{ .root_id = "root-id" });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), snapshot.snapshot.nodes.len);
}

test "failed canonical rollback observation retains the prepublished relationship" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-id");
    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        "root-id",
        "child-id",
        .{},
    );

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "child-id",
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = "child-id",
    };
    var replaced = try capability.atomicReplace(
        alloc,
        .subagent_control,
        "control.json",
        "{\"schema_version\":1",
    );
    replaced.deinit(alloc);

    var manager = Manager{ .sessions = &env.store };
    var rollback = (try manager.rollbackPrepublishedRelationshipIfUncommitted(
        alloc,
        store,
        "root-id",
        "child-id",
    )).?;
    defer rollback.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_commit_indeterminate,
        rollback.failure.code,
    );

    var page = try relationship_index.page(
        alloc,
        &env.store,
        "root-id",
        .{},
        null,
        1,
        1,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.candidates.len);
    try std.testing.expectEqualStrings("child-id", page.candidates[0].child_id);
}

test "manager fails closed when the control lock is busy or unsupported" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var command = try validateCreate(alloc, "child");
    defer command.deinit(alloc);
    var clock = LockFailureClock{};
    var busy_manager = Manager{
        .sessions = &env.store,
        .options = .{ .child_store = .{ .lock_ops = .{
            .ctx = &clock,
            .try_lock = alwaysBusy,
            .now_ms = lockNow,
            .sleep_ms = lockSleep,
        } } },
    };
    var busy = try busy_manager.execute(alloc, command, .{
        .actor_id = "parent-id",
        .operation_id = "busy",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer busy.deinit(alloc);
    try std.testing.expectEqual(FailureCode.control_lock_busy, busy.failure.code);

    var unsupported_manager = Manager{
        .sessions = &env.store,
        .options = .{ .child_store = .{ .lock_ops = .{ .try_lock = unsupportedLock } } },
    };
    var unsupported = try unsupported_manager.execute(alloc, command, .{
        .actor_id = "parent-id",
        .operation_id = "unsupported",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer unsupported.deinit(alloc);
    try std.testing.expectEqual(
        FailureCode.control_lock_unsupported,
        unsupported.failure.code,
    );
}

test "ordered relationship locks reject cycles after reload" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");
    var manager = Manager{ .sessions = &env.store };

    var attach_a = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-a",
        .parent_id = "child-b",
    } });
    defer attach_a.deinit(alloc);
    var first = try manager.execute(alloc, attach_a, .{
        .actor_id = "root-id",
        .operation_id = "attach-a",
        .relationship_authorization = .direct,
        .timestamp_ms = 1,
    });
    defer first.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, first.receipt.code);

    var attach_b = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-b",
        .parent_id = "child-a",
    } });
    defer attach_b.deinit(alloc);
    var cycle = try manager.execute(alloc, attach_b, .{
        .actor_id = "root-id",
        .operation_id = "attach-b",
        .relationship_authorization = .direct,
        .timestamp_ms = 2,
    });
    defer cycle.deinit(alloc);
    try std.testing.expectEqual(FailureCode.relationship_cycle, cycle.failure.code);
}

test "pure ancestry validation accepts trees and rejects cycles and stale read sets" {
    const edges = [_]ParentEdge{
        .{ .child_id = "child-a", .parent_id = @constCast("child-b") },
        .{ .child_id = "child-b", .parent_id = null },
        .{ .child_id = "new-child", .parent_id = null },
    };
    try std.testing.expect(validateAncestry(&edges, "new-child", "child-a") == null);
    try std.testing.expectEqual(
        FailureCode.relationship_cycle,
        validateAncestry(&edges, "child-b", "child-a").?,
    );
    try std.testing.expectEqual(
        FailureCode.graph_changed,
        validateAncestry(&edges, "new-child", "missing-parent").?,
    );
}

test "relationship reparent and detach update the canonical child edge" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "parent-a");
    try env.createSession(alloc, "parent-b");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };

    const cases = [_]struct {
        action: domain.RelationshipAction,
        parent_id: ?[]const u8,
        operation_id: []const u8,
    }{
        .{ .action = .attach, .parent_id = "parent-a", .operation_id = "attach" },
        .{ .action = .reparent, .parent_id = "parent-b", .operation_id = "reparent" },
        .{ .action = .detach, .parent_id = null, .operation_id = "detach" },
    };
    for (cases) |case| {
        var command = try domain.validateCommand(alloc, .{ .relationship = .{
            .action = case.action,
            .id = "child-id",
            .parent_id = case.parent_id,
        } });
        defer command.deinit(alloc);
        var result = try manager.execute(alloc, command, .{
            .actor_id = "root-id",
            .operation_id = case.operation_id,
            .relationship_authorization = if (case.action == .detach) .none else .direct,
            .timestamp_ms = 1,
        });
        defer result.deinit(alloc);
        try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, result.receipt.code);
    }

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{.relationship},
    } });
    defer inspect.deinit(alloc);
    var result = try manager.execute(alloc, inspect, .{
        .actor_id = "root-id",
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result.inspection.relationship_selected);
    try std.testing.expect(result.inspection.parent_id == null);
}

test "pure reducer cleans up every failing allocation path" {
    const alloc = std.testing.allocator;
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var current = try buildCreateRecord(
        alloc,
        create.create,
        .{ .actor_id = "parent-id", .timestamp_ms = 1 },
        "child-id",
        "create",
    );
    defer current.deinit(alloc);
    var send = try validateSend(alloc, "child-id", "queued work");
    defer send.deinit(alloc);

    var succeeded = false;
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = index });
        const failing_alloc = failing.allocator();
        const result = reduce(
            failing_alloc,
            current,
            send,
            .{
                .actor_id = "parent-id",
                .operation_id = "send",
                .timestamp_ms = 2,
            },
            "child-id",
            null,
        );
        if (result) |value| {
            var decision = value;
            decision.deinit(failing_alloc);
            succeeded = true;
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(succeeded);
}

test "relationship reducer owns parent replacement across every allocation failure" {
    const alloc = std.testing.allocator;
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var current = try buildCreateRecord(
        alloc,
        create.create,
        .{ .actor_id = "parent-id", .timestamp_ms = 1 },
        "child-id",
        "create",
    );
    defer current.deinit(alloc);
    var relationship = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "child-id",
        .parent_id = "next-parent-id",
    } });
    defer relationship.deinit(alloc);

    var succeeded = false;
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = index },
        );
        const failing_alloc = failing.allocator();
        const result = reduce(
            failing_alloc,
            current,
            relationship,
            .{
                .actor_id = "parent-id",
                .operation_id = "reparent",
                .relationship_authorization = .direct,
                .timestamp_ms = 2,
            },
            "child-id",
            null,
        );
        if (result) |value| {
            var decision = value;
            decision.deinit(failing_alloc);
            succeeded = true;
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(succeeded);
}

test "concurrent control mutations preserve every queued message" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    const Worker = struct {
        home: []const u8,
        workspace: []const u8,
        operation_id: []const u8,
        content: []const u8,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            const thread_alloc = std.heap.c_allocator;
            var store = session_store.Store.initFromHome(
                thread_alloc,
                self.home,
                self.workspace,
            ) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer store.deinit(thread_alloc);
            var command = validateSend(
                thread_alloc,
                "child-id",
                self.content,
            ) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer command.deinit(thread_alloc);
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            var thread_manager = Manager{ .sessions = &store };
            var result = thread_manager.execute(thread_alloc, command, .{
                .actor_id = "parent-id",
                .operation_id = self.operation_id,
                .timestamp_ms = 2,
            }) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer result.deinit(thread_alloc);
            if (result != .receipt or result.receipt.code != .message_queued) {
                self.failed.store(true, .seq_cst);
            }
        }
    };

    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    const workers = [_]Worker{
        .{
            .home = env.home,
            .workspace = env.workspace,
            .operation_id = "send-a",
            .content = "message a",
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        },
        .{
            .home = env.home,
            .workspace = env.workspace,
            .operation_id = "send-b",
            .content = "message b",
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        },
    };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, workers) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    while (ready.load(.seq_cst) != workers.len) std.atomic.spinLoopHint();
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.seq_cst));

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{.messages},
    } });
    defer inspect.deinit(alloc);
    var result = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 3,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), result.inspection.messages.len);
    var found_a = false;
    var found_b = false;
    for (result.inspection.messages) |message| {
        found_a = found_a or std.mem.eql(u8, message.content, "message a");
        found_b = found_b or std.mem.eql(u8, message.content, "message b");
    }
    try std.testing.expect(found_a and found_b);
}

test "concurrent inverse attaches cannot commit a relationship cycle" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");

    const Worker = struct {
        home: []const u8,
        workspace: []const u8,
        child_id: []const u8,
        parent_id: []const u8,
        operation_id: []const u8,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        successes: *std.atomic.Value(usize),
        cycles: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            const thread_alloc = std.heap.c_allocator;
            var store = session_store.Store.initFromHome(
                thread_alloc,
                self.home,
                self.workspace,
            ) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer store.deinit(thread_alloc);
            var command = domain.validateCommand(thread_alloc, .{ .relationship = .{
                .action = .attach,
                .id = self.child_id,
                .parent_id = self.parent_id,
            } }) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer command.deinit(thread_alloc);
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            var manager = Manager{ .sessions = &store };
            var result = manager.execute(thread_alloc, command, .{
                .actor_id = "root-id",
                .operation_id = self.operation_id,
                .relationship_authorization = .direct,
                .timestamp_ms = 1,
            }) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
            defer result.deinit(thread_alloc);
            switch (result) {
                .receipt => |receipt| if (receipt.code == .relationship_changed) {
                    _ = self.successes.fetchAdd(1, .seq_cst);
                } else self.failed.store(true, .seq_cst),
                .failure => |failure_value| if (failure_value.code == .relationship_cycle) {
                    _ = self.cycles.fetchAdd(1, .seq_cst);
                } else self.failed.store(true, .seq_cst),
                .inspection => self.failed.store(true, .seq_cst),
            }
        }
    };

    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var successes = std.atomic.Value(usize).init(0);
    var cycles = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);
    const workers = [_]Worker{
        .{
            .home = env.home,
            .workspace = env.workspace,
            .child_id = "child-a",
            .parent_id = "child-b",
            .operation_id = "attach-a",
            .ready = &ready,
            .start = &start,
            .successes = &successes,
            .cycles = &cycles,
            .failed = &failed,
        },
        .{
            .home = env.home,
            .workspace = env.workspace,
            .child_id = "child-b",
            .parent_id = "child-a",
            .operation_id = "attach-b",
            .ready = &ready,
            .start = &start,
            .successes = &successes,
            .cycles = &cycles,
            .failed = &failed,
        },
    };
    var threads: [workers.len]std.Thread = undefined;
    for (&threads, workers) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    while (ready.load(.seq_cst) != workers.len) std.atomic.spinLoopHint();
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), successes.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), cycles.load(.seq_cst));
}

const ProcessMutation = union(enum) {
    send: struct {
        operation_id: []const u8,
        content: []const u8,
    },
    attach: struct {
        child_id: []const u8,
        parent_id: []const u8,
        operation_id: []const u8,
    },
    delivery_query: struct {
        owner_id: []const u8,
        target_id: []const u8,
        boundary: bool,
        status_fd: std.c.fd_t,
        force_lock_busy: bool,
    },
    interval_poll: struct {
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    },
    capacity_policy: struct {
        child_id: []const u8,
        work_id: []const u8,
    },
    relationship_snapshot: struct {
        root_id: []const u8,
    },
};

const ProcessDeliveryOutcome = enum(u8) {
    invalid_request = 20,
    data_exposed = 21,
    lock_busy = 22,
    empty_or_wait = 23,
    other_error = 24,
    interval_emitted = 25,
    interval_pending = 26,
    interval_inactive = 27,
    interval_stopped = 28,
    capacity_admitted = 29,
    capacity_rejected = 30,
    relationship_present = 31,
    relationship_absent = 32,
};

fn processDeliveryError(err: communication_manager_mod.Error) u8 {
    return @intFromEnum(switch (err) {
        error.InvalidRequest => ProcessDeliveryOutcome.invalid_request,
        error.LockBusy => ProcessDeliveryOutcome.lock_busy,
        else => ProcessDeliveryOutcome.other_error,
    });
}

fn runProcessMutation(
    home: []const u8,
    workspace: []const u8,
    mutation: ProcessMutation,
) u8 {
    const alloc = std.heap.c_allocator;
    var store = session_store.Store.initFromHome(alloc, home, workspace) catch return switch (mutation) {
        .delivery_query,
        .interval_poll,
        .capacity_policy,
        .relationship_snapshot,
        => @intFromEnum(ProcessDeliveryOutcome.other_error),
        .send, .attach => 90,
    };
    defer store.deinit(alloc);
    var manager = Manager{ .sessions = &store };
    switch (mutation) {
        .send => |send| {
            var command = validateSend(alloc, "child-id", send.content) catch return 91;
            defer command.deinit(alloc);
            var result = manager.execute(alloc, command, .{
                .actor_id = "parent-id",
                .operation_id = send.operation_id,
                .timestamp_ms = 2,
            }) catch return 92;
            defer result.deinit(alloc);
            return switch (result) {
                .receipt => |receipt| if (receipt.code == .message_queued) 0 else 93,
                .inspection, .failure => 94,
            };
        },
        .attach => |attach| {
            var command = domain.validateCommand(alloc, .{ .relationship = .{
                .action = .attach,
                .id = attach.child_id,
                .parent_id = attach.parent_id,
            } }) catch return 95;
            defer command.deinit(alloc);
            var result = manager.execute(alloc, command, .{
                .actor_id = "root-id",
                .operation_id = attach.operation_id,
                .relationship_authorization = .direct,
                .timestamp_ms = 3,
            }) catch return 96;
            defer result.deinit(alloc);
            return switch (result) {
                .receipt => |receipt| if (receipt.code == .relationship_changed) 10 else 97,
                .failure => |failure_value| if (failure_value.code == .relationship_cycle)
                    11
                else
                    98,
                .inspection => 99,
            };
        },
        .delivery_query => |query| {
            var lock_probe = ProcessLockProbe{
                .status_fd = query.status_fd,
                .force_lock_busy = query.force_lock_busy,
            };
            var communication_manager = communication_manager_mod.Manager{
                .sessions = &store,
                .child_store_options = .{ .lock_ops = lock_probe.ops() },
            };
            if (query.boundary) {
                var result = communication_manager.prepareParentBoundary(
                    alloc,
                    query.owner_id,
                    "parent-model",
                    query.target_id,
                    .turn_boundary,
                    null,
                ) catch |err| return processDeliveryError(err);
                defer result.deinit(alloc);
                return @intFromEnum(if (result == .inject)
                    ProcessDeliveryOutcome.data_exposed
                else
                    ProcessDeliveryOutcome.empty_or_wait);
            }
            var result = communication_manager.page(
                alloc,
                query.owner_id,
                "human-surface",
                query.target_id,
                null,
                10,
            ) catch |err| return processDeliveryError(err);
            defer result.deinit(alloc);
            return @intFromEnum(if (result.deliveries.len != 0)
                ProcessDeliveryOutcome.data_exposed
            else
                ProcessDeliveryOutcome.empty_or_wait);
        },
        .interval_poll => |query| {
            var communication_manager = communication_manager_mod.Manager{
                .sessions = &store,
            };
            const outcome = communication_manager.poll(
                alloc,
                query.child_id,
                query.work_id,
                query.now_ms,
            ) catch return @intFromEnum(ProcessDeliveryOutcome.other_error);
            return @intFromEnum(switch (outcome) {
                .emitted => ProcessDeliveryOutcome.interval_emitted,
                .pending => ProcessDeliveryOutcome.interval_pending,
                .inactive => ProcessDeliveryOutcome.interval_inactive,
                .stopped => ProcessDeliveryOutcome.interval_stopped,
            });
        },
        .capacity_policy => |admission| {
            admitCapacityPolicy(
                alloc,
                &store,
                admission.child_id,
                admission.work_id,
            ) catch |err| return @intFromEnum(
                if (err == error.CapacityExceeded)
                    ProcessDeliveryOutcome.capacity_rejected
                else
                    ProcessDeliveryOutcome.other_error,
            );
            return @intFromEnum(ProcessDeliveryOutcome.capacity_admitted);
        },
        .relationship_snapshot => |query| {
            var snapshot = manager.snapshot(
                alloc,
                .{ .root_id = query.root_id },
            ) catch return @intFromEnum(ProcessDeliveryOutcome.other_error);
            defer snapshot.deinit(alloc);
            return @intFromEnum(switch (snapshot) {
                .snapshot => |value| if (!value.restart_required and
                    value.nodes.len == 1)
                    ProcessDeliveryOutcome.relationship_present
                else
                    ProcessDeliveryOutcome.relationship_absent,
                .failure => ProcessDeliveryOutcome.other_error,
            });
        },
    }
}

fn readExactProcessFd(fd: std.c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(read_count)) {
            .SUCCESS => {
                if (read_count == 0) return error.ProcessPipeFailed;
                offset += @intCast(read_count);
            },
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn writeExactProcessFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const write_count = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(write_count)) {
            .SUCCESS => offset += @intCast(write_count),
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

const process_lock_contended: u8 = 1;

const ProcessLockProbe = struct {
    status_fd: std.c.fd_t,
    force_lock_busy: bool,
    contended: bool = false,
    forced_now_ms: i64 = 0,

    fn tryLock(raw: ?*anyopaque, file: std.Io.File) !bool {
        const self: *ProcessLockProbe = @ptrCast(@alignCast(raw.?));
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        if (!locked and !self.contended) {
            try writeExactProcessFd(self.status_fd, &.{process_lock_contended});
            self.contended = true;
        }
        return locked;
    }

    fn now(raw: ?*anyopaque) i64 {
        const self: *ProcessLockProbe = @ptrCast(@alignCast(raw.?));
        if (self.force_lock_busy) {
            const current = self.forced_now_ms;
            self.forced_now_ms = std.math.maxInt(i64);
            return current;
        }
        return io_mod.milliTimestamp();
    }

    fn sleep(_: ?*anyopaque, millis: u64) void {
        io_mod.sleep(millis * std.time.ns_per_ms);
    }

    fn ops(self: *ProcessLockProbe) io_mod.LockOps {
        return .{
            .ctx = self,
            .try_lock = tryLock,
            .now_ms = now,
            .sleep_ms = sleep,
        };
    }
};

fn forkProcessMutation(
    home: []const u8,
    workspace: []const u8,
    mutation: ProcessMutation,
    ready_fd: std.c.fd_t,
    start_fd: std.c.fd_t,
    status_fd: ?std.c.fd_t,
) !std.c.pid_t {
    const pid = std.c.fork();
    if (pid < 0) return error.ProcessForkFailed;
    if (pid != 0) return pid;

    writeExactProcessFd(ready_fd, &.{1}) catch std.c._exit(100);
    var start: [1]u8 = undefined;
    readExactProcessFd(start_fd, &start) catch std.c._exit(101);
    const outcome = runProcessMutation(home, workspace, mutation);
    if (status_fd) |fd| writeExactProcessFd(fd, &.{outcome}) catch std.c._exit(102);
    std.c._exit(outcome);
}

fn waitProcessMutation(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(waited)) {
            .SUCCESS => {
                if (waited != pid or (status & 0x7f) != 0) {
                    return error.ProcessWaitFailed;
                }
                return @intCast((status >> 8) & 0xff);
            },
            .INTR => continue,
            else => return error.ProcessWaitFailed,
        }
    }
}

fn closeProcessFd(fd: std.c.fd_t) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io_mod.getIo());
}

fn runProcessMutationPair(
    home: []const u8,
    workspace: []const u8,
    first: ProcessMutation,
    second: ProcessMutation,
) ![2]u8 {
    var ready_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.ProcessPipeFailed;
    defer closeProcessFd(ready_pipe[0]);
    defer closeProcessFd(ready_pipe[1]);
    var start_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&start_pipe) != 0) return error.ProcessPipeFailed;
    defer closeProcessFd(start_pipe[0]);
    defer closeProcessFd(start_pipe[1]);

    const first_pid = try forkProcessMutation(
        home,
        workspace,
        first,
        ready_pipe[1],
        start_pipe[0],
        null,
    );
    const second_pid = forkProcessMutation(
        home,
        workspace,
        second,
        ready_pipe[1],
        start_pipe[0],
        null,
    ) catch |err| {
        writeExactProcessFd(start_pipe[1], &.{1}) catch {};
        _ = waitProcessMutation(first_pid) catch {};
        return err;
    };
    var ready: [2]u8 = undefined;
    try readExactProcessFd(ready_pipe[0], &ready);
    try writeExactProcessFd(start_pipe[1], &.{ 1, 1 });
    return .{
        try waitProcessMutation(first_pid),
        try waitProcessMutation(second_pid),
    };
}

test "competing processes converge while recovering one pending relationship transaction" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "recovery-root");
    try env.createSession(alloc, "recovery-child");
    var manager = Manager{ .sessions = &env.store };
    try executeRelationshipForTest(
        alloc,
        &manager,
        "recovery-root",
        "recovery-attach",
        .attach,
        "recovery-child",
        "recovery-root",
    );
    try std.testing.expect(try relationship_index.removeChild(
        alloc,
        &env.store,
        "recovery-root",
        "recovery-child",
        .{},
    ));
    var sync_failure = FailSyncFileAt{ .fail_at = 2 };
    try std.testing.expectError(
        error.StoreUnavailable,
        relationship_index.ensureChild(
            alloc,
            &env.store,
            "recovery-root",
            "recovery-child",
            .{ .replace_ops = .{
                .ctx = &sync_failure,
                .sync_file = FailSyncFileAt.syncFile,
            } },
        ),
    );

    var outcomes = try runProcessMutationPair(
        env.home,
        env.workspace,
        .{ .relationship_snapshot = .{ .root_id = "recovery-root" } },
        .{ .relationship_snapshot = .{ .root_id = "recovery-root" } },
    );
    std.mem.sort(u8, &outcomes, {}, std.sort.asc(u8));
    try std.testing.expectEqualSlices(u8, &.{
        @intFromEnum(ProcessDeliveryOutcome.relationship_present),
        @intFromEnum(ProcessDeliveryOutcome.relationship_present),
    }, &outcomes);

    var page = try relationship_index.page(
        alloc,
        &env.store,
        "recovery-root",
        .{},
        null,
        10,
        relationship_index.max_candidate_reads,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.candidates.len);
    try std.testing.expectEqualStrings(
        "recovery-child",
        page.candidates[0].child_id,
    );
}

test "competing process interval polls append one durable delivery" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try setupRunningIntervalWork(alloc, &env, "process-poll-child", "process-work");

    var outcomes = try runProcessMutationPair(
        env.home,
        env.workspace,
        .{ .interval_poll = .{
            .child_id = "process-poll-child",
            .work_id = "process-work",
            .now_ms = 100,
        } },
        .{ .interval_poll = .{
            .child_id = "process-poll-child",
            .work_id = "process-work",
            .now_ms = 100,
        } },
    );
    std.mem.sort(u8, &outcomes, {}, std.sort.asc(u8));
    try std.testing.expectEqualSlices(u8, &.{
        @intFromEnum(ProcessDeliveryOutcome.interval_emitted),
        @intFromEnum(ProcessDeliveryOutcome.interval_pending),
    }, &outcomes);

    var communication_manager = communication_manager_mod.Manager{
        .sessions = &env.store,
    };
    var page = try communication_manager.page(
        alloc,
        "process-poll-child",
        "process-human",
        "interval-parent",
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
}

test "competing process policy admissions cannot cross the capacity budget" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "process-capacity-child");
    try seedCapacityPolicyLedger(alloc, &env.store, "process-capacity-child");

    var outcomes = try runProcessMutationPair(
        env.home,
        env.workspace,
        .{ .capacity_policy = .{
            .child_id = "process-capacity-child",
            .work_id = "process-capacity-a",
        } },
        .{ .capacity_policy = .{
            .child_id = "process-capacity-child",
            .work_id = "process-capacity-b",
        } },
    );
    std.mem.sort(u8, &outcomes, {}, std.sort.asc(u8));
    try std.testing.expectEqualSlices(u8, &.{
        @intFromEnum(ProcessDeliveryOutcome.capacity_admitted),
        @intFromEnum(ProcessDeliveryOutcome.capacity_rejected),
    }, &outcomes);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        "process-capacity-child",
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = "process-capacity-child",
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.max_active_work_notifications,
        ledger.work_notifications.len,
    );
}

const ProcessDeliveryRaceAction = union(enum) {
    reparent: []const u8,
    detach,
    hold_until_busy,
};

fn processDeliveryOutcome(exit_code: u8) !ProcessDeliveryOutcome {
    return switch (exit_code) {
        @intFromEnum(ProcessDeliveryOutcome.invalid_request) => .invalid_request,
        @intFromEnum(ProcessDeliveryOutcome.data_exposed) => .data_exposed,
        @intFromEnum(ProcessDeliveryOutcome.lock_busy) => .lock_busy,
        @intFromEnum(ProcessDeliveryOutcome.empty_or_wait) => .empty_or_wait,
        @intFromEnum(ProcessDeliveryOutcome.other_error) => .other_error,
        else => error.ProcessWaitFailed,
    };
}

fn runProcessDeliveryRace(
    alloc: Allocator,
    sessions: *session_store.Store,
    home: []const u8,
    workspace: []const u8,
    child_id: []const u8,
    old_parent_id: []const u8,
    boundary: bool,
    action: ProcessDeliveryRaceAction,
) !ProcessDeliveryOutcome {
    var ready_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.ProcessPipeFailed;
    defer closeProcessFd(ready_pipe[0]);
    defer closeProcessFd(ready_pipe[1]);
    var start_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&start_pipe) != 0) return error.ProcessPipeFailed;
    defer closeProcessFd(start_pipe[0]);
    defer closeProcessFd(start_pipe[1]);
    var status_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&status_pipe) != 0) return error.ProcessPipeFailed;
    defer closeProcessFd(status_pipe[0]);
    defer closeProcessFd(status_pipe[1]);

    const force_lock_busy = switch (action) {
        .hold_until_busy => true,
        .reparent, .detach => false,
    };

    const pid = try forkProcessMutation(
        home,
        workspace,
        .{ .delivery_query = .{
            .owner_id = child_id,
            .target_id = old_parent_id,
            .boundary = boundary,
            .status_fd = status_pipe[1],
            .force_lock_busy = force_lock_busy,
        } },
        ready_pipe[1],
        start_pipe[0],
        status_pipe[1],
    );
    errdefer {
        writeExactProcessFd(start_pipe[1], &.{1}) catch {};
        _ = waitProcessMutation(pid) catch {};
    }
    var ready: [1]u8 = undefined;
    try readExactProcessFd(ready_pipe[0], &ready);

    var capability = try sessions.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try control.acquireLock();
    var lock_held = true;
    defer if (lock_held) lock.release();
    try writeExactProcessFd(start_pipe[1], &.{1});

    var status: [1]u8 = undefined;
    try readExactProcessFd(status_pipe[0], &status);
    if (status[0] != process_lock_contended) {
        const exit_code = try waitProcessMutation(pid);
        if (exit_code != status[0]) return error.ProcessWaitFailed;
        return processDeliveryOutcome(exit_code);
    }
    if (force_lock_busy) {
        return processDeliveryOutcome(try waitProcessMutation(pid));
    }

    var record = try control.load(alloc);
    defer record.deinit(alloc);
    alloc.free(record.parent_id.?);
    record.parent_id = switch (action) {
        .reparent => |parent_id| try alloc.dupe(u8, parent_id),
        .detach => null,
        .hold_until_busy => unreachable,
    };
    try control.save(alloc, record);
    lock.release();
    lock_held = false;
    return processDeliveryOutcome(try waitProcessMutation(pid));
}

fn expectProcessDeliveryRaceLost(outcome: ProcessDeliveryOutcome) !void {
    return switch (outcome) {
        .invalid_request, .lock_busy => {},
        .data_exposed => error.TestUnauthorizedDeliveryExposed,
        .empty_or_wait => error.TestUnauthorizedDeliveryWaited,
        .other_error,
        .interval_emitted,
        .interval_pending,
        .interval_inactive,
        .interval_stopped,
        .capacity_admitted,
        .capacity_rejected,
        .relationship_present,
        .relationship_absent,
        => error.TestDeliveryQueryFailed,
    };
}

fn expectFormerParentRejected(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    former_parent_id: []const u8,
) !void {
    var communication_manager = communication_manager_mod.Manager{ .sessions = sessions };
    try std.testing.expectError(
        error.InvalidRequest,
        communication_manager.page(
            alloc,
            child_id,
            "former-human",
            former_parent_id,
            null,
            10,
        ),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        communication_manager.prepareParentBoundary(
            alloc,
            child_id,
            "former-parent-model",
            former_parent_id,
            .turn_boundary,
            null,
        ),
    );
}

fn checkDeliveryProjectionAllocationFailures(
    alloc: Allocator,
    sessions: *session_store.Store,
    projection: communication.Projection,
) !void {
    var communication_manager = communication_manager_mod.Manager{ .sessions = sessions };
    switch (projection) {
        .human => {
            var page = try communication_manager.page(
                alloc,
                "allocation-child",
                "allocation-human",
                "allocation-parent",
                null,
                10,
            );
            defer page.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
        },
        .parent_turn => {
            var boundary = try communication_manager.prepareParentBoundary(
                alloc,
                "allocation-child",
                "allocation-parent-model",
                "allocation-parent",
                .turn_boundary,
                null,
            );
            defer boundary.deinit(alloc);
            try std.testing.expect(boundary == .inject);
        },
    }
}

fn expectDeliveryProjectionAllocationCleanup(
    alloc: Allocator,
    sessions: *session_store.Store,
    projection: communication.Projection,
) !void {
    var succeeded = false;
    for (0..512) |fail_index| {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        if (checkDeliveryProjectionAllocationFailures(
            failing.allocator(),
            sessions,
            projection,
        )) |_| {
            succeeded = true;
            break;
        } else |err| switch (err) {
            error.OutOfMemory, error.StoreUnavailable => {},
            else => return err,
        }
    }
    try std.testing.expect(succeeded);
}

test "delivery projections release ordered locks on every allocation failure" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "allocation-parent");
    try env.createSession(alloc, "allocation-child");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "allocation child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "allocation-parent",
        .operation_id = "allocation-create",
        .created_child_id = "allocation-child",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var message = try validateSend(alloc, "allocation-parent", "allocation delivery");
    defer message.deinit(alloc);
    var sent = try manager.execute(alloc, message, .{
        .actor_id = "allocation-child",
        .operation_id = "allocation-send",
        .timestamp_ms = 2,
    });
    defer sent.deinit(alloc);

    try expectDeliveryProjectionAllocationCleanup(alloc, &env.store, .human);
    try expectDeliveryProjectionAllocationCleanup(alloc, &env.store, .parent_turn);
}

test "independent process delivery queries cannot cross detach or reparent" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "process-parent-a");
    try env.createSession(alloc, "process-parent-b");
    try env.createSession(alloc, "process-child");
    var manager = Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "process delivery race",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "process-parent-a",
        .operation_id = "process-delivery-create",
        .created_child_id = "process-child",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);
    var message = try validateSend(alloc, "process-parent-a", "private delivery");
    defer message.deinit(alloc);
    var sent = try manager.execute(alloc, message, .{
        .actor_id = "process-child",
        .operation_id = "process-private-delivery",
        .timestamp_ms = 2,
    });
    defer sent.deinit(alloc);

    try std.testing.expectEqual(ProcessDeliveryOutcome.lock_busy, try runProcessDeliveryRace(
        alloc,
        &env.store,
        env.home,
        env.workspace,
        "process-child",
        "process-parent-a",
        false,
        .hold_until_busy,
    ));
    try std.testing.expectEqual(ProcessDeliveryOutcome.lock_busy, try runProcessDeliveryRace(
        alloc,
        &env.store,
        env.home,
        env.workspace,
        "process-child",
        "process-parent-a",
        true,
        .hold_until_busy,
    ));

    var communication_manager = communication_manager_mod.Manager{ .sessions = &env.store };
    var after_busy_page = try communication_manager.page(
        alloc,
        "process-child",
        "human-after-busy",
        "process-parent-a",
        null,
        10,
    );
    defer after_busy_page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), after_busy_page.deliveries.len);
    var after_busy_boundary = try communication_manager.prepareParentBoundary(
        alloc,
        "process-child",
        "parent-after-busy",
        "process-parent-a",
        .turn_boundary,
        null,
    );
    defer after_busy_boundary.deinit(alloc);
    try std.testing.expect(after_busy_boundary == .inject);

    try expectProcessDeliveryRaceLost(try runProcessDeliveryRace(
        alloc,
        &env.store,
        env.home,
        env.workspace,
        "process-child",
        "process-parent-a",
        false,
        .{ .reparent = "process-parent-b" },
    ));
    try expectFormerParentRejected(
        alloc,
        &env.store,
        "process-child",
        "process-parent-a",
    );

    var message_b = try validateSend(alloc, "process-parent-b", "private delivery b");
    defer message_b.deinit(alloc);
    var sent_b = try manager.execute(alloc, message_b, .{
        .actor_id = "process-child",
        .operation_id = "process-private-delivery-b",
        .timestamp_ms = 3,
    });
    defer sent_b.deinit(alloc);

    try expectProcessDeliveryRaceLost(try runProcessDeliveryRace(
        alloc,
        &env.store,
        env.home,
        env.workspace,
        "process-child",
        "process-parent-b",
        true,
        .detach,
    ));
    try expectFormerParentRejected(
        alloc,
        &env.store,
        "process-child",
        "process-parent-b",
    );
}

test "independent processes preserve messages and reject inverse relationship cycles" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent-id");
    try env.createSession(alloc, "child-id");
    try env.createSession(alloc, "root-id");
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");
    var manager = Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, "child");
    defer create.deinit(alloc);
    var created = try manager.execute(alloc, create, .{
        .actor_id = "parent-id",
        .operation_id = "create",
        .created_child_id = "child-id",
        .timestamp_ms = 1,
    });
    defer created.deinit(alloc);

    const message_results = try runProcessMutationPair(
        env.home,
        env.workspace,
        .{ .send = .{ .operation_id = "process-send-a", .content = "message a" } },
        .{ .send = .{ .operation_id = "process-send-b", .content = "message b" } },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &message_results);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{.messages},
    } });
    defer inspect.deinit(alloc);
    var inspected = try manager.execute(alloc, inspect, .{
        .actor_id = "parent-id",
        .timestamp_ms = 2,
    });
    defer inspected.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), inspected.inspection.messages.len);
    var found_a = false;
    var found_b = false;
    for (inspected.inspection.messages) |message| {
        found_a = found_a or std.mem.eql(u8, message.content, "message a");
        found_b = found_b or std.mem.eql(u8, message.content, "message b");
    }
    try std.testing.expect(found_a and found_b);

    const relationship_results = try runProcessMutationPair(
        env.home,
        env.workspace,
        .{ .attach = .{
            .child_id = "child-a",
            .parent_id = "child-b",
            .operation_id = "process-attach-a",
        } },
        .{ .attach = .{
            .child_id = "child-b",
            .parent_id = "child-a",
            .operation_id = "process-attach-b",
        } },
    );
    try std.testing.expect(
        (relationship_results[0] == 10 and relationship_results[1] == 11) or
            (relationship_results[0] == 11 and relationship_results[1] == 10),
    );

    var graph = try manager.snapshot(alloc, .{ .root_id = "root-id" });
    defer graph.deinit(alloc);
    try std.testing.expect(graph == .snapshot);
}
