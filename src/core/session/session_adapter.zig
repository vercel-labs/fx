//! The one door between fx and the session manager (sessions v2).
//!
//! Behind `--sessions-v2` or FX_SESSIONS_V2=1, with one backend per process.
//! Hosts call this file; it is the only fx file that imports
//! `session_manager`, and the boundary test at the bottom keeps it so. v1
//! code is never called from here except for its encoders and its turn
//! builder, so both backends store the same bytes for the same history.
//!
//! What goes where:
//! - each completed piece of a turn is one `item` whose `type` is the v1
//!   piece kind and whose `data` is the v1 payload;
//! - a turn ends with a `turn_end` item and `turn_committed`, or an
//!   `interruption` item and `turn_interrupted` (`cancel` or `failed`);
//! - preferences, permissions, conversation language, title and usage are
//!   `set` values in v1's encodings;
//! - large bodies (tool results, tool images, command replay, web-fetch
//!   downloads) are blobs of the session, each named by its hash (D44); an
//!   ACP client's prompt and tool identities are settings (D46); hosted
//!   terminal state lives in `~/.fx/terminal/{id}/` (D45). An older session
//!   with a `~/.fx/session-files/{id}/` side folder moves on its first
//!   writable open (D47, `tla/MoveSideFiles.tla`).

const std = @import("std");
const builtin = @import("builtin");
const sm = @import("session_manager");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const image_data = @import("../images/image_data.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_event = @import("session_event.zig");
const result_store = @import("result_store.zig");
const session_log = @import("session_log.zig");
const session_codec = @import("session_codec.zig");
const session_usage = @import("session_usage.zig");
const session_layout = @import("session_layout.zig");
const session_child_store = @import("session_child_store.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const session_summary_codec = @import("session_summary_codec.zig");
const v1_conversion = @import("v1_conversion.zig");
const child_state = @import("../subagent/child_state.zig");
const artifact_digest = @import("artifact_digest.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;
const Event = session_event.ConversationEvent;
const PieceKind = std.meta.Tag(Event);

/// Folder of the side files older v2 sessions kept, under `~/.fx`; a
/// session moves out of it on its first writable open (D47).
pub const files_dir_name = profile_paths.session_files_dir_name;
/// Folder of v2 sessions' hosted terminal state, under `~/.fx` (D45).
pub const terminal_dir_name = profile_paths.terminal_dir_name;
/// Folder of the usage-recovery markers of v2 sessions, under `~/.fx`;
/// v1's readers load only v1 sessions, so v2 markers live apart.
pub const usage_markers_dir_name = "usage-recovery-v2";
/// The profile's home folder, opened for listing: creating `~/.fx` in it
/// syncs it, and Linux cannot sync a folder opened any other way (`O_PATH`).
fn openHome(home: []const u8) !io_mod.VerifiedDir {
    return .{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true, .follow_symlinks = false }) };
}

/// Pieces larger than this go to a blob; the line keeps a reference.
const max_inline_piece_bytes: usize = 256 * 1024;
/// Lines per page when replaying history.
const replay_page_lines: usize = 256;

/// Whether this process keeps its sessions in v2: the flag, or
/// FX_SESSIONS_V2 set to `1` or `true`.
pub fn enabled(flag: bool) bool {
    if (flag) return true;
    const value = io_mod.getenv("FX_SESSIONS_V2") orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

pub const Host = sm.Host;
pub const ChildOutcome = sm.Outcome;

/// One child as its parent's log folds it (D22). Owns its strings.
pub const Child = struct {
    id: []u8,
    /// The child's newest work item.
    work_id: []u8,
    /// That work item is spawned and not finished.
    open: bool,
    /// How the newest finished work item ended; null before the first.
    outcome: ?ChildOutcome,
    /// fx's data on the newest `child_spawned` and `child_finished`.
    spawn_data: ?[]u8,
    finish_data: ?[]u8,
    /// Seq of the newest line about this child.
    seq: u64,
};

pub fn freeChildren(alloc: Allocator, children: []Child) void {
    for (children) |child| freeChild(alloc, child);
    alloc.free(children);
}

fn freeChild(alloc: Allocator, child: Child) void {
    alloc.free(child.id);
    alloc.free(child.work_id);
    if (child.spawn_data) |data| alloc.free(data);
    if (child.finish_data) |data| alloc.free(data);
}

/// A line about a child, appended through its parent.
pub const ChildLine = union(enum) {
    spawned: struct { child: []const u8, work_id: []const u8, data: ?[]const u8 = null },
    finished: struct { child: []const u8, work_id: []const u8, outcome: ChildOutcome, data: ?[]const u8 = null },
};

// ---------------------------------------------------------------------------
// Wiring trace

/// One step of `Wiring.tla`, as a `wiring` trace line that trace validation
/// reads back: the store opening and closing (the process's start and
/// exit), a host session opening and closing, and the turn and child lines
/// a host session writes. `pid` tells one process's steps from another's.
fn traceWiring(comptime action: []const u8, session_id: []const u8, comptime detail: []const u8, pid: i64) void {
    debug_trace.logf("wiring", "action=" ++ action ++ " session={s}" ++ detail ++ " pid={d}", .{ session_id, pid });
}

fn processId() i64 {
    if (comptime builtin.os.tag == .wasi) return 0;
    return std.c.getpid();
}

// ---------------------------------------------------------------------------
// Store: one per process

pub const Store = struct {
    manager: *sm.Manager,
    /// `$HOME`, owned: the base of `~/.fx/sessions/v2` and of the side folders.
    home: []u8,
    /// Read once, for the wiring trace: not a call per append.
    pid: i64,
    /// Why the last v1 session this store refused to convert is unreadable
    /// (D61): the file and the reason.
    problem: v1_conversion.Problem = .{},
    /// Told once when converting a v1 session runs past
    /// `slow_conversion_ms`, so the host can say why the open is slow (D61).
    notice: ?Notice = null,

    pub const Notice = struct {
        context: ?*anyopaque,
        emit: *const fn (context: ?*anyopaque, text: []const u8) void,
    };

    /// The file and the reason the last refused conversion found its v1
    /// session unreadable, or null. Borrowed until the next conversion.
    pub fn conversionProblem(store: *const Store) ?[]const u8 {
        return if (store.problem.len == 0) null else store.problem.text();
    }

    /// Marks `id`'s usage checkpoint at `ms` as still owing the profile
    /// ledger (D20).
    fn writeUsageMarker(store: *Store, alloc: Allocator, id: []const u8, ms: i64) !void {
        var dir = try store.openUsageMarkers();
        defer dir.close();
        var buffer: [48]u8 = undefined;
        const content = try std.fmt.bufPrint(&buffer, "v1 {d}\n", .{ms});
        // A full disk stops the turn here, before the model is asked, so it
        // must read as one (D29) and not as a failed replace.
        var cause: ?anyerror = null;
        io_mod.durableReplaceVerifiedWithOps(alloc, &dir, id, content, .{ .pre_rename_cause = &cause }) catch |err| {
            if (cause) |stopped| if (storageCause(stopped)) |named| return named;
            return err;
        };
    }

    fn openUsageMarkers(store: *Store) !io_mod.VerifiedDir {
        return store.makeProfileFolder(usage_markers_dir_name);
    }

    /// Touches no disk: a session's folder appears with its first turn.
    pub fn open(alloc: Allocator, home: []const u8) !Store {
        // Resolved as v1 resolves its sessions root, so a home reached
        // through a symlink (macOS `/var`) passes the no-follow opens below.
        const owned_home = io_mod.realpathAlloc(alloc, home) catch |err| blk: {
            debug_trace.logf("session", "event=sessions_v2_home_unresolved err={s} using=given", .{@errorName(err)});
            break :blk try alloc.dupe(u8, home);
        };
        errdefer alloc.free(owned_home);
        const root = try std.fs.path.join(alloc, &.{
            home,
            profile_paths.root_dir_name,
            profile_paths.sessions_dir_name,
            session_layout.sessions_v2_dir,
        });
        defer alloc.free(root);
        const manager = try sm.Manager.init(alloc, io_mod.getIo(), .{
            .root = root,
            .diagnostics = .{ .context = null, .emit = traceDiagnostic },
        });
        const pid = processId();
        traceWiring("StoreOpen", "-", "", pid);
        return .{ .manager = manager, .home = owned_home, .pid = pid };
    }

    /// `$HOME` from the environment.
    pub fn openFromEnv(alloc: Allocator) !Store {
        return open(alloc, io_mod.getenv("HOME") orelse return error.HomeNotSet);
    }

    /// Every Session must be closed first.
    pub fn deinit(store: *Store, alloc: Allocator) void {
        traceWiring("StoreClose", "-", "", store.pid);
        store.manager.deinit();
        alloc.free(store.home);
        store.* = undefined;
    }

    /// `~/.fx/{name}`, or null when nothing has made it yet. `~/.fx` may be
    /// readable by others, as an old release left it (D61), until v2 first
    /// writes there; what v2 keeps below it is private.
    fn openProfileFolder(store: *Store, name: []const u8) !?io_mod.VerifiedDir {
        var home = try openHome(store.home);
        defer home.close();
        var fx = try io_mod.openRealDirIfPresent(&home, profile_paths.root_dir_name) orelse return null;
        defer fx.close();
        return io_mod.openVerifiedPrivateDirIfPresent(&fx, name);
    }

    /// `~/.fx/{name}`, made `0700` when missing; `~/.fx` too, as v1's
    /// writable root makes it.
    fn makeProfileFolder(store: *Store, name: []const u8) !io_mod.VerifiedDir {
        var home = try openHome(store.home);
        defer home.close();
        var fx = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.root_dir_name);
        defer fx.close();
        return io_mod.openOrCreateVerifiedPrivateDir(&fx, name);
    }

    /// The folders of `id` outside the manager: its terminal state (D45)
    /// and a side folder not yet moved (D47).
    const outside_folders = [_][]const u8{ terminal_dir_name, files_dir_name };

    /// Removes the folders of `id` outside the manager; `why` names the
    /// caller in the trace.
    fn removeFiles(store: *Store, id: []const u8, why: []const u8) void {
        for (outside_folders) |root_name| {
            var root = (store.openProfileFolder(root_name) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why={s} err={s}", .{ id, root_name, why, @errorName(err) });
                continue;
            }) orelse continue;
            defer root.close();
            if (root.dir.statFile(io_mod.getIo(), id, .{ .follow_symlinks = false })) |_| {} else |_| continue;
            root.dir.deleteTree(io_mod.getIo(), id) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why={s} err={s}", .{ id, root_name, why, @errorName(err) });
                continue;
            };
            debug_trace.logf("session", "event=sessions_v2_files_removed session={s} root={s} why={s}", .{ id, root_name, why });
        }
    }

    /// Copies the folders of `from` outside the manager to `to`, root by
    /// root: plain files and folders only, never through a link. False when
    /// anything was left out; a source with none has nothing to copy. A
    /// side folder not yet moved is copied as it is, and the copy moves on
    /// its own first open.
    fn copyFiles(store: *Store, from: []const u8, to: []const u8) bool {
        var complete = true;
        for (outside_folders) |root_name| {
            var root = (store.openProfileFolder(root_name) catch |err| {
                complete = copyFailed(from, err);
                continue;
            }) orelse continue;
            defer root.close();
            var source = (io_mod.openVerifiedPrivateDirIfPresent(&root, from) catch |err| {
                complete = copyFailed(from, err);
                continue;
            }) orelse continue;
            defer source.close();
            var target = io_mod.openOrCreateVerifiedPrivateDir(&root, to) catch |err| {
                complete = copyFailed(from, err);
                continue;
            };
            defer target.close();
            if (!copyTree(&source, &target, 0)) complete = false;
        }
        return complete;
    }

    /// Removes folders outside the manager whose session is gone, except
    /// young ones (D36, D45), in both roots.
    fn sweepFiles(store: *Store, alloc: Allocator, report: *Doctor, now_ms: i64) !void {
        for (outside_folders) |root_name| try store.sweepRoot(alloc, root_name, report, now_ms);
    }

    fn sweepRoot(store: *Store, alloc: Allocator, root_name: []const u8, report: *Doctor, now_ms: i64) !void {
        var files = try store.openProfileFolder(root_name) orelse return;
        defer files.close();
        var it = files.dir.iterate();
        while (try it.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            session_layout.validateSessionId(entry.name) catch continue;
            var probe = store.manager.read(alloc, entry.name, .start, .forward, 1) catch |err| switch (err) {
                error.NotFound => null,
                else => continue,
            };
            if (probe) |*page| {
                page.deinit();
                continue;
            }
            const stat = files.dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false }) catch {
                report.kept += 1;
                continue;
            };
            const changed_ms: i64 = @intCast(@divFloor(stat.mtime.toNanoseconds(), std.time.ns_per_ms));
            if (now_ms - changed_ms < orphan_min_age_ms) {
                debug_trace.logf("session", "event=sessions_v2_orphan_files_young session={s} root={s}", .{ entry.name, root_name });
                continue;
            }
            files.dir.deleteTree(io_mod.getIo(), entry.name) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_files_kept session={s} root={s} why=orphan err={s}", .{ entry.name, root_name, @errorName(err) });
                report.kept += 1;
                continue;
            };
            debug_trace.logf("session", "event=sessions_v2_files_removed session={s} root={s} why=orphan", .{ entry.name, root_name });
            report.removed += 1;
        }
    }

    /// A child's whole history, read without its lock: every turn, oldest
    /// first. Free with `types.freeHistoryTurnSlice`.
    pub fn childHistory(store: *Store, alloc: Allocator, child_id: []const u8) ![]types.HistoryTurn {
        var history: std.ArrayList(types.HistoryTurn) = .empty;
        errdefer {
            for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
            history.deinit(alloc);
        }
        const Sink = struct {
            alloc: Allocator,
            history: *std.ArrayList(types.HistoryTurn),

            fn turn(sink: *@This(), value: types.HistoryTurn, _: ?u64) !void {
                errdefer types.freeHistoryTurn(sink.alloc, value);
                try sink.history.append(sink.alloc, value);
            }

            /// A child's history is its turns only.
            fn summary(_: *@This(), _: []const u8) !void {}
        };
        var sink: Sink = .{ .alloc = alloc, .history = &history };
        try replay(.{ .store = store, .id = child_id }, alloc, alloc, .start, null, ReplaySink.init(&sink));
        return history.toOwnedSlice(alloc);
    }

    /// A child's newest preferences, read without its lock. Caller owns.
    pub fn childPreferences(store: *Store, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        var from: sm.From = .end;
        while (true) {
            var page = try store.manager.read(alloc, child_id, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                if (body == .set and body.set.key == .prefs) return decodePreferences(alloc, body.set.value);
            }
            from = .{ .at = page.next orelse return error.InvalidSessionFormat };
        }
    }
};

/// Every repair or drop the manager makes reaches the trace log.
fn traceDiagnostic(_: ?*anyopaque, event: sm.Diagnostic) void {
    debug_trace.logf("session", "event=sessions_v2_diagnostic kind={s} session={s} count={d} offset={d}", .{
        @tagName(event.kind), event.session_id, event.count, event.offset,
    });
}

// ---------------------------------------------------------------------------
// Commands: `fx session {id}`, `fx session recover`, doctor

/// What the session commands report, in the names fx's CLI knows.
pub const CommandError = error{
    SessionNotFound,
    InvalidSessionId,
    SessionBusy,
    InvalidSessionFormat,
    UnsupportedSessionSchema,
    SessionRecoveryBoundaryInvalid,
    SessionStoreUnavailable,
    DurablePathUnsafe,
    HomeNotSet,
    OutOfMemory,
};

/// Maps an error from `Store.openFromEnv`, `listPage`, `readSession`,
/// `recover` or `doctor` onto `CommandError`: a storage fault leaves the
/// store unavailable, and anything else a record fails with is damage.
pub fn commandError(err: anyerror) CommandError {
    return switch (err) {
        error.SessionNotFound, error.NotFound, error.ChildSession => error.SessionNotFound,
        error.InvalidArgument, error.InvalidSessionId => error.InvalidSessionId,
        error.Busy, error.SessionBusy => error.SessionBusy,
        error.UnsupportedVersion => error.UnsupportedSessionSchema,
        error.Corrupt => error.InvalidSessionFormat,
        // `recover` of a session whose first turn never ended whole (D15).
        error.InvalidForkPoint => error.SessionRecoveryBoundaryInvalid,
        error.DurablePathUnsafe, error.SessionPathUnsafe => error.DurablePathUnsafe,
        error.HomeNotSet => error.HomeNotSet,
        error.OutOfMemory => error.OutOfMemory,
        error.Io, error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig => blk: {
            debug_trace.logf("session", "event=sessions_v2_command_failed kind=store err={s}", .{@errorName(err)});
            break :blk error.SessionStoreUnavailable;
        },
        else => blk: {
            debug_trace.logf("session", "event=sessions_v2_command_failed kind=record err={s}", .{@errorName(err)});
            break :blk error.InvalidSessionFormat;
        },
    };
}

/// A saved root session as v1's state, read without its lock while another
/// process may hold it (D37), for `fx session {id}`: every turn, with each
/// compaction's summary where it happened (D32). A missing session, a
/// child, or an id that cannot name one is `error.SessionNotFound`. Caller
/// owns the result.
pub fn readSession(store: *Store, alloc: Allocator, id: []const u8) !Resumed {
    var peeked = store.manager.peek(alloc, id) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => readV1Session(store, alloc, id),
        else => err,
    };
    defer peeked.deinit(alloc);
    if (peeked.role != .root) return error.SessionNotFound;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var restored = try settingsFrom(alloc, scratch.allocator(), peeked.state);
    defer restored.deinit(alloc);
    restored.history = try detailHistory(.{ .store = store, .id = id }, alloc);
    return resumedOf(alloc, &restored, id, peeked.workspace);
}

/// A v1 root v2 does not hold yet, read by v1's reader without converting
/// it (D61). Caller owns the result.
fn readV1Session(store: *Store, alloc: Allocator, id: []const u8) !Resumed {
    var detail = (try v1_conversion.readDetail(alloc, store.home, id)) orelse return error.SessionNotFound;
    defer detail.summary.deinit(alloc);
    errdefer detail.state.deinit(alloc);
    const title = if (detail.summary.title) |value| try alloc.dupe(u8, value) else null;
    return .{ .state = detail.state, .title = title };
}

/// A page of saved root sessions as v1 pages them: newest first, one
/// workspace when `workspace` is set, and only what follows `continuation`.
/// It reads only the part of v2's index the page needs (D62), and those of
/// v1's roots not converted yet that can reach the page, each one v2 does
/// not hold (D59). Caller owns the page.
pub fn listPage(
    store: *Store,
    alloc: Allocator,
    workspace: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0 or limit > session_store.session_list_max_limit) return error.InvalidSessionListLimit;
    var candidates: std.ArrayList(session_store.SessionSummary) = .empty;
    defer {
        for (candidates.items) |*summary| summary.deinit(alloc);
        candidates.deinit(alloc);
    }
    try v2Window(store, alloc, workspace, continuation, limit + 1, &candidates);
    session_summary_codec.sortSummariesNewestFirst(candidates.items);
    const v2_count = candidates.items.len;

    var v1_roots = try v1_conversion.listRoots(alloc, store.home, null);
    defer v1_roots.deinit(alloc);
    session_summary_codec.sortSummariesNewestFirst(v1_roots.summaries.items);
    var added: usize = 0;
    for (v1_roots.summaries.items) |summary| {
        if (workspace) |root| if (!std.mem.eql(u8, summary.workspace_root orelse continue, root)) continue;
        if (continuation) |position| if (!session_summary_codec.summaryFollowsContinuation(summary, position)) continue;
        // After `limit` newer ones, this one and every later one is off the page.
        if (countBefore(candidates.items[0..v2_count], summary) + added > limit) break;
        if (holdsV2(store, alloc, summary.id)) continue;
        try candidates.ensureUnusedCapacity(alloc, 1);
        candidates.appendAssumeCapacity(try session_summary_codec.cloneSessionSummary(alloc, summary));
        added += 1;
    }
    session_summary_codec.sortSummariesNewestFirst(candidates.items);
    return session_summary_codec.sessionListPageFromSummaries(alloc, candidates.items, workspace, continuation, limit);
}

/// Appends v2's roots that follow `continuation` in v1's order to `out`,
/// owned by `alloc`: at least `want` when there are, and every one tied at
/// the time of the last, since v2 orders a tie by id ascending and v1 by
/// id descending (D11), so a page cut inside a tie has all of it.
fn v2Window(
    store: *Store,
    alloc: Allocator,
    workspace: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    want: usize,
    out: *std.ArrayList(session_store.SessionSummary),
) !void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const filter: sm.Filter = if (workspace) |root| .{ .workspace = root } else .all;
    // From the continuation's time with its ties: those v1 orders first
    // are dropped below.
    var cursor: ?sm.ListCursor = if (continuation) |position| .{ .updated_ms = std.math.cast(u64, position.updated_at_ms) orelse return } else null;
    var kept: usize = 0;
    var cut: ?u64 = null;
    while (true) {
        var page = try store.manager.list(alloc, filter, cursor, want);
        defer page.deinit();
        for (page.items) |item| {
            if (cut) |at| if (item.updated_ms != at) return;
            var summary = try summaryOf(alloc, scratch.allocator(), item);
            if (continuation) |position| if (!session_summary_codec.summaryFollowsContinuation(summary, position)) {
                summary.deinit(alloc);
                continue;
            };
            out.append(alloc, summary) catch |err| {
                summary.deinit(alloc);
                return err;
            };
            kept += 1;
            if (kept == want) cut = item.updated_ms;
        }
        cursor = page.next orelse return;
    }
}

/// How many of `sorted`, newest first, come before `summary`.
fn countBefore(sorted: []const session_store.SessionSummary, summary: session_store.SessionSummary) usize {
    var count: usize = 0;
    while (count < sorted.len and session_summary_codec.summaryFollowsContinuation(summary, .{ .updated_at_ms = sorted[count].updated_at_ms, .id = sorted[count].id })) count += 1;
    return count;
}

pub const Recovered = struct {
    id: []u8,
    /// Entries in the copy's history; a compaction summary counts as one.
    history_len: usize,
    /// False when a side file could not be copied.
    files_complete: bool,

    pub fn deinit(recovered: *Recovered, alloc: Allocator) void {
        alloc.free(recovered.id);
        recovered.* = undefined;
    }
};

/// `fx session recover` (D15): a new root session copied from `id` up to
/// its last turn that ended before any damage, with a copy of its side
/// files. The source is never changed, and may be held by another process.
/// Caller owns the result.
pub fn recover(store: *Store, alloc: Allocator, id: []const u8) !Recovered {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // Line 1 names the session's kind and workspace, however damaged the rest is.
    var first = store.manager.read(sa, id, .start, .forward, 1) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => error.SessionNotFound,
        else => err,
    };
    defer first.deinit();
    if (first.entries.len == 0) return error.SessionNotFound;
    const created = switch (first.entries[0].body orelse return error.InvalidSessionFormat) {
        .session_created => |value| value,
        else => return error.InvalidSessionFormat,
    };
    if (created.role != .root) return error.SessionNotFound;
    const copy = store.manager.openFork(.{ .source = id, .at = .last_good, .workspace = created.workspace, .host = .ask }) catch |err| return switch (err) {
        error.NotFound, error.ChildSession => error.SessionNotFound,
        else => err,
    };
    defer copy.release();
    var restored = try restoreFrom(.{ .store = store, .id = copy.id(), .handle = copy }, alloc, sa, try copy.state(sa), null);
    defer restored.deinit(alloc);
    const copy_id = try alloc.dupe(u8, copy.id());
    errdefer alloc.free(copy_id);
    copy.close() catch |err| debug_trace.logf("session", "event=sessions_v2_recovered_close_failed session={s} err={s}", .{ copy_id, @errorName(err) });
    return .{ .id = copy_id, .history_len = restored.history.len, .files_complete = store.copyFiles(id, copy_id) };
}

pub const Doctor = struct {
    /// Saved root sessions.
    sessions: usize = 0,
    /// The most recently updated one.
    latest: ?[]u8 = null,
    /// Sessions whose log was checked, up to the limit.
    checked: usize = 0,
    /// Checked sessions with a damaged line or a stale snapshot.
    damaged: std.ArrayList([]u8) = .empty,
    /// Side folders removed because their session is gone.
    removed: usize = 0,
    /// Side folders with no session that could not be removed.
    kept: usize = 0,

    pub fn deinit(report: *Doctor, alloc: Allocator) void {
        if (report.latest) |id| alloc.free(id);
        for (report.damaged.items) |id| alloc.free(id);
        report.damaged.deinit(alloc);
        report.* = undefined;
    }
};

/// A side folder younger than this may belong to a new session whose first
/// turn has not created its log yet (D36).
const orphan_min_age_ms: i64 = 24 * std.time.ms_per_hour;

/// `fx doctor` on v2 (D36): verifies up to `limit` sessions and removes side
/// folders whose session is gone. Rebuilds nothing. Caller owns the report.
pub fn doctor(store: *Store, alloc: Allocator, limit: usize, now_ms: i64) !Doctor {
    var report: Doctor = .{};
    errdefer report.deinit(alloc);
    var latest_ms: u64 = 0;
    var cursor: ?sm.ListCursor = null;
    while (true) {
        var page = try store.manager.list(alloc, .all, cursor, list_page_size);
        defer page.deinit();
        for (page.items) |item| {
            if (item.role != .root) continue;
            report.sessions += 1;
            if (report.latest == null or item.updated_ms > latest_ms) {
                const id = try alloc.dupe(u8, item.id);
                if (report.latest) |old| alloc.free(old);
                report.latest = id;
                latest_ms = item.updated_ms;
            }
            if (report.checked == limit) continue;
            report.checked += 1;
            const verified = store.manager.verify(item.id) catch |err| switch (err) {
                error.NotFound => continue,
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=sessions_v2_doctor_unreadable session={s} err={s}", .{ item.id, @errorName(err) });
                    try report.damaged.append(alloc, try alloc.dupe(u8, item.id));
                    continue;
                },
            };
            if (verified.damaged_at != null or verified.bad_snapshots > 0 or verified.bad_blobs > 0) try report.damaged.append(alloc, try alloc.dupe(u8, item.id));
        }
        cursor = page.next orelse break;
    }
    try store.sweepFiles(alloc, &report, now_ms);
    return report;
}

// ---------------------------------------------------------------------------
// Session: one per open session

/// Settings a new session starts with; held in memory until its first turn.
pub const Seed = struct {
    preferences: session_codec.DurableSessionPreferences,
    language: types.ConversationLanguage,
    permission_state: session_permission_state.State,
    /// A child's instructions, kept in its own `prefs` (D34); roots leave
    /// it empty.
    instructions: []const u8 = "",
};

pub const Target = union(enum) {
    id: []const u8,
    /// The newest updated root session in the workspace.
    last,
    /// The session this host last opened in the workspace (`fx -c`).
    last_opened,
};

/// What resume gives back. Owns everything; free with `deinit`.
pub const Restored = struct {
    history: []types.HistoryTurn,
    language: types.ConversationLanguage,
    preferences: ?session_codec.DurableSessionPreferences = null,
    permission_state: ?session_permission_state.State = null,
    usage: ?session_usage.Snapshot = null,
    /// The stored title, generated or chosen by the user.
    title: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64 = 0,

    pub fn deinit(restored: *Restored, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, restored.history);
        if (restored.title) |value| alloc.free(value);
        if (restored.preferences) |*value| value.deinit(alloc);
        if (restored.permission_state) |*value| value.deinit(alloc);
        if (restored.usage) |*value| value.deinit(alloc);
        restored.* = undefined;
    }
};

/// A resumed session as v1's state. Owns everything; free with `deinit`.
pub const Resumed = struct {
    state: session_codec.DurableSessionState,
    title: ?[]u8,

    pub fn deinit(resumed: *Resumed, alloc: Allocator) void {
        resumed.state.deinit(alloc);
        if (resumed.title) |value| alloc.free(value);
        resumed.* = undefined;
    }
};

/// A session's blobs as fx's stores reach them (D44), shared by every
/// capability over the session, including the copies a background reader or
/// a running command keeps. It lives until the last holder releases it.
/// Once the session closes it stores nothing more; reads go to the
/// process's manager, which outlives every session.
///
/// Locks: `life` is held through each store, so a close waits for one in
/// flight; `mutex` guards only the counts and lists. Neither is taken while
/// the other is wanted, and no store takes the session's own lock.
const BlobHost = struct {
    alloc: Allocator,
    store: *Store,
    /// The session's id, owned.
    id: []u8,
    life: std.Io.Mutex = .init,
    /// The open session; null once it closed.
    session: ?sm.Session,
    mutex: std.Io.Mutex = .init,
    refs: usize = 1,
    /// Blobs stored since the last item that lists them (D44).
    pending: std.ArrayList(Hash) = .empty,
    /// A moved session's old side-file names, as `{folder}/{name}`, to their
    /// blobs (D47). Set while the session opens; read-only after.
    moved: std.StringHashMapUnmanaged(Hash) = .empty,
    /// The compactor's records by name (D50), loaded on open and kept
    /// since; `mutex` guards them.
    records: std.StringArrayHashMapUnmanaged(Hash) = .empty,
    /// Records kept since the last `compaction_records` line, which the
    /// next one lists.
    records_added: std.ArrayList(Hash) = .empty,
    /// Counts record changes, so a line written while another record
    /// arrives leaves the map due again.
    records_generation: u64 = 0,
    records_written: u64 = 0,

    const Hash = session_child_store.Blobs.Hash;

    const vtable: session_child_store.Blobs.VTable = .{
        .put = put,
        .put_file = putFile,
        .put_record = putRecord,
        .record_names = recordNames,
        .resolve = resolve,
        .get = get,
        .path = path,
        .retain = retain,
        .release = release,
    };

    fn create(alloc: Allocator, store: *Store, handle: sm.Session) !*BlobHost {
        const host = try alloc.create(BlobHost);
        errdefer alloc.destroy(host);
        host.* = .{ .alloc = alloc, .store = store, .id = try alloc.dupe(u8, handle.id()), .session = handle };
        return host;
    }

    fn blobs(host: *BlobHost) session_child_store.Blobs {
        return .{ .ctx = host, .vtable = &vtable };
    }

    fn from(ctx: *anyopaque) *BlobHost {
        return @ptrCast(@alignCast(ctx));
    }

    /// The session is closing: waits for a store in flight, then refuses
    /// new ones. Blobs stored but never listed stay unreachable from a fork,
    /// so the trace counts them.
    fn detach(host: *BlobHost) void {
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        host.session = null;
        host.life.unlock(io);
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (host.pending.items.len > 0) debug_trace.logf("session", "event=sessions_v2_blobs_unlisted session={s} count={d}", .{ host.id, host.pending.items.len });
        if (host.records_generation != host.records_written) debug_trace.logf("session", "event=sessions_v2_records_unlisted session={s} count={d}", .{ host.id, host.records_added.items.len });
    }

    fn put(ctx: *anyopaque, bytes: []const u8) session_child_store.BlobError!Hash {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlob(bytes) catch |err| return host.storeFailed(err);
        try host.remember(hash);
        return hash;
    }

    fn putFile(ctx: *anyopaque, file: std.Io.File, len: u64) session_child_store.BlobError!Hash {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlobFile(file, len) catch |err| return host.storeFailed(err);
        try host.remember(hash);
        return hash;
    }

    fn putRecord(ctx: *anyopaque, name: []const u8, bytes: []const u8) session_child_store.BlobError!void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.life.lockUncancelable(io);
        defer host.life.unlock(io);
        const handle = host.session orelse return error.BlobStoreClosed;
        const hash = handle.putBlob(bytes) catch |err| return host.storeFailed(err);
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        try host.records_added.ensureUnusedCapacity(host.alloc, 1);
        if (host.records.getPtr(name)) |known| {
            known.* = hash;
        } else {
            const key = try host.alloc.dupe(u8, name);
            errdefer host.alloc.free(key);
            try host.records.put(host.alloc, key, hash);
        }
        host.records_added.appendAssumeCapacity(hash);
        host.records_generation += 1;
    }

    /// Every record's name, then a moved session's old tool-results names
    /// that no record replaced (D47, D50).
    fn recordNames(ctx: *anyopaque, arena: Allocator) session_child_store.BlobError![]const []const u8 {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        var names: std.ArrayList([]const u8) = .empty;
        try names.ensureTotalCapacity(arena, host.records.count() + host.moved.count());
        for (host.records.keys()) |name| names.appendAssumeCapacity(try arena.dupe(u8, name));
        // `movedFolder(.tool_results)`'s names.
        const prefix = "tool-results/";
        var moved = host.moved.keyIterator();
        while (moved.next()) |key| {
            if (!std.mem.startsWith(u8, key.*, prefix)) continue;
            const name = key.*[prefix.len..];
            if (host.records.contains(name)) continue;
            names.appendAssumeCapacity(try arena.dupe(u8, name));
        }
        return names.items;
    }

    /// The records map as JSON and the records it adds, when it changed
    /// since the last line that recorded it (D50); in `a`.
    fn recordsDue(host: *BlobHost, a: Allocator) error{OutOfMemory}!?RecordsDue {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        if (host.records_generation == host.records_written) return null;
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try map.ensureTotalCapacity(a, host.records.count());
        for (host.records.keys(), host.records.values()) |name, *hash| map.putAssumeCapacity(name, try a.dupe(u8, hash));
        var json: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(std.json.ArrayHashMap([]const u8){ .map = map }, .{}, &json.writer) catch return error.OutOfMemory;
        return .{ .map_json = json.written(), .added = try a.dupe(Hash, host.records_added.items), .generation = host.records_generation };
    }

    /// A durable line now records `due`: its records are listed, and the map
    /// is current unless a record arrived since.
    fn recordsWritten(host: *BlobHost, due: RecordsDue) void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        host.records_added.replaceRangeAssumeCapacity(0, due.added.len, &.{});
        host.records_written = due.generation;
    }

    const RecordsDue = struct { map_json: []const u8, added: []const Hash, generation: u64 };

    fn storeFailed(host: *BlobHost, err: sm.AppendError) session_child_store.BlobError {
        // A body is stored only while the session is on disk (D44).
        if (err == error.InvalidTransition) debug_trace.logf("session", "event=sessions_v2_body_before_turn session={s}", .{host.id});
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge => error.BlobTooLarge,
            error.SessionClosed => error.BlobStoreClosed,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.FileTooBig => error.FileTooBig,
            error.InvalidArgument, error.InvalidTransition, error.Io => error.BlobStoreFailed,
        };
    }

    fn remember(host: *BlobHost, hash: Hash) error{OutOfMemory}!void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        for (host.pending.items) |*known| if (std.mem.eql(u8, known, &hash)) return;
        try host.pending.append(host.alloc, hash);
    }

    /// The pending blobs, in `a`.
    fn pendingCopy(host: *BlobHost, a: Allocator) error{OutOfMemory}![]Hash {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        return a.dupe(Hash, host.pending.items);
    }

    /// Forgets pending blobs a durable line now lists.
    fn listed(host: *BlobHost, hashes: []const Hash) void {
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        for (hashes) |*hash| {
            for (host.pending.items, 0..) |*known, index| {
                if (!std.mem.eql(u8, known, hash)) continue;
                _ = host.pending.orderedRemove(index);
                break;
            }
        }
    }

    fn resolve(ctx: *anyopaque, kind: session_child_store.ManagedChildKind, name: []const u8) session_child_store.BlobError!Hash {
        const host = from(ctx);
        if (artifact_digest.blobHash(name)) |hash| return hash[0..artifact_digest.blob_hex_bytes].*;
        if (kind == .tool_results) {
            const io = io_mod.getIo();
            host.mutex.lockUncancelable(io);
            defer host.mutex.unlock(io);
            if (host.records.get(name)) |hash| return hash;
        }
        const folder = movedFolder(kind) orelse return error.BlobNotFound;
        var key_buffer: [movedKeyMax]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "{s}/{s}", .{ folder, name }) catch return error.BlobNotFound;
        return host.moved.get(key) orelse error.BlobNotFound;
    }

    fn get(ctx: *anyopaque, alloc: Allocator, hash: []const u8, max_bytes: usize) session_child_store.BlobError![]u8 {
        const host = from(ctx);
        const bytes = host.store.manager.getBlob(alloc, host.id, hash) catch |err| return blobReadFailed(err);
        if (bytes.len > max_bytes) {
            alloc.free(bytes);
            return error.BlobTooLarge;
        }
        return bytes;
    }

    fn path(ctx: *anyopaque, alloc: Allocator, hash: []const u8) session_child_store.BlobError![]u8 {
        const host = from(ctx);
        return host.store.manager.blobPath(alloc, host.id, hash) catch |err| blobReadFailed(err);
    }

    fn blobReadFailed(err: sm.BlobError) session_child_store.BlobError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArgument, error.NotFound => error.BlobNotFound,
            error.Corrupt => error.BlobDamaged,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.FileTooBig => error.FileTooBig,
            error.Io => error.BlobStoreFailed,
        };
    }

    fn retain(ctx: *anyopaque) void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        defer host.mutex.unlock(io);
        host.refs += 1;
    }

    fn release(ctx: *anyopaque) void {
        const host = from(ctx);
        const io = io_mod.getIo();
        host.mutex.lockUncancelable(io);
        host.refs -= 1;
        const last = host.refs == 0;
        host.mutex.unlock(io);
        if (!last) return;
        var keys = host.moved.keyIterator();
        while (keys.next()) |key| host.alloc.free(key.*);
        host.moved.deinit(host.alloc);
        for (host.records.keys()) |name| host.alloc.free(name);
        host.records.deinit(host.alloc);
        host.records_added.deinit(host.alloc);
        host.pending.deinit(host.alloc);
        host.alloc.free(host.id);
        host.alloc.destroy(host);
    }
};

/// The side-folder layout an older session kept each kind of body in, as
/// `session_child_store` routes it; the key prefix of its moved names (D47).
fn movedFolder(kind: session_child_store.ManagedChildKind) ?[]const u8 {
    return switch (kind) {
        .tool_results => "tool-results",
        .command_artifacts => "logs/commands",
        .browser_artifacts => "artifacts/web-fetch",
        else => null,
    };
}

/// A moved name's key: a folder of a few bytes and a handle of at most 160.
const movedKeyMax = 256;

pub const Session = struct {
    alloc: Allocator,
    store: *Store,
    handle: sm.Session,
    /// `~/.fx/session-files/{id}`, owned: where an older session kept its
    /// side files, read once by the move (D47).
    files_path: []u8,
    /// The session's blobs, shared with every capability over it (D44).
    host: *BlobHost,
    capability: ?session_child_store.SessionChildCapability = null,
    /// Serializes this adapter's own state; the manager's Session is
    /// thread-safe on its own.
    mutex: std.Io.Mutex = .init,
    /// Encodings of the open turn's pieces already appended, in order.
    streamed: std.ArrayList([]u8) = .empty,
    /// Result files the open turn's stream wrote, by call id; both owned.
    stored_results: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Ids of the open turn's calls already saved as running (D28), owned.
    running: std.ArrayList([]u8) = .empty,
    turn_open: bool = false,
    /// Highest turn number started; the manager numbers turns the same way.
    last_turn: u64 = 0,
    /// The v2 turn behind each of fx's history turns, in order; null for a
    /// compacted summary.
    turn_numbers: std.ArrayList(?u64) = .empty,
    /// The language tag last written, owned.
    language: ?[]u8 = null,
    /// Started in this process: its first commit may name it.
    fresh: bool,
    /// A host's own session, not a subagent child's: `Wiring.tla` models
    /// only these.
    root: bool = true,
    titled: bool = false,
    /// A resumed session with no title: the title its first prompt gives,
    /// owned, written with its next turn end (D52).
    first_title: ?[]u8 = null,
    /// A usage-recovery marker protects a checkpoint still waiting for the
    /// profile ledger; it keeps its first time until nothing is pending.
    usage_marked: bool = false,
    /// Time of the newest usage checkpoint; each new one is later.
    usage_at_ms: i64 = 0,
    /// A child's instructions as its `prefs` hold them (D34), owned; null
    /// for a root and for a child without any.
    instructions: ?[]u8 = null,
    /// A conversion's import: the original time of the batches it writes
    /// next (D59). Null for every other session.
    import_ts: ?u64 = null,

    pub fn create(alloc: Allocator, store: *Store, workspace: []const u8, host: Host, seed: Seed) !*Session {
        // Every v2 write needs a writable open, and both start here or in
        // resumeSession: E2E tests use this to prove read-only paths never
        // reach one.
        io_mod.e2eFailIfDurableMutationAttempted();
        const handle = try newHandle(store, workspace, host);
        errdefer handle.release();
        const self = try init(alloc, store, handle, true);
        errdefer self.destroyInner();
        try self.appendSeed(seed);
        traceWiring("Open", self.id(), "", self.store.pid);
        return self;
    }

    /// A new session whose id no v1 folder has, so it never hides a session
    /// still to convert (`tla/V1Conversion.tla` NoShadow). `openNew` touches
    /// no disk, so a taken id costs one more try.
    fn newHandle(store: *Store, workspace: []const u8, host: Host) !sm.Session {
        for (0..8) |_| {
            const handle = try store.manager.openNew(.{ .workspace = workspace, .host = host });
            const taken = v1_conversion.hasFolder(store.home, handle.id()) catch |err| {
                debug_trace.logf("convert", "action=IdUnchecked session={s} err={s}", .{ handle.id(), @errorName(err) });
                handle.release();
                return error.SessionStoreUnavailable;
            };
            if (!taken) return handle;
            debug_trace.logf("convert", "action=IdTaken session={s}", .{handle.id()});
            handle.release();
        }
        return error.SessionStoreUnavailable;
    }

    /// The settings a new session holds until its first turn.
    fn appendSeed(self: *Session, seed: Seed) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try self.write(&.{
            .{ .set = .{ .key = .prefs, .value = try encodePreferences(a, seed.preferences, self.instructions) } },
            .{ .set = .{ .key = .permissions, .value = try session_codec.encodePermissionState(a, seed.permission_state) } },
            .{ .set = .{ .key = .language, .value = try jsonString(a, seed.language.view()) } },
        });
        self.language = try self.alloc.dupe(u8, seed.language.view());
    }

    /// Opens a child of `parent_id` for one work item (D22, D34): its log
    /// when it has one, or a new child under `child_id`, the id the parent's
    /// `child_spawned` already names, holding `seed` until its first turn.
    /// Instructions in `seed` replace the stored ones; empty keeps them.
    pub fn openChild(alloc: Allocator, store: *Store, parent_id: []const u8, child_id: []const u8, workspace: []const u8, seed: Seed) !*Session {
        io_mod.e2eFailIfDurableMutationAttempted();
        if (store.manager.openResume(.{ .target = .{ .id = child_id }, .workspace = workspace, .host = .child, .parent = parent_id })) |handle| {
            errdefer handle.release();
            const self = try init(alloc, store, handle, false);
            errdefer self.destroyInner();
            self.root = false;
            try self.openMoved();
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const state = try handle.state(scratch.allocator());
            self.last_turn = state.last_turn;
            // Every child starts with its preferences (`appendSeed`).
            const raw = state.prefs orelse return error.InvalidSessionFormat;
            self.instructions = try decodeInstructions(alloc, raw);
            if (seed.instructions.len > 0 and !std.mem.eql(u8, seed.instructions, self.childInstructions())) {
                var preferences = try decodePreferences(alloc, raw);
                defer preferences.deinit(alloc);
                try self.replaceInstructions(preferences, seed.instructions);
            }
            return self;
        } else |err| switch (err) {
            error.NotFound => {},
            else => return err,
        }
        const handle = try store.manager.openNew(.{ .workspace = workspace, .host = .child, .role = .child, .parent = parent_id, .id = child_id });
        errdefer handle.release();
        const self = try init(alloc, store, handle, false);
        errdefer self.destroyInner();
        self.root = false;
        if (seed.instructions.len > 0) self.instructions = try alloc.dupe(u8, seed.instructions);
        try self.appendSeed(seed);
        return self;
    }

    /// The session's current preferences. Caller owns.
    pub fn currentPreferences(self: *Session, alloc: Allocator) !session_codec.DurableSessionPreferences {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const state = try self.handle.state(scratch.allocator());
        return decodePreferences(alloc, state.prefs orelse return error.InvalidSessionFormat);
    }

    /// A child's instructions (D34), or empty. Borrowed until `close`.
    pub fn childInstructions(self: *const Session) []const u8 {
        return self.instructions orelse "";
    }

    fn replaceInstructions(self: *Session, preferences: session_codec.DurableSessionPreferences, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = try self.write(&.{.{ .set = .{ .key = .prefs, .value = try encodePreferences(arena.allocator(), preferences, owned) } }});
        if (self.instructions) |old| self.alloc.free(old);
        self.instructions = owned;
    }

    pub fn resumeSession(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host) !*Session {
        return resumeWaiting(alloc, store, target, workspace, host, null);
    }

    /// As `resumeSession`, but SessionBusy at once when another process has
    /// the session open, for the session picker (D38).
    pub fn resumeSessionWithoutWaiting(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host) !*Session {
        return resumeWaiting(alloc, store, target, workspace, host, 0);
    }

    /// `lock_wait_ms` null waits 2 s for the writer lock, v2's or v1's. A
    /// session only v1 holds is converted first, its family whole (D55,
    /// D61, `tla/V1Conversion.tla`): every host opens through here.
    fn resumeWaiting(alloc: Allocator, store: *Store, target: Target, workspace: []const u8, host: Host, lock_wait_ms: ?u64) !*Session {
        io_mod.e2eFailIfDurableMutationAttempted();
        // A reason belongs to this open only, never an earlier one's.
        store.problem = .{};
        const started = io_mod.nanoTimestamp();
        switch (target) {
            .id => |session_id| return openOrConvert(alloc, store, session_id, workspace, host, lock_wait_ms, started),
            // The newest of the listing, which holds v1's unconverted roots
            // too (D61).
            .last => {
                const newest = (try newestListed(store, alloc, workspace)) orelse return error.NoSavedSessions;
                defer alloc.free(newest);
                return openOrConvert(alloc, store, newest, workspace, host, lock_wait_ms, started);
            },
            .last_opened => {
                if (store.manager.openResume(.{ .target = .{ .last_opened = host }, .workspace = workspace, .host = host, .lock_wait_ms = lock_wait_ms })) |handle| {
                    return opened(alloc, store, handle, true);
                } else |err| switch (err) {
                    error.NotFound => {},
                    else => return resumeError(err, target),
                }
                // v1's remembered session, when v2 has none (D56).
                const remembered = (try v1_conversion.rememberedId(alloc, store.home, workspace)) orelse return error.NoRememberedSession;
                defer alloc.free(remembered);
                return openOrConvert(alloc, store, remembered, workspace, host, lock_wait_ms, started);
            },
        }
    }

    /// Opens `session_id`, converting it first when only v1 holds it. The
    /// `[convert] action=Opened` line times a converting open from `started`
    /// to its return.
    fn openOrConvert(alloc: Allocator, store: *Store, session_id: []const u8, workspace: []const u8, host: Host, lock_wait_ms: ?u64, started: i128) !*Session {
        const target: Target = .{ .id = session_id };
        const resume_options: sm.ResumeOptions = .{ .target = .{ .id = session_id }, .workspace = workspace, .host = host, .lock_wait_ms = lock_wait_ms };
        if (store.manager.openResume(resume_options)) |handle| {
            return opened(alloc, store, handle, true);
        } else |err| switch (err) {
            error.NotFound => {},
            else => return resumeError(err, target),
        }
        var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = host, .started = started };
        defer conversion.deinit();
        const outcome = try conversion.family(session_id, lock_wait_ms orelse v1_conversion.lock_wait_ms);
        const handle = store.manager.openResume(resume_options) catch |err| return resumeError(err, target);
        // Held: another process converted it, and may have left v1 state.
        const self = try opened(alloc, store, handle, outcome == .held);
        if (outcome == .converted) {
            const ms = @as(f64, @floatFromInt(io_mod.nanoTimestamp() - started)) / std.time.ns_per_ms;
            debug_trace.logf("convert", "action=Opened session={s} members={d} turns={d} files={d} ms={d:.3}", .{ session_id, conversion.members, conversion.turns, conversion.files, ms });
            conversion.tellLeftOut(session_id);
        }
        return self;
    }

    /// `clean` removes what a conversion left in v1 for this session.
    fn opened(alloc: Allocator, store: *Store, handle: sm.Session, clean: bool) !*Session {
        errdefer handle.release();
        const self = try init(alloc, store, handle, false);
        errdefer self.destroyInner();
        try self.openMoved();
        var state = try handle.state(alloc);
        defer state.deinit(alloc);
        self.last_turn = state.last_turn;
        if (clean) cleanLeftovers(store, alloc, self.id(), &state);
        traceWiring("Open", self.id(), "", self.store.pid);
        return self;
    }

    fn init(alloc: Allocator, store: *Store, handle: sm.Session, fresh: bool) !*Session {
        const files_path = try std.fs.path.join(alloc, &.{ store.home, profile_paths.root_dir_name, files_dir_name, handle.id() });
        errdefer alloc.free(files_path);
        const host = try BlobHost.create(alloc, store, handle);
        errdefer BlobHost.release(host);
        const self = try alloc.create(Session);
        self.* = .{ .alloc = alloc, .store = store, .handle = handle, .files_path = files_path, .host = host, .fresh = fresh };
        return self;
    }

    pub fn id(self: *const Session) []const u8 {
        return self.handle.id();
    }

    /// Appends through the manager; a host session also traces the turn and
    /// child lines `Wiring.tla` models. The first item lists every blob the
    /// stores kept since the last such line, so verify and recover see a
    /// lost one as damage (D39, D44). Compactor records kept since the last
    /// `compaction_records` line get a new one first, so the line that
    /// cites them never lands without them (D50).
    fn write(self: *Session, events: []const sm.Event) sm.AppendError!u64 {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();
        const due = try self.host.recordsDue(a);
        const with_records = if (due) |records| try std.mem.concat(a, sm.Event, &.{ try self.recordLines(a, records), events }) else events;
        const pending = try self.host.pendingCopy(a);
        const batch = try listPending(a, with_records, pending);
        const seq = if (self.import_ts) |ts| try self.handle.appendAt(batch.events, ts) else try self.handle.append(batch.events);
        if (batch.listed) self.host.listed(pending);
        if (due) |records| self.host.recordsWritten(records);
        if (self.root) for (events) |event| switch (event) {
            .turn_started => traceWiring("BeginTurn", self.id(), "", self.store.pid),
            .turn_committed => traceWiring("EndTurn", self.id(), " end=commit", self.store.pid),
            .turn_interrupted => traceWiring("EndTurn", self.id(), " end=interrupt", self.store.pid),
            .child_spawned => traceWiring("Spawn", self.id(), "", self.store.pid),
            .child_finished => traceWiring("ChildDone", self.id(), "", self.store.pid),
            else => {},
        };
        return seq;
    }

    /// The `compaction_records` lines for `due`: its map as one more blob,
    /// listed with the records it adds, in chunks as the move's are (D50).
    fn recordLines(self: *Session, a: Allocator, due: BlobHost.RecordsDue) sm.AppendError![]const sm.Event {
        const map_hash = try a.dupe(u8, &(try self.handle.putBlob(due.map_json)));
        const value = try std.fmt.allocPrint(a, "{{\"map\":\"{s}\"}}", .{map_hash});
        var refs: std.ArrayList([]const u8) = .empty;
        try refs.ensureTotalCapacity(a, due.added.len + 1);
        for (due.added) |*hash| refs.appendAssumeCapacity(hash);
        refs.appendAssumeCapacity(map_hash);
        var lines: std.ArrayList(sm.Event) = .empty;
        var rest = refs.items;
        while (rest.len > 0) {
            const take = @min(rest.len, moved_refs_per_line);
            try lines.append(a, .{ .set = .{ .key = .compaction_records, .value = value, .blobs = rest[0..take] } });
            rest = rest[take..];
        }
        return lines.items;
    }

    /// The session is on disk: it has a turn, ended or open.
    pub fn saved(self: *const Session) bool {
        return self.last_turn > 0;
    }

    /// The session's folder under `~/.fx/sessions/v2`, for display. Caller owns it.
    pub fn folderPath(self: *const Session, alloc: Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{
            self.store.home,
            profile_paths.root_dir_name,
            profile_paths.sessions_dir_name,
            session_layout.sessions_v2_dir,
            self.id(),
        });
    }

    /// Closes the session and frees the adapter. Every child thread of this
    /// session must have joined (`tla/Wiring.tla` ParentOutlivesChildren).
    /// A copy of its capability that a background reader still holds keeps
    /// reading, and stores nothing more (D44).
    pub fn close(self: *Session) void {
        self.host.detach();
        self.handle.close() catch |err| debug_trace.logf("session", "event=sessions_v2_close_failed session={s} err={s}", .{ self.id(), @errorName(err) });
        if (self.root) traceWiring("Close", self.id(), "", self.store.pid);
        if (self.turn_open) debug_trace.logf("session", "event=sessions_v2_turn_closed_open session={s} streamed={d}", .{ self.id(), self.streamed.items.len });
        // Before `release`: the id lives in the handle.
        if (!self.saved()) self.removeUnsavedFiles();
        self.handle.release();
        self.destroyInner();
    }

    /// A session that never reached the disk takes its terminal folder with
    /// it, as v1 removes a pristine session's folder. Asks the manager
    /// first: a first write that failed may still have landed.
    fn removeUnsavedFiles(self: *Session) void {
        var probe = self.store.manager.read(self.alloc, self.id(), .start, .forward, 1) catch |err| switch (err) {
            error.NotFound => null,
            else => {
                debug_trace.logf("session", "event=sessions_v2_unsaved_files_kept session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
        };
        if (probe) |*page| {
            page.deinit();
            return;
        }
        self.store.removeFiles(self.id(), "unsaved");
    }

    fn destroyInner(self: *Session) void {
        const alloc = self.alloc;
        if (self.capability) |*capability| capability.deinit();
        BlobHost.release(self.host);
        self.clearStreamed();
        self.streamed.deinit(alloc);
        self.stored_results.deinit(alloc);
        self.running.deinit(alloc);
        self.turn_numbers.deinit(alloc);
        if (self.language) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.first_title) |value| alloc.free(value);
        alloc.free(self.files_path);
        alloc.destroy(self);
    }

    /// Forgets what the open turn holds, once it ends or is superseded.
    fn clearStreamed(self: *Session) void {
        for (self.streamed.items) |bytes| self.alloc.free(bytes);
        self.streamed.clearRetainingCapacity();
        var stored = self.stored_results.iterator();
        while (stored.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.stored_results.clearRetainingCapacity();
        for (self.running.items) |call_id| self.alloc.free(call_id);
        self.running.clearRetainingCapacity();
    }

    // -- bodies --------------------------------------------------------------

    /// The capability over this session's blobs (D44): it stores and reads
    /// large bodies, routes terminal state to `~/.fx/terminal/{id}` (D45),
    /// and has no side folder. Borrowed until `close`.
    pub fn childCapability(self: *Session) !*session_child_store.SessionChildCapability {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.capabilityLocked();
    }

    fn capabilityLocked(self: *Session) !*session_child_store.SessionChildCapability {
        if (self.capability) |*capability| return capability;
        const terminal_path = try std.fs.path.join(self.alloc, &.{ self.store.home, profile_paths.root_dir_name, terminal_dir_name, self.id() });
        defer self.alloc.free(terminal_path);
        self.capability = try session_child_store.SessionChildCapability.initBlobs(self.alloc, self.host.blobs(), terminal_path, .writable);
        return &self.capability.?;
    }

    // -- turns ---------------------------------------------------------------

    /// Opens the turn on disk if it is not open yet, so a body stored for it
    /// is a blob of a session on disk (D44). Caller holds the mutex.
    fn openTurnLocked(self: *Session) !void {
        if (self.turn_open) return;
        _ = try self.write(&.{.turn_started});
        self.startedTurn();
    }

    /// Opens a subagent child's turn as its work starts: a child streams
    /// nothing, and its tools may store bodies before the commit (D44).
    pub fn beginTurn(self: *Session) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.openTurnLocked();
    }

    /// Stores the turn's tool results and images as blobs and gives them
    /// handles, as v1 does at commit. A result whose blob the stream already
    /// wrote (`withResultFiles`) keeps it, unwritten a second time.
    pub fn prepareTurn(self: *Session, turn: *types.HistoryTurn) !void {
        try self.reuseStreamedFiles(turn);
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            const stores = switch (turn.*) {
                .assistant => |entry| storesBodies(entry.execution),
                .interrupted => |entry| storesBodies(entry.execution),
                .compacted_summary => false,
            };
            if (stores) try self.openTurnLocked();
        }
        try session_log.externalizeConversationTurnResults(self.alloc, turn, try self.childCapability());
    }

    fn reuseStreamedFiles(self: *Session, turn: *types.HistoryTurn) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.stored_results.count() == 0) return;
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => return,
        };
        for (execution.tool_steps) |step| for (step.tool_results) |*result| {
            if (result.output_handle != null) continue;
            const stored = self.stored_results.get(result.tool_call_id) orelse continue;
            // The name is the content's hash, so a match means the same bytes.
            const handle = try result_store.blobHandle(self.alloc, result.output);
            if (!std.mem.eql(u8, handle, stored)) {
                self.alloc.free(handle);
                continue;
            }
            result.output_handle = handle;
            result.stored_output_bytes = result.output.len;
        };
    }

    /// Appends a finished turn: the pieces not streamed yet, then its end,
    /// in one durable batch. `turn` must already be prepared.
    pub fn commitTurn(self: *Session, turn: types.HistoryTurn, language: types.ConversationLanguage) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var events: std.ArrayList(Event) = .empty;
        try session_event.appendHistoryTurnConversationEvents(a, &events, turn);
        if (events.items.len < 2) return error.InvalidConversationFrame;
        const pieces = events.items[0 .. events.items.len - 1];
        const end = events.items[events.items.len - 1];

        // The end piece joins the others; its line ends the turn.
        const all = events.items;
        const encoded = try a.alloc([]u8, all.len);
        for (all, encoded) |piece, *bytes| bytes.* = try encodePiece(a, piece);
        const start = try self.streamedPrefix(encoded[0..pieces.len]);

        var tail: std.ArrayList(sm.Event) = .empty;
        switch (end) {
            .turn_completed => try tail.append(a, .turn_committed),
            .interrupted => |interruption| try tail.append(a, .{ .turn_interrupted = switch (interruption.reason) {
                .cancelled => .cancel,
                .failed => .failed,
            } }),
            else => return error.InvalidConversationFrame,
        }
        const language_tag = language.view();
        const language_changed = self.language == null or !std.mem.eql(u8, self.language.?, language_tag);
        if (language_changed) try tail.append(a, .{ .set = .{ .key = .language, .value = try jsonString(a, language_tag) } });
        // A new session's first turn names it, or a resumed one's first
        // prompt, which a crash may have left in an interrupted turn (D52).
        const derived_title = if (!self.root or self.titled)
            null
        else if (self.first_title) |title|
            title
        else if (self.fresh)
            try deriveTitle(a, &.{turn})
        else
            null;
        if (derived_title) |title| try tail.append(a, .{ .set = .{ .key = .title, .value = try jsonString(a, title) } });

        try self.writePieces(a, all[start..], encoded[start..], tail.items);
        try self.turn_numbers.append(self.alloc, self.last_turn);
        self.turn_open = false;
        self.clearStreamed();
        if (language_changed) {
            const owned = try self.alloc.dupe(u8, language_tag);
            if (self.language) |old| self.alloc.free(old);
            self.language = owned;
        }
        if (derived_title != null) self.titled = true;
        self.fresh = false;
    }

    /// Streams the turn so far (`AgentRuntimeDeps.append_turn_piece`): the
    /// first call starts the turn, later calls append only the pieces
    /// completed since. A tool result gets the side file the commit would
    /// write for it (`withResultFiles`); a tool image without its handle
    /// waits for the commit, which is authoritative. `running`'s calls are
    /// saved once each as `tool_running` items, outside the streamed pieces,
    /// so a finished step still streams and commits as it always did (D28),
    /// and its message's text with them (D51).
    pub fn appendProgress(
        self: *Session,
        user: types.UserTurn,
        execution: types.ExecutionMemory,
        running: Running,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var events: std.ArrayList(Event) = .empty;
        try events.append(a, .{ .user = .{ .text = user.text, .images = user.images, .work_id = user.work_id } });
        // A result's blob needs the turn on disk first (D44).
        if (storesBodies(execution)) try self.openTurnLocked();
        // On a missing handle the list keeps the pieces before it.
        session_event.appendExecutionConversationEvents(a, &events, try self.withResultFiles(a, execution)) catch |err| switch (err) {
            error.ConversationArtifactRequired => {},
            else => return err,
        };
        const encoded = try a.alloc([]u8, events.items.len);
        for (events.items, encoded) |event, *bytes| bytes.* = try encodePiece(a, event);
        const start = try self.streamedPrefix(encoded);
        if (!self.turn_open or start < encoded.len) {
            try self.writePieces(a, events.items[start..], encoded[start..], &.{});
            try self.streamed.ensureUnusedCapacity(self.alloc, encoded.len - start);
            for (encoded[start..]) |bytes| self.streamed.appendAssumeCapacity(try self.alloc.dupe(u8, bytes));
        }
        try self.saveRunning(a, running);
    }

    /// The step whose calls are running: its calls in their saved form, and
    /// the text of the message that issued them.
    pub const Running = struct {
        calls: []const types.ToolCall = &.{},
        assistant: ?[]const u8 = null,
    };

    /// Saves the calls not yet saved as running in the open turn, which the
    /// pieces above have just opened if it was not. A step's first save also
    /// keeps its message's text as an `assistant_running` item (D51). Not
    /// its provider replay, which binds to all of that message's calls.
    fn saveRunning(self: *Session, a: Allocator, running: Running) !void {
        var batch: std.ArrayList(sm.Event) = .empty;
        var ids: std.ArrayList([]const u8) = .empty;
        for (running.calls) |call| {
            if (self.isRunning(call.id)) continue;
            const bytes = try encodePiece(a, .{ .tool_call = conversationToolCall(call) });
            try batch.append(a, .{ .item = try self.itemAs(a, running_type, bytes) });
            try ids.append(a, call.id);
        }
        if (batch.items.len == 0) return;
        const text = running.assistant orelse "";
        if (text.len > 0) {
            const bytes = try encodePiece(a, .{ .assistant = .{ .text = text } });
            try batch.insert(a, 0, .{ .item = try self.itemAs(a, running_assistant_type, bytes) });
        }
        _ = try self.write(batch.items);
        try self.running.ensureUnusedCapacity(self.alloc, ids.items.len);
        for (ids.items) |call_id| self.running.appendAssumeCapacity(try self.alloc.dupe(u8, call_id));
    }

    fn isRunning(self: *const Session, call_id: []const u8) bool {
        for (self.running.items) |running_id| if (std.mem.eql(u8, running_id, call_id)) return true;
        return false;
    }

    /// A copy of `execution` in which each tool result without a result file
    /// has the one the commit gives it (`session_log.externalizeConversationTurnResults`):
    /// the same handle, size and preview, so its streamed piece is the
    /// committed one. A result backed only by its command replay has no file
    /// before then. Each file is written once a turn.
    fn withResultFiles(self: *Session, a: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        var copy = execution;
        copy.tool_steps = try a.dupe(types.ToolExecutionStep, execution.tool_steps);
        for (copy.tool_steps) |*step| {
            step.tool_results = try a.dupe(types.PersistedToolResult, step.tool_results);
            for (step.tool_results) |*result| {
                if (result.output_handle != null) continue;
                const handle = self.stored_results.get(result.tool_call_id) orelse blk: {
                    const stored = try result_store.storeLargeResultManaged(self.alloc, try self.capabilityLocked(), result.tool_call_id, result.tool_name, result.output);
                    errdefer self.alloc.free(stored);
                    const key = try self.alloc.dupe(u8, result.tool_call_id);
                    errdefer self.alloc.free(key);
                    try self.stored_results.put(self.alloc, key, stored);
                    break :blk stored;
                };
                // Copied: a superseded turn frees the cache before its pieces are written.
                result.output_handle = try a.dupe(u8, handle);
                result.stored_output_bytes = result.output.len;
                if (result.preview == null) result.preview = try result_store.previewText(a, result.output, result_store.preview_bytes);
            }
        }
        return copy;
    }

    /// Appends `events` (already encoded) as items, then `tail`, starting
    /// the turn first if none is open. One durable batch, except that a
    /// blob needs a published session with an open turn before it.
    fn writePieces(self: *Session, a: Allocator, events: []const Event, encoded: []const []u8, tail: []const sm.Event) !void {
        var batch: std.ArrayList(sm.Event) = .empty;
        if (!self.turn_open) {
            try batch.append(a, .turn_started);
            const needs_blob = for (encoded) |bytes| {
                if (bytes.len > max_inline_piece_bytes) break true;
            } else false;
            if (needs_blob) {
                _ = try self.write(batch.items);
                self.startedTurn();
                batch.clearRetainingCapacity();
            }
        }
        for (events, encoded) |event, bytes| try batch.append(a, .{ .item = try self.item(a, std.meta.activeTag(event), bytes) });
        try batch.appendSlice(a, tail);
        if (batch.items.len == 0) return;
        _ = try self.write(batch.items);
        if (!self.turn_open) self.startedTurn();
    }

    fn startedTurn(self: *Session) void {
        self.last_turn += 1;
        self.turn_open = true;
    }

    // -- a conversion's import (D56) -----------------------------------------

    /// Writes a turn as v1 framed it: its pieces, then its end. One v1
    /// never ended gets the end v1's next writable open gives it, a failed
    /// interruption.
    fn importFramed(self: *Session, a: Allocator, events: []const Event, open: bool) !void {
        const all = if (open) try std.mem.concat(a, Event, &.{ events, &.{.{ .interrupted = .{ .reason = .failed } }} }) else events;
        try self.importTurn(a, all);
    }

    /// Writes a whole turn with its bodies as blobs, as a commit does.
    fn importWhole(self: *Session, a: Allocator, turn: types.HistoryTurn) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var copy = turn;
        const stores = switch (copy) {
            .assistant => |entry| storesBodies(entry.execution),
            .interrupted => |entry| storesBodies(entry.execution),
            .compacted_summary => return error.InvalidConversationFrame,
        };
        if (stores) try self.openTurnLocked();
        try session_log.externalizeConversationTurnResults(a, &copy, try self.capabilityLocked());
        var events: std.ArrayList(Event) = .empty;
        try session_event.appendHistoryTurnConversationEvents(a, &events, copy);
        try self.importTurn(a, events.items);
    }

    /// `events`, a turn's pieces, ended by the last one.
    fn importTurn(self: *Session, a: Allocator, events: []const Event) !void {
        if (events.len < 2) return error.InvalidConversationFrame;
        const encoded = try a.alloc([]u8, events.len);
        for (events, encoded) |event, *bytes| bytes.* = try encodePiece(a, event);
        const end: sm.Event = switch (events[events.len - 1]) {
            .turn_completed => .turn_committed,
            .interrupted => |interruption| .{ .turn_interrupted = switch (interruption.reason) {
                .cancelled => .cancel,
                .failed => .failed,
            } },
            else => return error.InvalidConversationFrame,
        };
        try self.writePieces(a, events, encoded, &.{end});
        self.turn_open = false;
    }

    /// Lets go of an import, published or not. A published one is opened
    /// again as any session is.
    fn dropImport(self: *Session) void {
        self.host.detach();
        self.handle.release();
        self.destroyInner();
    }

    /// How many of `encoded` the open turn already holds. A streamed piece
    /// that differs from the final turn is a bug; the stale turn is closed
    /// as superseded and the whole turn is written afresh, never mixed.
    fn streamedPrefix(self: *Session, encoded: []const []u8) !usize {
        if (!self.turn_open) return 0;
        const streamed = self.streamed.items;
        const same = streamed.len <= encoded.len and (for (streamed, encoded[0..streamed.len]) |x, y| {
            if (!samePiece(self.alloc, x, y)) break false;
        } else true);
        if (same) return streamed.len;
        debug_trace.logf("session", "event=sessions_v2_stream_mismatch session={s} streamed={d} final={d} dropped=stale_turn", .{ self.id(), streamed.len, encoded.len });
        _ = try self.write(&.{
            .{ .item = .{ .type = superseded_type, .data = "{}" } },
            .{ .turn_interrupted = .failed },
        });
        self.turn_open = false;
        self.clearStreamed();
        return 0;
    }

    /// One piece as an item; a large one goes to a blob.
    fn item(self: *Session, a: Allocator, kind: PieceKind, bytes: []u8) !sm.Piece {
        return self.itemAs(a, itemType(kind) orelse return error.InvalidConversationFrame, bytes);
    }

    fn itemAs(self: *Session, a: Allocator, item_type: []const u8, bytes: []u8) !sm.Piece {
        if (bytes.len <= max_inline_piece_bytes) return .{ .type = item_type, .data = bytes };
        const hash = try self.handle.putBlob(bytes);
        const hash_copy = try a.dupe(u8, &hash);
        const refs = try a.alloc([]const u8, 1);
        refs[0] = hash_copy;
        return .{
            .type = item_type,
            .data = try std.fmt.allocPrint(a, "{{\"{s}\":\"{s}\"}}", .{ blob_ref_key, hash_copy }),
            .blobs = refs,
        };
    }

    // -- compaction ----------------------------------------------------------

    /// Records a compaction. The history after it starts with the summary,
    /// then the retained turns, which the log already holds.
    pub fn commitCompaction(
        self: *Session,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: bool,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const cut = retained_from orelse types.ContextHistoryCut{ .turns = self.turn_numbers.items.len };
        const first_kept = turnSlot(self.turn_numbers.items, cut.turns);
        var keep_from: ?u64 = null;
        for (self.turn_numbers.items[first_kept..]) |number| {
            if (number) |n| {
                keep_from = n;
                break;
            }
        }
        if (keep_from == null and active_prefix and self.turn_open) keep_from = self.last_turn;
        if (cut.tool_steps != 0 or cut.steering != 0) {
            debug_trace.logf("session", "event=sessions_v2_compaction_cut session={s} kept=whole_turn tool_steps={d} steering={d}", .{ self.id(), cut.tool_steps, cut.steering });
        }
        const data: CompactedData = .{
            .summary = summary.summary,
            .removed_turn_count = summary.removed_turn_count,
            .compaction_count = summary.compaction_count,
            .keep_from_turn = keep_from,
        };
        _ = try self.write(&.{.{ .compacted = try jsonValue(arena.allocator(), data) }});
        // fx's history is now the summary, then the retained turns.
        var kept: std.ArrayList(?u64) = .empty;
        errdefer kept.deinit(self.alloc);
        try kept.append(self.alloc, null);
        try kept.appendSlice(self.alloc, self.turn_numbers.items[first_kept..]);
        self.turn_numbers.deinit(self.alloc);
        self.turn_numbers = kept;
    }

    /// Where fx's raw history turn `turn` sits in `numbers`. A compaction cut
    /// counts only raw turns, while `numbers` also holds the summary's slot.
    /// Returns `numbers.len` when the history has no such turn.
    fn turnSlot(numbers: []const ?u64, turn: usize) usize {
        var seen: usize = 0;
        for (numbers, 0..) |number, slot| {
            if (number == null) continue;
            if (seen == turn) return slot;
            seen += 1;
        }
        return numbers.len;
    }

    // -- settings ------------------------------------------------------------

    pub fn setPreferences(self: *Session, preferences: session_codec.DurableSessionPreferences) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = try self.write(&.{.{ .set = .{ .key = .prefs, .value = try encodePreferences(arena.allocator(), preferences, self.instructions) } }});
    }

    // -- children (D22) ------------------------------------------------------

    /// Every child of this session as its log folds them, in first-spawn
    /// order. Free with `freeChildren`.
    pub fn children(self: *Session, alloc: Allocator) ![]Child {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const state = try self.handle.state(scratch.allocator());
        const out = try alloc.alloc(Child, state.children.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |child| freeChild(alloc, child);
            alloc.free(out);
        }
        for (state.children.items) |child| {
            const id_copy = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id_copy);
            const work_copy = try alloc.dupe(u8, child.work_id);
            errdefer alloc.free(work_copy);
            const spawn_copy = if (child.spawn_data) |data| try alloc.dupe(u8, data) else null;
            errdefer if (spawn_copy) |data| alloc.free(data);
            out[built] = .{
                .id = id_copy,
                .work_id = work_copy,
                .open = child.open,
                .outcome = child.outcome,
                .spawn_data = spawn_copy,
                .finish_data = if (child.finish_data) |data| try alloc.dupe(u8, data) else null,
                .seq = child.seq,
            };
            built += 1;
        }
        return out;
    }

    /// Appends child lines as one durable batch. The manager refuses a spawn
    /// while that child has unfinished work, and a finish for other work.
    pub fn appendChildLines(self: *Session, lines: []const ChildLine) !void {
        if (lines.len == 0) return;
        const events = try self.alloc.alloc(sm.Event, lines.len);
        defer self.alloc.free(events);
        for (lines, events) |line, *event| event.* = switch (line) {
            .spawned => |spawned| .{ .child_spawned = .{ .child = spawned.child, .work_id = spawned.work_id, .data = spawned.data } },
            .finished => |finished| .{ .child_finished = .{ .child = finished.child, .work_id = finished.work_id, .outcome = finished.outcome, .data = finished.data } },
        };
        _ = try self.write(events);
    }

    pub fn setPermissions(self: *Session, state: session_permission_state.State) !void {
        const value = try session_codec.encodePermissionState(self.alloc, state);
        defer self.alloc.free(value);
        _ = try self.write(&.{.{ .set = .{ .key = .permissions, .value = value } }});
    }

    // -- an ACP client's settings (D46) ---------------------------------------

    /// The system prompt the ACP client gave this session, or null. Caller
    /// owns it.
    pub fn clientPrompt(self: *Session, alloc: Allocator) !?[]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).client_prompt orelse return null;
        return try alloc.dupe(u8, try std.json.parseFromSliceLeaky([]const u8, sa, raw, .{}));
    }

    /// Keeps the ACP client's system prompt with the session; the same
    /// prompt again writes nothing.
    pub fn setClientPrompt(self: *Session, text: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        try self.putSetting(scratch.allocator(), .client_prompt, try jsonString(scratch.allocator(), text));
    }

    /// The MCP tool identities this ACP session recorded for replay, as
    /// their JSON object, or null. Caller owns it.
    pub fn toolIdentities(self: *Session, alloc: Allocator) !?[]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const raw = (try self.handle.state(scratch.allocator())).tool_identities orelse return null;
        return try alloc.dupe(u8, raw);
    }

    /// Keeps the session's tool identity record, a JSON object; the same
    /// record again writes nothing.
    pub fn setToolIdentities(self: *Session, record_json: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        try self.putSetting(scratch.allocator(), .tool_identities, record_json);
    }

    /// Writes `key` only when its value changed, in `sa`.
    fn putSetting(self: *Session, sa: Allocator, key: sm.SetKey, value: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const state = try self.handle.state(sa);
        const current = switch (key) {
            .client_prompt => state.client_prompt,
            .tool_identities => state.tool_identities,
            else => unreachable,
        };
        if (current) |stored| if (std.mem.eql(u8, stored, value)) return;
        _ = try self.write(&.{.{ .set = .{ .key = key, .value = value } }});
    }

    /// A title the user chose. It differs from the derived one, so a
    /// generated title never replaces it.
    pub fn rename(self: *Session, title: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const value = try jsonString(self.alloc, title);
        defer self.alloc.free(value);
        _ = try self.write(&.{.{ .set = .{ .key = .title, .value = value } }});
        self.titled = true;
    }

    /// v1's rule: a generated title never replaces one the user chose, only
    /// none or the one derived from the first message.
    pub fn installGeneratedTitle(self: *Session, history: []const types.HistoryTurn, title: []const u8) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var state = try self.handle.state(a);
        defer state.deinit(a);
        if (state.title) |raw| {
            const current = try std.json.parseFromSliceLeaky([]const u8, a, raw, .{});
            var display = try session_display_metadata.deriveFromHistory(a, history);
            defer display.deinit(a);
            if (!display.present or !std.mem.eql(u8, current, display.title)) {
                debug_trace.logf("session", "event=title_generation_apply result=dropped reason=user_title_present", .{});
                return false;
            }
        }
        _ = try self.write(&.{.{ .set = .{ .key = .title, .value = try jsonString(a, title) } }});
        self.titled = true;
        return true;
    }

    // -- usage ---------------------------------------------------------------

    /// Saves a usage checkpoint with v1's marker rules: a checkpoint that
    /// still owes the profile ledger is covered by a marker written first
    /// (keeping the time of the first such checkpoint), and the marker goes
    /// once a durable checkpoint owes nothing (`tla/Wiring.tla`
    /// UsageNeverSilent).
    pub fn persistUsage(self: *Session, snapshot: session_usage.Snapshot) !void {
        const now_ms = @max(io_mod.milliTimestamp(), 0);
        const at_ms = if (now_ms > self.usage_at_ms) now_ms else try std.math.add(i64, self.usage_at_ms, 1);
        const pending = session_usage.needsProfileRecovery(snapshot);
        if (pending and !self.usage_marked) {
            try self.writeUsageMarker(at_ms);
            self.usage_marked = true;
        }
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const value = try encodeUsage(arena.allocator(), snapshot, at_ms);
        _ = try self.write(&.{.{ .set = .{ .key = .usage, .value = value } }});
        self.usage_at_ms = at_ms;
        if (pending) return;
        // Before the first turn a `set` waits in memory, not on disk.
        if (!self.saved()) return;
        self.clearUsageMarker();
        self.usage_marked = false;
    }

    fn writeUsageMarker(self: *Session, now_ms: i64) !void {
        return self.store.writeUsageMarker(self.alloc, self.id(), now_ms);
    }

    fn clearUsageMarker(self: *Session) void {
        var dir = self.store.openUsageMarkers() catch |err| {
            debug_trace.logf("session", "event=sessions_v2_usage_marker_kept session={s} err={s}", .{ self.id(), @errorName(err) });
            return;
        };
        defer dir.close();
        dir.dir.deleteFile(io_mod.getIo(), self.id()) catch |err| switch (err) {
            error.FileNotFound => {},
            else => debug_trace.logf("session", "event=sessions_v2_usage_marker_kept session={s} err={s}", .{ self.id(), @errorName(err) }),
        };
    }

    // -- resume --------------------------------------------------------------

    /// Rebuilds fx's history and settings from the open log (`restoreFrom`),
    /// and keeps what later appends compare against: the last turn, the turn
    /// behind each history entry, and the stored usage and language.
    pub fn restore(self: *Session, alloc: Allocator) !Restored {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const state = try self.handle.state(sa);
        self.last_turn = state.last_turn;
        self.turn_numbers.clearRetainingCapacity();
        var restored = try restoreFrom(self.source(), alloc, sa, state, .{ .alloc = self.alloc, .list = &self.turn_numbers });
        errdefer restored.deinit(alloc);
        if (self.first_title) |value| self.alloc.free(value);
        self.first_title = null;
        if (self.root and state.title == null) {
            if (try deriveTitle(sa, restored.history)) |title| self.first_title = try self.alloc.dupe(u8, title);
        }
        if (state.usage) |raw| {
            const checkpoint = try decodeUsage(sa, raw);
            self.usage_at_ms = checkpoint.at_ms;
            self.usage_marked = session_usage.needsProfileRecovery(checkpoint.snapshot);
        }
        if (state.language != null) {
            const owned = try self.alloc.dupe(u8, restored.language.view());
            if (self.language) |old| self.alloc.free(old);
            self.language = owned;
        }
        return restored;
    }

    /// Hands `visitor.append` every turn in the log, oldest first, as v1's
    /// conversation reader does: a compaction hides no turn from the
    /// transcript. Each turn is freed after its call, and pages are freed as
    /// they are read, so memory stays bounded by one page and one turn.
    /// Leaves the state resume keeps untouched. It reads only through the
    /// manager's thread-safe handle and changes no adapter state, so it
    /// takes no lock: a visitor may call back into this session, as the app
    /// does to read a command replay's side file while it draws a turn.
    pub fn visitHistory(self: *Session, alloc: Allocator, visitor: anytype) !void {
        const Sink = struct {
            alloc: Allocator,
            visitor: @TypeOf(visitor),

            fn turn(sink: *@This(), value: types.HistoryTurn, _: ?u64) !void {
                defer types.freeHistoryTurn(sink.alloc, value);
                try sink.visitor.append(value);
            }

            /// The transcript shows turns only, as v1's does.
            fn summary(_: *@This(), _: []const u8) !void {}
        };
        var sink: Sink = .{ .alloc = alloc, .visitor = visitor };
        try replay(self.source(), alloc, alloc, .start, null, ReplaySink.init(&sink));
    }

    /// The session as v1's `DurableSessionState`, for hosts that restore
    /// through it, and its stored title. Caller owns both.
    pub fn durableState(self: *Session, alloc: Allocator, workspace: []const u8) !Resumed {
        var restored = try self.restore(alloc);
        defer restored.deinit(alloc);
        return resumedOf(alloc, &restored, self.id(), workspace);
    }

    pub const Info = struct {
        /// The stored title, decoded; owned by the caller.
        title: ?[]u8,
        /// The time of the newest line; 0 before the first turn.
        updated_ms: i64,
    };

    /// What a host shows about the open session.
    pub fn info(self: *Session, alloc: Allocator) !Info {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const st = try self.handle.state(sa);
        const title = if (st.title) |raw| try alloc.dupe(u8, try std.json.parseFromSliceLeaky([]const u8, sa, raw, .{})) else null;
        return .{ .title = title, .updated_ms = std.math.cast(i64, st.updated_ms) orelse 0 };
    }

    fn source(self: *Session) Source {
        return .{ .store = self.store, .id = self.id(), .handle = self.handle, .host = self.host, .files_path = self.files_path };
    }

    // -- the move off the side folder (D47) -----------------------------------

    /// Makes an older session one manager folder (D47, `tla/MoveSideFiles.tla`)
    /// on its first writable open, then loads the map its old handles resolve
    /// through. Every body in the side folder becomes a blob, the map from
    /// each old name to its blob is one more blob, and one batch records the
    /// map, every moved blob, and the client's settings from the old files.
    /// Then the terminal folder moves to `~/.fx/terminal/{id}` and the side
    /// folder goes. Each step can be repeated, so a crash at any point
    /// redoes the move on the next open.
    fn openMoved(self: *Session) !void {
        try self.moveSideFiles();
        try self.loadMovedMap();
        try self.loadRecords();
    }

    fn moveSideFiles(self: *Session) !void {
        var files_root = (try self.store.openProfileFolder(files_dir_name)) orelse return;
        defer files_root.close();
        const bodies = blk: {
            var side = (try io_mod.openVerifiedPrivateDirIfPresent(&files_root, self.id())) orelse return;
            defer side.close();
            break :blk try self.moveOut(&side);
        };
        files_root.dir.deleteTree(io_mod.getIo(), self.id()) catch |err| {
            // The next open redoes the move; every step is repeatable.
            debug_trace.logf("session", "event=sessions_v2_move_folder_kept session={s} err={s}", .{ self.id(), @errorName(err) });
            return;
        };
        debug_trace.logf("session", "event=sessions_v2_moved session={s} bodies={d}", .{ self.id(), bodies });
    }

    /// Every step of the move but the side folder's removal, in the order
    /// `tla/MoveSideFiles.tla` checks; returns how many bodies moved.
    fn moveOut(self: *Session, side: *io_mod.VerifiedDir) !usize {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const lines = try sideFileLines(scratch.allocator(), self.handle, side, &moved_body_folders, &.{}, &.{});
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            _ = try self.write(lines.events);
        }

        try self.moveTerminalFolder(side);
        return lines.bodies;
    }

    /// Renames `side/terminal` to `~/.fx/terminal/{id}/terminal`, the layout
    /// the terminal store keeps (D45). A terminal folder already there was
    /// moved by an earlier try.
    fn moveTerminalFolder(self: *Session, side: *io_mod.VerifiedDir) !void {
        const io = io_mod.getIo();
        _ = side.dir.statFile(io, terminal_dir_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var root = try self.store.makeProfileFolder(terminal_dir_name);
        defer root.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, self.id());
        defer owner.close();
        if (owner.dir.statFile(io, terminal_dir_name, .{ .follow_symlinks = false })) |_| {
            debug_trace.logf("session", "event=sessions_v2_move_terminal_kept session={s} reason=already_moved", .{self.id()});
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.Dir.rename(side.dir, terminal_dir_name, owner.dir, terminal_dir_name, io);
        io_mod.syncVerifiedDir(owner.dir) catch |err| debug_trace.logf("session", "event=sessions_v2_move_terminal_unsynced session={s} err={s}", .{ self.id(), @errorName(err) });
    }

    /// Reads the map a moved session's old names resolve through, once.
    fn loadMovedMap(self: *Session) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).moved_files orelse return;
        const Value = struct { map: []const u8 };
        const value = std.json.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its old handles read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_moved_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
        const host = self.host;
        try host.moved.ensureUnusedCapacity(host.alloc, @intCast(map.map.count()));
        for (map.map.keys(), map.map.values()) |key, hash| {
            if (key.len > movedKeyMax or hash.len != artifact_digest.blob_hex_bytes) return error.InvalidSessionFormat;
            if (host.moved.contains(key)) continue;
            host.moved.putAssumeCapacity(try host.alloc.dupe(u8, key), hash[0..artifact_digest.blob_hex_bytes].*);
        }
    }

    /// Reads the compactor's records map (D50), once, as `loadMovedMap` reads
    /// the move's.
    fn loadRecords(self: *Session) !void {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const raw = (try self.handle.state(sa)).compaction_records orelse return;
        const Value = struct { map: []const u8 };
        const value = std.json.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its records read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_records_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
        const host = self.host;
        host.mutex.lockUncancelable(io_mod.getIo());
        defer host.mutex.unlock(io_mod.getIo());
        try host.records.ensureUnusedCapacity(host.alloc, map.map.count());
        for (map.map.keys(), map.map.values()) |name, hash| {
            session_child_store.SessionChildCapability.validateManagedName(name) catch return error.InvalidSessionFormat;
            if (hash.len != artifact_digest.blob_hex_bytes) return error.InvalidSessionFormat;
            if (host.records.contains(name)) continue;
            host.records.putAssumeCapacity(try host.alloc.dupe(u8, name), hash[0..artifact_digest.blob_hex_bytes].*);
        }
    }
};

/// The side-folder layouts an older session kept its bodies in (D47); the
/// first three are `movedFolder`'s, and `images` holds prompt images.
/// The folders whose files become blobs on a move or a conversion. A
/// converted v1 session's images go inside its prompts instead (D44).
const body_folders = [_][]const u8{ "tool-results", "logs/commands", "artifacts/web-fetch" };
const moved_body_folders = body_folders ++ [_][]const u8{"images"};

const SideFileLines = struct {
    events: []const sm.Event,
    bodies: usize,
};

/// The `set` lines that carry a side folder into `handle` (D46, D47): each
/// file of `folders` but those `left_out` names (`{folder}/{name}`, D62),
/// and each of `stored` (results an older format kept inline), put as a
/// blob and named in the moved map, which is one more blob, and the ACP
/// client's files. In `a`.
fn sideFileLines(a: Allocator, handle: sm.Session, side: *io_mod.VerifiedDir, folders: []const []const u8, stored: []const v1_conversion.Stored, left_out: []const []const u8) !SideFileLines {
    const io = io_mod.getIo();
    var bodies: std.ArrayList(Body) = .empty;
    var dirs: std.ArrayList(std.Io.Dir) = .empty;
    defer for (dirs.items) |dir| dir.close(io);
    for (folders) |folder| try listFolder(a, handle, side, folder, &dirs, &bodies);
    var kept: usize = 0;
    for (bodies.items) |body| {
        for (left_out) |key| {
            if (std.mem.eql(u8, key, body.key)) break;
        } else {
            bodies.items[kept] = body;
            kept += 1;
        }
    }
    bodies.shrinkRetainingCapacity(kept);
    try putBodies(handle, bodies.items);
    var moved: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try moved.ensureTotalCapacity(a, bodies.items.len + stored.len);
    for (bodies.items) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &body.hash));
    for (stored) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &(try handle.putBlob(body.bytes))));
    var map_json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(std.json.ArrayHashMap([]const u8){ .map = moved }, .{}, &map_json.writer);
    const map_hash = try a.dupe(u8, &(try handle.putBlob(map_json.written())));

    var events: std.ArrayList(sm.Event) = .empty;
    const value = try std.fmt.allocPrint(a, "{{\"map\":\"{s}\"}}", .{map_hash});
    // One line per chunk of blobs keeps each line well under the limit;
    // the last one names the map, so the value is the same on each.
    var refs: std.ArrayList([]const u8) = .empty;
    try refs.appendSlice(a, moved.values());
    try refs.append(a, map_hash);
    var rest = refs.items;
    while (rest.len > 0) {
        const take = @min(rest.len, moved_refs_per_line);
        try events.append(a, .{ .set = .{ .key = .moved_files, .value = value, .blobs = rest[0..take] } });
        rest = rest[take..];
    }
    if (try readSideFile(a, side, moved_client_prompt_file, moved_client_prompt_max)) |text| {
        if (std.unicode.utf8ValidateSlice(text)) {
            try events.append(a, .{ .set = .{ .key = .client_prompt, .value = try jsonString(a, text) } });
        } else debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} file={s} reason=not_utf8", .{ handle.id(), moved_client_prompt_file });
    }
    if (try readSideFile(a, side, moved_tool_identities_file, moved_tool_identities_max)) |record| {
        if (isJsonObject(a, record)) {
            try events.append(a, .{ .set = .{ .key = .tool_identities, .value = record } });
        } else debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} file={s} reason=not_a_json_object", .{ handle.id(), moved_tool_identities_file });
    }
    return .{ .events = events.items, .bodies = moved.count() };
}

/// A side file to put as a blob, named `key` (`{folder}/{name}`) in the
/// moved map.
const Body = struct {
    dir: std.Io.Dir,
    name: []const u8,
    key: []const u8,
    hash: BlobHost.Hash = undefined,
};

/// Lists each regular file of `side/{folder}`, keeping the folder open in
/// `dirs`. Anything else there is not fx's and is left for the side
/// folder's removal, with a trace.
fn listFolder(a: Allocator, handle: sm.Session, side: *io_mod.VerifiedDir, folder: []const u8, dirs: *std.ArrayList(std.Io.Dir), bodies: *std.ArrayList(Body)) !void {
    const io = io_mod.getIo();
    try dirs.ensureUnusedCapacity(a, 1);
    const dir = side.dir.openDir(io, folder, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dirs.appendAssumeCapacity(dir);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len > 160) {
            debug_trace.logf("session", "event=sessions_v2_move_dropped session={s} folder={s} kind={s}", .{ handle.id(), folder, @tagName(entry.kind) });
            continue;
        }
        try bodies.append(a, .{ .dir = dir, .name = try a.dupe(u8, entry.name), .key = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, entry.name }) });
    }
}

const PutBodyError = sm.AppendError || std.Io.File.OpenError || std.Io.File.StatError;

/// Puts `bodies` as blobs, a few at a time: each waits on its own syncs
/// (D44), which then overlap.
fn putBodies(handle: sm.Session, bodies: []Body) PutBodyError!void {
    const Putter = struct {
        handle: sm.Session,
        bodies: []Body,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        failure: PutBodyError = undefined,
        mutex: std.Io.Mutex = .init,

        fn run(putter: *@This()) void {
            while (!putter.failed.load(.acquire)) {
                const index = putter.next.fetchAdd(1, .monotonic);
                if (index >= putter.bodies.len) return;
                putter.put(&putter.bodies[index]) catch |err| {
                    putter.mutex.lockUncancelable(io_mod.getIo());
                    defer putter.mutex.unlock(io_mod.getIo());
                    if (!putter.failed.load(.monotonic)) putter.failure = err;
                    putter.failed.store(true, .release);
                };
            }
        }

        fn put(putter: *@This(), body: *Body) PutBodyError!void {
            const io = io_mod.getIo();
            var file = try body.dir.openFile(io, body.name, .{ .follow_symlinks = false });
            defer file.close(io);
            body.hash = try putter.handle.putBlobFile(file, (try file.stat(io)).size);
        }
    };
    var putter: Putter = .{ .handle = handle, .bodies = bodies };
    var threads: [3]?std.Thread = @splat(null);
    for (&threads, 1..) |*thread, count| {
        if (bodies.len <= count) break;
        // Without a thread the others, and this one, do its share.
        thread.* = std.Thread.spawn(.{}, Putter.run, .{&putter}) catch null;
    }
    putter.run();
    for (threads) |thread| if (thread) |value| value.join();
    if (putter.failed.load(.acquire)) return putter.failure;
}
/// The side files an ACP client's settings came from, as `acp`'s
/// `client_instructions.file_name` and `tool_call_identities.file_name`
/// name them under the `client` folder (D46).
pub const moved_client_prompt_file = "client/system-prompt.txt";
pub const moved_tool_identities_file = "client/mcp-tool-identities.json";
const moved_client_prompt_max = 64 * 1024;
const moved_tool_identities_max = 256 * 1024;
/// Blobs listed on one `moved_files` line: about 270 KiB of hashes.
const moved_refs_per_line = 4096;

/// A side file's bytes, or null when it is missing; at most `max_bytes`.
fn readSideFile(a: Allocator, side: *io_mod.VerifiedDir, name: []const u8, max_bytes: usize) !?[]u8 {
    var file = side.dir.openFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(a, &file, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => {
            debug_trace.logf("session", "event=sessions_v2_move_dropped file={s} reason=too_large", .{name});
            return null;
        },
        else => err,
    };
}

fn isJsonObject(a: Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return false;
    return parsed == .object;
}

/// Where replay reads a log: an open session's own handle, or the store by
/// id without a lock, as for a finished child's result.
const Source = struct {
    store: *Store,
    id: []const u8,
    handle: ?sm.Session = null,
    /// An open session's blobs, for a moved session's old names (D47).
    host: ?*BlobHost = null,
    /// Where that session kept its side files before the move.
    files_path: ?[]const u8 = null,

    fn read(src: Source, sa: Allocator, from: sm.From, limit: usize) !sm.Page {
        return src.readTo(sa, from, .forward, limit);
    }

    fn readTo(src: Source, sa: Allocator, from: sm.From, direction: sm.Direction, limit: usize) !sm.Page {
        if (src.handle) |handle| return handle.read(sa, from, direction, limit);
        return src.store.manager.read(sa, src.id, from, direction, limit);
    }

    /// The cursor of `turn`'s `turn_started`, reading back from `before`.
    fn findTurnStart(src: Source, sa: Allocator, before: sm.Cursor, turn: u64) !sm.Cursor {
        var from: sm.From = .{ .at = before };
        while (true) {
            var page = try src.readTo(sa, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                if (body == .turn_started and body.turn_started.turn == turn) return .{ .offset = entry.offset, .seq = entry.seq };
            }
            from = .{ .at = page.next orelse return error.InvalidConversationFrame };
        }
    }

    /// `user` with the bytes of each image an older session kept in its side
    /// folder (D47), from its blob: inside the turn, as a v2 session keeps
    /// images now (D44). Other images are unchanged; an unreadable one keeps
    /// its old path, as a lost snapshot does.
    fn withMovedImages(src: Source, pa: Allocator, user: session_event.ConversationUser) !session_event.ConversationUser {
        const host = src.host orelse return user;
        const files_path = src.files_path orelse return user;
        if (host.moved.count() == 0) return user;
        var images: ?[]types.ImageAttachment = null;
        for (user.images, 0..) |image, index| {
            if (image.inline_data != null) continue;
            const path = image.snapshot_path orelse continue;
            if (path.len <= files_path.len + 1 or !std.mem.startsWith(u8, path, files_path) or path[files_path.len] != '/') continue;
            const hash = host.moved.get(path[files_path.len + 1 ..]) orelse continue;
            const bytes = src.store.manager.getBlob(pa, src.id, &hash) catch |err| {
                debug_trace.logf("session", "event=sessions_v2_moved_image_unreadable session={s} err={s}", .{ src.id, @errorName(err) });
                continue;
            };
            if (images == null) images = try pa.dupe(types.ImageAttachment, user.images);
            images.?[index].inline_data = bytes;
        }
        const list = images orelse return user;
        return .{ .text = user.text, .images = list, .work_id = user.work_id };
    }

    /// A piece's bytes, from its blob when the line holds a reference. The
    /// item may list more blobs, the stores' bodies (D44); the reference is
    /// the one its data names.
    fn pieceData(src: Source, pa: Allocator, piece: sm.Body.Piece) ![]const u8 {
        const hash = blobRefOf(piece.data) orelse return piece.data;
        const listed = for (piece.blobs) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        if (!listed) return piece.data;
        return src.store.manager.getBlob(pa, src.id, hash) catch |err| switch (err) {
            // A blob the log names that is gone or damaged damages the
            // session, as a bad line does (D39).
            error.NotFound, error.Corrupt => {
                debug_trace.logf("session", "event=sessions_v2_blob_unreadable session={s} err={s}", .{ src.id, @errorName(err) });
                return error.InvalidSessionFormat;
            },
            else => |e| return e,
        };
    }
};

// ---------------------------------------------------------------------------
// Converting v1 sessions (D55 to D61, `tla/V1Conversion.tla`)

/// A conversion that runs past this tells the host why the open is slow.
const slow_conversion_ns: i128 = 150 * std.time.ns_per_ms;
const slow_conversion_text = "Converting this session from the previous session format…";

/// What v2 keeps of a converted member's v1 source (`set v1_source`): the
/// fingerprint its removal checks (D60), and v1's usage marker as the copy
/// found it, when it could be read (D20).
const V1Source = struct {
    fingerprint: []const u8,
    marker: ?MovedMarker = null,
};

/// The v1 usage marker a member's copy took v1's verdict from, and the time
/// of the v2 marker that keeps that verdict (D20). The move happens only
/// while v1's marker is still this one (D62).
const MovedMarker = struct {
    v1: v1_conversion.MarkerId,
    ms: i64,
};

/// A side file a conversion leaves out (D62): larger than one v2 blob.
pub const LeftOut = struct {
    /// The family member that kept it in v1.
    member: []u8,
    /// `{folder}/{name}` in that member's v1 folder.
    file: []u8,
    bytes: u64,

    fn deinit(entry: LeftOut, alloc: Allocator) void {
        alloc.free(entry.member);
        alloc.free(entry.file);
    }

    /// What a host tells the user about it.
    fn note(entry: LeftOut, alloc: Allocator, root_id: []const u8) ![]u8 {
        if (std.mem.eql(u8, entry.member, root_id))
            return std.fmt.allocPrint(alloc, "This session was converted without {s}, which is {d} bytes, more than the {d} the new store keeps in one file.", .{ entry.file, entry.bytes, sm.max_blob_bytes });
        return std.fmt.allocPrint(alloc, "This session was converted without {s} of its subagent {s}, which is {d} bytes, more than the {d} the new store keeps in one file.", .{ entry.file, entry.member, entry.bytes, sm.max_blob_bytes });
    }
};

/// One family's conversion, in the order `tla/V1Conversion.tla` checks:
/// lock every member or answer busy (CBegin); once locked, see whether
/// another process converted it meanwhile, then sweep what a crashed try
/// left (CSweep, D61); stage every member, any unreadable one refusing the
/// whole family with nothing half converted (CStage); publish the children
/// and then the root (CPublishChild, CPublishRoot); for each member still
/// the copy converted, move its usage marker and then remove its v1 folder,
/// under its lock (MoveMark, DropMark, CDelete).
const Conversion = struct {
    store: *Store,
    alloc: Allocator,
    /// The host the publish stamps as having opened it (`publishImport`).
    host: Host,
    started: i128,
    noticed: bool = false,
    members: usize = 0,
    turns: usize = 0,
    files: usize = 0,
    /// The side files the first pass found too large to keep (D62).
    left_out: std.ArrayList(LeftOut) = .empty,

    const Outcome = enum { converted, held };

    fn deinit(c: *Conversion) void {
        for (c.left_out.items) |entry| entry.deinit(c.alloc);
        c.left_out.deinit(c.alloc);
    }

    /// A member ready to publish, or a child an earlier try already
    /// published, reused as it is (TLA `Orphan`).
    const Staged = struct {
        id: []const u8,
        session: ?*Session,
        marker: ?MovedMarker,
        /// Whether its v1 state goes once the root is published (TLA
        /// `Unchanged`): copied in this run, or reused while its v1 copy is
        /// the one converted.
        unchanged: bool = true,
    };

    /// A member the first pass checked (D62): a child an earlier try
    /// published, reused as it is, or one to stage, whose read only a family
    /// of one keeps, so that family is read once.
    const Checked = union(enum) {
        reused: Staged,
        read: ?Read,
    };

    const Read = struct {
        member: v1_conversion.Member,
        marker: ?MovedMarker,
    };

    fn family(c: *Conversion, root_id: []const u8, wait_ms: u64) !Outcome {
        const store = c.store;
        store.problem = .{};
        var v1 = try session_store.Store.initReadOnlyFromHome(c.alloc, store.home, "/");
        defer v1.deinit(c.alloc);
        const kind = v1_conversion.kindOf(&v1, c.alloc, root_id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                v1_conversion.kindProblem(&v1, c.alloc, root_id, err, &store.problem) catch {};
                c.traceUnreadable(root_id, root_id);
                return error.InvalidSessionFormat;
            },
        };
        if (kind != .root) return error.SessionNotFound;
        var locks = v1_conversion.lockFamily(c.alloc, &v1, root_id, wait_ms, &store.problem) catch |err| {
            switch (err) {
                error.SessionBusy => debug_trace.logf("convert", "action=Busy session={s}", .{root_id}),
                error.InvalidSessionFormat => c.traceUnreadable(root_id, root_id),
                // Another process converted it while this one waited, and
                // removed its v1 folder once v2 held it (D61).
                error.SessionNotFound => if (holdsV2(store, c.alloc, root_id)) return traceHeld(root_id),
                else => {},
            }
            return err;
        };
        defer locks.release();
        if (holdsV2(store, c.alloc, root_id)) return traceHeld(root_id);
        try c.sweep(&v1, &locks);

        // Every member to copy is checked before any is staged, keeping
        // nothing (TLA CStage, D62), so one v1 cannot read refuses the family
        // with nothing staged; then each is read again and staged in turn,
        // so memory holds one member at a time.
        const members = locks.members.items;
        var checked: std.ArrayList(Checked) = .empty;
        defer {
            for (checked.items) |*item| if (item.* == .read) if (item.read) |*read| read.member.deinit();
            checked.deinit(c.alloc);
        }
        try checked.ensureTotalCapacity(c.alloc, members.len);
        for (members, 0..) |*member, index| checked.appendAssumeCapacity(try c.check(&v1, member, root_id, index == 0, members.len == 1));

        var staged: std.ArrayList(Staged) = .empty;
        defer staged.deinit(c.alloc);
        errdefer for (staged.items) |member| c.discard(member);
        defer for (staged.items) |member| if (member.session) |session| session.dropImport();
        try staged.ensureTotalCapacity(c.alloc, members.len);
        // The children first: the root's child lines name them.
        for (members[1..], checked.items[1..]) |*member, *item| {
            const instructions = childInstructionsOf(locks.registry, member.id);
            staged.appendAssumeCapacity(try c.stage(&v1, item, member, .{ .child = .{ .parent = root_id, .instructions = instructions } }));
        }
        const has_log = try c.alloc.alloc(bool, locks.registry.children.len);
        defer c.alloc.free(has_log);
        for (locks.registry.children, has_log) |child, *logged| logged.* = locks.isMember(child.id);
        staged.appendAssumeCapacity(try c.stage(&v1, &checked.items[0], &members[0], .{ .root = .{ .registry = &locks.registry, .has_log = has_log } }));
        c.phase();

        for (staged.items, 0..) |member, index| {
            const session = member.session orelse continue;
            try session.handle.publishImport();
            const root = index == staged.items.len - 1;
            debug_trace.logf("convert", "action={s} session={s} member={s}", .{ if (root) "PublishedRoot" else "PublishedChild", root_id, member.id });
        }
        c.phase();
        // The root's v1 state first, so v1 stops listing the family.
        c.removeMember(&v1, root_id, staged.items[staged.items.len - 1]);
        for (staged.items[0 .. staged.items.len - 1]) |member| c.removeMember(&v1, root_id, member);
        c.members = members.len;
        return .converted;
    }

    fn traceHeld(root_id: []const u8) Outcome {
        debug_trace.logf("convert", "action=Held session={s}", .{root_id});
        return .held;
    }

    /// Removes a published member's v1 state while it is the copy converted
    /// (MoveMark, DropMark, CDelete).
    fn removeMember(c: *Conversion, v1: *session_store.Store, root_id: []const u8, member: Staged) void {
        if (!member.unchanged) {
            debug_trace.logf("convert", "action=KeptV1 session={s} member={s}", .{ root_id, member.id });
            return;
        }
        _ = removeV1State(c.store, c.alloc, v1, member.id, member.marker, "converted");
    }

    /// Empties the trash and drops the unpublished staging of every member
    /// and of each child the root names whose folder is gone (TLA CSweep),
    /// under the family's locks (D61).
    fn sweep(c: *Conversion, v1: *session_store.Store, locks: *const v1_conversion.Family) !void {
        const root_id = locks.members.items[0].id;
        v1_conversion.emptyTrash(c.alloc, v1);
        for (locks.members.items) |member| try c.sweepOne(root_id, member.id);
        for (locks.absent.items) |id| try c.sweepOne(root_id, id);
        debug_trace.logf("convert", "action=Swept session={s} members={d} absent={d}", .{ root_id, locks.members.items.len, locks.absent.items.len });
    }

    fn sweepOne(c: *Conversion, root_id: []const u8, id: []const u8) !void {
        c.store.manager.discardImport(id) catch |err| switch (err) {
            error.InvalidArgument => return c.refuse(root_id, id, "the session id {s} is not one the new store can keep", .{id}),
            else => return conversionStorageFailed("sweep", err),
        };
    }

    const Role = union(enum) {
        root: struct { registry: *const child_state.Registry, has_log: []const bool },
        child: struct { parent: []const u8, instructions: ?[]const u8 },
    };

    /// Checks one locked member, or finds the child an earlier try
    /// published. Keeps its read only when `keep`.
    fn check(c: *Conversion, v1: *session_store.Store, locked: *v1_conversion.Locked, root_id: []const u8, is_root: bool, keep: bool) !Checked {
        if (!is_root) if (try c.reusedOrphan(locked)) |kept| return .{ .reused = kept };
        var read = try c.load(v1, locked, root_id);
        errdefer read.member.deinit();
        try c.findLeftOut(root_id, locked);
        c.phase();
        if (keep) return .{ .read = read };
        read.member.deinit();
        return .{ .read = null };
    }

    fn load(c: *Conversion, v1: *session_store.Store, locked: *v1_conversion.Locked, root_id: []const u8) !Read {
        var member = v1_conversion.readMember(c.alloc, v1, locked, &c.store.problem) catch |err| {
            if (err == error.InvalidSessionFormat) c.traceUnreadable(root_id, locked.id);
            return err;
        };
        return .{ .member = member, .marker = movedMarker(v1, locked.id, &member) };
    }

    /// Records each side file larger than one v2 blob, which the conversion
    /// leaves out (D62), naming it in the trace. A side folder it cannot
    /// list refuses the family before anything is staged.
    fn findLeftOut(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked) !void {
        const io = io_mod.getIo();
        for (body_folders) |folder| {
            var dir = locked.dir.dir.openDir(io, folder, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return c.refuse(root_id, locked.id, "{s} can't be opened ({s})", .{ folder, @errorName(err) }),
            };
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch |err| return c.refuse(root_id, locked.id, "{s} can't be listed ({s})", .{ folder, @errorName(err) })) |entry| {
                if (entry.kind != .file) continue;
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err|
                    return c.refuse(root_id, locked.id, "{s}/{s} can't be read ({s})", .{ folder, entry.name, @errorName(err) });
                if (stat.size <= sm.max_blob_bytes) continue;
                try c.left_out.ensureUnusedCapacity(c.alloc, 1);
                const member = try c.alloc.dupe(u8, locked.id);
                errdefer c.alloc.free(member);
                const file = try std.fmt.allocPrint(c.alloc, "{s}/{s}", .{ folder, entry.name });
                c.left_out.appendAssumeCapacity(.{ .member = member, .file = file, .bytes = stat.size });
                debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} bytes={d} limit={d}", .{ root_id, locked.id, file, stat.size, sm.max_blob_bytes });
            }
        }
    }

    /// Reads a checked member again unless its read was kept, and writes it
    /// as an import, unpublished; its read is freed either way.
    fn stage(c: *Conversion, v1: *session_store.Store, checked: *Checked, locked: *v1_conversion.Locked, role: Role) !Staged {
        const store = c.store;
        const kept = switch (checked.*) {
            .reused => |reused| return reused,
            .read => |*kept| kept,
        };
        if (kept.* == null) kept.* = try c.load(v1, locked, rootOf(role, locked.id));
        const read = &kept.*.?;
        defer {
            read.member.deinit();
            kept.* = null;
        }
        const handle = store.manager.openImport(.{
            .id = locked.id,
            .workspace = read.member.workspace,
            .host = c.host,
            .role = if (role == .root) .root else .child,
            .parent = if (role == .child) role.child.parent else null,
            .created_ms = read.member.created_ms,
        }) catch |err| switch (err) {
            error.Exists => return c.refuse(rootOf(role, locked.id), locked.id, "the session {s} was deleted from the new store", .{locked.id}),
            error.Busy => return error.SessionBusy,
            else => return conversionStorageFailed("import", err),
        };
        const session = Session.init(c.alloc, store, handle, false) catch |err| {
            handle.release();
            c.discardStaging(locked.id);
            return err;
        };
        session.root = false;
        errdefer {
            session.dropImport();
            c.discardStaging(locked.id);
        }
        try c.writeMember(session, read, locked, role);
        return .{ .id = locked.id, .session = session, .marker = read.marker };
    }

    /// A child an earlier try published before it stopped (TLA `Orphan`):
    /// reused as it is, unread, since the sweep cannot take it back without
    /// a tombstone (`tla/Catalog.tla` NoResurrection) and its v1 copy may
    /// have changed or been damaged since. Its v1 folder goes only while it
    /// is the copy converted (D60).
    fn reusedOrphan(c: *Conversion, locked: *v1_conversion.Locked) !?Staged {
        var peeked = c.store.manager.peek(c.alloc, locked.id) catch |err| switch (err) {
            error.NotFound => return null,
            else => return conversionStorageFailed("orphan", err),
        };
        defer peeked.deinit(c.alloc);
        var scratch = std.heap.ArenaAllocator.init(c.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();
        const source = parseV1Source(a, peeked.state.v1_source);
        const unchanged = if (source) |known| std.mem.eql(u8, known.fingerprint, &(try v1_conversion.fingerprintOf(a, &locked.dir))) else false;
        debug_trace.logf("convert", "action=Reused member={s} v1={s}", .{ locked.id, if (unchanged) "unchanged" else "kept" });
        return .{
            .id = locked.id,
            .session = null,
            .marker = if (source) |known| known.marker else null,
            .unchanged = unchanged,
        };
    }

    /// Writes `member` into `session`, each batch at its original time
    /// (D59): its turns and compactions, then its settings at the time v1
    /// lists it.
    fn writeMember(c: *Conversion, session: *Session, read: *const Read, locked: *v1_conversion.Locked, role: Role) !void {
        const member = &read.member;
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var newest = member.created_ms;
        // The v2 turn of each of the member's turns, for `keep_from`.
        var turns: std.ArrayList(u64) = .empty;
        try turns.ensureTotalCapacity(a, member.steps.len);
        // Each turn is encoded in its own scratch, so a long session never
        // holds every turn's encoding at once (D62).
        var step_arena = std.heap.ArenaAllocator.init(c.alloc);
        defer step_arena.deinit();
        for (member.steps) |step| {
            _ = step_arena.reset(.retain_capacity);
            const sa = step_arena.allocator();
            const ts = switch (step) {
                inline else => |value| value.ts_ms,
            };
            newest = @max(newest, ts);
            session.import_ts = newest;
            switch (step) {
                .framed => |turn| try session.importFramed(sa, turn.events, turn.open),
                .whole => |turn| try session.importWhole(sa, turn.turn),
                .compacted => |compacted| {
                    const data: CompactedData = .{
                        .summary = compacted.summary,
                        .removed_turn_count = compacted.removed_turn_count,
                        .compaction_count = compacted.compaction_count,
                        .keep_from_turn = if (compacted.keep_from) |index| turns.items[index] else null,
                    };
                    _ = try session.write(&.{.{ .compacted = try jsonValue(sa, data) }});
                    continue;
                },
            }
            turns.appendAssumeCapacity(session.last_turn);
        }

        var settings: std.ArrayList(sm.Event) = .empty;
        const instructions = if (role == .child) role.child.instructions else null;
        try settings.append(a, .{ .set = .{ .key = .prefs, .value = try encodePreferences(a, member.preferences, instructions) } });
        try settings.append(a, .{ .set = .{ .key = .permissions, .value = try session_codec.encodePermissionState(a, member.permissions) } });
        try settings.append(a, .{ .set = .{ .key = .language, .value = try jsonString(a, member.language.view()) } });
        if (member.title) |title| try settings.append(a, .{ .set = .{ .key = .title, .value = try jsonString(a, title) } });
        if (member.usage) |usage| try settings.append(a, .{ .set = .{ .key = .usage, .value = try encodeUsage(a, usage, member.usage_at_ms) } });
        var left_out: std.ArrayList([]const u8) = .empty;
        for (c.left_out.items) |entry| if (std.mem.eql(u8, entry.member, locked.id)) try left_out.append(a, entry.file);
        const side = try sideFileLines(a, session.handle, &locked.dir, &body_folders, member.stored, left_out.items);
        try settings.appendSlice(a, side.events);
        try settings.append(a, .{ .set = .{ .key = .v1_source, .value = try jsonValue(a, V1Source{ .fingerprint = &member.fingerprint, .marker = read.marker }) } });
        if (role == .root) {
            for (try child_state.v1ImportLines(a, role.root.registry.*, role.root.has_log)) |line| try settings.append(a, switch (line) {
                .spawned => |spawned| .{ .child_spawned = .{ .child = spawned.child, .work_id = spawned.work_id, .data = spawned.data } },
                .finished => |finished| .{ .child_finished = .{ .child = finished.child, .work_id = finished.work_id, .outcome = finished.outcome, .data = finished.data } },
            });
        }
        session.import_ts = @max(newest, member.listed_ms);
        _ = try session.write(settings.items);
        try copyTerminalState(c.store, locked);
        c.turns += member.turns;
        c.files += side.bodies;
    }

    /// Tells the host about each side file the conversion left out (D62),
    /// as it tells it the open is slow.
    fn tellLeftOut(c: *Conversion, root_id: []const u8) void {
        const notice = c.store.notice orelse return;
        for (c.left_out.items) |entry| {
            const text = entry.note(c.alloc, root_id) catch continue;
            defer c.alloc.free(text);
            notice.emit(notice.context, text);
        }
    }

    /// Tells the host once that the open is slow (D61), at a step boundary.
    fn phase(c: *Conversion) void {
        if (c.noticed or io_mod.nanoTimestamp() - c.started < slow_conversion_ns) return;
        c.noticed = true;
        const notice = c.store.notice orelse return;
        notice.emit(notice.context, slow_conversion_text);
    }

    fn discard(c: *Conversion, member: Staged) void {
        if (member.session != null) c.discardStaging(member.id);
    }

    /// Drops `id`'s staging after a failed try; what stays is swept by the
    /// next one (CSweep).
    fn discardStaging(c: *Conversion, id: []const u8) void {
        c.store.manager.discardImport(id) catch |err| debug_trace.logf("convert", "action=DiscardFailed member={s} err={s}", .{ id, @errorName(err) });
    }

    fn refuse(c: *Conversion, root_id: []const u8, member_id: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidSessionFormat} {
        const refused = c.store.problem.set(fmt, args);
        c.traceUnreadable(root_id, member_id);
        return refused;
    }

    fn traceUnreadable(c: *Conversion, root_id: []const u8, member_id: []const u8) void {
        debug_trace.logf("convert", "action=Unreadable session={s} member={s} reason=\"{s}\"", .{ root_id, member_id, c.store.problem.text() });
    }

    fn rootOf(role: Role, id: []const u8) []const u8 {
        return switch (role) {
            .root => id,
            .child => |child| child.parent,
        };
    }
};

fn childInstructionsOf(registry: child_state.Registry, id: []const u8) ?[]const u8 {
    for (registry.children) |child| if (std.mem.eql(u8, child.id, id)) return switch (child.kind) {
        .one_off => null,
        .persistent => |persistent| if (persistent.instructions.len == 0) null else persistent.instructions,
    };
    return null;
}

/// v1's usage marker of a member and the time of the v2 marker that makes
/// v2's usage recovery reach v1's verdict (D20): a pending checkpoint counts
/// when it is at least as new as its marker, a settled one when it is
/// newer. Null when v1 has none, or one it cannot read, which then keeps
/// the member's v1 state while it stays (`removeV1State`).
fn movedMarker(v1: *session_store.Store, id: []const u8, member: *const v1_conversion.Member) ?MovedMarker {
    const marker = (v1_conversion.readMarker(v1, id, member) catch |err| {
        debug_trace.logf("convert", "action=MarkerUnreadable session={s} err={s}", .{ id, @errorName(err) });
        return null;
    }) orelse return null;
    const at = member.usage_at_ms;
    const pending = if (member.usage) |usage| session_usage.needsProfileRecovery(usage) else false;
    const ms = if (pending)
        (if (marker.newer) at else at +| 1)
    else
        (if (marker.newer) at -| 1 else at);
    return .{ .v1 = marker.id, .ms = ms };
}

/// Copies `<v1>/terminal` to `~/.fx/terminal/{id}/terminal` (D45), over
/// what a crashed try left there. A copy, not a move: a conversion that
/// stops leaves v1 whole.
fn copyTerminalState(store: *Store, locked: *v1_conversion.Locked) !void {
    const io = io_mod.getIo();
    var source = (try io_mod.openRealDirIfPresent(&locked.dir, terminal_dir_name)) orelse return;
    defer source.close();
    var root = try store.makeProfileFolder(terminal_dir_name);
    defer root.close();
    var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, locked.id);
    defer owner.close();
    try owner.dir.deleteTree(io, terminal_dir_name);
    var target = try io_mod.openOrCreateVerifiedPrivateDir(&owner, terminal_dir_name);
    defer target.close();
    if (!copyTree(&source, &target, 0)) return error.SessionStoreUnavailable;
}

/// Whether v2 holds `id`, a damaged copy included: nothing converts over
/// it, nor over one v2 cannot tell about, and the listing shows v2's.
fn holdsV2(store: *Store, alloc: Allocator, id: []const u8) bool {
    var peeked = store.manager.peek(alloc, id) catch |err| switch (err) {
        error.NotFound => return false,
        else => {
            debug_trace.logf("convert", "action=HeldUnknown session={s} err={s}", .{ id, @errorName(err) });
            return true;
        },
    };
    peeked.deinit(alloc);
    return true;
}

fn parseV1Source(a: Allocator, raw: ?[]const u8) ?V1Source {
    const bytes = raw orelse return null;
    const source = std.json.parseFromSliceLeaky(V1Source, a, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (source.fingerprint.len != 64) return null;
    return source;
}

/// Removes the v1 state of a converted member it has locked, unchanged
/// since its copy (TLA MoveMark, DropMark, CDelete, CClean): v1's usage
/// marker as it stands moves first, the v2 marker at `moved.ms` written
/// before v1's goes, and only then the folder (D60, D62). A marker other
/// than `moved.v1`, one that cannot be read, or a refused step keeps the
/// folder for a later open, never failing the caller, so v1's marker never
/// names a session that is gone. True when the folder went.
fn removeV1State(store: *Store, alloc: Allocator, v1: *session_store.Store, id: []const u8, moved: ?MovedMarker, why: []const u8) bool {
    const now = v1_conversion.markerOf(v1, id) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=v1_marker err={s}", .{ id, why, @errorName(err) });
        return false;
    };
    if (now) |marker| {
        // A marker the copy did not see: its verdict is not the one the
        // copy carries.
        const known = moved orelse return refuseMarker(id, why);
        if (!known.v1.eql(marker)) return refuseMarker(id, why);
        store.writeUsageMarker(alloc, id, known.ms) catch |err| {
            debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=usage_marker err={s}", .{ id, why, @errorName(err) });
            return false;
        };
        if (!v1_conversion.removeMarker(v1, id)) {
            debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=v1_marker", .{ id, why });
            return false;
        }
    }
    return v1_conversion.removeFolder(v1, id, why);
}

fn refuseMarker(id: []const u8, why: []const u8) bool {
    debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=v1_marker reason=changed", .{ id, why });
    return false;
}

/// Removes what a conversion left in v1 for the converted session
/// `root_id` and its children: each member's v1 state, while its v1 copy is
/// what was converted (TLA CClean, D60). A member another process holds,
/// or that changed, keeps it; nothing here fails the open.
fn cleanLeftovers(store: *Store, alloc: Allocator, root_id: []const u8, state: *const sm.State) void {
    if (state.v1_source == null) return;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const a = scratch.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList(?[]const u8) = .empty;
    if (leftFolder(store, root_id)) {
        ids.append(a, root_id) catch return;
        sources.append(a, state.v1_source) catch return;
    }
    for (state.children.items) |child| {
        if (!leftFolder(store, child.id)) continue;
        const peeked = store.manager.peek(a, child.id) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ child.id, @errorName(err) });
            continue;
        };
        ids.append(a, child.id) catch return;
        sources.append(a, peeked.state.v1_source) catch return;
    }
    if (ids.items.len == 0) return;
    var v1 = session_store.Store.initReadOnlyFromHome(alloc, store.home, "/") catch |err| {
        debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ root_id, @errorName(err) });
        return;
    };
    defer v1.deinit(alloc);
    for (ids.items, sources.items) |id, raw| {
        const source = parseV1Source(a, raw) orelse {
            debug_trace.logf("convert", "action=Kept session={s} reason=no_source", .{id});
            continue;
        };
        var locked = (v1_conversion.tryLockLeftover(alloc, &v1, id) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
            continue;
        }) orelse {
            debug_trace.logf("convert", "action=Kept session={s} reason=busy", .{id});
            continue;
        };
        defer v1_conversion.releaseLocked(alloc, &locked);
        const fingerprint = v1_conversion.fingerprintOf(a, &locked.dir) catch |err| {
            debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
            continue;
        };
        if (!std.mem.eql(u8, &fingerprint, source.fingerprint)) {
            debug_trace.logf("convert", "action=Kept session={s} reason=changed", .{id});
            continue;
        }
        if (removeV1State(store, alloc, &v1, id, source.marker, "leftover")) debug_trace.logf("convert", "action=Cleaned session={s}", .{id});
    }
}

/// Whether v1 still has a folder for `id`; one that cannot be checked is
/// traced and left for a later open.
fn leftFolder(store: *Store, id: []const u8) bool {
    return v1_conversion.hasFolder(store.home, id) catch |err| {
        debug_trace.logf("convert", "action=CleanRefused session={s} err={s}", .{ id, @errorName(err) });
        return false;
    };
}

/// The newest session of the merged listing in `workspace` (D61). Caller
/// owns it.
fn newestListed(store: *Store, alloc: Allocator, workspace: []const u8) !?[]u8 {
    var page = try listPage(store, alloc, workspace, null, 1);
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) return null;
    return try alloc.dupe(u8, page.summaries.items[0].id);
}

/// What `fx sessions convert` did (D61).
pub const ConvertReport = struct {
    converted: usize = 0,
    busy: usize = 0,
    unreadable: usize = 0,
    /// One per skipped session, in the order v1 lists its folders.
    skipped: std.ArrayList(Skipped) = .empty,
    /// Each side file a converted family was converted without (D62).
    left_out: std.ArrayList(LeftOutFile) = .empty,

    pub const LeftOutFile = struct {
        /// The family's root.
        id: []u8,
        file: LeftOut,
    };

    /// The largest side file a conversion keeps (D62).
    pub const file_limit_bytes: u64 = sm.max_blob_bytes;

    pub const Skipped = struct {
        id: []u8,
        /// `SessionBusy` or `InvalidSessionFormat`.
        code: []const u8,
        /// The file and the reason, for an unreadable one.
        reason: ?[]u8,
    };

    pub fn deinit(report: *ConvertReport, alloc: Allocator) void {
        for (report.skipped.items) |skipped| {
            alloc.free(skipped.id);
            if (skipped.reason) |reason| alloc.free(reason);
        }
        report.skipped.deinit(alloc);
        for (report.left_out.items) |entry| {
            alloc.free(entry.id);
            entry.file.deinit(alloc);
        }
        report.left_out.deinit(alloc);
        report.* = undefined;
    }

    /// Records `id` as skipped, `code` a static name, and traces it.
    fn skip(report: *ConvertReport, alloc: Allocator, id: []const u8, code: []const u8, reason: ?[]const u8) !void {
        debug_trace.logf("convert", "action=Skipped session={s} code={s} reason=\"{s}\"", .{ id, code, reason orelse "" });
        try report.skipped.ensureUnusedCapacity(alloc, 1);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_reason = if (reason) |text| try alloc.dupe(u8, text) else null;
        report.skipped.appendAssumeCapacity(.{ .id = owned_id, .code = code, .reason = owned_reason });
        if (std.mem.eql(u8, code, "SessionBusy")) report.busy += 1 else report.unreadable += 1;
    }
};

/// Converts every v1 family v2 does not hold, opening none (TLA
/// `Request("all")`), and cleans what an earlier conversion left of those
/// it does. A busy family is skipped at once, and one that cannot be
/// converted is skipped with its reason; only what would stop every other
/// family too stops the run. Caller owns the report.
pub fn convertAll(store: *Store, alloc: Allocator) !ConvertReport {
    io_mod.e2eFailIfDurableMutationAttempted();
    var report: ConvertReport = .{};
    errdefer report.deinit(alloc);
    const roots = try v1_conversion.rootIds(alloc, store.home);
    defer {
        for (roots) |root| root.deinit(alloc);
        alloc.free(roots);
    }
    var reason: [v1_conversion.Problem.capacity]u8 = undefined;
    for (roots) |root| {
        const id = root.id;
        if (root.unreadable) |why| {
            try report.skip(alloc, id, "InvalidSessionFormat", why);
            continue;
        }
        if (store.manager.peek(alloc, id)) |peeked_value| {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            cleanLeftovers(store, alloc, id, &peeked.state);
            continue;
        } else |err| switch (err) {
            error.NotFound, error.InvalidArgument => {},
            else => {
                try report.skip(alloc, id, "InvalidSessionFormat", std.fmt.bufPrint(&reason, "the new store can't read its copy ({s})", .{@errorName(err)}) catch null);
                continue;
            },
        }
        var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
        defer conversion.deinit();
        const outcome = conversion.family(id, 0) catch |err| switch (err) {
            error.OutOfMemory, error.NoSpaceLeft, error.ReadOnlyFileSystem => return err,
            error.SessionNotFound => continue,
            error.SessionBusy => {
                try report.skip(alloc, id, "SessionBusy", null);
                continue;
            },
            error.InvalidSessionFormat => {
                try report.skip(alloc, id, "InvalidSessionFormat", store.problem.text());
                continue;
            },
            else => {
                try report.skip(alloc, id, "InvalidSessionFormat", std.fmt.bufPrint(&reason, "the conversion failed ({s})", .{@errorName(err)}) catch null);
                continue;
            },
        };
        if (outcome == .converted) {
            report.converted += 1;
            const ms = @as(f64, @floatFromInt(io_mod.nanoTimestamp() - conversion.started)) / std.time.ns_per_ms;
            debug_trace.logf("convert", "action=Converted session={s} members={d} turns={d} files={d} ms={d:.3}", .{ id, conversion.members, conversion.turns, conversion.files, ms });
            try report.left_out.ensureUnusedCapacity(alloc, conversion.left_out.items.len);
            for (conversion.left_out.items, 0..) |file, index| {
                const owned_root = alloc.dupe(u8, id) catch |err| {
                    // Those moved so far are the report's now.
                    const rest = conversion.left_out.items[index..];
                    std.mem.copyForwards(LeftOut, conversion.left_out.items[0..rest.len], rest);
                    conversion.left_out.shrinkRetainingCapacity(rest.len);
                    return err;
                };
                report.left_out.appendAssumeCapacity(.{ .id = owned_root, .file = file });
            }
            conversion.left_out.clearRetainingCapacity();
        }
    }
    return report;
}

const ConversionStorageError = error{ NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig, SessionStoreUnavailable };

/// A v2 store step of a conversion that failed: its storage cause when it
/// has one (D29), else `SessionStoreUnavailable`.
fn conversionStorageFailed(comptime step: []const u8, err: anyerror) ConversionStorageError {
    debug_trace.logf("convert", "action=StoreFailed step=" ++ step ++ " err={s}", .{@errorName(err)});
    return storageCause(err) orelse error.SessionStoreUnavailable;
}

fn copyFailed(id: []const u8, err: anyerror) bool {
    debug_trace.logf("session", "event=sessions_v2_files_copy_incomplete session={s} err={s}", .{ id, @errorName(err) });
    return false;
}

/// Side folders are a few levels deep (a kind, then files); deeper trees
/// are not fx's and are left out.
const max_copy_depth = 8;

fn copyTree(source: *io_mod.VerifiedDir, target: *io_mod.VerifiedDir, depth: usize) bool {
    const io = io_mod.getIo();
    var complete = true;
    var it = source.dir.iterate();
    while (it.next(io) catch |err| return copyFailed("tree", err)) |entry| switch (entry.kind) {
        .directory => {
            if (depth + 1 == max_copy_depth) {
                complete = copyFailed(entry.name, error.TooDeep);
                continue;
            }
            var from = (io_mod.openVerifiedPrivateDirIfPresent(source, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            }) orelse continue;
            defer from.close();
            var to = io_mod.openOrCreateVerifiedPrivateDir(target, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            };
            defer to.close();
            if (!copyTree(&from, &to, depth + 1)) complete = false;
        },
        .file => copyFile(source.dir, target.dir, entry.name) catch |err| {
            complete = copyFailed(entry.name, err);
        },
        else => complete = copyFailed(entry.name, error.NotAFile),
    };
    return complete;
}

fn copyFile(from: std.Io.Dir, to: std.Io.Dir, name: []const u8) !void {
    const io = io_mod.getIo();
    var source = try from.openFile(io, name, .{ .follow_symlinks = false, .resolve_beneath = true, .allow_directory = false });
    defer source.close(io);
    var target = try to.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600), .resolve_beneath = true });
    defer target.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try source.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        try target.writePositionalAll(io, buffer[0..n], offset);
        offset += n;
    }
}

/// Where `restoreFrom` puts the number of the turn behind each history entry.
const TurnNumbers = struct {
    alloc: Allocator,
    list: *std.ArrayList(?u64),
};

/// Rebuilds fx's history and settings from `state` and its log: the newest
/// compaction's summary, then every turn after it (or after the turn it
/// kept). A turn a crash or close ended has no `interruption` item and
/// comes back interrupted: `failed` after a crash, `cancelled` after a
/// close. Caller owns the result.
fn restoreFrom(src: Source, alloc: Allocator, sa: Allocator, state: sm.State, numbers: ?TurnNumbers) !Restored {
    var restored = try settingsFrom(alloc, sa, state);
    errdefer restored.deinit(alloc);

    var history: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var from: sm.From = .start;
    var skip_offset: ?u64 = null;
    if (state.compaction_offset) |offset| {
        const cursor: sm.Cursor = .{ .offset = offset, .seq = state.last_compaction_seq.? };
        var page = try src.read(sa, .{ .at = cursor }, 1);
        defer page.deinit();
        const data = compactedData(&page) orelse {
            debug_trace.logf("session", "event=sessions_v2_compaction_unreadable session={s} offset={d}", .{ src.id, offset });
            return error.InvalidSessionFormat;
        };
        const compacted = try std.json.parseFromSliceLeaky(CompactedData, sa, data, .{});
        try history.ensureUnusedCapacity(alloc, 1);
        if (numbers) |n| try n.list.append(n.alloc, null);
        history.appendAssumeCapacity(.{ .compacted_summary = .{
            .summary = try alloc.dupe(u8, compacted.summary),
            .removed_turn_count = compacted.removed_turn_count,
            .compaction_count = compacted.compaction_count,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
        skip_offset = offset;
        from = .{ .at = cursor };
        if (compacted.keep_from_turn) |turn| from = .{ .at = try src.findTurnStart(sa, cursor, turn) };
    }
    var sink: RestoreSink = .{ .alloc = alloc, .history = &history, .numbers = numbers };
    try replay(src, alloc, sa, from, skip_offset, ReplaySink.init(&sink));
    restored.history = try history.toOwnedSlice(alloc);
    return restored;
}

/// fx's settings from `state`, with an empty history. Caller owns the result.
fn settingsFrom(alloc: Allocator, sa: Allocator, state: sm.State) !Restored {
    const language = if (state.language) |raw| try decodeLanguage(sa, raw) else types.ConversationLanguage.default();
    var restored: Restored = .{
        .history = &.{},
        .language = language,
        .created_at_ms = std.math.cast(i64, state.created_ms) orelse 0,
        .updated_at_ms = std.math.cast(i64, state.updated_ms) orelse 0,
    };
    errdefer restored.deinit(alloc);
    if (state.title) |raw| restored.title = try alloc.dupe(u8, try std.json.parseFromSliceLeaky([]const u8, sa, raw, .{}));
    if (state.prefs) |raw| restored.preferences = try decodePreferences(alloc, raw);
    if (state.permissions) |raw| restored.permission_state = try session_codec.decodePermissionState(alloc, raw);
    if (state.usage) |raw| restored.usage = (try decodeUsage(alloc, raw)).snapshot;
    return restored;
}

/// Every turn in the log, oldest first, with each compaction's summary where
/// its line sits, as v1's archive lists them for `fx session {id}` (D32).
/// Pages are freed as they are read. Caller owns the result.
fn detailHistory(src: Source, alloc: Allocator) ![]types.HistoryTurn {
    var history: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var sink: DetailSink = .{ .alloc = alloc, .history = &history };
    try replay(src, alloc, alloc, .start, null, ReplaySink.init(&sink));
    return history.toOwnedSlice(alloc);
}

/// Keeps each turn for resume, with the number of the turn that holds it.
const RestoreSink = struct {
    alloc: Allocator,
    history: *std.ArrayList(types.HistoryTurn),
    numbers: ?TurnNumbers,

    fn turn(sink: *RestoreSink, value: types.HistoryTurn, number: ?u64) !void {
        errdefer types.freeHistoryTurn(sink.alloc, value);
        try sink.history.ensureUnusedCapacity(sink.alloc, 1);
        if (sink.numbers) |n| try n.list.append(n.alloc, number);
        sink.history.appendAssumeCapacity(value);
    }

    /// The newest summary already leads the history (`restoreFrom`).
    fn summary(_: *RestoreSink, _: []const u8) !void {}
};

/// Keeps every turn and each compaction's summary where its line sits,
/// counted as v1's archive counts them: the turns before the summary, and
/// its place among the compactions (D32).
const DetailSink = struct {
    alloc: Allocator,
    history: *std.ArrayList(types.HistoryTurn),
    turns: usize = 0,
    compactions: usize = 0,

    fn turn(sink: *DetailSink, value: types.HistoryTurn, _: ?u64) !void {
        errdefer types.freeHistoryTurn(sink.alloc, value);
        try sink.history.append(sink.alloc, value);
        sink.turns += 1;
    }

    fn summary(sink: *DetailSink, data: []const u8) !void {
        const parsed = try std.json.parseFromSlice(CompactedData, sink.alloc, data, .{});
        defer parsed.deinit();
        const text = try sink.alloc.dupe(u8, parsed.value.summary);
        errdefer sink.alloc.free(text);
        try sink.history.append(sink.alloc, .{ .compacted_summary = .{
            .summary = text,
            .removed_turn_count = sink.turns,
            .compaction_count = sink.compactions + 1,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
        sink.compactions += 1;
    }
};

/// Moves `restored` into v1's `DurableSessionState` with its stored title;
/// `restored` keeps only what it still owns. Caller owns the result.
fn resumedOf(alloc: Allocator, restored: *Restored, id: []const u8, workspace: []const u8) !Resumed {
    const id_copy = try alloc.dupe(u8, id);
    errdefer alloc.free(id_copy);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const workspace_copy = try alloc.dupe(u8, workspace);
    errdefer alloc.free(workspace_copy);
    // Every session starts with its preferences (`create`).
    const preferences = restored.preferences orelse return error.InvalidSessionFormat;
    restored.preferences = null;
    const resumed: Resumed = .{
        .state = .{
            .id = id_copy,
            .origin_workspace_root = origin,
            .workspace_root = workspace_copy,
            .created_at_ms = restored.created_at_ms,
            .updated_at_ms = restored.updated_at_ms,
            .conversation_language = restored.language,
            .preferences = preferences,
            .history = restored.history,
            // v1 reloads its totals as zero as well.
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .permission_state = restored.permission_state orelse .{},
            .usage = restored.usage,
        },
        .title = restored.title,
    };
    restored.history = &.{};
    restored.permission_state = null;
    restored.usage = null;
    restored.title = null;
    return resumed;
}

fn lastStarted(entry: sm.Entry) ?u64 {
    return switch (entry.body.?) {
        .item => |piece| piece.turn,
        else => null,
    };
}

// Borrows its context for the synchronous replay call. Turn callbacks take
// ownership even on failure; summary bytes remain owned by the current page.
const ReplaySink = struct {
    context: *anyopaque,
    turn_fn: *const fn (*anyopaque, types.HistoryTurn, ?u64) anyerror!void,
    summary_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    fn init(sink: anytype) ReplaySink {
        const SinkPtr = @TypeOf(sink);
        const Callbacks = struct {
            fn turn(context: *anyopaque, value: types.HistoryTurn, number: ?u64) anyerror!void {
                const typed: SinkPtr = @ptrCast(@alignCast(context));
                return typed.turn(value, number);
            }

            fn summary(context: *anyopaque, data: []const u8) anyerror!void {
                const typed: SinkPtr = @ptrCast(@alignCast(context));
                return typed.summary(data);
            }
        };
        return .{ .context = @ptrCast(sink), .turn_fn = Callbacks.turn, .summary_fn = Callbacks.summary };
    }

    fn turn(sink: ReplaySink, value: types.HistoryTurn, number: ?u64) anyerror!void {
        return sink.turn_fn(sink.context, value, number);
    }

    fn summary(sink: ReplaySink, data: []const u8) anyerror!void {
        return sink.summary_fn(sink.context, data);
    }
};

noinline fn replay(
    src: Source,
    alloc: Allocator,
    sa: Allocator,
    start: sm.From,
    skip_offset: ?u64,
    /// Takes each finished turn, even when it fails: `turn(value, number)`,
    /// and each compaction's stored data where its line sits: `summary(data)`.
    sink: ReplaySink,
) !void {
    var builder = session_log.ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var interrupted_item = false;
    var superseded = false;
    var piece_arena = std.heap.ArenaAllocator.init(alloc);
    defer piece_arena.deinit();
    // The open turn's calls saved as running, and the call ids its pieces
    // already answer or hold (D28).
    var turn_arena = std.heap.ArenaAllocator.init(alloc);
    defer turn_arena.deinit();
    var running: std.ArrayList(session_event.ConversationToolCall) = .empty;
    var represented: std.ArrayList([]const u8) = .empty;
    // The text of the message whose calls are running, until a finished
    // step's own assistant piece supersedes it (D51).
    var running_text: ?[]const u8 = null;
    var from = start;
    while (true) {
        var page = try src.read(sa, from, replay_page_lines);
        defer page.deinit();
        if (page.damaged) debug_trace.logf("session", "event=sessions_v2_replay_damaged session={s} dropped=lines_after_damage", .{src.id});
        for (page.entries) |entry| {
            _ = piece_arena.reset(.retain_capacity);
            const pa = piece_arena.allocator();
            if (skip_offset) |offset| if (entry.offset == offset) continue;
            const body = entry.body orelse continue;
            switch (body) {
                .turn_started => {
                    interrupted_item = false;
                    superseded = false;
                    _ = turn_arena.reset(.retain_capacity);
                    running = .empty;
                    represented = .empty;
                    running_text = null;
                },
                .item => |piece| {
                    if (std.mem.eql(u8, piece.type, superseded_type)) {
                        superseded = true;
                        continue;
                    }
                    const ta = turn_arena.allocator();
                    if (std.mem.eql(u8, piece.type, running_type)) {
                        // Kept for the whole turn: copies, not views of the page.
                        const call = try decodePiece(ta, .tool_call, try src.pieceData(ta, piece), .alloc_always);
                        try running.append(ta, call.tool_call);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, running_assistant_type)) {
                        const value = try decodePiece(ta, .assistant, try src.pieceData(ta, piece), .alloc_always);
                        running_text = value.assistant.text;
                        continue;
                    }
                    const kind = pieceKind(piece.type) orelse {
                        debug_trace.logf("session", "event=sessions_v2_unknown_item session={s} type={s} dropped=item", .{ src.id, piece.type });
                        continue;
                    };
                    const data = try src.pieceData(pa, piece);
                    // The builder copies what it keeps, as it does for v1's
                    // reader, so strings may point into the page.
                    switch (try decodePiece(pa, kind, data, .alloc_if_needed)) {
                        .user => |value| try builder.begin(try src.withMovedImages(pa, value)),
                        .assistant => |value| {
                            running_text = null;
                            try builder.appendAssistant(value);
                        },
                        .tool_call => |value| {
                            try builder.appendToolCall(value);
                            try represented.append(ta, try ta.dupe(u8, value.call_id));
                        },
                        .tool_result => |value| {
                            try builder.appendToolResult(value);
                            try represented.append(ta, try ta.dupe(u8, value.call_id));
                        },
                        .steering => |value| try builder.appendSteering(value.text),
                        .turn_completed => |value| try sink.turn(try presentStoredResults(alloc, try builder.finishAssistant(value)), lastStarted(entry)),
                        .interrupted => |value| {
                            interrupted_item = true;
                            try sink.turn(try presentStoredResults(alloc, try builder.finishInterrupted(value)), lastStarted(entry));
                        },
                        .context_checkpoint => return error.InvalidConversationFrame,
                    }
                },
                .turn_interrupted => |ended| {
                    if (superseded) {
                        debug_trace.logf("session", "event=sessions_v2_replay_superseded session={s} turn={d} dropped=stale_turn", .{ src.id, ended.turn });
                        builder.deinit();
                        builder = session_log.ConversationTurnBuilder.init(alloc);
                        superseded = false;
                        continue;
                    }
                    if (interrupted_item or builder.isIdle()) continue;
                    var turn = try builder.finishInterrupted(.{ .reason = switch (ended.reason) {
                        .cancel, .closed => .cancelled,
                        .failed, .crash => .failed,
                    } });
                    const answered = answerRunning(alloc, &turn.interrupted, running.items, represented.items, running_text) catch |err| {
                        types.freeHistoryTurn(alloc, turn);
                        return err;
                    };
                    if (answered > 0) debug_trace.logf("session", "event=sessions_v2_replay_unfinished_tools session={s} turn={d} calls={d}", .{ src.id, ended.turn, answered });
                    try sink.turn(try presentStoredResults(alloc, turn), ended.turn);
                },
                .compacted => |line| try sink.summary(line.data),
                .session_created, .turn_committed, .set, .child_spawned, .child_finished, .snapshot, .closed => {},
            }
        }
        from = .{ .at = page.next orelse break };
    }
    if (!builder.isIdle()) debug_trace.logf("session", "event=sessions_v2_replay_open_turn session={s} dropped=unfinished_pieces", .{src.id});
}

/// `turn` with each stored result that kept only a preview shown as v1
/// shows it (`session_log.zig` `restoreExecutionResultBodies`): the preview
/// wrapped with its handle and stored size, so the model knows where the
/// rest is. Takes `turn`, freeing it on failure.
fn presentStoredResults(alloc: Allocator, turn: types.HistoryTurn) !types.HistoryTurn {
    var shown = turn;
    errdefer types.freeHistoryTurn(alloc, shown);
    const execution = switch (shown) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => return shown,
    };
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        if (!result.truncated) continue;
        const handle = result.output_handle orelse continue;
        const body = try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes);
        alloc.free(result.output);
        result.output = body;
    };
    return shown;
}

/// Whether a streamed piece is the final one. fx stamps a tool result's
/// `created_at_ms` each time it rebuilds a turn, so that field alone may
/// differ; the streamed, earlier stamp stands.
fn samePiece(alloc: Allocator, streamed: []const u8, final: []const u8) bool {
    if (std.mem.eql(u8, streamed, final)) return true;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const x = withoutCreatedAt(a, streamed) catch return false;
    const y = withoutCreatedAt(a, final) catch return false;
    return std.mem.eql(u8, x, y);
}

fn withoutCreatedAt(a: Allocator, bytes: []const u8) ![]u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (value != .object) return error.NotAnObject;
    if (!value.object.swapRemove("created_at_ms")) return error.NoCreatedAt;
    return jsonValue(a, value);
}

/// Gives each call that was saved as running but that `represented` does not
/// name a failed result saying it may have partly run (D28), as one more
/// step of `turn`, so every call keeps its result. That step keeps `text`,
/// the text of the message that issued them (D51). Returns how many.
fn answerRunning(
    alloc: Allocator,
    turn: *types.InterruptedHistoryTurn,
    running: []const session_event.ConversationToolCall,
    represented: []const []const u8,
    text: ?[]const u8,
) !usize {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var calls: std.ArrayList(types.ToolCall) = .empty;
    var results: std.ArrayList(types.PersistedToolResult) = .empty;
    for (running) |call| {
        if (containsId(represented, call.call_id)) continue;
        try calls.append(a, historyToolCall(call));
        try results.append(a, .{
            .tool_call_id = @constCast(call.call_id),
            .tool_name = @constCast(call.tool_name),
            .status = .failure,
            .output = @constCast(unfinished_tool_output),
            .output_bytes = unfinished_tool_output.len,
            .stored_output_bytes = unfinished_tool_output.len,
        });
    }
    if (calls.items.len == 0) return 0;
    const owned_calls = try types.dupeToolCallSlice(alloc, calls.items);
    errdefer types.freeToolCallSlice(alloc, owned_calls);
    const owned_results = try types.dupePersistedToolResults(alloc, results.items);
    errdefer types.freePersistedToolResults(alloc, owned_results);
    const owned_text = if (text) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_text) |value| alloc.free(value);
    const old = turn.execution.tool_steps;
    const steps = try alloc.alloc(types.ToolExecutionStep, old.len + 1);
    @memcpy(steps[0..old.len], old);
    steps[old.len] = .{ .assistant = owned_text, .tool_calls = owned_calls, .tool_results = owned_results };
    if (old.len > 0) alloc.free(old);
    turn.execution.tool_steps = steps;
    return calls.items.len;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn conversationToolCall(call: types.ToolCall) session_event.ConversationToolCall {
    return .{
        .call_id = call.id,
        .tool_name = call.name,
        .arguments_json = call.arguments_json,
        .argument_integrity = call.argument_integrity,
        .provisional_id = call.provisional_id,
        .provider_result = call.provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

fn historyToolCall(call: session_event.ConversationToolCall) types.ToolCall {
    return .{
        .id = call.call_id,
        .name = call.tool_name,
        .arguments_json = call.arguments_json,
        .argument_integrity = call.argument_integrity,
        .provisional_id = call.provisional_id,
        .provider_result = call.provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

// ---------------------------------------------------------------------------
// Listing

const list_page_size: usize = 256;

/// Every saved root session, newest first, as v1's picker summaries, leaving
/// out `active_id`. A saved session always has a turn (D2), so each one can
/// be resumed. Stops with `error.Cancelled` once `cancel` is set. Caller
/// owns the list and every summary; safe from any thread.
pub fn listSummaries(
    store: *Store,
    alloc: Allocator,
    active_id: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
) !std.ArrayList(session_store.SessionSummary) {
    var list: std.ArrayList(session_store.SessionSummary) = .empty;
    errdefer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    if (cancel.load(.acquire)) return error.Cancelled;
    {
        // One read of the index, not one per page of it (D62).
        var page = try store.manager.list(alloc, .all, null, std.math.maxInt(usize));
        defer page.deinit();
        try list.ensureTotalCapacity(alloc, page.items.len);
        for (page.items) |item| {
            if (item.role != .root) continue;
            if (active_id) |active| if (std.mem.eql(u8, active, item.id)) continue;
            list.appendAssumeCapacity(try summaryOf(alloc, scratch.allocator(), item));
        }
    }
    // And v1's roots not converted yet (D59), which v2 wins on an id.
    if (cancel.load(.acquire)) return error.Cancelled;
    var v1_roots = try v1_conversion.listRoots(alloc, store.home, active_id);
    defer v1_roots.deinit(alloc);
    var held: std.StringHashMapUnmanaged(void) = .empty;
    try held.ensureTotalCapacity(scratch.allocator(), @intCast(list.items.len));
    for (list.items) |summary| held.putAssumeCapacity(summary.id, {});
    try list.ensureUnusedCapacity(alloc, v1_roots.summaries.items.len);
    var kept: usize = 0;
    for (v1_roots.summaries.items) |summary| {
        if (held.contains(summary.id)) {
            v1_roots.summaries.items[kept] = summary;
            kept += 1;
        } else list.appendAssumeCapacity(summary);
    }
    v1_roots.summaries.shrinkRetainingCapacity(kept);
    return list;
}

fn summaryOf(alloc: Allocator, scratch: Allocator, item: sm.Summary) !session_store.SessionSummary {
    const id = try alloc.dupe(u8, item.id);
    errdefer alloc.free(id);
    const workspace = try alloc.dupe(u8, item.workspace);
    errdefer alloc.free(workspace);
    const origin = try alloc.dupe(u8, item.workspace);
    errdefer alloc.free(origin);
    const title: ?[]u8 = if (item.title) |raw|
        try alloc.dupe(u8, try std.json.parseFromSliceLeaky([]const u8, scratch, raw, .{}))
    else
        null;
    errdefer if (title) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace,
        .origin_workspace_root = origin,
        .title = title,
        .display_metadata_present = title != null,
        .created_at_ms = std.math.cast(i64, item.created_ms) orelse 0,
        .updated_at_ms = std.math.cast(i64, item.updated_ms) orelse 0,
        .conversation_language = if (item.language) |raw| try decodeLanguage(scratch, raw) else types.ConversationLanguage.default(),
        .history_len = @max(item.turns, 1),
    };
}

// ---------------------------------------------------------------------------
// Usage recovery: what the profile's readers need from v2 sessions

/// A v2 session's usage-recovery marker and its newest usage checkpoint,
/// read without the session's lock. Owns everything.
pub const MarkedUsage = struct {
    id: []u8,
    /// Null when the session or its checkpoint cannot be read.
    snapshot: ?session_usage.Snapshot,
    /// When the checkpoint was written.
    at_ms: i64 = 0,
    protected_updated_at_ms: ?i64,
    marker_modified_at_ns: i128,

    pub fn deinit(marked: *MarkedUsage, alloc: Allocator) void {
        alloc.free(marked.id);
        if (marked.snapshot) |*snapshot| snapshot.deinit(alloc);
        marked.* = undefined;
    }
};

const max_usage_markers: usize = 512;

/// Every v2 usage-recovery marker under `home`, with v1's validation.
pub fn collectMarkedUsage(alloc: Allocator, home: []const u8) !std.ArrayList(MarkedUsage) {
    var list: std.ArrayList(MarkedUsage) = .empty;
    errdefer {
        for (list.items) |*entry| entry.deinit(alloc);
        list.deinit(alloc);
    }
    const path = try std.fs.path.join(alloc, &.{ home, profile_paths.root_dir_name, usage_markers_dir_name });
    defer alloc.free(path);
    var markers = io_mod.VerifiedDir{ .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return err,
    } };
    defer markers.close();
    var store = try Store.open(alloc, home);
    defer store.deinit(alloc);
    var it = markers.dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or list.items.len == max_usage_markers) return error.InvalidUsageRecoveryIndex;
        const protected = session_store.validateUsageRecoveryMarker(&markers, entry.name) catch return error.InvalidUsageRecoveryIndex;
        const stat = try markers.dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false });
        const id = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(id);
        const checkpoint = newestUsage(&store, alloc, id) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("usage", "event=sessions_v2_usage_unreadable session={s} err={s}", .{ id, @errorName(err) });
            break :blk null;
        };
        try list.append(alloc, .{
            .id = id,
            .snapshot = if (checkpoint) |c| c.snapshot else null,
            .at_ms = if (checkpoint) |c| c.at_ms else 0,
            .protected_updated_at_ms = protected,
            .marker_modified_at_ns = stat.mtime.nanoseconds,
        });
    }
    return list;
}

/// The newest `set usage`, or the usage in the newest snapshot, reading
/// back from the end without the session's lock.
fn newestUsage(store: *Store, alloc: Allocator, id: []const u8) !?UsageCheckpoint {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var from: sm.From = .end;
    while (true) {
        var page = try store.manager.read(sa, id, from, .backward, replay_page_lines);
        defer page.deinit();
        for (page.entries) |entry| {
            const body = entry.body orelse continue;
            switch (body) {
                .set => |setting| if (setting.key == .usage) return try decodeUsage(alloc, setting.value),
                .snapshot => |snapshot| {
                    const state = try std.json.parseFromSliceLeaky(std.json.Value, sa, snapshot.state, .{});
                    if (state != .object) return error.InvalidUsageCheckpoint;
                    const usage = state.object.get("usage") orelse return null;
                    return try decodeUsageValue(alloc, usage);
                },
                else => {},
            }
        }
        from = .{ .at = page.next orelse return null };
    }
}

/// v1's error names for a failed resume, so every host reports the same
/// error whichever backend is on.
/// Whether a failed write may still have reached the log: after any I/O
/// fault, whatever its cause, durability is unknown (D29).
pub fn writeMayHaveLanded(err: anyerror) bool {
    inline for (@typeInfo(sm.IoFault).error_set.?) |fault| {
        if (err == @field(sm.IoFault, fault.name)) return true;
    }
    return false;
}

const ResumeError = error{ SessionNotFound, NoSavedSessions, NoRememberedSession, SessionBusy, InvalidSessionFormat, UnsupportedSessionFormat } || sm.OpenError;

/// The storage causes a host names (D29), from an OS error; null for any
/// other error.
fn storageCause(err: anyerror) ?error{ NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig } {
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.FileTooBig => error.FileTooBig,
        else => null,
    };
}

fn resumeError(err: sm.OpenError, target: Target) ResumeError {
    return switch (err) {
        error.NotFound => switch (target) {
            .id => error.SessionNotFound,
            .last => error.NoSavedSessions,
            .last_opened => error.NoRememberedSession,
        },
        // A child is resumed only through its parent, as in v1.
        error.ChildSession => error.SessionNotFound,
        error.Busy => error.SessionBusy,
        error.Corrupt => error.InvalidSessionFormat,
        error.UnsupportedVersion => error.UnsupportedSessionFormat,
        else => err,
    };
}

/// Item type of a turn closed because its streamed pieces did not match
/// the final turn; resume drops that turn.
const superseded_type = "superseded";
/// A tool call saved before it runs (D28); its data is a `tool_call` piece.
const running_type = "tool_running";
/// The text of the message whose calls are running (D51).
const running_assistant_type = "assistant_running";
/// What the model reads for a call that was running when its turn ended.
pub const unfinished_tool_output = "fx stopped while this tool was running, so it may have partly run. Check its effects before running it again.";
const blob_ref_key = "$blob";
const blob_ref_prefix = "{\"" ++ blob_ref_key ++ "\":\"";

/// The blob a large piece's data refers to (`itemAs`), or null for a piece
/// held inline. Borrows from `data`.
fn blobRefOf(data: []const u8) ?[]const u8 {
    if (data.len != blob_ref_prefix.len + artifact_digest.blob_hex_bytes + 2) return null;
    if (!std.mem.startsWith(u8, data, blob_ref_prefix) or !std.mem.endsWith(u8, data, "\"}")) return null;
    return data[blob_ref_prefix.len..][0..artifact_digest.blob_hex_bytes];
}

const CompactedData = struct {
    summary: []const u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// The first turn the compaction kept, read back to on resume.
    keep_from_turn: ?u64 = null,
};

/// The compaction line a page read at its cursor starts with, or null when
/// that line is damaged. Open reads only line 1, the newest snapshot and the
/// tail, and every compaction is followed by a snapshot, so damage to its
/// line shows only here.
fn compactedData(page: *const sm.Page) ?[]const u8 {
    if (page.entries.len == 0) return null;
    const body = page.entries[0].body orelse return null;
    return switch (body) {
        .compacted => |line| line.data,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Encodings (pure)

/// The item `type` of each v1 piece kind.
fn itemType(kind: PieceKind) ?[]const u8 {
    return switch (kind) {
        .user => "user",
        .assistant => "assistant",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .steering => "steering",
        .turn_completed => "turn_end",
        .interrupted => "interruption",
        .context_checkpoint => null,
    };
}

fn pieceKind(item_type: []const u8) ?PieceKind {
    inline for (@typeInfo(PieceKind).@"enum".fields) |field| {
        const kind: PieceKind = @enumFromInt(field.value);
        if (itemType(kind)) |name| {
            if (std.mem.eql(u8, name, item_type)) return kind;
        }
    }
    return null;
}

/// A piece's payload as v1 writes it inside its frame.
/// Whether committing `execution` stores a body: a result without its
/// output's handle, or with images but no image handle, as
/// `session_log.externalizeConversationTurnResults` decides.
fn storesBodies(execution: types.ExecutionMemory) bool {
    for (execution.tool_steps) |step| for (step.tool_results) |result| {
        if (result.output_handle == null) return true;
        if (result.tool_images.len > 0 and result.tool_image_handle == null) return true;
    };
    return false;
}

const ListedBatch = struct {
    events: []const sm.Event,
    /// The pending blobs are on the batch's first item.
    listed: bool,
};

/// `events` with every pending blob on its first item, in `a`; unchanged
/// when it has no item or nothing is pending. Only the move lists blobs on a
/// setting (D47).
fn listPending(a: Allocator, events: []const sm.Event, pending: []const BlobHost.Hash) !ListedBatch {
    if (pending.len == 0) return .{ .events = events, .listed = false };
    const at = for (events, 0..) |event, index| {
        if (event == .item) break index;
    } else return .{ .events = events, .listed = false };
    const copy = try a.dupe(sm.Event, events);
    var refs: std.ArrayList([]const u8) = .empty;
    try refs.appendSlice(a, copy[at].item.blobs);
    for (pending) |*hash| {
        const known = for (refs.items) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        if (!known) try refs.append(a, hash);
    }
    copy[at].item.blobs = refs.items;
    return .{ .events = copy, .listed = true };
}

fn encodePiece(alloc: Allocator, event: Event) ![]u8 {
    try session_event.validateConversationEventShape(event, session_event.conversation_schema_version);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    switch (event) {
        .user => |user| {
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            try std.json.Stringify.value(try WireUser.of(scratch.allocator(), user), .{}, &out.writer);
        },
        inline else => |payload| try std.json.Stringify.value(payload, .{}, &out.writer),
    }
    return out.toOwnedSlice();
}

/// Payload slices point into `arena` or `data`.
/// With `.alloc_if_needed`, strings may point into `data`.
fn decodePiece(arena: Allocator, kind: PieceKind, data: []const u8, allocate: std.json.AllocWhen) !Event {
    const event: Event = switch (kind) {
        .user => .{ .user = try (try std.json.parseFromSliceLeaky(WireUser, arena, data, .{ .allocate = allocate })).toUser(arena) },
        inline else => |tag| @unionInit(Event, @tagName(tag), try std.json.parseFromSliceLeaky(
            @FieldType(Event, @tagName(tag)),
            arena,
            data,
            .{ .allocate = allocate },
        )),
    };
    try session_event.validateConversationEventShape(event, session_event.conversation_schema_version);
    return event;
}

/// A user piece as v2 writes it: `session_event.ConversationUser` field for
/// field, so a prompt without inline images encodes as v1's does. An
/// image's inline bytes, which a v2 session keeps inside the turn (D44),
/// are base64 text, since a JSON string cannot hold raw bytes.
const WireUser = struct {
    text: []const u8,
    images: []const WireImage = &.{},
    work_id: ?[]const u8 = null,

    /// `types.ImageAttachment` field for field, with `inline_data` in base64.
    const WireImage = struct {
        id: usize = 0,
        path: []const u8,
        media_type: []const u8,
        snapshot_path: ?[]const u8 = null,
        snapshot_sha256: ?[]const u8 = null,
        inline_data: ?[]const u8 = null,
        source_ref: ?[]const u8 = null,

        pub fn jsonStringify(self: WireImage, writer: *std.json.Stringify) !void {
            try writer.beginObject();
            inline for (std.meta.fields(WireImage)) |field| {
                if (!std.mem.eql(u8, field.name, "source_ref") or self.source_ref != null) {
                    try writer.objectField(field.name);
                    try writer.write(@field(self, field.name));
                }
            }
            try writer.endObject();
        }
    };

    const codec = std.base64.standard;

    fn of(a: Allocator, user: session_event.ConversationUser) !WireUser {
        const images = try a.alloc(WireImage, user.images.len);
        for (user.images, images) |image, *wire| {
            if (image.source_ref) |value| {
                if (!image_data.validSourceRef(value)) return error.InvalidSessionFormat;
            }
            wire.* = .{
                .id = image.id,
                .path = image.path,
                .media_type = image.media_type,
                .snapshot_path = image.snapshot_path,
                .snapshot_sha256 = image.snapshot_sha256,
                .inline_data = if (image.inline_data) |bytes| blk: {
                    const encoded = try a.alloc(u8, codec.Encoder.calcSize(bytes.len));
                    break :blk codec.Encoder.encode(encoded, bytes);
                } else null,
                .source_ref = image.source_ref,
            };
        }
        return .{ .text = user.text, .images = images, .work_id = user.work_id };
    }

    fn toUser(wire: WireUser, a: Allocator) !session_event.ConversationUser {
        const images = try a.alloc(types.ImageAttachment, wire.images.len);
        for (wire.images, images) |image, *out| {
            if (image.source_ref) |value| {
                if (!image_data.validSourceRef(value)) return error.InvalidSessionFormat;
            }
            out.* = .{
                .id = image.id,
                .path = try a.dupe(u8, image.path),
                .media_type = try a.dupe(u8, image.media_type),
                .snapshot_path = if (image.snapshot_path) |value| try a.dupe(u8, value) else null,
                .snapshot_sha256 = if (image.snapshot_sha256) |value| try a.dupe(u8, value) else null,
                .inline_data = if (image.inline_data) |encoded| blk: {
                    const size = codec.Decoder.calcSizeForSlice(encoded) catch return error.InvalidSessionFormat;
                    const bytes = try a.alloc(u8, size);
                    codec.Decoder.decode(bytes, encoded) catch return error.InvalidSessionFormat;
                    break :blk bytes;
                } else null,
                .source_ref = if (image.source_ref) |value| try a.dupe(u8, value) else null,
            };
        }
        return .{ .text = wire.text, .images = images, .work_id = wire.work_id };
    }
};

fn jsonValue(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn jsonString(alloc: Allocator, value: []const u8) ![]u8 {
    return jsonValue(alloc, value);
}

/// v1's shape, which `session_codec.parse_preferences` reads back: effort
/// as its label, the provider in its saved form.
/// A child's `prefs` also hold its instructions under this key (D34).
const instructions_key = "instructions";

fn encodePreferences(alloc: Allocator, preferences: session_codec.DurableSessionPreferences, instructions: ?[]const u8) ![]u8 {
    const Saved = struct {
        provider: model_provider.ProviderId,
        model: []const u8,
        effort: []const u8,
        fast_mode: bool,
        ultrafast_mode: ?bool,
        instructions: ?[]const u8,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Saved{
        .provider = preferences.provider,
        .model = preferences.model,
        .effort = preferences.effort.label(),
        .fast_mode = preferences.fast_mode,
        .ultrafast_mode = if (preferences.ultrafast_mode) true else null,
        .instructions = instructions,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.toOwnedSlice();
}

fn decodePreferences(alloc: Allocator, raw: []const u8) !session_codec.DurableSessionPreferences {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    // v1's codec knows every field but a child's instructions.
    if (parsed.value == .object) _ = parsed.value.object.swapRemove(instructions_key);
    return session_codec.parse_preferences(alloc, parsed.value);
}

/// A child's instructions from its `prefs`, or null. Caller owns.
fn decodeInstructions(alloc: Allocator, raw: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionFormat;
    const value = parsed.value.object.get(instructions_key) orelse return null;
    if (value != .string) return error.InvalidSessionFormat;
    return try alloc.dupe(u8, value.string);
}

fn decodeLanguage(arena: Allocator, raw: []const u8) !types.ConversationLanguage {
    const tag = try std.json.parseFromSliceLeaky([]const u8, arena, raw, .{});
    return session_codec.parseConversationLanguage(tag);
}

/// `{"at_ms":N,"snapshot":...}`: the snapshot as v1's usage file holds it.
fn encodeUsage(alloc: Allocator, snapshot: session_usage.Snapshot, at_ms: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"at_ms\":{d},\"snapshot\":", .{at_ms});
    try session_usage.writeRichSnapshot(&out.writer, snapshot);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const UsageCheckpoint = struct { snapshot: session_usage.Snapshot, at_ms: i64 };

fn decodeUsage(alloc: Allocator, raw: []const u8) !UsageCheckpoint {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    return decodeUsageValue(alloc, parsed.value);
}

fn decodeUsageValue(alloc: Allocator, value: std.json.Value) !UsageCheckpoint {
    if (value != .object) return error.InvalidUsageCheckpoint;
    const at = value.object.get("at_ms") orelse return error.InvalidUsageCheckpoint;
    if (at != .integer) return error.InvalidUsageCheckpoint;
    const snapshot = value.object.get("snapshot") orelse return error.InvalidUsageCheckpoint;
    return .{ .snapshot = try session_usage.parseSnapshotValue(alloc, snapshot), .at_ms = at.integer };
}

/// The title v1 derives from the first prompt of `history`, if any.
fn deriveTitle(arena: Allocator, history: []const types.HistoryTurn) !?[]const u8 {
    const display = session_display_metadata.deriveFromHistory(arena, history) catch return null;
    if (!display.present or std.mem.eql(u8, display.title, session_display_metadata.fallback_title)) return null;
    return display.title;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "every piece kind but checkpoints maps to one item type and back" {
    inline for (@typeInfo(PieceKind).@"enum".fields) |field| {
        const kind: PieceKind = @enumFromInt(field.value);
        if (itemType(kind)) |name| {
            try testing.expectEqual(@as(?PieceKind, kind), pieceKind(name));
        } else {
            try testing.expectEqual(PieceKind.context_checkpoint, kind);
        }
    }
    try testing.expectEqual(@as(?PieceKind, null), pieceKind("compacted"));
}

test "preferences round trip through v1's decoder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = "vendor/model-1".*;
    const efforts = [_]types.ReasoningEffort{ .auto, types.ReasoningEffort.parse("high").? };
    for (efforts) |effort| {
        const raw = try encodePreferences(arena.allocator(), .{ .model = &model, .effort = effort, .fast_mode = true, .ultrafast_mode = true }, null);
        try testing.expect((try decodeInstructions(testing.allocator, raw)) == null);
        var decoded = try decodePreferences(testing.allocator, raw);
        defer decoded.deinit(testing.allocator);
        try testing.expectEqualStrings("vendor/model-1", decoded.model);
        try testing.expectEqualStrings(effort.label(), decoded.effort.label());
        try testing.expect(decoded.fast_mode);
        try testing.expect(decoded.ultrafast_mode);
        try testing.expectEqual(model_provider.ProviderId.gateway, decoded.provider);
    }

    const off = try encodePreferences(arena.allocator(), .{ .model = &model, .effort = .auto, .fast_mode = false }, null);
    try testing.expectEqualStrings("{\"provider\":\"gateway\",\"model\":\"vendor/model-1\",\"effort\":\"auto\",\"fast_mode\":false}", off);
    var decoded_off = try decodePreferences(testing.allocator, off);
    defer decoded_off.deinit(testing.allocator);
    try testing.expect(!decoded_off.ultrafast_mode);
}

test "the switch is the flag or FX_SESSIONS_V2" {
    try testing.expect(enabled(true));
}

/// A HOME in a temp folder with an adapter store over it.
const TestHome = struct {
    tmp: testing.TmpDir,
    home: []u8,
    store: Store,

    fn init(t: *TestHome) !void {
        // Iterable, so Linux gives a real descriptor that `fsync` accepts
        // when a test makes `.fx` here (`io_mod.syncVerifiedDir`).
        t.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer t.tmp.cleanup();
        t.home = try io_mod.dirRealpathAlloc(testing.allocator, t.tmp.dir, ".");
        errdefer testing.allocator.free(t.home);
        t.store = try Store.open(testing.allocator, t.home);
    }

    fn deinit(t: *TestHome) void {
        t.store.deinit(testing.allocator);
        testing.allocator.free(t.home);
        t.tmp.cleanup();
    }
};

fn testSeed(model: []u8) Seed {
    return .{
        .preferences = .{ .model = model, .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    };
}

fn assistantTurn(user: []const u8, reply: []const u8) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast(user) },
        .assistant = @constCast(reply),
    } };
}

test "a new session commits turns, and resume gives them back with its settings" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "test-model".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("first question", "first answer"), types.ConversationLanguage.default());
    try s.commitTurn(.{ .interrupted = .{
        .user = .{ .text = @constCast("second question") },
        .assistant = @constCast("partial"),
        .terminal_reason = .failed,
    } }, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("first question", restored.history[0].assistant.user.text);
    try testing.expectEqualStrings("first answer", restored.history[0].assistant.assistant);
    try testing.expectEqualStrings("partial", restored.history[1].interrupted.assistant.?);
    try testing.expectEqual(types.InterruptedTerminalReason.failed, restored.history[1].interrupted.terminal_reason);
    try testing.expectEqualStrings("test-model", restored.preferences.?.model);
    try testing.expect(restored.created_at_ms > 0);
    // The first turn named the session.
    var st = try r.handle.state(testing.allocator);
    defer st.deinit(testing.allocator);
    try testing.expectEqualStrings("\"first question\"", st.title.?);
}

test "a child's prefs keep its instructions, and v1's decoder still reads the rest (D34)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var model = "vendor/model-1".*;
    const raw = try encodePreferences(arena.allocator(), .{ .model = &model, .effort = .auto, .fast_mode = false }, "Answer in one line.");
    const instructions = (try decodeInstructions(testing.allocator, raw)).?;
    defer testing.allocator.free(instructions);
    try testing.expectEqualStrings("Answer in one line.", instructions);
    var decoded = try decodePreferences(testing.allocator, raw);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("vendor/model-1", decoded.model);
}

fn childSeed(model: []u8, instructions: []const u8) Seed {
    var seed = testSeed(model);
    seed.instructions = instructions;
    return seed;
}

test "a child opens under the id its parent names, and its parent folds its lines (D22, D34)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const alloc = testing.allocator;
    var model = "test-model".*;
    const parent = try Session.create(alloc, &t.store, "/w", .ask, testSeed(&model));
    defer parent.close();
    try parent.commitTurn(assistantTurn("delegate this", "delegated"), types.ConversationLanguage.default());
    const child_id = "1786460757753-kid";
    try parent.appendChildLines(&.{.{ .spawned = .{ .child = child_id, .work_id = "w1", .data = "{\"kind\":\"persistent\"}" } }});

    {
        const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", childSeed(&model, "Be brief."));
        defer child.close();
        try testing.expectEqualStrings(child_id, child.id());
        try testing.expectEqualStrings("Be brief.", child.childInstructions());
        try child.commitTurn(assistantTurn("task one", "done one"), types.ConversationLanguage.default());
    }
    try parent.appendChildLines(&.{.{ .finished = .{ .child = child_id, .work_id = "w1", .outcome = .ok, .data = "{}" } }});

    const children = try parent.children(alloc);
    defer freeChildren(alloc, children);
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings(child_id, children[0].id);
    try testing.expectEqualStrings("w1", children[0].work_id);
    try testing.expect(!children[0].open);
    try testing.expectEqual(ChildOutcome.ok, children[0].outcome.?);
    try testing.expectEqualStrings("{\"kind\":\"persistent\"}", children[0].spawn_data.?);
    try testing.expectEqualStrings("{}", children[0].finish_data.?);

    // Read by id, without the child's lock.
    const history = try t.store.childHistory(alloc, child_id);
    defer types.freeHistoryTurnSlice(alloc, history);
    try testing.expectEqual(@as(usize, 1), history.len);
    try testing.expectEqualStrings("done one", history[0].assistant.assistant);
    var preferences = try t.store.childPreferences(alloc, child_id);
    defer preferences.deinit(alloc);
    try testing.expectEqualStrings("test-model", preferences.model);

    // New instructions replace the stored ones; none keeps them.
    {
        const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", childSeed(&model, "Be thorough."));
        defer child.close();
        try testing.expectEqualStrings("Be thorough.", child.childInstructions());
    }
    {
        const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", testSeed(&model));
        defer child.close();
        try testing.expectEqualStrings("Be thorough.", child.childInstructions());
        var restored = try child.restore(alloc);
        defer restored.deinit(alloc);
        try testing.expectEqualStrings("test-model", restored.preferences.?.model);
        try testing.expectEqual(@as(usize, 1), restored.history.len);
    }
    // Children stay out of the session list.
    var page = try t.store.manager.list(alloc, .all, null, 10);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
}

test "the manager guards child lines, and a child without a log reopens under its id (D22, D34)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const alloc = testing.allocator;
    var model = "test-model".*;
    const parent = try Session.create(alloc, &t.store, "/w", .ask, testSeed(&model));
    defer parent.close();
    try parent.commitTurn(assistantTurn("delegate", "ok"), types.ConversationLanguage.default());
    const child_id = "1786460757753-lost";
    try parent.appendChildLines(&.{.{ .spawned = .{ .child = child_id, .work_id = "w1" } }});
    try testing.expectError(error.InvalidTransition, parent.appendChildLines(&.{.{ .spawned = .{ .child = child_id, .work_id = "w2" } }}));
    try testing.expectError(error.InvalidTransition, parent.appendChildLines(&.{.{ .finished = .{ .child = child_id, .work_id = "w9", .outcome = .ok } }}));

    // Closed before its first turn, as a crash would leave it: nothing on disk.
    (try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", childSeed(&model, "Stay short."))).close();
    try testing.expectError(error.NotFound, t.store.childHistory(alloc, child_id));
    const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", testSeed(&model));
    defer child.close();
    try testing.expectEqualStrings(child_id, child.id());
    try testing.expectEqualStrings("", child.childInstructions());
}

test "v2 child ultrafast preferences survive instruction changes and resume" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const alloc = testing.allocator;
    var model = "test-model".*;
    const parent = try Session.create(alloc, &t.store, "/w", .ask, testSeed(&model));
    defer parent.close();
    try parent.commitTurn(assistantTurn("delegate", "ok"), types.ConversationLanguage.default());
    const child_id = "1786460757753-ultra";
    try parent.appendChildLines(&.{.{ .spawned = .{ .child = child_id, .work_id = "w1" } }});
    var seed = childSeed(&model, "Be brief.");
    seed.preferences.ultrafast_mode = true;
    {
        const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", seed);
        defer child.close();
        try child.commitTurn(assistantTurn("task", "done"), types.ConversationLanguage.default());
        var preferences = try child.currentPreferences(alloc);
        defer preferences.deinit(alloc);
        try testing.expect(preferences.ultrafast_mode);
    }
    seed.instructions = "Be thorough.";
    {
        const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", seed);
        defer child.close();
        var preferences = try child.currentPreferences(alloc);
        defer preferences.deinit(alloc);
        try testing.expect(preferences.ultrafast_mode);
        preferences.ultrafast_mode = false;
        try child.setPreferences(preferences);
        try testing.expectEqualStrings("Be thorough.", child.childInstructions());
    }
    seed.instructions = "Answer in one line.";
    const child = try Session.openChild(alloc, &t.store, parent.id(), child_id, "/w", seed);
    defer child.close();
    var preferences = try child.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    try testing.expect(!preferences.ultrafast_mode);
    try testing.expectEqualStrings("Answer in one line.", child.childInstructions());
    var state = try child.handle.state(alloc);
    defer state.deinit(alloc);
    try testing.expect(std.mem.find(u8, state.prefs.?, "\"ultrafast_mode\"") == null);
}

test "a copy of a parent's children frees every part when memory runs out" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const parent = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    defer parent.close();
    try parent.commitTurn(assistantTurn("delegate", "ok"), types.ConversationLanguage.default());
    try parent.appendChildLines(&.{.{ .spawned = .{ .child = "1786460757753-one", .work_id = "w1", .data = "{}" } }});
    try parent.appendChildLines(&.{.{ .finished = .{ .child = "1786460757753-one", .work_id = "w1", .outcome = .ok, .data = "{}" } }});
    try parent.appendChildLines(&.{.{ .spawned = .{ .child = "1786460757753-two", .work_id = "w2", .data = "{}" } }});
    const Copy = struct {
        fn run(alloc: Allocator, session: *Session) !void {
            freeChildren(alloc, try session.children(alloc));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Copy.run, .{parent});
}

fn countItems(manager: *sm.Manager, id: []const u8, item_type: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .item and std.mem.eql(u8, body.item.type, item_type)) n += 1;
    }
    return n;
}

test "streamed pieces are written once, and the commit adds only the rest" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("streamed question") };
    try s.appendProgress(user, .{}, .{});
    // The first piece published the session.
    try testing.expect(s.saved());
    try s.appendProgress(user, .{}, .{});
    try s.commitTurn(.{ .assistant = .{ .user = user, .assistant = @constCast("streamed answer") } }, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "user"));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "turn_end"));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqualStrings("streamed answer", restored.history[0].assistant.assistant);
}

test "any I/O fault may have left a write in the log" {
    inline for (.{ error.Io, error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig }) |err| {
        try testing.expect(writeMayHaveLanded(err));
    }
    try testing.expect(!writeMayHaveLanded(error.Busy));
    try testing.expect(!writeMayHaveLanded(error.InvalidTransition));
    try testing.expect(!writeMayHaveLanded(error.OutOfMemory));
}

test "a running tool call is saved once, and resume answers it as possibly run" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("run it") };
    const call: types.ToolCall = .{ .id = "call_1", .name = "bash", .arguments_json = "{\"command\":\"sleep 9\"}" };
    try s.appendProgress(user, .{}, .{ .calls = &.{call} });
    try testing.expect(s.saved());
    try s.appendProgress(user, .{}, .{ .calls = &.{call} });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, running_type));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "user"));
    // Closing in the middle of the turn ends it `closed`.
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    const turn = restored.history[0].interrupted;
    try testing.expectEqualStrings("run it", turn.user.text);
    try testing.expect(turn.tool_call == null);
    try testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    const step = turn.execution.tool_steps[0];
    try testing.expectEqual(@as(usize, 1), step.tool_calls.len);
    try testing.expectEqualStrings("call_1", step.tool_calls[0].id);
    try testing.expectEqualStrings("bash", step.tool_calls[0].name);
    try testing.expectEqualStrings("{\"command\":\"sleep 9\"}", step.tool_calls[0].arguments_json);
    try testing.expectEqual(@as(usize, 1), step.tool_results.len);
    try testing.expectEqualStrings("call_1", step.tool_results[0].tool_call_id);
    try testing.expectEqualStrings("bash", step.tool_results[0].tool_name);
    try testing.expectEqual(types.PersistedToolStatus.failure, step.tool_results[0].status);
    try testing.expectEqualStrings(unfinished_tool_output, step.tool_results[0].output);
}

test "a crash while a tool runs keeps the text of the message that issued it (D51)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("build it") };
    const call: types.ToolCall = .{ .id = "call_1", .name = "bash", .arguments_json = "{\"command\":\"bash build.sh\"}" };
    const plan = "It makes .build and prints forty steps. Running it now.";
    try s.appendProgress(user, .{}, .{ .calls = &.{call}, .assistant = plan });
    // Saved once with its calls; the same step reported again adds nothing.
    try s.appendProgress(user, .{}, .{ .calls = &.{call}, .assistant = plan });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, running_assistant_type));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, running_type));
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    const turn = restored.history[0].interrupted;
    try testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    const step = turn.execution.tool_steps[0];
    try testing.expectEqualStrings(plan, step.assistant.?);
    try testing.expectEqualStrings("call_1", step.tool_calls[0].id);
    try testing.expectEqualStrings(unfinished_tool_output, step.tool_results[0].output);
}

test "text an earlier step finished with never lands on a later running step without text (D51)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("two steps") };
    const first: types.ToolCall = .{ .id = "call-1", .name = "shell", .arguments_json = "{}" };
    const second: types.ToolCall = .{ .id = "call-2", .name = "bash", .arguments_json = "{\"command\":\"sleep 9\"}" };
    try s.appendProgress(user, .{}, .{ .calls = &.{first}, .assistant = "plan A" });
    // The first step finishes with its text; the second runs with none.
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("listed"),
        .output_bytes = 6,
        .stored_output_bytes = 6,
    }};
    var steps: [1]types.ToolExecutionStep = undefined;
    const turn = toolTurn("two steps", &results, &steps);
    steps[0].assistant = @constCast("plan A");
    try s.appendProgress(user, turn.assistant.execution, .{ .calls = &.{second} });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, running_assistant_type));
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const interrupted = restored.history[0].interrupted;
    try testing.expectEqual(@as(usize, 2), interrupted.execution.tool_steps.len);
    try testing.expectEqualStrings("plan A", interrupted.execution.tool_steps[0].assistant.?);
    try testing.expectEqual(types.PersistedToolStatus.success, interrupted.execution.tool_steps[0].tool_results[0].status);
    const repaired = interrupted.execution.tool_steps[1];
    try testing.expectEqual(@as(?[]u8, null), repaired.assistant);
    try testing.expectEqualStrings("call-2", repaired.tool_calls[0].id);
    try testing.expectEqualStrings(unfinished_tool_output, repaired.tool_results[0].output);
}

test "a crash answers only the running calls its turn does not already hold" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user_piece = try encodePiece(a, .{ .user = .{ .text = "two tools" } });
    const first = try encodePiece(a, .{ .tool_call = .{ .call_id = "call_1", .tool_name = "bash", .arguments_json = "{}" } });
    const second = try encodePiece(a, .{ .tool_call = .{ .call_id = "call_2", .tool_name = "read_file", .arguments_json = "{\"path\":\"a\"}" } });
    const imported = try t.store.manager.openImport(.{ .id = "1786460757753-tools", .workspace = "/w", .host = .ask, .created_ms = 1000 });
    _ = try imported.appendAt(&.{
        .turn_started,
        .{ .item = .{ .type = "user", .data = user_piece } },
        .{ .item = .{ .type = running_type, .data = first } },
        .{ .item = .{ .type = running_type, .data = second } },
        // The turn already holds call_1, as its one pending call.
        .{ .item = .{ .type = "tool_call", .data = first } },
        .{ .turn_interrupted = .crash },
    }, 2000);
    try imported.publishImport();
    imported.release();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = "1786460757753-tools" }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    const turn = restored.history[0].interrupted;
    try testing.expectEqual(types.InterruptedTerminalReason.failed, turn.terminal_reason);
    try testing.expectEqualStrings("call_1", turn.tool_call.?.id);
    try testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    const step = turn.execution.tool_steps[0];
    try testing.expectEqual(@as(usize, 1), step.tool_calls.len);
    try testing.expectEqualStrings("call_2", step.tool_calls[0].id);
    try testing.expectEqualStrings("call_2", step.tool_results[0].tool_call_id);
    try testing.expectEqualStrings(unfinished_tool_output, step.tool_results[0].output);
}

fn countTitleSets(manager: *sm.Manager, id: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .set and body.set.key == .title) n += 1;
    }
    return n;
}

fn storedTitle(s: *Session) !?[]u8 {
    const shown = try s.info(testing.allocator);
    return shown.title;
}

test "a session whose first turn never ended takes its first prompt as title at its next turn end (D52)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.appendProgress(.{ .text = @constCast("Why is the sky orange at dusk?") }, .{}, .{});
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    // The first turn never ends through fx, as when fx is killed.
    s.close();
    try testing.expectEqual(@as(usize, 0), try countTitleSets(t.store.manager, id));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expect(restored.title == null);
    try testing.expect(restored.history[0] == .interrupted);
    try r.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("next") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    const title = (try storedTitle(r)) orelse return error.TestExpectedTitle;
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Why is the sky orange at dusk?", title);
    // Written once; later turns leave it.
    try r.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("again") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    try testing.expectEqual(@as(usize, 1), try countTitleSets(t.store.manager, id));
}

test "a resumed session keeps the title it has (D52)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("First question") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    try s.rename("Mine");
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 2), try countTitleSets(t.store.manager, id));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try r.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("Second question") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    const title = (try storedTitle(r)) orelse return error.TestExpectedTitle;
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Mine", title);
    try testing.expectEqual(@as(usize, 2), try countTitleSets(t.store.manager, id));
}

test "a finished turn keeps no trace of its running calls" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("asked") };
    const call: types.ToolCall = .{ .id = "call_9", .name = "bash", .arguments_json = "{}" };
    try s.appendProgress(user, .{}, .{ .calls = &.{call} });
    try s.commitTurn(.{ .assistant = .{ .user = user, .assistant = @constCast("answered") } }, types.ConversationLanguage.default());
    // The next turn starts with nothing saved as running.
    try testing.expectEqual(@as(usize, 0), s.running.items.len);
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqualStrings("answered", restored.history[0].assistant.assistant);
    try testing.expectEqual(@as(usize, 0), restored.history[0].assistant.execution.tool_steps.len);
}

test "the history visit shows every turn, even those a compaction summarized" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    defer s.close();
    const language = types.ConversationLanguage.default();
    try s.commitTurn(assistantTurn("one", "a"), language);
    try s.commitTurn(assistantTurn("two", "b"), language);
    try s.commitCompaction(.{ .summary = @constCast("summary"), .removed_turn_count = 2, .compaction_count = 1 }, false, null);
    try s.commitTurn(assistantTurn("three", "c"), language);

    const Visitor = struct {
        prompts: std.ArrayList([]u8) = .empty,
        fail_at: ?usize = null,

        pub fn append(self: *@This(), turn: types.HistoryTurn) !void {
            if (self.fail_at == self.prompts.items.len) return error.ConsumerFailed;
            try self.prompts.append(testing.allocator, try testing.allocator.dupe(u8, turn.assistant.user.text));
        }

        fn deinit(self: *@This()) void {
            for (self.prompts.items) |prompt| testing.allocator.free(prompt);
            self.prompts.deinit(testing.allocator);
        }
    };
    const numbers = try testing.allocator.dupe(?u64, s.turn_numbers.items);
    defer testing.allocator.free(numbers);
    var visitor: Visitor = .{};
    defer visitor.deinit();
    try s.visitHistory(testing.allocator, &visitor);
    try testing.expectEqual(@as(usize, 3), visitor.prompts.items.len);
    for (visitor.prompts.items, [_][]const u8{ "one", "two", "three" }) |got, want| try testing.expectEqualStrings(want, got);
    // The visit leaves what resume and compaction rely on unchanged.
    try testing.expectEqualSlices(?u64, numbers, s.turn_numbers.items);

    // A visitor that fails stops the visit without leaking its turn.
    var failing: Visitor = .{ .fail_at = 1 };
    defer failing.deinit();
    try testing.expectError(error.ConsumerFailed, s.visitHistory(testing.allocator, &failing));
    try testing.expectEqual(@as(usize, 1), failing.prompts.items.len);

    // A visitor may call back into the session, as the app does to read a
    // command replay's side file while it draws a turn.
    const Reentrant = struct {
        session: *Session,
        visits: usize = 0,

        pub fn append(self: *@This(), _: types.HistoryTurn) !void {
            // Fails rather than hangs if the visit holds the adapter's lock.
            if (!self.session.mutex.tryLock()) return error.VisitHeldSessionLock;
            self.session.mutex.unlock(io_mod.getIo());
            _ = try self.session.childCapability();
            self.visits += 1;
        }
    };
    var reentrant: Reentrant = .{ .session = s };
    try s.visitHistory(testing.allocator, &reentrant);
    try testing.expectEqual(@as(usize, 3), reentrant.visits);

    // Resume still starts from the summary.
    var restored = try s.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("summary", restored.history[0].compacted_summary.summary);
    try testing.expectEqualStrings("three", restored.history[1].assistant.user.text);
}

test "a tool result backed only by its command replay streams as it commits" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("run it") };
    var calls = [_]types.ToolCall{.{ .id = "call-1", .name = "shell", .arguments_json = "{}" }};
    // As a shell result arrives with `.required` command replay: no result file yet.
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("REPLAY_ONLY_OUTPUT"),
        .output_bytes = 18,
        .stored_output_bytes = 18,
        .command_output_replay = .{ .available = .{ .handle = "fx-command-replay-0-0.bin", .framed_bytes = 27 } },
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const execution: types.ExecutionMemory = .{ .tool_steps = &steps };
    try s.appendProgress(user, execution, .{});
    try s.appendProgress(user, execution, .{});
    const streamed = s.stored_results.get("call-1").?;
    const written = try (try s.childCapability()).readBlob(testing.allocator, .tool_results, streamed, 1024);
    defer testing.allocator.free(written);
    // The commit gets the agent's own turn, still without a result file;
    // preparing it fills in the handle and preview.
    try testing.expectEqual(@as(?[]u8, null), results[0].output_handle);
    try testing.expectEqualStrings("REPLAY_ONLY_OUTPUT", written);
    var turn: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("done"), .execution = execution } };
    try s.prepareTurn(&turn);
    defer testing.allocator.free(results[0].output_handle.?);
    defer testing.allocator.free(results[0].preview.?);
    // The same blob: its name is its content's hash.
    try testing.expectEqualStrings(streamed, results[0].output_handle.?);
    try s.commitTurn(turn, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 0), try countItems(t.store.manager, id, superseded_type));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "tool_result"));
}

test "a tool result's rebuild time alone does not supersede its stream" {
    const a = "{\"call_id\":\"c\",\"created_at_ms\":100,\"preview\":\"x\"}";
    const b = "{\"call_id\":\"c\",\"created_at_ms\":142,\"preview\":\"x\"}";
    const c = "{\"call_id\":\"c\",\"created_at_ms\":142,\"preview\":\"y\"}";
    try testing.expect(samePiece(testing.allocator, a, a));
    try testing.expect(samePiece(testing.allocator, a, b));
    try testing.expect(!samePiece(testing.allocator, a, c));
    try testing.expect(!samePiece(testing.allocator, "{\"text\":\"a\"}", "{\"text\":\"b\"}"));
}

test "a streamed turn that differs from its commit is superseded, never mixed" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.appendProgress(.{ .text = @constCast("draft") }, .{}, .{});
    try s.commitTurn(assistantTurn("final", "answer"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, superseded_type));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqualStrings("final", restored.history[0].assistant.user.text);
}

test "a turn ended by a close or a crash comes back interrupted" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const language = types.ConversationLanguage.default();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const user_piece = try encodePiece(arena.allocator(), .{ .user = .{ .text = "unfinished" } });

    // A close in the middle of a turn: the manager ends it `closed`.
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("done", "yes"), language);
    _ = try s.handle.append(&.{ .turn_started, .{ .item = .{ .type = "user", .data = user_piece } } });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), restored.history.len);
        try testing.expectEqualStrings("unfinished", restored.history[1].interrupted.user.text);
        try testing.expectEqual(types.InterruptedTerminalReason.cancelled, restored.history[1].interrupted.terminal_reason);
    }

    // A crash, written through the API as the v1 converter writes one.
    const crashed_id = "1786460757753-crash";
    const imported = try t.store.manager.openImport(.{ .id = crashed_id, .workspace = "/w", .host = .ask, .created_ms = 1000 });
    _ = try imported.appendAt(&.{ .turn_started, .{ .item = .{ .type = "user", .data = user_piece } }, .{ .turn_interrupted = .crash } }, 2000);
    try imported.publishImport();
    imported.release();
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = crashed_id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqual(types.InterruptedTerminalReason.failed, restored.history[0].interrupted.terminal_reason);
    try testing.expectEqual(@as(i64, 1000), restored.created_at_ms);
}

test "resume after a compaction starts with its summary and keeps the retained turn" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("one", "1"), types.ConversationLanguage.default());
    try s.commitTurn(assistantTurn("two", "2"), types.ConversationLanguage.default());
    try s.commitTurn(assistantTurn("three", "3"), types.ConversationLanguage.default());
    var summary = "turns one and two".*;
    try s.commitCompaction(.{ .summary = &summary, .removed_turn_count = 2, .compaction_count = 1 }, false, .{ .turns = 2 });
    try s.commitTurn(assistantTurn("four", "4"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), restored.history.len);
    try testing.expectEqualStrings("turns one and two", restored.history[0].compacted_summary.summary);
    try testing.expectEqualStrings("three", restored.history[1].assistant.user.text);
    try testing.expectEqualStrings("four", restored.history[2].assistant.user.text);
}

test "each later compaction keeps only the turns after its cut" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const language = types.ConversationLanguage.default();
    try s.commitTurn(assistantTurn("one", "1"), language);
    try s.commitTurn(assistantTurn("two", "2"), language);
    var first = "turn one".*;
    try s.commitCompaction(.{ .summary = &first, .removed_turn_count = 1, .compaction_count = 1 }, false, .{ .turns = 1 });
    // From here fx's history starts with the summary, and each cut counts
    // only the raw turns after it, so `.turns = 1` keeps the newest turn.
    try s.commitTurn(assistantTurn("three", "3"), language);
    var second = "turns one and two".*;
    try s.commitCompaction(.{ .summary = &second, .removed_turn_count = 2, .compaction_count = 2 }, false, .{ .turns = 1 });
    try s.commitTurn(assistantTurn("four", "4"), language);
    var third = "turns one to three".*;
    try s.commitCompaction(.{ .summary = &third, .removed_turn_count = 3, .compaction_count = 3 }, false, .{ .turns = 1 });
    try s.commitTurn(assistantTurn("five", "5"), language);
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), restored.history.len);
    try testing.expectEqualStrings("turns one to three", restored.history[0].compacted_summary.summary);
    try testing.expectEqualStrings("four", restored.history[1].assistant.user.text);
    try testing.expectEqualStrings("five", restored.history[2].assistant.user.text);
}

test "resume refuses a session whose compaction line is damaged" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("one", "1"), types.ConversationLanguage.default());
    try s.commitTurn(assistantTurn("two", "2"), types.ConversationLanguage.default());
    var summary = "turns one and two".*;
    try s.commitCompaction(.{ .summary = &summary, .removed_turn_count = 2, .compaction_count = 1 }, false, null);
    try s.commitTurn(assistantTurn("three", "3"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    // One byte of the summary changes, so its line fails its check. Open
    // reads past it: a snapshot follows every compaction.
    const io = io_mod.getIo();
    const log_path = try std.fs.path.join(testing.allocator, &.{ ".fx", "sessions", "v2", id, "log.jsonl" });
    defer testing.allocator.free(log_path);
    const bytes = try t.tmp.dir.readFileAlloc(io, log_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    const at = std.mem.find(u8, bytes, "turns one and two") orelse return error.TestUnexpectedResult;
    bytes[at] = 'T';
    try t.tmp.dir.writeFile(io, .{ .sub_path = log_path, .data = bytes });

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    try testing.expectError(error.InvalidSessionFormat, r.restore(testing.allocator));
}

test "fx session lists every turn with each summary where it happened, as v1 counts it (D32)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const language = types.ConversationLanguage.default();
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("one", "1"), language);
    try s.commitTurn(assistantTurn("two", "2"), language);
    // fx's own count differs from the log's; the listing counts the log.
    var first = "turn one".*;
    try s.commitCompaction(.{ .summary = &first, .removed_turn_count = 1, .compaction_count = 1 }, false, .{ .turns = 1 });
    try s.commitTurn(assistantTurn("three", "3"), language);
    var second = "turns one to three".*;
    try s.commitCompaction(.{ .summary = &second, .removed_turn_count = 2, .compaction_count = 2 }, false, null);
    try s.commitTurn(assistantTurn("four", "4"), language);
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    var detail = try readSession(&t.store, testing.allocator, id);
    defer detail.deinit(testing.allocator);
    const Want = struct { prompt: ?[]const u8 = null, summary: ?[]const u8 = null, removed: usize = 0, count: usize = 0 };
    const want = [_]Want{
        .{ .prompt = "one" },
        .{ .prompt = "two" },
        .{ .summary = "turn one", .removed = 2, .count = 1 },
        .{ .prompt = "three" },
        .{ .summary = "turns one to three", .removed = 3, .count = 2 },
        .{ .prompt = "four" },
    };
    try testing.expectEqual(want.len, detail.state.history.len);
    for (want, detail.state.history) |w, got| {
        if (w.summary) |text| {
            try testing.expectEqualStrings(text, got.compacted_summary.summary);
            try testing.expectEqual(w.removed, got.compacted_summary.removed_turn_count);
            try testing.expectEqual(w.count, got.compacted_summary.compaction_count);
        } else try testing.expectEqualStrings(w.prompt.?, got.assistant.user.text);
    }

    // Resume still starts at the newest summary.
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("turns one to three", restored.history[0].compacted_summary.summary);
    try testing.expectEqualStrings("four", restored.history[1].assistant.user.text);
}

test "a piece above the inline limit goes to a blob and comes back whole" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const big = try testing.allocator.alloc(u8, max_inline_piece_bytes + 10);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try s.commitTurn(assistantTurn("big", big), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqualStrings(big, restored.history[0].assistant.assistant);
}

test "usage is durable before its marker goes, and resume restores it" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(testing.allocator);
    var snapshot = try usage.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try s.persistUsage(snapshot);
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    // Nothing left to publish: the marker is gone.
    var markers = try t.tmp.dir.openDir(io_mod.getIo(), ".fx/" ++ usage_markers_dir_name, .{});
    defer markers.close(io_mod.getIo());
    try testing.expectError(error.FileNotFound, markers.statFile(io_mod.getIo(), id, .{}));
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expect(restored.usage != null);
}

test "a usage marker that cannot be written names a storage cause (D29)" {
    // The real write is proven on a full disk end to end; opening the
    // markers folder makes it private again, so a unit test cannot block it.
    const Cause = ?error{ NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig };
    try testing.expectEqual(@as(Cause, error.NoSpaceLeft), storageCause(error.NoSpaceLeft));
    try testing.expectEqual(@as(Cause, error.AccessDenied), storageCause(error.AccessDenied));
    try testing.expectEqual(@as(Cause, error.AccessDenied), storageCause(error.PermissionDenied));
    try testing.expectEqual(@as(Cause, error.ReadOnlyFileSystem), storageCause(error.ReadOnlyFileSystem));
    try testing.expectEqual(@as(Cause, error.FileTooBig), storageCause(error.FileTooBig));
    try testing.expectEqual(@as(Cause, null), storageCause(error.InputOutput));
}

test "a failed resume reports v1's error names" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectError(error.NoSavedSessions, Session.resumeSession(testing.allocator, &t.store, .last, "/w", .ask));
    try testing.expectError(error.SessionNotFound, Session.resumeSession(testing.allocator, &t.store, .{ .id = "AAAAAAAAAAAA" }, "/w", .ask));
    try testing.expectEqual(error.SessionBusy, resumeError(error.Busy, .last));
    try testing.expectEqual(error.SessionNotFound, resumeError(error.ChildSession, .{ .id = "AAAAAAAAAAAA" }));
    try testing.expectEqual(error.InvalidSessionFormat, resumeError(error.Corrupt, .last));
    try testing.expectEqual(error.UnsupportedSessionFormat, resumeError(error.UnsupportedVersion, .last));
    try testing.expectEqual(error.Io, resumeError(error.Io, .last));
    // An OS cause reaches the user as itself (D29).
    try testing.expectEqual(error.NoSpaceLeft, resumeError(error.NoSpaceLeft, .last));
    try testing.expectEqual(error.ReadOnlyFileSystem, resumeError(error.ReadOnlyFileSystem, .{ .id = "AAAAAAAAAAAA" }));
}

test "a resumed session gives v1's state and the title the user chose" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    try s.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    try s.rename("Chosen title");
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    defer r.close();
    var resumed = try r.durableState(testing.allocator, "/w");
    defer resumed.deinit(testing.allocator);
    try testing.expectEqualStrings(id, resumed.state.id);
    try testing.expectEqualStrings("/w", resumed.state.workspace_root);
    try testing.expectEqual(@as(usize, 1), resumed.state.history.len);
    try testing.expectEqualStrings("m", resumed.state.preferences.model);
    try testing.expectEqualStrings("Chosen title", resumed.title.?);
    try testing.expect(resumed.state.created_at_ms > 0);
    try testing.expect(resumed.state.updated_at_ms >= resumed.state.created_at_ms);
    // A generated title does not replace the one the user chose.
    try testing.expect(!try r.installGeneratedTitle(resumed.state.history, "Generated"));
}

test "the picker lists saved root sessions newest first, without the open one" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const first = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    try first.commitTurn(assistantTurn("first", "a"), types.ConversationLanguage.default());
    const first_id = try testing.allocator.dupe(u8, first.id());
    defer testing.allocator.free(first_id);
    first.close();
    // A session with no turn is not saved, so it is never listed (D2).
    const empty = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    empty.close();
    io_mod.sleep(2 * std.time.ns_per_ms);
    const second = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer second.close();
    try second.commitTurn(assistantTurn("second", "b"), types.ConversationLanguage.default());

    var cancel = std.atomic.Value(bool).init(false);
    var all = try listSummaries(&t.store, testing.allocator, null, &cancel);
    defer {
        for (all.items) |*summary| summary.deinit(testing.allocator);
        all.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), all.items.len);
    try testing.expectEqualStrings(second.id(), all.items[0].id);
    try testing.expectEqualStrings("/w", all.items[0].workspace_root.?);
    try testing.expect(all.items[0].hasResumableContent());

    var others = try listSummaries(&t.store, testing.allocator, second.id(), &cancel);
    defer {
        for (others.items) |*summary| summary.deinit(testing.allocator);
        others.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), others.items.len);
    try testing.expectEqualStrings(first_id, others.items[0].id);

    cancel.store(true, .release);
    try testing.expectError(error.Cancelled, listSummaries(&t.store, testing.allocator, null, &cancel));
}

test "-c resumes the session this host last opened" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    try s.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const again = try Session.resumeSession(testing.allocator, &t.store, .last_opened, "/w", .app);
    defer again.close();
    try testing.expectEqualStrings(id, again.id());
    try testing.expectError(error.NoRememberedSession, Session.resumeSession(testing.allocator, &t.store, .last_opened, "/w", .acp));
}

fn pathExists(t: *TestHome, parts: []const []const u8) bool {
    const path = std.fs.path.join(testing.allocator, parts) catch return false;
    defer testing.allocator.free(path);
    t.tmp.dir.access(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn countSettings(manager: *sm.Manager, id: []const u8, key: sm.SetKey) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var n: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .set and body.set.key == key) n += 1;
    }
    return n;
}

/// A turn with one step whose single result answers `call-1`.
fn toolTurn(user: []const u8, results: []types.PersistedToolResult, steps: []types.ToolExecutionStep) types.HistoryTurn {
    const calls = struct {
        var list = [_]types.ToolCall{.{ .id = "call-1", .name = "shell", .arguments_json = "{}" }};
    };
    steps[0] = .{ .tool_calls = &calls.list, .tool_results = results };
    return .{ .assistant = .{
        .user = .{ .text = @constCast(user) },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = steps },
    } };
}

test "a v2 session keeps its bodies as blobs its items list, and never makes a side folder (D44, D48)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("run it") };
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("a body kept as a blob"),
        .output_bytes = 21,
        .stored_output_bytes = 21,
    }};
    var steps: [1]types.ToolExecutionStep = undefined;
    var turn = toolTurn("run it", &results, &steps);
    // Streaming the result stores its body before any piece opened the turn.
    try s.appendProgress(user, turn.assistant.execution, .{});
    try s.prepareTurn(&turn);
    defer testing.allocator.free(results[0].output_handle.?);
    defer testing.allocator.free(results[0].preview.?);
    const handle = results[0].output_handle.?;
    const expected = try result_store.blobHandle(testing.allocator, "a body kept as a blob");
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, handle);
    try s.commitTurn(turn, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    try testing.expect(!pathExists(&t, &.{ ".fx", files_dir_name }));
    const hash = artifact_digest.blobHash(handle).?;
    const body = try t.store.manager.getBlob(testing.allocator, id, hash);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("a body kept as a blob", body);
    // Listed on an item, so verify finds it and a fork links it.
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);
    const fork = try t.store.manager.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .ask });
    const fork_id = try testing.allocator.dupe(u8, fork.id());
    defer testing.allocator.free(fork_id);
    fork.release();
    const forked = try t.store.manager.getBlob(testing.allocator, fork_id, hash);
    defer testing.allocator.free(forked);
    try testing.expectEqualStrings("a body kept as a blob", forked);

    // Resumed, the stores read it back by its handle.
    {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        const page = try result_store.readByRangeManaged(testing.allocator, try r.childCapability(), handle, 1, 64);
        defer testing.allocator.free(page);
        try testing.expect(std.mem.find(u8, page, "kept as a blob") != null);
    }

    // Because an item lists it, a lost body damages the session (D39).
    const blob_path = try t.store.manager.blobPath(testing.allocator, id, hash);
    defer testing.allocator.free(blob_path);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), blob_path);
    try testing.expectEqual(@as(u64, 1), (try t.store.manager.verify(id)).bad_blobs);
}

test "a body is stored only while its session is on disk, and a child opens its turn to store one (D44)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const parent = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer parent.close();
    try parent.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    var child_seed = testSeed(&model);
    child_seed.instructions = "be brief";
    const child = try Session.openChild(testing.allocator, &t.store, parent.id(), "ChildSession1", "/w", child_seed);
    defer child.close();
    const capability = try child.childCapability();
    try testing.expectError(error.BlobStoreFailed, capability.putBlob("too early"));
    try child.beginTurn();
    const hash = try capability.putBlob("a child's body");
    try child.commitTurn(assistantTurn("work", "done"), types.ConversationLanguage.default());
    const body = try t.store.manager.getBlob(testing.allocator, child.id(), &hash);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("a child's body", body);
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(child.id())).bad_blobs);
}

test "a session that never reached the disk takes its terminal folder, and a saved one keeps it (D45)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    var fx = try io_mod.openOrCreateVerifiedPrivateDirFromDir(t.tmp.dir, ".fx");
    defer fx.close();
    var terminal_root = try io_mod.openOrCreateVerifiedPrivateDir(&fx, terminal_dir_name);
    defer terminal_root.close();

    const unsaved = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const unsaved_id = try testing.allocator.dupe(u8, unsaved.id());
    defer testing.allocator.free(unsaved_id);
    var made = try io_mod.openOrCreateVerifiedPrivateDir(&terminal_root, unsaved_id);
    made.close();
    unsaved.close();
    try testing.expect(!pathExists(&t, &.{ ".fx", terminal_dir_name, unsaved_id }));

    const saved = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const saved_id = try testing.allocator.dupe(u8, saved.id());
    defer testing.allocator.free(saved_id);
    var kept = try io_mod.openOrCreateVerifiedPrivateDir(&terminal_root, saved_id);
    kept.close();
    try saved.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    saved.close();
    try testing.expect(pathExists(&t, &.{ ".fx", terminal_dir_name, saved_id }));

    // A first write that landed although the adapter never saw it succeed
    // keeps its folder.
    const landed = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const landed_id = try testing.allocator.dupe(u8, landed.id());
    defer testing.allocator.free(landed_id);
    var landed_dir = try io_mod.openOrCreateVerifiedPrivateDir(&terminal_root, landed_id);
    landed_dir.close();
    _ = try landed.handle.append(&.{ .turn_started, .turn_committed });
    landed.close();
    try testing.expect(pathExists(&t, &.{ ".fx", terminal_dir_name, landed_id }));
}

test "recover copies the folders outside the manager, never a link, and says when it left one out" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const io = io_mod.getIo();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    {
        var fx = try io_mod.openOrCreateVerifiedPrivateDirFromDir(t.tmp.dir, ".fx");
        defer fx.close();
        var root = try io_mod.openOrCreateVerifiedPrivateDir(&fx, terminal_dir_name);
        defer root.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, id);
        defer owner.close();
        try owner.dir.writeFile(io, .{ .sub_path = "top.txt", .data = "top", .flags = .{ .permissions = .fromMode(0o600) } });
        var nested = try io_mod.openOrCreateVerifiedPrivateDirFromDir(owner.dir, "nested");
        defer nested.close();
        try nested.dir.writeFile(io, .{ .sub_path = "inner.txt", .data = "inner", .flags = .{ .permissions = .fromMode(0o600) } });
        try owner.dir.symLink(io, "/etc/hosts", "link", .{});
    }

    var recovered = try recover(&t.store, testing.allocator, id);
    defer recovered.deinit(testing.allocator);
    try testing.expect(!recovered.files_complete);
    try testing.expectEqual(@as(usize, 1), recovered.history_len);
    const copy = try std.fs.path.join(testing.allocator, &.{ ".fx", terminal_dir_name, recovered.id });
    defer testing.allocator.free(copy);
    var dir = try t.tmp.dir.openDir(io, copy, .{});
    defer dir.close(io);
    const top = try dir.readFileAlloc(io, "top.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(top);
    try testing.expectEqualStrings("top", top);
    const inner = try dir.readFileAlloc(io, "nested/inner.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(inner);
    try testing.expectEqualStrings("inner", inner);
    const stat = try dir.statFile(io, "nested/inner.txt", .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try testing.expectError(error.FileNotFound, dir.access(io, "link", .{ .follow_symlinks = false }));

    // The copy is a root session of its own; the source is unchanged.
    var copied = try readSession(&t.store, testing.allocator, recovered.id);
    defer copied.deinit(testing.allocator);
    try testing.expectEqualStrings("q", copied.state.history[0].assistant.user.text);
    try testing.expectError(error.SessionNotFound, recover(&t.store, testing.allocator, "NoSuchSession1"));
}

/// The side folder an older v2 session kept (D27), with one body of each
/// kind the move carries, the client's settings, and terminal state.
const OldSideFolder = struct {
    const result_handle = "result-shell-0011223344556677-8899aabbccddeeff.txt";
    const replay_handle = "fx-command-replay-00000000000000000000000000000000-0123456789abcdef.bin";
    const image_name = "image-1.png";
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89 };

    fn write(t: *TestHome, id: []const u8) !void {
        const io = io_mod.getIo();
        var fx = try io_mod.openOrCreateVerifiedPrivateDirFromDir(t.tmp.dir, ".fx");
        defer fx.close();
        var files = try io_mod.openOrCreateVerifiedPrivateDir(&fx, files_dir_name);
        defer files.close();
        var side = try io_mod.openOrCreateVerifiedPrivateDir(&files, id);
        defer side.close();
        try side.dir.createDirPath(io, "tool-results");
        try side.dir.writeFile(io, .{ .sub_path = "tool-results/" ++ result_handle, .data = "an old result body" });
        try side.dir.writeFile(io, .{ .sub_path = "tool-results/compacted-T9.txt", .data = "T9 kept by the compactor before the move" });
        try side.dir.createDirPath(io, "logs/commands");
        try side.dir.writeFile(io, .{ .sub_path = "logs/commands/" ++ replay_handle, .data = "FXRPLY01" });
        try side.dir.createDirPath(io, "images");
        try side.dir.writeFile(io, .{ .sub_path = "images/" ++ image_name, .data = &png });
        try side.dir.createDirPath(io, "client");
        try side.dir.writeFile(io, .{ .sub_path = moved_client_prompt_file, .data = "You run inside Mini." });
        try side.dir.writeFile(io, .{ .sub_path = moved_tool_identities_file, .data = "{\"mcp_mini_read\":{\"server\":\"mini\",\"tool\":\"read\",\"title\":null}}" });
        try side.dir.createDirPath(io, "terminal/state");
        try side.dir.writeFile(io, .{ .sub_path = "terminal/state/terminal-1.json", .data = "{}" });
    }

    /// A turn whose user image and tool result point into the side folder.
    fn commitTurn(t: *TestHome, s: *Session) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&png, &digest, .{});
        var digest_hex = std.fmt.bytesToHex(digest, .lower);
        const snapshot_path = try std.fs.path.join(testing.allocator, &.{ t.home, ".fx", files_dir_name, s.id(), "images", image_name });
        defer testing.allocator.free(snapshot_path);
        var images = [_]types.ImageAttachment{.{
            .id = 1,
            .path = @constCast("/Users/me/shot.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = &digest_hex,
        }};
        var results = [_]types.PersistedToolResult{.{
            .tool_call_id = @constCast("call-1"),
            .tool_name = @constCast("shell"),
            .status = .success,
            .output = @constCast("an old result body"),
            .output_bytes = 18,
            .stored_output_bytes = 18,
            .output_handle = @constCast(result_handle),
            .preview = @constCast("an old"),
        }};
        var steps: [1]types.ToolExecutionStep = undefined;
        var turn = toolTurn("look", &results, &steps);
        turn.assistant.user.images = &images;
        try s.commitTurn(turn, types.ConversationLanguage.default());
    }
};

test "an older session moves off its side folder on its first writable open, and its old names still resolve (D47)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .acp, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try OldSideFolder.write(&t, id);
    try OldSideFolder.commitTurn(&t, s);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .acp);
    defer r.close();
    // One manager folder, and terminal state where the terminal store looks.
    try testing.expect(!pathExists(&t, &.{ ".fx", files_dir_name, id }));
    try testing.expect(pathExists(&t, &.{ ".fx", terminal_dir_name, id, "terminal", "state", "terminal-1.json" }));
    // Old handles resolve through the map.
    const capability = try r.childCapability();
    const body = try capability.readBlob(testing.allocator, .tool_results, OldSideFolder.result_handle, 1024);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("an old result body", body);
    var replay_file = try capability.openBlobFile(testing.allocator, .command_artifacts, OldSideFolder.replay_handle);
    replay_file.close(io_mod.getIo());
    try testing.expectError(error.BlobNotFound, capability.readBlob(testing.allocator, .tool_results, "result-shell-0-0.txt", 1024));
    // The compactor still lists and reads its old record, until a newer one
    // of the same name replaces it (D50).
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const records = result_store.compactorStore(capability);
        const names = try records.list(arena);
        var listed = false;
        for (names) |name| listed = listed or std.mem.eql(u8, name, "compacted-T9.txt");
        try testing.expect(listed);
        try testing.expectEqualStrings("T9 kept by the compactor before the move", try records.read(arena, "compacted-T9.txt", 1024));
        try records.write(testing.allocator, "compacted-T9.txt", "T9 kept again");
        try testing.expectEqualStrings("T9 kept again", try records.read(arena, "compacted-T9.txt", 1024));
        var count: usize = 0;
        for (try records.list(arena)) |name| count += @intFromBool(std.mem.eql(u8, name, "compacted-T9.txt"));
        try testing.expectEqual(@as(usize, 1), count);
    }
    // The image is inside the turn now, and the client's settings are settings.
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const image = restored.history[0].assistant.user.images[0];
    try testing.expectEqualSlices(u8, &OldSideFolder.png, image.inline_data.?);
    const prompt = (try r.clientPrompt(testing.allocator)).?;
    defer testing.allocator.free(prompt);
    try testing.expectEqualStrings("You run inside Mini.", prompt);
    const identities = (try r.toolIdentities(testing.allocator)).?;
    defer testing.allocator.free(identities);
    try testing.expect(std.mem.find(u8, identities, "mcp_mini_read") != null);
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);

    // An image whose blob is lost keeps its old path, as a lost snapshot does.
    const image_hash = r.host.moved.get("images/" ++ OldSideFolder.image_name).?;
    const image_blob = try t.store.manager.blobPath(testing.allocator, id, &image_hash);
    defer testing.allocator.free(image_blob);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), image_blob);
    var without = try r.restore(testing.allocator);
    defer without.deinit(testing.allocator);
    const lost = without.history[0].assistant.user.images[0];
    try testing.expectEqual(@as(?[]u8, null), lost.inline_data);
    try testing.expect(std.mem.endsWith(u8, lost.snapshot_path.?, "images/" ++ OldSideFolder.image_name));
}

test "compactor records on v2 are recorded by one setting with the next write, and come back on resume and in a fork (D50)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    try s.beginTurn();
    // Mid-turn, as auto compaction keeps them; a name kept twice is replaced.
    const records = result_store.compactorStore(try s.childCapability());
    try records.write(testing.allocator, "compacted-T1.txt", "T1 shell: ls\nResult:\nfirst\n");
    try records.write(testing.allocator, "compacted-M1.txt", "M1 the first turn\n");
    try records.write(testing.allocator, "compacted-T1.txt", "T1 shell: ls\nResult:\nreplaced\n");
    try testing.expectEqual(@as(usize, 0), try countSettings(t.store.manager, s.id(), .compaction_records));
    try testing.expectEqualStrings("T1 shell: ls\nResult:\nreplaced\n", try records.read(arena, "compacted-T1.txt", 1024));
    // The turn's next write records them, once.
    try s.commitTurn(assistantTurn("compact it", "done"), types.ConversationLanguage.default());
    try testing.expectEqual(@as(usize, 1), try countSettings(t.store.manager, s.id(), .compaction_records));
    try s.beginTurn();
    try s.commitTurn(assistantTurn("again", "done again"), types.ConversationLanguage.default());
    try testing.expectEqual(@as(usize, 1), try countSettings(t.store.manager, s.id(), .compaction_records));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expect(!pathExists(&t, &.{ ".fx", files_dir_name }));
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);

    // A new process reads them back by name, and lists them.
    {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        const again = result_store.compactorStore(try r.childCapability());
        const names = try again.list(arena);
        try testing.expectEqual(@as(usize, 2), names.len);
        try testing.expectEqualStrings("T1 shell: ls\nResult:\nreplaced\n", try again.read(arena, "compacted-T1.txt", 1024));
        try testing.expectEqualStrings("M1 the first turn\n", try again.read(arena, "compacted-M1.txt", 1024));
        // read_tool_result opens a record by its ID.
        const page = try result_store.readByRangeManaged(testing.allocator, try r.childCapability(), "compacted-M1.txt", 1, 64);
        defer testing.allocator.free(page);
        try testing.expect(std.mem.find(u8, page, "the first turn") != null);
    }

    // A fork carries the records with the turns that kept them.
    const fork = try t.store.manager.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .ask });
    const fork_id = try testing.allocator.dupe(u8, fork.id());
    defer testing.allocator.free(fork_id);
    fork.release();
    {
        const f = try Session.resumeSession(testing.allocator, &t.store, .{ .id = fork_id }, "/w", .ask);
        defer f.close();
        try testing.expectEqualStrings("M1 the first turn\n", try result_store.compactorStore(try f.childCapability()).read(arena, "compacted-M1.txt", 1024));
    }
}

test "a web-fetch download on v2 is a read-only blob the model opens by its path (D49)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    defer s.close();
    try s.beginTurn();
    var downloads = try @import("web_fetch_artifacts.zig").Store.initBlobs(testing.allocator, try s.childCapability(), s.id());
    defer downloads.deinit();
    var artifact = try downloads.write(testing.allocator, "application/pdf", "%PDF-1.7 a download");
    defer artifact.deinit(testing.allocator);
    const folder = try s.folderPath(testing.allocator);
    defer testing.allocator.free(folder);
    try testing.expect(std.mem.startsWith(u8, artifact.display_path, folder));
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), artifact.display_path, .{});
    defer file.close(io_mod.getIo());
    var buffer: [64]u8 = undefined;
    const len = try file.readPositionalAll(io_mod.getIo(), &buffer, 0);
    try testing.expectEqualStrings("%PDF-1.7 a download", buffer[0..len]);
    const stat = try file.stat(io_mod.getIo());
    try testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try testing.expect(!pathExists(&t, &.{ ".fx", files_dir_name }));
}

test "a move cut short is redone on the next open, and old names still resolve (D47)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try OldSideFolder.commitTurn(&t, s);
    // The side folder appears while the session is open, and the move stops
    // after its batch and the terminal rename, before the folder goes.
    try OldSideFolder.write(&t, id);
    {
        var files_root = (try t.store.openProfileFolder(files_dir_name)).?;
        defer files_root.close();
        var side = (try io_mod.openVerifiedPrivateDirIfPresent(&files_root, id)).?;
        defer side.close();
        // A tool result, a compactor record, a replay and an image.
        try testing.expectEqual(@as(usize, 4), try s.moveOut(&side));
    }
    s.close();
    try testing.expect(pathExists(&t, &.{ ".fx", files_dir_name, id }));
    try testing.expectEqual(@as(usize, 1), try countSettings(t.store.manager, id, .moved_files));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    try testing.expect(!pathExists(&t, &.{ ".fx", files_dir_name, id }));
    try testing.expectEqual(@as(usize, 2), try countSettings(t.store.manager, id, .moved_files));
    try testing.expect(pathExists(&t, &.{ ".fx", terminal_dir_name, id, "terminal", "state", "terminal-1.json" }));
    const body = try (try r.childCapability()).readBlob(testing.allocator, .tool_results, OldSideFolder.result_handle, 1024);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("an old result body", body);
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);
}

test "an ACP client's prompt and tool identities are settings, written only when they change (D46)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .acp, testSeed(&model));
    // Held with the session until its first turn, like the seed.
    try testing.expectEqual(@as(?[]u8, null), try s.clientPrompt(testing.allocator));
    try s.setClientPrompt("You run inside Mini.");
    try s.setClientPrompt("You run inside Mini.");
    try s.setToolIdentities("{\"a\":{\"server\":\"s\",\"tool\":\"t\",\"title\":null}}");
    try s.commitTurn(assistantTurn("q", "a"), types.ConversationLanguage.default());
    try s.setToolIdentities("{\"a\":{\"server\":\"s\",\"tool\":\"t\",\"title\":null}}");
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 1), try countSettings(t.store.manager, id, .client_prompt));
    try testing.expectEqual(@as(usize, 1), try countSettings(t.store.manager, id, .tool_identities));

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .acp);
    defer r.close();
    const prompt = (try r.clientPrompt(testing.allocator)).?;
    defer testing.allocator.free(prompt);
    try testing.expectEqualStrings("You run inside Mini.", prompt);
    try r.setClientPrompt("A new prompt.");
    try testing.expectEqual(@as(usize, 2), try countSettings(t.store.manager, id, .client_prompt));
}

test "a prompt image's bytes ride inside the user's item, and an image without them encodes as v1's (D44)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const bytes = OldSideFolder.png ++ [_]u8{ 0x00, 0xff, '"', '\\' };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/Users/me/shot.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/fx-snapshots/image-1.png"),
        .snapshot_sha256 = &digest_hex,
        .inline_data = @constCast(&bytes),
    }};
    const v1_image_prefix = "{\"text\":\"look\",\"images\":[{\"id\":1,\"path\":\"/Users/me/shot.png\",\"media_type\":\"image/png\"," ++
        "\"snapshot_path\":\"/tmp/fx-snapshots/image-1.png\"," ++
        "\"snapshot_sha256\":\"5a84b42e05f3301948f95fb3f8255a8f5c2c51c70551b1726afd8e435def96d0\",\"inline_data\":null";
    for ([_]?[]const u8{ null, "host:original" }) |source_ref| {
        images[0].inline_data = @constCast(&bytes);
        images[0].source_ref = if (source_ref) |value| @constCast(value) else null;
        const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
        var turn = assistantTurn("look", "a png");
        turn.assistant.user.images = &images;
        try s.commitTurn(turn, types.ConversationLanguage.default());
        const id = try testing.allocator.dupe(u8, s.id());
        defer testing.allocator.free(id);
        s.close();

        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        const image = restored.history[0].assistant.user.images[0];
        try testing.expectEqualSlices(u8, &bytes, image.inline_data.?);
        try testing.expectEqualStrings(&digest_hex, image.snapshot_sha256.?);
        try testing.expectEqualStrings(images[0].path, image.path);
        try testing.expectEqualStrings(images[0].snapshot_path.?, image.snapshot_path.?);
        if (source_ref) |value| {
            try testing.expectEqualStrings(value, image.source_ref.?);
        } else try testing.expectEqual(@as(?[]u8, null), image.source_ref);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        images[0].inline_data = null;
        const user: session_event.ConversationUser = .{ .text = "look", .images = &images };
        const ours = try encodePiece(arena.allocator(), .{ .user = user });
        const v1 = if (source_ref != null)
            v1_image_prefix ++ ",\"source_ref\":\"host:original\"}],\"work_id\":null}"
        else
            v1_image_prefix ++ "}],\"work_id\":null}";
        try testing.expectEqualStrings(v1, ours);
        const decoded = (try decodePiece(arena.allocator(), .user, v1, .alloc_always)).user.images[0];
        try testing.expectEqual(@as(?[]u8, null), decoded.inline_data);
        try testing.expectEqualStrings(&digest_hex, decoded.snapshot_sha256.?);
        try testing.expectEqualStrings(images[0].snapshot_path.?, decoded.snapshot_path.?);
        if (source_ref) |value| {
            try testing.expectEqualStrings(value, decoded.source_ref.?);
        } else try testing.expectEqual(@as(?[]u8, null), decoded.source_ref);
    }
}

test "v2 image source refs reject malformed metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][]const u8{ "", "bad\nref", "x" ** 513 }) |source_ref| {
        const images = [_]types.ImageAttachment{.{
            .id = 1,
            .path = @constCast("image.png"),
            .media_type = @constCast("image/png"),
            .source_ref = @constCast(source_ref),
        }};
        try testing.expectError(error.InvalidSessionFormat, WireUser.of(alloc, .{ .text = "look", .images = &images }));
        const wire_images = [_]WireUser.WireImage{.{ .id = 1, .path = "image.png", .media_type = "image/png", .source_ref = source_ref }};
        const wire = WireUser{ .text = "look", .images = &wire_images };
        try testing.expectError(error.InvalidSessionFormat, wire.toUser(alloc));
    }
}

/// v1's own store over a test home, which writes the v1 sessions the
/// conversion tests convert.
const V1Home = struct {
    store: session_store.Store,

    fn init(t: *TestHome) !V1Home {
        return .{ .store = try session_store.Store.initFromHome(testing.allocator, t.home, "/w") };
    }

    fn deinit(v1: *V1Home) void {
        v1.store.deinit(testing.allocator);
    }

    /// A new v1 session `id`, open for writing. Close it with `deinit`.
    fn start(v1: *V1Home, id: []const u8) !session_log.LoadedWritableSession {
        return v1.startAs(id, false);
    }

    fn startAs(v1: *V1Home, id: []const u8, child: bool) !session_log.LoadedWritableSession {
        const alloc = testing.allocator;
        var state: session_codec.DurableSessionState = .{
            .subagent_child = child,
            .id = try alloc.dupe(u8, id),
            .origin_workspace_root = try alloc.dupe(u8, "/w"),
            .workspace_root = try alloc.dupe(u8, "/w"),
            .created_at_ms = 1_000,
            .updated_at_ms = 1_000,
            .conversation_language = types.ConversationLanguage.default(),
            .preferences = .{ .model = try alloc.dupe(u8, "v1/model"), .effort = .auto, .fast_mode = false },
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        };
        defer state.deinit(alloc);
        return v1.store.startWritableSession(alloc, state);
    }

    /// Writes `turns` to a new v1 session `id`, one second apart.
    fn session(v1: *V1Home, id: []const u8, turns: []const types.HistoryTurn) !void {
        var writer = try v1.start(id);
        defer writer.deinit(testing.allocator);
        for (turns, 0..) |turn, index| try writer.conversation_writer.appendHistoryTurn(testing.allocator, @intCast(2_000 + 1_000 * index), turn);
    }

    /// Writes `bytes` to `{folder}/{name}` in v1's folder of `id`, the
    /// folder and the file private as v1 makes them.
    fn put(v1: *V1Home, id: []const u8, folder: ?[]const u8, name: []const u8, bytes: []const u8) !void {
        var dir = (try io_mod.openVerifiedPrivateDirIfPresent(&v1.store.canonical_root.sessions.?, id)).?;
        defer dir.close();
        var target = if (folder) |sub| try io_mod.openOrCreateVerifiedPrivateDir(&dir, sub) else null;
        defer if (target) |*value| value.close();
        try (if (target) |value| value.dir else dir.dir).writeFile(io_mod.getIo(), .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    }

    fn exists(t: *TestHome, id: []const u8) bool {
        var buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, ".fx/sessions/{s}", .{id}) catch unreachable;
        _ = t.tmp.dir.statFile(io_mod.getIo(), path, .{}) catch return false;
        return true;
    }

    fn read(t: *TestHome, path: []const u8) ![]u8 {
        return t.tmp.dir.readFileAlloc(io_mod.getIo(), path, testing.allocator, .limited(1 << 20));
    }
};

fn openConverted(t: *TestHome, id: []const u8) !*Session {
    return Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
}

/// A v1 session's top-level files, to put back after its conversion as a
/// leftover a refused delete leaves.
const V1Copy = struct {
    names: std.ArrayList([]u8) = .empty,
    bytes: std.ArrayList([]u8) = .empty,

    fn take(t: *TestHome, id: []const u8) !V1Copy {
        const io = io_mod.getIo();
        var copy: V1Copy = .{};
        errdefer copy.deinit();
        var buffer: [64]u8 = undefined;
        var dir = try t.tmp.dir.openDir(io, try std.fmt.bufPrint(&buffer, ".fx/sessions/{s}", .{id}), .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or std.mem.eql(u8, entry.name, "session.lock")) continue;
            try copy.names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
            try copy.bytes.append(testing.allocator, try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(1 << 20)));
        }
        return copy;
    }

    fn restore(copy: *const V1Copy, v1: *V1Home, id: []const u8) !void {
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&v1.store.canonical_root.sessions.?, id);
        dir.close();
        for (copy.names.items, copy.bytes.items) |name, bytes| try v1.put(id, null, name, bytes);
    }

    fn deinit(copy: *V1Copy) void {
        for (copy.names.items, copy.bytes.items) |name, bytes| {
            testing.allocator.free(name);
            testing.allocator.free(bytes);
        }
        copy.names.deinit(testing.allocator);
        copy.bytes.deinit(testing.allocator);
    }
};

test "a v1 session converts on its first open, and its v1 folder goes (D55, D60)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-basic", &.{
        assistantTurn("first question", "first answer"),
        .{ .interrupted = .{ .user = .{ .text = @constCast("second question") }, .assistant = @constCast("partial"), .terminal_reason = .cancelled } },
    });

    const s = try Session.resumeSession(testing.allocator, &t.store, .{ .id = "v1-basic" }, "/w", .ask);
    defer s.close();
    var restored = try s.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("first answer", restored.history[0].assistant.assistant);
    try testing.expectEqualStrings("partial", restored.history[1].interrupted.assistant.?);
    try testing.expectEqual(types.InterruptedTerminalReason.cancelled, restored.history[1].interrupted.terminal_reason);
    try testing.expectEqualStrings("v1/model", restored.preferences.?.model);
    try testing.expectEqual(@as(i64, 1_000), restored.created_at_ms);
    try testing.expect(!V1Home.exists(&t, "v1-basic"));
    // Its turns kept their times.
    var page = try t.store.manager.read(testing.allocator, "v1-basic", .start, .forward, 64);
    defer page.deinit();
    var starts: std.ArrayList(u64) = .empty;
    defer starts.deinit(testing.allocator);
    for (page.entries) |entry| if (entry.body) |body| if (body == .turn_started) try starts.append(testing.allocator, entry.ts_ms);
    try testing.expectEqualSlices(u64, &.{ 2_000, 3_000 }, starts.items);
}

test "a converted v1 session keeps its title, permission rules and preferences (D56)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const key = try session_permission_state.RuleKey.init(.command, "command\x00/w\x00zig build");
    {
        var writer = try v1.start("v1-settings");
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("q", "a"));
        _ = try writer.renameConversation(alloc, "Named by hand");
        var applied = try session_permission_state.apply(alloc, .{}, .{ .set = .{ .key = key, .display_identity = "zig build", .decision = .deny, .expected_generation = null } });
        var permissions = applied.takeApplied() orelse return error.TestUnexpectedResult;
        defer permissions.deinit(alloc);
        try writer.replacePermissionState(alloc, permissions, 2_500);
    }

    const s = try openConverted(&t, "v1-settings");
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    try testing.expectEqualStrings("\"Named by hand\"", st.title.?);
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(session_permission_state.StateDecision.deny, session_permission_state.decide(restored.permission_state.?, key));
    try testing.expectEqualStrings("v1/model", restored.preferences.?.model);
}

test "a converted v1 session's side files keep their old names, and its prompt images ride inside the prompt (D44, D47)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // As v1's log names a prompt image: by its folder and digest.
    const digest = "aaaaaaaaaaaaaaaa" ** 4;
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("shot.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("images/image-1-" ++ digest[0..16] ++ ".bin"),
        .snapshot_sha256 = @constCast(digest),
    }};
    try v1.session("v1-side", &.{.{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = &images }, .assistant = @constCast("seen") } }});
    try v1.put("v1-side", "tool-results", "call-1.txt", "the full tool output");
    try v1.put("v1-side", "images", "image-1-" ++ digest[0..16] ++ ".bin", "PNG bytes");

    const s = try openConverted(&t, "v1-side");
    defer s.close();
    const hash = s.host.moved.get("tool-results/call-1.txt") orelse return error.TestUnexpectedResult;
    const body = try t.store.manager.getBlob(alloc, "v1-side", &hash);
    defer alloc.free(body);
    try testing.expectEqualStrings("the full tool output", body);
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const image = restored.history[0].assistant.user.images[0];
    try testing.expectEqualStrings("PNG bytes", image.inline_data.?);
    try testing.expect(image.snapshot_path == null);
}

test "a converted v1 session's usage and its marker keep v1's verdict (D20, D56)" {
    const alloc = testing.allocator;
    const session_usage_sidecar = @import("session_usage_sidecar.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    {
        var writer = try v1.start("v1-usage");
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("q", "a"));
        var usage = session_usage.Usage.initFresh();
        defer usage.deinit(alloc);
        var snapshot = try usage.snapshot(alloc);
        defer snapshot.deinit(alloc);
        try session_usage_sidecar.write(alloc, &writer.log.dir, "v1-usage", snapshot);
    }
    // Marked after its checkpoint: v1 does not count that checkpoint as
    // newer than its marker.
    try v1.store.markUsageRecoveryPending(alloc, "v1-usage", 1_000);

    const s = try openConverted(&t, "v1-usage");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expect(restored.usage != null);
    // A settled checkpoint at 1000 is newer only past its marker's time.
    const marker = try V1Home.read(&t, ".fx/" ++ usage_markers_dir_name ++ "/v1-usage");
    defer alloc.free(marker);
    try testing.expectEqualStrings("v1 1000\n", marker);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io_mod.getIo(), ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-usage", .{}));
}

test "a converted v1 session keeps its ACP client's prompt and tool identities (D46)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-acp", &.{assistantTurn("q", "a")});
    const record = "{\"mcp_mini_read\":{\"server\":\"mini\",\"tool\":\"read\",\"title\":null}}";
    try v1.put("v1-acp", "client", "system-prompt.txt", "You run inside Mini.");
    try v1.put("v1-acp", "client", "mcp-tool-identities.json", record);

    const s = try openConverted(&t, "v1-acp");
    defer s.close();
    const prompt = (try s.clientPrompt(alloc)).?;
    defer alloc.free(prompt);
    try testing.expectEqualStrings("You run inside Mini.", prompt);
    const identities = (try s.toolIdentities(alloc)).?;
    defer alloc.free(identities);
    try testing.expectEqualStrings(record, identities);
}

test "a converted v1 session's hosted terminal state lands where v2 keeps it (D45)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-term", &.{assistantTurn("q", "a")});
    try v1.put("v1-term", terminal_dir_name, "state.json", "{\"sessions\":[]}");

    const s = try openConverted(&t, "v1-term");
    defer s.close();
    const state = try V1Home.read(&t, ".fx/" ++ terminal_dir_name ++ "/v1-term/" ++ terminal_dir_name ++ "/state.json");
    defer alloc.free(state);
    try testing.expectEqualStrings("{\"sessions\":[]}", state);
}

fn writeRecovery(v1: *V1Home, id: []const u8, seq: u64, user: []const u8, partial: []const u8) !void {
    const alloc = testing.allocator;
    const checkpoint: session_codec.RecoveryCheckpoint = .{
        .turn_id = 1,
        .user = .{ .text = @constCast(user) },
        .assistant_source = @constCast(partial),
        .cause = .response_interrupted,
        .action = .continuing_response,
        .authority = .{ .provider = .gateway, .model = @constCast("v1/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    const encoded = try session_codec.encodeRecoveryCheckpoint(alloc, checkpoint);
    defer alloc.free(encoded);
    const bytes = try std.fmt.allocPrint(alloc, "{{\"conversation_seq\":{d},\"checkpoint\":{s}}}\n", .{ seq, encoded });
    defer alloc.free(bytes);
    try v1.put(id, null, "recovery.json", bytes);
}

test "a v1 turn left open comes back unfinished exactly as v1 shows it (D56)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // Each turn but the first stops after its prompt, as a crash leaves it.
    for ([_][]const u8{ "v1-checkpoint", "v1-stale", "v1-open" }) |id| {
        var writer = try v1.start(id);
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("q", "a"));
        const done = writer.conversation_writer.last_seq;
        if (!std.mem.eql(u8, id, "v1-stale")) _ = try writer.conversation_writer.append(alloc, 3_000, .{ .user = .{ .text = "stalled" } });
        if (std.mem.eql(u8, id, "v1-checkpoint")) try writeRecovery(&v1, id, writer.conversation_writer.last_seq, "stalled", "a partial reply");
        // A checkpoint whose turn the log has since ended: v1 drops it.
        if (std.mem.eql(u8, id, "v1-stale")) try writeRecovery(&v1, id, done - 1, "q", "never shown");
    }

    {
        const s = try openConverted(&t, "v1-checkpoint");
        defer s.close();
        var restored = try s.restore(alloc);
        defer restored.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), restored.history.len);
        try testing.expectEqualStrings("stalled", restored.history[1].interrupted.user.text);
        try testing.expectEqualStrings("a partial reply", restored.history[1].interrupted.assistant.?);
        try testing.expectEqual(types.InterruptedTerminalReason.failed, restored.history[1].interrupted.terminal_reason);
    }
    {
        const s = try openConverted(&t, "v1-stale");
        defer s.close();
        var restored = try s.restore(alloc);
        defer restored.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), restored.history.len);
    }
    {
        // No checkpoint: v1's next writable open fails the turn.
        const s = try openConverted(&t, "v1-open");
        defer s.close();
        var restored = try s.restore(alloc);
        defer restored.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), restored.history.len);
        try testing.expectEqualStrings("stalled", restored.history[1].interrupted.user.text);
        try testing.expectEqual(types.InterruptedTerminalReason.failed, restored.history[1].interrupted.terminal_reason);
    }
}

test "a v1 family converts together: its children first, and one whose folder is gone recorded lost (D33, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-parent", &.{assistantTurn("q", "a")});
    {
        var writer = try v1.startAs("v1-kid", true);
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("child task", "child answer"));
    }
    var registry = try child_state.Registry.init(alloc, "v1-parent");
    defer registry.deinit(alloc);
    registry.children = try alloc.alloc(child_state.Child, 2);
    for (registry.children, [_][]const u8{ "v1-kid", "v1-gone" }, [_][]const u8{ "w1", "w2" }) |*child, id, work| child.* = .{
        .id = try alloc.dupe(u8, id),
        .kind = .one_off,
        .phase = .finished,
        .work_generation = 1,
        .last_work_id = try alloc.dupe(u8, work),
        .last_request_fingerprint = [_]u8{7} ** 32,
        .last_outcome = .completed,
    };
    try (child_state.Store{ .backend = .{ .v1 = &v1.store }, .parent_id = "v1-parent" }).save(alloc, registry);

    // A v1 child opens only through its parent.
    try testing.expectError(error.SessionNotFound, openConverted(&t, "v1-kid"));
    const s = try openConverted(&t, "v1-parent");
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), st.children.items.len);
    for (st.children.items) |child| {
        const expected: sm.Outcome = if (std.mem.eql(u8, child.id, "v1-kid")) .ok else .lost;
        try testing.expectEqual(expected, child.outcome.?);
    }
    var kid = try t.store.manager.peek(alloc, "v1-kid");
    defer kid.deinit(alloc);
    try testing.expectEqual(sm.Role.child, kid.role);
    try testing.expectEqualStrings("v1-parent", kid.parent.?);
    try testing.expect(!V1Home.exists(&t, "v1-parent") and !V1Home.exists(&t, "v1-kid"));
}

test "a v1 session another process holds answers busy, and converts nothing (D38)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-held", &.{assistantTurn("q", "a")});
    {
        var holder = try v1.store.resumeForWrite(alloc, "v1-held");
        defer holder.deinit(alloc);
        try testing.expectError(error.SessionBusy, Session.resumeSessionWithoutWaiting(alloc, &t.store, .{ .id = "v1-held" }, "/w", .app));
        try testing.expectError(error.NotFound, t.store.manager.peek(alloc, "v1-held"));
        try testing.expect(V1Home.exists(&t, "v1-held"));
    }
    const s = try openConverted(&t, "v1-held");
    s.close();
}

test "an unreadable v1 session is refused with its file and reason, and nothing is half converted (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-torn", &.{assistantTurn("q", "a")});
    const log = try V1Home.read(&t, ".fx/sessions/v1-torn/events.jsonl");
    defer alloc.free(log);
    const damaged = try std.mem.concat(alloc, u8, &.{ log, "{ not json\n" });
    defer alloc.free(damaged);
    try v1.put("v1-torn", null, "events.jsonl", damaged);

    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, "v1-torn"));
    const line = std.mem.count(u8, log, "\n") + 1;
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "events.jsonl line {d} is not valid JSON", .{line}), t.store.conversionProblem().?);
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, "v1-torn"));
    // No staging left behind, if any was made.
    if (t.tmp.dir.openDir(io_mod.getIo(), ".fx/sessions/v2/.tmp", .{ .iterate = true })) |opened_staging| {
        var staging = opened_staging;
        defer staging.close(io_mod.getIo());
        var it = staging.iterate();
        try testing.expect(try it.next(io_mod.getIo()) == null);
    } else |err| try testing.expectEqual(error.FileNotFound, err);
    const after = try V1Home.read(&t, ".fx/sessions/v1-torn/events.jsonl");
    defer alloc.free(after);
    try testing.expectEqualStrings(damaged, after);
}

test "a leftover v1 folder goes on a later open only while it is what was converted (D60)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-left", &.{assistantTurn("q", "a")});
    var copy = try V1Copy.take(&t, "v1-left");
    defer copy.deinit();
    (try openConverted(&t, "v1-left")).close();

    // As a refused delete leaves it: the next open deletes it.
    try copy.restore(&v1, "v1-left");
    (try openConverted(&t, "v1-left")).close();
    try testing.expect(!V1Home.exists(&t, "v1-left"));

    // Changed since by an older build: kept, and never reaches the v2 copy.
    try copy.restore(&v1, "v1-left");
    try v1.put("v1-left", null, "events.jsonl", "changed\n");
    const s = try openConverted(&t, "v1-left");
    defer s.close();
    try testing.expect(V1Home.exists(&t, "v1-left"));
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
}

test "a converted v1 folder stays until its usage marker has moved to v2, and a later open finishes the move (D62)" {
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-mark", &.{assistantTurn("q", "a")});
    try v1.store.markUsageRecoveryPending(testing.allocator, "v1-mark", 1_000);
    const v1_marker = ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-mark";
    const v2_markers = ".fx/" ++ usage_markers_dir_name;
    // v2's marker cannot be written: the move is refused, and v1's marker
    // and folder stay.
    try t.tmp.dir.writeFile(io, .{ .sub_path = v2_markers, .data = "" });
    (try openConverted(&t, "v1-mark")).close();
    try testing.expect(V1Home.exists(&t, "v1-mark"));
    _ = try t.tmp.dir.statFile(io, v1_marker, .{});

    try t.tmp.dir.deleteFile(io, v2_markers);
    (try openConverted(&t, "v1-mark")).close();
    try testing.expect(!V1Home.exists(&t, "v1-mark"));
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, v1_marker, .{}));
    _ = try t.tmp.dir.statFile(io, v2_markers ++ "/v1-mark", .{});
}

test "a leftover v1 folder whose usage marker its copy never saw stays, the marker with it (D62)" {
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-late", &.{assistantTurn("q", "a")});
    var copy = try V1Copy.take(&t, "v1-late");
    defer copy.deinit();
    (try openConverted(&t, "v1-late")).close();

    // A refused delete's leftover, then an older build marks usage owed
    // without changing the session: that marker's verdict is not the
    // copy's, so it neither moves nor loses its folder.
    try copy.restore(&v1, "v1-late");
    try v1.store.markUsageRecoveryPending(testing.allocator, "v1-late", 1_000);
    (try openConverted(&t, "v1-late")).close();
    try testing.expect(V1Home.exists(&t, "v1-late"));
    _ = try t.tmp.dir.statFile(io, ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-late", .{});
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, ".fx/" ++ usage_markers_dir_name ++ "/v1-late", .{}));
}

test "-c opens the session v1 remembers while v2 has none, and --resume last the newest of both (D56, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-remembered", &.{assistantTurn("q", "a")});
    try v1.store.rememberSessionId(alloc, "v1-remembered");
    {
        const s = try Session.resumeSession(alloc, &t.store, .last_opened, "/w", .app);
        defer s.close();
        try testing.expectEqualStrings("v1-remembered", s.id());
    }
    var model = "m".*;
    const fresh = try Session.create(alloc, &t.store, "/w", .ask, testSeed(&model));
    try fresh.commitTurn(assistantTurn("v2 question", "v2 answer"), types.ConversationLanguage.default());
    fresh.close();
    // Written after the v2 session's turn, so listed as newer.
    try v1.session("v1-newest", &.{assistantTurn("q", "a")});
    const s = try Session.resumeSession(alloc, &t.store, .last, "/w", .ask);
    defer s.close();
    try testing.expectEqualStrings("v1-newest", s.id());
}

test "the listing shows v1 sessions not converted yet, and fx session reads one without converting it (D59, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-listed", &.{assistantTurn("listed question", "a")});
    var cancel = std.atomic.Value(bool).init(false);
    var list = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("v1-listed", list.items[0].id);

    var detail = try readSession(&t.store, alloc, "v1-listed");
    defer detail.deinit(alloc);
    try testing.expectEqualStrings("listed question", detail.state.history[0].assistant.user.text);
    try testing.expect(V1Home.exists(&t, "v1-listed"));
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, "v1-listed"));
}

test "the listing's pages, read from part of the index, are the whole listing in v1's order, through a tie and v1's roots (D59, D62)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // Tied on their update time: v2 orders them by id ascending, v1's pages
    // by id descending.
    for ([_][]const u8{ "tie-c", "tie-a", "tie-e", "tie-b", "tie-d" }) |id| {
        const s = try t.store.manager.openImport(.{ .id = id, .workspace = "/w", .host = .ask, .created_ms = 1000 });
        defer s.release();
        _ = try s.appendAt(&.{ .turn_started, .turn_committed }, 5000);
        try s.publishImport();
    }
    try v1.session("v1-only", &.{assistantTurn("q", "a")});
    // Converted, its v1 folder left behind as a refused delete leaves it:
    // listed once.
    try v1.session("v1-held", &.{assistantTurn("q", "a")});
    var copy = try V1Copy.take(&t, "v1-held");
    defer copy.deinit();
    (try openConverted(&t, "v1-held")).close();
    try copy.restore(&v1, "v1-held");

    var cancel = std.atomic.Value(bool).init(false);
    var whole = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (whole.items) |*summary| summary.deinit(alloc);
        whole.deinit(alloc);
    }
    session_summary_codec.sortSummariesNewestFirst(whole.items);
    try testing.expectEqual(@as(usize, 7), whole.items.len);
    for ([_]?[]const u8{ null, "/w" }) |workspace| for ([_]usize{ 1, 2, 3 }) |limit| {
        var seen: usize = 0;
        var continuation: ?session_store.ResumableSessionContinuation = null;
        var last_id: ?[]u8 = null;
        defer if (last_id) |id| alloc.free(id);
        while (true) {
            var page = try listPage(&t.store, alloc, workspace, continuation, limit);
            defer page.deinit(alloc);
            for (page.summaries.items) |summary| {
                try testing.expectEqualStrings(whole.items[seen].id, summary.id);
                seen += 1;
            }
            if (!page.has_more) break;
            const last = page.summaries.items[page.summaries.items.len - 1];
            if (last_id) |id| alloc.free(id);
            last_id = try alloc.dupe(u8, last.id);
            continuation = .{ .updated_at_ms = last.updated_at_ms, .id = last_id.? };
        }
        try testing.expectEqual(whole.items.len, seen);
    };
}

test "a v1 session in the oldest format converts through v1's older reader (D61)" {
    const alloc = testing.allocator;
    const session_json = @import("session_json.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const text = try session_json.renderSessionJson(alloc, "v1-legacy", 10, 20, types.ConversationLanguage.default(), "/w", &.{assistantTurn("old question", "old answer")}, .{});
    defer alloc.free(text);
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&v1.store.canonical_root.sessions.?, "v1-legacy");
    dir.close();
    try v1.put("v1-legacy", null, "session.json", text);

    const s = try openConverted(&t, "v1-legacy");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqualStrings("old answer", restored.history[0].assistant.assistant);
    try testing.expect(!V1Home.exists(&t, "v1-legacy"));
}

test "a conversion past its slow mark tells the host once (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var told: usize = 0;
    t.store.notice = .{ .context = &told, .emit = struct {
        fn emit(context: ?*anyopaque, text: []const u8) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, text, slow_conversion_text)) count.* += 1;
        }
    }.emit };
    var quick: Conversion = .{ .store = &t.store, .alloc = testing.allocator, .host = .ask, .started = io_mod.nanoTimestamp() };
    quick.phase();
    try testing.expectEqual(@as(usize, 0), told);
    var slow: Conversion = .{ .store = &t.store, .alloc = testing.allocator, .host = .ask, .started = io_mod.nanoTimestamp() - 2 * slow_conversion_ns };
    slow.phase();
    slow.phase();
    try testing.expectEqual(@as(usize, 1), told);
}

test "fx sessions convert converts every v1 family, and counts what it skipped (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-plain", &.{assistantTurn("q", "a")});
    try v1.session("v1-busy", &.{assistantTurn("q", "a")});
    try v1.session("v1-bad", &.{assistantTurn("q", "a")});
    try v1.put("v1-bad", null, "events.jsonl", "{ not json\n");
    var holder = try v1.store.resumeForWrite(alloc, "v1-busy");
    defer holder.deinit(alloc);

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 1), report.busy);
    try testing.expectEqual(@as(usize, 1), report.unreadable);
    for (report.skipped.items) |skipped| {
        const busy = std.mem.eql(u8, skipped.id, "v1-busy");
        try testing.expectEqualStrings(if (busy) "SessionBusy" else "InvalidSessionFormat", skipped.code);
        if (!busy) try testing.expectEqualStrings("events.jsonl line 1 is not valid JSON", skipped.reason.?);
    }
    var plain = try t.store.manager.peek(alloc, "v1-plain");
    plain.deinit(alloc);
}

/// Writes v1 child sessions `ids` of the v1 root `parent`, and its
/// registry naming them, each finished.
fn v1Children(v1: *V1Home, parent: []const u8, ids: []const []const u8) !void {
    const alloc = testing.allocator;
    for (ids) |id| {
        var writer = try v1.startAs(id, true);
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("child task", "child answer"));
    }
    var registry = try child_state.Registry.init(alloc, parent);
    defer registry.deinit(alloc);
    registry.children = try alloc.alloc(child_state.Child, ids.len);
    for (registry.children, ids) |*child, id| child.* = .{
        .id = try alloc.dupe(u8, id),
        .kind = .one_off,
        .phase = .finished,
        .work_generation = 1,
        .last_work_id = try alloc.dupe(u8, id),
        .last_request_fingerprint = [_]u8{7} ** 32,
        .last_outcome = .completed,
    };
    try (child_state.Store{ .backend = .{ .v1 = &v1.store }, .parent_id = parent }).save(alloc, registry);
}

test "a child an earlier try published is reused as it is, its v1 folder kept once v1 changed it (D60, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-root", &.{assistantTurn("q", "a")});
    try v1Children(&v1, "v1-root", &.{ "v1-same", "v1-changed" });
    // A try that published the children and stopped before the root.
    {
        var v1_store = try session_store.Store.initReadOnlyFromHome(alloc, t.store.home, "/");
        defer v1_store.deinit(alloc);
        var locks = try v1_conversion.lockFamily(alloc, &v1_store, "v1-root", 0, &t.store.problem);
        defer locks.release();
        var c: Conversion = .{ .store = &t.store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
        for (locks.members.items[1..]) |*member| {
            var checked = try c.check(&v1_store, member, "v1-root", false, false);
            const staged = try c.stage(&v1_store, &checked, member, .{ .child = .{ .parent = "v1-root", .instructions = null } });
            defer staged.session.?.dropImport();
            try staged.session.?.handle.publishImport();
        }
    }
    // An older build changes one child since; a damaged one reads the same.
    try v1.put("v1-changed", null, "events.jsonl", "{ not json\n");

    const s = try openConverted(&t, "v1-root");
    defer s.close();
    var changed = try t.store.manager.peek(alloc, "v1-changed");
    defer changed.deinit(alloc);
    try testing.expectEqual(sm.Role.child, changed.role);
    try testing.expect(V1Home.exists(&t, "v1-changed"));
    try testing.expect(!V1Home.exists(&t, "v1-same") and !V1Home.exists(&t, "v1-root"));
}

test "a v1 session whose session.json is damaged names that file, whatever registry it has (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-broken", &.{assistantTurn("q", "a")});
    try v1Children(&v1, "v1-broken", &.{"v1-broken-kid"});
    try v1.put("v1-broken", null, "session.json", "{ not json");
    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, "v1-broken"));
    try testing.expectEqualStrings("session.json is not valid JSON", t.store.conversionProblem().?);
    try testing.expect(V1Home.exists(&t, "v1-broken") and V1Home.exists(&t, "v1-broken-kid"));
}

test "a v1 profile an old release left readable by others converts (D61)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-open", &.{assistantTurn("q", "a")});
    for ([_][]const u8{ ".fx", ".fx/sessions", ".fx/sessions/v1-open" }) |path| {
        var dir = try t.tmp.dir.openDir(io, path, .{});
        defer dir.close(io);
        dir.setPermissions(io, .fromMode(0o755)) catch return error.SkipZigTest;
    }
    const s = try openConverted(&t, "v1-open");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expect(!V1Home.exists(&t, "v1-open"));
}

/// A legacy relationship-index page naming `child` in its first slot.
fn relationshipPage(alloc: Allocator, child: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("FXRELP01");
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u64, 0, .little);
    for (0..64) |slot| {
        try w.writeByte(if (slot == 0) 1 else 0);
        try w.writeInt(u64, std.math.maxInt(u64), .little);
        const name = if (slot == 0) child else "";
        try w.writeInt(u16, @intCast(name.len), .little);
        try w.writeAll(name);
    }
    return out.toOwnedSlice();
}

test "a schema 3 family converts its children from the relationship index, with no child lines (D61)" {
    const alloc = testing.allocator;
    const relationship_index_codec = @import("session_relationship_index_codec.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-old-root", &.{assistantTurn("q", "a")});
    {
        var writer = try v1.startAs("v1-old-kid", true);
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("child task", "child answer"));
    }
    const header = try relationship_index_codec.encodeHeader(alloc, .{ .high_watermark = 1, .active_count = 1 });
    defer alloc.free(header);
    try v1.put("v1-old-root", "subagent", "relationship-index.bin", header);
    const page = try relationshipPage(alloc, "v1-old-kid");
    defer alloc.free(page);
    try v1.put("v1-old-root", "subagent", &relationship_index_codec.pageFileName(0), page);

    const s = try openConverted(&t, "v1-old-root");
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), st.children.items.len);
    var kid = try t.store.manager.peek(alloc, "v1-old-kid");
    defer kid.deinit(alloc);
    try testing.expectEqualStrings("v1-old-root", kid.parent.?);
    try testing.expect(!V1Home.exists(&t, "v1-old-root") and !V1Home.exists(&t, "v1-old-kid"));
}

test "a stored result that kept only its preview replays as v1 shows it: wrapped with its handle" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(alloc, &t.store, "/w", .ask, testSeed(&model));
    defer s.close();
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("the first part"),
        .output_bytes = 14,
        .output_handle = @constCast("result-shell-0.txt"),
        .preview = @constCast("the first part"),
        .stored_output_bytes = 9000,
        .truncated = true,
    }};
    var steps: [1]types.ToolExecutionStep = undefined;
    try s.commitTurn(toolTurn("run it", &results, &steps), types.ConversationLanguage.default());
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const shown = try result_store.formatStoredResultOutput(alloc, "result-shell-0.txt", "the first part", 9000);
    defer alloc.free(shown);
    try testing.expectEqualStrings(shown, restored.history[0].assistant.execution.tool_steps[0].tool_results[0].output);
}

test "an older format's inline result converts as v1's migration stores it: under v1's handle, truncated (D61)" {
    const alloc = testing.allocator;
    const session_json = @import("session_json.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("the whole old output"),
        .output_bytes = 20,
        .stored_output_bytes = 20,
    }};
    var steps: [1]types.ToolExecutionStep = undefined;
    const text = try session_json.renderSessionJson(alloc, "v1-inline", 10, 20, types.ConversationLanguage.default(), "/w", &.{toolTurn("run it", &results, &steps)}, .{});
    defer alloc.free(text);
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&v1.store.canonical_root.sessions.?, "v1-inline");
    dir.close();
    try v1.put("v1-inline", null, "session.json", text);

    const s = try openConverted(&t, "v1-inline");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const result = restored.history[0].assistant.execution.tool_steps[0].tool_results[0];
    const handle = try result_store.makeHandle(alloc, "call-1", "shell", "the whole old output");
    defer alloc.free(handle);
    try testing.expectEqualStrings(handle, result.output_handle.?);
    const shown = try result_store.formatStoredResultOutput(alloc, handle, "the whole old output", 20);
    defer alloc.free(shown);
    try testing.expectEqualStrings(shown, result.output);
    // The handle still reads the whole output.
    const body = try (try s.childCapability()).readBlob(alloc, .tool_results, handle, 1024);
    defer alloc.free(body);
    try testing.expectEqualStrings("the whole old output", body);
}

test "a refusal's reason is never shown for a later open (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-torn-once", &.{assistantTurn("q", "a")});
    try v1.put("v1-torn-once", null, "events.jsonl", "{ not json\n");
    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, "v1-torn-once"));
    try testing.expect(t.store.conversionProblem() != null);
    try testing.expectError(error.SessionNotFound, openConverted(&t, "nowhere"));
    try testing.expect(t.store.conversionProblem() == null);
}

test "a v1 prompt image that cannot be read refuses the session, and one that is gone keeps its path (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    var images = [_]types.ImageAttachment{.{ .id = 1, .path = @constCast("shot.png"), .media_type = @constCast("image/png"), .snapshot_path = @constCast("images/shot.bin") }};
    const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = &images }, .assistant = @constCast("seen") } };
    try v1.session("v1-image-bad", &.{turn});
    try v1.session("v1-image-gone", &.{turn});
    // A folder where the image should be: not a lost snapshot, a fault.
    var dir = (try io_mod.openVerifiedPrivateDirIfPresent(&v1.store.canonical_root.sessions.?, "v1-image-bad")).?;
    defer dir.close();
    try dir.dir.createDirPath(io_mod.getIo(), "images/shot.bin");

    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, "v1-image-bad"));
    try testing.expectEqualStrings("images/shot.bin can't be read (ReadFailed)", t.store.conversionProblem().?);
    try testing.expect(V1Home.exists(&t, "v1-image-bad"));

    const s = try openConverted(&t, "v1-image-gone");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqualStrings("images/shot.bin", restored.history[0].assistant.user.images[0].snapshot_path.?);
}

test "a root with a registry converts its children from it, never from a relationship index too (D61)" {
    const alloc = testing.allocator;
    const relationship_index_codec = @import("session_relationship_index_codec.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-both", &.{assistantTurn("q", "a")});
    try v1Children(&v1, "v1-both", &.{"v1-listed-kid"});
    {
        var writer = try v1.startAs("v1-indexed-kid", true);
        defer writer.deinit(alloc);
    }
    const header = try relationship_index_codec.encodeHeader(alloc, .{ .high_watermark = 1, .active_count = 1 });
    defer alloc.free(header);
    try v1.put("v1-both", "subagent", "relationship-index.bin", header);
    const page = try relationshipPage(alloc, "v1-indexed-kid");
    defer alloc.free(page);
    try v1.put("v1-both", "subagent", &relationship_index_codec.pageFileName(0), page);

    (try openConverted(&t, "v1-both")).close();
    var listed = try t.store.manager.peek(alloc, "v1-listed-kid");
    listed.deinit(alloc);
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, "v1-indexed-kid"));
    try testing.expect(V1Home.exists(&t, "v1-indexed-kid"));
}

test "the sweep drops what an earlier try staged for a child whose folder is gone since (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-parent", &.{assistantTurn("q", "a")});
    try v1Children(&v1, "v1-parent", &.{"v1-went"});
    const staging = try t.store.manager.openImport(.{ .id = "v1-went", .workspace = "/w", .host = .ask, .role = .child, .parent = "v1-parent", .created_ms = 1 });
    // An import's staging appears with its first blob.
    _ = try staging.putBlob("staged before the folder went");
    staging.release();
    try t.tmp.dir.deleteTree(io_mod.getIo(), ".fx/sessions/v1-went");
    _ = try t.tmp.dir.statFile(io_mod.getIo(), ".fx/sessions/v2/.tmp/v1-went", .{});

    (try openConverted(&t, "v1-parent")).close();
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io_mod.getIo(), ".fx/sessions/v2/.tmp/v1-went", .{}));
}

test "a v1 session whose usage marker cannot be read converts, and its v1 state stays (D20)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-marked", &.{assistantTurn("q", "a")});
    try v1.store.markUsageRecoveryPending(testing.allocator, "v1-marked", 1_000);
    // Readable by others: v1 refuses such a marker.
    try t.tmp.dir.setFilePermissions(io_mod.getIo(), ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-marked", .fromMode(0o644), .{});

    (try openConverted(&t, "v1-marked")).close();
    try testing.expect(V1Home.exists(&t, "v1-marked"));
    _ = try t.tmp.dir.statFile(io_mod.getIo(), ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-marked", .{});
    // Nor does a later open's cleanup take it.
    (try openConverted(&t, "v1-marked")).close();
    try testing.expect(V1Home.exists(&t, "v1-marked"));
}

test "converted usage that still owes the ledger counts once at every point a conversion can stop (D20)" {
    const alloc = testing.allocator;
    const session_usage_sidecar = @import("session_usage_sidecar.zig");
    const usage_recovery = @import("usage_recovery.zig");
    const usage_report = @import("usage_report.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const now_ms = io_mod.milliTimestamp();
    var owed_facts = [_]usage_report.GenerationFact{.{
        .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        .created_at_ms = now_ms - 1_000,
        .model = @constCast("provider/model"),
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .total_cost = 0.25,
    }};
    {
        var writer = try v1.start("v1-owed");
        defer writer.deinit(alloc);
        try writer.conversation_writer.appendHistoryTurn(alloc, 2_000, assistantTurn("q", "a"));
        var usage = session_usage.Usage.initFresh();
        defer usage.deinit(alloc);
        var snapshot = try usage.snapshot(alloc);
        defer snapshot.deinit(alloc);
        var owed = snapshot;
        owed.publication_backlog = &owed_facts;
        try testing.expect(session_usage.needsProfileRecovery(owed));
        try session_usage_sidecar.write(alloc, &writer.log.dir, "v1-owed", owed);
    }
    try v1.store.markUsageRecoveryPending(alloc, "v1-owed", 1_000);
    var copy = try V1Copy.take(&t, "v1-owed");
    defer copy.deinit();
    const v1_marker = ".fx/" ++ profile_paths.usage_recovery_dir_name ++ "/v1-owed";
    const v2_marker = ".fx/" ++ usage_markers_dir_name ++ "/v1-owed";
    const marker_bytes = try V1Home.read(&t, v1_marker);
    defer alloc.free(marker_bytes);
    // A conversion that stops leaves v1's marker as it was, its time too.
    const marker_mtime = (try t.tmp.dir.statFile(io_mod.getIo(), v1_marker, .{})).mtime;

    (try openConverted(&t, "v1-owed")).close();
    const Point = struct { name: []const u8, v1_folder: bool, v1_marker: bool, v2_marker: bool };
    // Publish, then the v2 marker, then v1's marker goes, then its folder.
    const points = [_]Point{
        .{ .name = "after publish", .v1_folder = true, .v1_marker = true, .v2_marker = false },
        .{ .name = "after the v2 marker", .v1_folder = true, .v1_marker = true, .v2_marker = true },
        .{ .name = "after v1's marker went", .v1_folder = true, .v1_marker = false, .v2_marker = true },
        .{ .name = "done", .v1_folder = false, .v1_marker = false, .v2_marker = true },
    };
    const v2_marker_bytes = try V1Home.read(&t, v2_marker);
    defer alloc.free(v2_marker_bytes);
    for (points) |point| {
        const io = io_mod.getIo();
        t.tmp.dir.deleteTree(io, ".fx/sessions/v1-owed") catch {};
        t.tmp.dir.deleteFile(io, v1_marker) catch {};
        t.tmp.dir.deleteFile(io, v2_marker) catch {};
        if (point.v1_folder) try copy.restore(&v1, "v1-owed");
        if (point.v1_marker) {
            try t.tmp.dir.writeFile(io, .{ .sub_path = v1_marker, .data = marker_bytes, .flags = .{ .permissions = .fromMode(0o600) } });
            try t.tmp.dir.setTimestamps(io, v1_marker, .{ .modify_timestamp = .{ .new = marker_mtime } });
        }
        if (point.v2_marker) try t.tmp.dir.writeFile(io, .{ .sub_path = v2_marker, .data = v2_marker_bytes, .flags = .{ .permissions = .fromMode(0o600) } });

        var recovered = try usage_recovery.collectFromHome(alloc, t.store.home);
        defer recovered.deinit(alloc);
        // Each marker reports the same fact: the ledger and every report
        // keep one fact per id (`profile_usage_store.classifyGeneration`,
        // `usage_report.buildRollingSnapshot`).
        const expected: usize = @as(usize, @intFromBool(point.v1_marker)) + @intFromBool(point.v2_marker);
        testing.expectEqual(expected, recovered.facts.len) catch |err| {
            std.debug.print("at {s}\n", .{point.name});
            return err;
        };
        for (recovered.facts) |fact| try testing.expect(usage_report.GenerationFact.eql(owed_facts[0], fact));
        var report = try usage_report.buildRollingSnapshot(alloc, .days_30, now_ms, now_ms - 10_000, recovered.facts, &.{});
        defer report.deinit(alloc);
        try testing.expectEqual(@as(u64, 10), report.totals.?.input_tokens);

        // And the next open leaves the v2 marker alone in charge of it.
        (try openConverted(&t, "v1-owed")).close();
        try testing.expect(!V1Home.exists(&t, "v1-owed"));
        try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, v1_marker, .{}));
        _ = try t.tmp.dir.statFile(io, v2_marker, .{});
    }
}

test "a new session never takes an id v1's folder could not be checked for (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const io = io_mod.getIo();
    var sessions = try t.tmp.dir.openDir(io, ".fx/sessions", .{});
    defer sessions.close(io);
    sessions.setPermissions(io, .fromMode(0o000)) catch return error.SkipZigTest;
    defer sessions.setPermissions(io, .fromMode(0o700)) catch {};
    var model = "m".*;
    try testing.expectError(error.SessionStoreUnavailable, Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model)));
}

test "a v1 folder whose kind cannot be told stays listed and is reported unreadable (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    try v1.session("v1-fine", &.{assistantTurn("q", "a")});
    try v1.session("v1-unknown", &.{assistantTurn("q", "a")});
    try v1.put("v1-unknown", null, "session.json", "{ not json");

    var cancel = std.atomic.Value(bool).init(false);
    var list = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 2), list.items.len);

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 1), report.unreadable);
    try testing.expectEqualStrings("v1-unknown", report.skipped.items[0].id);
    try testing.expectEqualStrings("session.json is not valid JSON", report.skipped.items[0].reason.?);
}

test "a legacy session larger than the current format's metadata converts (D61)" {
    const alloc = testing.allocator;
    const session_json = @import("session_json.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const long_answer = try alloc.alloc(u8, session_codec.max_session_metadata_bytes);
    defer alloc.free(long_answer);
    @memset(long_answer, 'a');
    const text = try session_json.renderSessionJson(alloc, "v1-big-legacy", 10, 20, types.ConversationLanguage.default(), "/w", &.{assistantTurn("old question", long_answer)}, .{});
    defer alloc.free(text);
    try testing.expect(text.len > session_codec.max_session_metadata_bytes);
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&v1.store.canonical_root.sessions.?, "v1-big-legacy");
    dir.close();
    try v1.put("v1-big-legacy", null, "session.json", text);

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    const s = try openConverted(&t, "v1-big-legacy");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(long_answer.len, restored.history[0].assistant.assistant.len);
}

test "a v1 side file larger than one v2 blob is left out and named, and the rest of its session converts and continues (D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    for ([_][]const u8{ "v1-huge", "v1-huge-all" }) |id| {
        try v1.session(id, &.{assistantTurn("q", "a")});
        var path: [64]u8 = undefined;
        var commands = try t.tmp.dir.createDirPathOpen(io, try std.fmt.bufPrint(&path, ".fx/sessions/{s}/logs/commands", .{id}), .{});
        defer commands.close(io);
        try commands.writeFile(io, .{ .sub_path = "small.bin", .data = "kept", .flags = .{ .permissions = .fromMode(0o600) } });
        var file = try commands.createFile(io, "replay.bin", .{});
        defer file.close(io);
        // Sparse: no disk for the hole.
        try file.setLength(io, sm.max_blob_bytes + 1);
    }
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(alloc);
    t.store.notice = .{ .context = &told, .emit = struct {
        fn emit(context: ?*anyopaque, text: []const u8) void {
            const out: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?));
            out.appendSlice(testing.allocator, text) catch {};
        }
    }.emit };

    // Opened: the host is told what was left out.
    const s = try openConverted(&t, "v1-huge");
    defer s.close();
    var expected: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "This session was converted without logs/commands/replay.bin, which is {d} bytes, more than the {d} the new store keeps in one file.", .{ sm.max_blob_bytes + 1, sm.max_blob_bytes }), told.items);
    try testing.expect(s.host.moved.get("logs/commands/small.bin") != null);
    try testing.expect(s.host.moved.get("logs/commands/replay.bin") == null);
    try s.commitTurn(assistantTurn("next", "reply"), types.ConversationLanguage.default());
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), restored.history.len);

    // Converted by `fx sessions convert`: the report names it.
    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 0), report.skipped.items.len);
    try testing.expectEqual(@as(usize, 1), report.left_out.items.len);
    const left = report.left_out.items[0];
    try testing.expectEqualStrings("v1-huge-all", left.id);
    try testing.expectEqualStrings("v1-huge-all", left.file.member);
    try testing.expectEqualStrings("logs/commands/replay.bin", left.file.file);
    try testing.expectEqual(@as(u64, sm.max_blob_bytes + 1), left.file.bytes);
}

test "only the adapter imports the session manager" {
    // Set by `zig build test`; tests read the process environment directly.
    const root = std.mem.span(std.c.getenv("FX_TEST_SOURCE_ROOT") orelse return error.SkipZigTest);
    const io = io_mod.getIo();
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var checked: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "core/session_manager/")) continue;
        if (std.mem.eql(u8, entry.path, "core/session/session_adapter.zig")) continue;
        const source = try dir.readFileAlloc(io, entry.path, testing.allocator, .limited(16 << 20));
        defer testing.allocator.free(source);
        if (std.mem.find(u8, source, "@import(\"session_manager\")") != null) {
            std.debug.print("{s} imports the session manager; only session_adapter.zig may\n", .{entry.path});
            return error.BoundaryViolation;
        }
        checked += 1;
    }
    try testing.expect(checked > 100);
}
