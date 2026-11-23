//! The `fx session prune`, `--discard-original`, and `fx session restore`
//! actions, one session at a time, as the CLI reports them. Each action returns
//! a Row: what happened, or the error that stopped it. The changes themselves
//! are in the session manager (`session_manager/prune.zig`).

const std = @import("std");
const session_adapter = @import("session_adapter.zig");

const Allocator = std.mem.Allocator;

pub const kept_dir_name = session_adapter.prune_kept_dir_name;
pub const log_name = session_adapter.prune_log_name;

pub const Action = enum { prune, discard_original, restore };

pub const Status = enum {
    pruned,
    nothing_to_do,
    would_prune,
    discarded,
    would_discard,
    nothing_to_discard,
    restored,
    busy,
    failed,
};

pub const Row = struct {
    action: Action,
    session_id: []u8,
    status: Status,
    bytes_before: ?u64 = null,
    bytes_after: ?u64 = null,
    usage_superseded: u64 = 0,
    snapshots_superseded: u64 = 0,
    freed_bytes: ?u64 = null,
    /// A kept original exists after the action.
    original_kept: bool = false,
    /// The kept original's absolute path, when one exists.
    original_path: ?[]u8 = null,
    /// Set for a busy or a failed row.
    failure: ?session_adapter.CommandError = null,
    /// The person-facing text for `failure`, set by the caller.
    message: ?[]const u8 = null,

    pub fn deinit(row: *Row, alloc: Allocator) void {
        alloc.free(row.session_id);
        if (row.original_path) |path| alloc.free(path);
        row.* = undefined;
    }
};

const page_size: usize = 100;

fn newRow(alloc: Allocator, action: Action, id: []const u8) !Row {
    return .{
        .action = action,
        .session_id = try alloc.dupe(u8, id),
        .status = .failed,
    };
}

fn failRow(row: *Row, err: anyerror) void {
    const mapped = session_adapter.commandError(err);
    row.failure = mapped;
    row.status = if (mapped == error.SessionBusy) .busy else .failed;
}

fn keptPath(store: *session_adapter.Store, alloc: Allocator, row: *Row) !void {
    row.original_path = try store.manager.keptOriginalPath(alloc, row.session_id);
}

/// `fx session prune <id>`, or its dry run.
pub fn prune(store: *session_adapter.Store, alloc: Allocator, id: []const u8, dry_run: bool) !Row {
    var row = try newRow(alloc, .prune, id);
    errdefer row.deinit(alloc);
    const report = store.manager.prune(id, .{ .dry_run = dry_run }) catch |err| {
        failRow(&row, err);
        return row;
    };
    row.bytes_before = report.bytes_before;
    row.bytes_after = report.bytes_after;
    row.usage_superseded = report.usage_superseded;
    row.snapshots_superseded = report.snapshots_superseded;
    // The report's flag says whether an original was kept before this run; a
    // finished prune keeps one either way.
    row.original_kept = report.original_kept or report.outcome == .pruned;
    row.status = switch (report.outcome) {
        .no_op => .nothing_to_do,
        .dry_run => .would_prune,
        .pruned => .pruned,
    };
    if (row.original_kept) try keptPath(store, alloc, &row);
    return row;
}

/// `fx session prune <id> --discard-original`, or its dry run. In a batch
/// (`many`), a session without a finished cleanup has nothing to discard;
/// alone, it is refused.
pub fn discardOriginal(store: *session_adapter.Store, alloc: Allocator, id: []const u8, dry_run: bool, many: bool) !Row {
    var row = try newRow(alloc, .discard_original, id);
    errdefer row.deinit(alloc);
    if (dry_run) {
        const status = store.manager.pruneStatus(id) catch |err| {
            failRow(&row, err);
            return row;
        };
        if (!status.finished) {
            notPruned(&row, many);
            return row;
        }
        row.freed_bytes = status.kept_bytes;
        row.status = .would_discard;
        row.original_kept = true;
        try keptPath(store, alloc, &row);
        return row;
    }
    const freed = store.manager.discardOriginal(id) catch |err| {
        if (err == error.NotPruned) {
            notPruned(&row, many);
        } else failRow(&row, err);
        return row;
    };
    row.freed_bytes = freed;
    row.status = .discarded;
    return row;
}

fn notPruned(row: *Row, many: bool) void {
    if (many) {
        row.status = .nothing_to_discard;
        return;
    }
    failRow(row, error.NotPruned);
}

/// `fx session restore <id>`.
pub fn restore(store: *session_adapter.Store, alloc: Allocator, id: []const u8) !Row {
    var row = try newRow(alloc, .restore, id);
    errdefer row.deinit(alloc);
    const report = store.manager.restore(id) catch |err| {
        failRow(&row, err);
        return row;
    };
    row.status = .restored;
    row.bytes_before = report.bytes_before;
    row.bytes_after = report.bytes_after;
    return row;
}

/// The ids of every root session the store lists, across workspaces, newest
/// first. The caller frees each id and the slice.
pub fn rootIds(store: *session_adapter.Store, alloc: Allocator) ![][]u8 {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    var cursor: ?session_adapter.ListCursor = null;
    while (true) {
        var page = try store.manager.list(alloc, .all, cursor, page_size);
        defer page.deinit();
        for (page.items) |item| {
            if (item.role != .root) continue;
            const id = try alloc.dupe(u8, item.id);
            errdefer alloc.free(id);
            try ids.append(alloc, id);
        }
        cursor = page.next orelse break;
    }
    return ids.toOwnedSlice(alloc);
}

pub fn freeIds(alloc: Allocator, ids: [][]u8) void {
    for (ids) |id| alloc.free(id);
    alloc.free(ids);
}
