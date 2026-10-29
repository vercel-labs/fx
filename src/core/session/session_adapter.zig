//! The one door between fx and the session manager (sessions v2), fx's only
//! session store.
//!
//! Hosts call this file; it is the only fx file that imports
//! `session_manager`, and the boundary test at the bottom keeps it so. v1
//! code is never called from here except for its encoders and its turn
//! builder, so a session converted from v1 holds the same bytes for the same
//! history as one fx started here.
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
//!   writable open (D47, `tests/tla/session_manager/MoveSideFiles.tla`).
//!
//! Models of the sessions v2 rollout, one per step that changed this file:
//! - `tests/tla/session_manager/rollout/pr-1072/PR1072Ask.tla`: `fx ask`
//! - `tests/tla/session_manager/rollout/pr-1073/PR1073Interactive.tla`: resume and switch
//! - `tests/tla/session_manager/rollout/pr-1076/PR1076RunningTools.tla`: running tool calls
//! - `tests/tla/session_manager/rollout/pr-1079/PR1079ACP.tla`: ACP sessions
//! - `tests/tla/session_manager/rollout/pr-1081/PR1081Subagents.tla`: subagents
//! - `tests/tla/session_manager/rollout/pr-1082/PR1082Commands.tla`: session commands
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Blobs.tla`: bodies as blobs
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116ChildCheckpoint.tla`: child checkpoints
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Migration.tla`: moving older sessions
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Records.tla`: records and forks
//! - `tests/tla/session_manager/rollout/pr-1116/PR1116Terminal.tla`: hosted terminal state

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const sm = @import("session_manager");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_data = @import("../images/image_data.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_event = @import("session_event.zig");
const result_store = @import("result_store.zig");
const session_log = @import("session_log.zig");
const session_codec = @import("session_codec.zig");
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
const text_utils = @import("../shared/text_utils.zig");
const history_range = @import("../shared/history_range.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const Event = session_event.ConversationEvent;
const PieceKind = std.meta.Tag(Event);

/// Folder of the side files older v2 sessions kept, under `~/.fx`; a
/// session moves out of it on its first writable open (D47).
pub const files_dir_name = profile_paths.session_files_dir_name;
/// Folder of v2 sessions' hosted terminal state, under `~/.fx` (D45).
pub const terminal_dir_name = profile_paths.terminal_dir_name;
/// The profile's home folder, opened for listing: creating `~/.fx` in it
/// syncs it, and Linux cannot sync a folder opened any other way (`O_PATH`).
fn openHome(home: []const u8) !io_mod.VerifiedDir {
    return .{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true, .follow_symlinks = false }) };
}

/// Pieces larger than this go to a blob; the line keeps a reference.
const max_inline_piece_bytes: usize = 256 * 1024;
/// Lines per page when replaying history.
const replay_page_lines: usize = 256;

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
    if (comptime builtin.target.os.tag == .wasi) return 0;
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

    /// Touches no disk: a session's folder appears with its first turn.
    pub fn open(alloc: Allocator, home: []const u8) !Store {
        // Resolved as v1 resolves its sessions root, so a home reached
        // through a symlink (macOS `/var`) passes the no-follow opens below.
        const owned_home = io_mod.realpathAlloc(alloc, home) catch |err| blk: {
            debug_trace.logf("session", "event=sessions_v2_home_unresolved err={s} using=given", .{@errorName(err)});
            break :blk try alloc.dupe(u8, home);
        };
        errdefer alloc.free(owned_home);
        try checkSessionsPath(owned_home);
        const root = try std.Io.Dir.path.join(alloc, &.{
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

    /// Refuses, before any session is asked for, a `~/.fx`, `~/.fx/sessions`
    /// or `v2` folder that is not a real folder, such as a file or a symlink
    /// (D67): every write would fail on it. One that is missing is made by
    /// the first write; one that others can read converts (D61).
    fn checkSessionsPath(home: []const u8) !void {
        var parent = openHome(home) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer parent.close();
        for ([_][]const u8{ profile_paths.root_dir_name, profile_paths.sessions_dir_name, session_layout.sessions_v2_dir }) |name| {
            const next = (io_mod.openRealDirIfPresent(&parent, name) catch |err| switch (err) {
                error.DurablePathUnsafe => return error.SessionPathUnsafe,
                else => return err,
            }) orelse return;
            parent.close();
            parent = next;
        }
    }

    /// `$HOME` from the environment.
    pub fn openFromEnv(alloc: Allocator) !Store {
        return open(alloc, io_mod.homeDir() orelse return error.HomeNotSet);
    }

    /// Every Session must be closed first.
    pub fn deinit(store: *Store, alloc: Allocator) void {
        traceWiring("StoreClose", "-", "", store.pid);
        store.manager.deinit();
        alloc.free(store.home);
        store.* = undefined;
    }

    /// `~/.fx/{name}`, or null when nothing has made it yet.
    /// Every caller is about to change the folder, so an existing `~/.fx` is
    /// made `0700` as every other fx writer makes it: one made by hand or an
    /// install script keeps the default mode, and refusing it would refuse
    /// every resume.
    fn openProfileFolder(store: *Store, name: []const u8) !?io_mod.VerifiedDir {
        var home = try openHome(store.home);
        defer home.close();
        _ = home.dir.statFile(io_mod.getIo(), profile_paths.root_dir_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        var fx = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.root_dir_name);
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
            if (!copyTree(io_mod.openVerifiedPrivateDirIfPresent, &source, &target, 0)) complete = false;
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
    SessionRecoveryNotNeeded,
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
        // v1's own recovery, salvaging a v1 session (D64). An older format
        // it reads whole needs none; one it cannot read has no boundary.
        error.SessionRecoveryNotNeeded => error.SessionRecoveryNotNeeded,
        error.SessionRecoveryBoundaryInvalid, error.SessionRecoveryRequiresCurrentSchema => error.SessionRecoveryBoundaryInvalid,
        error.SessionRecoveryUnsupportedSchema => error.UnsupportedSessionSchema,
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
    store.problem = .{};
    var detail = (v1_conversion.readDetail(alloc, store.home, id) catch |err| switch (err) {
        error.OutOfMemory, error.SessionNotFound => return err,
        else => return v1Unreadable(store, alloc, id, err),
    }) orelse return error.SessionNotFound;
    defer detail.summary.deinit(alloc);
    errdefer detail.state.deinit(alloc);
    const title = if (detail.summary.title) |value| try alloc.dupe(u8, value) else null;
    return .{ .state = detail.state, .title = title };
}

/// A v1 root v1's reader refuses, however it fails: damage, with the file
/// and the reason in `store.problem` when the converter's read names them
/// (D78).
fn v1Unreadable(store: *Store, alloc: Allocator, id: []const u8, err: anyerror) error{ OutOfMemory, InvalidSessionFormat } {
    debug_trace.logf("session", "event=v1_detail_unreadable session={s} err={s}", .{ id, @errorName(err) });
    const stuck = (checkV1(store, alloc, id) catch |check_err| switch (check_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    }) orelse {
        store.problem = .{};
        return error.InvalidSessionFormat;
    };
    defer {
        alloc.free(stuck.id);
        alloc.free(stuck.reason);
    }
    store.problem = .{};
    return store.problem.set("{s}", .{stuck.reason});
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
    var page = try session_summary_codec.sessionListPageFromSummaries(alloc, candidates.items, workspace, continuation, limit);
    // A workspace's page leaves out v1's roots that can't be read, whose
    // workspace is unknown, and counts them as v1 did; the profile-wide
    // listing shows them instead (D61).
    if (workspace != null and continuation == null) {
        for (v1_roots.summaries.items) |summary| {
            if (summary.workspace_root == null) page.skipped_invalid += 1;
        }
    }
    return page;
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
    /// True when the source's saved permission rules could not be read, so
    /// the copy has none (D72).
    permission_rules_dropped: bool = false,

    pub fn deinit(recovered: *Recovered, alloc: Allocator) void {
        alloc.free(recovered.id);
        recovered.* = undefined;
    }
};

/// `fx session recover` (D15): a new root session copied from `id` up to
/// its last turn that ended before any damage, with a copy of its side
/// files. The source is never changed, and may be held by another process.
/// A v1 session is salvaged as v1's recover salvaged it (D64). Caller owns
/// the result.
pub fn recover(store: *Store, alloc: Allocator, id: []const u8) !Recovered {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // Line 1 names the session's kind and workspace, however damaged the rest is.
    var first = store.manager.read(sa, id, .start, .forward, 1) catch |err| return switch (err) {
        error.NotFound, error.InvalidArgument => salvageV1(store, alloc, id),
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

/// `fx session recover` on a session only v1 holds (D64). Caller owns the
/// result.
fn salvageV1(store: *Store, alloc: Allocator, id: []const u8) !Recovered {
    var conversion: Conversion = .{ .store = store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
    defer conversion.deinit();
    return conversion.salvage(id);
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
    /// Roots an older fx saved that v2 does not hold yet; each converts
    /// when it is first opened (D73).
    unconverted: usize = 0,
    /// v1 folders of converted sessions and subagents, kept subagents among
    /// them, that keep something their copy left out (D56, D62).
    keeps_left_out: usize = 0,
    /// Those of them that can't be converted, among the checked ones.
    stuck: std.ArrayList(Stuck) = .empty,
    /// Each v1 subagent no conversion takes, kept as it is (D88).
    kept_children: []KeptChild = &.{},

    pub const Stuck = struct {
        id: []u8,
        /// The file and the reason the conversion refuses it.
        reason: []u8,
        /// What `fx session recover` copies of it.
        recover: enum { without_rules, good_turns, nothing },
    };

    pub fn deinit(report: *Doctor, alloc: Allocator) void {
        if (report.latest) |id| alloc.free(id);
        for (report.damaged.items) |id| alloc.free(id);
        report.damaged.deinit(alloc);
        for (report.stuck.items) |stuck| {
            alloc.free(stuck.id);
            alloc.free(stuck.reason);
        }
        report.stuck.deinit(alloc);
        freeKeptChildren(alloc, report.kept_children);
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
    try doctorV1(store, alloc, &report, limit);
    report.kept_children = try keptChildren(store, alloc);
    for (report.kept_children) |child| report.keeps_left_out += @intFromBool(child.keeps);
    try store.sweepFiles(alloc, &report, now_ms);
    return report;
}

/// Counts the roots an older fx saved that v2 does not hold yet, and names
/// each checked one that can't be converted with what `fx session recover`
/// copies of it (D73). Reads only; a busy family is left out.
fn doctorV1(store: *Store, alloc: Allocator, report: *Doctor, limit: usize) !void {
    const roots = v1_conversion.rootIds(alloc, store.home) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("session", "event=doctor_v1_unlisted err={s}", .{@errorName(err)});
            return;
        },
    };
    defer {
        for (roots) |root| root.deinit(alloc);
        alloc.free(roots);
    }
    for (roots) |root| {
        if (store.manager.peek(alloc, root.id)) |peeked_value| {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();
            const a = scratch.allocator();
            if (parseV1Source(a, peeked.state.v1_source)) |source| {
                if (source.keeps()) report.keeps_left_out += 1;
            }
            for (peeked.state.children.items) |child| {
                const present = v1_conversion.hasFolder(store.home, child.id) catch |err| {
                    debug_trace.logf("session", "event=doctor_v1_child_unread session={s} err={s}", .{ child.id, @errorName(err) });
                    continue;
                };
                if (!present) continue;
                const child_state_value = store.manager.peek(a, child.id) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        debug_trace.logf("session", "event=doctor_v1_child_unread session={s} err={s}", .{ child.id, @errorName(err) });
                        continue;
                    },
                };
                if (parseV1Source(a, child_state_value.state.v1_source)) |source| {
                    if (source.keeps()) report.keeps_left_out += 1;
                }
            }
            continue;
        } else |err| switch (err) {
            error.NotFound, error.InvalidArgument => {},
            error.OutOfMemory => return err,
            else => continue,
        }
        report.unconverted += 1;
        if (report.checked == limit) continue;
        report.checked += 1;
        try report.stuck.ensureUnusedCapacity(alloc, 1);
        if (root.unreadable) |why| {
            report.stuck.appendAssumeCapacity(try stuckRoot(alloc, root.id, why, .nothing));
            continue;
        }
        if (try checkV1(store, alloc, root.id)) |stuck| report.stuck.appendAssumeCapacity(stuck);
    }
}

fn stuckRoot(alloc: Allocator, id: []const u8, reason: []const u8, recover_kind: @FieldType(Doctor.Stuck, "recover")) !Doctor.Stuck {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    return .{ .id = owned_id, .reason = try alloc.dupe(u8, reason), .recover = recover_kind };
}

/// Null when `root_id`'s family converts, or is busy.
fn checkV1(store: *Store, alloc: Allocator, root_id: []const u8) !?Doctor.Stuck {
    store.problem = .{};
    var v1 = try session_store.Store.initReadOnlyFromHome(alloc, store.home, "/");
    defer v1.deinit(alloc);
    var locks = v1_conversion.lockFamily(alloc, &v1, root_id, 0, &store.problem) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SessionBusy, error.SessionNotFound => return null,
        error.InvalidSessionFormat => return try stuckRoot(alloc, root_id, store.problem.text(), .nothing),
        else => return try stuckRoot(alloc, root_id, @errorName(err), .nothing),
    };
    defer locks.release();
    for (locks.members.items) |*locked| {
        var member = v1_conversion.readMember(alloc, &v1, locked, &store.problem, .required) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        member.deinit();
    } else return null;
    var reason: [v1_conversion.Problem.capacity]u8 = undefined;
    const why = if (store.problem.len > 0) store.problem.text() else "its folder can't be read";
    @memcpy(reason[0..why.len], why);
    // What `recover` would copy, read in the order its salvage reads: a
    // root that reads whole is not salvaged at all.
    const root = &locks.members.items[0];
    const recover_kind: @FieldType(Doctor.Stuck, "recover") = kind: {
        store.problem = .{};
        if (v1_conversion.readMember(alloc, &v1, root, &store.problem, .required)) |whole| {
            var read = whole;
            read.deinit();
            break :kind .nothing;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        if (v1_conversion.readMember(alloc, &v1, root, &store.problem, .drop_unreadable)) |whole| {
            var read = whole;
            read.deinit();
            break :kind .without_rules;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        if (v1_conversion.readSalvage(alloc, &v1, root, &store.problem)) |salvaged| {
            var read = salvaged;
            read.deinit();
            break :kind .good_turns;
        } else |err| if (err == error.OutOfMemory) return err;
        break :kind .nothing;
    };
    return try stuckRoot(alloc, root_id, reason[0..why.len], recover_kind);
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
    /// The stored title, generated or chosen by the user.
    title: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64 = 0,

    pub fn deinit(restored: *Restored, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, restored.history);
        if (restored.title) |value| alloc.free(value);
        if (restored.preferences) |*value| value.deinit(alloc);
        if (restored.permission_state) |*value| value.deinit(alloc);
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
    records: std.array_hash_map.String(Hash) = .empty,
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
        var map: std.array_hash_map.String([]const u8) = .empty;
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
        const key = std.mem.print(&key_buffer, "{s}/{s}", .{ folder, name }) catch return error.BlobNotFound;
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

/// Whether the session `fx -c` opens in `workspace` left its newest turn
/// unfinished: still open, or ended by a crash or a closed window. A session
/// another fx has open is working, not interrupted. Reads the index, the
/// session's lock, and its log tail, and writes nothing.
pub fn hasInterruptedTurn(store: *Store, alloc: Allocator, workspace: []const u8) bool {
    const id = (store.manager.lastOpened(alloc, workspace, .app) catch return false) orelse return false;
    defer alloc.free(id);
    if (store.manager.isBusy(id) catch true) return false;
    var peeked = store.manager.peek(alloc, id) catch return false;
    defer peeked.deinit(alloc);
    const state = peeked.state;
    if (state.open_turn != null) return true;
    const last = state.last_interrupted orelse return false;
    return last.turn == state.last_turn and (last.reason == .crash or last.reason == .closed);
}

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
    /// Prompt images saved as blobs (D89), digest to blob path, both owned.
    /// The store deletes no blob of a live session, so an entry stays true,
    /// and every copy of a turn the host passes encodes its images alike.
    prompt_blobs: std.array_hash_map.String([]u8) = .empty,
    turn_open: bool = false,
    /// Highest turn number started; the manager numbers turns the same way.
    last_turn: u64 = 0,
    /// The v2 turn behind each of fx's history turns, in order; null for a
    /// compacted summary.
    turn_numbers: std.ArrayList(?u64) = .empty,
    /// What fx's history leaves out of its first kept turn (D87).
    trim: Trim = .{},
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
    /// A child's instructions as its `prefs` hold them (D34), owned; null
    /// for a root and for a child without any.
    instructions: ?[]u8 = null,
    /// A conversion's import: the original time of the batches it writes
    /// next (D59). Null for every other session.
    import_ts: ?u64 = null,
    /// The session's token totals as its newest `set usage` holds them
    /// (D92), read from the log on the first reply this process records.
    usage: ?types.Usage = null,

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
    /// still to convert (`tests/tla/session_manager/V1Conversion.tla` NoShadow). `openNew` touches
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
    /// D61, `tests/tla/session_manager/V1Conversion.tla`): every host opens through here.
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
                const newest = (try newestListed(store, alloc, workspace)) orelse return noLatestError(store, alloc);
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
        const files_path = try std.Io.Dir.path.join(alloc, &.{ store.home, profile_paths.root_dir_name, files_dir_name, handle.id() });
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
        const value = try a.print("{{\"map\":\"{s}\"}}", .{map_hash});
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

    /// The session is on disk, so `fx --resume` opens it: from its first
    /// turn, ended or open, or from its open when it was resumed or forked.
    /// A fork before the first prompt holds no turn and is saved (D90).
    pub fn saved(self: *const Session) bool {
        return self.handle.onDisk();
    }

    /// The session's folder under `~/.fx/sessions/v2`, for display. Caller owns it.
    pub fn folderPath(self: *const Session, alloc: Allocator) ![]u8 {
        return std.Io.Dir.path.join(alloc, &.{
            self.store.home,
            profile_paths.root_dir_name,
            profile_paths.sessions_dir_name,
            session_layout.sessions_v2_dir,
            self.id(),
        });
    }

    /// Closes the session and frees the adapter. Every child thread of this
    /// session must have joined (`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren).
    /// A copy of its capability that a background reader still holds keeps
    /// reading, and stores nothing more (D44).
    pub fn close(self: *Session) void {
        // Before the close, which forgets whether the log is on disk.
        const was_saved = self.saved();
        self.host.detach();
        self.handle.close() catch |err| debug_trace.logf("session", "event=sessions_v2_close_failed session={s} err={s}", .{ self.id(), @errorName(err) });
        if (self.root) traceWiring("Close", self.id(), "", self.store.pid);
        if (self.turn_open) debug_trace.logf("session", "event=sessions_v2_turn_closed_open session={s} streamed={d}", .{ self.id(), self.streamed.items.len });
        // Before `release`: the id lives in the handle.
        if (!was_saved) self.removeUnsavedFiles();
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
        for (self.prompt_blobs.keys(), self.prompt_blobs.values()) |digest, path| {
            alloc.free(digest);
            alloc.free(path);
        }
        self.prompt_blobs.deinit(alloc);
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
        const terminal_path = try std.Io.Dir.path.join(self.alloc, &.{ self.store.home, profile_paths.root_dir_name, terminal_dir_name, self.id() });
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

    /// Opens the turn as its work starts. A subagent child streams nothing,
    /// and its tools may store bodies before the commit (D44); an ACP prompt
    /// opens it before the model is asked, so a disk that cannot take the
    /// turn fails the prompt first.
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
        for (all, encoded) |piece, *bytes| bytes.* = try self.encodeEvent(a, piece);
        const start = try self.streamedPrefix(encoded[0..pieces.len], .commit, countResults(pieces));

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

        try self.writePieces(a, all[start..], encoded[start..], tail.items, openingAuthor(turn));
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

    /// Saves each prompt image of the turn as a blob named by its digest
    /// before the turn's first request is built, and gives the image that
    /// blob's path for the model's note (`AgentRuntimeDeps.save_prompt_images`,
    /// D89, `tests/tla/session_manager/PromptImages.tla`). Each save lists
    /// the blob again on the turn's next item, so a fork hard-links it even
    /// after a crash lost an earlier listing. A saved image then keeps only
    /// that handle, and readers load its bytes from the blob. An image the
    /// store refuses keeps its bytes inline, as before D89, and gets no
    /// path. An image that arrives as only a handle, perhaps to another
    /// session's blob, is saved from that file. `alloc` owns `images` and
    /// what this sets on them; the bytes an image arrived with are the
    /// caller's and are not freed.
    pub fn savePromptImages(self: *Session, alloc: Allocator, images: []types.ImageAttachment) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (images) |*image| {
            // Bytes this read from the file a handle names, which `alloc` owns.
            var loaded: ?[]u8 = null;
            if (image.inline_data == null) {
                const verified = image_attachments.loadVerifiedSnapshot(alloc, image.*, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        debug_trace.logf("session", "event=sessions_v2_prompt_image_unreadable session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                        image.blob_path = null;
                        continue;
                    },
                };
                loaded = verified.bytes;
                image.inline_data = verified.bytes;
            }
            image.blob_path = null;
            const bytes = image.inline_data.?;
            const digest = image.snapshot_sha256 orelse continue;
            const path = self.savePromptImageLocked(bytes, digest) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("session", "event=sessions_v2_prompt_image_inline session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                    continue;
                },
            };
            image.blob_path = try alloc.dupe(u8, path);
            image.inline_data = null;
            if (loaded) |value| alloc.free(value);
        }
    }

    /// The path of the blob holding `bytes`, owned by `prompt_blobs`. A turn
    /// the store cannot start fails the save, as a refused blob does, so the
    /// image stays inline and the prompt goes on.
    fn savePromptImageLocked(self: *Session, bytes: []const u8, digest: []const u8) ![]const u8 {
        // A blob needs the turn on disk (D44).
        try self.openTurnLocked();
        const hash = try BlobHost.put(self.host, bytes);
        // The digest names the blob: bytes that do not match it are not
        // saved under it.
        if (!std.mem.eql(u8, &hash, digest)) return error.ImageDigestMismatch;
        if (self.prompt_blobs.get(digest)) |path| return path;
        // The blob's path once the session is published, as
        // `Manager.blobPath` joins it, so a conversion's staged import (D59)
        // names its images too. The put above just stored the file.
        const path = try std.Io.Dir.path.join(self.alloc, &.{ self.store.manager.root_path, self.id(), "blobs", &hash });
        errdefer self.alloc.free(path);
        const key = try self.alloc.dupe(u8, digest);
        errdefer self.alloc.free(key);
        try self.prompt_blobs.put(self.alloc, key, path);
        return path;
    }

    /// `event` as this session writes it: an image is written as a blob
    /// exactly when this session saved it as one, whichever copy of the turn
    /// the host passes and whatever path the copy carries. So a commit
    /// matches what was streamed, and an item never names another session's
    /// blob (D89, `tests/tla/session_manager/PromptImages.tla` RefHasBlob).
    fn encodeEvent(self: *Session, a: Allocator, event: Event) ![]u8 {
        const user = switch (event) {
            .user => |value| value,
            .tool_result => |value| return encodePiece(a, .{ .tool_result = try withoutReviewLines(value) }),
            else => return encodePiece(a, event),
        };
        if (user.images.len == 0) return encodePiece(a, event);
        const images = try a.dupe(types.ImageAttachment, user.images);
        for (images) |*image| {
            const digest = image.snapshot_sha256 orelse {
                image.blob_path = null;
                continue;
            };
            image.blob_path = self.prompt_blobs.get(digest);
        }
        return encodePiece(a, .{ .user = .{ .text = user.text, .images = images, .work_id = user.work_id } });
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
        return self.appendProgressWithRecord(user, execution, running, .keep);
    }

    /// `appendProgress`, with the recovery module's record for the send this
    /// write goes before (`recovery_type`).
    pub fn appendProgressWithRecord(
        self: *Session,
        user: types.UserTurn,
        execution: types.ExecutionMemory,
        running: Running,
        record: types.RecoveryRecordWrite,
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
        for (events.items, encoded) |event, *bytes| bytes.* = try self.encodeEvent(a, event);
        const start = try self.streamedPrefix(encoded, .stream, countResults(events.items));
        // The record goes out in the same write as the pieces before its
        // send, so a turn's first write already carries it
        // (`tests/tla/recovery/Resume.tla` CrashLoopAsks).
        var tail: std.ArrayList(sm.Event) = .empty;
        if (try self.recoveryItem(a, record)) |piece| try tail.append(a, .{ .item = piece });
        if (!self.turn_open or start < encoded.len) {
            try self.writePieces(a, events.items[start..], encoded[start..], tail.items, user.author);
            try self.streamed.ensureUnusedCapacity(self.alloc, encoded.len - start);
            for (encoded[start..]) |bytes| self.streamed.appendAssumeCapacity(try self.alloc.dupe(u8, bytes));
        } else if (tail.items.len > 0) {
            _ = try self.write(tail.items);
        }
        try self.saveRunning(a, running);
    }

    /// Saves or clears the record in the open turn. A turn not written yet
    /// takes the record with its first pieces instead, so this writes
    /// nothing and returns false.
    pub fn saveRecovery(self: *Session, record: types.RecoveryRecordWrite) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.turn_open) return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const piece = (try self.recoveryItem(a, record)) orelse return false;
        _ = try self.write(&.{.{ .item = piece }});
        return true;
    }

    fn recoveryItem(self: *Session, a: Allocator, record: types.RecoveryRecordWrite) !?sm.Piece {
        const bytes: []u8 = switch (record) {
            .keep => return null,
            .save => |value| try a.print("{{\"record\":\"{x}\"}}", .{&value}),
            .clear => try a.dupe(u8, "{\"record\":null}"),
        };
        return try self.itemAs(a, recovery_type, bytes);
    }

    /// The model request a crash or a close left unfinished in the newest
    /// turn: the record of its newest `recovery` piece, null when its
    /// response had arrived or none was saved, and when it was saved. Null
    /// when the newest turn ended otherwise, has no prompt, or completed.
    pub fn interruptedRequest(self: *Session) !?InterruptedRequest {
        var state = try self.handle.state(self.alloc);
        defer state.deinit(self.alloc);
        const ended = state.last_interrupted orelse return null;
        if (state.open_turn != null or ended.turn != state.last_turn) return null;
        switch (ended.reason) {
            .crash, .closed => {},
            .cancel, .failed => return null,
        }
        var found: InterruptedRequest = .{ .record = null, .saved_ms = 0 };
        var record_seen = false;
        var has_prompt = false;
        var from: sm.From = .end;
        scan: while (true) {
            var page = try self.source().readTo(self.alloc, from, .backward, replay_page_lines);
            defer page.deinit();
            for (page.entries) |entry| {
                const body = entry.body orelse continue;
                switch (body) {
                    .turn_started => |started| if (started.turn == ended.turn) break :scan,
                    .item => |piece| {
                        if (found.saved_ms == 0) found.saved_ms = entry.ts_ms;
                        if (std.mem.eql(u8, piece.type, itemType(.turn_completed).?)) return null;
                        if (std.mem.eql(u8, piece.type, itemType(.user).?)) has_prompt = true;
                        if (record_seen or !std.mem.eql(u8, piece.type, recovery_type)) continue;
                        record_seen = true;
                        found.saved_ms = entry.ts_ms;
                        found.record = parseRecoveryRecord(try self.source().pieceData(page.arena.allocator(), piece));
                    },
                    else => {},
                }
            }
            from = .{ .at = page.next orelse break };
        }
        return if (has_prompt) found else null;
    }

    /// See `interruptedRequest`.
    pub const InterruptedRequest = struct {
        record: ?[32]u8,
        /// `ts` of the line that saved the record, or of the turn's newest
        /// piece when no record was saved.
        saved_ms: u64,
    };

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
    /// Writes `events` as the open turn's items, opening it first if it is
    /// not open. When the user piece is among them and someone other than
    /// the user wrote it, an `author` item follows it, once: a stream writes
    /// each piece once, and a superseded turn is written afresh.
    fn writePieces(self: *Session, a: Allocator, events: []const Event, encoded: []const []u8, tail: []const sm.Event, author: types.MessageAuthor) !void {
        const reviews = try a.alloc(?[]u8, events.len);
        for (events, reviews) |event, *review| review.* = try encodeFileReview(a, event);
        var batch: std.ArrayList(sm.Event) = .empty;
        if (!self.turn_open) {
            try batch.append(a, .turn_started);
            const needs_blob = for (encoded, reviews) |bytes, review| {
                if (bytes.len > max_inline_piece_bytes) break true;
                if (review) |data| if (data.len > max_inline_piece_bytes) break true;
            } else false;
            if (needs_blob) {
                _ = try self.write(batch.items);
                self.startedTurn();
                batch.clearRetainingCapacity();
            }
        }
        for (events, encoded, reviews) |event, bytes, review| {
            try batch.append(a, .{ .item = try self.item(a, std.meta.activeTag(event), bytes) });
            if (review) |data| try batch.append(a, .{ .item = try self.itemAs(a, file_review_type, data) });
            if (event == .user and author != .user) {
                try batch.append(a, .{ .item = try self.itemAs(a, author_type, try encodeAuthor(a, author)) });
            }
        }
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
        // v1 had subagent results only as tool results: every turn is the user's.
        try self.importTurn(a, all, .user);
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
        try self.importTurn(a, events.items, openingAuthor(copy));
    }

    /// Saves each image of `events`' user items as this session's blob, as
    /// a turn's start saves a prompt's (D89), so a converted session names
    /// its images by blob too. An image the store refuses keeps its bytes
    /// inline. The caller holds the mutex.
    fn saveImportedImages(self: *Session, events: []const Event) !void {
        for (events) |event| switch (event) {
            .user => |user| for (user.images) |image| {
                const bytes = image.inline_data orelse continue;
                const digest = image.snapshot_sha256 orelse continue;
                _ = self.savePromptImageLocked(bytes, digest) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("session", "event=sessions_v2_prompt_image_inline session={s} image={d} reason={s}", .{ self.id(), image.id, @errorName(err) });
                    continue;
                };
            },
            else => {},
        };
    }

    /// `events`, a turn's pieces, ended by the last one.
    fn importTurn(self: *Session, a: Allocator, turn_events: []const Event, author: types.MessageAuthor) !void {
        if (turn_events.len < 2) return error.InvalidConversationFrame;
        const events = try a.dupe(Event, turn_events);
        try self.saveImportedImages(events);
        const encoded = try a.alloc([]u8, events.len);
        for (events, encoded) |event, *bytes| bytes.* = try self.encodeEvent(a, event);
        const end: sm.Event = switch (events[events.len - 1]) {
            .turn_completed => .turn_committed,
            .interrupted => |interruption| .{ .turn_interrupted = switch (interruption.reason) {
                .cancelled => .cancel,
                .failed => .failed,
            } },
            else => return error.InvalidConversationFrame,
        };
        try self.writePieces(a, events, encoded, &.{end}, author);
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
    /// `phase` and `results`, the rebuild's tool result count, only name
    /// the decision in the session trace, which the driver of
    /// `tests/tla/session/TurnStreamTrace.tla` replays.
    fn streamedPrefix(self: *Session, encoded: []const []u8, phase: StreamPhase, results: usize) !usize {
        const streamed = self.streamed.items;
        const held = if (self.turn_open) streamed.len else 0;
        const reparsed: ?usize = if (self.turn_open) reparsedPrefix(self.alloc, streamed, encoded) else 0;
        debug_trace.logf("session", "event=sessions_v2_stream session={s} phase={s} held={d} kept={d} results={d} reparsed={d}", .{
            self.id(), @tagName(phase), held, if (reparsed != null) held else 0, results, reparsed orelse 0,
        });
        if (!self.turn_open) return 0;
        if (reparsed != null) return streamed.len;
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
            .data = try a.print("{{\"{s}\":\"{s}\"}}", .{ blob_ref_key, hash_copy }),
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
        // Whether `keep_from` is the turn the cut falls in.
        var cut_turn = false;
        for (self.turn_numbers.items[first_kept..], 0..) |number, slot| {
            if (number) |n| {
                keep_from = n;
                cut_turn = slot == 0;
                break;
            }
        }
        if (keep_from == null and active_prefix and self.turn_open) {
            keep_from = self.last_turn;
            cut_turn = true;
        }
        // A cut inside a turn counts from where fx's view of that turn starts,
        // past what an earlier compaction inside it covered (D87).
        const trim: Trim = if (!cut_turn) .{} else if (self.trim.turn == keep_from) .{
            .turn = keep_from,
            .tool_steps = self.trim.tool_steps + cut.tool_steps,
            .steering = self.trim.steering + cut.steering,
        } else .{ .turn = keep_from, .tool_steps = cut.tool_steps, .steering = cut.steering };
        if (trim.tool_steps != 0 or trim.steering != 0) {
            debug_trace.logf("session", "event=sessions_v2_compaction_cut session={s} turn={?d} tool_steps={d} steering={d}", .{ self.id(), trim.turn, trim.tool_steps, trim.steering });
        }
        const data: CompactedData = .{
            .summary = summary.summary,
            .removed_turn_count = summary.removed_turn_count,
            .compaction_count = summary.compaction_count,
            .keep_from_turn = keep_from,
            .keep_tool_steps = trim.tool_steps,
            .keep_steering = trim.steering,
        };
        _ = try self.write(&.{.{ .compacted = try jsonValue(arena.allocator(), data) }});
        self.trim = if (trim.tool_steps != 0 or trim.steering != 0) trim else .{};
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
        return try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{}));
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

    /// Adds one model reply's provider usage to the session's totals and
    /// writes them as `set usage`, so a run that is killed or times out
    /// keeps the usage of every reply it received (D92). A reply with no
    /// counts writes nothing.
    pub fn recordUsage(self: *Session, reply: types.Usage) !void {
        if (std.meta.eql(reply, types.Usage{})) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var total = self.usage orelse try self.savedUsage(sa);
        total.add(reply);
        const value = try std.json.Stringify.valueAlloc(sa, total, .{});
        _ = try self.write(&.{.{ .set = .{ .key = .usage, .value = value } }});
        self.usage = total;
    }

    /// The totals the log's newest `set usage` holds. A value written
    /// before D92, or one fx cannot read, counts from zero.
    fn savedUsage(self: *Session, sa: Allocator) !types.Usage {
        const raw = (try self.handle.state(sa)).usage orelse return .{};
        return json_decode.parseFromSliceLeaky(types.Usage, sa, raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("session", "event=sessions_v2_usage_reset session={s} reason={s} dropped=saved_usage", .{ self.id(), @errorName(err) });
                return .{};
            },
        };
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
            const current = try json_decode.parseFromSliceLeaky([]const u8, a, raw, .{});
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
        var restored = try restoreFrom(self.source(), alloc, sa, state, .{ .alloc = self.alloc, .list = &self.turn_numbers, .trim = &self.trim });
        errdefer restored.deinit(alloc);
        if (self.first_title) |value| self.alloc.free(value);
        self.first_title = null;
        if (self.root and state.title == null) {
            if (try deriveTitle(sa, restored.history)) |title| self.first_title = try self.alloc.dupe(u8, title);
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

    /// A prompt a fork can start before: the turn it opened and its text.
    pub const ForkPoint = struct {
        turn: u64,
        prompt: []u8,
    };

    /// Every turn's prompt in the log, oldest first, for `fork` (D58).
    /// Caller owns the slice and each prompt; free with `freeForkPoints`.
    pub fn forkPoints(self: *Session, alloc: Allocator) ![]ForkPoint {
        const Sink = struct {
            alloc: Allocator,
            points: std.ArrayList(ForkPoint) = .empty,

            fn turn(sink: *@This(), value: types.HistoryTurn, number: ?u64) !void {
                defer types.freeHistoryTurn(sink.alloc, value);
                const user = switch (value) {
                    .assistant => |entry| entry.user,
                    .interrupted => |entry| entry.user,
                    .compacted_summary => return,
                };
                const prompt = try sink.alloc.dupe(u8, user.text);
                errdefer sink.alloc.free(prompt);
                try sink.points.append(sink.alloc, .{ .turn = number orelse return error.InvalidConversationFrame, .prompt = prompt });
            }

            fn summary(_: *@This(), _: []const u8) !void {}
        };
        var sink: Sink = .{ .alloc = alloc };
        errdefer {
            for (sink.points.items) |point| alloc.free(point.prompt);
            sink.points.deinit(alloc);
        }
        try replay(self.source(), alloc, alloc, .start, null, ReplaySink.init(&sink));
        return sink.points.toOwnedSlice(alloc);
    }

    pub fn freeForkPoints(alloc: Allocator, points: []const ForkPoint) void {
        for (points) |point| alloc.free(point.prompt);
        alloc.free(points);
    }

    pub const Fork = struct {
        /// The fork holds every turn before this one (a `ForkPoint.turn`).
        before_turn: u64,
        workspace: []const u8,
        host: Host,
        /// The title the source shows; the fork gets it marked as a fork.
        title: ?[]const u8 = null,
    };

    /// A new session holding this one's log up to the end of the turn before
    /// `options.before_turn`, under a new id (D58). The manager copies the
    /// lines and hard-links the blobs; this session is never written. The
    /// caller owns the fork, open for writing.
    pub fn fork(self: *Session, alloc: Allocator, options: Fork) !*Session {
        if (options.before_turn == 0) return error.InvalidForkPoint;
        io_mod.e2eFailIfDurableMutationAttempted();
        const handle = try self.store.manager.openFork(.{
            .source = self.id(),
            .at = .{ .turn = options.before_turn - 1 },
            .workspace = options.workspace,
            .host = options.host,
        });
        errdefer handle.release();
        const copy = try init(alloc, self.store, handle, false);
        errdefer copy.destroyInner();
        try copy.openMoved();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const state = try handle.state(arena.allocator());
        copy.last_turn = state.last_turn;
        if (options.title) |title| try copy.rename(try forkTitle(arena.allocator(), title));
        traceWiring("Fork", copy.id(), "", copy.store.pid);
        return copy;
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
        const title = if (st.title) |raw| try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{})) else null;
        return .{ .title = title, .updated_ms = std.math.cast(i64, st.updated_ms) orelse 0 };
    }

    fn source(self: *Session) Source {
        return .{ .store = self.store, .id = self.id(), .handle = self.handle, .host = self.host, .files_path = self.files_path };
    }

    // -- the move off the side folder (D47) -----------------------------------

    /// Makes an older session one manager folder (D47,
    /// `tests/tla/session_manager/MoveSideFiles.tla`) on its first writable
    /// open, then loads the map its old handles resolve through. Every body
    /// in the side folder becomes a blob, the map from each old name to its
    /// blob is one more blob, and one batch records the map, every moved
    /// blob, and the client's settings from the old files.
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
    /// `tests/tla/session_manager/MoveSideFiles.tla` checks; returns how many bodies moved.
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
        const value = json_decode.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its old handles read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_moved_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = json_decode.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
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
        const value = json_decode.parseFromSliceLeaky(Value, sa, raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionFormat;
        const bytes = self.store.manager.getBlob(sa, self.id(), value.map) catch |err| switch (err) {
            // A lost or damaged map damages the session, as a lost blob
            // does (D39); its records read as gone.
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_records_map_unreadable session={s} err={s}", .{ self.id(), @errorName(err) });
                return;
            },
            else => |e| return e,
        };
        const map = json_decode.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), sa, bytes, .{}) catch return error.InvalidSessionFormat;
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
/// Whether `stored` holds the result body named `handle`.
fn storedInline(stored: []const v1_conversion.Stored, handle: []const u8) bool {
    const prefix = "tool-results/";
    for (stored) |entry| {
        if (entry.key.len == prefix.len + handle.len and std.mem.startsWith(u8, entry.key, prefix) and std.mem.endsWith(u8, entry.key, handle)) return true;
    }
    return false;
}

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
    var moved: std.array_hash_map.String([]const u8) = .empty;
    try moved.ensureTotalCapacity(a, bodies.items.len + stored.len);
    for (bodies.items) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &body.hash));
    for (stored) |body| moved.putAssumeCapacity(body.key, try a.dupe(u8, &(try handle.putBlob(body.bytes))));
    var map_json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(std.json.ArrayHashMap([]const u8){ .map = moved }, .{}, &map_json.writer);
    const map_hash = try a.dupe(u8, &(try handle.putBlob(map_json.written())));

    var events: std.ArrayList(sm.Event) = .empty;
    const value = try a.print("{{\"map\":\"{s}\"}}", .{map_hash});
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
        try bodies.append(a, .{ .dir = dir, .name = try a.dupe(u8, entry.name), .key = try a.print("{s}/{s}", .{ folder, entry.name }) });
    }
}

const PutBodyError = sm.AppendError || OpenRegularError || std.Io.File.StatError;
/// What `io_mod.openExistingReadOnlyRegularFile` can return.
const OpenRegularError = @typeInfo(@typeInfo(@TypeOf(io_mod.openExistingReadOnlyRegularFile)).@"fn".return_type.?).error_union.error_set;

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
            var file = try io_mod.openExistingReadOnlyRegularFile(body.dir, body.name, .no_follow);
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
    // Never waits on a FIFO or other special file put in its place.
    var file = io_mod.openExistingReadOnlyRegularFile(side.dir, name, .no_follow) catch |err| switch (err) {
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

    /// `user` with the blob path of each image an older session kept in its
    /// side folder (D47), as a v2 session's own prompt images have it
    /// (D89). Other images are unchanged; one whose blob is gone keeps its
    /// old path, as a lost snapshot does.
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
            // The image is its own blob now, which readers load and the
            // model's note names (D89).
            const blob_path = src.store.manager.blobPath(pa, src.id, &hash) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("session", "event=sessions_v2_moved_image_unreadable session={s} err={s}", .{ src.id, @errorName(err) });
                    continue;
                },
            };
            if (images == null) images = try pa.dupe(types.ImageAttachment, user.images);
            images.?[index].blob_path = blob_path;
        }
        const list = images orelse return user;
        return .{ .text = user.text, .images = list, .work_id = user.work_id };
    }

    /// A `user` item, each image saved as its own blob given only that
    /// blob's path, from which readers load its bytes when they need them
    /// (D89). A fork reads the blobs it hard-linked here too.
    fn decodeUser(src: Source, pa: Allocator, data: []const u8) !session_event.ConversationUser {
        const wire = try json_decode.parseFromSliceLeaky(WireUser, pa, data, .{ .allocate = .alloc_if_needed });
        const images = try wire.toImages(pa);
        for (wire.images, images) |image, *out| {
            const hash = image.blob orelse continue;
            out.blob_path = src.store.manager.blobPath(pa, src.id, hash) catch |err| return imageBlobFailed(src, image.id, err);
        }
        return .{ .text = wire.text, .images = images, .work_id = wire.work_id };
    }

    /// An image blob the log names that is gone or misnamed damages the
    /// session, as a piece's blob does (D39). One whose bytes were damaged is
    /// found by `verify`, and by any reader, which checks them against the
    /// image's digest (D89).
    fn imageBlobFailed(src: Source, image_id: usize, err: sm.BlobError) (sm.BlobError || error{InvalidSessionFormat}) {
        return switch (err) {
            error.NotFound, error.Corrupt, error.InvalidArgument => {
                debug_trace.logf("session", "event=sessions_v2_prompt_image_unreadable session={s} image={d} err={s}", .{ src.id, image_id, @errorName(err) });
                return error.InvalidSessionFormat;
            },
            else => |e| e,
        };
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
// Converting v1 sessions (D55 to D61, `tests/tla/session_manager/V1Conversion.tla`)

/// A conversion that runs past this tells the host why the open is slow.
const slow_conversion_ns: i128 = 150 * std.time.ns_per_ms;
const slow_conversion_text = "Converting this session from the previous session format…";

/// What v2 keeps of a converted member's v1 source (`set v1_source`): the
/// fingerprint its removal checks (D60), and what its copy left out (D56,
/// D62), the first `max_records` files by name and how many in all, which
/// its v1 folder keeps and no removal then takes. The fingerprint is empty
/// then, so an older fx, which removes a v1 folder whose fingerprint
/// matches, never takes that folder either.
const V1Source = struct {
    fingerprint: []const u8 = "",
    left_out: []const Record = &.{},
    left_out_total: usize = 0,

    const Record = struct { file: []const u8, cause: LeftOut.Cause, bytes: u64 = 0 };
    /// The most files a copy names, which keeps its line far below the
    /// log's limit; the v1 folder keeps every file.
    const max_records = 32;

    fn leftOutCount(source: V1Source) usize {
        return @max(source.left_out_total, source.left_out.len);
    }

    fn keeps(source: V1Source) bool {
        return source.leftOutCount() > 0;
    }
};

/// A file a conversion leaves out, which the member's v1 folder keeps: a
/// side file larger than one v2 blob (D62), hosted terminal state the copy
/// can't take (D56), or, in salvage, a side file a kept result names that
/// is not what it records (D74).
pub const LeftOut = struct {
    /// The family member that kept it in v1.
    member: []u8,
    /// Its path in that member's v1 folder.
    file: []u8,
    /// Its size, for `too_large`.
    bytes: u64,
    cause: Cause,

    pub const Cause = enum {
        /// A side file larger than one v2 blob (D62).
        too_large,
        /// Hosted terminal state that is not a folder or a regular file,
        /// such as a link or a FIFO (D56).
        not_regular,
        /// Hosted terminal state that does not open (D56).
        unreadable,
        /// Hosted terminal state nested deeper than the copy goes (D56).
        too_deep,
        /// A side file a kept result names that is missing or not what the
        /// result records, which salvage does not copy (D74).
        unavailable,
    };

    fn deinit(entry: LeftOut, alloc: Allocator) void {
        alloc.free(entry.member);
        alloc.free(entry.file);
    }

    /// What a host tells the user about it.
    fn note(entry: LeftOut, alloc: Allocator, root_id: []const u8) ![]u8 {
        const why = try entry.reason(alloc);
        defer alloc.free(why);
        if (std.mem.eql(u8, entry.member, root_id))
            return alloc.print("This session was converted without {s} because {s}. Its earlier folder ~/.fx/sessions/{s} keeps it.", .{ entry.file, why, entry.member });
        return alloc.print("This session was converted without {s} of its subagent {s} because {s}. Its earlier folder ~/.fx/sessions/{s} keeps it.", .{ entry.file, entry.member, why, entry.member });
    }

    /// Why the copy left it out, as a clause. Caller owns it.
    pub fn reason(entry: LeftOut, alloc: Allocator) ![]u8 {
        return switch (entry.cause) {
            .too_large => alloc.print("it is {d} bytes, more than the {d} the new store keeps in one file", .{ entry.bytes, sm.max_blob_bytes }),
            .not_regular => alloc.dupe(u8, "it is not a file or folder"),
            .unreadable => alloc.dupe(u8, "it can't be read"),
            .too_deep => alloc.dupe(u8, "it is nested deeper than the copy goes"),
            .unavailable => alloc.dupe(u8, "it is missing or not what its result records"),
        };
    }
};

/// One family's conversion, in the order `tests/tla/session_manager/V1Conversion.tla` checks:
/// lock every member or answer busy (CBegin); once locked, see whether
/// another process converted it meanwhile, then sweep what a crashed try
/// left (CSweep, D61); stage every member, any unreadable one refusing the
/// whole family with nothing half converted (CStage); publish the children
/// and then the root (CPublishChild, CPublishRoot); remove the v1 folder of
/// each member still the copy converted, under its lock (CDelete).
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
    /// Every file this conversion left out, of every member (D56, D62).
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
        /// Whether its v1 state goes once the root is published (TLA
        /// `Unchanged`): copied in this run, or reused while its v1 copy is
        /// the one converted.
        unchanged: bool = true,
        /// Whether its v1 folder keeps something its copy left out (TLA
        /// `keeps`), which then stays.
        keeps: bool = false,
    };

    /// A member the first pass checked (D62): a child an earlier try
    /// published, reused as it is, or one to stage, whose read only a family
    /// of one keeps, so that family is read once.
    const Checked = union(enum) {
        reused: Staged,
        read: ?v1_conversion.Member,
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
            for (checked.items) |*item| if (item.* == .read) if (item.read) |*member| member.deinit();
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
        removeMember(&v1, root_id, staged.items[staged.items.len - 1]);
        for (staged.items[0 .. staged.items.len - 1]) |member| removeMember(&v1, root_id, member);
        c.members = members.len;
        return .converted;
    }

    /// A salvage of a v1 root (D64; `tests/tla/session_manager/V1Conversion.tla`
    /// SBegin, SFinish): under the family's locks, v1's own recovery reads
    /// the start of the root it keeps, which is written under a fresh id as
    /// a root of its own and published. No v1 file is written.
    fn salvage(c: *Conversion, root_id: []const u8) !Recovered {
        const store = c.store;
        store.problem = .{};
        var v1 = try session_store.Store.initReadOnlyFromHome(c.alloc, store.home, "/");
        defer v1.deinit(c.alloc);
        if (try v1_conversion.kindOf(&v1, c.alloc, root_id) != .root) return error.SessionNotFound;
        var locks = try v1_conversion.lockFamily(c.alloc, &v1, root_id, 0, &store.problem);
        defer locks.release();
        const locked = &locks.members.items[0];
        // A session the converter reads whole needs no salvage, as v1's
        // recover finds once it has brought an older format up to date.
        if (v1_conversion.readMember(c.alloc, &v1, locked, &store.problem, .required)) |whole| {
            var read = whole;
            read.deinit();
            return error.SessionRecoveryNotNeeded;
        } else |err| if (err == error.OutOfMemory) return err;
        store.problem = .{};
        // A conversation that only its saved rules keep from converting is
        // copied whole without them (D72); anything else is salvaged as v1
        // salvaged it.
        var member = v1_conversion.readMember(c.alloc, &v1, locked, &store.problem, .drop_unreadable) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => salvaged: {
                store.problem = .{};
                break :salvaged try v1_conversion.readSalvage(c.alloc, &v1, locked, &store.problem);
            },
        };
        defer member.deinit();
        try c.findLeftOut(root_id, locked);
        try c.checkKeptFiles(root_id, locked, &member);
        var id: [sm.new_id_len]u8 = undefined;
        sm.newId(io_mod.getIo(), &id);
        const handle = store.manager.openImport(.{ .id = &id, .workspace = member.workspace, .host = c.host, .created_ms = member.created_ms }) catch |err|
            return conversionStorageFailed("salvage", err);
        const session = Session.init(c.alloc, store, handle, false) catch |err| {
            handle.release();
            c.discardStaging(&id);
            return err;
        };
        session.root = false;
        defer session.dropImport();
        errdefer c.discardStaging(&id);
        var arena = std.heap.ArenaAllocator.init(c.alloc);
        defer arena.deinit();
        var registry = try child_state.Registry.init(arena.allocator(), &id);
        try c.writeMember(session, &member, locked, .{ .root = .{ .registry = &registry, .has_log = &.{} } }, &.{}, 0);
        try session.handle.publishImport();
        debug_trace.logf("convert", "action=Salvaged session={s} copy={s} turns={d} rules_dropped={}", .{ root_id, &id, member.turns, member.rules_dropped });
        return .{
            .id = try c.alloc.dupe(u8, &id),
            .history_len = member.steps.len,
            .files_complete = c.left_out.items.len == 0,
            .permission_rules_dropped = member.rules_dropped,
        };
    }

    /// Copies `<v1>/terminal` to `~/.fx/terminal/{id}/terminal` (D45), over
    /// what a crashed try left there, whatever its folders' modes, as v1
    /// opened them (it made each private). An entry the copy can't take is
    /// left out, and the member's v1 folder keeps it (D56, D62). A copy, not
    /// a move: a conversion that stops leaves v1 whole.
    fn copyTerminalState(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked) !void {
        const io = io_mod.getIo();
        var source = (io_mod.openRealDirIfPresent(&locked.dir, terminal_dir_name) catch |err|
            return c.leaveOut(root_id, locked.id, terminal_dir_name, .unreadable, err)) orelse return;
        defer source.close();
        var root = try c.store.makeProfileFolder(terminal_dir_name);
        defer root.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(&root, locked.id);
        defer owner.close();
        try owner.dir.deleteTree(io, terminal_dir_name);
        var target = try io_mod.openOrCreateVerifiedPrivateDir(&owner, terminal_dir_name);
        defer target.close();
        try c.copyTerminalTree(root_id, locked.id, &source, &target, terminal_dir_name, 0);
    }

    /// Copies the folders and regular files below `source`, at `path` in
    /// the member's v1 folder. An entry that is neither, one that does not
    /// open, or one nested deeper than `max_copy_depth` is left out. A write
    /// that fails fails the copy.
    fn copyTerminalTree(
        c: *Conversion,
        root_id: []const u8,
        member_id: []const u8,
        source: *io_mod.VerifiedDir,
        target: *io_mod.VerifiedDir,
        path: []const u8,
        depth: usize,
    ) (ConversionStorageError || Allocator.Error)!void {
        const io = io_mod.getIo();
        var it = source.dir.iterate();
        while (it.next(io) catch |err| return c.leaveOut(root_id, member_id, path, .unreadable, err)) |entry| {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub = std.mem.print(&buffer, "{s}/{s}", .{ path, entry.name }) catch return conversionStorageFailed("terminal", error.NameTooLong);
            switch (entry.kind) {
                .directory => {
                    if (depth + 1 == max_copy_depth) {
                        try c.leaveOut(root_id, member_id, sub, .too_deep, null);
                        continue;
                    }
                    var from = (io_mod.openRealDirIfPresent(source, entry.name) catch |err| {
                        try c.leaveOut(root_id, member_id, sub, .unreadable, err);
                        continue;
                    }) orelse continue;
                    defer from.close();
                    var to = io_mod.openOrCreateVerifiedPrivateDir(target, entry.name) catch |err| return conversionStorageFailed("terminal", err);
                    defer to.close();
                    try c.copyTerminalTree(root_id, member_id, &from, &to, sub, depth + 1);
                },
                .file => {
                    var file = io_mod.openExistingReadOnlyRegularFile(source.dir, entry.name, .no_follow) catch |err| {
                        try c.leaveOut(root_id, member_id, sub, .unreadable, err);
                        continue;
                    };
                    defer file.close(io);
                    copyOpenedFile(&file, target.dir, entry.name) catch |err| return conversionStorageFailed("terminal", err);
                },
                else => try c.leaveOut(root_id, member_id, sub, .not_regular, null),
            }
        }
    }

    /// Records `file`, which it takes, in `member_id`'s v1 folder as left
    /// out of its copy. `file` is freed when that fails.
    fn addLeftOut(c: *Conversion, member_id: []const u8, file: []u8, bytes: u64, cause: LeftOut.Cause) Allocator.Error!void {
        errdefer c.alloc.free(file);
        try c.left_out.ensureUnusedCapacity(c.alloc, 1);
        const member = try c.alloc.dupe(u8, member_id);
        c.left_out.appendAssumeCapacity(.{ .member = member, .file = file, .bytes = bytes, .cause = cause });
    }

    /// `addLeftOut` for hosted terminal state, naming it in the trace.
    fn leaveOut(c: *Conversion, root_id: []const u8, member_id: []const u8, file: []const u8, cause: LeftOut.Cause, err: ?anyerror) Allocator.Error!void {
        try c.addLeftOut(member_id, try c.alloc.dupe(u8, file), 0, cause);
        debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} cause={s} err={s}", .{ root_id, member_id, file, @tagName(cause), if (err) |value| @errorName(value) else "none" });
    }

    fn traceHeld(root_id: []const u8) Outcome {
        debug_trace.logf("convert", "action=Held session={s}", .{root_id});
        return .held;
    }

    /// Removes a published member's v1 folder while it is the copy converted
    /// (CDelete), unless it keeps something its copy left out (D56, D62),
    /// which then stays only there.
    fn removeMember(v1: *session_store.Store, root_id: []const u8, member: Staged) void {
        if (!member.unchanged or member.keeps) {
            debug_trace.logf("convert", "action=KeptV1 session={s} member={s} reason={s}", .{ root_id, member.id, if (member.keeps) "left_out" else "changed" });
            return;
        }
        _ = v1_conversion.removeFolder(v1, member.id, "converted");
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
        var member = try c.load(v1, locked, root_id);
        errdefer member.deinit();
        try c.findLeftOut(root_id, locked);
        c.phase();
        if (keep) return .{ .read = member };
        member.deinit();
        return .{ .read = null };
    }

    fn load(c: *Conversion, v1: *session_store.Store, locked: *v1_conversion.Locked, root_id: []const u8) !v1_conversion.Member {
        return v1_conversion.readMember(c.alloc, v1, locked, &c.store.problem, .required) catch |err| {
            if (err == error.InvalidSessionFormat) c.traceUnreadable(root_id, locked.id);
            return err;
        };
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
                const file = try c.alloc.print("{s}/{s}", .{ folder, entry.name });
                try c.addLeftOut(locked.id, file, stat.size, .too_large);
                debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} bytes={d} limit={d}", .{ root_id, locked.id, file, stat.size, sm.max_blob_bytes });
            }
        }
    }

    /// Leaves out each side file a kept result names that is missing, not
    /// the size its record gives, or not the bytes the digest in its name
    /// gives, which v1's recover would not copy (D74). The copy's result
    /// then says its content is unavailable, and the recovery says so.
    fn checkKeptFiles(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked, member: *const v1_conversion.Member) !void {
        for (member.steps) |step| switch (step) {
            .framed => |framed| for (framed.events) |event| switch (event) {
                .tool_result => |result| {
                    try c.checkKeptFile(root_id, locked, "tool-results", result.artifact_ref, ".txt", result.stored_bytes);
                    if (result.command_replay_ref) |ref| try c.checkKeptFile(root_id, locked, "logs/commands", ref, ".bin", result.command_replay_bytes);
                },
                else => {},
            },
            .whole => |whole| {
                const execution = switch (whole.turn) {
                    .assistant => |entry| entry.execution,
                    .interrupted => |entry| entry.execution,
                    .compacted_summary => continue,
                };
                for (execution.tool_steps) |tool_step| for (tool_step.tool_results) |result| {
                    const handle = result.output_handle orelse continue;
                    // An older format's inline result, which the conversion
                    // writes itself.
                    if (storedInline(member.stored, handle)) continue;
                    try c.checkKeptFile(root_id, locked, "tool-results", handle, ".txt", result.stored_output_bytes);
                };
            },
            .compacted => {},
        };
    }

    fn checkKeptFile(c: *Conversion, root_id: []const u8, locked: *v1_conversion.Locked, folder: []const u8, name: []const u8, suffix: []const u8, expected_bytes: ?u64) !void {
        if (name.len == 0) return;
        for (c.left_out.items) |entry| {
            if (std.mem.eql(u8, entry.member, locked.id) and entry.file.len == folder.len + 1 + name.len and
                std.mem.startsWith(u8, entry.file, folder) and std.mem.endsWith(u8, entry.file, name)) return;
        }
        const io = io_mod.getIo();
        const why: []const u8 = why: {
            var dir = locked.dir.dir.openDir(io, folder, .{ .follow_symlinks = false }) catch break :why "missing";
            defer dir.close(io);
            var file = io_mod.openExistingReadOnlyRegularFile(dir, name, .no_follow) catch break :why "missing";
            defer file.close(io);
            const stat = file.stat(io) catch break :why "unreadable";
            if (expected_bytes) |bytes| if (stat.size != bytes) break :why "not the size its result records";
            if (!artifact_digest.hasContentDigest(name, suffix)) return;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [16 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stat.size) {
                const count: usize = @intCast(@min(buffer.len, stat.size - offset));
                const read = file.readPositionalAll(io, buffer[0..count], offset) catch break :why "unreadable";
                if (read != count) break :why "unreadable";
                hash.update(buffer[0..count]);
                offset += count;
            }
            if (artifact_digest.handleMatchesContentDigest(name, suffix, hash.finalResult())) return;
            break :why "not the bytes its name records";
        };
        const file = try c.alloc.print("{s}/{s}", .{ folder, name });
        try c.addLeftOut(locked.id, file, 0, .unavailable);
        debug_trace.logf("convert", "action=LeftOut session={s} member={s} file={s} reason=\"{s}\"", .{ root_id, locked.id, file, why });
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
        const member = &kept.*.?;
        defer {
            member.deinit();
            kept.* = null;
        }
        const handle = store.manager.openImport(.{
            .id = locked.id,
            .workspace = member.workspace,
            .host = c.host,
            .role = if (role == .root) .root else .child,
            .parent = if (role == .child) role.child.parent else null,
            .created_ms = member.created_ms,
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
        try c.copyTerminalState(rootOf(role, locked.id), locked);
        var records: std.ArrayList(V1Source.Record) = .empty;
        defer records.deinit(c.alloc);
        var total: usize = 0;
        for (c.left_out.items) |entry| {
            if (!std.mem.eql(u8, entry.member, locked.id)) continue;
            total += 1;
            if (records.items.len < V1Source.max_records) try records.append(c.alloc, .{ .file = entry.file, .cause = entry.cause, .bytes = entry.bytes });
        }
        if (total > records.items.len) debug_trace.logf("convert", "action=LeftOutUnnamed member={s} named={d} total={d}", .{ locked.id, records.items.len, total });
        try c.writeMember(session, member, locked, role, records.items, total);
        return .{ .id = locked.id, .session = session, .keeps = total > 0 };
    }

    /// A child an earlier try published before it stopped (TLA `Orphan`):
    /// reused as it is, unread, since the sweep cannot take it back without
    /// a tombstone (`tests/tla/session_manager/Catalog.tla` NoResurrection) and its v1 copy may
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
        const named: []const V1Source.Record = if (source) |known| known.left_out else &.{};
        const total = if (source) |known| known.leftOutCount() else 0;
        // What the earlier try left out, told now as this run tells its own.
        for (named) |record| try c.addLeftOut(locked.id, try c.alloc.dupe(u8, record.file), record.bytes, record.cause);
        debug_trace.logf("convert", "action=Reused member={s} v1={s} left_out={d} named={d}", .{ locked.id, if (unchanged) "unchanged" else "kept", total, named.len });
        return .{
            .id = locked.id,
            .session = null,
            .unchanged = unchanged,
            .keeps = total > 0,
        };
    }

    /// Writes `member` into `session`, each batch at its original time
    /// (D59): its turns and compactions, then its settings at the time v1
    /// lists it, among them what its copy left out: `left_out_total` files,
    /// the first of them named in `records`.
    fn writeMember(c: *Conversion, session: *Session, member: *const v1_conversion.Member, locked: *v1_conversion.Locked, role: Role, records: []const V1Source.Record, left_out_total: usize) !void {
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
                        .keep_tool_steps = compacted.keep_tool_steps,
                        .keep_steering = compacted.keep_steering,
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
        var left_out: std.ArrayList([]const u8) = .empty;
        for (c.left_out.items) |entry| if (std.mem.eql(u8, entry.member, locked.id)) try left_out.append(a, entry.file);
        const side = try sideFileLines(a, session.handle, &locked.dir, &body_folders, member.stored, left_out.items);
        try settings.appendSlice(a, side.events);
        const source: V1Source = .{ .fingerprint = if (left_out_total > 0) "" else &member.fingerprint, .left_out = records, .left_out_total = left_out_total };
        try settings.append(a, .{ .set = .{ .key = .v1_source, .value = try jsonValue(a, source) } });
        if (role == .root) {
            for (try child_state.v1ImportLines(a, role.root.registry.*, role.root.has_log)) |line| try settings.append(a, switch (line) {
                .spawned => |spawned| .{ .child_spawned = .{ .child = spawned.child, .work_id = spawned.work_id, .data = spawned.data } },
                .finished => |finished| .{ .child_finished = .{ .child = finished.child, .work_id = finished.work_id, .outcome = finished.outcome, .data = finished.data } },
            });
        }
        session.import_ts = @max(newest, member.listed_ms);
        _ = try session.write(settings.items);
        c.turns += member.turns;
        c.files += side.bodies;
    }

    /// Tells the host about each file the conversion left out (D56, D62),
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
    const source = json_decode.parseFromSliceLeaky(V1Source, a, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (!source.keeps() and source.fingerprint.len != 64) return null;
    return source;
}

/// Removes what a conversion left in v1 for the converted session
/// `root_id` and its children: each member's v1 state, while its v1 copy is
/// what was converted (TLA CClean, D60). A member whose copy left something
/// out (D56, D62), one another process holds, or one that changed keeps
/// it; nothing here fails the open.
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
        if (source.keeps()) {
            debug_trace.logf("convert", "action=Kept session={s} reason=left_out", .{id});
            continue;
        }
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
        if (v1_conversion.removeFolder(&v1, id, "leftover")) debug_trace.logf("convert", "action=Cleaned session={s}", .{id});
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
/// What a latest lookup that finds nothing says: that there are no saved
/// sessions, or that only ones it can't read are left, as v1 said (D76).
pub fn noLatestError(store: *Store, alloc: Allocator) error{ OutOfMemory, NoSavedSessions, NoReadableSessions } {
    const unreadable = v1_conversion.hasUnreadable(alloc, store.home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    return if (unreadable) error.NoReadableSessions else error.NoSavedSessions;
}

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
    /// Each file a converted family was converted without, which its v1
    /// folder keeps (D56, D62).
    left_out: std.ArrayList(LeftOutFile) = .empty,
    /// Each v1 subagent no conversion takes, kept as it is (D88).
    kept_children: []KeptChild = &.{},

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
        freeKeptChildren(alloc, report.kept_children);
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
                try report.skip(alloc, id, "InvalidSessionFormat", std.mem.print(&reason, "the new store can't read its copy ({s})", .{@errorName(err)}) catch null);
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
                try report.skip(alloc, id, "InvalidSessionFormat", std.mem.print(&reason, "the conversion failed ({s})", .{@errorName(err)}) catch null);
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
                    @memmove(conversion.left_out.items[0..rest.len], rest);
                    conversion.left_out.shrinkRetainingCapacity(rest.len);
                    return err;
                };
                report.left_out.appendAssumeCapacity(.{ .id = owned_root, .file = file });
            }
            conversion.left_out.clearRetainingCapacity();
        }
    }
    // After every family converted, so a child its root left behind is named.
    report.kept_children = try keptChildren(store, alloc);
    return report;
}

/// A session an older fx saved as a subagent that no conversion takes, and
/// why no fx opens it (D88). Its v1 folder is kept as it is.
pub const KeptChild = struct {
    id: []u8,
    reason: []u8,
    /// Whether its converted copy left something out that its folder
    /// keeps (D62).
    keeps: bool = false,
};

pub fn freeKeptChildren(alloc: Allocator, kept: []KeptChild) void {
    for (kept) |child| {
        alloc.free(child.id);
        alloc.free(child.reason);
    }
    alloc.free(kept);
}

/// Each v1 child whose parent is not a v1 root, with why no fx opens it
/// (D88): one v2 already holds, whose folder a cleanup kept (D60), a child
/// of an earlier subagent, which v1 never let a subagent message, or one
/// whose parent is gone or does not list it. Reads only. Caller owns the
/// result; free it with `freeKeptChildren`.
fn keptChildren(store: *Store, alloc: Allocator) ![]KeptChild {
    const strays = v1_conversion.strayChildren(alloc, store.home) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("convert", "action=ChildrenUnlisted err={s}", .{@errorName(err)});
            return &.{};
        },
    };
    defer {
        for (strays) |stray| stray.deinit(alloc);
        alloc.free(strays);
    }
    var kept: std.ArrayList(KeptChild) = .empty;
    errdefer {
        for (kept.items) |child| {
            alloc.free(child.id);
            alloc.free(child.reason);
        }
        kept.deinit(alloc);
    }
    try kept.ensureTotalCapacity(alloc, strays.len);
    for (strays) |stray| {
        const verdict = try strayReason(store, alloc, stray);
        errdefer alloc.free(verdict.reason);
        debug_trace.logf("convert", "action=KeptChild session={s} reason=\"{s}\"", .{ stray.id, verdict.reason });
        kept.appendAssumeCapacity(.{ .id = try alloc.dupe(u8, stray.id), .reason = verdict.reason, .keeps = verdict.keeps });
    }
    return kept.toOwnedSlice(alloc);
}

const StrayVerdict = struct { reason: []u8, keeps: bool = false };

/// Why no fx opens `stray`, for `keptChildren`, and whether its folder
/// keeps something its converted copy left out. Caller owns the reason.
fn strayReason(store: *Store, alloc: Allocator, stray: v1_conversion.Stray) !StrayVerdict {
    if (store.manager.peek(alloc, stray.id)) |peeked_value| {
        var peeked = peeked_value;
        defer peeked.deinit(alloc);
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const source = parseV1Source(scratch.allocator(), peeked.state.v1_source);
        return .{ .reason = try convertedReason(alloc, source), .keeps = if (source) |known| known.keeps() else false };
    } else |err| switch (err) {
        error.NotFound, error.InvalidArgument => {},
        error.OutOfMemory => return err,
        else => return .{ .reason = try alloc.print("fx can't read its converted copy ({s}), so this folder stays as it is", .{@errorName(err)}) },
    }
    const parent = stray.parent orelse return .{ .reason = try alloc.dupe(u8, "it names no parent session, so no fx opens it") };
    return .{ .reason = try switch (stray.parent_kind) {
        .child => alloc.print("it is a subagent of the earlier subagent {s}, which no fx opens", .{parent}),
        .unreadable => alloc.print("its parent session {s} can't be read, so it stays with it", .{parent}),
        .absent => if (store.manager.peek(alloc, parent)) |peeked_value| blk: {
            var peeked = peeked_value;
            defer peeked.deinit(alloc);
            break :blk switch (peeked.role) {
                .child => alloc.print("it is a subagent of the earlier subagent {s}, which no fx opens", .{parent}),
                .root => alloc.print("its parent {s} does not list it, so no fx opens it", .{parent}),
            };
        } else |_| alloc.print("its parent session {s} is gone, so no fx opens it", .{parent}),
    } };
}

/// Why a converted subagent's v1 folder stays, from its copy's `source`
/// (D62). Caller owns it.
fn convertedReason(alloc: Allocator, source: ?V1Source) ![]u8 {
    const known = source orelse V1Source{};
    const count = known.leftOutCount();
    if (count == 1 and known.left_out.len == 1) return alloc.print("fx converted it already without {s}, so this folder keeps it", .{known.left_out[0].file});
    if (count > 0) return alloc.print("fx converted it already without {d} of its files, so this folder keeps them", .{count});
    return alloc.dupe(u8, "fx converted it already, so anything an older fx added since stays only in this folder");
}

const ConversionStorageError = error{ NoSpaceLeft, AccessDenied, ReadOnlyFileSystem, FileTooBig, SessionStoreUnavailable };

/// A v2 store step of a conversion that failed: its storage cause when it
/// has one (D29), else `SessionStoreUnavailable`.
fn conversionStorageFailed(comptime step: []const u8, err: anyerror) ConversionStorageError {
    debug_trace.logf("convert", "action=StoreFailed step=" ++ step ++ " err={s}", .{@errorName(err)});
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.FileTooBig => error.FileTooBig,
        else => error.SessionStoreUnavailable,
    };
}

fn copyFailed(id: []const u8, err: anyerror) bool {
    debug_trace.logf("session", "event=sessions_v2_files_copy_incomplete session={s} err={s}", .{ id, @errorName(err) });
    return false;
}

/// Side folders are a few levels deep (a kind, then files); deeper trees
/// are not fx's and are left out.
const max_copy_depth = 8;

/// `openSource` opens each folder below `source`, never through a symlink.
fn copyTree(comptime openSource: anytype, source: *io_mod.VerifiedDir, target: *io_mod.VerifiedDir, depth: usize) bool {
    const io = io_mod.getIo();
    var complete = true;
    var it = source.dir.iterate();
    while (it.next(io) catch |err| return copyFailed("tree", err)) |entry| switch (entry.kind) {
        .directory => {
            if (depth + 1 == max_copy_depth) {
                complete = copyFailed(entry.name, error.TooDeep);
                continue;
            }
            var from = (openSource(source, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            }) orelse continue;
            defer from.close();
            var to = io_mod.openOrCreateVerifiedPrivateDir(target, entry.name) catch |err| {
                complete = copyFailed(entry.name, err);
                continue;
            };
            defer to.close();
            if (!copyTree(openSource, &from, &to, depth + 1)) complete = false;
        },
        .file => copyFile(source.dir, target.dir, entry.name) catch |err| {
            complete = copyFailed(entry.name, err);
        },
        else => complete = copyFailed(entry.name, error.NotAFile),
    };
    return complete;
}

fn copyFile(from: std.Io.Dir, to: std.Io.Dir, name: []const u8) !void {
    var source = try io_mod.openExistingReadOnlyRegularFile(from, name, .no_follow);
    defer source.close(io_mod.getIo());
    try copyOpenedFile(&source, to, name);
}

fn copyOpenedFile(source: *std.Io.File, to: std.Io.Dir, name: []const u8) !void {
    const io = io_mod.getIo();
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

/// Where `restoreFrom` puts the number of the turn behind each history entry,
/// and what the history leaves out of its first kept turn.
const TurnNumbers = struct {
    alloc: Allocator,
    list: *std.ArrayList(?u64),
    trim: *Trim,
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
    var covered: types.ContextHistoryCut = .{};
    if (state.compaction_offset) |offset| {
        const cursor: sm.Cursor = .{ .offset = offset, .seq = state.last_compaction_seq.? };
        var page = try src.read(sa, .{ .at = cursor }, 1);
        defer page.deinit();
        const data = compactedData(&page) orelse {
            debug_trace.logf("session", "event=sessions_v2_compaction_unreadable session={s} offset={d}", .{ src.id, offset });
            return error.InvalidSessionFormat;
        };
        const compacted = try json_decode.parseFromSliceLeaky(CompactedData, sa, data, .{});
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
        covered = .{ .tool_steps = compacted.keep_tool_steps, .steering = compacted.keep_steering };
    }
    var sink: RestoreSink = .{ .alloc = alloc, .history = &history, .numbers = numbers };
    try replay(src, alloc, sa, from, skip_offset, ReplaySink.init(&sink));
    if (numbers) |n| n.trim.* = .{};
    if (covered.tool_steps != 0 or covered.steering != 0) {
        if (try trimFirstKept(alloc, sa, &history, covered, src.id)) {
            if (numbers) |n| n.trim.* = .{ .turn = n.list.items[1], .tool_steps = covered.tool_steps, .steering = covered.steering };
        }
    }
    restored.history = try history.toOwnedSlice(alloc);
    return restored;
}

/// Leaves out of the first kept turn the steps and steering messages a
/// compaction inside it summarized, as fx's history leaves them out when it
/// compacts (D87). A turn that does not have them stays whole, with a trace
/// line, so a resume is never refused for it. Returns whether it trimmed.
fn trimFirstKept(alloc: Allocator, sa: Allocator, history: *std.ArrayList(types.HistoryTurn), covered: types.ContextHistoryCut, id: []const u8) !bool {
    if (history.items.len < 2) return false;
    const kept = history_range.contextHistoryRange(sa, history.items[1..2], covered, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_compaction_cut_kept_whole session={s} tool_steps={d} steering={d} reason={s}", .{ id, covered.tool_steps, covered.steering, @errorName(err) });
            return false;
        },
    };
    const owned = try types.dupeHistoryTurn(alloc, kept[0]);
    types.freeHistoryTurn(alloc, history.items[1]);
    history.items[1] = owned;
    return true;
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
    if (state.title) |raw| restored.title = try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, sa, raw, .{}));
    if (state.prefs) |raw| restored.preferences = try decodePreferences(alloc, raw);
    if (state.permissions) |raw| restored.permission_state = try session_codec.decodePermissionState(alloc, raw);
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
        const parsed = try json_decode.parseFromSlice(CompactedData, sink.alloc, data, .{});
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
        },
        .title = restored.title,
    };
    restored.history = &.{};
    restored.permission_state = null;
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
                    // The recovery module's record, which only a launch reads.
                    if (std.mem.eql(u8, piece.type, recovery_type)) continue;
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
                    if (std.mem.eql(u8, piece.type, file_review_type)) {
                        try attachFileReview(src, pa, &builder, piece);
                        continue;
                    }
                    if (std.mem.eql(u8, piece.type, author_type)) {
                        try builder.setUserAuthor(decodeAuthor(pa, try src.pieceData(pa, piece)));
                        continue;
                    }
                    const kind = pieceKind(piece.type) orelse {
                        debug_trace.logf("session", "event=sessions_v2_unknown_item session={s} type={s} dropped=item", .{ src.id, piece.type });
                        continue;
                    };
                    const data = try src.pieceData(pa, piece);
                    // The builder copies what it keeps, as it does for v1's
                    // reader, so strings may point into the page.
                    if (kind == .user) {
                        try builder.begin(try src.withMovedImages(pa, try src.decodeUser(pa, data)));
                        continue;
                    }
                    switch (try decodePiece(pa, kind, data, .alloc_if_needed)) {
                        // Read above, with its images' blobs.
                        .user => unreachable,
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
                        .context_note => |value| try builder.appendContextNote(value.text, value.sources),
                        .runtime_context => |value| try builder.setRuntimeContext(value.messages),
                        .turn_completed => |value| try sink.turn(try presentStoredResults(src, alloc, try builder.finishAssistant(value)), lastStarted(entry)),
                        .interrupted => |value| {
                            interrupted_item = true;
                            try sink.turn(try presentStoredResults(src, alloc, try builder.finishInterrupted(value)), lastStarted(entry));
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
                    turn.interrupted.stopped_by_exit = switch (ended.reason) {
                        .crash, .closed => true,
                        .cancel, .failed => false,
                    };
                    const answered = answerRunning(alloc, &turn.interrupted, running.items, represented.items, running_text) catch |err| {
                        types.freeHistoryTurn(alloc, turn);
                        return err;
                    };
                    if (answered > 0) debug_trace.logf("session", "event=sessions_v2_replay_unfinished_tools session={s} turn={d} calls={d}", .{ src.id, ended.turn, answered });
                    try sink.turn(try presentStoredResults(src, alloc, turn), ended.turn);
                },
                .compacted => |line| try sink.summary(line.data),
                .session_created, .turn_committed, .set, .child_spawned, .child_finished, .snapshot, .closed => {},
            }
        }
        from = .{ .at = page.next orelse break };
    }
    if (!builder.isIdle()) debug_trace.logf("session", "event=sessions_v2_replay_open_turn session={s} dropped=unfinished_pieces", .{src.id});
}

/// `turn` with each stored result shown as v1 showed it: one the model saw
/// cut keeps its preview, wrapped with its handle and stored size so the
/// model knows where the rest is; one it saw whole gets its whole body back
/// from its blob, or a note that the body is unavailable. A converted
/// session's result under its old name is left as saved when no open
/// session can name its blob. Takes `turn`, freeing it on failure.
fn presentStoredResults(src: Source, alloc: Allocator, turn: types.HistoryTurn) !types.HistoryTurn {
    var shown = turn;
    errdefer types.freeHistoryTurn(alloc, shown);
    const execution = switch (shown) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => return shown,
    };
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        const handle = result.output_handle orelse continue;
        if (!result.truncated and result.output.len == result.stored_output_bytes) continue;
        const body = if (result.truncated)
            try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes)
        else
            (storedBody(src, alloc, handle, result.stored_output_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    debug_trace.logf("session", "event=context_result_unavailable session={s} handle={s} err={s}; marking content unavailable", .{ src.id, handle, @errorName(err) });
                    result.truncated = true;
                    break :blk try alloc.dupe(u8, "Saved tool-result content is unavailable. The complete output could not be restored.");
                },
            }) orelse continue;
        alloc.free(result.output);
        result.output = body;
    };
    return shown;
}

/// A stored result's whole body, from the blob its handle names, or the
/// blob a converted session's map names for its old handle (D47). Null for
/// an old handle when no open session holds that map.
fn storedBody(src: Source, alloc: Allocator, handle: []const u8, len: usize) !?[]u8 {
    const hash: [artifact_digest.blob_hex_bytes]u8 = if (artifact_digest.blobHash(handle)) |named|
        named[0..artifact_digest.blob_hex_bytes].*
    else if (src.host) |host|
        try BlobHost.resolve(host, .tool_results, handle)
    else
        return null;
    const bytes = try src.store.manager.getBlob(alloc, src.id, &hash);
    if (bytes.len != len) {
        alloc.free(bytes);
        return error.StoredSizeMismatch;
    }
    return bytes;
}

/// Which of the two calls of `Session.streamedPrefix` a decision came from.
const StreamPhase = enum { stream, commit };

fn countResults(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event| count += @intFromBool(event == .tool_result);
    return count;
}

/// How many of the open turn's pieces `samePiece` had to parse because the
/// rebuild changed their bytes, or null when one of them no longer stands.
/// A rebuild keeps each tool result's stamp, so this is 0 unless some path
/// lost it (`tests/tla/session/TurnStream.tla` NoReparseOfStamped).
fn reparsedPrefix(alloc: Allocator, streamed: []const []const u8, encoded: []const []const u8) ?usize {
    if (streamed.len > encoded.len) return null;
    var reparsed: usize = 0;
    for (streamed, encoded[0..streamed.len]) |held, bytes| {
        if (std.mem.eql(u8, held, bytes)) continue;
        if (!samePiece(alloc, held, bytes)) return null;
        reparsed += 1;
    }
    return reparsed;
}

/// Whether a streamed piece is the final one. A rebuild keeps each tool
/// result's `created_at_ms`, so the bytes match; a result whose message
/// carries no stamp is stamped again when rebuilt, so that field alone may
/// differ, and the streamed, earlier stamp stands.
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
    // Newest first across both, as `listPage` orders them (D61).
    session_summary_codec.sortSummariesNewestFirst(list.items);
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
        try alloc.dupe(u8, try json_decode.parseFromSliceLeaky([]const u8, scratch, raw, .{}))
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

/// v1's error names for a failed resume, so every host reports the same
/// error whichever backend is on.
/// Whether a failed write may still have reached the log: after any I/O
/// fault, whatever its cause, durability is unknown (D29).
pub fn writeMayHaveLanded(err: anyerror) bool {
    inline for (comptime @typeInfo(sm.IoFault).error_set.error_names.?) |fault_name| {
        if (err == @field(sm.IoFault, fault_name)) return true;
    }
    return false;
}

const ResumeError = error{ SessionNotFound, NoSavedSessions, NoRememberedSession, SessionBusy, InvalidSessionFormat, UnsupportedSessionFormat, OneOffSessionNotResumable } || sm.OpenError;

fn resumeError(err: sm.OpenError, target: Target) ResumeError {
    return switch (err) {
        error.NotFound => switch (target) {
            .id => error.SessionNotFound,
            .last => error.NoSavedSessions,
            .last_opened => error.NoRememberedSession,
        },
        // A child is resumed only through its parent, and fx says so, as v1
        // did (D71).
        error.ChildSession => error.OneOffSessionNotResumable,
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
/// The item after a turn's user piece when someone other than the user
/// wrote that message, such as a subagent's report that woke its parent.
/// Older fx drops it as an unknown item and reads the turn as before.
const author_type = "author";

/// The `author` item's data: `{"by":"child"}`.
fn encodeAuthor(a: Allocator, author: types.MessageAuthor) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .by = author }, .{}, &out.writer);
    return out.written();
}

/// Who an `author` item names. Anything other than a readable `user` is
/// read as a subagent's, so no item a reader cannot read ever counts as the
/// user's words.
fn decodeAuthor(a: Allocator, data: []const u8) types.MessageAuthor {
    const Wire = struct { by: []const u8 };
    const wire = std.json.parseFromSliceLeaky(Wire, a, data, .{ .ignore_unknown_fields = true }) catch return .child;
    if (std.mem.eql(u8, wire.by, "user")) return .user;
    if (std.mem.eql(u8, wire.by, "parent")) return .parent;
    return .child;
}

/// Who wrote the message that opened `turn`.
fn openingAuthor(turn: types.HistoryTurn) types.MessageAuthor {
    return switch (turn) {
        .assistant => |entry| entry.user.author,
        .interrupted => |entry| entry.user.author,
        .compacted_summary => .user,
    };
}

const running_type = "tool_running";
/// The text of the message whose calls are running (D51).
const running_assistant_type = "assistant_running";
/// The recovery module's record for the turn's model request in flight,
/// `{"record":"<64 hex digits>"}`, or `{"record":null}` once the request's
/// response is complete. A launch that finds a turn a crash ended reads
/// the newest one (`interruptedRequest`). Older builds drop the piece as an
/// unknown item.
const recovery_type = "recovery";
/// The bytes of a `recovery` piece's record; null for a cleared one or one
/// that does not parse, which the recovery module treats as no record.
fn parseRecoveryRecord(data: []const u8) ?[32]u8 {
    const prefix = "{\"record\":\"";
    if (!std.mem.startsWith(u8, data, prefix)) return null;
    const rest = data[prefix.len..];
    if (rest.len != 64 + 2 or !std.mem.eql(u8, rest[64..], "\"}")) return null;
    var record: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&record, rest[0..64]) catch return null;
    return record;
}

/// An edit's full-diff rows, saved right after its `tool_result` item rather
/// than inside it. Older fx versions reject unknown fields in a piece but
/// skip unknown item types, so they still read the result and show the
/// edit's preview; its data is a `FileReview`.
const file_review_type = "file_review";

const FileReview = struct {
    call_id: []const u8,
    lifecycle_id: types.ToolLifecycleId,
    rows: []const types.CommittedFilePresentationLine,
};

/// `result` without its edit's rows and their lifecycle id, which
/// `encodeFileReview` saves beside it, so the piece has the shape older fx
/// versions read. Checks the whole result first.
fn withoutReviewLines(result: session_event.ConversationToolResult) !session_event.ConversationToolResult {
    var presentation = result.committed_file_presentation orelse return result;
    if (presentation.review_lines == null) return result;
    try session_event.validateConversationEventShape(.{ .tool_result = result }, session_event.conversation_schema_version);
    presentation.review_lines = null;
    presentation.lifecycle_id = null;
    var stripped = result;
    stripped.committed_file_presentation = presentation;
    return stripped;
}

/// The `file_review` item data for `event`'s edit rows, or null when it has
/// none. The data is owned by `a`.
fn encodeFileReview(a: Allocator, event: Event) !?[]u8 {
    const result = switch (event) {
        .tool_result => |value| value,
        else => return null,
    };
    const presentation = result.committed_file_presentation orelse return null;
    const rows = presentation.review_lines orelse return null;
    const lifecycle_id = presentation.lifecycle_id orelse return error.InvalidConversationFrame;
    try session_event.validateCommittedFileReview(result.call_id, lifecycle_id, rows);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(FileReview{ .call_id = result.call_id, .lifecycle_id = lifecycle_id, .rows = rows }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Gives a replayed edit the rows its `file_review` item holds. A review
/// that cannot be read, or matches no edit of the turn, is dropped and the
/// edit keeps its preview.
fn attachFileReview(src: Source, a: Allocator, builder: *session_log.ConversationTurnBuilder, piece: sm.Body.Piece) !void {
    const data = src.pieceData(a, piece) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_file_review_unreadable session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
            return;
        },
    };
    const review = json_decode.parseFromSliceLeaky(FileReview, a, data, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=sessions_v2_file_review_invalid session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
            return;
        },
    };
    session_event.validateCommittedFileReview(review.call_id, review.lifecycle_id, review.rows) catch |err| {
        debug_trace.logf("session", "event=sessions_v2_file_review_invalid session={s} err={s} dropped=file_review", .{ src.id, @errorName(err) });
        return;
    };
    if (!try builder.attachReviewLines(review.call_id, review.lifecycle_id, review.rows)) {
        debug_trace.logf("session", "event=sessions_v2_file_review_unmatched session={s} call_id={s} dropped=file_review", .{ src.id, review.call_id });
    }
}
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
    /// The steps and steering messages of the first kept turn that the
    /// summary covers, which fx's history leaves out of that turn, as it
    /// does when it compacts inside a turn (D87). Older lines have neither,
    /// and keep the turn whole.
    keep_tool_steps: usize = 0,
    keep_steering: usize = 0,
};

/// What fx's history leaves out of its first kept turn (D87): none, or the
/// steps and steering messages of `turn` a compaction covers.
const Trim = struct {
    turn: ?u64 = null,
    tool_steps: usize = 0,
    steering: usize = 0,
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
        // An older fx leaves out an item type it does not know (D17, D93, D94).
        .context_note => "context_note",
        .runtime_context => "runtime_context",
    };
}

fn pieceKind(item_type: []const u8) ?PieceKind {
    inline for (@typeInfo(PieceKind).@"enum".field_values) |field_value| {
        const kind: PieceKind = @fromBackingInt(@intCast(field_value));
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
        .user => .{ .user = try (try json_decode.parseFromSliceLeaky(WireUser, arena, data, .{ .allocate = allocate })).toUser(arena) },
        inline else => |tag| @unionInit(Event, @tagName(tag), try json_decode.parseFromSliceLeaky(
            @FieldType(Event, @tagName(tag)),
            arena,
            data,
            .{ .allocate = allocate },
        )),
    };
    try session_event.validateConversationEventShape(event, session_event.conversation_schema_version);
    return event;
}

test "v2 conversation pieces stay bounded under fuzzed bytes" {
    try std.testing.fuzz({}, fuzzConversationPiece, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "{}",
            "{\"text\":\"ok\"}",
            // A context note (D93) and a saved runtime context (D94), as v2 writes them.
            "{\"text\":\"<scoped-rules from=\\\"sub/AGENTS.md\\\" scope=\\\"sub\\\">\\nR\\n</scoped-rules>\",\"sources\":[{\"path\":\"/w/sub/AGENTS.md\",\"stamp\":7}]}",
            "{\"text\":\"n\",\"sources\":[{\"path\":\"\",\"stamp\":0}]}",
            "{\"messages\":[\"<fx-turn-context>\\ngit_branch: main\\n</fx-turn-context>\",\"Runtime context: permission mode is auto.\"]}",
            "{\"messages\":[]}",
        }) ++ @import("fuzz_corpus").session_conversation_piece.*),
    });
}

/// Reads the bytes as a piece of every kind, as replay does for a v2 item.
fn fuzzConversationPiece(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    inline for (@typeInfo(PieceKind).@"enum".field_names) |name| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        _ = decodePiece(arena_state.allocator(), @field(PieceKind, name), buffer[0..len], .alloc_always) catch {};
    }
}

/// A user piece as v2 writes it: `session_event.ConversationUser` field for
/// field, so a prompt without inline images encodes as v1's does. An
/// image's inline bytes, which a v2 session keeps inside the turn (D44),
/// are base64 text, since a JSON string cannot hold raw bytes.
const WireUser = struct {
    text: []const u8,
    images: []const WireImage = &.{},
    work_id: ?[]const u8 = null,

    /// `types.ImageAttachment` field for field, with `inline_data` in base64,
    /// or the image's own blob (D89): `blob` names it by its digest, and the
    /// bytes, the digest, and the snapshot are not written again.
    const WireImage = struct {
        id: usize = 0,
        path: []const u8,
        media_type: []const u8,
        snapshot_path: ?[]const u8 = null,
        snapshot_sha256: ?[]const u8 = null,
        inline_data: ?[]const u8 = null,
        source_ref: ?[]const u8 = null,
        blob: ?[]const u8 = null,

        pub fn jsonStringify(self: WireImage, writer: *std.json.Stringify) !void {
            try writer.beginObject();
            inline for (@typeInfo(WireImage).@"struct".field_names) |field_name| {
                // Written only when set, so an image without them encodes
                // as it did before they existed.
                const optional = comptime std.mem.eql(u8, field_name, "source_ref") or std.mem.eql(u8, field_name, "blob");
                // An image in its blob has no bytes, digest or snapshot here.
                const in_blob = comptime std.mem.eql(u8, field_name, "snapshot_path") or
                    std.mem.eql(u8, field_name, "snapshot_sha256") or
                    std.mem.eql(u8, field_name, "inline_data");
                const write = if (optional) @field(self, field_name) != null else !(in_blob and self.blob != null);
                if (write) {
                    try writer.objectField(field_name);
                    try writer.write(@field(self, field_name));
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
            if (image.blob_path != null) {
                wire.* = .{
                    .id = image.id,
                    .path = image.path,
                    .media_type = image.media_type,
                    .source_ref = image.source_ref,
                    .blob = image.snapshot_sha256 orelse return error.InvalidSessionFormat,
                };
                continue;
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
        return .{ .text = wire.text, .images = try wire.toImages(a), .work_id = wire.work_id };
    }

    /// The images, without the bytes of those in blobs: `Source.decodeUser`
    /// reads those.
    fn toImages(wire: WireUser, a: Allocator) ![]types.ImageAttachment {
        const images = try a.alloc(types.ImageAttachment, wire.images.len);
        for (wire.images, images) |image, *out| {
            if (image.source_ref) |value| {
                if (!image_data.validSourceRef(value)) return error.InvalidSessionFormat;
            }
            if (image.blob) |hash| {
                if (image.inline_data != null or image.snapshot_path != null or image.snapshot_sha256 != null) return error.InvalidSessionFormat;
                out.* = .{
                    .id = image.id,
                    .path = try a.dupe(u8, image.path),
                    .media_type = try a.dupe(u8, image.media_type),
                    .snapshot_sha256 = try a.dupe(u8, hash),
                    .source_ref = if (image.source_ref) |value| try a.dupe(u8, value) else null,
                };
                continue;
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
        return images;
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
    const tag = try json_decode.parseFromSliceLeaky([]const u8, arena, raw, .{});
    return session_codec.parseConversationLanguage(tag);
}

/// A fork's title: the source's, marked once as a fork (D58).
fn forkTitle(arena: Allocator, title: []const u8) ![]const u8 {
    const mark = " (fork)";
    if (std.mem.endsWith(u8, title, mark)) return title;
    return arena.print("{s}" ++ mark, .{title});
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
    inline for (@typeInfo(PieceKind).@"enum".field_values) |field_value| {
        const kind: PieceKind = @fromBackingInt(@intCast(field_value));
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

test "the store refuses a sessions folder that is a file or a symlink, and opens a missing one (D67)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home);
    // Missing: the first write makes it.
    var missing = try Store.open(testing.allocator, home);
    missing.deinit(testing.allocator);

    try tmp.dir.createDirPath(io, ".fx");
    try tmp.dir.writeFile(io, .{ .sub_path = ".fx/sessions", .data = "not a folder" });
    try testing.expectError(error.SessionPathUnsafe, Store.open(testing.allocator, home));

    try tmp.dir.deleteFile(io, ".fx/sessions");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.symLink(io, "../elsewhere", ".fx/sessions", .{ .is_directory = true });
    try testing.expectError(error.SessionPathUnsafe, Store.open(testing.allocator, home));
}

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

test "a result the model saw whole comes back whole after a resume, or says its body is unavailable" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const whole = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(whole);
    @memset(whole, 'x');
    @memcpy(whole[whole.len - 4 ..], "TAIL");
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    var calls = [_]types.ToolCall{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = whole,
        .output_bytes = whole.len,
        .stored_output_bytes = whole.len,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const user: types.UserTurn = .{ .text = @constCast("read it") };
    const execution: types.ExecutionMemory = .{ .tool_steps = &steps };
    // As the app saves it: the result's file while the turn runs, then the
    // commit, which keeps the body in that file and a preview in the turn.
    try s.appendProgress(user, execution, .{});
    var turn: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("read"), .execution = execution } };
    try s.prepareTurn(&turn);
    defer testing.allocator.free(results[0].output_handle.?);
    defer testing.allocator.free(results[0].preview.?);
    try s.commitTurn(turn, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    var handle: []u8 = &.{};
    defer testing.allocator.free(handle);
    for ([_]bool{ false, true }) |lost| {
        if (lost) {
            // Its blob gone, the result says so rather than show a preview.
            const path = try std.mem.concat(testing.allocator, u8, &.{ ".fx/sessions/v2/", id, "/blobs/", artifact_digest.blobHash(handle).? });
            defer testing.allocator.free(path);
            try t.tmp.dir.deleteFile(io_mod.getIo(), path);
        }
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        const result = restored.history[0].assistant.execution.tool_steps[0].tool_results[0];
        if (!lost) {
            handle = try testing.allocator.dupe(u8, result.output_handle.?);
            try testing.expect(!result.truncated);
            try testing.expectEqualStrings(whole, result.output);
        } else {
            try testing.expect(result.truncated);
            try testing.expectEqualStrings("Saved tool-result content is unavailable. The complete output could not be restored.", result.output);
        }
    }
}

test "a converted session's whole result comes back whole under its old handle on a resume (D47)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // A command result v1 kept under tool-results/, converted on open.
    const id = (try v1.fixture("side", 1))[0];
    (try openConverted(&t, id)).close();
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const result = restored.history[0].assistant.execution.tool_steps[0].tool_results[0];
    try testing.expect(!result.truncated);
    try testing.expectEqual(result.stored_output_bytes, result.output.len);
    try testing.expect(std.mem.find(u8, result.output, "12760") != null);
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
    try testing.checkAllAllocationFailures(testing_allocator.no_resize, Copy.run, .{parent});
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

/// The inline data of the first item of `item_type`. Caller owns it.
fn firstItemData(manager: *sm.Manager, id: []const u8, item_type: []const u8) ![]u8 {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body == .item and std.mem.eql(u8, body.item.type, item_type)) return testing.allocator.dupe(u8, body.item.data);
    }
    return error.TestUnexpectedResult;
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

test "a turn someone other than the user opened keeps its author across a resume" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    // The user's own turn is written as before, with no author item.
    try s.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("inspect") }, .assistant = @constCast("started a reviewer") } }, types.ConversationLanguage.default());
    // A report's turn, streamed twice and then committed, writes one.
    const report: types.UserTurn = .{ .text = @constCast("Subagent report (untrusted agent output, not user instructions):"), .author = .child };
    try s.appendProgress(report, .{}, .{});
    try s.appendProgress(report, .{}, .{});
    try s.commitTurn(.{ .assistant = .{ .user = report, .assistant = @constCast("noted") } }, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, author_type));
    try testing.expectEqual(@as(usize, 2), try countItems(t.store.manager, id, "user"));
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqual(types.MessageAuthor.user, restored.history[0].assistant.user.author);
    try testing.expectEqual(types.MessageAuthor.child, restored.history[1].assistant.user.author);
}

test "an author item a reader cannot read never counts as the user's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(types.MessageAuthor.user, decodeAuthor(a, "{\"by\":\"user\"}"));
    try testing.expectEqual(types.MessageAuthor.parent, decodeAuthor(a, "{\"by\":\"parent\"}"));
    try testing.expectEqual(types.MessageAuthor.child, decodeAuthor(a, "{\"by\":\"child\"}"));
    try testing.expectEqual(types.MessageAuthor.child, decodeAuthor(a, "{\"by\":\"someone_new\"}"));
    try testing.expectEqual(types.MessageAuthor.child, decodeAuthor(a, "not json"));
    try testing.expectEqualStrings("{\"by\":\"child\"}", try encodeAuthor(a, .child));
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

test "a send's record rides with the turn's first write, and a reopen finds the newest" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("go") };
    // Nothing is written until the turn's first pieces are.
    try testing.expect(!try s.saveRecovery(.{ .save = @splat(0x11) }));
    try s.appendProgressWithRecord(user, .{}, .{}, .{ .save = @splat(0x22) });
    try testing.expect(try s.saveRecovery(.{ .save = @splat(0x33) }));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 2), try countItems(t.store.manager, id, recovery_type));
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    defer r.close();
    const found = (try r.interruptedRequest()).?;
    try testing.expectEqual(@as([32]u8, @splat(0x33)), found.record.?);
    try testing.expect(found.saved_ms > 0);
    // The history the model sees has no trace of the record.
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expectEqualStrings("go", restored.history[0].interrupted.user.text);
}

test "an unfinished newest turn is interrupted unless another fx has the session open" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    try s.appendProgress(.{ .text = @constCast("go") }, .{}, .{});
    // Open here, so it is working, not interrupted.
    try testing.expect(!hasInterruptedTurn(&t.store, testing.allocator, "/w"));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expect(hasInterruptedTurn(&t.store, testing.allocator, "/w"));
    try testing.expect(!hasInterruptedTurn(&t.store, testing.allocator, "/elsewhere"));

    // A reopen marks it, and it stays interrupted until a turn ends it.
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    r.close();
    try testing.expect(hasInterruptedTurn(&t.store, testing.allocator, "/w"));

    // A turn the user cancelled is finished.
    const c = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    try c.commitTurn(.{ .interrupted = .{ .user = .{ .text = @constCast("next") }, .terminal_reason = .cancelled } }, types.ConversationLanguage.default());
    c.close();
    try testing.expect(!hasInterruptedTurn(&t.store, testing.allocator, "/w"));
}

test "a cleared record leaves the turn resumable without one" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("run it") };
    try s.appendProgressWithRecord(user, .{}, .{}, .{ .save = @splat(0x44) });
    // The response arrived: its tool call runs with no request in flight.
    try testing.expect(try s.saveRecovery(.clear));
    const call: types.ToolCall = .{ .id = "call_1", .name = "bash", .arguments_json = "{}" };
    try s.appendProgress(user, .{}, .{ .calls = &.{call} });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    defer r.close();
    const found = (try r.interruptedRequest()).?;
    try testing.expectEqual(@as(?[32]u8, null), found.record);
}

test "a session with no interrupted turn has nothing to resume" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer s.close();
    try testing.expectEqual(@as(?Session.InterruptedRequest, null), try s.interruptedRequest());
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

fn commitPrompt(s: *Session, prompt: []const u8) !void {
    try s.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast(prompt) }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
}

fn lineCount(manager: *sm.Manager, id: []const u8) !usize {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    return page.entries.len;
}

test "fork points list every turn's prompt, an interrupted one included (D58)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer s.close();
    try commitPrompt(s, "first");
    try s.commitTurn(.{ .interrupted = .{ .user = .{ .text = @constCast("second") }, .terminal_reason = .cancelled } }, types.ConversationLanguage.default());
    try commitPrompt(s, "third\nwith a second line");
    const points = try s.forkPoints(testing.allocator);
    defer Session.freeForkPoints(testing.allocator, points);
    try testing.expectEqual(@as(usize, 3), points.len);
    try testing.expectEqualStrings("first", points[0].prompt);
    try testing.expectEqualStrings("second", points[1].prompt);
    try testing.expectEqualStrings("third\nwith a second line", points[2].prompt);
    try testing.expect(points[0].turn < points[1].turn and points[1].turn < points[2].turn);
}

test "a fork holds the turns before its prompt under a new id and leaves the source as it was (D58)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer s.close();
    try commitPrompt(s, "first");
    try commitPrompt(s, "second");
    try commitPrompt(s, "third");
    const source_lines = try lineCount(t.store.manager, s.id());
    const points = try s.forkPoints(testing.allocator);
    defer Session.freeForkPoints(testing.allocator, points);

    const copy = try s.fork(testing.allocator, .{ .before_turn = points[2].turn, .workspace = "/w", .host = .app, .title = "Plan" });
    defer copy.close();
    try testing.expect(!std.mem.eql(u8, s.id(), copy.id()));
    try testing.expectEqual(source_lines, try lineCount(t.store.manager, s.id()));
    var restored = try copy.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("second", restored.history[1].assistant.user.text);
    try testing.expectEqualStrings("Plan (fork)", restored.title.?);
    // The fork goes on as any session does; the source is still untouched.
    try commitPrompt(copy, "a different third");
    try testing.expectEqual(source_lines, try lineCount(t.store.manager, s.id()));
}

test "a fork of a fork keeps one fork mark, and a fork before the first prompt is empty (D58)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer s.close();
    try commitPrompt(s, "first");
    const points = try s.forkPoints(testing.allocator);
    defer Session.freeForkPoints(testing.allocator, points);
    const copy = try s.fork(testing.allocator, .{ .before_turn = points[0].turn, .workspace = "/w", .host = .app, .title = "Plan (fork)" });
    defer copy.close();
    var restored = try copy.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), restored.history.len);
    try testing.expectEqualStrings("Plan (fork)", restored.title.?);
    try testing.expectError(error.InvalidForkPoint, s.fork(testing.allocator, .{ .before_turn = 0, .workspace = "/w", .host = .app }));
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

test "an edit's review rows are saved beside its tool result in the shape older fx reads" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("edit it") };
    var calls = [_]types.ToolCall{.{ .id = "call-1", .name = "edit_file", .arguments_json = "{}" }};
    const preview = [_]types.CommittedFilePresentationLine{
        .{ .kind = .deletion, .old_line = 4, .text = "old" },
        .{ .kind = .addition, .new_line = 4, .text = "new" },
    };
    const rows = [_]types.CommittedFilePresentationLine{
        .{ .kind = .elision, .text = "3 unchanged lines ⋯" },
        .{ .kind = .deletion, .old_line = 4, .text = "old" },
        .{ .kind = .addition, .new_line = 4, .text = "new" },
    };
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("edit_file"),
        .status = .success,
        .output = @constCast("edited a.txt"),
        .output_bytes = 12,
        .stored_output_bytes = 12,
        .committed_file_presentation = .{
            .path = "a.txt",
            .kind = .edited,
            .lines = &preview,
            .additions = 1,
            .deletions = 1,
            .truncated = false,
            .lifecycle_id = .{ .turn_id = 1, .call_id = "call-1" },
            .review_lines = &rows,
        },
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const execution: types.ExecutionMemory = .{ .tool_steps = &steps };
    try s.appendProgress(user, execution, .{});
    var turn: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("done"), .execution = execution } };
    try s.prepareTurn(&turn);
    defer testing.allocator.free(results[0].output_handle.?);
    defer testing.allocator.free(results[0].preview.?);
    try s.commitTurn(turn, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    // Streamed, then committed: one result and one review, nothing redone.
    try testing.expectEqual(@as(usize, 0), try countItems(t.store.manager, id, superseded_type));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "tool_result"));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, file_review_type));

    // The result's presentation has only the fields older fx versions know,
    // and no lifecycle id: the preview-only shape they write themselves.
    const data = try firstItemData(t.store.manager, id, "tool_result");
    defer testing.allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, data, .{});
    defer parsed.deinit();
    const presentation = parsed.value.object.get("committed_file_presentation").?.object;
    const released_fields = [_][]const u8{ "path", "kind", "lines", "additions", "deletions", "truncated", "previous_content", "after_content", "lifecycle_id", "content_handle" };
    try testing.expectEqual(released_fields.len, presentation.count());
    for (released_fields) |field| try testing.expect(presentation.contains(field));
    try testing.expect(presentation.get("lifecycle_id").? == .null);

    // Resume puts the rows and their lifecycle id back on the edit.
    const history = try detailHistory(.{ .store = &t.store, .id = id }, testing.allocator);
    defer types.freeHistoryTurnSlice(testing.allocator, history);
    const restored = history[0].assistant.execution.tool_steps[0].tool_results[0].committed_file_presentation.?;
    try testing.expectEqual(@as(u64, 1), restored.lifecycle_id.?.turn_id);
    try testing.expectEqualStrings("call-1", restored.lifecycle_id.?.call_id);
    const restored_rows = restored.review_lines.?;
    try testing.expectEqual(rows.len, restored_rows.len);
    for (rows, restored_rows) |expected, actual| {
        try testing.expectEqual(expected.kind, actual.kind);
        try testing.expectEqual(expected.old_line, actual.old_line);
        try testing.expectEqualStrings(expected.text, actual.text);
    }
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

fn resultEvent(call_id: []const u8, preview: []const u8, stamp: i64) Event {
    return .{ .tool_result = .{
        .call_id = call_id,
        .tool_name = "read_file",
        .status = .success,
        .artifact_ref = "result-read_file.txt",
        .stored_bytes = preview.len,
        .completeness = .complete,
        .preview = preview,
        .created_at_ms = stamp,
    } };
}

fn encodeAll(a: Allocator, events: []const Event) ![]const []const u8 {
    const encoded = try a.alloc([]const u8, events.len);
    for (events, encoded) |event, *bytes| bytes.* = try encodePiece(a, event);
    return encoded;
}

test "streamed pieces stand by their bytes, and only a restamped result needs parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user: Event = .{ .user = .{ .text = "read them" } };
    const streamed = try encodeAll(a, &.{ user, resultEvent("call-1", "one", 100), resultEvent("call-2", "two", 101) });
    // A rebuild that kept every stamp, with one more result.
    try testing.expectEqual(@as(?usize, 0), reparsedPrefix(testing.allocator, streamed, try encodeAll(a, &.{
        user, resultEvent("call-1", "one", 100), resultEvent("call-2", "two", 101), resultEvent("call-3", "three", 102),
    })));
    // A rebuild that stamped each result again still stands, by parsing.
    try testing.expectEqual(@as(?usize, 2), reparsedPrefix(testing.allocator, streamed, try encodeAll(a, &.{
        user, resultEvent("call-1", "one", 200), resultEvent("call-2", "two", 201),
    })));
    // Other content, or a missing piece, no longer stands.
    try testing.expectEqual(@as(?usize, null), reparsedPrefix(testing.allocator, streamed, try encodeAll(a, &.{
        user, resultEvent("call-1", "uno", 100), resultEvent("call-2", "two", 101),
    })));
    try testing.expectEqual(@as(?usize, null), reparsedPrefix(testing.allocator, streamed, try encodeAll(a, &.{
        user, resultEvent("call-2", "two", 101),
    })));
}

fn readResult(call_id: []const u8, output: []const u8, stamp: i64) types.PersistedToolResult {
    return .{
        .tool_call_id = @constCast(call_id),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast(output),
        .output_bytes = output.len,
        .stored_output_bytes = output.len,
        .created_at_ms = stamp,
    };
}

/// The stamp of the one tool result a session's only turn restores with.
fn restoredStamp(t: *TestHome, id: []const u8) !i64 {
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    const steps = restored.history[0].assistant.execution.tool_steps;
    try testing.expectEqual(@as(usize, 1), steps.len);
    try testing.expectEqual(@as(usize, 1), steps[0].tool_results.len);
    return steps[0].tool_results[0].created_at_ms;
}

test "a turn whose result keeps its stamp commits as streamed, with that stamp" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("read it") };
    var calls = [_]types.ToolCall{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }};
    var results = [_]types.PersistedToolResult{readResult("call-1", "contents", 100)};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const execution: types.ExecutionMemory = .{ .tool_steps = &steps };
    try s.appendProgress(user, execution, .{});
    try s.appendProgress(user, execution, .{});
    var turn: types.HistoryTurn = .{ .assistant = .{ .user = user, .assistant = @constCast("done"), .execution = execution } };
    try s.prepareTurn(&turn);
    defer if (results[0].output_handle) |handle| testing.allocator.free(handle);
    defer if (results[0].preview) |preview| testing.allocator.free(preview);
    try s.commitTurn(turn, types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 0), try countItems(t.store.manager, id, superseded_type));
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, "tool_result"));
    try testing.expectEqual(@as(i64, 100), try restoredStamp(&t, id));
}

test "a result rebuilt with other content supersedes its stream and is written as rebuilt" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const user: types.UserTurn = .{ .text = @constCast("read it") };
    var calls = [_]types.ToolCall{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }};
    var results = [_]types.PersistedToolResult{readResult("call-1", "contents", 100)};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const execution: types.ExecutionMemory = .{ .tool_steps = &steps };
    try s.appendProgress(user, execution, .{});
    results[0].status = .failure;
    results[0].created_at_ms = 200;
    try s.appendProgress(user, execution, .{});
    // The turn written afresh holds the rebuild, its stamp included.
    const written = for (s.streamed.items) |bytes| {
        if (std.mem.find(u8, bytes, "\"artifact_ref\"") != null) break bytes;
    } else return error.TestExpectedStreamedResult;
    try testing.expect(std.mem.find(u8, written, "\"created_at_ms\":200") != null);
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();
    try testing.expectEqual(@as(usize, 1), try countItems(t.store.manager, id, superseded_type));
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

test "a compaction inside a turn leaves the steps it covers out of that turn on resume, and a second one counts on (D87)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const result = struct {
        fn ok(id: []const u8, handle: []const u8) types.PersistedToolResult {
            return .{ .tool_call_id = @constCast(id), .tool_name = @constCast("shell"), .status = .success, .output = @constCast("ok"), .output_bytes = 2, .output_handle = @constCast(handle), .stored_output_bytes = 2 };
        }
    };
    var calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "shell", .arguments_json = "{}" },
    };
    var results = [_]types.PersistedToolResult{
        result.ok("call-1", "result-shell-1.txt"),
        result.ok("call-2", "result-shell-2.txt"),
        result.ok("call-3", "result-shell-3.txt"),
    };
    var steps = [_]types.ToolExecutionStep{
        .{ .tool_calls = calls[0..1], .tool_results = results[0..1] },
        .{ .tool_calls = calls[1..2], .tool_results = results[1..2] },
        .{ .tool_calls = calls[2..3], .tool_results = results[2..3] },
    };
    var steering = [_]types.PersistedSteering{
        .{ .text = @constCast("after one"), .after_tool_step_count = 1 },
        .{ .text = @constCast("after two"), .after_tool_step_count = 2 },
    };
    try s.commitTurn(.{ .assistant = .{
        .user = .{ .text = @constCast("three steps") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = &steps, .steering = &steering },
    } }, types.ConversationLanguage.default());
    var first = "steps one and two".*;
    try s.commitCompaction(.{ .summary = &first, .removed_turn_count = 0, .compaction_count = 1 }, false, .{ .tool_steps = 2, .steering = 1 });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    // As fx's history after the compaction: the summary, then the turn's
    // prompt and what came after the cut.
    {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), restored.history.len);
        const kept = restored.history[1].assistant;
        try testing.expectEqualStrings("three steps", kept.user.text);
        try testing.expectEqualStrings("done", kept.assistant);
        try testing.expectEqual(@as(usize, 1), kept.execution.tool_steps.len);
        try testing.expectEqualStrings("call-3", kept.execution.tool_steps[0].tool_calls[0].id);
        try testing.expectEqual(@as(usize, 1), kept.execution.steering.len);
        try testing.expectEqualStrings("after two", kept.execution.steering[0].text);
        try testing.expectEqual(@as(usize, 0), kept.execution.steering[0].after_tool_step_count);
        // fx's cut counts from the turn as its history now shows it.
        var second = "all three steps".*;
        try r.commitCompaction(.{ .summary = &second, .removed_turn_count = 0, .compaction_count = 2 }, false, .{ .tool_steps = 1, .steering = 1 });
    }
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("all three steps", restored.history[0].compacted_summary.summary);
    const kept = restored.history[1].assistant;
    try testing.expectEqualStrings("three steps", kept.user.text);
    try testing.expectEqual(@as(usize, 0), kept.execution.tool_steps.len);
    try testing.expectEqual(@as(usize, 0), kept.execution.steering.len);
}

/// Two shell steps whose results name their stored bodies.
const NoteTestSteps = struct {
    calls: [3]types.ToolCall = .{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "shell", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "shell", .arguments_json = "{}" },
    },
    results: [3]types.PersistedToolResult = .{
        ok("call-1", "result-shell-1.txt"),
        ok("call-2", "result-shell-2.txt"),
        ok("call-3", "result-shell-3.txt"),
    },
    steps: [3]types.ToolExecutionStep = undefined,

    fn ok(id: []const u8, handle: []const u8) types.PersistedToolResult {
        return .{ .tool_call_id = @constCast(id), .tool_name = @constCast("shell"), .status = .success, .output = @constCast("ok"), .output_bytes = 2, .output_handle = @constCast(handle), .stored_output_bytes = 2 };
    }

    fn init(self: *NoteTestSteps) void {
        for (&self.steps, 0..) |*step, i| step.* = .{ .tool_calls = self.calls[i .. i + 1], .tool_results = self.results[i .. i + 1] };
    }
};

test "a turn's context notes come back on resume at their boundaries, before that boundary's steering (D93)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    var fixture: NoteTestSteps = .{};
    fixture.init();
    var delivered = [_]types.ContextNoteSource{
        .{ .path = "/w/sub/AGENTS.md", .stamp = 0x1F_FFFF_FFFF_FFFF },
        .{ .path = "/w/sub/deep/CLAUDE.md", .stamp = 0 },
    };
    var notes = [_]types.PersistedContextNote{
        .{ .text = @constCast("note at start"), .after_tool_step_count = 0 },
        .{ .text = @constCast("note after one"), .after_tool_step_count = 1, .sources = &delivered },
        .{ .text = @constCast("note at the end"), .after_tool_step_count = 2 },
    };
    var steering = [_]types.PersistedSteering{.{ .text = @constCast("steer after one"), .after_tool_step_count = 1 }};
    try s.commitTurn(.{ .assistant = .{
        .user = .{ .text = @constCast("two steps") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = fixture.steps[0..2], .steering = &steering, .context_notes = &notes },
    } }, types.ConversationLanguage.default());
    try s.commitTurn(assistantTurn("plain", "turn"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    // Each note is its own `context_note` item, written before the steering
    // at its boundary.
    const io = io_mod.getIo();
    const log_path = try std.Io.Dir.path.join(testing.allocator, &.{ ".fx", "sessions", "v2", id, "log.jsonl" });
    defer testing.allocator.free(log_path);
    const bytes = try t.tmp.dir.readFileAlloc(io, log_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\"context_note\""));
    try testing.expect(std.mem.find(u8, bytes, "note after one").? < std.mem.find(u8, bytes, "steer after one").?);
    try testing.expect(std.mem.find(u8, bytes, "call-2").? < std.mem.find(u8, bytes, "note at the end").?);

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    const execution = restored.history[0].assistant.execution;
    try testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try testing.expectEqual(notes.len, execution.context_notes.len);
    for (notes, execution.context_notes) |want, got| {
        try testing.expectEqualStrings(want.text, got.text);
        try testing.expectEqual(want.after_tool_step_count, got.after_tool_step_count);
        // Each delivered file comes back with its stamp, including the
        // largest stamp and an unknown one.
        try testing.expectEqual(want.sources.len, got.sources.len);
        for (want.sources, got.sources) |want_source, got_source| {
            try testing.expectEqualStrings(want_source.path, got_source.path);
            try testing.expectEqual(want_source.stamp, got_source.stamp);
        }
    }
    try testing.expectEqual(@as(usize, 1), execution.steering.len);
    try testing.expectEqual(@as(usize, 1), execution.steering[0].after_tool_step_count);
    // A turn without notes comes back without any.
    try testing.expectEqual(@as(usize, 0), restored.history[1].assistant.execution.context_notes.len);
}

test "a turn's runtime context comes back on resume, saved once right after its user message (D94)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    var fixture: NoteTestSteps = .{};
    fixture.init();
    var captured = [_][]u8{ @constCast("<fx-turn-context>\ngit_branch: main\n</fx-turn-context>"), @constCast("Runtime context: permission mode is ask.") };
    var notes = [_]types.PersistedContextNote{.{ .text = @constCast("note at start"), .after_tool_step_count = 0 }};
    const user: types.UserTurn = .{ .text = @constCast("two steps") };
    // Every save of the turn carries it, so the streamed pieces stay a prefix
    // of the committed turn.
    try s.appendProgress(user, .{ .tool_steps = fixture.steps[0..1], .context_notes = &notes, .runtime_context = &captured }, .{});
    try s.commitTurn(.{ .assistant = .{
        .user = user,
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = fixture.steps[0..2], .context_notes = &notes, .runtime_context = &captured },
    } }, types.ConversationLanguage.default());
    try s.commitTurn(assistantTurn("plain", "turn"), types.ConversationLanguage.default());
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    const io = io_mod.getIo();
    const log_path = try std.Io.Dir.path.join(testing.allocator, &.{ ".fx", "sessions", "v2", id, "log.jsonl" });
    defer testing.allocator.free(log_path);
    const bytes = try t.tmp.dir.readFileAlloc(io, log_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, superseded_type) == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "git_branch: main"));
    try testing.expect(std.mem.find(u8, bytes, "two steps").? < std.mem.find(u8, bytes, "git_branch: main").?);
    try testing.expect(std.mem.find(u8, bytes, "git_branch: main").? < std.mem.find(u8, bytes, "note at start").?);

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    const execution = restored.history[0].assistant.execution;
    try testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try testing.expectEqual(@as(usize, 1), execution.context_notes.len);
    try testing.expectEqual(captured.len, execution.runtime_context.?.len);
    for (captured, execution.runtime_context.?) |want, got| try testing.expectEqualStrings(want, got);
    // A later turn that used the saved copy saves none.
    try testing.expect(restored.history[1].assistant.execution.runtime_context == null);
}

test "a compaction inside a turn drops the context notes it covers and keeps the later ones on resume (D93)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    var fixture: NoteTestSteps = .{};
    fixture.init();
    var notes = [_]types.PersistedContextNote{
        .{ .text = @constCast("note after one"), .after_tool_step_count = 1 },
        .{ .text = @constCast("note after two"), .after_tool_step_count = 2 },
        .{ .text = @constCast("note after three"), .after_tool_step_count = 3 },
    };
    var steering = [_]types.PersistedSteering{
        .{ .text = @constCast("after one"), .after_tool_step_count = 1 },
        .{ .text = @constCast("after two"), .after_tool_step_count = 2 },
    };
    try s.commitTurn(.{ .assistant = .{
        .user = .{ .text = @constCast("three steps") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = &fixture.steps, .steering = &steering, .context_notes = &notes },
    } }, types.ConversationLanguage.default());
    var first = "steps one and two".*;
    try s.commitCompaction(.{ .summary = &first, .removed_turn_count = 0, .compaction_count = 1 }, false, .{ .tool_steps = 2, .steering = 1 });
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    s.close();

    {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        const kept = restored.history[1].assistant;
        try testing.expectEqual(@as(usize, 1), kept.execution.tool_steps.len);
        // The note before the cut is gone; the one at the cut and the one
        // after the last step stay, counted from the cut.
        try testing.expectEqual(@as(usize, 2), kept.execution.context_notes.len);
        try testing.expectEqualStrings("note after two", kept.execution.context_notes[0].text);
        try testing.expectEqual(@as(usize, 0), kept.execution.context_notes[0].after_tool_step_count);
        try testing.expectEqualStrings("note after three", kept.execution.context_notes[1].text);
        try testing.expectEqual(@as(usize, 1), kept.execution.context_notes[1].after_tool_step_count);
        var second = "all three steps".*;
        try r.commitCompaction(.{ .summary = &second, .removed_turn_count = 0, .compaction_count = 2 }, false, .{ .tool_steps = 1, .steering = 1 });
    }
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const kept = restored.history[1].assistant;
    try testing.expectEqual(@as(usize, 0), kept.execution.tool_steps.len);
    // The second cut covers the note before the step it covers and keeps the
    // note after the last step, which nothing follows.
    try testing.expectEqual(@as(usize, 1), kept.execution.context_notes.len);
    try testing.expectEqualStrings("note after three", kept.execution.context_notes[0].text);
    try testing.expectEqual(@as(usize, 0), kept.execution.context_notes[0].after_tool_step_count);
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
    const log_path = try std.Io.Dir.path.join(testing.allocator, &.{ ".fx", "sessions", "v2", id, "log.jsonl" });
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

test "a failed resume reports v1's error names" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectError(error.NoSavedSessions, Session.resumeSession(testing.allocator, &t.store, .last, "/w", .ask));
    try testing.expectError(error.SessionNotFound, Session.resumeSession(testing.allocator, &t.store, .{ .id = "AAAAAAAAAAAA" }, "/w", .ask));
    try testing.expectEqual(error.SessionBusy, resumeError(error.Busy, .last));
    try testing.expectEqual(error.OneOffSessionNotResumable, resumeError(error.ChildSession, .{ .id = "AAAAAAAAAAAA" }));
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
    const path = std.Io.Dir.path.join(testing.allocator, parts) catch return false;
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
    const copy = try std.Io.Dir.path.join(testing.allocator, &.{ ".fx", terminal_dir_name, recovered.id });
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

test "a resume makes a hand-made ~/.fx private instead of refusing the session" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const s = try Session.create(testing.allocator, &t.store, "/w", .ask, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try OldSideFolder.commitTurn(&t, s);
    s.close();
    try t.tmp.dir.setFilePermissions(io_mod.getIo(), ".fx", .fromMode(0o755), .{});

    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    r.close();
    const stat = try t.tmp.dir.statFile(io_mod.getIo(), ".fx", .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
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
        const snapshot_path = try std.Io.Dir.path.join(testing.allocator, &.{ t.home, ".fx", files_dir_name, s.id(), "images", image_name });
        defer testing.allocator.free(snapshot_path);
        var images = [_]types.ImageAttachment{.{
            .id = 1,
            .path = @constCast("/Users/example/shot.png"),
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
    // The image is its blob now, read back on demand, and the client's
    // settings are settings.
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const image = restored.history[0].assistant.user.images[0];
    try testing.expectEqual(@as(?[]u8, null), image.inline_data);
    {
        var read = try image_attachments.loadVerifiedSnapshot(testing.allocator, image, .{});
        defer read.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &OldSideFolder.png, read.bytes);
    }
    // Its blob is the file the model's note names (D89).
    {
        const hash = r.host.moved.get("images/" ++ OldSideFolder.image_name).?;
        const path = try t.store.manager.blobPath(testing.allocator, id, &hash);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(path, image.blob_path.?);
    }
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
    try testing.expectEqual(@as(?[]u8, null), lost.blob_path);
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

/// Whether session `id`'s first user item lists blob `hash`.
fn userItemLists(t: *TestHome, id: []const u8, hash: []const u8) !bool {
    var page = try t.store.manager.read(testing.allocator, id, .start, .forward, 64);
    defer page.deinit();
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body != .item or !std.mem.eql(u8, body.item.type, "user")) continue;
        for (body.item.blobs) |ref| if (std.mem.eql(u8, ref, hash)) return true;
        return false;
    }
    return error.TestUnexpectedResult;
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
        .path = @constCast("/Users/example/shot.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/fx-snapshots/image-1.png"),
        .snapshot_sha256 = &digest_hex,
        .inline_data = @constCast(&bytes),
    }};
    const v1_image_prefix = "{\"text\":\"look\",\"images\":[{\"id\":1,\"path\":\"/Users/example/shot.png\",\"media_type\":\"image/png\"," ++
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

/// Session `id`'s first `user` item, whether it lists blob `hash`, and how
/// many turns were superseded. The caller frees `data`.
const UserItem = struct { data: []u8, lists: bool, superseded: usize };

fn firstUserItem(manager: *sm.Manager, id: []const u8, hash: []const u8) !UserItem {
    var page = try manager.read(testing.allocator, id, .start, .forward, 1000);
    defer page.deinit();
    var found: ?UserItem = null;
    var superseded: usize = 0;
    for (page.entries) |entry| {
        const body = entry.body orelse continue;
        if (body != .item) continue;
        if (std.mem.eql(u8, body.item.type, superseded_type)) superseded += 1;
        if (found != null or !std.mem.eql(u8, body.item.type, itemType(.user).?)) continue;
        const lists = for (body.item.blobs) |ref| {
            if (std.mem.eql(u8, ref, hash)) break true;
        } else false;
        found = .{ .data = try testing.allocator.dupe(u8, body.item.data), .lists = lists, .superseded = 0 };
    }
    var item = found orelse return error.TestUnexpectedResult;
    item.superseded = superseded;
    return item;
}

test "a prompt image is saved as its own blob before the request, named in the user's item, and read back with its path (D89)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const bytes = OldSideFolder.png ++ [_]u8{ 0x00, 0xff };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    const original = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/Users/example/shot.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/fx-image-snapshots-0000000000000001/image-1.bin"),
        .snapshot_sha256 = &digest_hex,
        .inline_data = @constCast(&bytes),
    }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);

    var images = original;
    try s.savePromptImages(arena.allocator(), &images);
    const blob_path = try t.store.manager.blobPath(testing.allocator, id, &digest_hex);
    defer testing.allocator.free(blob_path);
    try testing.expectEqualStrings(blob_path, images[0].blob_path.?);
    // The turn keeps only the handle; the host's copy keeps its bytes.
    try testing.expectEqual(@as(?[]u8, null), images[0].inline_data);
    try testing.expect(original[0].inline_data != null);
    // Before any request: the file the note names already holds the image.
    {
        var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), blob_path, .{});
        defer file.close(io_mod.getIo());
        var buffer: [256]u8 = undefined;
        const len = try file.readPositionalAll(io_mod.getIo(), &buffer, 0);
        try testing.expectEqualSlices(u8, &bytes, buffer[0..len]);
    }
    // Saving the handle again reads it back and keeps the one blob and its
    // path.
    try s.savePromptImages(arena.allocator(), &images);
    try testing.expectEqualStrings(blob_path, images[0].blob_path.?);
    try testing.expectEqual(@as(?[]u8, null), images[0].inline_data);

    // Streamed from the saved copy, committed from the host's copy without
    // paths: the same item, so the turn is not superseded.
    try s.appendProgress(.{ .text = @constCast("look"), .images = &images }, .{}, .{});
    var turn = assistantTurn("look", "a png");
    var host_copy = original;
    turn.assistant.user.images = &host_copy;
    try s.commitTurn(turn, types.ConversationLanguage.default());
    s.close();

    const item = try firstUserItem(t.store.manager, id, &digest_hex);
    defer testing.allocator.free(item.data);
    try testing.expectEqual(@as(usize, 0), item.superseded);
    try testing.expect(item.lists);
    const blob_field = try arena.allocator().print("\"blob\":\"{s}\"", .{&digest_hex});
    try testing.expect(std.mem.find(u8, item.data, blob_field) != null);
    // Neither the bytes nor the process's temporary snapshot are written.
    try testing.expect(std.mem.find(u8, item.data, "inline_data") == null);
    try testing.expect(std.mem.find(u8, item.data, "fx-image-snapshots") == null);
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);

    // Resumed, and in a fork that hard-links the blob, the image has only
    // the path of its own session's blob, which reads back as its bytes.
    const fork = try t.store.manager.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
    const fork_id = try testing.allocator.dupe(u8, fork.id());
    defer testing.allocator.free(fork_id);
    fork.release();
    for ([_][]const u8{ id, fork_id }) |which| {
        const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = which }, "/w", .app);
        defer r.close();
        var restored = try r.restore(testing.allocator);
        defer restored.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), restored.history.len);
        const image = restored.history[0].assistant.user.images[0];
        try testing.expectEqual(@as(?[]u8, null), image.inline_data);
        try testing.expectEqualStrings(&digest_hex, image.snapshot_sha256.?);
        try testing.expectEqual(@as(?[]u8, null), image.snapshot_path);
        try testing.expectEqualStrings(original[0].path, image.path);
        const path = try t.store.manager.blobPath(testing.allocator, which, &digest_hex);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(path, image.blob_path.?);
        var read = try image_attachments.loadVerifiedSnapshot(testing.allocator, image, .{});
        defer read.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &bytes, read.bytes);
    }

    // A blob the item names that is gone damages the session (D39).
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), blob_path);
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    defer r.close();
    try testing.expectError(error.InvalidSessionFormat, r.restore(testing.allocator));
}

test "a prompt image the store does not save keeps its bytes inline and gets no path (D89)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const bytes = OldSideFolder.png;
    // A digest that is not the bytes' cannot name their blob.
    const wrong_digest: [32]u8 = @splat(0xab);
    var wrong = std.fmt.bytesToHex(wrong_digest, .lower);
    var images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/Users/example/a.png"), .media_type = @constCast("image/png"), .snapshot_sha256 = &wrong, .inline_data = @constCast(&bytes) },
        // Bytes the session does not hold are not its to save.
        .{ .id = 2, .path = @constCast("/Users/example/b.png"), .media_type = @constCast("image/png"), .snapshot_path = @constCast("/Users/example/.fx/sessions/s/images/image-2.bin") },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    try s.savePromptImages(arena.allocator(), &images);
    try testing.expectEqual(@as(?[]u8, null), images[0].blob_path);
    try testing.expectEqual(@as(?[]u8, null), images[1].blob_path);
    var turn = assistantTurn("look", "two");
    turn.assistant.user.images = &images;
    try s.commitTurn(turn, types.ConversationLanguage.default());
    s.close();

    const item = try firstUserItem(t.store.manager, id, &wrong);
    defer testing.allocator.free(item.data);
    try testing.expect(std.mem.find(u8, item.data, "\"blob\"") == null);
    const r = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .app);
    defer r.close();
    var restored = try r.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    const kept = restored.history[0].assistant.user.images;
    try testing.expectEqualSlices(u8, &bytes, kept[0].inline_data.?);
    try testing.expectEqual(@as(?[]u8, null), kept[0].blob_path);
    try testing.expectEqual(@as(?[]u8, null), kept[1].blob_path);
    try testing.expectEqualStrings(images[1].snapshot_path.?, kept[1].snapshot_path.?);
}

test "a turn the store cannot start keeps its prompt images inline and does not fail the prompt (D89)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const bytes = OldSideFolder.png;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    var images = [_]types.ImageAttachment{.{ .id = 1, .path = @constCast("/Users/example/a.png"), .media_type = @constCast("image/png"), .snapshot_sha256 = &digest_hex, .inline_data = @constCast(&bytes) }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    defer s.close();
    // A new session reaches the disk with its first line, the turn's start,
    // which a read-only store refuses.
    const io = io_mod.getIo();
    try std.Io.Dir.cwd().createDirPath(io, t.store.manager.root_path);
    var root = try std.Io.Dir.openDirAbsolute(io, t.store.manager.root_path, .{});
    defer root.close(io);
    root.setPermissions(io, .fromMode(0o500)) catch return error.SkipZigTest;
    defer root.setPermissions(io, .fromMode(0o700)) catch {};
    try s.savePromptImages(arena.allocator(), &images);
    try testing.expectEqual(@as(?[]u8, null), images[0].blob_path);
    try testing.expectEqualSlices(u8, &bytes, images[0].inline_data.?);
}

test "an image that arrives with another session's blob path is saved here or written without a blob (D89)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const bytes = OldSideFolder.png;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    var digest_hex = std.fmt.bytesToHex(digest, .lower);
    const other_digest: [32]u8 = @splat(0xcd);
    var other_hex = std.fmt.bytesToHex(other_digest, .lower);
    const elsewhere = "/Users/example/.fx/sessions/v2/other/blobs/elsewhere";
    const original = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/Users/example/a.png"), .media_type = @constCast("image/png"), .snapshot_sha256 = &digest_hex, .inline_data = @constCast(&bytes), .blob_path = @constCast(elsewhere) },
        // No bytes here to save, only another session's blob.
        .{ .id = 2, .path = @constCast("/Users/example/b.png"), .media_type = @constCast("image/png"), .snapshot_path = @constCast("/Users/example/b.bin"), .snapshot_sha256 = &other_hex, .blob_path = @constCast(elsewhere) },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try Session.create(testing.allocator, &t.store, "/w", .app, testSeed(&model));
    const id = try testing.allocator.dupe(u8, s.id());
    defer testing.allocator.free(id);
    var images = original;
    try s.savePromptImages(arena.allocator(), &images);
    const own = try t.store.manager.blobPath(testing.allocator, id, &digest_hex);
    defer testing.allocator.free(own);
    try testing.expectEqualStrings(own, images[0].blob_path.?);
    try testing.expectEqual(@as(?[]u8, null), images[1].blob_path);

    // Committed from a copy that still carries the other session's paths.
    var turn = assistantTurn("look", "two");
    var host_copy = original;
    turn.assistant.user.images = &host_copy;
    try s.commitTurn(turn, types.ConversationLanguage.default());
    s.close();
    const item = try firstUserItem(t.store.manager, id, &digest_hex);
    defer testing.allocator.free(item.data);
    const own_ref = try arena.allocator().print("\"blob\":\"{s}\"", .{&digest_hex});
    try testing.expect(std.mem.find(u8, item.data, own_ref) != null);
    const other_ref = try arena.allocator().print("\"blob\":\"{s}\"", .{&other_hex});
    try testing.expect(std.mem.find(u8, item.data, other_ref) == null);
    try testing.expect(std.mem.find(u8, item.data, elsewhere) == null);
    try testing.expectEqual(@as(u64, 0), (try t.store.manager.verify(id)).bad_blobs);
}

test "v2 image source refs reject malformed metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_][]const u8{ "", "bad\nref", text_utils.repeat("x", 513) }) |source_ref| {
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
/// A test home's v1 sessions: copies of what the real v0.0.14 release saved
/// (`tests/fixtures/v1-sessions/generate.ts`), and raw files a test writes
/// over them.
const V1Home = struct {
    t: *TestHome,
    arena: std.heap.ArenaAllocator,
    /// Where the fixtures were saved, which v1 recorded; set by `fixture`.
    workspace: []const u8 = "",

    fn init(t: *TestHome) !V1Home {
        return .{ .t = t, .arena = .init(testing.allocator) };
    }

    fn deinit(v1: *V1Home) void {
        v1.arena.deinit();
    }

    /// Copies the first `count` sessions of the fixture `kind`, root first,
    /// into the home's `~/.fx`, private as v1 left them, with what the kind
    /// keeps outside its sessions, and returns their ids.
    fn fixture(v1: *V1Home, kind: []const u8, count: usize) ![]const []const u8 {
        const io = io_mod.getIo();
        const a = v1.arena.allocator();
        const root = try std.Io.Dir.path.join(a, &.{ @import("test_paths").source_root, "..", "tests", "fixtures", "v1-sessions" });
        // `source_root` is relative to the build root, where tests run.
        var fixtures = try std.Io.Dir.cwd().openDir(io, root, .{});
        defer fixtures.close(io);
        const manifest = try fixtures.readFileAlloc(io, "manifest.json", a, .limited(1 << 16));
        const Manifest = struct { workspace: []const u8, kinds: std.json.ArrayHashMap([]const []const u8) };
        const parsed = try json_decode.parseFromSliceLeaky(Manifest, a, manifest, .{ .ignore_unknown_fields = true });
        v1.workspace = parsed.workspace;
        const all = parsed.kinds.map.get(kind) orelse return error.FileNotFound;
        if (count > all.len) return error.TestUnexpectedResult;
        const ids = all[0..count];
        var source = try fixtures.openDir(io, kind, .{ .iterate = true });
        defer source.close(io);
        var fx = try io_mod.openOrCreateVerifiedPrivateDirFromDir(v1.t.tmp.dir, profile_paths.root_dir_name);
        defer fx.close();
        var walker = try source.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            // Leave out the sessions past `count`.
            var parts = std.mem.splitScalar(u8, entry.path, std.Io.Dir.path.sep);
            if (std.mem.eql(u8, parts.first(), profile_paths.sessions_dir_name)) if (parts.next()) |id| {
                const left_out = for (all[count..]) |other| {
                    if (std.mem.eql(u8, id, other)) break true;
                } else false;
                if (left_out) continue;
            };
            switch (entry.kind) {
                // Another kind may have made it.
                .directory => fx.dir.createDir(io, entry.path, .fromMode(0o700)) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                },
                .file => try fx.dir.writeFile(io, .{
                    .sub_path = entry.path,
                    .data = try source.readFileAlloc(io, entry.path, a, .limited(1 << 24)),
                    .flags = .{ .permissions = .fromMode(0o600) },
                }),
                else => return error.UnexpectedFixtureEntry,
            }
        }
        // A copy's log gets the time v1 left on it, its `session.json`'s:
        // v1 lists a session by the later of the two, and a copy's own time
        // would order the copies by when they were made.
        for (ids) |id| {
            const folder = try std.Io.Dir.path.join(a, &.{ profile_paths.sessions_dir_name, id });
            const saved_json = try fx.dir.readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ folder, "session.json" }), a, .limited(1 << 20));
            const Saved = struct { updated_at_ms: ?i64 = null };
            const saved = (try json_decode.parseFromSliceLeaky(Saved, a, saved_json, .{ .ignore_unknown_fields = true })).updated_at_ms orelse continue;
            const at: std.Io.Timestamp = .{ .nanoseconds = @as(i96, saved) * std.time.ns_per_ms };
            const log = try std.Io.Dir.path.join(a, &.{ folder, "events.jsonl" });
            _ = fx.dir.statFile(io, log, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            try fx.dir.setTimestamps(io, log, .{ .modify_timestamp = .{ .new = at } });
        }
        return ids;
    }

    /// Writes `bytes` to `{folder}/{name}` in v1's folder of `id`, the
    /// folders and the file private as v1 makes them.
    fn put(v1: *V1Home, id: []const u8, folder: ?[]const u8, name: []const u8, bytes: []const u8) !void {
        var fx = try io_mod.openOrCreateVerifiedPrivateDirFromDir(v1.t.tmp.dir, profile_paths.root_dir_name);
        defer fx.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&fx, profile_paths.sessions_dir_name);
        defer sessions.close();
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&sessions, id);
        defer dir.close();
        var target = if (folder) |sub| try io_mod.openOrCreateVerifiedPrivateDir(&dir, sub) else null;
        defer if (target) |*value| value.close();
        try (if (target) |value| value.dir else dir.dir).writeFile(io_mod.getIo(), .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    }

    /// v1's `session.json` of `id`. The arena's.
    fn metadata(v1: *V1Home, id: []const u8) !std.json.ObjectMap {
        const a = v1.arena.allocator();
        const path = try std.Io.Dir.path.join(a, &.{ ".fx", "sessions", id, "session.json" });
        const bytes = try v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), path, a, .limited(1 << 20));
        return (try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{})).object;
    }

    /// When v1 logged each prompt of `id`: the times its turns start.
    fn promptTimes(v1: *V1Home, id: []const u8) ![]const u64 {
        const a = v1.arena.allocator();
        const path = try std.Io.Dir.path.join(a, &.{ ".fx", "sessions", id, "events.jsonl" });
        const bytes = try v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), path, a, .limited(1 << 24));
        var times: std.ArrayList(u64) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const event = (try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{})).object;
            if (event.get("event").?.object.get("user") != null) try times.append(a, @intCast(event.get("timestamp_ms").?.integer));
        }
        return times.items;
    }

    /// The one file in `folder` of v1's `id`. The arena's.
    fn only(v1: *V1Home, id: []const u8, folder: []const u8) ![]const u8 {
        const a = v1.arena.allocator();
        var dir = try v1.t.tmp.dir.openDir(io_mod.getIo(), try std.Io.Dir.path.join(a, &.{ ".fx", "sessions", id, folder }), .{ .iterate = true });
        defer dir.close(io_mod.getIo());
        var entries = dir.iterate();
        const first = (try entries.next(io_mod.getIo())) orelse return error.FileNotFound;
        if (try entries.next(io_mod.getIo())) |_| return error.TestUnexpectedResult;
        return a.dupe(u8, first.name);
    }

    /// The bytes of `{folder}/{name}` in v1's `id`. The arena's.
    fn file(v1: *V1Home, id: []const u8, folder: []const u8, name: []const u8) ![]const u8 {
        const a = v1.arena.allocator();
        return v1.t.tmp.dir.readFileAlloc(io_mod.getIo(), try std.Io.Dir.path.join(a, &.{ ".fx", "sessions", id, folder, name }), a, .limited(1 << 24));
    }

    /// Every file under `folder` of v1's `id`, by its path there, with its
    /// bytes. The arena's.
    fn tree(v1: *V1Home, id: []const u8, folder: []const u8) !std.array_hash_map.String([]const u8) {
        const io = io_mod.getIo();
        const a = v1.arena.allocator();
        var dir = try v1.t.tmp.dir.openDir(io, try std.Io.Dir.path.join(a, &.{ ".fx", "sessions", id, folder }), .{ .iterate = true });
        defer dir.close(io);
        var files: std.array_hash_map.String([]const u8) = .empty;
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| if (entry.kind == .file) {
            try files.put(a, try a.dupe(u8, entry.path), try dir.readFileAlloc(io, entry.path, a, .limited(1 << 24)));
        };
        return files;
    }

    /// `.fx/sessions/{id}/{rest}`, relative to the home. The arena's.
    fn sessionPath(v1: *V1Home, id: []const u8, rest: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(v1.arena.allocator(), &.{ ".fx", "sessions", id, rest });
    }

    fn exists(t: *TestHome, id: []const u8) bool {
        var buffer: [64]u8 = undefined;
        const path = std.mem.print(&buffer, ".fx/sessions/{s}", .{id}) catch unreachable;
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
        var dir = try t.tmp.dir.openDir(io, try std.mem.print(&buffer, ".fx/sessions/{s}", .{id}), .{ .iterate = true });
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
    // A finished turn, then one the user cancelled while its reply streamed.
    const id = (try v1.fixture("cancelled", 1))[0];
    const saved = try v1.metadata(id);
    const prompts = try v1.promptTimes(id);

    const s = try Session.resumeSession(testing.allocator, &t.store, .{ .id = id }, "/w", .ask);
    defer s.close();
    var restored = try s.restore(testing.allocator);
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), restored.history.len);
    try testing.expectEqualStrings("CONV_FIRST_ANSWER", restored.history[0].assistant.assistant);
    try testing.expectEqualStrings("CONV_PARTIAL", restored.history[1].interrupted.assistant.?);
    try testing.expectEqual(types.InterruptedTerminalReason.cancelled, restored.history[1].interrupted.terminal_reason);
    try testing.expectEqualStrings(saved.get("model").?.string, restored.preferences.?.model);
    try testing.expectEqual(saved.get("created_at_ms").?.integer, restored.created_at_ms);
    try testing.expectEqualStrings(saved.get("conversation_language").?.string, restored.language.bytes[0..restored.language.len]);
    try testing.expect(!V1Home.exists(&t, id));
    // Its turns kept their times.
    var page = try t.store.manager.read(testing.allocator, id, .start, .forward, 64);
    defer page.deinit();
    var starts: std.ArrayList(u64) = .empty;
    defer starts.deinit(testing.allocator);
    for (page.entries) |entry| if (entry.body) |body| if (body == .turn_started) try starts.append(testing.allocator, entry.ts_ms);
    try testing.expectEqualSlices(u64, prompts, starts.items);
}

test "a converted v1 session keeps its title, permission rules and preferences (D56)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // A saved-session allow rule the v1 app remembered.
    const id = (try v1.fixture("rules", 1))[0];
    const saved = try v1.metadata(id);

    const s = try openConverted(&t, id);
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    const title = try std.json.parseFromSliceLeaky([]const u8, v1.arena.allocator(), st.title.?, .{});
    try testing.expectEqualStrings(saved.get("title").?.string, title);
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const rules = restored.permission_state.?.rules.items;
    try testing.expectEqual(@as(usize, 1), rules.len);
    try testing.expectEqualStrings("shell.run touch conv-allowed", rules[0].display_identity);
    try testing.expect(rules[0].decision == .allow);
    try testing.expectEqualStrings(saved.get("model").?.string, restored.preferences.?.model);
}

test "a converted v1 session's side files keep their old names, and its prompt images become its blobs (D44, D47, D89)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // A prompt image, and the vision tool's result in a side file.
    const id = (try v1.fixture("image", 1))[0];
    const result_name = try v1.only(id, "tool-results");
    const result = try v1.file(id, "tool-results", result_name);
    const image_bytes = try v1.file(id, "images", try v1.only(id, "images"));

    const s = try openConverted(&t, id);
    defer s.close();
    const moved = try std.mem.concat(v1.arena.allocator(), u8, &.{ "tool-results/", result_name });
    const hash = s.host.moved.get(moved) orelse return error.TestUnexpectedResult;
    const body = try t.store.manager.getBlob(alloc, id, &hash);
    defer alloc.free(body);
    try testing.expectEqualStrings(result, body);
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const image = restored.history[0].assistant.user.images[0];
    try testing.expectEqual(@as(?[]u8, null), image.inline_data);
    {
        var read = try image_attachments.loadVerifiedSnapshot(alloc, image, .{});
        defer read.deinit(alloc);
        try testing.expectEqualSlices(u8, image_bytes, read.bytes);
    }
    // Its v1 file went with the folder. The converted prompt names the
    // image by its blob, listed on the user's item, as a new prompt does
    // (D89).
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image_bytes, &digest, .{});
    const image_hash = std.fmt.bytesToHex(digest, .lower);
    const blob_path = try t.store.manager.blobPath(alloc, id, &image_hash);
    defer alloc.free(blob_path);
    try testing.expectEqualStrings(blob_path, image.blob_path.?);
    try testing.expectEqual(@as(?[]u8, null), image.snapshot_path);
    try testing.expect(try userItemLists(&t, id, &image_hash));
}

test "a converted v1 session keeps its ACP client's prompt and tool identities (D46)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // A v1 ACP session with a client system prompt and an MCP tool.
    const id = (try v1.fixture("acp", 1))[0];
    const saved_prompt = try v1.file(id, "client", "system-prompt.txt");
    const saved_identities = try v1.file(id, "client", "mcp-tool-identities.json");

    const s = try openConverted(&t, id);
    defer s.close();
    const prompt = (try s.clientPrompt(alloc)).?;
    defer alloc.free(prompt);
    try testing.expectEqualStrings(saved_prompt, prompt);
    const identities = (try s.toolIdentities(alloc)).?;
    defer alloc.free(identities);
    try testing.expectEqualStrings(saved_identities, identities);
}

test "a converted v1 session's hosted terminal state lands where v2 keeps it (D45)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // A hosted terminal a v1 turn started, which ended with that process.
    const id = (try v1.fixture("terminal", 1))[0];
    const saved = try v1.tree(id, terminal_dir_name);
    try testing.expect(saved.count() > 0);

    const s = try openConverted(&t, id);
    defer s.close();
    for (saved.keys(), saved.values()) |path, bytes| {
        const moved = try std.Io.Dir.path.join(alloc, &.{ ".fx", terminal_dir_name, id, terminal_dir_name, path });
        defer alloc.free(moved);
        const state = try V1Home.read(&t, moved);
        defer alloc.free(state);
        try testing.expectEqualSlices(u8, bytes, state);
    }
}

test "a v1 session's hosted terminal folders an old fx left readable by others convert, private (D45)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const id = (try v1.fixture("terminal", 1))[0];
    const saved = try v1.tree(id, terminal_dir_name);
    try testing.expect(saved.count() > 0);
    // v1 opened these at any mode and made each private as it did.
    for ([_][]const u8{ "", "/state", "/proofs" }) |sub| {
        const path = try alloc.print("{s}/{s}{s}", .{ try v1.sessionPath(id, ""), terminal_dir_name, sub });
        defer alloc.free(path);
        var dir = try t.tmp.dir.openDir(io, path, .{});
        defer dir.close(io);
        dir.setPermissions(io, .fromMode(0o755)) catch return error.SkipZigTest;
    }

    const s = try openConverted(&t, id);
    defer s.close();
    for (saved.keys(), saved.values()) |path, bytes| {
        const moved = try std.Io.Dir.path.join(alloc, &.{ ".fx", terminal_dir_name, id, terminal_dir_name, path });
        defer alloc.free(moved);
        const state = try V1Home.read(&t, moved);
        defer alloc.free(state);
        try testing.expectEqualSlices(u8, bytes, state);
    }
    const moved = try std.Io.Dir.path.join(alloc, &.{ ".fx", terminal_dir_name, id, terminal_dir_name, "state" });
    defer alloc.free(moved);
    const stat = try t.tmp.dir.statFile(io, moved, .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "a v1 session whose hosted terminal state holds an entry the copy can't take converts without it, and its v1 folder keeps it (D56, D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const id = (try v1.fixture("terminal", 1))[0];
    var state = try t.tmp.dir.openDir(io, try v1.sessionPath(id, "terminal/state"), .{});
    defer state.close(io);
    state.symLink(io, "elsewhere", "stray-link", .{}) catch return error.SkipZigTest;

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 0), report.skipped.items.len);
    try testing.expectEqual(@as(usize, 1), report.left_out.items.len);
    const left = report.left_out.items[0].file;
    try testing.expectEqualStrings(id, left.member);
    try testing.expectEqualStrings("terminal/state/stray-link", left.file);
    try testing.expectEqual(LeftOut.Cause.not_regular, left.cause);
    // The rest of its terminal state is copied, the link is not.
    try testing.expect(pathExists(&t, &.{ ".fx", terminal_dir_name, id, "terminal", "state", "record-shell-P1Rx7ZvNXwWFA8DxO1uT2w.json" }));
    try testing.expect(!pathExists(&t, &.{ ".fx", terminal_dir_name, id, "terminal", "state", "stray-link" }));

    // Its v1 folder keeps the link, and a later run's cleanup keeps the
    // folder by what the copy recorded, even once the link is gone.
    var link: [64]u8 = undefined;
    try testing.expectEqualStrings("elsewhere", link[0..try state.readLink(io, "stray-link", &link)]);
    try state.deleteFile(io, "stray-link");
    var again = try convertAll(&t.store, alloc);
    defer again.deinit(alloc);
    try testing.expect(V1Home.exists(&t, id));
    var doctor_report = try doctor(&t.store, alloc, 64, 0);
    defer doctor_report.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), doctor_report.stuck.items.len);
    try testing.expectEqual(@as(usize, 0), doctor_report.unconverted);
    try testing.expectEqual(@as(usize, 1), doctor_report.keeps_left_out);
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
    const bytes = try alloc.print("{{\"conversation_seq\":{d},\"checkpoint\":{s}}}\n", .{ seq, encoded });
    defer alloc.free(bytes);
    try v1.put(id, null, "recovery.json", bytes);
}

test "a v1 turn left open comes back unfinished exactly as v1 shows it (D56)" {
    const alloc = testing.allocator;
    // A turn v1 left open when fx was killed mid-reply, its unfinished reply
    // in recovery.json; that turn without the checkpoint; and a finished
    // session whose checkpoint names a turn the log has since ended.
    for ([_]enum { checkpoint, open, stale }{ .checkpoint, .open, .stale }) |variant| {
        var t: TestHome = undefined;
        try t.init();
        defer t.deinit();
        var v1 = try V1Home.init(&t);
        defer v1.deinit();
        const id = (try v1.fixture(if (variant == .stale) "plain" else "unfinished", 1))[0];
        switch (variant) {
            .checkpoint => {},
            .open => try t.tmp.dir.deleteFile(io_mod.getIo(), try std.Io.Dir.path.join(v1.arena.allocator(), &.{ ".fx", "sessions", id, "recovery.json" })),
            // v1 drops a checkpoint inside a turn that ended at seq 3.
            .stale => try writeRecovery(&v1, id, 2, "CONV_FIRST 1", "never shown"),
        }

        const s = try openConverted(&t, id);
        defer s.close();
        var restored = try s.restore(alloc);
        defer restored.deinit(alloc);
        const last = restored.history[restored.history.len - 1];
        switch (variant) {
            .stale => {
                try testing.expectEqual(@as(usize, 1), restored.history.len);
                try testing.expectEqualStrings("CONV_FIRST_ANSWER", last.assistant.assistant);
            },
            .checkpoint, .open => {
                // No checkpoint: v1's next writable open fails the turn.
                try testing.expectEqualStrings("CONV_STALL", last.interrupted.user.text);
                try testing.expectEqual(types.InterruptedTerminalReason.failed, last.interrupted.terminal_reason);
                if (variant == .checkpoint) try testing.expectEqualStrings("CONV_PARTIAL_REPLY", last.interrupted.assistant.?);
            },
        }
    }
}

test "a compaction inside an open v1 turn that kept an earlier turn leaves out what it covered there (D87)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const a = v1.arena.allocator();
    const id = (try v1.fixture("unfinished", 1))[0];
    // The fixture's lines as v1 wrote them: a finished turn (seq 1 to 3), then
    // an open one with a tool step (4 to 7) that compacted (8), its reply in
    // recovery.json.
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, try v1.file(id, "", "events.jsonl"), '\n');
    while (it.next()) |line| if (line.len > 0) try lines.append(a, line);
    try testing.expectEqual(@as(usize, 8), lines.items.len);
    // Rebuilt so that the first turn runs two tool steps and the compaction in
    // the open turn covers only the first: it keeps the first turn from there.
    const Line = struct { from: usize, call: ?[]const u8 = null };
    const plan = [_]Line{
        .{ .from = 0 },               .{ .from = 5, .call = "c1" }, .{ .from = 6, .call = "c1" },
        .{ .from = 5, .call = "c2" }, .{ .from = 6, .call = "c2" }, .{ .from = 1 },
        .{ .from = 2 },               .{ .from = 3 },               .{ .from = 4 },
        .{ .from = 5 },               .{ .from = 6 },               .{ .from = 7 },
    };
    var events: std.Io.Writer.Allocating = .init(a);
    for (plan, 1..) |line, seq| {
        var text = try std.mem.replaceOwned(u8, a, lines.items[line.from], try a.print("\"seq\":{d},", .{line.from + 1}), try a.print("\"seq\":{d},", .{seq}));
        if (line.call) |call| text = try std.mem.replaceOwned(u8, a, text, "conv-stall-run", call);
        if (line.from == 7) text = try std.mem.replaceOwned(u8, a, text, "\"covers_through_seq\":7", "\"covers_through_seq\":3");
        try events.writer.print("{s}\n", .{text});
    }
    try v1.put(id, null, "events.jsonl", events.written());
    try v1.put(id, null, "recovery.json", try std.mem.replaceOwned(u8, a, try v1.file(id, "", "recovery.json"), "\"conversation_seq\":8", "\"conversation_seq\":12"));

    const s = try openConverted(&t, id);
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    // The summary, the first turn from its second step, and the open turn
    // whole from the checkpoint, as v1 shows them.
    try testing.expectEqual(@as(usize, 3), restored.history.len);
    const first = restored.history[1].assistant;
    try testing.expectEqualStrings("CONV_FIRST", first.user.text);
    try testing.expectEqual(@as(usize, 1), first.execution.tool_steps.len);
    try testing.expectEqualStrings("c2", first.execution.tool_steps[0].tool_calls[0].id);
    try testing.expectEqualStrings("CONV_PARTIAL_REPLY", restored.history[2].interrupted.assistant.?);
}

test "a v1 session another process holds answers busy, and converts nothing (D38)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 1);
    const v1_held_id = roots[0];
    {
        // Held as a v1 writer holds it.
        var v1_store = try session_store.Store.initReadOnlyFromHome(alloc, t.store.home, "/");
        defer v1_store.deinit(alloc);
        var holder = try v1_conversion.lockFamily(alloc, &v1_store, v1_held_id, 0, &t.store.problem);
        defer holder.release();
        try testing.expectError(error.SessionBusy, Session.resumeSessionWithoutWaiting(alloc, &t.store, .{ .id = v1_held_id }, "/w", .app));
        try testing.expectError(error.NotFound, t.store.manager.peek(alloc, v1_held_id));
        try testing.expect(V1Home.exists(&t, v1_held_id));
    }
    const s = try openConverted(&t, v1_held_id);
    s.close();
}

test "an unreadable v1 session is refused with its file and reason, and nothing is half converted (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 1);
    const v1_torn_id = roots[0];
    const log = try V1Home.read(&t, try v1.sessionPath(v1_torn_id, "events.jsonl"));
    defer alloc.free(log);
    const damaged = try std.mem.concat(alloc, u8, &.{ log, "{ not json\n" });
    defer alloc.free(damaged);
    try v1.put(v1_torn_id, null, "events.jsonl", damaged);

    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, v1_torn_id));
    const line = std.mem.count(u8, log, "\n") + 1;
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&buffer, "events.jsonl line {d} is not valid JSON", .{line}), t.store.conversionProblem().?);
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, v1_torn_id));
    // No staging left behind, if any was made.
    if (t.tmp.dir.openDir(io_mod.getIo(), ".fx/sessions/v2/.tmp", .{ .iterate = true })) |opened_staging| {
        var staging = opened_staging;
        defer staging.close(io_mod.getIo());
        var it = staging.iterate();
        try testing.expect(try it.next(io_mod.getIo()) == null);
    } else |err| try testing.expectEqual(error.FileNotFound, err);
    const after = try V1Home.read(&t, try v1.sessionPath(v1_torn_id, "events.jsonl"));
    defer alloc.free(after);
    try testing.expectEqualStrings(damaged, after);
}

test "recover salvages a damaged v1 session into a fresh v2 root and leaves its v1 folder as it was (D64)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // Two turns, then a torn line.
    const torn = (try v1.fixture("cancelled", 1))[0];
    const log = try V1Home.read(&t, try v1.sessionPath(torn, "events.jsonl"));
    defer alloc.free(log);
    const damaged = try std.mem.concat(alloc, u8, &.{ log, "{ not json\n" });
    defer alloc.free(damaged);
    try v1.put(torn, null, "events.jsonl", damaged);

    var recovered = try recover(&t.store, alloc, torn);
    defer recovered.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), recovered.history_len);
    try testing.expect(!std.mem.eql(u8, recovered.id, torn));
    var copy = try t.store.manager.peek(alloc, recovered.id);
    defer copy.deinit(alloc);
    try testing.expectEqual(sm.Role.root, copy.role);
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, torn));
    const after = try V1Home.read(&t, try v1.sessionPath(torn, "events.jsonl"));
    defer alloc.free(after);
    try testing.expectEqualStrings(damaged, after);

    const whole = (try v1.fixture("plain", 1))[0];
    try testing.expectError(error.SessionRecoveryNotNeeded, recover(&t.store, alloc, whole));
    try testing.expectError(error.SessionNotFound, recover(&t.store, alloc, "v1-none"));
}

test "recover copies a v1 conversation without saved rules it can't read and leaves its v1 folder as it was (D72)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const id = (try v1.fixture("rules", 1))[0];
    for ([_][]const u8{ "{broken", "" }) |rules| {
        try v1.put(id, null, "permissions.json", rules);
        // Resume still refuses to convert it.
        try testing.expectError(error.InvalidSessionFormat, openConverted(&t, id));
        var recovered = try recover(&t.store, alloc, id);
        defer recovered.deinit(alloc);
        try testing.expect(recovered.permission_rules_dropped);
        try testing.expectEqual(@as(usize, 1), recovered.history_len);
        try testing.expect(!std.mem.eql(u8, recovered.id, id));
        var copy = try t.store.manager.peek(alloc, recovered.id);
        defer copy.deinit(alloc);
        try testing.expectEqual(sm.Role.root, copy.role);
        const after = try V1Home.read(&t, try v1.sessionPath(id, "permissions.json"));
        defer alloc.free(after);
        try testing.expectEqualStrings(rules, after);
    }
}

test "doctor counts sessions an older fx saved and names each that can't be converted with what recover copies (D73)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    _ = try v1.fixture("plain", 3);
    const ruleless = (try v1.fixture("rules", 1))[0];
    try v1.put(ruleless, null, "permissions.json", "{broken");
    const torn = (try v1.fixture("cancelled", 1))[0];
    const log = try V1Home.read(&t, try v1.sessionPath(torn, "events.jsonl"));
    defer alloc.free(log);
    const damaged = try std.mem.concat(alloc, u8, &.{ log, "{ not json\n" });
    defer alloc.free(damaged);
    try v1.put(torn, null, "events.jsonl", damaged);

    var report = try doctor(&t.store, alloc, 100, io_mod.milliTimestamp());
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), report.sessions);
    try testing.expectEqual(@as(usize, 5), report.unconverted);
    try testing.expectEqual(@as(usize, 2), report.stuck.items.len);
    for (report.stuck.items) |stuck| {
        if (std.mem.eql(u8, stuck.id, ruleless)) {
            try testing.expect(stuck.recover == .without_rules);
            try testing.expect(std.mem.find(u8, stuck.reason, "permissions.json") != null);
        } else {
            try testing.expectEqualStrings(torn, stuck.id);
            try testing.expect(stuck.recover == .good_turns);
        }
    }
    // It converts nothing.
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, ruleless));
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, torn));
}

test "recover leaves out a kept side file that is gone or not the bytes its name records, and says so (D74)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // One command result under tool-results/, then a torn line.
    const id = (try v1.fixture("side", 1))[0];
    const log = try V1Home.read(&t, try v1.sessionPath(id, "events.jsonl"));
    defer alloc.free(log);
    const torn = try std.mem.concat(alloc, u8, &.{ log, "{ not json\n" });
    defer alloc.free(torn);
    try v1.put(id, null, "events.jsonl", torn);
    const artifact = "result-shell-70a192405eaee816-83e94389437f0489.txt";
    const original = try V1Home.read(&t, try v1.sessionPath(id, "tool-results/" ++ artifact));
    defer alloc.free(original);
    {
        var whole = try recover(&t.store, alloc, id);
        defer whole.deinit(alloc);
        try testing.expect(whole.files_complete);
    }
    const changed = try alloc.dupe(u8, original);
    defer alloc.free(changed);
    changed[0] ^= 1;
    for ([_]bool{ false, true }) |gone| {
        if (gone) {
            const path = try std.mem.concat(alloc, u8, &.{ ".fx/sessions/", id, "/tool-results/", artifact });
            defer alloc.free(path);
            try t.tmp.dir.deleteFile(io_mod.getIo(), path);
        } else try v1.put(id, "tool-results", artifact, changed);
        var recovered = try recover(&t.store, alloc, id);
        defer recovered.deinit(alloc);
        try testing.expect(!recovered.files_complete);
        const r = try Session.resumeSession(alloc, &t.store, .{ .id = recovered.id }, "/w", .ask);
        defer r.close();
        var restored = try r.restore(alloc);
        defer restored.deinit(alloc);
        const result = restored.history[0].assistant.execution.tool_steps[0].tool_results[0];
        try testing.expectEqualStrings("Saved tool-result content is unavailable. The complete output could not be restored.", result.output);
    }
}

test "latest resume says saved sessions are unreadable when only an unreadable v1 one exists (D76)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectError(error.NoSavedSessions, Session.resumeSession(testing.allocator, &t.store, .last, "/w", .ask));
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const id = (try v1.fixture("plain", 1))[0];
    try v1.put(id, null, "session.json", "{ not json");
    try testing.expectError(error.NoReadableSessions, Session.resumeSession(testing.allocator, &t.store, .last, "/w", .ask));
}

test "a leftover v1 folder goes on a later open only while it is what was converted (D60)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 1);
    const v1_left_id = roots[0];
    var copy = try V1Copy.take(&t, v1_left_id);
    defer copy.deinit();
    (try openConverted(&t, v1_left_id)).close();

    // As a refused delete leaves it: the next open deletes it.
    try copy.restore(&v1, v1_left_id);
    (try openConverted(&t, v1_left_id)).close();
    try testing.expect(!V1Home.exists(&t, v1_left_id));

    // Changed since by an older build: kept, and never reaches the v2 copy.
    try copy.restore(&v1, v1_left_id);
    try v1.put(v1_left_id, null, "events.jsonl", "changed\n");
    const s = try openConverted(&t, v1_left_id);
    defer s.close();
    try testing.expect(V1Home.exists(&t, v1_left_id));
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
}

test "-c opens the session v1 remembers while v2 has none, and --resume last the newest of both (D56, D61)" {
    const alloc = testing.allocator;
    // The v1 app last opened the first; the second is newer. Each half in
    // its own home: opening a session makes it the newest.
    for ([_]enum { remembered, newest }{ .remembered, .newest }) |half| {
        var t: TestHome = undefined;
        try t.init();
        defer t.deinit();
        var v1 = try V1Home.init(&t);
        defer v1.deinit();
        const ids = try v1.fixture("remembered", 2);
        switch (half) {
            .remembered => {
                const s = try Session.resumeSession(alloc, &t.store, .last_opened, v1.workspace, .app);
                defer s.close();
                try testing.expectEqualStrings(ids[0], s.id());
            },
            .newest => {
                {
                    // A v2 session older than the newest v1 one.
                    const s = try t.store.manager.openImport(.{ .id = "v2-older", .workspace = v1.workspace, .host = .ask, .created_ms = 1000 });
                    defer s.release();
                    _ = try s.appendAt(&.{ .turn_started, .turn_committed }, 5000);
                    try s.publishImport();
                }
                const s = try Session.resumeSession(alloc, &t.store, .last, v1.workspace, .ask);
                defer s.close();
                try testing.expectEqualStrings(ids[1], s.id());
            },
        }
    }
}

test "the picker's listing orders v2 sessions and v1's unconverted ones newest first together (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const newer = (try v1.fixture("plain", 1))[0];
    {
        // A v2 session older than the v1 one.
        const s = try t.store.manager.openImport(.{ .id = "v2-older", .workspace = v1.workspace, .host = .ask, .created_ms = 1000 });
        defer s.release();
        _ = try s.appendAt(&.{ .turn_started, .turn_committed }, 5000);
        try s.publishImport();
    }
    var cancel = std.atomic.Value(bool).init(false);
    var list = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings(newer, list.items[0].id);
    try testing.expectEqualStrings("v2-older", list.items[1].id);
}

test "-c says the remembered session cannot be read when v1's bookmark is not a file (D86)" {
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    _ = try v1.fixture("remembered", 1);
    // The bookmark becomes a folder, which v1's reader refuses as it does a FIFO.
    var bookmarks = try t.tmp.dir.openDir(io, profile_paths.root_dir_name ++ "/continue", .{ .iterate = true });
    defer bookmarks.close(io);
    var entries = bookmarks.iterate();
    const name = try v1.arena.allocator().dupe(u8, (try entries.next(io)).?.name);
    try bookmarks.deleteFile(io, name);
    try bookmarks.createDir(io, name, .fromMode(0o700));
    try testing.expectError(error.RememberedSessionUnavailable, Session.resumeSession(testing.allocator, &t.store, .last_opened, v1.workspace, .app));
}

test "the listing shows v1 sessions not converted yet, and fx session reads one without converting it (D59, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const listed = (try v1.fixture("plain", 1))[0];
    var cancel = std.atomic.Value(bool).init(false);
    var list = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings(listed, list.items[0].id);

    var detail = try readSession(&t.store, alloc, listed);
    defer detail.deinit(alloc);
    try testing.expectEqualStrings("CONV_FIRST 1", detail.state.history[0].assistant.user.text);
    try testing.expect(V1Home.exists(&t, listed));
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, listed));
}

test "the listing shows v1 roots, an empty one too, and never a child, by its flag or its owner marker (D59)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const plain = (try v1.fixture("plain", 1))[0];
    const empty = (try v1.fixture("empty", 1))[0];
    const family = try v1.fixture("family", 3);
    // A child from before the flag, known only by its owner marker.
    var older = try v1.metadata(family[2]);
    try older.put(v1.arena.allocator(), "subagent_child", .{ .bool = false });
    try v1.put(family[2], null, "session.json", try std.json.Stringify.valueAlloc(v1.arena.allocator(), std.json.Value{ .object = older }, .{}));

    var cancel = std.atomic.Value(bool).init(false);
    var list = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (list.items) |*summary| summary.deinit(alloc);
        list.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 3), list.items.len);
    for (list.items) |summary| {
        try testing.expect(std.mem.eql(u8, summary.id, plain) or std.mem.eql(u8, summary.id, empty) or std.mem.eql(u8, summary.id, family[0]));
    }
    const Listing = struct {
        fn run(failing: Allocator, home: []const u8) !void {
            var roots = try v1_conversion.listRoots(failing, home, null);
            defer roots.deinit(failing);
            try testing.expectEqual(@as(usize, 3), roots.summaries.items.len);
        }
    };
    try testing.checkAllAllocationFailures(testing_allocator.no_resize, Listing.run, .{t.store.home});
}

test "the listing's pages, read from part of the index, are the whole listing in v1's order, through a tie and v1's roots (D59, D62)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 2);
    // Tied on their update time: v2 orders them by id ascending, v1's pages
    // by id descending.
    for ([_][]const u8{ "tie-c", "tie-a", "tie-e", "tie-b", "tie-d" }) |id| {
        const s = try t.store.manager.openImport(.{ .id = id, .workspace = v1.workspace, .host = .ask, .created_ms = 1000 });
        defer s.release();
        _ = try s.appendAt(&.{ .turn_started, .turn_committed }, 5000);
        try s.publishImport();
    }
    // Converted, its v1 folder left behind as a refused delete leaves it:
    // listed once.
    const v1_held_id = roots[1];
    var copy = try V1Copy.take(&t, v1_held_id);
    defer copy.deinit();
    // Opened where v1 saved it, so it stays in that workspace.
    (try Session.resumeSession(alloc, &t.store, .{ .id = v1_held_id }, v1.workspace, .ask)).close();
    try copy.restore(&v1, v1_held_id);

    var cancel = std.atomic.Value(bool).init(false);
    var whole = try listSummaries(&t.store, alloc, null, &cancel);
    defer {
        for (whole.items) |*summary| summary.deinit(alloc);
        whole.deinit(alloc);
    }
    session_summary_codec.sortSummariesNewestFirst(whole.items);
    try testing.expectEqual(@as(usize, 7), whole.items.len);
    for ([_]?[]const u8{ null, v1.workspace }) |workspace| for ([_]usize{ 1, 2, 3 }) |limit| {
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

/// A legacy upgrade's pending authority fence for `id`, as v1 wrote it.
fn legacyFence(a: Allocator, id: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ "{\"schema_version\":1,\"session_id\":\"", id, "\",\"operation_id\":\"11111111111111111111111111111111\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"22222222222222222222222222222222\",\"prior\":{\"storage_format\":\"legacy_snapshot_v1\",\"primary_bytes\":1,\"primary_sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"proposed\":{\"storage_format\":\"event_log_v1\",\"log_generation\":\"33333333333333333333333333333333\",\"through_seq\":1,\"through_event_id\":\"44444444444444444444444444444444\",\"through_event_log_bytes\":1}}" });
}

test "a FIFO in a v1 session never blocks the listing or its conversion, which refuses it and keeps v1 (D68)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    const C = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    for ([_][]const u8{ "events.jsonl", "session.json", "permissions.json" }) |name| {
        var t: TestHome = undefined;
        try t.init();
        defer t.deinit();
        var v1 = try V1Home.init(&t);
        defer v1.deinit();
        const ids = try v1.fixture("plain", 2);
        const rel = try v1.sessionPath(ids[1], name);
        try t.tmp.dir.deleteFile(io, rel);
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (C.mkfifo(try std.mem.printSentinel(&buf, "{s}/{s}", .{ t.home, rel }, 0), 0o600) != 0) return error.SkipZigTest;
        // A blocking open of the FIFO would wait for a writer that never comes.
        var cancel = std.atomic.Value(bool).init(false);
        var list = try listSummaries(&t.store, alloc, null, &cancel);
        defer {
            for (list.items) |*summary| summary.deinit(alloc);
            list.deinit(alloc);
        }
        try testing.expectEqual(@as(usize, 2), list.items.len);
        try testing.expectError(error.InvalidSessionFormat, openConverted(&t, ids[1]));
        try testing.expect(V1Home.exists(&t, ids[1]));
        const s = try openConverted(&t, ids[0]);
        s.close();
    }
}

test "a v1 side folder that links elsewhere is refused, never followed, and v1 is kept (D68)" {
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const a = v1.arena.allocator();
    const id = (try v1.fixture("side", 1))[0];
    const rel = try v1.sessionPath(id, "tool-results");
    var files = try v1.tree(id, "tool-results");
    try testing.expect(files.count() > 0);
    try t.tmp.dir.createDirPath(io, "outside");
    var it = files.iterator();
    while (it.next()) |entry| try t.tmp.dir.writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ "outside", entry.key_ptr.* }), .data = entry.value_ptr.* });
    try t.tmp.dir.deleteTree(io, rel);
    try t.tmp.dir.symLink(io, "../../../outside", rel, .{ .is_directory = true });

    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, id));
    try testing.expect(V1Home.exists(&t, id));
    it = files.iterator();
    while (it.next()) |entry| {
        const kept = try t.tmp.dir.readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ "outside", entry.key_ptr.* }), a, .limited(1 << 24));
        try testing.expectEqualStrings(entry.value_ptr.*, kept);
    }
}

test "a legacy authority fence stops only an upgrade that never published, which keeps v1 (D70)" {
    const alloc = testing.allocator;
    const session_json = @import("session_json.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // Published: v0.0.14's own format, with a fence left behind.
    const published = (try v1.fixture("plain", 1))[0];
    try v1.put(published, null, "authority.pending.json", try legacyFence(v1.arena.allocator(), published));
    // Never published: the oldest format's snapshot under its fence.
    const snapshot = try session_json.renderSessionJson(alloc, "v1-fenced", 10, 20, types.ConversationLanguage.default(), "/w", &.{assistantTurn("old question", "old answer")}, .{});
    defer alloc.free(snapshot);
    try v1.put("v1-fenced", null, "session.json", snapshot);
    try v1.put("v1-fenced", null, "authority.pending.json", try legacyFence(v1.arena.allocator(), "v1-fenced"));

    const s = try openConverted(&t, published);
    s.close();
    try testing.expect(!V1Home.exists(&t, published));
    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, "v1-fenced"));
    try testing.expect(V1Home.exists(&t, "v1-fenced"));
}

test "an image the oldest format saved as only its path is captured from its file, or left out when it can't be (D82)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const a = v1.arena.allocator();
    const bytes = "\x89PNG\r\n\x1a\nkept";
    try t.tmp.dir.writeFile(io, .{ .sub_path = "kept.png", .data = bytes });
    const kept = try std.json.Stringify.valueAlloc(a, try io_mod.dirRealpathAlloc(a, t.tmp.dir, "kept.png"), .{});
    const gone = try std.json.Stringify.valueAlloc(a, try std.Io.Dir.path.join(a, &.{ try io_mod.dirRealpathAlloc(a, t.tmp.dir, "."), "gone.png" }), .{});
    try v1.put("v1-path-images", null, "session.json", try std.mem.concat(a, u8, &.{
        "{\"schema_version\":2,\"id\":\"v1-path-images\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/w\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"look [Image #1] [Image #2]\",\"images\":[{\"id\":1,\"path\":",
        kept,
        ",\"media_type\":\"image/png\"},{\"id\":2,\"path\":",
        gone,
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"seen\"}",
        "],\"total_input_tokens\":0,\"total_output_tokens\":0}",
    }));
    const s = try openConverted(&t, "v1-path-images");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const user = restored.history[0].assistant.user;
    // The prompt keeps its text; only the image whose file is gone is left out.
    try testing.expectEqualStrings("look [Image #1] [Image #2]", user.text);
    try testing.expectEqual(@as(usize, 1), user.images.len);
    try testing.expectEqual(@as(usize, 1), user.images[0].id);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), user.images[0].snapshot_sha256.?);
    // The captured image converts to the session's blob, as any does (D89).
    try testing.expect(user.images[0].blob_path != null);
    var read = try image_attachments.loadVerifiedSnapshot(alloc, user.images[0], .{});
    defer read.deinit(alloc);
    try testing.expectEqualSlices(u8, bytes, read.bytes);
}

test "images the oldest format saved without an id get the numbers v1's resume gave them (D69)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const a = v1.arena.allocator();
    var quoted: [4][]const u8 = undefined;
    for ([_][]const u8{ "first", "second", "valid", "nine" }, 0..) |name, i| {
        const file = try std.mem.concat(a, u8, &.{ name, ".png" });
        try t.tmp.dir.writeFile(io, .{ .sub_path = file, .data = try std.mem.concat(a, u8, &.{ "\x89PNG\r\n\x1a\n", name }) });
        quoted[i] = try std.json.Stringify.valueAlloc(a, try io_mod.dirRealpathAlloc(a, t.tmp.dir, file), .{});
    }
    try v1.put("v1-zero-ids", null, "session.json", try std.mem.concat(a, u8, &.{
        "{\"schema_version\":2,\"id\":\"v1-zero-ids\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/w\",\"conversation_language\":\"en\",\"history_len\":4,\"history\":[",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"first [Image #1]\",\"images\":[{\"path\":",
        quoted[0],
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"first answer\"},",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"second [Image #1]\",\"images\":[{\"path\":",
        quoted[1],
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"second answer\"},",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"existing [Image #3]\",\"images\":[{\"id\":3,\"path\":",
        quoted[2],
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"existing answer\"},",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"later [Image #9]\",\"images\":[{\"path\":",
        quoted[3],
        ",\"media_type\":\"image/png\"}]},\"assistant\":\"later answer\"}",
        "],\"total_input_tokens\":0,\"total_output_tokens\":0}",
    }));
    const s = try openConverted(&t, "v1-zero-ids");
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    const expected = [_]struct { id: usize, text: []const u8 }{
        .{ .id = 1, .text = "first [Image #1]" },
        .{ .id = 2, .text = "second [Image #2]" },
        .{ .id = 3, .text = "existing [Image #3]" },
        .{ .id = 9, .text = "later [Image #9]" },
    };
    try testing.expectEqual(expected.len, restored.history.len);
    for (expected, restored.history) |want, turn| {
        try testing.expectEqual(want.id, turn.assistant.user.images[0].id);
        try testing.expectEqualStrings(want.text, turn.assistant.user.text);
    }
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

test "fx sessions convert keeps a v1 subagent's own subagent as it is, and fx doctor names it too (D88)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const family = try v1.fixture("family", 3);
    const a = v1.arena.allocator();
    try nestThirdChild(&v1, family);
    const before = try v1.tree(family[2], ".");

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 0), report.skipped.items.len);
    const reason = try a.print("it is a subagent of the earlier subagent {s}, which no fx opens", .{family[1]});
    try testing.expectEqual(@as(usize, 1), report.kept_children.len);
    try testing.expectEqualStrings(family[2], report.kept_children[0].id);
    try testing.expectEqualStrings(reason, report.kept_children[0].reason);
    // Its folder is as it was.
    const after = try v1.tree(family[2], ".");
    try testing.expectEqual(before.count(), after.count());
    for (before.keys(), before.values()) |path, bytes| try testing.expectEqualStrings(bytes, after.get(path).?);

    var doctor_report = try doctor(&t.store, alloc, 64, 0);
    defer doctor_report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), doctor_report.kept_children.len);
    try testing.expectEqualStrings(family[2], doctor_report.kept_children[0].id);
    try testing.expectEqualStrings(reason, doctor_report.kept_children[0].reason);
}

test "fx sessions convert says a v1 subagent's own subagent stays with a parent it can't read (D88)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const family = try v1.fixture("family", 3);
    try nestThirdChild(&v1, family);
    var parent = try t.tmp.dir.openDir(io, try v1.sessionPath(family[1], "."), .{});
    defer parent.close(io);
    parent.setFilePermissions(io, "session.json", .fromMode(0o000), .{}) catch return error.SkipZigTest;
    defer parent.setFilePermissions(io, "session.json", .fromMode(0o600), .{}) catch {};
    // Not when the file still opens, as it does for root.
    if (parent.readFileAlloc(io, "session.json", alloc, .limited(1 << 20))) |bytes| {
        alloc.free(bytes);
        return error.SkipZigTest;
    } else |_| {}

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.kept_children.len);
    try testing.expectEqualStrings(family[2], report.kept_children[0].id);
    var expected: [160]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&expected, "its parent session {s} can't be read, so it stays with it", .{family[1]}), report.kept_children[0].reason);
}

/// Makes `family`'s third member the second's own subagent, as fx made
/// them before a subagent lost the subagent tool.
fn nestThirdChild(v1: *V1Home, family: []const []const u8) !void {
    const a = v1.arena.allocator();
    var registry = try std.json.parseFromSliceLeaky(std.json.Value, a, try v1.file(family[0], "subagent", "children.json"), .{});
    const children = &registry.object.getPtr("children").?.array;
    for (children.items, 0..) |child, index| {
        if (std.mem.eql(u8, child.object.get("id").?.string, family[2])) {
            _ = children.orderedRemove(index);
            break;
        }
    } else return error.TestUnexpectedResult;
    try v1.put(family[0], "subagent", "children.json", try std.json.Stringify.valueAlloc(a, registry, .{}));
    try v1.put(family[2], "subagent", "owner.json", try a.print("{{\"schema_version\":1,\"parent_id\":\"{s}\"}}", .{family[1]}));
}

test "fx sessions convert says a converted v1 child whose folder a cleanup kept is converted already (D60, D88)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const family = try v1.fixture("family", 3);
    const child = family[1];
    var copy = try V1Copy.take(&t, child);
    defer copy.deinit();
    const owner = try v1.file(child, "subagent", "owner.json");
    const s = try openConverted(&t, family[0]);
    s.close();
    try testing.expect(!V1Home.exists(&t, child));
    // The child's folder as a cleanup keeps it when an older fx changed it
    // after its conversion: its parent's folder is gone.
    try copy.restore(&v1, child);
    try v1.put(child, "subagent", "owner.json", owner);

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.kept_children.len);
    try testing.expectEqualStrings(child, report.kept_children[0].id);
    try testing.expectEqualStrings("fx converted it already, so anything an older fx added since stays only in this folder", report.kept_children[0].reason);
}

test "a kept subagent's reason names what its copy left out, one file by name and more by count (D62)" {
    const alloc = testing.allocator;
    const one = [_]V1Source.Record{.{ .file = "logs/commands/replay.bin", .cause = .too_large }};
    const two = [_]V1Source.Record{ one[0], .{ .file = "terminal/state/link", .cause = .not_regular } };
    const cases = [_]struct { source: ?V1Source, reason: []const u8 }{
        .{ .source = null, .reason = "fx converted it already, so anything an older fx added since stays only in this folder" },
        .{ .source = .{ .fingerprint = "f" }, .reason = "fx converted it already, so anything an older fx added since stays only in this folder" },
        .{ .source = .{ .left_out = &one, .left_out_total = 1 }, .reason = "fx converted it already without logs/commands/replay.bin, so this folder keeps it" },
        .{ .source = .{ .left_out = &two, .left_out_total = 2 }, .reason = "fx converted it already without 2 of its files, so this folder keeps them" },
        // A copy names the first files only; the count is all of them.
        .{ .source = .{ .left_out = &two, .left_out_total = 33 }, .reason = "fx converted it already without 33 of its files, so this folder keeps them" },
        .{ .source = .{ .left_out_total = 1 }, .reason = "fx converted it already without 1 of its files, so this folder keeps them" },
    };
    for (cases) |case| {
        const reason = try convertedReason(alloc, case.source);
        defer alloc.free(reason);
        try testing.expectEqualStrings(case.reason, reason);
    }
}

test "a copy names the first files it left out and counts them all (D56, D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const id = (try v1.fixture("terminal", 1))[0];
    var state = try t.tmp.dir.openDir(io, try v1.sessionPath(id, "terminal/state"), .{});
    defer state.close(io);
    const total = V1Source.max_records + 1;
    for (0..total) |index| {
        var name: [32]u8 = undefined;
        state.symLink(io, "elsewhere", try std.mem.print(&name, "link-{d}", .{index}), .{}) catch return error.SkipZigTest;
    }

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, total), report.left_out.items.len);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const peeked = try t.store.manager.peek(scratch.allocator(), id);
    const source = parseV1Source(scratch.allocator(), peeked.state.v1_source).?;
    try testing.expectEqualStrings("", source.fingerprint);
    try testing.expectEqual(@as(usize, V1Source.max_records), source.left_out.len);
    try testing.expectEqual(@as(usize, total), source.left_out_total);
    try testing.expect(V1Home.exists(&t, id));
}

test "fx doctor counts each v1 folder a family's conversion kept, a subagent's included (D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const family = try v1.fixture("family", 2);
    for (family) |id| {
        var commands = try t.tmp.dir.createDirPathOpen(io, try v1.sessionPath(id, "logs/commands"), .{});
        defer commands.close(io);
        var file = try commands.createFile(io, "replay.bin", .{});
        defer file.close(io);
        // Sparse: no disk for the hole.
        try file.setLength(io, sm.max_blob_bytes + 1);
    }
    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 2), report.left_out.items.len);
    for (family) |id| try testing.expect(V1Home.exists(&t, id));
    var doctor_report = try doctor(&t.store, alloc, 64, 0);
    defer doctor_report.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), doctor_report.keeps_left_out);
    // Each copy names what it left out and keeps no fingerprint, which an
    // older fx would match to remove the folder.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    for (family) |id| {
        const peeked = try t.store.manager.peek(scratch.allocator(), id);
        const source = parseV1Source(scratch.allocator(), peeked.state.v1_source).?;
        try testing.expectEqualStrings("", source.fingerprint);
        try testing.expectEqual(@as(usize, 1), source.left_out.len);
        try testing.expectEqualStrings("logs/commands/replay.bin", source.left_out[0].file);
        try testing.expectEqual(LeftOut.Cause.too_large, source.left_out[0].cause);
        try testing.expectEqual(@as(u64, sm.max_blob_bytes + 1), source.left_out[0].bytes);
    }
}

test "fx sessions convert says when it can't read a kept v1 child's converted copy (D88)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const family = try v1.fixture("family", 3);
    const child = family[1];
    var copy = try V1Copy.take(&t, child);
    defer copy.deinit();
    const owner = try v1.file(child, "subagent", "owner.json");
    const s = try openConverted(&t, family[0]);
    s.close();
    try copy.restore(&v1, child);
    try v1.put(child, "subagent", "owner.json", owner);
    // The converted copy is damaged since.
    var copied = try t.tmp.dir.openDir(io, try std.Io.Dir.path.join(v1.arena.allocator(), &.{ ".fx", "sessions", "v2", child }), .{});
    defer copied.close(io);
    try copied.writeFile(io, .{ .sub_path = "log.jsonl", .data = "not a log\n" });

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.kept_children.len);
    try testing.expectEqualStrings(child, report.kept_children[0].id);
    try testing.expect(std.mem.startsWith(u8, report.kept_children[0].reason, "fx can't read its converted copy ("));
}

test "fx sessions convert converts every v1 family, and counts what it skipped (D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 3);
    const v1_plain_id = roots[0];
    const v1_busy_id = roots[1];
    const v1_bad_id = roots[2];
    try v1.put(v1_bad_id, null, "events.jsonl", "{ not json\n");
    // Held as a v1 writer holds it.
    var v1_store = try session_store.Store.initReadOnlyFromHome(alloc, t.store.home, "/");
    defer v1_store.deinit(alloc);
    var holder = try v1_conversion.lockFamily(alloc, &v1_store, v1_busy_id, 0, &t.store.problem);
    defer holder.release();

    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.converted);
    try testing.expectEqual(@as(usize, 1), report.busy);
    try testing.expectEqual(@as(usize, 1), report.unreadable);
    for (report.skipped.items) |skipped| {
        const busy = std.mem.eql(u8, skipped.id, v1_busy_id);
        try testing.expectEqualStrings(if (busy) "SessionBusy" else "InvalidSessionFormat", skipped.code);
        if (!busy) try testing.expectEqualStrings("events.jsonl line 1 is not valid JSON", skipped.reason.?);
    }
    var plain = try t.store.manager.peek(alloc, v1_plain_id);
    plain.deinit(alloc);
}

test "a v1 profile an old release left readable by others converts (D61)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 1);
    const v1_open_id = roots[0];
    for ([_][]const u8{ ".fx", ".fx/sessions", try v1.sessionPath(v1_open_id, "") }) |path| {
        var dir = try t.tmp.dir.openDir(io, path, .{});
        defer dir.close(io);
        dir.setPermissions(io, .fromMode(0o755)) catch return error.SkipZigTest;
    }
    const s = try openConverted(&t, v1_open_id);
    defer s.close();
    var restored = try s.restore(alloc);
    defer restored.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), restored.history.len);
    try testing.expect(!V1Home.exists(&t, v1_open_id));
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
    // A family whose root keeps no registry, so its child comes from the
    // older relationship index.
    const ids = try v1.fixture("family", 2);
    const old_root = ids[0];
    const old_kid = ids[1];
    try t.tmp.dir.deleteFile(io_mod.getIo(), try v1.sessionPath(old_root, "subagent/children.json"));
    const header = try relationship_index_codec.encodeHeader(alloc, .{ .high_watermark = 1, .active_count = 1 });
    defer alloc.free(header);
    try v1.put(old_root, "subagent", "relationship-index.bin", header);
    const page = try relationshipPage(alloc, old_kid);
    defer alloc.free(page);
    try v1.put(old_root, "subagent", &relationship_index_codec.pageFileName(0), page);

    const s = try openConverted(&t, old_root);
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), st.children.items.len);
    var kid = try t.store.manager.peek(alloc, old_kid);
    defer kid.deinit(alloc);
    try testing.expectEqualStrings(old_root, kid.parent.?);
    try testing.expect(!V1Home.exists(&t, old_root) and !V1Home.exists(&t, old_kid));
}

test "a v1 family converts together: its children first, and one whose folder is gone recorded lost (D33, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    // The root and its first child; the registry also names a second child,
    // whose folder is gone.
    const ids = try v1.fixture("family", 2);
    const parent = ids[0];
    const kid = ids[1];

    // A v1 child opens only through its parent.
    try testing.expectError(error.SessionNotFound, openConverted(&t, kid));
    const s = try openConverted(&t, parent);
    defer s.close();
    var st = try s.handle.state(alloc);
    defer st.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), st.children.items.len);
    for (st.children.items) |child| {
        const expected: sm.Outcome = if (std.mem.eql(u8, child.id, kid)) .ok else .lost;
        try testing.expectEqual(expected, child.outcome.?);
    }
    var converted = try t.store.manager.peek(alloc, kid);
    defer converted.deinit(alloc);
    try testing.expectEqual(sm.Role.child, converted.role);
    try testing.expectEqualStrings(parent, converted.parent.?);
    try testing.expect(!V1Home.exists(&t, parent) and !V1Home.exists(&t, kid));
}

test "a child an earlier try published is reused as it is, its v1 folder kept once v1 changed it (D60, D61)" {
    const alloc = testing.allocator;
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const ids = try v1.fixture("family", 3);
    const root = ids[0];
    const same = ids[1];
    const changed_id = ids[2];
    // A try that published the children and stopped before the root.
    {
        var v1_store = try session_store.Store.initReadOnlyFromHome(alloc, t.store.home, "/");
        defer v1_store.deinit(alloc);
        var locks = try v1_conversion.lockFamily(alloc, &v1_store, root, 0, &t.store.problem);
        defer locks.release();
        var c: Conversion = .{ .store = &t.store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
        for (locks.members.items[1..]) |*member| {
            var checked = try c.check(&v1_store, member, root, false, false);
            const staged = try c.stage(&v1_store, &checked, member, .{ .child = .{ .parent = root, .instructions = null } });
            defer staged.session.?.dropImport();
            try staged.session.?.handle.publishImport();
        }
    }
    // An older build changes one child since; a damaged one reads the same.
    try v1.put(changed_id, null, "events.jsonl", "{ not json\n");

    const s = try openConverted(&t, root);
    defer s.close();
    var changed = try t.store.manager.peek(alloc, changed_id);
    defer changed.deinit(alloc);
    try testing.expectEqual(sm.Role.child, changed.role);
    try testing.expect(V1Home.exists(&t, changed_id));
    try testing.expect(!V1Home.exists(&t, same) and !V1Home.exists(&t, root));
}

test "a child an earlier try published keeps its v1 folder when that try left a file of it out (D60, D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const ids = try v1.fixture("family", 2);
    const root = ids[0];
    const child = ids[1];
    {
        var commands = try t.tmp.dir.createDirPathOpen(io, try v1.sessionPath(child, "logs/commands"), .{});
        defer commands.close(io);
        var file = try commands.createFile(io, "replay.bin", .{});
        defer file.close(io);
        // Sparse: no disk for the hole.
        try file.setLength(io, sm.max_blob_bytes + 1);
    }
    // A try that published the child, leaving the file out, and stopped
    // before the root.
    {
        var v1_store = try session_store.Store.initReadOnlyFromHome(alloc, t.store.home, "/");
        defer v1_store.deinit(alloc);
        var locks = try v1_conversion.lockFamily(alloc, &v1_store, root, 0, &t.store.problem);
        defer locks.release();
        var c: Conversion = .{ .store = &t.store, .alloc = alloc, .host = .ask, .started = io_mod.nanoTimestamp() };
        defer c.deinit();
        var checked = try c.check(&v1_store, &locks.members.items[1], root, false, false);
        const staged = try c.stage(&v1_store, &checked, &locks.members.items[1], .{ .child = .{ .parent = root, .instructions = null } });
        defer staged.session.?.dropImport();
        try staged.session.?.handle.publishImport();
        try testing.expect(staged.keeps);
    }

    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(alloc);
    t.store.notice = .{ .context = &told, .emit = struct {
        fn emit(context: ?*anyopaque, text: []const u8) void {
            const out: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?));
            out.appendSlice(testing.allocator, text) catch {};
        }
    }.emit };
    const s = try openConverted(&t, root);
    defer s.close();
    try testing.expect(!V1Home.exists(&t, root));
    const stat = try t.tmp.dir.statFile(io, try v1.sessionPath(child, "logs/commands/replay.bin"), .{});
    try testing.expectEqual(@as(u64, sm.max_blob_bytes + 1), stat.size);
    // The open names what the earlier try left out, as that try would have.
    var expected: [320]u8 = undefined;
    try testing.expect(std.mem.find(u8, told.items, try std.mem.print(&expected, "converted without logs/commands/replay.bin of its subagent {s} because", .{child})) != null);

    // fx sessions convert names the kept folder and what it keeps.
    var report = try convertAll(&t.store, alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), report.kept_children.len);
    try testing.expectEqualStrings(child, report.kept_children[0].id);
    try testing.expectEqualStrings("fx converted it already without logs/commands/replay.bin, so this folder keeps it", report.kept_children[0].reason);
    // fx doctor counts that folder, though its root's folder is gone.
    var doctor_report = try doctor(&t.store, alloc, 64, 0);
    defer doctor_report.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), doctor_report.keeps_left_out);
}

test "a v1 session whose session.json is damaged names that file, whatever registry it has (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const ids = try v1.fixture("family", 2);
    try v1.put(ids[0], null, "session.json", "{ not json");
    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, ids[0]));
    try testing.expectEqualStrings("session.json is not valid JSON", t.store.conversionProblem().?);
    try testing.expect(V1Home.exists(&t, ids[0]) and V1Home.exists(&t, ids[1]));
}

test "a root with a registry converts its children from it, never from a relationship index too (D61)" {
    const alloc = testing.allocator;
    const relationship_index_codec = @import("session_relationship_index_codec.zig");
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const ids = try v1.fixture("family", 3);
    const both = ids[0];
    const listed_kid = ids[1];
    const indexed_kid = ids[2];
    // The registry keeps only the first child; the index names the second.
    const a = v1.arena.allocator();
    var registry = try std.json.parseFromSliceLeaky(std.json.Value, a, try v1.file(both, "subagent", "children.json"), .{});
    const children = &registry.object.getPtr("children").?.array;
    var kept: usize = 0;
    for (children.items) |child| if (!std.mem.eql(u8, child.object.get("id").?.string, indexed_kid)) {
        children.items[kept] = child;
        kept += 1;
    };
    children.shrinkRetainingCapacity(kept);
    try v1.put(both, "subagent", "children.json", try std.json.Stringify.valueAlloc(a, registry, .{}));
    const header = try relationship_index_codec.encodeHeader(alloc, .{ .high_watermark = 1, .active_count = 1 });
    defer alloc.free(header);
    try v1.put(both, "subagent", "relationship-index.bin", header);
    const page = try relationshipPage(alloc, indexed_kid);
    defer alloc.free(page);
    try v1.put(both, "subagent", &relationship_index_codec.pageFileName(0), page);

    (try openConverted(&t, both)).close();
    var listed = try t.store.manager.peek(alloc, listed_kid);
    listed.deinit(alloc);
    try testing.expectError(error.NotFound, t.store.manager.peek(alloc, indexed_kid));
    try testing.expect(V1Home.exists(&t, indexed_kid));
}

test "the sweep drops what an earlier try staged for a child whose folder is gone since (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const ids = try v1.fixture("family", 2);
    const parent = ids[0];
    const went = ids[1];
    const staging = try t.store.manager.openImport(.{ .id = went, .workspace = "/w", .host = .ask, .role = .child, .parent = parent, .created_ms = 1 });
    // An import's staging appears with its first blob.
    _ = try staging.putBlob("staged before the folder went");
    staging.release();
    try t.tmp.dir.deleteTree(io_mod.getIo(), try v1.sessionPath(went, ""));
    const staged = try std.Io.Dir.path.join(v1.arena.allocator(), &.{ ".fx", "sessions", "v2", ".tmp", went });
    _ = try t.tmp.dir.statFile(io_mod.getIo(), staged, .{});

    (try openConverted(&t, parent)).close();
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io_mod.getIo(), staged, .{}));
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
    const roots = try v1.fixture("plain", 1);
    const v1_torn_once_id = roots[0];
    try v1.put(v1_torn_once_id, null, "events.jsonl", "{ not json\n");
    try testing.expectError(error.InvalidSessionFormat, openConverted(&t, v1_torn_once_id));
    try testing.expect(t.store.conversionProblem() != null);
    try testing.expectError(error.SessionNotFound, openConverted(&t, "nowhere"));
    try testing.expect(t.store.conversionProblem() == null);
}

test "a v1 prompt image that cannot be read refuses the session, and one that is gone keeps its path (D61)" {
    const alloc = testing.allocator;
    for ([_]enum { unreadable, gone }{ .unreadable, .gone }) |variant| {
        var t: TestHome = undefined;
        try t.init();
        defer t.deinit();
        var v1 = try V1Home.init(&t);
        defer v1.deinit();
        const id = (try v1.fixture("image", 1))[0];
        const a = v1.arena.allocator();
        const snapshot = try std.mem.concat(a, u8, &.{ "images/", try v1.only(id, "images") });
        const on_disk = try v1.sessionPath(id, snapshot);
        try t.tmp.dir.deleteFile(io_mod.getIo(), on_disk);
        switch (variant) {
            .unreadable => {
                // A folder where the image should be: not a lost snapshot, a fault.
                try t.tmp.dir.createDirPath(io_mod.getIo(), on_disk);
                try testing.expectError(error.InvalidSessionFormat, openConverted(&t, id));
                // Refused at the open: never read through anything but a regular file.
                try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ snapshot, " can't be read (DurablePathUnsafe)" }), t.store.conversionProblem().?);
                try testing.expect(V1Home.exists(&t, id));
            },
            .gone => {
                const s = try openConverted(&t, id);
                defer s.close();
                var restored = try s.restore(alloc);
                defer restored.deinit(alloc);
                try testing.expectEqualStrings(snapshot, restored.history[0].assistant.user.images[0].snapshot_path.?);
            },
        }
    }
}

test "a new session never takes an id v1's folder could not be checked for (D61)" {
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    const io = io_mod.getIo();
    try t.tmp.dir.createDirPath(io, ".fx/sessions");
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
    const roots = try v1.fixture("plain", 2);
    const v1_unknown_id = roots[1];
    try v1.put(v1_unknown_id, null, "session.json", "{ not json");

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
    try testing.expectEqualStrings(v1_unknown_id, report.skipped.items[0].id);
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

test "a v1 side file larger than one v2 blob is left out and named, its v1 folder keeps it, and the rest of its session converts and continues (D62)" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var t: TestHome = undefined;
    try t.init();
    defer t.deinit();
    var v1 = try V1Home.init(&t);
    defer v1.deinit();
    const roots = try v1.fixture("plain", 2);
    for (roots) |id| {
        var commands = try t.tmp.dir.createDirPathOpen(io, try v1.sessionPath(id, "logs/commands"), .{});
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
    const s = try openConverted(&t, roots[0]);
    defer s.close();
    var expected: [320]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&expected, "This session was converted without logs/commands/replay.bin because it is {d} bytes, more than the {d} the new store keeps in one file. Its earlier folder ~/.fx/sessions/{s} keeps it.", .{ sm.max_blob_bytes + 1, sm.max_blob_bytes, roots[0] }), told.items);
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
    try testing.expectEqualStrings(roots[1], left.id);
    try testing.expectEqualStrings(roots[1], left.file.member);
    try testing.expectEqualStrings("logs/commands/replay.bin", left.file.file);
    try testing.expectEqual(@as(u64, sm.max_blob_bytes + 1), left.file.bytes);

    // Each v1 folder keeps the file it alone holds, and a later run, whose
    // cleanup removes a converted session's v1 folder, keeps it too, by
    // what the copy recorded: even once the file is small enough.
    var small = try t.tmp.dir.openFile(io, try v1.sessionPath(roots[0], "logs/commands/replay.bin"), .{ .mode = .read_write });
    try small.setLength(io, 1);
    small.close(io);
    var again = try convertAll(&t.store, alloc);
    defer again.deinit(alloc);
    for (roots) |id| try testing.expect(V1Home.exists(&t, id));
    try testing.expectEqual(@as(u64, sm.max_blob_bytes + 1), (try t.tmp.dir.statFile(io, try v1.sessionPath(roots[1], "logs/commands/replay.bin"), .{})).size);
    var doctor_report = try doctor(&t.store, alloc, 64, 0);
    defer doctor_report.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), doctor_report.keeps_left_out);
}

test "only the adapter imports the session manager" {
    // Set by `zig build test`.
    const root = @import("test_paths").source_root;
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
