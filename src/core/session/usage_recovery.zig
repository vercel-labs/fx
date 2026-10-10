const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("session_store.zig");
const session_adapter = @import("session_adapter.zig");
const session_usage = @import("session_usage.zig");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const max_recovery_facts: usize = 4096;
const max_recovery_incidents: usize = 4096;
const max_recovery_pending: usize = 4096;

pub const OwnedRecovery = struct {
    facts: []usage_report.GenerationFact,
    incidents: []usage_report.Incident,
    pending: []usage_report.PendingMarker,
    unknown_pending: bool,

    pub fn deinit(self: *OwnedRecovery, alloc: Allocator) void {
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        alloc.free(self.incidents);
        for (self.pending) |hint| alloc.free(hint.id);
        alloc.free(self.pending);
        self.* = undefined;
    }
};

/// Collects unresolved publication state through the bounded recovery
/// registry. Only marked sessions are loaded; historical session directories
/// are never scanned.
pub fn collectFromHome(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHomeCancelable(alloc, home_path, null);
}

fn collectFromHomeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: ?*const std.atomic.Value(bool),
) !OwnedRecovery {
    if (cancelRequested(cancel_requested)) return error.Cancelled;
    var store = session_store.Store.initReadOnlyFromHome(
        alloc,
        home_path,
        "/",
    ) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer store.deinit(alloc);

    var marked_sessions = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marked_sessions.items) |*entry| entry.deinit(alloc);
        marked_sessions.deinit(alloc);
    }

    var facts: std.ArrayList(usage_report.GenerationFact) = .empty;
    errdefer {
        for (facts.items) |*fact| fact.deinit(alloc);
        facts.deinit(alloc);
    }
    var incidents: std.ArrayList(usage_report.Incident) = .empty;
    errdefer incidents.deinit(alloc);
    var pending_hints: std.ArrayList(usage_report.PendingMarker) = .empty;
    errdefer {
        for (pending_hints.items) |hint| alloc.free(hint.id);
        pending_hints.deinit(alloc);
    }
    var out: Collected = .{ .facts = &facts, .incidents = &incidents, .pending = &pending_hints };

    for (marked_sessions.items) |marked| {
        if (cancelRequested(cancel_requested)) return error.Cancelled;
        var state = store.loadReadOnly(alloc, marked.id) catch {
            out.unknown_pending = true;
            continue;
        };
        defer state.deinit(alloc);
        const usage = state.usage orelse {
            out.unknown_pending = true;
            continue;
        };
        const checkpoint_modified = store.usageCheckpointModifiedAtNs(marked.id) catch null;
        const newer = checkpointIsNewer(usage, state.updated_at_ms, checkpoint_modified, marked.marker_modified_at_ns, marked.protected_updated_at_ms);
        try collectMarkedSession(alloc, &out, usage, state.updated_at_ms, newer);
    }

    // Sessions saved by `--sessions-v2` keep their markers apart; a marker and
    // a checkpoint each record their own time.
    var marked_v2 = session_adapter.collectMarkedUsage(alloc, home_path) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("usage", "sessions v2 usage recovery incomplete reason={s}", .{@errorName(err)});
        out.unknown_pending = true;
        break :blk std.ArrayList(session_adapter.MarkedUsage).empty;
    };
    defer {
        for (marked_v2.items) |*entry| entry.deinit(alloc);
        marked_v2.deinit(alloc);
    }
    for (marked_v2.items) |marked| {
        if (cancelRequested(cancel_requested)) return error.Cancelled;
        const usage = marked.snapshot orelse {
            out.unknown_pending = true;
            continue;
        };
        try collectMarkedSession(alloc, &out, usage, marked.at_ms, v2CheckpointIsNewer(usage, marked.at_ms, marked.protected_updated_at_ms));
    }

    return .{
        .facts = try facts.toOwnedSlice(alloc),
        .incidents = try incidents.toOwnedSlice(alloc),
        .pending = try pending_hints.toOwnedSlice(alloc),
        .unknown_pending = out.unknown_pending,
    };
}

const Collected = struct {
    facts: *std.ArrayList(usage_report.GenerationFact),
    incidents: *std.ArrayList(usage_report.Incident),
    pending: *std.ArrayList(usage_report.PendingMarker),
    unknown_pending: bool = false,
};

/// Whether a v1 session's durable usage checkpoint is at least as new as
/// what its marker protects, from the files' modification times. The v1
/// converter carries this verdict to the v2 marker (D20).
pub fn checkpointIsNewer(
    usage: session_usage.Snapshot,
    updated_at_ms: i64,
    checkpoint_modified_ns: ?i128,
    marker_modified_at_ns: i128,
    protected_updated_at_ms: ?i64,
) bool {
    if (!session_usage.needsProfileRecovery(usage)) {
        const modified = checkpoint_modified_ns orelse return false;
        return modified > marker_modified_at_ns;
    }
    const protected = protected_updated_at_ms orelse return true;
    if (checkpoint_modified_ns) |modified| return modified > marker_modified_at_ns;
    return updated_at_ms >= protected;
}

/// The same for a v2 session: its marker records the time of the checkpoint
/// it protects, and a session's checkpoint times only grow.
fn v2CheckpointIsNewer(usage: session_usage.Snapshot, at_ms: i64, protected_updated_at_ms: ?i64) bool {
    const protected = protected_updated_at_ms orelse return false;
    return if (session_usage.needsProfileRecovery(usage)) at_ms >= protected else at_ms > protected;
}

/// Adds one marked session's usage to `out`. `newer` says whether its
/// durable checkpoint is at least as new as what its marker protects.
fn collectMarkedSession(
    alloc: Allocator,
    out: *Collected,
    usage: session_usage.Snapshot,
    updated_at_ms: i64,
    newer: bool,
) !void {
    if (!newer) out.unknown_pending = true;
    if (!session_usage.needsProfileRecovery(usage)) return;

    if (usage.settled_through_sequence != usage.next_sequence - 1) {
        out.unknown_pending = true;
    }
    for (usage.publication_backlog) |fact| {
        if (out.facts.items.len == max_recovery_facts) {
            out.unknown_pending = true;
            break;
        }
        try out.facts.append(alloc, try fact.dupe(alloc));
    }
    for (usage.incidents) |incident| {
        if (out.incidents.items.len == max_recovery_incidents) {
            out.unknown_pending = true;
            break;
        }
        try out.incidents.append(alloc, incident);
    }
    for (usage.pending) |pending| {
        if (out.pending.items.len == max_recovery_pending) {
            out.unknown_pending = true;
            break;
        }
        const id = try alloc.dupe(u8, pending.id);
        errdefer alloc.free(id);
        try out.pending.append(alloc, .{
            .id = id,
            .observed_at_ms = pending.observed_at_ms orelse
                @max(updated_at_ms, 0),
        });
    }
    if (usage.billing == .incomplete and
        usage.incidents.len == 0 and
        usage.settled_through_sequence == usage.next_sequence - 1)
    {
        if (out.incidents.items.len == max_recovery_incidents) {
            out.unknown_pending = true;
        } else {
            try out.incidents.append(alloc, .{
                .occurred_at_ms = @max(updated_at_ms, 0),
                .completeness = .incomplete,
            });
        }
    }
}

pub fn collectFromHomeConservative(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHome(
        alloc,
        home_path,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

pub fn collectFromHomeConservativeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: *const std.atomic.Value(bool),
) !OwnedRecovery {
    return collectFromHomeCancelable(
        alloc,
        home_path,
        cancel_requested,
    ) catch |err| {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

fn cancelRequested(cancel_requested: ?*const std.atomic.Value(bool)) bool {
    return if (cancel_requested) |flag| flag.load(.seq_cst) else false;
}

fn empty(alloc: Allocator) Allocator.Error!OwnedRecovery {
    return .{
        .facts = try alloc.alloc(usage_report.GenerationFact, 0),
        .incidents = try alloc.alloc(usage_report.Incident, 0),
        .pending = try alloc.alloc(usage_report.PendingMarker, 0),
        .unknown_pending = false,
    };
}

fn unknown(alloc: Allocator) Allocator.Error!OwnedRecovery {
    var recovery = try empty(alloc);
    recovery.unknown_pending = true;
    return recovery;
}

test "empty recovery owns empty slices" {
    const alloc = std.testing.allocator;
    var recovery = try empty(alloc);
    defer recovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), recovery.facts.len);
    try std.testing.expectEqual(@as(usize, 0), recovery.incidents.len);
    try std.testing.expectEqual(@as(usize, 0), recovery.pending.len);
    try std.testing.expect(!recovery.unknown_pending);
}

test "cancelled recovery stops before opening profile state" {
    const alloc = std.testing.allocator;
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        collectFromHomeConservativeCancelable(alloc, "/unused", &cancelled),
    );
}

test "missing recovery registry is an empty bounded set" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try session_store.Store.initFromHome(alloc, home, "/");
    store.deinit(alloc);

    var recovery = try collectFromHome(alloc, home);
    defer recovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), recovery.facts.len);
    try std.testing.expect(!recovery.unknown_pending);
}

test "recovery markers are idempotent and clear durably" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    try store.markUsageRecoveryPending(alloc, "recovery-marker", 1);
    try store.markUsageRecoveryPending(alloc, "recovery-marker", 1);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(
            io_mod.getIo(),
            "home/.fx/sessions/usage-recovery",
            .{},
        ),
    );
    try tmp.dir.access(
        io_mod.getIo(),
        "home/.fx/usage-recovery/recovery-marker",
        .{},
    );

    var marked = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marked.items) |*entry| entry.deinit(alloc);
        marked.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), marked.items.len);
    try std.testing.expectEqualStrings("recovery-marker", marked.items[0].id);
    try std.testing.expectEqual(
        @as(?i64, 1),
        marked.items[0].protected_updated_at_ms,
    );

    try store.clearUsageRecoveryPending("recovery-marker");
    try store.clearUsageRecoveryPending("recovery-marker");
    var cleared = try store.listUsageRecoverySessions(alloc);
    defer {
        for (cleared.items) |*entry| entry.deinit(alloc);
        cleared.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), cleared.items.len);
}

test "recovery registry reads only marked durable session state" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        fn persist(_: *anyopaque, _: session_usage.Snapshot) !void {}
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var runtime_usage = session_usage.Usage.initFresh();
    defer runtime_usage.deinit(alloc);
    var checkpoint_context: u8 = 0;
    runtime_usage.configureCheckpointSink(.{
        .context = &checkpoint_context,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });
    const sequence = try runtime_usage.reserveInvocation();
    try runtime_usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try runtime_usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });
    const saved_usage = try runtime_usage.snapshot(alloc);
    try std.testing.expect(session_usage.needsProfileRecovery(saved_usage));

    const history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, "prompt", "response");
    var state = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "indexed-usage-recovery"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1000,
        .updated_at_ms = 1000,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "provider/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .usage = saved_usage,
    };
    defer state.deinit(alloc);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    try store.markUsageRecoveryPending(
        alloc,
        state.id,
        1,
    );
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var marker_before_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "home/.fx/usage-recovery/indexed-usage-recovery",
        .{},
    );
    defer marker_before_file.close(io_mod.getIo());
    const marker_before = try io_mod.readFileToEnd(
        alloc,
        &marker_before_file,
        16,
    );
    defer alloc.free(marker_before);

    var recovery = try collectFromHome(alloc, home);
    defer recovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), recovery.facts.len);
    try std.testing.expectEqualStrings(
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        recovery.facts[0].id,
    );
    try std.testing.expectEqual(@as(usize, 1), recovery.pending.len);
    try std.testing.expect(!recovery.unknown_pending);

    var marker_after_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "home/.fx/usage-recovery/indexed-usage-recovery",
        .{},
    );
    defer marker_after_file.close(io_mod.getIo());
    const marker_after = try io_mod.readFileToEnd(
        alloc,
        &marker_after_file,
        16,
    );
    defer alloc.free(marker_after);
    try std.testing.expectEqualStrings(marker_before, marker_after);
}

test "recovery marker distinguishes checkpoints around a crash boundary" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var runtime_usage = session_usage.Usage.initFresh();
    defer runtime_usage.deinit(alloc);
    const initial_usage = try runtime_usage.snapshot(alloc);
    const history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, "prompt", "response");
    var state = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "recovery-crash-boundary"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1000,
        .updated_at_ms = 1000,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "provider/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .usage = initial_usage,
    };
    defer state.deinit(alloc);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);

    const sequence = try runtime_usage.reserveInvocation();
    var unresolved = try runtime_usage.snapshot(alloc);
    defer unresolved.deinit(alloc);
    try std.testing.expect(session_usage.needsProfileRecovery(unresolved));
    const unresolved_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        alloc,
        &writable,
        unresolved,
    );
    try std.testing.expect(unresolved_checkpoint.recovery_pending);

    var before_unresolved_checkpoint = try collectFromHome(alloc, home);
    defer before_unresolved_checkpoint.deinit(alloc);
    try std.testing.expect(before_unresolved_checkpoint.unknown_pending);

    const generation_before = writable.position.log_generation;
    _ = try writable.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = unresolved } },
        unresolved_checkpoint.timestamp_ms,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        &generation_before,
        &writable.position.log_generation,
    ));

    runtime_usage.finishInvocation(sequence, 1, .unbilled);
    var settled = try runtime_usage.snapshot(alloc);
    defer settled.deinit(alloc);
    try std.testing.expect(!session_usage.needsProfileRecovery(settled));
    const settled_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        alloc,
        &writable,
        settled,
    );
    try std.testing.expect(!settled_checkpoint.recovery_pending);
    _ = try writable.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = settled } },
        settled_checkpoint.timestamp_ms,
    );

    var after_settled_checkpoint = try collectFromHome(alloc, home);
    defer after_settled_checkpoint.deinit(alloc);
    try std.testing.expect(!after_settled_checkpoint.unknown_pending);
    try std.testing.expectEqual(
        @as(usize, 0),
        after_settled_checkpoint.facts.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        after_settled_checkpoint.pending.len,
    );

    var marker_still_present = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marker_still_present.items) |*entry| entry.deinit(alloc);
        marker_still_present.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), marker_still_present.items.len);
}

test "a v2 session's usage marker is judged from its own log" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_adapter.Store.open(alloc, home);
    defer store.deinit(alloc);
    var model = "m".*;
    const s = try session_adapter.Session.create(alloc, &store, "/w", .ask, .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    });
    defer s.close();
    try s.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("q") }, .assistant = @constCast("a") } }, types.ConversationLanguage.default());

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var settled = try usage.snapshot(alloc);
    defer settled.deinit(alloc);
    var generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV".*;
    var origin = "fx".*;
    var generations = [_]session_usage.PendingGeneration{.{ .id = &generation_id, .sequence = 1, .origin = &origin, .team = null, .observed_at_ms = 5 }};
    // Generation 1 is counted but not yet published to the ledger.
    var pending = settled;
    pending.next_sequence = 2;
    pending.settled_through_sequence = 1;
    pending.billing = .pending;
    pending.pending = &generations;

    // A checkpoint still owed to the ledger is recovered from the log.
    try s.persistUsage(pending);
    {
        var recovery = try collectFromHome(alloc, home);
        defer recovery.deinit(alloc);
        try std.testing.expect(!recovery.unknown_pending);
        try std.testing.expectEqual(@as(usize, 1), recovery.pending.len);
        try std.testing.expectEqualStrings(&generation_id, recovery.pending[0].id);
        try std.testing.expectEqual(@as(i64, 5), recovery.pending[0].observed_at_ms);
    }

    // A marker newer than every durable checkpoint: the crash came between
    // the marker and its checkpoint, so recovery cannot be complete.
    var markers = try tmp.dir.openDir(io, ".fx/" ++ session_adapter.usage_markers_dir_name, .{});
    defer markers.close(io);
    try markers.writeFile(io, .{ .sub_path = s.id(), .data = "v1 9999999999999\n", .flags = .{ .permissions = .fromMode(0o600) } });
    {
        var recovery = try collectFromHome(alloc, home);
        defer recovery.deinit(alloc);
        try std.testing.expect(recovery.unknown_pending);
    }
    try markers.deleteFile(io, s.id());

    // Once nothing is owed, the marker goes and nothing is recovered.
    try s.persistUsage(pending);
    try s.persistUsage(settled);
    try std.testing.expectError(error.FileNotFound, markers.statFile(io, s.id(), .{}));
    var recovery = try collectFromHome(alloc, home);
    defer recovery.deinit(alloc);
    try std.testing.expect(!recovery.unknown_pending);
    try std.testing.expectEqual(@as(usize, 0), recovery.pending.len);
}
