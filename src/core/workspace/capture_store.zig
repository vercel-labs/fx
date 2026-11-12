//! One workspace capture of a git repository into fx's own store.
//!
//! Each repository gets a bare store under the profile, keyed by its common
//! git directory, with alternates into the user's objects, so hashing a file
//! the user's git already holds writes nothing. The store still holds its
//! own compressed copy of every object its captures reach (see below), so it
//! grows to about the size of the worktree's tree, packed, plus what changed
//! since. Each worktree, named by its git directory and its work tree
//! (`worktreeIdentity`), gets its own capture index, lock and scratch
//! directory. A capture lists the worktree, applies `workspace_capture`'s
//! policy, writes a tree, and appends a commit to the ref for the session and
//! worktree, `refs/fx/sessions/<session key>/<worktree key>`, with
//! compare-and-swap, and `encodeRecord` turns the outcome into the session's
//! `workspace_capture` item (D98). git reads the user's repository through
//! `safe_git`'s read-only route, and the store reads the user's objects
//! through its alternates. fx itself reads the index file to copy it and
//! checks a few files in the git directory, and opens only regular files of
//! bounded size, so a pipe or device there cannot stall it. The one write
//! that reaches the user's repository is git's own freshening: when the store
//! hashes a file whose object the user's objects folder already holds, git
//! updates the modification time of that loose object or of the pack holding
//! it instead of writing a copy. It never changes their content, and git
//! offers no setting to turn it off.
//!
//! A capture never depends on the user's objects. Its tree can name objects
//! only the user's repository holds, such as a staged blob or a file of a
//! branch the user may delete and prune. Before the ref moves, the capture
//! copies into the store every object its tree reaches that the parent
//! capture's tree does not (`copyObjects`), so every commit a capture ref
//! names is readable with the alternates gone. A capture with no parent
//! leaves out what the store's newest captures hold instead, so until the
//! store holds a capture, a copy takes the whole tree. The copy writes packs
//! of at most `copy_batch_objects` objects and skips what the store already
//! holds itself, loose or in its own packs, so the packs an interrupted copy
//! finished are kept and the next capture goes on from there. A copy that
//! cannot finish leaves the ref where it was and the capture reports no
//! tree: `timeout` at the deadline, `io_error` for another failure.
//! Objects the store wrote itself stay loose and are not copied again.
//! Retention keeps both: its `gc` and `repack` store commands repack
//! everything with `repack -a -d` and without `-l`, which `git gc` always
//! passes and which would drop every object the alternates also hold, and
//! only then delete loose objects. Capture commits link only to earlier
//! captures, never to the user's, so the store takes in no user history.
//!
//! The caller passes one deadline and, optionally, a cancel flag. Every git
//! run, lock wait and the untracked listing stop at them. A capture runs on
//! a longer one-time budget instead (`first_capture_budget_ms`) while the
//! store, the worktree's capture index or any capture ref is missing: it
//! creates them, writes the objects the store lacks and copies every object
//! of its tree, which in a large repository takes longer than a turn's
//! budget allows. That lasts until a capture lands, however many runs out
//! of time first.
//!
//! A path whose presence decides whether the store or capture index is
//! created counts as missing only when the system says it does not exist.
//! Any other answer, such as a permission error or a cancel, fails the
//! capture, so a store is never replaced because a check could not see it.
//!
//! A folder that git hands to another checkout's git directory is
//! `foreign_git_dir`: a `.git` symlink, a `gitdir:` file into another
//! checkout's `.git` folder, or one into a linked worktree's git directory
//! that names another `.git` file. A separate git directory, such as one
//! `git init --separate-git-dir` makes, records no work tree, so git's view is
//! taken as it is; its worktree key includes the work tree, so two folders
//! that point at it never share a capture index or a ref.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const indexer = @import("../indexer/indexer.zig");
const policy = @import("workspace_capture.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

/// The repository a capture read, as absolute paths with every symlink
/// resolved, so two spellings of one repository name the same one.
pub const Repository = struct {
    /// Root of the worktree being captured.
    work_tree: []const u8,
    /// This worktree's git directory (`.git`, or `.git/worktrees/<name>`).
    git_dir: []const u8,
    /// The common git directory that holds the objects.
    common_dir: []const u8,
};

pub const Phase = enum { start, end };

pub const Request = struct {
    /// The fx profile root, such as `~/.fx`.
    profile_root: []const u8,
    /// An absolute folder inside the worktree to capture, such as the
    /// session's working directory. The whole worktree that holds it is
    /// captured, and `Outcome.repository` names it.
    path: []const u8,
    /// fx's session id, `[A-Za-z0-9._-]{1,255}` not starting with `.`.
    /// The ref names it by a hash, so every valid id fits git's ref rules.
    session_id: []const u8,
    phase: Phase,
    unix_seconds: i64,
    /// One budget for the whole capture, shared by every git command, lock
    /// wait and the untracked listing; a worktree's first capture may extend
    /// it (`first_capture_budget_ms`).
    deadline: std.Io.Clock.Timestamp,
    limits: policy.Limits = .{},
    /// Thread-safe allocator for the native indexer, which lists folders on
    /// several threads, and for the copy's pack indexes. Its memory is freed
    /// before `capture` returns.
    scan_allocator: Allocator,
    /// The host's cancel flag for the turn. Once set, the running git ends
    /// within `safe_git`'s poll, no further git starts, and lock waits stop;
    /// the capture is `cancelled`. It reaches git even when a `std.Io` cancel
    /// was already spent.
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Status = enum { complete, partial, failed, unavailable };

/// HEAD as the capture saw it: not read, a repository with no commit yet,
/// or a commit.
pub const Head = union(enum) { unknown, unborn, commit: []const u8 };

/// Where the untracked listing came from.
pub const Listing = enum { indexer, git };

/// How the capture index started: a copy of the user's index, a rebuild
/// from HEAD (split index), or this worktree's index from a previous capture.
pub const IndexStart = enum { copied, rebuilt, persisted };

/// What one capture did. A field stays at its default when the capture
/// stopped before measuring it, so a failure never claims a fact it did not
/// see.
pub const Outcome = struct {
    status: Status,
    /// Set for every status but `complete`.
    reason: ?policy.Reason = null,
    /// Set once git has resolved the repository.
    repository: ?Repository = null,
    /// The ref the capture extends, set with `repository`.
    ref: ?[]const u8 = null,
    head: Head = .unknown,
    object_format: ?safe_git.ObjectFormat = null,
    listing: ?Listing = null,
    index: ?IndexStart = null,
    /// Set for `complete` and `partial`.
    tree: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    /// Whether the tree can be compared with the user's commits.
    comparable: bool = false,
    /// Paths the policy left out, borrowed from the arena.
    excluded: []const policy.Exclusion = &.{},
    /// The tool whose action reached this repository first in the turn, for
    /// a start capture it triggered; null for the turn's own captures (D98).
    /// Set by the caller, not by `capture`.
    trigger_tool: ?[]const u8 = null,
};

/// The budget of a first capture, counted from its setup: one that creates
/// the repository's store or the worktree's capture index, or that finds no
/// capture ref in the store, so its copy has nothing to leave out. It writes
/// every object the new store lacks and copies its whole tree into the
/// store, and in a large repository that alone takes longer than a turn's
/// capture budget, so the whole capture runs until this much after setup
/// begins, or until the caller's deadline when that is later. A first
/// capture that runs out of time keeps the packs it finished, so the next
/// one, on this budget again, goes on from there; once a capture lands,
/// later ones keep the caller's deadline.
const first_capture_budget_ms: i64 = 10_000;

/// The deadline a capture runs on from its setup on: for a first capture
/// (`first`), `first_capture_budget_ms` after `started` unless the caller's
/// `deadline` is later; otherwise `deadline`.
fn setupDeadline(started: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp, first: bool) std.Io.Clock.Timestamp {
    if (!first) return deadline;
    const budget_end = started.addDuration(.{ .raw = .fromMilliseconds(first_capture_budget_ms), .clock = deadline.clock });
    return if (budget_end.compare(.gt, deadline)) budget_end else deadline;
}

/// A capture index or session ref lock older than this was left by a git
/// that died: fx's own git runs on them only under the worktree lock, or for
/// one short ref command, and stops at the capture's deadline plus the setup
/// budget, both far shorter.
const stale_lock_ms: i64 = 2 * std.time.ms_per_min;

/// Captures `request.repository` into its store. Every failure is an
/// `Outcome`; only allocation failure is returned as an error. Memory belongs
/// to `arena`.
pub fn capture(arena: Allocator, request: Request) Allocator.Error!Outcome {
    if (!validSessionId(request.session_id)) return .{ .status = .failed, .reason = .invalid_request };
    for ([_][]const u8{ request.profile_root, request.path }) |path| {
        if (!std.Io.Dir.path.isAbsolute(path)) return .{ .status = .failed, .reason = .invalid_request };
    }
    var run: Run = .{ .arena = arena, .io = io_mod.getIo(), .request = request, .deadline = request.deadline };
    if (try run.resolve()) |done| return done;
    if (try run.findProfile()) |done| return done;
    if (try run.lockWorktree()) |done| return done;
    defer if (run.lock) |*lock| lock.close(run.io);
    if (try run.clearStaleLocks()) |done| return done;
    if (try run.setUp()) |done| return done;
    if (try run.select()) |done| return done;
    if (try run.apply()) |done| return done;
    return run.commit();
}

/// One capture's state, filled in step by step. Each step returns the
/// final outcome when the capture stops there, or null to go on.
const Run = struct {
    arena: Allocator,
    io: std.Io,
    request: Request,
    /// The capture's deadline, moved later by the time setup took.
    deadline: std.Io.Clock.Timestamp,
    outcome: Outcome = .{ .status = .complete },
    ready: safe_git.Ready = undefined,
    store_ready: safe_git.StoreReady = undefined,
    facts: safe_git.RepositoryFacts = undefined,
    canonical: Repository = undefined,
    /// `worktreeIdentity` of `canonical`.
    worktree: []const u8 = undefined,
    ref: []const u8 = undefined,
    /// The repository's folder under the profile (`storeDir`).
    store_dir: []const u8 = undefined,
    store: safe_git.Store = undefined,
    /// The worktree's lock, held from `lockWorktree` to the end.
    lock: ?Lock = null,
    /// What the user's git tracks, and what the capture index held before.
    tracked: []const Staged = &.{},
    captured: []const Staged = &.{},
    tracked_paths: std.StringHashMapUnmanaged(Staged) = .empty,
    selection: policy.Selection = undefined,
    /// fx's profile folder relative to the work tree when the work tree
    /// holds it (`findProfile`), which the capture never lists.
    profile: ?[]const u8 = null,
    /// The one exclusion recorded for the profile folder: set only when the
    /// user's git tracks files in it, which the tree then lacks.
    profile_exclusion: ?policy.Exclusion = null,
    /// The store's newest captures, which a capture with no parent leaves
    /// out of its copy (`newestCaptures`); read in `setUp`.
    copy_base: []const []const u8 = &.{},

    fn limits(self: *const Run) safe_git.Limits {
        return .{ .deadline = self.deadline, .cancel = self.request.cancel };
    }

    fn fail(self: *const Run, status: Status, reason: policy.Reason) Outcome {
        return withFailure(self.outcome, status, reason);
    }

    /// `outcome`, unless the cancel flag or the deadline explains it: a git
    /// run they stopped can surface as a refusal.
    fn stoppedOr(self: *const Run, outcome: Outcome) Outcome {
        if (self.request.cancel) |flag| if (flag.load(.acquire)) return withFailure(outcome, .unavailable, .cancelled);
        return deadlineOr(self.io, self.deadline, outcome);
    }

    fn gitFail(self: *const Run, failure: safe_git.Failure) Outcome {
        return withGitFailure(self.outcome, failure);
    }

    /// `io_error` for a failure outside git, logged with what failed, since
    /// the record names no path; `cancelled` for a cancel request, which is
    /// re-armed for the caller's next step.
    fn ioFail(self: *const Run, step: []const u8, path: []const u8, err: anyerror) Outcome {
        if (err == error.Canceled) {
            self.io.recancel();
            return self.fail(.unavailable, .cancelled);
        }
        logIoError(step, path, err);
        return self.fail(.failed, .io_error);
    }

    /// The user's repository: read only, through the agent's read-only
    /// prelude. A refusal after the deadline is the deadline's: prepare's own
    /// git runs stop there too.
    fn resolve(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        self.ready = switch (try safe_git.prepareWithin(arena, self.request.path, self.limits())) {
            .ready => |value| value,
            .refused => return self.stoppedOr(.{ .status = .unavailable, .reason = .git_refused }),
        };
        // No repository holds the folder.
        if (self.ready.git_dir == null) return .{ .status = .unavailable, .reason = .not_git };
        // The store route needs git 2.29; check it before `repositoryFacts`,
        // which already uses a 2.29 option, so old git is unavailable, not
        // failed.
        self.store_ready = switch (try safe_git.prepareStore(arena, self.limits())) {
            .ready => |value| value,
            .refused => return self.stoppedOr(.{ .status = .unavailable, .reason = .git_refused }),
        };
        self.facts = switch (try safe_git.repositoryFacts(arena, self.ready, self.request.path, self.limits())) {
            .ok => |facts| facts,
            .failed => |failure| {
                debug_trace.logf("workspace", "event=workspace_capture_facts_failed kind={s}", .{@tagName(failure)});
                return self.stoppedOr(.{ .status = .failed, .reason = .io_error });
            },
        };
        // The repository as git resolves it, with symlinks resolved: every
        // key below uses these spellings, so `/tmp/x`, `/private/tmp/x` and
        // any folder inside the worktree reach the same store, index and ref.
        self.outcome = .{
            .status = .complete,
            .head = if (self.facts.head) |oid| .{ .commit = oid } else .unborn,
            .object_format = self.facts.object_format,
        };
        self.canonical = .{
            .work_tree = try resolvedPath(arena, self.facts.work_tree) orelse return self.ioFail("resolve", self.facts.work_tree, error.Unresolvable),
            .git_dir = try resolvedPath(arena, self.facts.git_dir) orelse return self.ioFail("resolve", self.facts.git_dir, error.Unresolvable),
            .common_dir = try resolvedPath(arena, self.facts.common_dir) orelse return self.ioFail("resolve", self.facts.common_dir, error.Unresolvable),
        };
        // The outcome claims nothing here: HEAD, the repository and the ref
        // would all be the other checkout's.
        if (!try ownsGitDir(arena, self.io, self.canonical, self.request.path)) {
            return .{ .status = .unavailable, .reason = .foreign_git_dir };
        }
        self.outcome.repository = self.canonical;
        // One chain per session and worktree: two worktrees of one
        // repository in the same session never race for one ref or mix their
        // trees.
        self.worktree = try worktreeIdentity(arena, self.canonical);
        self.ref = try sessionRefName(arena, self.request.session_id, self.worktree);
        self.outcome.ref = self.ref;
        // A sparse index holds folder entries the store cannot expand without
        // the user's sparse-checkout patterns.
        if (self.facts.sparse_index) return self.fail(.unavailable, .index_sparse);
        return null;
    }

    /// Layout and the worktree lock, held for the whole capture. flock is
    /// released by the kernel if fx dies, so a crash never leaves it held.
    fn lockWorktree(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const store_dir = try storeDir(arena, self.request.profile_root, self.canonical.common_dir);
        self.store_dir = store_dir;
        const worktree_dir = try worktreeDir(arena, store_dir, self.worktree);
        const scratch_dir = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "scratch" });
        // Captures hold the user's uncommitted work: every folder fx creates
        // for them is private, whatever the umask.
        for ([_][]const u8{ try std.Io.Dir.path.join(arena, &.{ self.request.profile_root, "captures" }), store_dir, try std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" }), worktree_dir, scratch_dir }) |dir| {
            ensurePrivateDir(self.io, dir) catch |err| return self.ioFail("private_dir", dir, err);
        }
        // `lockUntil` logs why a lock could not be taken.
        const lock_path = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "lock" });
        self.lock = .{ .file = lockUntil(self.io, lock_path, self.deadline, self.request.cancel) catch |err| return switch (err) {
            error.Busy => self.fail(.unavailable, .capture_locked),
            error.Unavailable => self.fail(.failed, .io_error),
            error.Canceled => self.fail(.unavailable, .cancelled),
        } };
        self.store = .{
            .git_dir = try storeGitDir(arena, store_dir),
            .index_file = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "index" }),
            .work_tree = self.canonical.work_tree,
            .scratch_dir = scratch_dir,
            .conversions = self.facts.conversions,
        };
        return null;
    }

    /// A git that outlived its capture, such as one a killed fx left, can
    /// leave the capture index or this session's ref locked. Only captures
    /// holding the worktree lock run git on the index and move the ref, and
    /// this one holds it; the fork copy and retention touch the ref for one
    /// short command at most. So a lock older than any of them can run is
    /// removed; a newer one is reported.
    fn clearStaleLocks(self: *Run) Allocator.Error!?Outcome {
        const locks = [_][]const u8{
            try self.arena.print("{s}.lock", .{self.store.index_file}),
            try self.arena.print("{s}/{s}.lock", .{ self.store.git_dir, self.ref }),
        };
        for (locks) |path| if (try self.clearStaleLock(path)) |done| return done;
        return null;
    }

    fn clearStaleLock(self: *Run, path: []const u8) Allocator.Error!?Outcome {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            error.Canceled => return self.ioFail("lock_stat", path, err),
            else => return self.fail(.unavailable, .capture_locked),
        };
        const age_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds() - stat.mtime.toMilliseconds();
        if (age_ms < stale_lock_ms) return self.fail(.unavailable, .capture_locked);
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            error.Canceled => return self.ioFail("lock_remove", path, err),
            else => return self.fail(.unavailable, .capture_locked),
        };
        debug_trace.logf("workspace", "event=workspace_capture_stale_lock_removed lock={s} age_ms={d}", .{ path, age_ms });
        return null;
    }

    /// Makes sure the store exists and the worktree has a capture index. The
    /// first capture starts the index from a copy of the user's with its
    /// timestamp, so git's racy-entry check still sees files changed in the
    /// index's second. A split index keeps entries in a shared file the copy
    /// would miss, so it is rebuilt from HEAD instead. When either is new,
    /// or the store holds no capture ref, the rest of the capture runs on
    /// `first_capture_budget_ms` (`setupDeadline`). An index that is not a
    /// regular file of bounded size, such as a pipe whose open would block
    /// past any deadline, is rebuilt from HEAD too. Only a store or index
    /// the system reports missing is created; a check that fails otherwise
    /// fails the capture.
    fn setUp(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const clock = self.deadline.clock;
        const store_head = try std.Io.Dir.path.join(arena, &.{ self.store.git_dir, "HEAD" });
        const store_missing = !(isPresent(io, store_head) catch |err| return self.ioFail("store_check", store_head, err));
        const index_missing = !(isPresent(io, self.store.index_file) catch |err| return self.ioFail("index_check", self.store.index_file, err));
        const started: std.Io.Clock.Timestamp = .now(io, clock);
        const setup_deadline = setupDeadline(started, self.deadline, store_missing or index_missing);
        // An existing store is only checked; its lock, which pruning also
        // holds, waits on the capture's own deadline.
        const store_deadline = if (store_missing) setup_deadline else self.deadline;
        if (try ensureStore(arena, io, self.store_ready, self.store_dir, self.store.git_dir, self.canonical.common_dir, self.facts.object_format, .{ .deadline = store_deadline, .cancel = self.request.cancel }, store_deadline)) |failure| {
            return self.gitFail(failure);
        }
        // Until the store holds a capture, a copy has nothing to leave out
        // and takes the whole tree, so the capture keeps the first budget;
        // a new store holds none.
        if (!store_missing) {
            const refs = switch (try storeOutput(arena, self.store_ready, self.store, .list_refs, .{ .deadline = setup_deadline, .cancel = self.request.cancel })) {
                .ok => |stdout| stdout,
                .failed => |failure| return self.gitFail(failure),
            };
            self.copy_base = try newestCaptures(arena, refs, self.facts.object_format);
        }
        const first = store_missing or index_missing or self.copy_base.len == 0;
        if (builtin.is_test) test_hooks.first_budget = first;
        const first_deadline = setupDeadline(started, self.deadline, first);
        self.outcome.index = .persisted;
        if (index_missing) {
            const user_index = try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "index" });
            if (self.facts.split_index or try hasSharedIndex(io, self.canonical.git_dir) or !copyableIndex(io, user_index)) {
                if (try runStore(arena, self.store_ready, self.store, .{ .read_tree = self.facts.head }, .{ .deadline = first_deadline, .cancel = self.request.cancel })) |failure| return self.gitFail(failure);
                self.outcome.index = .rebuilt;
            } else {
                copyPreservingTime(arena, io, user_index, self.store.index_file) catch |err| return self.ioFail("index_copy", user_index, err);
                self.outcome.index = .copied;
            }
        }
        if (first) {
            // The first capture keeps the longer budget for its whole run:
            // the objects the new store lacks are written, and its whole
            // tree copied, after setup.
            self.deadline = first_deadline;
            const took = started.durationTo(.now(io, clock));
            debug_trace.logf("workspace", "event=workspace_capture_setup store_created={} index={s} captures={d} ms={d} budget_ms={d}", .{ store_missing, @tagName(self.outcome.index.?), self.copy_base.len, took.raw.toMilliseconds(), first_capture_budget_ms });
        }
        return null;
    }

    /// Lists what the user's git tracks, what the capture index holds and
    /// the untracked files, checks each on disk, and applies
    /// `workspace_capture`'s policy.
    fn select(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const tracked_listing = switch (try safe_git.listRepository(arena, self.ready, self.canonical.work_tree, .tracked, null, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.tracked = try self.leaveOutProfile(safe_git.parseStageListing(arena, tracked_listing) catch return self.fail(.failed, .inconsistent));
        const index_listing = switch (try storeOutput(arena, self.store_ready, self.store, .list_index, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.captured = safe_git.parseStageListing(arena, index_listing) catch return self.fail(.failed, .inconsistent);

        // Untracked files: the native indexer, or git when it cannot read the
        // index format completely.
        for (self.tracked) |entry| try self.tracked_paths.put(arena, entry.path, entry);
        const untracked = switch (try listUntracked(arena, self.request.scan_allocator, self.ready, self.facts, self.profile, self.limits(), &self.tracked_paths, &self.outcome)) {
            .listed => |value| value,
            .stopped => return self.fail(.unavailable, .untracked_timeout),
            .cancelled => return self.fail(.unavailable, .cancelled),
            .failed => return deadlineOr(io, self.deadline, self.fail(.failed, .io_error)),
        };
        if (pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);

        // Candidates with what the disk holds now.
        var candidates: std.ArrayList(policy.Candidate) = .empty;
        var disk: Disk = .{ .arena = arena, .io = io, .work_tree = self.canonical.work_tree };
        for (self.tracked, 0..) |entry, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(entry.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
                error.Canceled => return self.fail(.unavailable, .cancelled),
            };
            // A tracked file replaced by a folder is gone, unless it is a
            // gitlink.
            const present = found.present and ((entry.mode == .gitlink) or found.kind != .gitlink);
            try candidates.append(arena, .{
                .path = entry.path,
                .tracked = true,
                .present = present,
                .skip_worktree = entry.skip_worktree,
                .bytes = found.bytes,
                .kind = if ((entry.mode == .gitlink)) .gitlink else found.kind,
            });
        }
        for (untracked.files, 0..) |path, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
                error.Canceled => return self.fail(.unavailable, .cancelled),
            };
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = found.present, .bytes = found.bytes, .kind = found.kind });
        }
        // A repository nested inside the worktree is recorded as left out,
        // never silently dropped.
        for (untracked.nested) |path| {
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = true, .kind = .gitlink });
        }
        var previous: std.ArrayList([]const u8) = .empty;
        for (self.captured) |entry| try previous.append(arena, entry.path);
        self.selection = policy.select(arena, candidates.items, previous.items, self.request.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.DuplicatePath => return self.fail(.failed, .inconsistent),
        };
        if (self.profile_exclusion) |exclusion| {
            self.selection.excluded = try std.mem.concat(arena, policy.Exclusion, &.{ self.selection.excluded, &.{exclusion} });
        }
        return null;
    }

    /// Finds fx's own profile folder, `~/.fx` or `$FX_HOME`, in the work
    /// tree. It holds sessions, credentials and this very store, so a capture
    /// never lists it: otherwise every capture would list the objects the
    /// earlier ones wrote. A work tree that is the profile folder itself
    /// holds only fx's data and is `private_root`.
    fn findProfile(self: *Run) Allocator.Error!?Outcome {
        self.profile = try profileWithin(self.arena, self.canonical.work_tree, self.request.profile_root);
        if (self.profile) |profile| if (profile.len == 0) return self.fail(.unavailable, .private_root);
        return null;
    }

    /// `tracked` without the files under the profile folder. The untracked
    /// listing skips the folder without a trace, since what fx wrote there
    /// is not the user's work and a tree never held it, so a capture stays
    /// complete and comparable. A file the user's git tracks there is
    /// different: the tree lacks what the user's commits hold, so the folder
    /// is recorded once as a `sensitive` exclusion, which makes the capture
    /// partial.
    fn leaveOutProfile(self: *Run, tracked: []const Staged) Allocator.Error![]const Staged {
        const profile = self.profile orelse return tracked;
        var kept: std.ArrayList(Staged) = .empty;
        for (tracked) |entry| if (!isUnder(profile, entry.path)) try kept.append(self.arena, entry);
        if (kept.items.len < tracked.len) self.profile_exclusion = .{ .path = profile, .reason = .sensitive };
        return kept.items;
    }

    /// Applies the selection to the capture index only. Paths read from disk
    /// lose the flags the index copy inherited, or git would keep their old
    /// content.
    fn apply(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const selection = self.selection;
        {
            var inherited: std.StringHashMapUnmanaged(Staged) = .empty;
            for (self.captured) |entry| if (entry.assume_unchanged or entry.skip_worktree) try inherited.put(arena, entry.path, entry);
            var assume: std.ArrayList([]const u8) = .empty;
            var skip: std.ArrayList([]const u8) = .empty;
            for (selection.read) |path| if (inherited.get(path)) |entry| {
                if (entry.assume_unchanged) try assume.append(arena, path);
                if (entry.skip_worktree) try skip.append(arena, path);
            };
            if (assume.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .assume_unchanged, .paths = assume.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
            if (skip.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .skip_worktree, .paths = skip.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
        }
        if (selection.keep_index.len > 0) {
            var entries: std.ArrayList(safe_git.IndexEntry) = .empty;
            for (selection.keep_index) |path| {
                const entry = self.tracked_paths.get(path) orelse return self.fail(.failed, .inconsistent);
                try entries.append(arena, .{ .mode = entry.mode, .oid = entry.oid, .path = path });
            }
            if (try runStore(arena, self.store_ready, self.store, .{ .index_info = entries.items }, self.limits())) |failure| return self.gitFail(failure);
        }
        // Removed paths may still be on disk (an untracked file that became
        // ignored, or went over a limit), so they are forced out.
        if (selection.remove.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .force_remove = selection.remove }, self.limits())) |failure| return self.gitFail(failure);
        }
        if (selection.read.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .add_remove = selection.read }, self.limits())) |failure| return self.gitFail(failure);
        }
        return null;
    }

    /// Writes the tree and the commit, and moves the session ref to it.
    fn commit(self: *Run) Allocator.Error!Outcome {
        const arena = self.arena;
        const format = self.facts.object_format;
        const tree = switch (try storeOutput(arena, self.store_ready, self.store, .write_tree, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(tree, format)) return self.fail(.failed, .inconsistent);
        const parent_out = switch (try storeOutput(arena, self.store_ready, self.store, .{ .resolve_ref = self.ref }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        const parent: ?[]const u8 = if (parent_out.len == 0) null else parent_out;
        const message = try arena.print("fx capture {s} {s}\n", .{ self.request.session_id, @tagName(self.request.phase) });
        const commit_oid = switch (try storeOutput(arena, self.store_ready, self.store, .{ .commit_tree = .{ .tree = tree, .parent = parent, .message = message, .unix_seconds = self.request.unix_seconds } }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(commit_oid, format)) return self.fail(.failed, .inconsistent);
        // The ref moves only once the store holds every object of the tree
        // itself, so every commit a capture ref names is self-sufficient.
        // Every capture ref passed this copy, so what the parent, or with no
        // parent the store's newest captures, reach is left out.
        const except: []const []const u8 = if (parent) |oid| try arena.dupe([]const u8, &.{oid}) else self.copy_base;
        if (try copyObjects(arena, self.request.scan_allocator, self.store_ready, self.store, format, tree, except, self.limits())) |failure| return self.gitFail(failure);
        if (try runStore(arena, self.store_ready, self.store, .{ .update_ref = .{ .ref = self.ref, .new = commit_oid, .old = parent } }, self.limits())) |failure| return self.gitFail(failure);

        var outcome = self.outcome;
        outcome.tree = tree;
        outcome.commit = commit_oid;
        outcome.excluded = self.selection.excluded;
        // Filters or attributes from the repository's own config never reach
        // the store, so its tree may differ from the user's. A file that
        // cannot be checked counts as there, so the capture claims less.
        const repository_conversions = self.ready.filter_names.len > 0 or
            presentOr(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "info", "attributes" }), true) or
            presentOr(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.common_dir, "info", "attributes" }), true);
        outcome.comparable = self.selection.canCompareTrees(repository_conversions);
        if (lossReason(self.selection.excluded)) |reason| {
            outcome.status = .partial;
            outcome.reason = reason;
        }
        return outcome;
    }
};

/// Whether the worktree git reports is the captured folder's own: the folder
/// lies inside it, and the git directory's own record of its work tree, where
/// it keeps one, names this worktree's `.git`. A `.git` symlink, or a
/// `gitdir:` file into another checkout's `.git` folder or linked worktree,
/// makes git treat the folder as that checkout's worktree and report its
/// HEAD.
fn ownsGitDir(arena: Allocator, io: std.Io, repo: Repository, path: []const u8) Allocator.Error!bool {
    const folder = try resolvedPath(arena, path) orelse return false;
    if (!isWithin(repo.work_tree, folder)) return false;
    const dot_git = try std.Io.Dir.path.join(arena, &.{ repo.work_tree, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io, dot_git, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return false;
    };
    switch (stat.kind) {
        .directory => {
            const real = try resolvedPath(arena, dot_git) orelse return false;
            return std.mem.eql(u8, real, repo.git_dir);
        },
        .file => {
            if (!std.mem.eql(u8, repo.git_dir, repo.common_dir)) {
                // A linked worktree: its git directory records which `.git`
                // file is the worktree's, absolute or relative to itself.
                const gitdir_file = try std.Io.Dir.path.join(arena, &.{ repo.git_dir, "gitdir" });
                const recorded = try readSmallRegularFile(arena, io, gitdir_file, std.Io.Dir.max_path_bytes) orelse return false;
                const trimmed = std.mem.trimEnd(u8, recorded, "\r\n");
                const target = if (std.Io.Dir.path.isAbsolute(trimmed)) trimmed else try std.Io.Dir.path.join(arena, &.{ repo.git_dir, trimmed });
                const real_target = try resolvedPath(arena, target) orelse return false;
                const real_dot_git = try resolvedPath(arena, dot_git) orelse return false;
                return std.mem.eql(u8, real_target, real_dot_git);
            }
            // Never another checkout's own `.git` folder.
            const parent = std.Io.Dir.path.dirname(repo.git_dir) orelse return false;
            if (std.mem.eql(u8, std.Io.Dir.path.basename(repo.git_dir), ".git")) return std.mem.eql(u8, parent, repo.work_tree);
            // A submodule's git directory names its work tree in
            // `core.worktree`, which git applied: a `.git` file elsewhere
            // gets that work tree, and `isWithin` above refuses it. A
            // separate git directory names none, so git's work tree, the
            // folder holding this `.git` file, is the only record there is.
            // Its worktree key includes that work tree (`worktreeIdentity`),
            // so another folder pointing at the same git directory never
            // shares this one's capture index or ref.
            return true;
        },
        else => return false,
    }
}

/// What names one worktree inside its repository's store, for its folder
/// (`worktreeDir`) and its session refs (`sessionRefName`). A work tree's own
/// `.git` folder belongs to that work tree alone, so it is named by its git
/// directory. Any other git directory, a separate one or a linked
/// worktree's, can be handed to a second folder by a `gitdir:` file, so it is
/// named by the git directory and the work tree together, joined by a NUL
/// that no path holds, so the two forms never collide. Owned by `arena`.
fn worktreeIdentity(arena: Allocator, repo: Repository) Allocator.Error![]const u8 {
    const own_dot_git = std.mem.eql(u8, std.Io.Dir.path.basename(repo.git_dir), ".git") and
        std.mem.eql(u8, std.Io.Dir.path.dirname(repo.git_dir) orelse "", repo.work_tree);
    if (own_dot_git) return repo.git_dir;
    return arena.print("{s}\x00{s}", .{ repo.git_dir, repo.work_tree });
}

/// The contents of `path` when it is a regular file of at most `max_bytes`,
/// checked before it is opened; null otherwise. A pipe, socket or device is
/// never opened, since opening one can block with no deadline. A cancel
/// request is re-armed for the capture's next step.
fn readSmallRegularFile(arena: Allocator, io: std.Io, path: []const u8, max_bytes: usize) Allocator.Error!?[]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return null;
    };
    if (stat.kind != .file or stat.size > max_bytes) {
        debug_trace.logf("workspace", "event=workspace_capture_file_skipped path={s} kind={s} bytes={d}", .{ path, @tagName(stat.kind), stat.size });
        return null;
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            keepCancel(io, err);
            return null;
        },
    };
}

/// Whether the user's index at `path` can be copied: a regular file no larger
/// than `max_index_bytes`. Anything else is rebuilt from HEAD, which is
/// always correct.
fn copyableIndex(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        if (err != error.FileNotFound) logIoError("index_stat", path, err);
        return false;
    };
    if (stat.kind == .file and stat.size <= max_index_bytes) return true;
    debug_trace.logf("workspace", "event=workspace_capture_index_rebuilt path={s} kind={s} bytes={d}", .{ path, @tagName(stat.kind), stat.size });
    return false;
}

/// Logs a failure outside git that a capture reports as `io_error`.
fn logIoError(step: []const u8, path: []const u8, err: anyerror) void {
    debug_trace.logf("workspace", "event=workspace_capture_failed step={s} path={s} err={s}", .{ step, path, @errorName(err) });
}

/// Whether `path` is `root` or inside it; both absolute and resolved.
pub fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

/// Where the profile folder `profile_root` lies in `work_tree`, relative to
/// it and empty when it is the work tree itself; null when it lies outside
/// or cannot be resolved.
fn profileWithin(arena: Allocator, work_tree: []const u8, profile_root: []const u8) Allocator.Error!?[]const u8 {
    const resolved = try resolvedPath(arena, profile_root) orelse return null;
    if (!isWithin(work_tree, resolved)) return null;
    return std.mem.trimStart(u8, resolved[@min(work_tree.len, resolved.len)..], "/");
}

/// Whether the repository-relative `path` is `folder` or inside it; an empty
/// `folder` holds every path.
fn isUnder(folder: []const u8, path: []const u8) bool {
    if (folder.len == 0) return true;
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

/// `path` with every symlink resolved, or null when it cannot be resolved.
fn resolvedPath(arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    return io_mod.realpathAlloc(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// The ref for `session_id` and the worktree whose `worktreeIdentity` is
/// `worktree`. Both parts are hashes, so any id fx accepts fits git's ref
/// rules and `safe_git`'s two-segment ref check.
fn sessionRefName(arena: Allocator, session_id: []const u8, worktree: []const u8) Allocator.Error![]const u8 {
    return arena.print("refs/fx/sessions/{s}/{s}", .{ try sessionKey(arena, session_id), try pathKey(arena, worktree) });
}

/// The ref segment that names `session_id`: the first 16 bytes of its
/// SHA-256, in hex. Retention matches sessions to refs with it.
pub fn sessionKey(arena: Allocator, session_id: []const u8) Allocator.Error![]const u8 {
    return pathKey(arena, session_id);
}

pub fn pastDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return deadline.compare(.lte, .now(io, deadline.clock));
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    // `iterate` opens a real descriptor: on Linux a plain open is O_PATH,
    // which fchmod rejects with EBADF (as `settings_store` opens its home).
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
}

/// fx's session id rule (`src/core/session_manager/schema.zig` `validId`).
fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '.') return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn withFailure(base: Outcome, status: Status, reason: policy.Reason) Outcome {
    var outcome = base;
    outcome.status = status;
    outcome.reason = reason;
    outcome.tree = null;
    outcome.commit = null;
    return outcome;
}

fn withGitFailure(base: Outcome, failure: safe_git.Failure) Outcome {
    return switch (failure) {
        .timeout => withFailure(base, .unavailable, .timeout),
        .cancelled => withFailure(base, .unavailable, .cancelled),
        .path_rejected => withFailure(base, .failed, .inconsistent),
        .spawn_failed, .input_failed, .read_failed, .output_too_large, .exited_nonzero, .terminated => withFailure(base, .failed, .io_error),
    };
}

/// A failure observed after the shared deadline passed is a timeout.
fn deadlineOr(io: std.Io, deadline: std.Io.Clock.Timestamp, outcome: Outcome) Outcome {
    if (pastDeadline(io, deadline)) return withFailure(outcome, .unavailable, .timeout);
    return outcome;
}

/// Runs a store command and returns its output. Every argument comes from
/// git's own listings or validated input, so a rejected argument means the
/// listing and the store disagree.
pub fn storeOutput(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!safe_git.Outcome {
    return safe_git.runStore(arena, ready, store, command, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .{ .failed = .path_rejected },
    };
}

/// Runs a store command whose output is not needed; null on success.
fn runStore(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!?safe_git.Failure {
    return switch (try storeOutput(arena, ready, store, command, limits)) {
        .ok => null,
        .failed => |failure| failure,
    };
}

/// Captures whose trees a parentless capture's copy leaves out, newest first.
/// Each costs one tree walk, so a store with many refs stays bounded.
const max_copy_exclusions = 16;

/// Objects in one pack the copy writes. Each finished pack stays when a later
/// one runs out of time, so an interrupted copy loses at most one pack's work,
/// and the copy of a large tree leaves a few dozen packs until retention
/// repacks them into one.
const copy_batch_objects: usize = 20_000;

/// Seams for tests. Production code reads and writes them only under
/// `builtin.is_test`, so a release build has none.
const test_hooks = struct {
    /// Replaces `copy_batch_objects`.
    var copy_batch_objects: ?usize = null;
    /// The packs a copy writes before it stops as if its deadline passed.
    var copy_packs_before_timeout: ?usize = null;
    /// A path suffix whose presence check fails as if access were denied.
    var access_denied_suffix: ?[]const u8 = null;
    /// Whether the last capture's setup chose the first-capture budget.
    var first_budget: ?bool = null;
    /// The objects the last copy packed.
    var copied_objects: usize = 0;
};

/// Copies into the store every object `tree` reaches that it might hold only
/// through its alternates: a staged blob, or one from a branch the user may
/// delete. Objects the trees of the `except` commits reach are left out:
/// every commit a capture ref names already passed this copy. Objects the
/// store holds itself are skipped: loose ones, which it wrote, and those in
/// its own packs, such as the packs an earlier copy finished before it ran
/// out of time. They stay safe because no store command deletes a loose
/// object before packing it into the store's own pack, and none drops an
/// object a ref reaches from a pack: retention's `gc` and `repack` both
/// repack everything without `-l`. The rest goes into packs of at most
/// `copy_batch_objects` objects, each kept once written. `scratch` holds the
/// pack indexes while the copy runs. Null on success; `.path_rejected` when
/// git lists something that is not an object ID.
fn copyObjects(
    arena: Allocator,
    scratch: Allocator,
    ready: safe_git.StoreReady,
    store: safe_git.Store,
    format: safe_git.ObjectFormat,
    tree: []const u8,
    except: []const []const u8,
    limits: safe_git.Limits,
) Allocator.Error!?safe_git.Failure {
    const io = io_mod.getIo();
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    if (builtin.is_test) test_hooks.copied_objects = 0;
    const listing = switch (try storeOutput(arena, ready, store, .{ .list_objects = .{ .tree = tree, .except = except } }, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return failure,
    };
    var packs = OwnPacks.load(arena, scratch, io, store.git_dir, format) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return .cancelled,
    };
    defer packs.deinit(io);
    var objects: std.ArrayList([]const u8) = .empty;
    var loose: usize = 0;
    var held: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!safe_git.isOid(line, format)) return .path_rejected;
        if (packs.contains(io, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return .cancelled,
        }) {
            held += 1;
            continue;
        }
        // A loose object in the store is one it wrote itself. One that
        // cannot be checked is copied.
        const loose_path = try arena.print("{s}/objects/{s}/{s}", .{ store.git_dir, line[0..2], line[2..] });
        if (isPresent(io, loose_path) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return .cancelled;
            },
            else => false,
        }) {
            loose += 1;
            continue;
        }
        try objects.append(arena, line);
    }
    const batch = @max(1, if (builtin.is_test) test_hooks.copy_batch_objects orelse copy_batch_objects else copy_batch_objects);
    var start: usize = 0;
    var written: usize = 0;
    while (start < objects.items.len) : (written += 1) {
        if (builtin.is_test) if (test_hooks.copy_packs_before_timeout) |limit| if (written == limit) return .timeout;
        const end = @min(objects.items.len, start + batch);
        if (try runStore(arena, ready, store, .{ .pack_objects = objects.items[start..end] }, limits)) |failure| return failure;
        if (builtin.is_test) test_hooks.copied_objects += end - start;
        start = end;
    }
    debug_trace.logf("workspace", "event=workspace_capture_objects_copied objects={d} packs={d} loose={d} packed={d} excluded={d} ms={d}", .{
        objects.items.len,
        written,
        loose,
        held,
        except.len,
        started.durationTo(.now(io, .awake)).raw.toMilliseconds(),
    });
    return null;
}

/// The store's own packs, read from their version 2 `.idx` files, apart from
/// the packs its alternates hold: which objects the store already holds
/// itself in a pack. Loading also deletes the temporary files of a pack that
/// a killed git left, once older than any git of a capture or retention
/// runs (`stale_lock_ms`). A pack that cannot be read is left out, which only
/// copies more.
const OwnPacks = struct {
    scratch: Allocator,
    indexes: []PackIndex,

    const Error = Allocator.Error || error{Canceled};

    fn load(arena: Allocator, scratch: Allocator, io: std.Io, git_dir: []const u8, format: safe_git.ObjectFormat) Error!OwnPacks {
        var indexes: std.ArrayList(PackIndex) = .empty;
        const pack_dir = try std.Io.Dir.path.join(arena, &.{ git_dir, "objects", "pack" });
        var dir = std.Io.Dir.openDirAbsolute(io, pack_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{ .scratch = scratch, .indexes = indexes.items },
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => {
                logIoError("pack_list", pack_dir, err);
                return .{ .scratch = scratch, .indexes = indexes.items };
            },
        };
        defer dir.close(io);
        const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        var entries = dir.iterate();
        while (entries.next(io) catch |err| {
            if (err == error.Canceled) {
                io.recancel();
                return error.Canceled;
            }
            logIoError("pack_list", pack_dir, err);
            return .{ .scratch = scratch, .indexes = indexes.items };
        }) |entry| {
            if (std.mem.startsWith(u8, entry.name, "tmp_")) {
                removeStaleTemporaryPack(io, dir, pack_dir, entry.name, now_ms);
                continue;
            }
            if (!std.mem.startsWith(u8, entry.name, "pack-") or !std.mem.endsWith(u8, entry.name, ".idx")) continue;
            const pack_name = try arena.print("{s}.pack", .{entry.name[0 .. entry.name.len - ".idx".len]});
            if (PackIndex.open(io, dir, entry.name, pack_name, format)) |index| {
                try indexes.append(arena, index);
            } else |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    return error.Canceled;
                },
                else => debug_trace.logf("workspace", "event=workspace_capture_pack_skipped dir={s} name={s} err={s}", .{ pack_dir, entry.name, @errorName(err) }),
            }
        }
        return .{ .scratch = scratch, .indexes = indexes.items };
    }

    fn deinit(self: *OwnPacks, io: std.Io) void {
        for (self.indexes) |*index| index.close(io, self.scratch);
    }

    /// Whether one of the packs holds `oid`, given in hex. Reads each pack's
    /// object table once lookups are many enough that reading it whole
    /// costs less than searching it on disk.
    fn contains(self: *OwnPacks, io: std.Io, oid: []const u8) Error!bool {
        var raw_buffer: [32]u8 = undefined;
        const raw = std.fmt.hexToBytes(raw_buffer[0 .. oid.len / 2], oid) catch return false;
        for (self.indexes) |*index| {
            if (index.contains(io, self.scratch, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {
                    io.recancel();
                    return error.Canceled;
                },
                else => {
                    // A pack that fails to read is left out from here on.
                    index.count = 0;
                    continue;
                },
            }) return true;
        }
        return false;
    }
};

/// Deletes `name`, a temporary file of a pack in `dir`, when it was last
/// written longer ago than any capture's or retention's git runs, so it is
/// left by a git that died, never one still writing. Logged either way.
fn removeStaleTemporaryPack(io: std.Io, dir: std.Io.Dir, pack_dir: []const u8, name: []const u8, now_ms: i64) void {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| {
        keepCancel(io, err);
        return;
    };
    if (stat.kind != .file) return;
    const age_ms = now_ms - stat.mtime.toMilliseconds();
    if (age_ms < stale_lock_ms) return;
    if (dir.deleteFile(io, name)) {
        debug_trace.logf("workspace", "event=workspace_capture_temp_pack_removed dir={s} name={s} age_ms={d}", .{ pack_dir, name, age_ms });
    } else |err| {
        keepCancel(io, err);
        debug_trace.logf("workspace", "event=workspace_capture_temp_pack_remove_failed dir={s} name={s} err={s}", .{ pack_dir, name, @errorName(err) });
    }
}

/// One version 2 pack index: a header, a fan-out table of 256 counts, then
/// the sorted object IDs (git's `gitformat-pack`).
const PackIndex = struct {
    file: std.Io.File,
    fanout: [256]u32,
    /// Objects in the pack; 0 once the pack is left out.
    count: u32,
    hash_len: usize,
    /// The object table, read once lookups are many.
    table: ?[]u8 = null,
    lookups: usize = 0,

    const header_len = 8;
    const table_offset = header_len + 256 * 4;
    /// Lookups that are searched on disk before the table is read whole.
    const lookups_before_read = 64;

    /// Opens `name` in `dir` when its pack, `pack_name`, is there too and
    /// the index is a version 2 one of the store's object format.
    fn open(io: std.Io, dir: std.Io.Dir, name: []const u8, pack_name: []const u8, format: safe_git.ObjectFormat) !PackIndex {
        _ = try dir.statFile(io, pack_name, .{ .follow_symlinks = false });
        const file = try dir.openFile(io, name, .{});
        errdefer file.close(io);
        var header: [table_offset]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != header.len) return error.Truncated;
        if (!std.mem.eql(u8, header[0..4], "\xfftOc") or std.mem.readInt(u32, header[4..8], .big) != 2) return error.UnsupportedIndex;
        var index: PackIndex = .{ .file = file, .fanout = undefined, .count = 0, .hash_len = switch (format) {
            .sha1 => 20,
            .sha256 => 32,
        } };
        var previous: u32 = 0;
        for (&index.fanout, 0..) |*slot, i| {
            slot.* = std.mem.readInt(u32, header[header_len + i * 4 ..][0..4], .big);
            if (slot.* < previous) return error.Corrupt;
            previous = slot.*;
        }
        index.count = index.fanout[255];
        // The object IDs, a CRC and an offset for each, then the pack's and
        // the index's own checksums.
        const minimum = table_offset + @as(u64, index.count) * (index.hash_len + 8) + 2 * index.hash_len;
        if (try file.length(io) < minimum) return error.Truncated;
        return index;
    }

    fn close(self: *PackIndex, io: std.Io, scratch: Allocator) void {
        if (self.table) |table| scratch.free(table);
        self.file.close(io);
    }

    fn contains(self: *PackIndex, io: std.Io, scratch: Allocator, raw: []const u8) !bool {
        if (self.count == 0 or raw.len != self.hash_len) return false;
        self.lookups += 1;
        if (self.table == null and self.lookups > lookups_before_read) {
            const table = try scratch.alloc(u8, @as(usize, self.count) * self.hash_len);
            errdefer scratch.free(table);
            if (try self.file.readPositionalAll(io, table, table_offset) != table.len) return error.Truncated;
            self.table = table;
        }
        var low: usize = if (raw[0] == 0) 0 else self.fanout[raw[0] - 1];
        var high: usize = self.fanout[raw[0]];
        var buffer: [32]u8 = undefined;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = if (self.table) |table| table[middle * self.hash_len ..][0..self.hash_len] else blk: {
                const slot = buffer[0..self.hash_len];
                if (try self.file.readPositionalAll(io, slot, table_offset + middle * self.hash_len) != slot.len) return error.Truncated;
                break :blk slot;
            };
            switch (std.mem.order(u8, entry, raw)) {
                .eq => return true,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return false;
    }
};

/// One `list_refs` line.
pub const RefLine = struct {
    /// `refs/fx/sessions/<key>/<worktree>`.
    name: []const u8,
    /// The session's `sessionKey`.
    key: []const u8,
    /// The worktree's key (`sessionRefName`).
    worktree: []const u8,
    /// The commit the ref names, SHA-1 or SHA-256.
    oid: []const u8,
    /// The newest capture's commit time.
    seconds: i64,
};

/// The length of each key in a capture ref: 16 bytes in hex (`pathKey`).
const ref_key_len = 32;

/// Parses one line of `list_refs` output,
/// `refs/fx/sessions/<key>/<worktree> <object> <unix seconds>`, where both
/// keys are `ref_key_len` lowercase hex characters and the object a SHA-1 or
/// SHA-256 ID. Null for anything else, such as an extra field or segment.
/// Slices borrow `line`.
pub fn parseRefLine(line: []const u8) ?RefLine {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return null;
    const oid = fields.next() orelse return null;
    const seconds = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    const prefix = "refs/fx/sessions/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var segments = std.mem.splitScalar(u8, name[prefix.len..], '/');
    const key = segments.next() orelse return null;
    const worktree = segments.next() orelse return null;
    if (segments.next() != null or !isRefKey(key) or !isRefKey(worktree)) return null;
    if (!safe_git.isOid(oid, .sha1) and !safe_git.isOid(oid, .sha256)) return null;
    return .{ .name = name, .key = key, .worktree = worktree, .oid = oid, .seconds = seconds };
}

fn isRefKey(text: []const u8) bool {
    if (text.len != ref_key_len) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The commits of the newest `max_copy_exclusions` captures of `format` in
/// `list_refs` output (`parseRefLine`). A line that does not parse is
/// skipped: leaving a capture out only copies more.
fn newestCaptures(arena: Allocator, refs: []const u8, format: safe_git.ObjectFormat) Allocator.Error![]const []const u8 {
    const Entry = struct { commit: []const u8, seconds: i64 };
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line| {
        const parsed = parseRefLine(line) orelse continue;
        if (!safe_git.isOid(parsed.oid, format)) continue;
        try entries.append(arena, .{ .commit = parsed.oid, .seconds = parsed.seconds });
    }
    sort_utils.sort(Entry, entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return a.seconds > b.seconds;
        }
    }.newer);
    const kept = entries.items[0..@min(entries.items.len, max_copy_exclusions)];
    const commits = try arena.alloc([]const u8, kept.len);
    for (kept, commits) |entry, *commit| commit.* = entry.commit;
    return commits;
}

/// The reason for a partial capture: the most telling exclusion that loses
/// content, whatever the paths' order. A file that vanished mid-capture
/// shows concurrent change, so it outranks limits, which outrank secrets,
/// which outrank submodules.
fn lossReason(excluded: []const policy.Exclusion) ?policy.Reason {
    const ranked = [_]struct { policy.Reason, @FieldType(policy.Exclusion, "reason") }{
        .{ .inconsistent, .missing },
        .{ .too_large, .too_large },
        .{ .file_limit, .file_limit },
        .{ .sensitive, .sensitive },
        .{ .submodule, .submodule },
    };
    var best: ?usize = null;
    for (excluded) |entry| {
        for (ranked, 0..) |rank, i| {
            if (entry.reason == rank[1] and (best == null or i < best.?)) best = i;
        }
    }
    return if (best) |i| ranked[i][0] else null;
}

pub const EncodeError = Allocator.Error || error{InvalidOutcome};

/// Excluded paths the record names one by one; the rest are only counted.
const max_sample_paths = 32;
const max_sample_bytes = 32 * 1024;

const ExclusionReason = @FieldType(policy.Exclusion, "reason");

/// The session's `workspace_capture` item for `outcome` at `phase`, as one
/// line of JSON (D98). Exclusions are counted by reason with a bounded
/// sample, so the item stays far below the 256 KiB a session item allows
/// however many paths a capture leaves out; a path that is not UTF-8 is
/// written as hex. Fails with `InvalidOutcome` when the outcome contradicts
/// itself. Returns owned bytes; the caller frees them.
pub fn encodeRecord(alloc: Allocator, phase: Phase, outcome: Outcome) EncodeError![]u8 {
    try checkOutcome(outcome);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var by_reason: Counts = .{};
    var sample: std.ArrayList(Sample) = .empty;
    var sample_bytes: usize = 0;
    var truncated = false;
    for (outcome.excluded) |entry| {
        switch (entry.reason) {
            .sensitive => by_reason.sensitive += 1,
            .too_large => by_reason.too_large += 1,
            .file_limit => by_reason.file_limit += 1,
            .missing => by_reason.missing += 1,
            .submodule => by_reason.submodule += 1,
        }
        const utf8 = std.unicode.utf8ValidateSlice(entry.path);
        const cost = if (utf8) entry.path.len else entry.path.len * 2;
        if (sample.items.len == max_sample_paths or sample_bytes + cost > max_sample_bytes) {
            truncated = true;
            continue;
        }
        sample_bytes += cost;
        try sample.append(arena, if (utf8)
            .{ .path = entry.path, .reason = entry.reason }
        else
            .{ .path_hex = try arena.print("{x}", .{entry.path}), .reason = entry.reason });
    }
    const record: RecordJson = .{
        .phase = phase,
        .status = outcome.status,
        .reason = outcome.reason,
        .work_tree = if (outcome.repository) |repo| repo.work_tree else null,
        .ref = outcome.ref,
        .head_state = outcome.head,
        .head = switch (outcome.head) {
            .commit => |oid| oid,
            else => null,
        },
        .tree = outcome.tree,
        .commit = outcome.commit,
        .object_format = outcome.object_format,
        .listing = outcome.listing,
        .index = outcome.index,
        .comparable = outcome.comparable,
        .trigger_tool = outcome.trigger_tool,
        .excluded = .{ .total = outcome.excluded.len, .by_reason = by_reason, .sample = sample.items, .sample_truncated = truncated },
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    std.json.Stringify.value(record, .{}, &writer.writer) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

const RecordJson = struct {
    v: u8 = 1,
    phase: Phase,
    status: Status,
    reason: ?policy.Reason,
    work_tree: ?[]const u8,
    ref: ?[]const u8,
    head_state: std.meta.Tag(Head),
    head: ?[]const u8,
    tree: ?[]const u8,
    commit: ?[]const u8,
    object_format: ?safe_git.ObjectFormat,
    listing: ?Listing,
    index: ?IndexStart,
    comparable: bool,
    trigger_tool: ?[]const u8,
    excluded: struct {
        total: usize,
        by_reason: Counts,
        sample: []const Sample,
        sample_truncated: bool,
    },
};

const Counts = struct {
    sensitive: usize = 0,
    too_large: usize = 0,
    file_limit: usize = 0,
    missing: usize = 0,
    submodule: usize = 0,
};

const Sample = struct {
    path: ?[]const u8 = null,
    path_hex: ?[]const u8 = null,
    reason: ExclusionReason,
};

/// Rejects an outcome whose status, reason and object IDs disagree, so a
/// record never claims a tree for a failure or a reason the status rules out.
fn checkOutcome(outcome: Outcome) error{InvalidOutcome}!void {
    switch (outcome.status) {
        .complete => if (outcome.reason != null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .partial => if (outcome.reason == null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .failed, .unavailable => if (outcome.reason == null or outcome.tree != null or outcome.commit != null) return error.InvalidOutcome,
    }
    if (outcome.reason) |reason| {
        const allowed = switch (reason) {
            .sensitive, .too_large, .file_limit, .submodule => outcome.status == .partial,
            .timeout, .not_git, .git_refused, .index_sparse, .capture_locked, .foreign_git_dir, .cancelled, .budget, .private_root, .untracked_timeout => outcome.status == .unavailable,
            .inconsistent => outcome.status == .partial or outcome.status == .failed,
            .io_error, .invalid_request => outcome.status == .failed,
        };
        if (!allowed) return error.InvalidOutcome;
    }
    const oids = [_]?[]const u8{ outcome.tree, outcome.commit, switch (outcome.head) {
        .commit => |oid| oid,
        else => null,
    } };
    for (oids) |maybe| if (maybe) |oid| {
        const format = outcome.object_format orelse return error.InvalidOutcome;
        if (!safe_git.isOid(oid, format)) return error.InvalidOutcome;
    };
}

const Lock = struct {
    file: std.Io.File,

    fn close(self: *Lock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Takes the worktree's lock, waiting for another capture of the same
/// worktree, such as a parallel subagent's, until `deadline`. A cancel
/// request that ends the wait is `Unavailable`, and stays armed for the
/// caller's next step.
pub fn acquireLock(io: std.Io, path: []const u8, deadline: std.Io.Clock.Timestamp) error{ Busy, Unavailable }!Lock {
    return .{ .file = lockUntil(io, path, deadline, null) catch |err| return switch (err) {
        error.Canceled => error.Unavailable,
        else => |other| other,
    } };
}

/// How long a lock wait sleeps between tries.
const lock_poll_ns: u64 = 10 * std.time.ns_per_ms;

/// Opens `path`, creating it, and takes an exclusive flock on it, trying
/// again until `deadline`. The kernel releases flock when its holder dies,
/// so a crash never leaves one held. `Busy` when the deadline passed first;
/// `Unavailable`, logged, when the file cannot be opened or locked;
/// `Canceled` once `cancel` is set or on a `std.Io` cancel request, which is
/// re-armed for the caller's next step.
fn lockUntil(io: std.Io, path: []const u8, deadline: std.Io.Clock.Timestamp, cancel: ?*const std.atomic.Value(bool)) error{ Busy, Unavailable, Canceled }!std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch |err| return lockFailed(io, path, err);
    errdefer file.close(io);
    while (!(file.tryLock(io, .exclusive) catch |err| return lockFailed(io, path, err))) {
        if (pastDeadline(io, deadline)) return error.Busy;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
        io.sleep(.fromNanoseconds(lock_poll_ns), .awake) catch |err| return lockFailed(io, path, err);
    }
    return file;
}

fn lockFailed(io: std.Io, path: []const u8, err: anyerror) error{ Unavailable, Canceled } {
    if (err == error.Canceled) {
        io.recancel();
        return error.Canceled;
    }
    logIoError("lock", path, err);
    return error.Unavailable;
}

/// Whether `path` exists. Only a path the system reports missing is false;
/// any other failure, a cancel request included, is returned as it is and
/// not re-armed, so the caller decides. A check whose wrong "missing" would
/// create, replace or delete something must use this, never `exists`.
fn isPresent(io: std.Io, path: []const u8) std.Io.Dir.AccessError!bool {
    const denied = builtin.is_test and test_hooks.access_denied_suffix != null and std.mem.endsWith(u8, path, test_hooks.access_denied_suffix.?);
    const access: std.Io.Dir.AccessError!void = if (denied) error.AccessDenied else std.Io.Dir.accessAbsolute(io, path, .{});
    access catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// `isPresent`, or `fallback` when the check fails, with a cancel request
/// re-armed for the caller's next step.
fn presentOr(io: std.Io, path: []const u8, fallback: bool) bool {
    return isPresent(io, path) catch |err| {
        keepCancel(io, err);
        return fallback;
    };
}

/// Whether `path` exists, false when that cannot be checked. Only for a
/// check whose wrong answer deletes and creates nothing, such as which
/// stores to list; see `isPresent`.
pub fn exists(io: std.Io, path: []const u8) bool {
    return presentOr(io, path, false);
}

/// Re-arms a `std.Io` cancel request that `err` consumed, so the next
/// cancelation point, such as the next git run, still sees it. Call once for
/// each `error.Canceled` a helper swallows instead of returning.
fn keepCancel(io: std.Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

fn hasSharedIndex(io: std.Io, git_dir: []const u8) Allocator.Error!bool {
    // When the folder cannot be read, assume a split index: rebuilding from
    // HEAD is always correct, a copy of a split index is not.
    var dir = std.Io.Dir.openDirAbsolute(io, git_dir, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return true;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        return true;
    }) |entry| {
        if (std.mem.startsWith(u8, entry.name, "sharedindex.")) return true;
    }
    return false;
}

/// Makes sure the store exists with alternates into the user's objects. It is
/// built under a temporary name and renamed into place, so a store is either
/// absent or complete: a crash between `git init` and the alternates can never
/// leave a store that cannot read the user's objects. Everything happens under
/// a store-wide lock shared by the repository's worktrees. Null on success.
fn ensureStore(
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    store_dir: []const u8,
    git_dir: []const u8,
    common_dir: []const u8,
    format: safe_git.ObjectFormat,
    limits: safe_git.Limits,
    deadline: std.Io.Clock.Timestamp,
) Allocator.Error!?safe_git.Failure {
    const init_lock_path = try std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
    const init_lock = lockUntil(io, init_lock_path, deadline, limits.cancel) catch |err| return switch (err) {
        error.Busy => .timeout,
        error.Unavailable => .read_failed,
        error.Canceled => .cancelled,
    };
    defer init_lock.close(io);
    const alternates_line = try arena.print("{s}\n", .{try std.Io.Dir.path.join(arena, &.{ common_dir, "objects" })});
    // Only a HEAD the system reports missing means no store: a check that
    // fails otherwise, such as on a permission error or a cancel, must never
    // set a complete store aside to be deleted.
    const head = try std.Io.Dir.path.join(arena, &.{ git_dir, "HEAD" });
    if (isPresent(io, head) catch |err| return storeFailed(io, "store_check", head, err)) {
        // A store from before atomic creation may lack its alternates.
        const alternates = try std.Io.Dir.path.join(arena, &.{ git_dir, "objects", "info", "alternates" });
        if (!(isPresent(io, alternates) catch |err| return storeFailed(io, "store_check", alternates, err))) {
            writeAlternates(io, alternates, alternates_line) catch |err| return storeFailed(io, "store_alternates", alternates, err);
        }
        return null;
    }
    // A store folder without HEAD is a removal that stopped halfway; move it
    // aside so the rename below finds the name free. Its refs and objects
    // are what that removal meant to delete.
    if (isPresent(io, git_dir) catch |err| return storeFailed(io, "store_check", git_dir, err)) {
        const aside = try arena.print("{s}.tmp-aside-{d}", .{ git_dir, io_mod.nanoTimestamp() });
        std.Io.Dir.renameAbsolute(git_dir, aside, io) catch |err| return storeFailed(io, "store_set_aside", git_dir, err);
        debug_trace.logf("workspace", "event=workspace_capture_store_set_aside path={s} aside={s} reason=no_head", .{ git_dir, aside });
    }
    removeTemporaryStores(io, store_dir);
    const temporary = try arena.print("{s}.tmp-{d}", .{ git_dir, io_mod.nanoTimestamp() });
    switch (safe_git.initStore(arena, ready, temporary, format, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .spawn_failed,
    }) {
        .ok => {},
        .failed => |failure| return failure,
    }
    const info = try std.Io.Dir.path.join(arena, &.{ temporary, "objects", "info" });
    std.Io.Dir.cwd().createDirPath(io, info) catch |err| return storeFailed(io, "store_info", info, err);
    const alternates = try std.Io.Dir.path.join(arena, &.{ info, "alternates" });
    writeAlternates(io, alternates, alternates_line) catch |err| return storeFailed(io, "store_alternates", alternates, err);
    ensurePrivateDir(io, temporary) catch |err| return storeFailed(io, "store_private_dir", temporary, err);
    std.Io.Dir.renameAbsolute(temporary, git_dir, io) catch |err| return storeFailed(io, "store_rename", temporary, err);
    return null;
}

/// Logs a store check or write that failed outside git; the capture reports
/// it as `io_error`, or `cancelled` for a cancel request, which is re-armed.
fn storeFailed(io: std.Io, step: []const u8, path: []const u8, err: anyerror) safe_git.Failure {
    if (err == error.Canceled) {
        io.recancel();
        return .cancelled;
    }
    logIoError(step, path, err);
    return .read_failed;
}

fn writeAlternates(io: std.Io, path: []const u8, line: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line, .flags = .{ .permissions = .fromMode(0o600) } });
}

/// Deletes stores a crash left half built and stores set aside without HEAD.
/// Called under the store lock. Each removal, and each failed one, is logged.
fn removeTemporaryStores(io: std.Io, store_dir: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, store_dir, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        logIoError("temp_store_list", store_dir, err);
        return;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        logIoError("temp_store_list", store_dir, err);
        return;
    }) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "store.git.tmp-")) {
            if (dir.deleteTree(io, entry.name)) {
                debug_trace.logf("workspace", "event=workspace_capture_temp_store_removed store={s} name={s}", .{ store_dir, entry.name });
            } else |err| {
                keepCancel(io, err);
                debug_trace.logf("workspace", "event=workspace_capture_temp_store_remove_failed store={s} name={s} err={s}", .{ store_dir, entry.name, @errorName(err) });
            }
        }
    }
}

/// Copies `from` to `to` through a temporary file and gives the copy the
/// original's modification time.
fn copyPreservingTime(arena: Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    var source = try std.Io.Dir.openFileAbsolute(io, from, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    const bytes = try io_mod.readFileToEnd(arena, &source, max_index_bytes);
    const temporary = try arena.print("{s}.tmp", .{to});
    {
        var copy = try std.Io.Dir.createFileAbsolute(io, temporary, .{});
        defer copy.close(io);
        try copy.writeStreamingAll(io, bytes);
        try copy.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } });
    }
    try std.Io.Dir.renameAbsolute(temporary, to, io);
}

const max_index_bytes: usize = 1 << 30;

const Staged = safe_git.StagedEntry;

const Untracked = struct {
    files: []const []const u8,
    /// Folders holding their own repository, which git never enters.
    nested: []const []const u8,
};

const UntrackedListing = union(enum) {
    listed: Untracked,
    /// The deadline passed before a listing finished.
    stopped,
    /// No listing could be made.
    failed,
    /// The cancel flag ended git's listing.
    cancelled,
};

/// Untracked paths relative to the worktree root, outside `skip_folder`: the
/// native indexer's listing, or git's when the indexer cannot list exactly
/// what git would. Both stop at `limits`' deadline, and git at its cancel
/// flag too. Records the source in `outcome.listing`.
fn listUntracked(
    arena: Allocator,
    scan_allocator: Allocator,
    ready: safe_git.Ready,
    facts: safe_git.RepositoryFacts,
    skip_folder: ?[]const u8,
    limits: safe_git.Limits,
    tracked: *const std.StringHashMapUnmanaged(Staged),
    outcome: *Outcome,
) Allocator.Error!UntrackedListing {
    const io = io_mod.getIo();
    const deadline = limits.deadline.?;
    if (pastDeadline(io, deadline)) return .stopped;
    // The indexer skips folders only outside a repository, so git lists
    // when a folder must be skipped; it never enters that folder.
    if (skip_folder == null) if (try listWithIndexer(arena, scan_allocator, facts, deadline, tracked)) |listing| {
        if (listing == .listed) outcome.listing = .indexer;
        return listing;
    };
    // git starts only while time remains.
    if (pastDeadline(io, deadline)) return .stopped;
    const listing = try listWithGit(arena, ready, facts.work_tree, skip_folder, limits);
    if (listing == .listed) outcome.listing = .git;
    return listing;
}

/// The indexer's untracked listing, or null when git must list instead:
/// no task can stop the scan, or the indexer left something out or would
/// spell a name differently from git.
fn listWithIndexer(
    arena: Allocator,
    scan_allocator: Allocator,
    facts: safe_git.RepositoryFacts,
    deadline: std.Io.Clock.Timestamp,
    tracked: *const std.StringHashMapUnmanaged(Staged),
) Allocator.Error!?UntrackedListing {
    const io = io_mod.getIo();
    // Where git compares paths without case, a case-only rename shows up as
    // a new untracked spelling of a tracked file; git does not list it.
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    if (facts.ignore_case) {
        var it = tracked.keyIterator();
        while (it.next()) |path| try folded.put(arena, try std.ascii.allocLowerString(arena, path.*), {});
    }
    // The indexer's workers check the stop time themselves; a task that
    // raised a flag at the deadline could wake late while the scan holds
    // every core, as it did on Linux.
    const remaining_ns = std.Io.Clock.Timestamp.now(io, deadline.clock).durationTo(deadline).raw.toNanoseconds();
    const stop_at_ns: i64 = @intCast(std.math.clamp(@as(i128, io_mod.nanoTimestamp()) + remaining_ns, std.math.minInt(i64), std.math.maxInt(i64)));
    var result = indexer.scan(scan_allocator, facts.work_tree, .{ .candidate_cap = max_listed_paths, .stop_at_ns = stop_at_ns }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return .stopped,
        error.RootUnavailable => return null,
    };
    defer result.deinit();
    if (pastDeadline(io, deadline)) return .stopped;
    const listing = result.tree;
    // Anything the indexer left out sends the listing to git.
    if (listing.incomplete or listing.cap_reached or listing.skipped_overlong > 0 or !listing.repository) return null;
    var files: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    // A folder the indexer listed but did not enter holds its own
    // repository, exactly where git stops too.
    for (listing.folders) |folder| {
        if (folder.boundary and !tracked.contains(folder.rel)) try nested.append(arena, try arena.dupe(u8, folder.rel));
    }
    for (listing.entries, 0..) |entry, i| {
        if (i % 4096 == 4095 and pastDeadline(io, deadline)) return .stopped;
        if (tracked.contains(entry.path)) continue;
        // The indexer lists file names as the folder stores them; with
        // precomposed Unicode git compares another form of those names.
        if (facts.precompose_unicode and !isAscii(entry.path)) return null;
        switch (entry.kind) {
            .file => {
                if (facts.ignore_case and folded.contains(try std.ascii.allocLowerString(arena, entry.path))) continue;
                try files.append(arena, try arena.dupe(u8, entry.path));
            },
            .directory => {},
        }
    }
    return .{ .listed = .{ .files = files.items, .nested = nested.items } };
}

/// git's untracked listing outside `skip_folder`, which stops at `limits`.
fn listWithGit(arena: Allocator, ready: safe_git.Ready, work_tree: []const u8, skip_folder: ?[]const u8, limits: safe_git.Limits) Allocator.Error!UntrackedListing {
    const listing = switch (try safe_git.listRepository(arena, ready, work_tree, .untracked, skip_folder, limits)) {
        .ok => |stdout| stdout,
        .failed => |failure| return switch (failure) {
            .timeout => .stopped,
            .cancelled => .cancelled,
            else => .failed,
        },
    };
    var files: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        // git lists a nested repository once, as a folder with a slash.
        if (record[record.len - 1] == '/') {
            try nested.append(arena, record[0 .. record.len - 1]);
        } else {
            try files.append(arena, record);
        }
    }
    return .{ .listed = .{ .files = files.items, .nested = nested.items } };
}

fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

const max_listed_paths: usize = 1_000_000;

const Found = struct {
    present: bool,
    bytes: u64 = 0,
    kind: @FieldType(policy.Candidate, "kind") = .file,
};

const not_on_disk: Found = .{ .present = false };

/// What the disk holds at worktree paths, without following symlinks at any
/// level: a path under a symlinked folder is absent, as git sees it.
const Disk = struct {
    arena: Allocator,
    io: std.Io,
    work_tree: []const u8,
    /// Parent folders already checked: true when a real folder.
    parents: std.StringHashMapUnmanaged(bool) = .empty,

    /// Fails only when the disk cannot answer, such as a folder without read
    /// permission, or on a cancel request, which is re-armed; a missing path
    /// is `absent`.
    fn lstat(self: *Disk, path: []const u8) (Allocator.Error || error{ Unreadable, Canceled })!Found {
        var end: usize = 0;
        while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
            const parent = path[0..slash];
            const real = self.parents.get(parent) orelse blk: {
                const found = try self.statOne(parent);
                const is_dir = found.present and found.kind == .gitlink;
                try self.parents.put(self.arena, parent, is_dir);
                break :blk is_dir;
            };
            if (!real) return not_on_disk;
        }
        return self.statOne(path);
    }

    fn statOne(self: *Disk, path: []const u8) (Allocator.Error || error{ Unreadable, Canceled })!Found {
        const absolute = try std.Io.Dir.path.join(self.arena, &.{ self.work_tree, path });
        const stat = std.Io.Dir.cwd().statFile(self.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return not_on_disk,
            error.Canceled => {
                self.io.recancel();
                return error.Canceled;
            },
            else => {
                logIoError("stat", absolute, err);
                return error.Unreadable;
            },
        };
        return switch (stat.kind) {
            .sym_link => .{ .present = true, .bytes = stat.size, .kind = .symlink },
            .file => .{ .present = true, .bytes = stat.size, .kind = .file },
            // Callers decide what a folder means: a gitlink, or a gone file.
            .directory => .{ .present = true, .kind = .gitlink },
            // git records neither pipes, sockets nor devices.
            else => not_on_disk,
        };
    }
};

/// The directory for the repository whose common git directory is
/// `common_dir`: it holds the bare store (`storeGitDir`) and, beside it, one
/// directory per worktree. The worktree directories stay outside the bare
/// repository because git reserves its `worktrees/` folder and `git gc` prunes
/// it. Owned by `arena`.
fn storeDir(arena: Allocator, profile_root: []const u8, common_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ profile_root, "captures", try pathKey(arena, common_dir) });
}

/// The bare store inside a repository's `storeDir`. Owned by `arena`.
pub fn storeGitDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "store.git" });
}

/// The directory that holds one worktree's capture index, lock and scratch
/// files inside its repository's store directory, for the worktree whose
/// `worktreeIdentity` is `worktree`. Owned by `arena`.
fn worktreeDir(arena: Allocator, store_dir: []const u8, worktree: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees", try pathKey(arena, worktree) });
}

fn pathKey(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    return arena.print("{x}", .{digest[0..16]});
}

/// A store's git directory for ref commands, which touch neither an index
/// nor a worktree; git still needs both names, so they point inside the
/// store's folder.
pub fn refStore(arena: Allocator, store_dir: []const u8) Allocator.Error!safe_git.Store {
    return .{
        .git_dir = try storeGitDir(arena, store_dir),
        .index_file = try std.Io.Dir.path.join(arena, &.{ store_dir, "refs.index" }),
        .work_tree = store_dir,
        .scratch_dir = store_dir,
    };
}

/// The repository folders under `captures` whose store is complete, in name
/// order.
pub fn listStoreDirs(arena: Allocator, io: std.Io, captures: []const u8) Allocator.Error![]const []const u8 {
    var stores: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return stores.items;
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| blk: {
        keepCancel(io, err);
        break :blk null;
    }) |entry| {
        if (entry.kind != .directory or entry.name.len != 32) continue;
        const store_dir = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        if (exists(io, try std.Io.Dir.path.join(arena, &.{ store_dir, "store.git", "HEAD" }))) try stores.append(arena, store_dir);
    }
    sort_utils.sort([]const u8, stores.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return stores.items;
}

/// The store-wide lock a capture holds from before it writes the store's
/// first object (`ensureStore`). Owned by `arena`.
pub fn initLockPath(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
}

/// The folder that holds every `worktreeDir` of a store. Owned by `arena`.
pub fn worktreesDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" });
}

/// The file names of a worktree directory's capture lock and capture index.
pub const worktree_lock_name = "lock";
pub const worktree_index_name = "index";

// ---- Tests below this line ----

const testing = std.testing;

/// Plain git for fixtures and oracles. The capture itself finds its own git.
const test_git = "/usr/bin/git";
const test_unix_seconds: i64 = 1_700_000_000;
const test_deadline_ms: i64 = 20_000;
const fixture_identity = [_][]const u8{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid" };
/// Programs a repository could name stay off in oracles and probes.
const oracle_overrides = [_][]const u8{ "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" };

const EnvPair = struct { []const u8, []const u8 };

/// Real repositories under one temporary folder. fx's environment, which
/// `safe_git.environment()` reads through `io_mod.getenv`, and the fixtures'
/// git both point HOME and the global config at files inside it and turn the
/// system config off, so neither the developer's nor the machine's git config
/// reaches a test. The global config has no identity: capture commits must
/// not depend on one.
const TestRepos = struct {
    arena: Allocator,
    root: []const u8,
    home: []const u8,
    profile: []const u8,
    global_config: []const u8,
    sentinel: []const u8,
    sentinel_log: []const u8,
    env: *std.process.Environ.Map,

    fn init(arena: Allocator, dir: std.Io.Dir) !TestRepos {
        if (builtin.target.os.tag == .windows) return error.SkipZigTest;
        std.Io.Dir.accessAbsolute(testing.io, test_git, .{}) catch return error.SkipZigTest;
        switch (try safe_git.prepareStore(arena, .{})) {
            .ready => {},
            .refused => return error.SkipZigTest,
        }
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const home = try std.Io.Dir.path.join(arena, &.{ root, "home" });
        const env = try arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(arena);
        const self: TestRepos = .{
            .arena = arena,
            .root = root,
            .home = home,
            .profile = try std.Io.Dir.path.join(arena, &.{ root, "profile" }),
            .global_config = try std.Io.Dir.path.join(arena, &.{ home, ".gitconfig" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
            .sentinel_log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .env = env,
        };
        try std.Io.Dir.cwd().createDirPath(testing.io, home);
        try std.Io.Dir.cwd().createDirPath(testing.io, self.profile);
        try writeAbsolute(self.global_config, "[init]\n\tdefaultBranch = main\n[protocol \"file\"]\n\tallow = always\n");
        try env.put("HOME", home);
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(arena, &.{ home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", self.global_config);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        if (!try self.fixtureGitSupported()) return error.SkipZigTest;
        io_mod.setEnvironMap(env);
        return self;
    }

    fn deinit(self: TestRepos) void {
        _ = self;
        io_mod.resetEnvironForTest();
    }

    /// The fixtures use `--path-format`, `init -b` and `--sparse-index`.
    fn fixtureGitSupported(self: TestRepos) !bool {
        const result = try self.run(self.root, &.{ test_git, "--version" }, &.{});
        switch (result.term) {
            .exited => |code| if (code != 0) return false,
            else => return false,
        }
        const prefix = "git version ";
        if (!std.mem.startsWith(u8, result.stdout, prefix)) return false;
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, result.stdout[prefix.len..], "\n"), '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
        const minor_text = parts.next() orelse return false;
        var end: usize = 0;
        while (end < minor_text.len and std.ascii.isDigit(minor_text[end])) end += 1;
        const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch return false;
        return major > 2 or (major == 2 and minor >= 32);
    }

    fn path(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    // Files, by path relative to the temporary folder.

    fn writeAbsolute(absolute: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(testing.io, parent);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn write(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        try writeAbsolute(try self.path(sub_path), data);
    }

    fn append(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        const old = self.read(sub_path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        try self.write(sub_path, try std.mem.concat(self.arena, u8, &.{ old, data }));
    }

    fn read(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return readAbsolute(self.arena, try self.path(sub_path));
    }

    fn readAbsolute(arena: Allocator, absolute: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, absolute, arena, .limited(64 * 1024 * 1024));
    }

    fn chmod(self: TestRepos, sub_path: []const u8, mode: std.posix.mode_t) !void {
        try std.Io.Dir.cwd().setFilePermissions(testing.io, try self.path(sub_path), .fromMode(mode), .{});
    }

    fn remove(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.deleteFileAbsolute(testing.io, try self.path(sub_path));
    }

    fn rename(self: TestRepos, old: []const u8, new: []const u8) !void {
        try std.Io.Dir.renameAbsolute(try self.path(old), try self.path(new), testing.io);
    }

    fn symlink(self: TestRepos, target: []const u8, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().symLink(testing.io, target, try self.path(sub_path), .{});
    }

    fn exists(self: TestRepos, sub_path: []const u8) !bool {
        return existsAbsolute(try self.path(sub_path));
    }

    fn existsAbsolute(absolute: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(testing.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn deleteIfPresent(absolute: []const u8) !void {
        std.Io.Dir.deleteFileAbsolute(testing.io, absolute) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn setModified(self: TestRepos, sub_path: []const u8, unix_seconds: i64) !void {
        const at: std.Io.Timestamp = .{ .nanoseconds = @as(i96, unix_seconds) * std.time.ns_per_s };
        try std.Io.Dir.cwd().setTimestamps(testing.io, try self.path(sub_path), .{ .access_timestamp = .{ .new = at }, .modify_timestamp = .{ .new = at } });
    }

    /// Like `cp -p`: the copy keeps the source's modification time, so git's
    /// racy-timestamp check behaves as it does on the original index.
    fn copyKeepingTime(self: TestRepos, source: []const u8, dest: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dest, .data = try readAbsolute(self.arena, source) });
        const stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{});
        try std.Io.Dir.cwd().setTimestamps(testing.io, dest, .{ .access_timestamp = .init(stat.atime), .modify_timestamp = .{ .new = stat.mtime } });
    }

    fn randomBytes(self: TestRepos, len: usize, seed: u64) ![]const u8 {
        const bytes = try self.arena.alloc(u8, len);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(bytes);
        return bytes;
    }

    // Processes.

    fn run(self: TestRepos, cwd: []const u8, argv: []const []const u8, extra: []const EnvPair) !std.process.RunResult {
        var env = std.process.Environ.Map.init(self.arena);
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("LC_ALL", "C");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        // A fixture command never climbs out of the temporary folder into the
        // checkout that holds it.
        try env.put("GIT_CEILING_DIRECTORIES", self.root);
        var keys = self.env.iterator();
        while (keys.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
        for (extra) |pair| try env.put(pair[0], pair[1]);
        return std.process.run(self.arena, testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    fn gitArgv(self: TestRepos, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, test_git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs plain git and returns its trimmed stdout. Any failure fails the
    /// fixture, never the capture under test, and prints git's stderr.
    fn gitEnv(self: TestRepos, cwd: []const u8, args: []const []const u8, extra: []const EnvPair) ![]const u8 {
        const result = try self.run(cwd, try self.gitArgv(args), extra);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git", .{});
        for (args) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print(" failed in {s}: {s}\n", .{ cwd, result.stderr });
        return error.FixtureGitFailed;
    }

    fn git(self: TestRepos, cwd: []const u8, args: []const []const u8) ![]const u8 {
        return self.gitEnv(cwd, args, &.{});
    }

    fn gitIn(self: TestRepos, sub_path: []const u8, args: []const []const u8) ![]const u8 {
        return self.git(try self.path(sub_path), args);
    }

    fn commit(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-m", message }));
    }

    fn commitAll(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-am", message }));
    }

    fn initRepo(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(testing.io, try self.path(sub_path));
        _ = try self.gitIn(sub_path, &.{ "init", "-q", "-b", "main" });
    }

    /// The paths a capture reads, as git itself resolves them.
    fn repository(self: TestRepos, sub_path: []const u8) !Repository {
        const out = try self.gitIn(sub_path, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" });
        var lines = std.mem.splitScalar(u8, out, '\n');
        return .{
            .work_tree = lines.next() orelse return error.FixtureGitFailed,
            .git_dir = lines.next() orelse return error.FixtureGitFailed,
            .common_dir = lines.next() orelse return error.FixtureGitFailed,
        };
    }

    // Capture and store.

    fn request(self: TestRepos, repo: Repository, session_id: []const u8, limits: policy.Limits) Request {
        return .{
            .profile_root = self.profile,
            .path = repo.work_tree,
            .session_id = session_id,
            .phase = .start,
            .unix_seconds = test_unix_seconds,
            .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
            .limits = limits,
            .scan_allocator = testing.allocator,
        };
    }

    fn captureRepo(self: TestRepos, repo: Repository, session_id: []const u8) !Outcome {
        return capture(self.arena, self.request(repo, session_id, .{}));
    }

    /// The ref a capture of `repo` for `session_id` extends.
    fn sessionRef(self: TestRepos, repo: Repository, session_id: []const u8) ![]const u8 {
        return sessionRefName(self.arena, session_id, try worktreeIdentity(self.arena, repo));
    }

    fn store(self: TestRepos, repo: Repository) ![]const u8 {
        return storeGitDir(self.arena, try storeDir(self.arena, self.profile, repo.common_dir));
    }

    fn storeGit(self: TestRepos, repo: Repository, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "--git-dir", try self.store(repo) });
        try argv.appendSlice(self.arena, args);
        return self.git(self.root, argv.items);
    }

    /// One file of a stored tree, read from the store.
    fn storedFile(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) ![]const u8 {
        return self.storeGit(repo, &.{ "cat-file", "blob", try self.arena.print("{s}:{s}", .{ tree, file }) });
    }

    fn treeHas(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) !bool {
        return (try self.storeGit(repo, &.{ "ls-tree", "--name-only", tree, "--", file })).len != 0;
    }

    /// The object a store ref names, or null when the store or ref is missing.
    fn storeRef(self: TestRepos, repo: Repository, ref: []const u8) !?[]const u8 {
        const store_dir = try self.store(repo);
        if (!try existsAbsolute(store_dir)) return null;
        const result = try self.run(self.root, try self.gitArgv(&.{ "--git-dir", store_dir, "rev-parse", "-q", "--verify", ref }), &.{});
        return switch (result.term) {
            .exited => |code| if (code == 0) std.mem.trimEnd(u8, result.stdout, "\n") else null,
            else => null,
        };
    }

    fn storeRefs(self: TestRepos, repo: Repository) ![]const u8 {
        if (!try existsAbsolute(try self.store(repo))) return "";
        return self.storeGit(repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    }

    /// Runs git on the store with its alternates moved aside, so only the
    /// objects the store holds itself count. They come back afterwards.
    fn storeAlone(self: TestRepos, repo: Repository, args: []const []const u8) ![]const u8 {
        const alternates = try std.Io.Dir.path.join(self.arena, &.{ try self.store(repo), "objects", "info", "alternates" });
        const aside = try self.path("alternates.aside");
        try std.Io.Dir.renameAbsolute(alternates, aside, testing.io);
        defer std.Io.Dir.renameAbsolute(aside, alternates, testing.io) catch {};
        return self.storeGit(repo, args);
    }

    /// Whether `oid` can still be read from the user's repository.
    fn userHas(self: TestRepos, repo: Repository, oid: []const u8) !bool {
        return self.succeeds(repo.work_tree, &.{ "cat-file", "-e", oid });
    }

    /// Whether the store holds `oid` itself, without its alternates.
    fn storeAloneHas(self: TestRepos, repo: Repository, oid: []const u8) !bool {
        const alternates = try std.Io.Dir.path.join(self.arena, &.{ try self.store(repo), "objects", "info", "alternates" });
        const aside = try self.path("alternates.aside");
        try std.Io.Dir.renameAbsolute(alternates, aside, testing.io);
        defer std.Io.Dir.renameAbsolute(aside, alternates, testing.io) catch {};
        return self.succeeds(self.root, &.{ "--git-dir", try self.store(repo), "cat-file", "-e", oid });
    }

    fn succeeds(self: TestRepos, cwd: []const u8, args: []const []const u8) !bool {
        const result = try self.run(cwd, try self.gitArgv(args), &.{});
        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// Proves the store alone, without its alternates, reaches every object
    /// of every capture ref and holds `file` of `tree` as `content`.
    fn expectSelfSufficient(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8, content: []const u8) !void {
        _ = try self.storeAlone(repo, &.{ "fsck", "--connectivity-only", "--no-dangling", "--no-progress" });
        // `git` trims the output's final newline.
        try testing.expectEqualStrings(std.mem.trimEnd(u8, content, "\n"), try self.storeAlone(repo, &.{ "cat-file", "blob", try self.arena.print("{s}:{s}", .{ tree, file }) }));
    }

    /// Deletes every object the user's repository no longer reaches, as
    /// `git gc --prune=now` after dropping a branch or a staged change does.
    fn pruneUser(self: TestRepos, sub_path: []const u8) !void {
        _ = try self.gitIn(sub_path, &.{ "reflog", "expire", "--expire=now", "--all" });
        _ = try self.gitIn(sub_path, &.{ "gc", "-q", "--prune=now" });
        _ = try self.gitIn(sub_path, &.{ "prune", "--expire=now" });
    }

    // Oracles.

    /// The tree the user's own git records for the worktree as it is now:
    /// `git add -A` and `write-tree` on a copy of the worktree's index that
    /// keeps its time, minus the paths the capture leaves out on purpose.
    /// New objects go to a scratch object directory, so the oracle writes
    /// nothing into the user's repository or the store.
    fn expectedTree(self: TestRepos, repo: Repository, excluded: []const []const u8) ![]const u8 {
        const index_file = try self.path("oracle.index");
        try deleteIfPresent(index_file);
        const user_index = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, "index" });
        if (try existsAbsolute(user_index)) try self.copyKeepingTime(user_index, index_file);
        const objects = try self.path("oracle-objects");
        try std.Io.Dir.cwd().deleteTree(testing.io, objects);
        try std.Io.Dir.cwd().createDirPath(testing.io, objects);
        const env = [_]EnvPair{
            .{ "GIT_INDEX_FILE", index_file },
            .{ "GIT_OBJECT_DIRECTORY", objects },
            .{ "GIT_ALTERNATE_OBJECT_DIRECTORIES", try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "objects" }) },
        };
        _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "add", "-A" }), &env);
        for (excluded) |excluded_path| {
            _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "rm", "-q", "--cached", "--ignore-unmatch", "--", excluded_path }), &env);
        }
        return self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{"write-tree"}), &env);
    }

    /// Everything a capture must leave as it found it in the user's
    /// repository, read without refreshing the index.
    fn userState(self: TestRepos, repo: Repository) ![]const u8 {
        const no_locks = [_]EnvPair{.{ "GIT_OPTIONAL_LOCKS", "0" }};
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        try w.print("status:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "status", "--porcelain=v1", "-uall" }), &no_locks)});
        try w.print("index:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "ls-files", "-s", "-v" }), &no_locks)});
        try w.print("refs:\n{s}\n", .{try self.gitEnv(repo.work_tree, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, &no_locks)});
        for ([_][]const u8{ "index", "HEAD" }) |name| {
            const file = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, name });
            if (!try existsAbsolute(file)) {
                try w.print("{s}: none\n", .{name});
                continue;
            }
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try readAbsolute(self.arena, file), &digest, .{});
            const stat = try std.Io.Dir.cwd().statFile(testing.io, file, .{});
            try w.print("{s}: {x} {d}\n", .{ name, digest, stat.mtime.nanoseconds });
        }
        const config = try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "config" });
        try w.print("config:\n{s}\n", .{try readAbsolute(self.arena, config)});
        return out.written();
    }

    /// Checks `tree` out of the store into an empty folder and compares each
    /// of `paths` with the worktree: bytes, executable bit and symlink target.
    /// Proves the store, alone or through its alternates, holds every object.
    fn expectRestores(self: TestRepos, repo: Repository, tree: []const u8, paths: []const []const u8) !void {
        const out = try self.path("restore");
        try std.Io.Dir.cwd().deleteTree(testing.io, out);
        try std.Io.Dir.cwd().createDirPath(testing.io, out);
        const index_file = try self.path("restore.index");
        try deleteIfPresent(index_file);
        const env = [_]EnvPair{.{ "GIT_INDEX_FILE", index_file }};
        const store_dir = try self.store(repo);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "read-tree", tree }, &env);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "checkout-index", "-a", "-f" }, &env);
        for (paths) |rel| {
            const source = try std.Io.Dir.path.join(self.arena, &.{ repo.work_tree, rel });
            const restored = try std.Io.Dir.path.join(self.arena, &.{ out, rel });
            const source_stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{ .follow_symlinks = false });
            const restored_stat = std.Io.Dir.cwd().statFile(testing.io, restored, .{ .follow_symlinks = false }) catch |err| {
                std.debug.print("restore is missing {s}\n", .{rel});
                return err;
            };
            try testing.expectEqual(source_stat.kind, restored_stat.kind);
            if (source_stat.kind == .sym_link) {
                var source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var restored_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const source_len = try std.Io.Dir.cwd().readLink(testing.io, source, &source_buf);
                const restored_len = try std.Io.Dir.cwd().readLink(testing.io, restored, &restored_buf);
                try testing.expectEqualStrings(source_buf[0..source_len], restored_buf[0..restored_len]);
                continue;
            }
            try testing.expectEqualSlices(u8, try readAbsolute(self.arena, source), try readAbsolute(self.arena, restored));
            try testing.expectEqual(source_stat.permissions.toMode() & 0o100, restored_stat.permissions.toMode() & 0o100);
        }
    }

    /// How many times the sentinel program ran since the last call.
    fn sentinelRuns(self: TestRepos) !usize {
        const data = readAbsolute(self.arena, self.sentinel_log) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        try std.Io.Dir.deleteFileAbsolute(testing.io, self.sentinel_log);
        return std.mem.count(u8, data, "ran\n");
    }

    // Repository shapes a capture must store as the user's git would.

    fn in(self: TestRepos, repo_name: []const u8, rel: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ repo_name, rel });
    }

    /// `make_repo`: a committed repository with every shape the capture must
    /// handle.
    fn makeShapes(self: TestRepos, name: []const u8) !void {
        try self.initRepo(name);
        const files = [_]EnvPair{
            .{ "a.txt", "one\n" },
            .{ "dir/b.txt", "b\n" },
            .{ "space name.txt", "space\n" },
            .{ "\xc3\xb1and\xc3\xba.txt", "unicode\n" },
            .{ "nested/.gitignore", "tmp/\n" },
            .{ "nested/c.txt", "c\n" },
            .{ "todelete.txt", "delete me\n" },
            .{ "torename.txt", "rename me\n" },
            .{ ".gitignore", "*.log\n" },
            .{ "keep.log", "tracked but ignored\n" },
            .{ "exec.sh", "#!/bin/sh\necho hi\n" },
        };
        for (files) |file| try self.write(try self.in(name, file[0]), file[1]);
        try self.chmod(try self.in(name, "exec.sh"), 0o755);
        try self.symlink("a.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "bin.dat"), try self.randomBytes(4096, 1));
        _ = try self.gitIn(name, &.{ "add", "-A" });
        _ = try self.gitIn(name, &.{ "add", "-f", "keep.log" });
        try self.commit(name, "base");
    }

    /// `dirty_repo`. `big.bin` is larger than `shapes_limits` allows for an
    /// untracked file.
    fn dirtyShapes(self: TestRepos, name: []const u8) !void {
        try self.append(try self.in(name, "a.txt"), "two\n");
        try self.append(try self.in(name, "dir/b.txt"), "staged\n");
        _ = try self.gitIn(name, &.{ "add", "dir/b.txt" });
        try self.append(try self.in(name, "dir/b.txt"), "unstaged\n");
        try self.chmod(try self.in(name, "exec.sh"), 0o644);
        try self.remove(try self.in(name, "todelete.txt"));
        try self.rename(try self.in(name, "torename.txt"), try self.in(name, "renamed.txt"));
        try self.remove(try self.in(name, "link"));
        try self.symlink("dir/b.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "new.txt"), "new\n");
        try self.write(try self.in(name, "newdir/x.txt"), "x\n");
        try self.write(try self.in(name, "new.bin"), try self.randomBytes(1000, 2));
        try self.write(try self.in(name, "debug.log"), "ignored\n");
        try self.write(try self.in(name, "nested/tmp/t.txt"), "t\n");
        try self.write(try self.in(name, "local.txt"), "local\n");
        try self.append(try self.in(name, ".git/info/exclude"), "local.txt\n");
        try self.write(try self.in(name, ".env"), "SECRET=1\n");
        try self.write(try self.in(name, "big.bin"), try self.randomBytes(100 * 1024, 3));
        try self.append(try self.in(name, "keep.log"), "more tracked-ignored\n");
    }

    /// A main worktree and a linked `side` worktree, each on its own branch
    /// with a different `out/b`, both in a sparse cone that leaves `out/` off
    /// disk.
    fn makeTwoWorktrees(self: TestRepos) !void {
        try self.initRepo("wt-main");
        try self.write("wt-main/in/a", "i\n");
        try self.write("wt-main/out/b", "main\n");
        _ = try self.gitIn("wt-main", &.{ "add", "-A" });
        try self.commit("wt-main", "base");
        _ = try self.gitIn("wt-main", &.{ "worktree", "add", "-q", "-b", "side", try self.path("wt-side") });
        try self.write("wt-side/out/b", "side\n");
        try self.commitAll("wt-side", "side");
        _ = try self.gitIn("wt-side", &.{ "sparse-checkout", "set", "--cone", "in" });
        _ = try self.gitIn("wt-main", &.{ "sparse-checkout", "set", "--cone", "in" });
    }
};

const shapes_limits: policy.Limits = .{ .untracked_file_bytes = 64 * 1024 };
const shapes_excluded = [_][]const u8{ ".env", "big.bin" };
const shapes_restored = [_][]const u8{
    "a.txt",       "dir/b.txt", "exec.sh", "link",         "bin.dat",  "space name.txt", "\xc3\xb1and\xc3\xba.txt",
    "renamed.txt", "new.txt",   "new.bin", "newdir/x.txt", "keep.log", "nested/c.txt",   "nested/.gitignore",
};

fn printOutcome(outcome: Outcome) void {
    std.debug.print("capture outcome: status={s} reason={s} tree={s}\n", .{
        @tagName(outcome.status),
        if (outcome.reason) |reason| @tagName(reason) else "none",
        outcome.tree orelse "none",
    });
}

/// A capture that wrote a tree and a commit; returns the tree.
fn expectStored(outcome: Outcome) ![]const u8 {
    switch (outcome.status) {
        .complete, .partial => {},
        .failed, .unavailable => {
            printOutcome(outcome);
            return error.TestExpectedStoredCapture;
        },
    }
    const tree = outcome.tree orelse return error.TestExpectedTree;
    if (outcome.commit == null) return error.TestExpectedCommit;
    if (outcome.status == .partial and outcome.reason == null) return error.TestExpectedReason;
    return tree;
}

fn expectComplete(outcome: Outcome) ![]const u8 {
    const tree = try expectStored(outcome);
    if (outcome.status != .complete) printOutcome(outcome);
    try testing.expectEqual(Status.complete, outcome.status);
    try testing.expect(outcome.reason == null);
    return tree;
}

/// A capture that wrote nothing and says why.
fn expectNotStored(outcome: Outcome) !void {
    if (outcome.status == .complete or outcome.status == .partial) {
        printOutcome(outcome);
        return error.TestExpectedNoCapture;
    }
    try testing.expect(outcome.reason != null);
    try testing.expect(outcome.tree == null);
    try testing.expect(outcome.commit == null);
}

fn exclusionReason(outcome: Outcome, path: []const u8) ?ExclusionReason {
    for (outcome.excluded) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.reason;
    }
    return null;
}

fn expectExcluded(outcome: Outcome, path: []const u8, reason: ExclusionReason) !void {
    const found = exclusionReason(outcome, path) orelse {
        std.debug.print("{s} is not in the capture's exclusions\n", .{path});
        return error.TestExpectedExclusion;
    };
    try testing.expectEqual(reason, found);
}

const CaptureJob = struct {
    arena_state: std.heap.ArenaAllocator,
    request: Request,
    outcome: ?Outcome = null,

    fn run(job: *CaptureJob) void {
        job.outcome = capture(job.arena_state.allocator(), job.request) catch null;
    }
};

/// Starts every job on its own thread at once and waits for all of them.
fn captureConcurrently(jobs: []CaptureJob) !void {
    var threads: [2]std.Thread = undefined;
    std.debug.assert(jobs.len <= threads.len);
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (jobs) |*job| {
        threads[started] = try std.Thread.spawn(.{}, CaptureJob.run, .{job});
        started += 1;
    }
}

/// Sets a file's times to longer ago than any capture can run.
fn makeStale(absolute: []const u8) !void {
    const now = std.Io.Timestamp.now(testing.io, .real);
    const old: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - (stale_lock_ms + 60_000) * std.time.ns_per_ms };
    try std.Io.Dir.cwd().setTimestamps(testing.io, absolute, .{ .access_timestamp = .{ .new = old }, .modify_timestamp = .{ .new = old } });
}

/// Replaces `absolute` with a named pipe.
fn replaceWithFifo(repos: TestRepos, absolute: []const u8) !void {
    const mkfifo = "/usr/bin/mkfifo";
    std.Io.Dir.accessAbsolute(testing.io, mkfifo, .{}) catch return error.SkipZigTest;
    try TestRepos.deleteIfPresent(absolute);
    const result = try repos.run(repos.root, &.{ mkfifo, absolute }, &.{});
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.FixtureMkfifoFailed;
}

/// Opens a named pipe for writing, without blocking, from `after_ms` on
/// until `done`, so a reader a regression left blocked on it wakes at end of
/// file: its test then fails on the time taken instead of hanging the suite.
const FifoGuard = struct {
    path: [:0]const u8,
    after_ms: i64,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *FifoGuard) void {
        const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
        while (!self.done.load(.acquire)) {
            if (started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds() >= self.after_ms) {
                const fd = std.c.open(self.path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true });
                if (fd >= 0) _ = std.c.close(fd);
            }
            io_mod.sleep(20 * std.time.ns_per_ms);
        }
    }
};

/// How long the pipe tests let a capture run before their guard wakes a
/// blocked reader; a capture that took this long was blocked. Past the
/// first capture's budget, which a capture beside a pipe index runs on.
const fifo_guard_ms: i64 = first_capture_budget_ms + 4_000;

/// Captures `repo` with a 2 s deadline while a `FifoGuard` watches `fifo`.
/// Returns the outcome and the time it took.
fn captureBesideFifo(repos: TestRepos, repo: Repository, fifo: []const u8) !struct { Outcome, i64 } {
    var guard: FifoGuard = .{ .path = try repos.arena.dupeSentinel(u8, fifo, 0), .after_ms = fifo_guard_ms };
    const thread = try std.Thread.spawn(.{}, FifoGuard.run, .{&guard});
    defer {
        guard.done.store(true, .release);
        thread.join();
    }
    var request = repos.request(repo, "pipe", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(2000) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    const outcome = try capture(repos.arena, request);
    return .{ outcome, started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds() };
}

test "capture store: dirty worktree matches the user's git, restores byte for byte and leaves the repository untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");
    const before = try repos.userState(repo);
    const expected = try repos.expectedTree(repo, &shapes_excluded);
    const head = try repos.gitIn("repo", &.{ "rev-parse", "HEAD" });

    const outcome = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expect(outcome.reason.? == .sensitive or outcome.reason.? == .too_large);
    try testing.expect(!outcome.comparable);
    try expectExcluded(outcome, ".env", .sensitive);
    try expectExcluded(outcome, "big.bin", .too_large);
    for (outcome.excluded) |entry| {
        try testing.expect(std.mem.eql(u8, entry.path, ".env") or std.mem.eql(u8, entry.path, "big.bin"));
    }
    try testing.expectEqualStrings(head, outcome.head.commit);
    try testing.expectEqual(@as(?safe_git.ObjectFormat, .sha1), outcome.object_format);
    try testing.expectEqual(@as(?IndexStart, .copied), outcome.index);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
    try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "one"))).?);
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", tree }));

    try testing.expect(try repos.treeHas(repo, tree, "keep.log"));
    for ([_][]const u8{ "local.txt", "todelete.txt", "torename.txt", "debug.log", "nested/tmp", ".env", "big.bin" }) |absent| {
        try testing.expect(!try repos.treeHas(repo, tree, absent));
    }
    try testing.expectEqualStrings("100644", (try repos.storeGit(repo, &.{ "ls-tree", tree, "exec.sh" }))[0..6]);
    try testing.expectEqualStrings("120000", (try repos.storeGit(repo, &.{ "ls-tree", tree, "link" }))[0..6]);
    try repos.expectRestores(repo, tree, &shapes_restored);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: successive captures chain on the session ref and follow the worktree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");
    const ref = try repos.sessionRef(repo, "one");
    const ref_parent = try repos.arena.print("{s}^", .{ref});

    const first = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    _ = try expectStored(first);

    // A previous untracked file goes away and another becomes ignored.
    try repos.remove("repo/new.txt");
    try repos.append("repo/.gitignore", "newdir/\n");
    try repos.write("repo/later.txt", "later\n");
    const expected_second = try repos.expectedTree(repo, &shapes_excluded);
    const second = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    const second_tree = try expectStored(second);
    try testing.expectEqualStrings(expected_second, second_tree);
    try testing.expectEqual(@as(?IndexStart, .persisted), second.index);
    try testing.expect(!try repos.treeHas(repo, second_tree, "new.txt"));
    try testing.expect(!try repos.treeHas(repo, second_tree, "newdir"));
    try testing.expect(try repos.treeHas(repo, second_tree, "later.txt"));
    try testing.expectEqualStrings("2", try repos.storeGit(repo, &.{ "rev-list", "--count", ref }));
    try testing.expectEqualStrings(second.commit.?, (try repos.storeRef(repo, ref)).?);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", ref_parent }));

    // The user commits the same state: the capture equals the new commit's tree.
    try repos.remove("repo/.env");
    try repos.remove("repo/big.bin");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commit("repo", "work");
    const third = try repos.captureRepo(repo, "one");
    try testing.expectEqualStrings(try repos.gitIn("repo", &.{ "rev-parse", "HEAD^{tree}" }), try expectComplete(third));
    try testing.expect(third.comparable);
    try testing.expectEqualStrings(try repos.gitIn("repo", &.{ "rev-parse", "HEAD" }), third.head.commit);
    try testing.expectEqualStrings("3", try repos.storeGit(repo, &.{ "rev-list", "--count", ref }));
    try testing.expectEqualStrings(second.commit.?, try repos.storeGit(repo, &.{ "rev-parse", ref_parent }));
    // Capture ref updates keep no reflog that would hold old captures.
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "logs", "refs", "fx" })));
}

test "capture store: captures on the session ref survive gc --prune=now in the store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");

    const first_tree = try expectStored(try capture(repos.arena, repos.request(repo, "one", shapes_limits)));
    const first_blob = try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:new.txt", .{first_tree}) });
    try repos.write("repo/new.txt", "changed after the first capture\n");
    const second_tree = try expectStored(try capture(repos.arena, repos.request(repo, "one", shapes_limits)));

    _ = try repos.storeGit(repo, &.{ "gc", "-q", "--prune=now" });
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", first_tree }));
    try testing.expectEqualStrings("blob", try repos.storeGit(repo, &.{ "cat-file", "-t", first_blob }));
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", second_tree }));
    try repos.expectRestores(repo, second_tree, &shapes_restored);
}

test "capture store: a staged blob the user drops and prunes stays readable from the store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    // The second capture extends the first, so its copy leaves out what the
    // first holds.
    _ = try expectComplete(try repos.captureRepo(repo, "s"));
    try repos.write("repo/staged.txt", "staged once\n");
    _ = try repos.gitIn("repo", &.{ "add", "staged.txt" });
    const tree = try expectComplete(try repos.captureRepo(repo, "s"));
    const blob = try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:staged.txt", .{tree}) });

    // The user stages other content, drops it, and prunes.
    try repos.write("repo/staged.txt", "staged twice\n");
    _ = try repos.gitIn("repo", &.{ "add", "staged.txt" });
    _ = try repos.gitIn("repo", &.{ "rm", "-q", "--cached", "staged.txt" });
    try repos.remove("repo/staged.txt");
    try repos.pruneUser("repo");
    try testing.expect(!try repos.userHas(repo, blob));

    try repos.expectSelfSufficient(repo, tree, "staged.txt", "staged once\n");
    try repos.expectSelfSufficient(repo, tree, "a.txt", "one\n");
}

test "capture store: a file of a branch the user deletes and prunes stays readable from the store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    _ = try expectComplete(try repos.captureRepo(repo, "a"));
    _ = try repos.gitIn("repo", &.{ "checkout", "-q", "-b", "feature" });
    try repos.write("repo/feature.txt", "only on the branch\n");
    _ = try repos.gitIn("repo", &.{ "add", "feature.txt" });
    try repos.commit("repo", "feature");
    // A new session's first capture has no parent: its copy leaves out what
    // the store's newest captures hold.
    const tree = try expectComplete(try repos.captureRepo(repo, "b"));
    const blob = try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:feature.txt", .{tree}) });

    _ = try repos.gitIn("repo", &.{ "checkout", "-q", "main" });
    _ = try repos.gitIn("repo", &.{ "branch", "-q", "-D", "feature" });
    try repos.pruneUser("repo");
    try testing.expect(!try repos.userHas(repo, blob));

    try repos.expectSelfSufficient(repo, tree, "feature.txt", "only on the branch\n");
}

test "capture store: the object copy stops at the deadline, and a failed copy leaves the ref alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "s");
    _ = try expectComplete(first);

    // A tree only the user's repository holds.
    try repos.write("repo/late.txt", "late\n");
    _ = try repos.gitIn("repo", &.{ "add", "late.txt" });
    const tree = try repos.gitIn("repo", &.{"write-tree"});
    const ready = switch (try safe_git.prepareStore(repos.arena, .{})) {
        .ready => |value| value,
        .refused => return error.SkipZigTest,
    };
    const scratch = try repos.path("copy-scratch");
    try std.Io.Dir.cwd().createDirPath(testing.io, scratch);
    const store: safe_git.Store = .{
        .git_dir = try repos.store(repo),
        .index_file = try repos.path("copy-index"),
        .work_tree = repo.work_tree,
        .scratch_dir = scratch,
    };
    const expired: safe_git.Limits = .{ .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) }) };
    try testing.expectEqual(safe_git.Failure.timeout, (try copyObjects(repos.arena, testing.allocator, ready, store, .sha1, tree, &.{first.commit.?}, expired)).?);
    try testing.expect(!try repos.storeAloneHas(repo, tree));
    try testing.expect(try copyObjects(repos.arena, testing.allocator, ready, store, .sha1, tree, &.{first.commit.?}, .{}) == null);
    try testing.expect(try repos.storeAloneHas(repo, tree));
    try testing.expect(try repos.storeAloneHas(repo, try repos.arena.print("{s}:late.txt", .{tree})));

    // A copy that fails moves no ref, and the capture claims no tree.
    if (std.c.getuid() == 0) return;
    const pack_dir = try std.Io.Dir.path.join(repos.arena, &.{ store.git_dir, "objects", "pack" });
    try std.Io.Dir.cwd().setFilePermissions(testing.io, pack_dir, .fromMode(0o500), .{});
    defer std.Io.Dir.cwd().setFilePermissions(testing.io, pack_dir, .fromMode(0o700), .{}) catch {};
    // Staged, so only the user's objects hold it and the copy must write a
    // pack; what the store already holds in its packs is not copied again.
    try repos.write("repo/later.txt", "later\n");
    _ = try repos.gitIn("repo", &.{ "add", "later.txt" });
    const failed = try repos.captureRepo(repo, "s");
    try expectNotStored(failed);
    try testing.expectEqual(policy.Reason.io_error, failed.reason.?);
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "s"))).?);
    try std.Io.Dir.cwd().setFilePermissions(testing.io, pack_dir, .fromMode(0o700), .{});
    _ = try expectComplete(try repos.captureRepo(repo, "s"));
}

test "capture store: repository without commits captures its files with no head" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("unborn");
    try repos.write("unborn/u.txt", "u\n");
    try repos.write("unborn/d/v.txt", "v\n");
    const repo = try repos.repository("unborn");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "u");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expect(outcome.head == .unborn);
    try repos.expectRestores(repo, outcome.tree.?, &.{ "u.txt", "d/v.txt" });
}

test "capture store: linked worktree has its own capture index and shares the repository's store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    _ = try repos.gitIn("repo", &.{ "worktree", "add", "-q", try repos.path("linked"), "-b", "side" });
    try repos.append("linked/a.txt", "wt change\n");
    try repos.write("linked/wt.txt", "wt new\n");
    try repos.write("repo/main-only.txt", "main\n");
    const main = try repos.repository("repo");
    const linked = try repos.repository("linked");
    try testing.expectEqualStrings(main.common_dir, linked.common_dir);
    try testing.expect(!std.mem.eql(u8, main.git_dir, linked.git_dir));
    const expected_linked = try repos.expectedTree(linked, &.{});
    const expected_main = try repos.expectedTree(main, &.{});

    const linked_outcome = try repos.captureRepo(linked, "w");
    try testing.expectEqualStrings(expected_linked, try expectComplete(linked_outcome));
    try testing.expectEqualStrings(try repos.gitIn("linked", &.{ "rev-parse", "HEAD" }), linked_outcome.head.commit);
    const main_outcome = try repos.captureRepo(main, "m");
    try testing.expectEqualStrings(expected_main, try expectComplete(main_outcome));
    try testing.expect(!try repos.treeHas(main, main_outcome.tree.?, "wt.txt"));
    try testing.expect(!try repos.treeHas(linked, linked_outcome.tree.?, "main-only.txt"));

    const store_dir = try repos.store(linked);
    try testing.expectEqualStrings(store_dir, try repos.store(main));
    const alternates = try TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "objects", "info", "alternates" }));
    try testing.expectEqualStrings(try std.Io.Dir.path.join(repos.arena, &.{ linked.common_dir, "objects" }), std.mem.trimEnd(u8, alternates, "\n"));
    const repo_dir = try storeDir(repos.arena, repos.profile, linked.common_dir);
    const linked_dir = try worktreeDir(repos.arena, repo_dir, try worktreeIdentity(repos.arena, linked));
    const main_dir = try worktreeDir(repos.arena, repo_dir, try worktreeIdentity(repos.arena, main));
    try testing.expect(!std.mem.eql(u8, linked_dir, main_dir));
    try testing.expect(try TestRepos.existsAbsolute(linked_dir));
    try testing.expect(try TestRepos.existsAbsolute(main_dir));
}

test "capture store: submodule is recorded as a gitlink at its new HEAD and reported partial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("subsrc");
    try repos.write("subsrc/s.txt", "s1\n");
    _ = try repos.gitIn("subsrc", &.{ "add", "-A" });
    try repos.commit("subsrc", "s1");
    try repos.initRepo("withsub");
    try repos.write("withsub/m.txt", "m\n");
    _ = try repos.gitIn("withsub", &.{ "-c", "protocol.file.allow=always", "submodule", "-q", "add", try repos.path("subsrc"), "sub" });
    try repos.commit("withsub", "with sub");
    try repos.append("withsub/sub/s.txt", "s2\n");
    try repos.commitAll("withsub/sub", "s2");
    try repos.append("withsub/sub/s.txt", "dirty inside\n");
    const sub_head = try repos.gitIn("withsub/sub", &.{ "rev-parse", "HEAD" });
    const repo = try repos.repository("withsub");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "m");
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings(try repos.arena.print("160000 commit {s}\tsub", .{sub_head}), try repos.storeGit(repo, &.{ "ls-tree", tree, "sub" }));
    // The submodule's own dirty content is not captured, so the capture is
    // partial: workspace_capture excludes a present gitlink as `submodule`.
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.submodule, outcome.reason.?);
    try expectExcluded(outcome, "sub", .submodule);
    try testing.expect(!outcome.comparable);
}

test "capture store: concurrent captures of one worktree both finish in turn and never corrupt the store" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("conc");
    try repos.dirtyShapes("conc");
    const repo = try repos.repository("conc");
    _ = try expectStored(try capture(repos.arena, repos.request(repo, "c1", shapes_limits)));
    try repos.append("conc/a.txt", "race\n");
    const expected = try repos.expectedTree(repo, &shapes_excluded);

    var jobs = [_]CaptureJob{
        .{ .arena_state = .init(testing.allocator), .request = repos.request(repo, "c1", shapes_limits) },
        .{ .arena_state = .init(testing.allocator), .request = repos.request(repo, "c2", shapes_limits) },
    };
    defer for (&jobs) |*job| job.arena_state.deinit();
    try captureConcurrently(&jobs);

    var stored: usize = 0;
    for (jobs) |job| {
        const outcome = job.outcome orelse return error.TestCaptureReturnedError;
        switch (outcome.status) {
            .complete, .partial => {
                stored += 1;
                try testing.expectEqualStrings(expected, try expectStored(outcome));
                const ref = try repos.sessionRef(repo, job.request.session_id);
                try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, ref)).?);
            },
            // The second capture waits for the first one's lock.
            .unavailable, .failed => {
                printOutcome(outcome);
                return error.TestUnexpectedFailedCapture;
            },
        }
    }
    try testing.expectEqual(@as(usize, 2), stored);
    const fsck = try repos.run(repos.root, try repos.gitArgv(&.{ "--git-dir", try repos.store(repo), "fsck", "--no-dangling" }), &.{});
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, fsck.term);
    for ([_][]const u8{ "error", "missing", "broken" }) |word| {
        try testing.expect(std.mem.find(u8, fsck.stdout, word) == null);
        try testing.expect(std.mem.find(u8, fsck.stderr, word) == null);
    }
    // The lock leaves with the captures that held it.
    try testing.expectEqualStrings(expected, try expectStored(try capture(repos.arena, repos.request(repo, "c1", shapes_limits))));
}

test "capture store: repository core.autocrlf is applied, so the tree matches the user's and stays comparable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("eol");
    try repos.write("eol/base.txt", "base\n");
    _ = try repos.gitIn("eol", &.{ "add", "-A" });
    try repos.commit("eol", "base");
    _ = try repos.gitIn("eol", &.{ "config", "core.autocrlf", "input" });
    try repos.write("eol/base.txt", "base\r\nmore\r\n");
    try repos.write("eol/crlf.txt", "a\r\nb\r\n");
    const repo = try repos.repository("eol");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "e");
    const tree = try expectComplete(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expect(outcome.comparable);
    try testing.expectEqualStrings("a\nb", try repos.storedFile(repo, tree, "crlf.txt"));
    try testing.expectEqualStrings("base\nmore", try repos.storedFile(repo, tree, "base.txt"));
}

test "capture store: repository filters, fsmonitor and hooks never run during a capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("trap");
    try repos.dirtyShapes("trap");
    try TestRepos.writeAbsolute(repos.sentinel, try repos.arena.print("#!/bin/sh\necho ran >> '{s}'\ncat\n", .{repos.sentinel_log}));
    try std.Io.Dir.cwd().setFilePermissions(testing.io, repos.sentinel, .fromMode(0o755), .{});
    try repos.write("trap/.gitattributes", "*.txt filter=evil\n");
    _ = try repos.gitIn("trap", &.{ "config", "filter.evil.clean", repos.sentinel });
    _ = try repos.gitIn("trap", &.{ "config", "filter.evil.process", repos.sentinel });
    _ = try repos.gitIn("trap", &.{ "config", "core.fsmonitor", repos.sentinel });
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("trap/.git/hooks"));
    for ([_][]const u8{ "post-index-change", "reference-transaction", "pre-commit", "post-checkout" }) |hook| {
        try repos.symlink(repos.sentinel, try repos.arena.print("trap/.git/hooks/{s}", .{hook}));
    }
    const repo = try repos.repository("trap");
    _ = try repos.sentinelRuns();

    _ = try expectStored(try capture(repos.arena, repos.request(repo, "x", shapes_limits)));
    try testing.expectEqual(@as(usize, 0), try repos.sentinelRuns());

    // Control: the user's plain git in the same repository runs them.
    _ = try repos.run(repo.work_tree, try repos.gitArgv(&.{ "add", "-A" }), &.{});
    _ = try repos.run(repo.work_tree, try repos.gitArgv(&.{ "reset", "-q" }), &.{});
    try testing.expect(try repos.sentinelRuns() > 0);
}

test "capture store: sparse checkout keeps tracked files that are off disk on purpose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sparse");
    try repos.write("sparse/in/a", "i\n");
    try repos.write("sparse/out/b", "o\n");
    _ = try repos.gitIn("sparse", &.{ "add", "-A" });
    try repos.commit("sparse", "base");
    _ = try repos.gitIn("sparse", &.{ "sparse-checkout", "set", "--cone", "in" });
    try testing.expect(!try repos.exists("sparse/out/b"));
    const repo = try repos.repository("sparse");
    const before = try repos.userState(repo);

    const clean = try repos.captureRepo(repo, "sp");
    try testing.expectEqualStrings(try repos.gitIn("sparse", &.{ "rev-parse", "HEAD^{tree}" }), try expectComplete(clean));
    try testing.expectEqualStrings(before, try repos.userState(repo));

    try repos.append("sparse/in/a", "edited\n");
    const expected = try repos.expectedTree(repo, &.{});
    const tree = try expectComplete(try repos.captureRepo(repo, "sp"));
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings("o", try repos.storedFile(repo, tree, "out/b"));
}

test "capture store: split index rebuilds the capture index from HEAD and lists with git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("split");
    _ = try repos.gitIn("split", &.{ "config", "core.splitIndex", "true" });
    try repos.write("split/x", "x\n");
    try repos.write("split/d/y", "y\n");
    _ = try repos.gitIn("split", &.{ "add", "-A" });
    try repos.commit("split", "base");
    try repos.append("split/x", "more\n");
    try repos.write("split/n.txt", "new\n");
    // Fixture check: the index really is split.
    var git_dir = try std.Io.Dir.cwd().openDir(testing.io, try repos.path("split/.git"), .{ .iterate = true });
    defer git_dir.close(testing.io);
    var entries = git_dir.iterate();
    var shared = false;
    while (try entries.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "sharedindex.")) shared = true;
    }
    try testing.expect(shared);
    const repo = try repos.repository("split");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "si");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expectEqual(@as(?IndexStart, .rebuilt), outcome.index);
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
}

test "capture store: sparse index is unavailable with index_sparse and writes no tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sparseidx");
    try repos.write("sparseidx/in/a", "i\n");
    try repos.write("sparseidx/out/b", "o\n");
    _ = try repos.gitIn("sparseidx", &.{ "add", "-A" });
    try repos.commit("sparseidx", "base");
    _ = try repos.gitIn("sparseidx", &.{ "sparse-checkout", "set", "--cone", "--sparse-index", "in" });
    const repo = try repos.repository("sparseidx");
    const before = try repos.userState(repo);

    const outcome = try repos.captureRepo(repo, "sx");
    try expectNotStored(outcome);
    try testing.expectEqual(Status.unavailable, outcome.status);
    try testing.expectEqual(policy.Reason.index_sparse, outcome.reason.?);
    try testing.expect(try repos.storeRef(repo, try repos.sessionRef(repo, "sx")) == null);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: assume-unchanged and present skip-worktree files are captured from disk and the user's bits stay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("flags");
    for ([_][]const u8{ "flags/au.txt", "flags/sw.txt", "flags/plain.txt" }) |file| try repos.write(file, "one\n");
    _ = try repos.gitIn("flags", &.{ "add", "-A" });
    try repos.commit("flags", "base");
    _ = try repos.gitIn("flags", &.{ "update-index", "--assume-unchanged", "au.txt" });
    _ = try repos.gitIn("flags", &.{ "update-index", "--skip-worktree", "sw.txt" });
    try repos.write("flags/au.txt", "two\n");
    try repos.write("flags/sw.txt", "two\n");
    const repo = try repos.repository("flags");
    const before = try repos.userState(repo);

    const tree = try expectComplete(try repos.captureRepo(repo, "fl"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "au.txt"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "sw.txt"));
    try testing.expectEqualStrings("one", try repos.storedFile(repo, tree, "plain.txt"));
    try repos.expectRestores(repo, tree, &.{ "au.txt", "sw.txt", "plain.txt" });
    try testing.expectEqualStrings("h au.txt\nS sw.txt", try repos.gitIn("flags", &.{ "ls-files", "-v", "au.txt", "sw.txt" }));
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: sparse checkout that changes between captures takes HEAD's version off disk and the disk's on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sl");
    try repos.write("sl/in/a", "i\n");
    try repos.write("sl/out/b", "old\n");
    _ = try repos.gitIn("sl", &.{ "add", "-A" });
    try repos.commit("sl", "base");
    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "set", "--cone", "in" });
    const repo = try repos.repository("sl");
    _ = try expectComplete(try repos.captureRepo(repo, "sl"));

    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "disable" });
    try repos.write("sl/out/b", "new\n");
    try repos.commitAll("sl", "update");
    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "set", "--cone", "in" });
    try testing.expect(!try repos.exists("sl/out/b"));
    const moved = try expectComplete(try repos.captureRepo(repo, "sl"));
    try testing.expectEqualStrings(try repos.gitIn("sl", &.{ "rev-parse", "HEAD^{tree}" }), moved);
    try testing.expectEqualStrings("new", try repos.storedFile(repo, moved, "out/b"));

    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "disable" });
    try repos.write("sl/out/b", "edited\n");
    const expected = try repos.expectedTree(repo, &.{});
    const back = try expectComplete(try repos.captureRepo(repo, "sl"));
    try testing.expectEqualStrings(expected, back);
    try testing.expectEqualStrings("edited", try repos.storedFile(repo, back, "out/b"));
}

test "capture store: two worktrees of one repository each capture their own branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main = try repos.repository("wt-main");
    const side = try repos.repository("wt-side");
    const main_head_tree = try repos.gitIn("wt-main", &.{ "rev-parse", "HEAD^{tree}" });
    const side_head_tree = try repos.gitIn("wt-side", &.{ "rev-parse", "HEAD^{tree}" });
    try testing.expect(!std.mem.eql(u8, main_head_tree, side_head_tree));

    try testing.expectEqualStrings(main_head_tree, try expectComplete(try repos.captureRepo(main, "wm")));
    try testing.expectEqualStrings(side_head_tree, try expectComplete(try repos.captureRepo(side, "ws")));
    try testing.expectEqualStrings(main_head_tree, try expectComplete(try repos.captureRepo(main, "wm")));
}

test "capture store: with core.checkStat=minimal two worktrees with equal size and time capture their own file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.append("home/.gitconfig", "[core]\n\tcheckStat = minimal\n");
    try repos.initRepo("cs-main");
    try repos.write("cs-main/f", "main\n");
    _ = try repos.gitIn("cs-main", &.{ "add", "-A" });
    try repos.commit("cs-main", "base");
    _ = try repos.gitIn("cs-main", &.{ "worktree", "add", "-q", "-b", "side", try repos.path("cs-side") });
    try repos.write("cs-side/f", "side\n");
    try repos.commitAll("cs-side", "side");
    // Same size, same time, different content.
    try repos.setModified("cs-main/f", 1_577_836_800);
    try repos.setModified("cs-side/f", 1_577_836_800);
    const main = try repos.repository("cs-main");
    const side = try repos.repository("cs-side");

    const main_tree = try expectComplete(try repos.captureRepo(main, "cm"));
    const side_tree = try expectComplete(try repos.captureRepo(side, "cs"));
    try testing.expectEqualStrings("main", try repos.storedFile(main, main_tree, "f"));
    try testing.expectEqualStrings("side", try repos.storedFile(side, side_tree, "f"));
}

test "capture store: branch switch between captures is followed by the persistent capture index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("switch");
    try repos.write("switch/f", "a\n");
    try repos.write("switch/k", "keep\n");
    _ = try repos.gitIn("switch", &.{ "add", "-A" });
    try repos.commit("switch", "base");
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "-b", "other" });
    try repos.write("switch/f", "b\n");
    try repos.write("switch/g", "extra\n");
    _ = try repos.gitIn("switch", &.{ "add", "-A" });
    try repos.commit("switch", "other");
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "main" });
    try repos.append("switch/k", "dirty\n");
    const repo = try repos.repository("switch");
    const expected_first = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected_first, try expectComplete(try repos.captureRepo(repo, "bs")));

    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "--", "k" });
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "other" });
    try repos.write("switch/h.txt", "wip\n");
    const expected = try repos.expectedTree(repo, &.{});
    const second = try repos.captureRepo(repo, "bs");
    try testing.expectEqualStrings(expected, try expectComplete(second));
    try testing.expectEqual(@as(?IndexStart, .persisted), second.index);
    try testing.expectEqualStrings(try repos.gitIn("switch", &.{ "rev-parse", "HEAD" }), second.head.commit);
}

test "capture store: same-size change in the index's own second is captured because the index copy keeps its time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("racy");
    // Start right after a second boundary, so the index write and the edit
    // share one second, then capture in a later second.
    const now_ns = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const into_second: u64 = @intCast(@mod(now_ns, std.time.ns_per_s));
    io_mod.sleep(std.time.ns_per_s - into_second + 20 * std.time.ns_per_ms);
    try repos.write("racy/f", "one\n");
    _ = try repos.gitIn("racy", &.{ "add", "f" });
    try repos.commit("racy", "base");
    try repos.write("racy/f", "two\n");
    io_mod.sleep(1200 * std.time.ns_per_ms);
    const repo = try repos.repository("racy");
    // Fixture check: the user's own git sees the change without refreshing.
    try testing.expectEqualStrings(" M f", try repos.gitEnv(repo.work_tree, &.{ "status", "--porcelain" }, &.{.{ "GIT_OPTIONAL_LOCKS", "0" }}));

    const tree = try expectComplete(try repos.captureRepo(repo, "rc"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "f"));
    try repos.expectRestores(repo, tree, &.{"f"});
}

test "capture store: captures of two worktrees running at the same time each record their own worktree" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main = try repos.repository("wt-main");
    const side = try repos.repository("wt-side");
    // The store and both capture indexes exist before the race: this test is
    // about per-worktree intermediates, not store creation. The API has no
    // hook to pause a capture, so unlike run.sh's barrier the interleaving is
    // left to the scheduler over several rounds.
    _ = try expectComplete(try repos.captureRepo(main, "wm"));
    _ = try expectComplete(try repos.captureRepo(side, "ws"));

    var round: usize = 0;
    while (round < 4) : (round += 1) {
        try repos.write(try repos.arena.print("wt-main/in/main-{d}.txt", .{round}), "main\n");
        try repos.write(try repos.arena.print("wt-side/in/side-{d}.txt", .{round}), "side side\n");
        try repos.append("wt-main/in/a", "main edit\n");
        try repos.append("wt-side/in/a", "side edit\n");
        const expected_main = try repos.expectedTree(main, &.{});
        const expected_side = try repos.expectedTree(side, &.{});
        var jobs = [_]CaptureJob{
            .{ .arena_state = .init(testing.allocator), .request = repos.request(main, "wm", .{}) },
            .{ .arena_state = .init(testing.allocator), .request = repos.request(side, "ws", .{}) },
        };
        defer for (&jobs) |*job| job.arena_state.deinit();
        try captureConcurrently(&jobs);
        try testing.expectEqualStrings(expected_main, try expectComplete(jobs[0].outcome orelse return error.TestCaptureReturnedError));
        try testing.expectEqualStrings(expected_side, try expectComplete(jobs[1].outcome orelse return error.TestCaptureReturnedError));
    }
}

test "capture store: untracked limits and sensitive names make a partial capture that lists what it left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("limits");
    try repos.write("limits/tracked.txt", "tracked\n");
    try repos.write("limits/tracked-big.bin", try repos.randomBytes(8 * 1024, 4));
    _ = try repos.gitIn("limits", &.{ "add", "-A" });
    try repos.commit("limits", "base");
    try repos.write("limits/.env", "SECRET=1\n");
    try repos.write("limits/big.dat", try repos.randomBytes(4 * 1024, 5));
    try repos.write("limits/keep1.txt", "admitted\n");
    try repos.write("limits/keep2.txt", "over the count\n");
    try repos.append("limits/tracked-big.bin", "grows past the untracked limit\n");
    const repo = try repos.repository("limits");
    const expected = try repos.expectedTree(repo, &.{ ".env", "big.dat", "keep2.txt" });

    const limits: policy.Limits = .{ .untracked_file_bytes = 1024, .untracked_count = 1 };
    const outcome = try capture(repos.arena, repos.request(repo, "lim", limits));
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    const reason = outcome.reason.?;
    try testing.expect(reason == .sensitive or reason == .too_large or reason == .file_limit);
    try testing.expect(!outcome.comparable);
    try expectExcluded(outcome, ".env", .sensitive);
    try expectExcluded(outcome, "big.dat", .too_large);
    try expectExcluded(outcome, "keep2.txt", .file_limit);
    // Tracked files never get untracked limits.
    try testing.expect(exclusionReason(outcome, "tracked-big.bin") == null);
    try testing.expect(try repos.treeHas(repo, tree, "tracked-big.bin"));
    try testing.expect(try repos.treeHas(repo, tree, "keep1.txt"));
}

test "capture store: invalid session id writes nothing and is reported as an outcome" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    const before = try repos.userState(repo);
    const too_long = try repos.arena.alloc(u8, 256);
    @memset(too_long, 'a');

    for ([_][]const u8{ "", "../escape", "a/b", "a b", ".hidden", "refs/heads/main", "x\n", too_long }) |session_id| {
        const outcome = try repos.captureRepo(repo, session_id);
        try expectNotStored(outcome);
        try testing.expectEqual(Status.failed, outcome.status);
        try testing.expectEqual(policy.Reason.invalid_request, outcome.reason.?);
    }
    // Rejected before touching the profile: no store, no worktree directory.
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" })));
    try testing.expectEqualStrings("", try repos.storeRefs(repo));
    try testing.expectEqualStrings(before, try repos.userState(repo));
    // Control: the same repository with a valid id captures, and that ref is
    // the only one in the store.
    const valid = try repos.captureRepo(repo, "Valid_id-1");
    _ = try expectComplete(valid);
    try testing.expectEqualStrings(try repos.arena.print("{s} {s}", .{ try repos.sessionRef(repo, "Valid_id-1"), valid.commit.? }), try repos.storeRefs(repo));
}

test "capture store: an expired deadline reports timeout and leaves the session ref alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "d");
    _ = try expectComplete(first);
    try repos.append("repo/a.txt", "after\n");
    const before = try repos.userState(repo);

    for ([_][]const u8{ "d", "fresh" }) |session_id| {
        var expired = repos.request(repo, session_id, .{});
        expired.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
        const outcome = try capture(repos.arena, expired);
        try expectNotStored(outcome);
        try testing.expectEqual(policy.Reason.timeout, outcome.reason.?);
    }
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "d"))).?);
    try testing.expect(try repos.storeRef(repo, try repos.sessionRef(repo, "fresh")) == null);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: a worktree's first capture runs on the one-time budget" {
    const now: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    const soon = now.addDuration(.{ .raw = .fromMilliseconds(2000), .clock = .awake });
    const budget_end = now.addDuration(.{ .raw = .fromMilliseconds(first_capture_budget_ms), .clock = .awake });
    try testing.expect(setupDeadline(now, soon, true).compare(.eq, budget_end));
    try testing.expect(setupDeadline(now, soon, false).compare(.eq, soon));
    const later = now.addDuration(.{ .raw = .fromMilliseconds(first_capture_budget_ms + 1), .clock = .awake });
    try testing.expect(setupDeadline(now, later, true).compare(.eq, later));
}

test "capture store: the first capture of a medium repository finishes on a turn's deadline, and the next keeps it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    var index: usize = 0;
    while (index < 4000) : (index += 1) {
        try repos.write(try repos.arena.print("repo/d{d}/f{d}.txt", .{ index % 40, index }), try repos.arena.print("file {d}\n", .{index}));
    }
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commit("repo", "base");
    index = 0;
    while (index < 400) : (index += 1) {
        try repos.append(try repos.arena.print("repo/d{d}/f{d}.txt", .{ index % 40, index }), "changed\n");
    }
    const repo = try repos.repository("repo");
    // The deadline a turn gives every capture (`turn_capture.deadline_ms`).
    var first = repos.request(repo, "d", .{});
    first.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(2000) });
    _ = try expectComplete(try capture(repos.arena, first));
    // The store and index exist now: an expired deadline stops the next.
    var next = repos.request(repo, "d", .{});
    next.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    const outcome = try capture(repos.arena, next);
    try expectNotStored(outcome);
    try testing.expectEqual(policy.Reason.timeout, outcome.reason.?);
}

test "capture store: fx's profile folder inside the work tree is never listed and never enters a tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // A profile kept in the repository, which then holds the capture store.
    try repos.write("repo/.fx/sessions/s1/log.jsonl", "prompt\n");
    const repo = try repos.repository("repo");
    var request = repos.request(repo, "d", .{});
    request.profile_root = try std.Io.Dir.path.join(repos.arena, &.{ repo.work_tree, ".fx" });
    const store = try storeGitDir(repos.arena, try storeDir(repos.arena, request.profile_root, repo.common_dir));
    // Each capture writes objects into the store under the profile; none of
    // them, nor fx's sessions, is listed or recorded, so every capture stays
    // complete and comparable.
    for (0..2) |_| {
        const outcome = try capture(repos.arena, request);
        const tree = try expectStored(outcome);
        try testing.expectEqual(Status.complete, outcome.status);
        try testing.expect(outcome.comparable);
        try testing.expectEqual(@as(usize, 0), outcome.excluded.len);
        try testing.expectEqual(Listing.git, outcome.listing.?);
        const listed = try repos.git(repos.root, &.{ "--git-dir", store, "ls-tree", "-r", "--name-only", tree });
        try testing.expect(std.mem.find(u8, listed, ".fx/") == null);
        try testing.expect(std.mem.find(u8, listed, "a.txt") != null);
    }
    // A file the user's git tracks in the profile is left out too, and the
    // folder is recorded once, however many files it holds.
    try repos.write("repo/.fx/settings.json", "{\"secret\":true}\n");
    _ = try repos.gitIn("repo", &.{ "add", "-f", ".fx/settings.json" });
    try repos.commit("repo", "profile");
    for (0..2) |_| {
        const outcome = try capture(repos.arena, request);
        const tree = try expectStored(outcome);
        try testing.expectEqual(Status.partial, outcome.status);
        try testing.expectEqual(policy.Reason.sensitive, outcome.reason.?);
        try testing.expectEqual(@as(usize, 1), outcome.excluded.len);
        try expectExcluded(outcome, ".fx", .sensitive);
        const listed = try repos.git(repos.root, &.{ "--git-dir", store, "ls-tree", "-r", "--name-only", tree });
        try testing.expect(std.mem.find(u8, listed, ".fx/") == null);
    }
    try testing.expect((try profileWithin(repos.arena, repo.work_tree, repos.profile)) == null);
    // A work tree that is the profile folder itself is never captured.
    request.profile_root = repo.work_tree;
    const own = try capture(repos.arena, request);
    try testing.expectEqual(Status.unavailable, own.status);
    try testing.expectEqual(policy.Reason.private_root, own.reason.?);
}

test "capture store: an untracked nested repository is reported as left out, never dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.initRepo("repo/vendor/lib");
    try repos.write("repo/vendor/lib/x.txt", "x\n");
    _ = try repos.gitIn("repo/vendor/lib", &.{ "add", "-A" });
    try repos.commit("repo/vendor/lib", "lib");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "nested");
    const tree = try expectStored(outcome);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.submodule, outcome.reason.?);
    try expectExcluded(outcome, "vendor/lib", .submodule);
    try testing.expect(!try repos.treeHas(repo, tree, "vendor/lib"));
    try testing.expect(!outcome.comparable);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
}

test "capture store: a nested repository found by git's listing is left out, not a failed capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // A split index sends the untracked listing to git, which names a nested
    // repository as `vendor/lib/`.
    _ = try repos.gitIn("repo", &.{ "config", "core.splitIndex", "true" });
    _ = try repos.gitIn("repo", &.{ "update-index", "--split-index" });
    try repos.initRepo("repo/vendor/lib");
    try repos.write("repo/vendor/lib/x.txt", "x\n");
    _ = try repos.gitIn("repo/vendor/lib", &.{ "add", "-A" });
    try repos.commit("repo/vendor/lib", "lib");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "nested");
    _ = try expectStored(outcome);
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
    try expectExcluded(outcome, "vendor/lib", .submodule);
}

test "capture store: one session capturing two worktrees of a repository keeps one ref per worktree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main_repo = try repos.repository("wt-main");
    const side_repo = try repos.repository("wt-side");
    const main_outcome = try repos.captureRepo(main_repo, "same");
    const side_outcome = try repos.captureRepo(side_repo, "same");
    _ = try expectStored(main_outcome);
    _ = try expectStored(side_outcome);
    try testing.expectEqualStrings(main_outcome.commit.?, (try repos.storeRef(main_repo, try repos.sessionRef(main_repo, "same"))).?);
    try testing.expectEqualStrings(side_outcome.commit.?, (try repos.storeRef(side_repo, try repos.sessionRef(side_repo, "same"))).?);
    // Each chain starts on its own: neither capture is the other's parent.
    try testing.expectEqualStrings("1", try repos.storeGit(main_repo, &.{ "rev-list", "--count", try repos.sessionRef(main_repo, "same") }));
    try testing.expectEqualStrings("1", try repos.storeGit(side_repo, &.{ "rev-list", "--count", try repos.sessionRef(side_repo, "same") }));
}

test "capture store: a fresh capture index lock is reported, and one older than any capture is removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "l");
    _ = try expectStored(first);
    const worktree_dir = try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir);
    const stale_lock = try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "index.lock" });
    try TestRepos.writeAbsolute(stale_lock, "");
    try repos.append("repo/a.txt", "more\n");
    const second = try repos.captureRepo(repo, "l");
    try expectNotStored(second);
    try testing.expectEqual(Status.unavailable, second.status);
    try testing.expectEqual(policy.Reason.capture_locked, second.reason.?);
    try testing.expect(try TestRepos.existsAbsolute(stale_lock));
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "l"))).?);

    // The same lock, last written longer ago than any capture can run, is
    // a git that died: it is removed under the worktree lock.
    const now = std.Io.Timestamp.now(testing.io, .real);
    const old: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - (stale_lock_ms + 60_000) * std.time.ns_per_ms };
    try std.Io.Dir.cwd().setTimestamps(testing.io, stale_lock, .{ .access_timestamp = .{ .new = old }, .modify_timestamp = .{ .new = old } });
    const third = try repos.captureRepo(repo, "l");
    _ = try expectComplete(third);
    try testing.expect(!try TestRepos.existsAbsolute(stale_lock));
    try testing.expectEqualStrings("one\nmore", try repos.storedFile(repo, third.tree.?, "a.txt"));
    try testing.expectEqualStrings(third.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "l"))).?);
}

test "capture store: a fresh session ref lock is reported, and one older than any capture is removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "s");
    _ = try expectStored(first);
    // A git killed inside update-ref leaves `<ref>.lock` in the store.
    const ref = try repos.sessionRef(repo, "s");
    const ref_lock = try repos.arena.print("{s}/{s}.lock", .{ try repos.store(repo), ref });
    try TestRepos.writeAbsolute(ref_lock, "");
    try repos.append("repo/a.txt", "more\n");
    const second = try repos.captureRepo(repo, "s");
    try expectNotStored(second);
    try testing.expectEqual(Status.unavailable, second.status);
    try testing.expectEqual(policy.Reason.capture_locked, second.reason.?);
    try testing.expect(try TestRepos.existsAbsolute(ref_lock));
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, ref)).?);

    // Older than any capture can run: removed under the worktree lock, and
    // the chain goes on from the last capture.
    try makeStale(ref_lock);
    const third = try repos.captureRepo(repo, "s");
    _ = try expectComplete(third);
    try testing.expect(!try TestRepos.existsAbsolute(ref_lock));
    try testing.expectEqualStrings(third.commit.?, (try repos.storeRef(repo, ref)).?);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}^", .{third.commit.?}) }));
}

test "capture store: a worktree lock held past the deadline reports capture_locked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "h");
    _ = try expectStored(first);
    const worktree_dir = try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir);
    const held = try std.Io.Dir.createFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "lock" }), .{ .truncate = false, .read = true });
    defer held.close(testing.io);
    try testing.expect(try held.tryLock(testing.io, .exclusive));
    const lock_path = try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "lock" });
    // The wait tries the lock before it looks at the clock, so a held lock
    // is `Busy` however late the wait starts, even past its deadline.
    for ([_]i64{ -1, 0, 50 }) |ms| {
        try testing.expectError(error.Busy, acquireLock(testing.io, lock_path, .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(ms) })));
    }
    // A whole capture: the deadline leaves `resolve`'s git runs ample time
    // to reach the wait, which then lasts until the deadline. A deadline
    // that passes before the wait starts is a `timeout`, so a short one
    // would test the machine's load, not the lock.
    try repos.append("repo/a.txt", "more\n");
    const deadline_ms: i64 = 2_000;
    var request = repos.request(repo, "h", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    const second = try capture(repos.arena, request);
    const took_ms = started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds();
    try expectNotStored(second);
    try testing.expectEqual(Status.unavailable, second.status);
    try testing.expectEqual(policy.Reason.capture_locked, second.reason.?);
    try testing.expect(took_ms >= deadline_ms);
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "h"))).?);
}

test "capture store: a store missing its alternates is repaired and half-built stores are removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    // A crash during an earlier creation left a half-built store behind.
    const leftover = try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "store.git.tmp-1" });
    try TestRepos.writeAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ leftover, "HEAD" }), "ref: refs/heads/main\n");
    _ = try expectStored(try repos.captureRepo(repo, "r"));
    try testing.expect(!try TestRepos.existsAbsolute(leftover));

    // A store without alternates cannot read the user's objects; the next
    // capture restores them instead of failing forever.
    const alternates = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "info", "alternates" });
    try std.Io.Dir.deleteFileAbsolute(testing.io, alternates);
    try repos.append("repo/a.txt", "more\n");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "r")));
    try testing.expect(try TestRepos.existsAbsolute(alternates));
}

test "capture store: repository-local filters or attributes make a capture not comparable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const plain = try repos.captureRepo(repo, "c");
    _ = try expectComplete(plain);
    try testing.expect(plain.comparable);

    _ = try repos.gitIn("repo", &.{ "config", "filter.local.clean", "cat" });
    const filtered = try repos.captureRepo(repo, "c");
    _ = try expectComplete(filtered);
    try testing.expect(!filtered.comparable);
    _ = try repos.gitIn("repo", &.{ "config", "--unset", "filter.local.clean" });

    try repos.write("repo/.git/info/attributes", "*.txt -text\n");
    const attributed = try repos.captureRepo(repo, "c");
    _ = try expectComplete(attributed);
    try testing.expect(!attributed.comparable);
}

test "capture store: a folder that cannot be read fails the capture instead of dropping its files" {
    if (std.c.getuid() == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.chmod("repo/dir", 0o000);
    defer repos.chmod("repo/dir", 0o755) catch {};
    // A process that ignores permissions, root or one holding
    // CAP_DAC_READ_SEARCH as in some containers, can still read the folder.
    if (std.Io.Dir.openDirAbsolute(testing.io, try repos.path("repo/dir"), .{ .iterate = true })) |opened| {
        var readable = opened;
        readable.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}
    const outcome = try repos.captureRepo(repo, "u");
    try expectNotStored(outcome);
    try testing.expectEqual(Status.failed, outcome.status);
    try testing.expectEqual(policy.Reason.io_error, outcome.reason.?);
}

test "capture store: files under a folder replaced by a symlink are captured as git sees them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.rename("repo/dir", "repo/realdir");
    try repos.symlink("realdir", "repo/dir");
    const expected = try repos.expectedTree(repo, &.{});
    const tree = try expectComplete(try repos.captureRepo(repo, "s"));
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings("120000", (try repos.storeGit(repo, &.{ "ls-tree", tree, "dir" }))[0..6]);
}

test "capture store: a folder inside the worktree captures the whole worktree and names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    var inside = repo;
    inside.work_tree = try std.Io.Dir.path.join(repos.arena, &.{ repo.work_tree, "dir" });
    const outcome = try repos.captureRepo(inside, "p");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    const named = outcome.repository orelse return error.TestExpectedRepository;
    try testing.expectEqualStrings(try io_mod.realpathAlloc(repos.arena, repo.work_tree), named.work_tree);
    try testing.expectEqualStrings(try io_mod.realpathAlloc(repos.arena, repo.git_dir), named.git_dir);
    try testing.expectEqualStrings(try repos.sessionRef(repo, "p"), outcome.ref.?);
    try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, outcome.ref.?)).?);
}

test "capture store: a folder no repository holds is unavailable, not a failed capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    // Outside fx's own checkout, which holds the test's temporary folder.
    const plain = try repos.arena.print("/tmp/fx-capture-not-git-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(testing.io, plain);
    defer std.Io.Dir.cwd().deleteTree(testing.io, plain) catch {};
    var request = repos.request(.{ .work_tree = plain, .git_dir = plain, .common_dir = plain }, "n", .{});
    request.path = plain;
    const outcome = try capture(repos.arena, request);
    try expectNotStored(outcome);
    try testing.expectEqual(Status.unavailable, outcome.status);
    try testing.expectEqual(policy.Reason.not_git, outcome.reason.?);
    try testing.expect(outcome.repository == null and outcome.head == .unknown and outcome.object_format == null);
}

test "capture store: every session id fx accepts names its own ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const long = try repos.arena.alloc(u8, 255);
    @memset(long, 'z');
    var refs: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "session.v3", "_-UIdxIkuoLH", long }) |id| {
        const outcome = try repos.captureRepo(repo, id);
        _ = try expectComplete(outcome);
        for (refs.items) |other| try testing.expect(!std.mem.eql(u8, other, outcome.ref.?));
        try refs.append(repos.arena, outcome.ref.?);
        try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, outcome.ref.?)).?);
    }
}

test "capture store: every folder the capture creates is private" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    _ = try expectStored(try repos.captureRepo(repo, "v"));
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    const worktree_dir = try worktreeDir(repos.arena, store_dir, repo.git_dir);
    for ([_][]const u8{
        try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" }),
        store_dir,
        try repos.store(repo),
        worktree_dir,
        try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "scratch" }),
    }) |dir| {
        const stat = try std.Io.Dir.cwd().statFile(testing.io, dir, .{ .follow_symlinks = false });
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }
}

test "capture store: a case-only rename on a case-insensitive disk matches the user's git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // Only a case-insensitive disk can hold the renamed file under both names.
    if (!try repos.exists("repo/A.TXT")) return error.SkipZigTest;
    const repo = try repos.repository("repo");
    try repos.rename("repo/a.txt", "repo/A.txt");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "case")));
}

test "capture store: another spelling of the same repository reaches the same store and ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.symlink(repos.root, "alias");
    const alias = try repos.path("alias");
    const spelled: Repository = .{
        .work_tree = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo" }),
        .git_dir = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo", ".git" }),
        .common_dir = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo", ".git" }),
    };
    const first = try repos.captureRepo(repo, "a");
    _ = try expectStored(first);
    try repos.append("repo/a.txt", "more\n");
    const second = try repos.captureRepo(spelled, "a");
    _ = try expectStored(second);
    try testing.expectEqualStrings(second.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "a"))).?);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}^", .{second.commit.?}) }));
}

test "capture store: only what git treats as a nested repository is left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // An empty `.git` folder is not a repository, and a repository started
    // inside a tracked folder does not hide its tracked files.
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("repo/plain/.git"));
    try repos.write("repo/plain/file.txt", "plain\n");
    _ = try repos.gitIn("repo/dir", &.{ "init", "-q", "-b", "main" });
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    const outcome = try repos.captureRepo(repo, "g");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expect(outcome.comparable);
}

test "capture store: precomposed Unicode with a non-ASCII untracked name lists with git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    _ = try repos.gitIn("repo", &.{ "config", "core.precomposeUnicode", "true" });
    try repos.write("repo/caf\xc3\xa9.txt", "new\n");
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    const outcome = try repos.captureRepo(repo, "u");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
}

test "capture store: a store folder left without HEAD by an interrupted removal is replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try TestRepos.writeAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "leftover" }), "x");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "h")));
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "leftover" })));
}

test "capture store: the partial reason is the most telling exclusion, whatever the paths' order" {
    const Ex = policy.Exclusion;
    try testing.expectEqual(@as(?policy.Reason, .inconsistent), lossReason(&[_]Ex{
        .{ .path = "a", .reason = .submodule },
        .{ .path = "b", .reason = .sensitive },
        .{ .path = "c", .reason = .missing },
    }));
    try testing.expectEqual(@as(?policy.Reason, .file_limit), lossReason(&[_]Ex{
        .{ .path = ".env", .reason = .sensitive },
        .{ .path = "z", .reason = .file_limit },
    }));
    try testing.expectEqual(@as(?policy.Reason, .sensitive), lossReason(&[_]Ex{
        .{ .path = "a", .reason = .submodule },
        .{ .path = "b", .reason = .sensitive },
    }));
    try testing.expectEqual(@as(?policy.Reason, null), lossReason(&[_]Ex{}));
}

const record_oid = "0123456789abcdef0123456789abcdef01234567";

fn parseRecord(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(std.mem.findScalar(u8, bytes, '\n') == null);
    try testing.expect(bytes.len <= 256 * 1024);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
}

test "capture store: the record of a capture names its repository, ref, head and tree" {
    const outcome: Outcome = .{
        .status = .partial,
        .reason = .sensitive,
        .repository = .{ .work_tree = "/Users/example/repo", .git_dir = "/Users/example/repo/.git", .common_dir = "/Users/example/repo/.git" },
        .ref = "refs/fx/sessions/00/11",
        .head = .{ .commit = record_oid },
        .object_format = .sha1,
        .listing = .indexer,
        .index = .copied,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = &.{.{ .path = ".env", .reason = .sensitive }},
    };
    const bytes = try encodeRecord(testing.allocator, .end, outcome);
    defer testing.allocator.free(bytes);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), o.get("v").?.integer);
    try testing.expectEqualStrings("end", o.get("phase").?.string);
    try testing.expectEqualStrings("partial", o.get("status").?.string);
    try testing.expectEqualStrings("sensitive", o.get("reason").?.string);
    try testing.expectEqualStrings("/Users/example/repo", o.get("work_tree").?.string);
    try testing.expectEqualStrings("refs/fx/sessions/00/11", o.get("ref").?.string);
    try testing.expectEqualStrings("commit", o.get("head_state").?.string);
    try testing.expectEqualStrings(record_oid, o.get("head").?.string);
    try testing.expectEqualStrings(record_oid, o.get("tree").?.string);
    try testing.expectEqualStrings("sha1", o.get("object_format").?.string);
    try testing.expectEqualStrings("indexer", o.get("listing").?.string);
    try testing.expectEqualStrings("copied", o.get("index").?.string);
    const excluded = o.get("excluded").?.object;
    try testing.expectEqual(@as(i64, 1), excluded.get("total").?.integer);
    try testing.expectEqual(@as(i64, 1), excluded.get("by_reason").?.object.get("sensitive").?.integer);
    try testing.expectEqualStrings(".env", excluded.get("sample").?.array.items[0].object.get("path").?.string);
}

test "capture store: a record never claims what the capture did not see" {
    // A failure before git ran: no repository, head, format or listing.
    const early = try encodeRecord(testing.allocator, .start, .{ .status = .unavailable, .reason = .not_git });
    defer testing.allocator.free(early);
    const parsed = try parseRecord(early);
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("unknown", o.get("head_state").?.string);
    for ([_][]const u8{ "head", "tree", "commit", "object_format", "listing", "index", "work_tree", "ref" }) |field| {
        try testing.expectEqual(std.json.Value.null, o.get(field).?);
    }
    // A repository with no commit yet says so, apart from an unread HEAD.
    const unborn = try encodeRecord(testing.allocator, .start, .{ .status = .complete, .head = .unborn, .object_format = .sha1, .tree = record_oid, .commit = record_oid });
    defer testing.allocator.free(unborn);
    const born = try parseRecord(unborn);
    defer born.deinit();
    try testing.expectEqualStrings("unborn", born.value.object.get("head_state").?.string);
}

test "capture store: a record refuses an outcome that contradicts itself" {
    const invalid = [_]Outcome{
        .{ .status = .complete, .object_format = .sha1 },
        .{ .status = .complete, .reason = .timeout, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .unavailable, .reason = .not_git, .object_format = .sha1, .tree = record_oid },
        .{ .status = .failed },
        .{ .status = .partial, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .partial, .reason = .not_git, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .unavailable, .reason = .sensitive },
        .{ .status = .failed, .reason = .file_limit },
        .{ .status = .complete, .object_format = .sha1, .tree = "not-an-oid", .commit = record_oid },
        .{ .status = .complete, .object_format = .sha256, .tree = record_oid, .commit = record_oid },
        .{ .status = .complete, .tree = record_oid, .commit = record_oid },
        .{ .status = .failed, .reason = .io_error, .head = .{ .commit = "zz" }, .object_format = .sha1 },
        // A budget refusal and a cut-off listing write nothing.
        .{ .status = .partial, .reason = .budget, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .partial, .reason = .untracked_timeout, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
    };
    for (invalid) |outcome| try testing.expectError(error.InvalidOutcome, encodeRecord(testing.allocator, .end, outcome));
    const valid = [_]Outcome{
        .{ .status = .failed, .reason = .io_error },
        .{ .status = .failed, .reason = .invalid_request },
        .{ .status = .failed, .reason = .inconsistent },
        .{ .status = .unavailable, .reason = .budget },
        .{ .status = .unavailable, .reason = .capture_locked },
        .{ .status = .unavailable, .reason = .untracked_timeout },
    };
    for (valid) |outcome| {
        const bytes = try encodeRecord(testing.allocator, .end, outcome);
        testing.allocator.free(bytes);
    }
}

test "capture store: a record of thousands of exclusions and names that are not UTF-8 stays one small JSON line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var excluded: std.ArrayList(policy.Exclusion) = .empty;
    try excluded.append(arena, .{ .path = "caf\xe9.txt", .reason = .file_limit });
    try excluded.append(arena, .{ .path = "\xff\xfe", .reason = .sensitive });
    for (0..5000) |i| {
        const long = try arena.alloc(u8, 4000);
        @memset(long, 'p');
        try excluded.append(arena, .{ .path = try arena.print("{d}/{s}", .{ i, long }), .reason = .file_limit });
    }
    const bytes = try encodeRecord(testing.allocator, .end, .{
        .status = .partial,
        .reason = .file_limit,
        .object_format = .sha1,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = excluded.items,
    });
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len <= max_sample_bytes + 4096);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const out = parsed.value.object.get("excluded").?.object;
    try testing.expectEqual(@as(i64, 5002), out.get("total").?.integer);
    try testing.expectEqual(@as(i64, 5001), out.get("by_reason").?.object.get("file_limit").?.integer);
    try testing.expect(out.get("sample_truncated").?.bool);
    const sample = out.get("sample").?.array.items;
    try testing.expect(sample.len >= 2 and sample.len <= max_sample_paths);
    try testing.expectEqualStrings("636166e92e747874", sample[0].object.get("path_hex").?.string);
    try testing.expectEqual(std.json.Value.null, sample[0].object.get("path").?);
    try testing.expectEqualStrings("fffe", sample[1].object.get("path_hex").?.string);
}

fn encodeRecordCase(alloc: Allocator) !void {
    const bytes = try encodeRecord(alloc, .start, .{
        .status = .partial,
        .reason = .sensitive,
        .object_format = .sha1,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = &.{ .{ .path = ".env", .reason = .sensitive }, .{ .path = "\xff", .reason = .file_limit } },
    });
    alloc.free(bytes);
}

test "capture store: encoding a record releases its memory at every failure point" {
    try testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, encodeRecordCase, .{});
}

test "capture store: a capture over the untracked limit encodes into a record the session takes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    for (0..1200) |i| try repos.write(try repos.arena.print("repo/many/{d:0>4}.txt", .{i}), "x\n");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "big");
    _ = try expectStored(outcome);
    try testing.expectEqual(Status.partial, outcome.status);
    const bytes = try encodeRecord(testing.allocator, .end, outcome);
    defer testing.allocator.free(bytes);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const out = parsed.value.object.get("excluded").?.object;
    try testing.expectEqual(@as(i64, @intCast(outcome.excluded.len)), out.get("total").?.integer);
    try testing.expect(out.get("by_reason").?.object.get("file_limit").?.integer > 0);
}

test "capture store: credential files are left out whatever their case, and an ordinary config.json is kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("secrets");
    try repos.write("secrets/readme.txt", "readme\n");
    _ = try repos.gitIn("secrets", &.{ "add", "-A" });
    try repos.commit("secrets", "base");
    const sensitive = [_][]const u8{ ".ENV", "ID_RSA", "Credentials", ".docker/config.json", ".aws/credentials" };
    for (sensitive) |name| try repos.write(try repos.in("secrets", name), "SECRET=1\n");
    try repos.write("secrets/config.json", "{}\n");
    const repo = try repos.repository("secrets");
    const expected = try repos.expectedTree(repo, &sensitive);

    const outcome = try repos.captureRepo(repo, "secrets");
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.sensitive, outcome.reason.?);
    for (sensitive) |name| {
        try expectExcluded(outcome, name, .sensitive);
        try testing.expect(!try repos.treeHas(repo, tree, name));
    }
    try testing.expectEqual(sensitive.len, outcome.excluded.len);
    try testing.expectEqualStrings("{}", try repos.storedFile(repo, tree, "config.json"));
}

test "capture store: the untracked listing reports untracked_timeout at once when the deadline has passed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    const ready = switch (try safe_git.prepareWithin(repos.arena, repo.work_tree, .{})) {
        .ready => |value| value,
        .refused => return error.TestUnexpectedRefusal,
    };
    const facts = switch (try safe_git.repositoryFacts(repos.arena, ready, repo.work_tree, .{})) {
        .ok => |value| value,
        .failed => return error.TestExpectedFacts,
    };
    var tracked: std.StringHashMapUnmanaged(Staged) = .empty;
    var outcome: Outcome = .{ .status = .complete };

    // Control: with time left, the indexer lists the new file.
    const later: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) });
    const listed = try listUntracked(repos.arena, testing.allocator, ready, facts, null, .{ .deadline = later }, &tracked, &outcome);
    try testing.expect(listed == .listed);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);

    const expired: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    outcome = .{ .status = .complete };
    const stopped = try listUntracked(repos.arena, testing.allocator, ready, facts, null, .{ .deadline = expired }, &tracked, &outcome);
    const took_ms = started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds();
    try testing.expect(stopped == .stopped);
    try testing.expect(outcome.listing == null);
    try testing.expect(took_ms < 200);
    // The record of such a capture is accepted as unavailable.
    const record = try encodeRecord(testing.allocator, .start, withFailure(outcome, .unavailable, .untracked_timeout));
    testing.allocator.free(record);
}

test "capture store: a running untracked scan is ended at the deadline by its stop time" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("big");
    var folder = try std.Io.Dir.cwd().openDir(testing.io, try repos.path("big"), .{});
    defer folder.close(testing.io);
    const file_count = running_scan_files;
    var name_buf: [64]u8 = undefined;
    for (0..file_count) |i| {
        if (i % 100 == 0) try folder.createDirPath(testing.io, try std.mem.print(&name_buf, "d{d}", .{i / 100}));
        try folder.writeFile(testing.io, .{ .sub_path = try std.mem.print(&name_buf, "d{d}/f{d}", .{ i / 100, i }), .data = "" });
    }
    const repo = try repos.repository("big");
    const ready = switch (try safe_git.prepareWithin(repos.arena, repo.work_tree, .{})) {
        .ready => |value| value,
        .refused => return error.TestUnexpectedRefusal,
    };
    const facts = switch (try safe_git.repositoryFacts(repos.arena, ready, repo.work_tree, .{})) {
        .ok => |value| value,
        .failed => return error.TestExpectedFacts,
    };
    var tracked: std.StringHashMapUnmanaged(Staged) = .empty;

    // With time left the indexer lists every file; the fastest of a few
    // runs is how long an unstopped listing takes.
    var full_ms: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        var outcome: Outcome = .{ .status = .complete };
        const later: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(60_000) });
        const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
        const listed = try listUntracked(repos.arena, testing.allocator, ready, facts, null, .{ .deadline = later }, &tracked, &outcome);
        full_ms = @min(full_ms, started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds());
        try testing.expectEqual(file_count, listed.listed.files.len);
        try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
    }

    // A deadline that passes while the scan runs. Without the stop time the
    // scan would run to its end and only then see the deadline.
    const budget_ms = @max(10, @divTrunc(full_ms, 10));
    var outcome: Outcome = .{ .status = .complete };
    const deadline: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(budget_ms) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    const stopped = try listUntracked(repos.arena, testing.allocator, ready, facts, null, .{ .deadline = deadline }, &tracked, &outcome);
    const took_ms = started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds();
    if (took_ms >= @divTrunc(full_ms, 2)) std.debug.print("running scan: full_ms={d} budget_ms={d} took_ms={d}\n", .{ full_ms, budget_ms, took_ms });
    // `select` reports this as `untracked_timeout`.
    try testing.expect(stopped == .stopped);
    try testing.expect(outcome.listing == null);
    // It ran until the deadline, so the scan had started; it ended well
    // before an unstopped scan would have.
    try testing.expect(took_ms >= budget_ms);
    try testing.expect(took_ms < @divTrunc(full_ms, 2));
}

/// Enough untracked files that an unstopped scan takes far longer than the
/// deadline the running-scan test gives it.
const running_scan_files: usize = 100_000;

test "capture store: a .git that is a symlink or a gitdir file into another repository is unavailable as foreign_git_dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("other");
    const other = try repos.repository("other");
    try repos.write("linked/mine.txt", "mine\n");
    try repos.symlink(try std.Io.Dir.path.join(repos.arena, &.{ other.work_tree, ".git" }), "linked/.git");
    try repos.write("pointer/mine.txt", "mine\n");
    try repos.write("pointer/.git", try repos.arena.print("gitdir: {s}/.git\n", .{other.work_tree}));
    const before = try repos.userState(other);

    for ([_][]const u8{ "linked", "pointer" }) |name| {
        const folder = try io_mod.realpathAlloc(repos.arena, try repos.path(name));
        const outcome = try capture(repos.arena, repos.request(.{ .work_tree = folder, .git_dir = "", .common_dir = "" }, "foreign", .{}));
        try expectNotStored(outcome);
        try testing.expectEqual(Status.unavailable, outcome.status);
        try testing.expectEqual(policy.Reason.foreign_git_dir, outcome.reason.?);
        // Nothing of the other repository is claimed.
        try testing.expect(outcome.head == .unknown);
        try testing.expect(outcome.ref == null);
        try testing.expect(outcome.repository == null);
        const record = try encodeRecord(testing.allocator, .start, outcome);
        testing.allocator.free(record);
    }
    try testing.expectEqualStrings("", try repos.storeRefs(other));
    try testing.expectEqualStrings(before, try repos.userState(other));

    // A separate git directory is the folder's own and still captures.
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("separate"));
    _ = try repos.gitIn("separate", &.{ "init", "-q", "-b", "main", "--separate-git-dir", try repos.path("separate-git") });
    try repos.write("separate/a.txt", "a\n");
    const separate = try repos.repository("separate");
    _ = try expectComplete(try repos.captureRepo(separate, "own"));
}

test "capture store: a gitdir file into another checkout's separate git directory never shares that checkout's chain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("other"));
    _ = try repos.gitIn("other", &.{ "init", "-q", "-b", "main", "--separate-git-dir", try repos.path("other-git") });
    try repos.write("other/a.txt", "other\n");
    _ = try repos.gitIn("other", &.{ "add", "-A" });
    try repos.commit("other", "base");
    const other = try repos.repository("other");
    const own = try repos.captureRepo(other, "s");
    _ = try expectComplete(own);

    // `pointer` hands itself to the same git directory.
    try repos.write("pointer/mine.txt", "mine\n");
    try repos.write("pointer/.git", try repos.arena.print("gitdir: {s}\n", .{try repos.path("other-git")}));
    const folder = try io_mod.realpathAlloc(repos.arena, try repos.path("pointer"));
    const pointed = try capture(repos.arena, repos.request(.{ .work_tree = folder, .git_dir = "", .common_dir = "" }, "s", .{}));
    const pointed_tree = try expectStored(pointed);
    try testing.expectEqualStrings(folder, pointed.repository.?.work_tree);
    // Its own ref, index and chain: it neither moves `other`'s ref nor
    // builds on it.
    try testing.expect(!std.mem.eql(u8, own.ref.?, pointed.ref.?));
    try testing.expectEqualStrings(own.commit.?, (try repos.storeRef(other, own.ref.?)).?);
    try testing.expectEqualStrings("1", try repos.storeGit(other, &.{ "rev-list", "--count", pointed.commit.? }));
    const store_dir = try storeDir(repos.arena, repos.profile, other.common_dir);
    try testing.expect(!std.mem.eql(u8, try worktreeDir(repos.arena, store_dir, try worktreeIdentity(repos.arena, other)), try worktreeDir(repos.arena, store_dir, try worktreeIdentity(repos.arena, pointed.repository.?))));
    try testing.expect(try repos.treeHas(other, pointed_tree, "mine.txt"));

    // `other`'s next capture builds on its own and holds only its files.
    try repos.append("other/a.txt", "more\n");
    const next = try repos.captureRepo(other, "s");
    _ = try expectComplete(next);
    try testing.expectEqualStrings(own.commit.?, try repos.storeGit(other, &.{ "rev-parse", try repos.arena.print("{s}^", .{next.commit.?}) }));
    try testing.expect(try repos.treeHas(other, next.tree.?, "a.txt"));
    try testing.expect(!try repos.treeHas(other, next.tree.?, "mine.txt"));
}

test "capture store: a user's index that is a pipe is rebuilt from HEAD, never opened" {
    if (!builtin.link_libc) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const index = try std.Io.Dir.path.join(repos.arena, &.{ repo.git_dir, "index" });
    try replaceWithFifo(repos, index);
    const outcome, const took_ms = try captureBesideFifo(repos, repo, index);
    // The user's git blocks on the pipe until the deadline stops it; fx
    // itself never opened it.
    try testing.expect(took_ms < fifo_guard_ms);
    try testing.expectEqual(@as(?IndexStart, .rebuilt), outcome.index);
}

test "capture store: a linked worktree's gitdir record that is a pipe is never opened" {
    if (!builtin.link_libc) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    _ = try repos.gitIn("repo", &.{ "worktree", "add", "-q", "-b", "wt", try repos.path("linked") });
    const linked = try repos.repository("linked");
    const gitdir = try std.Io.Dir.path.join(repos.arena, &.{ linked.git_dir, "gitdir" });
    try replaceWithFifo(repos, gitdir);
    const outcome, const took_ms = try captureBesideFifo(repos, linked, gitdir);
    try testing.expect(took_ms < fifo_guard_ms);
    try expectNotStored(outcome);
    try testing.expectEqual(policy.Reason.foreign_git_dir, outcome.reason.?);
}

test "capture store: creating the store runs on its own budget, so a slow first setup still captures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    // Another process holds the store's `init.lock` past the capture's own
    // deadline, as a slow store creation would take that time.
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, store_dir);
    const held = try std.Io.Dir.createFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "init.lock" }), .{ .truncate = false, .read = true });
    try testing.expect(try held.tryLock(testing.io, .exclusive));
    const Release = struct {
        fn run(file: std.Io.File) void {
            io_mod.sleep(2000 * std.time.ns_per_ms);
            file.close(testing.io);
        }
    };
    const releaser = try std.Thread.spawn(.{}, Release.run, .{held});
    defer releaser.join();

    var request = repos.request(repo, "setup", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(1500) });
    const outcome = try capture(repos.arena, request);
    _ = try expectComplete(outcome);
    try testing.expectEqual(@as(?IndexStart, .copied), outcome.index);
    try testing.expect(try repos.treeHas(repo, outcome.tree.?, "new.txt"));
}
test "capture store: a store or capture index whose check fails fails the capture and keeps the store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    defer test_hooks.access_denied_suffix = null;
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "s");
    _ = try expectComplete(first);
    const ref = try repos.sessionRef(repo, "s");
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    const index = try std.Io.Dir.path.join(repos.arena, &.{ try worktreeDir(repos.arena, store_dir, try worktreeIdentity(repos.arena, repo)), worktree_index_name });
    const index_before = try TestRepos.readAbsolute(repos.arena, index);
    try repos.append("repo/a.txt", "more\n");

    // HEAD that cannot be checked, as on EACCES, EIO or a spent cancel, is
    // not a missing HEAD: the store is never set aside and deleted. An index
    // that cannot be checked is never replaced by a fresh copy.
    for ([_][]const u8{ "store.git/HEAD", index }) |suffix| {
        test_hooks.access_denied_suffix = suffix;
        const failed = try repos.captureRepo(repo, "s");
        test_hooks.access_denied_suffix = null;
        try expectNotStored(failed);
        try testing.expectEqual(Status.failed, failed.status);
        try testing.expectEqual(policy.Reason.io_error, failed.reason.?);
        try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, ref)).?);
        try testing.expectEqualStrings(index_before, try TestRepos.readAbsolute(repos.arena, index));
    }
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, store_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| try testing.expect(!std.mem.startsWith(u8, entry.name, "store.git.tmp-"));
    // Once the check answers again, the capture extends the same chain.
    const next = try repos.captureRepo(repo, "s");
    _ = try expectComplete(next);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}^", .{next.commit.?}) }));
}

test "capture store: a copy that runs out of time keeps its packs, so the next capture on the same budget finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    defer {
        test_hooks.copy_batch_objects = null;
        test_hooks.copy_packs_before_timeout = null;
        test_hooks.first_budget = null;
    }
    // 40 blobs in 4 folders: with the root, 45 objects only the user's
    // repository holds.
    try repos.initRepo("repo");
    var file: usize = 0;
    while (file < 40) : (file += 1) {
        try repos.write(try repos.arena.print("repo/d{d}/f{d}.txt", .{ file % 4, file }), try repos.arena.print("file {d}\n", .{file}));
    }
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commit("repo", "base");
    const repo = try repos.repository("repo");
    const ref = try repos.sessionRef(repo, "s");
    // Each capture's budget lets its copy write 4 packs of 4 objects.
    test_hooks.copy_batch_objects = 4;
    test_hooks.copy_packs_before_timeout = 4;

    const one = try repos.captureRepo(repo, "s");
    try expectNotStored(one);
    try testing.expectEqual(policy.Reason.timeout, one.reason.?);
    try testing.expectEqual(@as(usize, 16), test_hooks.copied_objects);
    try testing.expect((try repos.storeRef(repo, ref)) == null);
    // The store and index exist now, but no capture ref: the next capture
    // still runs on the first-capture budget, and copies only what the
    // first left.
    const two = try repos.captureRepo(repo, "s");
    try expectNotStored(two);
    try testing.expectEqual(policy.Reason.timeout, two.reason.?);
    try testing.expectEqual(@as(?bool, true), test_hooks.first_budget);
    try testing.expectEqual(@as(usize, 16), test_hooks.copied_objects);
    const three = try repos.captureRepo(repo, "s");
    const tree = try expectComplete(three);
    try testing.expectEqual(@as(?bool, true), test_hooks.first_budget);
    try testing.expectEqual(@as(usize, 13), test_hooks.copied_objects);
    try testing.expectEqualStrings(three.commit.?, (try repos.storeRef(repo, ref)).?);
    // The landed capture is readable with the alternates gone.
    try testing.expect(try repos.storeAloneHas(repo, tree));
    file = 0;
    while (file < 40) : (file += 1) {
        try testing.expect(try repos.storeAloneHas(repo, try repos.arena.print("{s}:d{d}/f{d}.txt", .{ tree, file % 4, file })));
    }
    // With a capture in the store, later ones keep the caller's deadline.
    try repos.append("repo/d0/f0.txt", "more\n");
    _ = try expectComplete(try repos.captureRepo(repo, "s"));
    try testing.expectEqual(@as(?bool, false), test_hooks.first_budget);
}

test "capture store: the temporary files of a pack a killed git left are removed once stale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    _ = try expectComplete(try repos.captureRepo(repo, "s"));
    const pack_dir = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "pack" });
    const stale = try std.Io.Dir.path.join(repos.arena, &.{ pack_dir, "tmp_pack_stale" });
    const fresh = try std.Io.Dir.path.join(repos.arena, &.{ pack_dir, "tmp_pack_fresh" });
    try TestRepos.writeAbsolute(stale, "partial pack");
    try TestRepos.writeAbsolute(fresh, "pack being written");
    const long_ago: std.Io.Timestamp = .{ .nanoseconds = @as(i96, test_unix_seconds) * std.time.ns_per_s };
    try std.Io.Dir.cwd().setTimestamps(testing.io, stale, .{ .access_timestamp = .{ .new = long_ago }, .modify_timestamp = .{ .new = long_ago } });
    try repos.write("repo/new.txt", "new\n");
    _ = try expectComplete(try repos.captureRepo(repo, "s"));
    try testing.expect(!try TestRepos.existsAbsolute(stale));
    // One another capture's git may still be writing stays.
    try testing.expect(try TestRepos.existsAbsolute(fresh));
}

test "capture store: a pack index is searched on disk and in memory alike, and a damaged one is left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    var file: usize = 0;
    while (file < 200) : (file += 1) {
        try repos.write(try repos.arena.print("repo/f{d}.txt", .{file}), try repos.arena.print("file {d}\n", .{file}));
    }
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commit("repo", "base");
    _ = try repos.gitIn("repo", &.{ "repack", "-a", "-d", "-q" });
    const pack_dir = try repos.path("repo/.git/objects/pack");
    const listed = try repos.gitIn("repo", &.{ "rev-list", "--objects", "--no-object-names", "--all" });
    var objects: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listed, '\n');
    while (lines.next()) |line| if (line.len > 0) try objects.append(repos.arena, line);
    try testing.expect(objects.items.len > PackIndex.lookups_before_read * 2);
    var packs = try OwnPacks.load(repos.arena, testing.allocator, testing.io, try repos.path("repo/.git"), .sha1);
    defer packs.deinit(testing.io);
    try testing.expectEqual(@as(usize, 1), packs.indexes.len);
    // The first lookups read the disk; the rest search the table in memory.
    for (objects.items) |oid| try testing.expect(try packs.contains(testing.io, oid));
    try testing.expect(packs.indexes[0].table != null);
    try testing.expect(!try packs.contains(testing.io, "0000000000000000000000000000000000000000"));
    try testing.expect(!try packs.contains(testing.io, "ffffffffffffffffffffffffffffffffffffffff"));

    // A truncated index, or one without its pack, is not counted.
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, pack_dir, .{ .iterate = true });
    defer dir.close(testing.io);
    var idx_name: ?[]const u8 = null;
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".idx")) {
        idx_name = try repos.arena.dupe(u8, entry.name);
    };
    const idx_path = try std.Io.Dir.path.join(repos.arena, &.{ pack_dir, idx_name.? });
    const bytes = try TestRepos.readAbsolute(repos.arena, idx_path);
    try std.Io.Dir.cwd().setFilePermissions(testing.io, idx_path, .fromMode(0o644), .{});
    try TestRepos.writeAbsolute(idx_path, bytes[0 .. bytes.len / 2]);
    var truncated = try OwnPacks.load(repos.arena, testing.allocator, testing.io, try repos.path("repo/.git"), .sha1);
    defer truncated.deinit(testing.io);
    try testing.expectEqual(@as(usize, 0), truncated.indexes.len);
    try TestRepos.writeAbsolute(idx_path, bytes);
    const pack_path = try repos.arena.print("{s}.pack", .{idx_path[0 .. idx_path.len - ".idx".len]});
    try std.Io.Dir.renameAbsolute(pack_path, try repos.path("moved.pack"), testing.io);
    var without_pack = try OwnPacks.load(repos.arena, testing.allocator, testing.io, try repos.path("repo/.git"), .sha1);
    defer without_pack.deinit(testing.io);
    try testing.expectEqual(@as(usize, 0), without_pack.indexes.len);
}

test "capture store: a capture whose cancel flag is set records cancelled and leaves the ref alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "s");
    _ = try expectComplete(first);
    try repos.append("repo/a.txt", "more\n");
    var cancel: std.atomic.Value(bool) = .init(true);
    var request = repos.request(repo, "s", .{});
    request.cancel = &cancel;
    const outcome = try capture(repos.arena, request);
    try expectNotStored(outcome);
    try testing.expectEqual(Status.unavailable, outcome.status);
    try testing.expectEqual(policy.Reason.cancelled, outcome.reason.?);
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "s"))).?);
}

test "capture selection: list_refs lines parse only when well formed, and the newest captures come first" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const other = "89abcdef0123456789abcdef0123456789abcdef";
    const key = "00112233445566778899aabbccddeeff";
    const wt = "ffeeddccbbaa99887766554433221100";
    const good = "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " 1700000000";
    const parsed = parseRefLine(good).?;
    try testing.expectEqualStrings("refs/fx/sessions/" ++ key ++ "/" ++ wt, parsed.name);
    try testing.expectEqualStrings(key, parsed.key);
    try testing.expectEqualStrings(wt, parsed.worktree);
    try testing.expectEqualStrings(oid, parsed.oid);
    try testing.expectEqual(@as(i64, 1_700_000_000), parsed.seconds);
    const bad = [_][]const u8{
        "",
        "refs/heads/main " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ " " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ "/x " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " nothex 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " soon",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " 1 extra",
        "refs/fx/sessions/ABCDEF33445566778899aabbccddeeff/" ++ wt ++ " " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/short " ++ oid ++ " 1",
    };
    for (bad) |line| try testing.expect(parseRefLine(line) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const listing = "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " 5\n" ++
        bad[6] ++ "\n" ++
        "refs/fx/sessions/" ++ wt ++ "/" ++ key ++ " " ++ other ++ " 9\n";
    const newest = try newestCaptures(arena_state.allocator(), listing, .sha1);
    try testing.expectEqual(@as(usize, 2), newest.len);
    try testing.expectEqualStrings(other, newest[0]);
    try testing.expectEqualStrings(oid, newest[1]);
    try testing.expectEqual(@as(usize, 0), (try newestCaptures(arena_state.allocator(), listing, .sha256)).len);
}

// ---- Retention (`capture_retention.zig`) against real stores ----

test "capture store: retention's gc and repack keep every copied object and take in no user history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.append("repo/a.txt", "second commit\n");
    try repos.commitAll("repo", "second");
    const repo = try repos.repository("repo");
    try repos.write("repo/staged.txt", "staged\n");
    _ = try repos.gitIn("repo", &.{ "add", "staged.txt" });
    const first = try repos.captureRepo(repo, "s");
    _ = try expectComplete(first);
    try repos.write("repo/new.txt", "new\n");
    const second = try repos.captureRepo(repo, "s");
    const tree = try expectComplete(second);

    const ready = switch (try safe_git.prepareStore(repos.arena, .{})) {
        .ready => |value| value,
        .refused => return error.SkipZigTest,
    };
    const store = try refStore(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir));
    for ([_]safe_git.StoreCommand{ .gc, .repack }) |command| {
        switch (try storeOutput(repos.arena, ready, store, command, .{})) {
            .ok => {},
            .failed => |failure| {
                std.debug.print("{s} failed: {s}\n", .{ @tagName(command), @tagName(failure) });
                return error.TestUnexpectedFailure;
            },
        }
        try repos.expectSelfSufficient(repo, tree, "staged.txt", "staged\n");
        try repos.expectSelfSufficient(repo, tree, "new.txt", "new\n");
    }
    // The pack holds the captures and their trees, never the user's commits.
    for ([_][]const u8{ "HEAD", "HEAD~1" }) |rev| {
        try testing.expect(!try repos.storeAloneHas(repo, try repos.gitIn("repo", &.{ "rev-parse", rev })));
    }
    const reachable = try repos.storeGit(repo, &.{ "rev-list", "--objects", "--all" });
    const packed_count = try repos.storeAlone(repo, &.{ "count-objects", "-v" });
    const in_pack = std.mem.find(u8, packed_count, "in-pack: ") orelse return error.TestUnexpectedResult;
    const count_text = packed_count[in_pack + "in-pack: ".len ..];
    const count = try std.fmt.parseInt(usize, count_text[0 .. std.mem.findScalar(u8, count_text, '\n') orelse count_text.len], 10);
    try testing.expectEqual(std.mem.count(u8, reachable, "\n") + 1, count);
    try testing.expectEqualStrings(second.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "s"))).?);
}

const retention = @import("capture_retention.zig");

/// The profile's sessions as maintenance sees them: every id exists and is
/// idle unless listed.
const TestSessions = struct {
    arena: Allocator,
    missing: []const []const u8 = &.{},
    busy_ids: []const []const u8 = &.{},
    /// Moved when maintenance asks whether its session is open, as a capture
    /// that starts between the inventory and the deletes would.
    moved: ?RefMove = null,

    const RefMove = struct { repos: TestRepos, repo: Repository, id: []const u8, to: []const u8 };

    fn listed(self: *TestSessions, ids: []const []const u8, key: []const u8) bool {
        for (ids) |id| if (std.mem.eql(u8, sessionKey(self.arena, id) catch return true, key)) return true;
        return false;
    }

    fn existsFn(ctx: *anyopaque, key: []const u8) bool {
        const self: *TestSessions = @ptrCast(@alignCast(ctx));
        return !self.listed(self.missing, key);
    }

    fn busyFn(ctx: *anyopaque, key: []const u8) bool {
        const self: *TestSessions = @ptrCast(@alignCast(ctx));
        if (self.moved) |move| if (self.listed(&.{move.id}, key)) {
            const ref = move.repos.sessionRef(move.repo, move.id) catch return true;
            _ = move.repos.storeGit(move.repo, &.{ "update-ref", ref, move.to }) catch return true;
        };
        return self.listed(self.busy_ids, key);
    }

    fn view(self: *TestSessions) retention.Sessions {
        return .{ .ctx = self, .exists = existsFn, .busy = busyFn };
    }
};

fn retentionConfig(repos: TestRepos, current_id: []const u8, sessions: *TestSessions, budget: u64, target: u64) !retention.Config {
    return .{
        .profile_root = repos.profile,
        .current_key = try sessionKey(repos.arena, current_id),
        .sessions = sessions.view(),
        .now_ms = io_mod.milliTimestamp(),
        .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
        .budget = budget,
        .target = target,
    };
}

/// A capture of `repo` for `session_id` dated `unix_seconds`.
fn captureAt(repos: TestRepos, repo: Repository, session_id: []const u8, unix_seconds: i64) ![]const u8 {
    var request = repos.request(repo, session_id, .{});
    request.unix_seconds = unix_seconds;
    _ = try expectStored(try capture(repos.arena, request));
    return (try repos.storeRef(repo, try repos.sessionRef(repo, session_id))).?;
}

/// Sets every loose object of `repo`'s store an hour back, as an evicted
/// session's objects are: retention's prune keeps loose objects written since
/// it took the store's locks, so one written in that same second would stay.
fn ageLooseObjects(repos: TestRepos, repo: Repository) !void {
    const objects = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects" });
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, objects, .{ .iterate = true });
    defer dir.close(testing.io);
    const past: std.Io.File.SetTimestamp = .{ .new = .{ .nanoseconds = (@as(i96, test_unix_seconds) - 3600) * std.time.ns_per_s } };
    var fanout = dir.iterate();
    while (try fanout.next(testing.io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 2) continue;
        var sub = try dir.openDir(testing.io, entry.name, .{ .iterate = true });
        defer sub.close(testing.io);
        var files = sub.iterate();
        while (try files.next(testing.io)) |file| {
            if (file.kind != .file) continue;
            try sub.setTimestamps(testing.io, file.name, .{ .access_timestamp = past, .modify_timestamp = past });
        }
    }
}

fn storeHasObject(repos: TestRepos, repo: Repository, oid: []const u8) !bool {
    const result = try repos.run(repos.root, try repos.gitArgv(&.{ "--git-dir", try repos.store(repo), "cat-file", "-e", oid }), &.{});
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn journalLines(repos: TestRepos) ![]const []const u8 {
    const text = TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "evictions.jsonl" })) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| if (line.len > 0) try lines.append(repos.arena, line);
    return lines.items;
}

fn usagePath(repos: TestRepos) ![]const u8 {
    return std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" });
}

/// The folder name a store has in `usage`.
fn storeName(repos: TestRepos, repo: Repository) ![]const u8 {
    return std.Io.Dir.path.basename(try storeDir(repos.arena, repos.profile, repo.common_dir));
}

/// Field `field` of the `usage` line that starts with `first`: `v2` for the
/// header, a store name for its line. Null when no line does.
fn usageField(repos: TestRepos, first: []const u8, field: usize) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.first(), first)) continue;
        for (1..field) |_| _ = fields.next() orelse return error.TestUnexpectedResult;
        return fields.next() orelse error.TestUnexpectedResult;
    }
    return null;
}

/// Rewrites one field of a `usage` line, as `usageField` names it.
fn setUsageField(repos: TestRepos, first: []const u8, field: usize, value: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        var index: usize = 0;
        const own = std.mem.eql(u8, fields.first(), first);
        fields.reset();
        while (fields.next()) |text| : (index += 1) {
            if (index > 0) try out.append(repos.arena, ' ');
            try out.appendSlice(repos.arena, if (own and index == field) value else text);
        }
        try out.append(repos.arena, '\n');
        found = found or own;
    }
    if (!found) return error.TestUnexpectedResult;
    try TestRepos.writeAbsolute(try usagePath(repos), out.items);
}

/// Moves every store's object folder times that are too recent to
/// fingerprint back past that window, as waiting would, so the next admit
/// can keep its measure. Older times stay, so a store settled before keeps
/// its fingerprint.
fn settle(repos: TestRepos) !void {
    const past: i96 = @intCast(io_mod.nanoTimestamp() - 3 * std.time.ns_per_s);
    const captures = try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" });
    for (try listStoreDirs(repos.arena, testing.io, captures)) |store_dir| {
        try setObjectTimes(try std.Io.Dir.path.join(repos.arena, &.{ try storeGitDir(repos.arena, store_dir), "objects" }), past, true);
    }
}

/// Sets the modification time of the `objects` folder and each folder in it
/// to `ns`; with `only_later`, only of those whose time is later.
fn setObjectTimes(objects: []const u8, ns: i96, only_later: bool) !void {
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, objects, .{ .iterate = true });
    defer dir.close(testing.io);
    const time: std.Io.File.SetTimestamp = .{ .new = .{ .nanoseconds = ns } };
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (only_later and (try dir.statFile(testing.io, entry.name, .{})).mtime.nanoseconds <= ns) continue;
        try dir.setTimestamps(testing.io, entry.name, .{ .modify_timestamp = time });
    }
    // Last: changing a folder in it leaves the folder's own time alone, but
    // only the folder's own update is certain not to move it again.
    if (only_later and (try dir.stat(testing.io)).mtime.nanoseconds <= ns) return;
    try dir.setTimestamps(testing.io, ".", .{ .modify_timestamp = time });
}

/// A folder in `store_dir` that no walk can open, so measuring the store
/// fails; null when this user opens it anyway, such as root. The caller
/// gives it back its permissions with `unblock`.
fn blockedFolder(repos: TestRepos, store_dir: []const u8) !?[]const u8 {
    const path = try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "blocked" });
    try std.Io.Dir.cwd().createDirPath(testing.io, path);
    try setFolderMode(path, 0o000);
    if (std.Io.Dir.openDirAbsolute(testing.io, path, .{ .iterate = true })) |opened| {
        var dir = opened;
        dir.close(testing.io);
        unblock(path);
        return null;
    } else |_| {}
    return path;
}

fn unblock(path: []const u8) void {
    setFolderMode(path, 0o700) catch {};
}

fn setFolderMode(path: []const u8, mode: std.posix.mode_t) !void {
    var parent = try std.Io.Dir.openDirAbsolute(testing.io, std.Io.Dir.path.dirname(path).?, .{});
    defer parent.close(testing.io);
    try parent.setFilePermissions(testing.io, std.Io.Dir.path.basename(path), .fromMode(mode), .{});
}

fn markerPath(repos: TestRepos, repo: Repository) ![]const u8 {
    return std.Io.Dir.path.join(repos.arena, &.{ try storeDir(repos.arena, repos.profile, repo.common_dir), retention.prune_marker });
}

test "capture retention: under the budget a capture is admitted and the measure kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };

    // No captures folder yet: nothing to measure.
    const empty = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, 1, 1));
    try testing.expect(empty.admit);
    try testing.expectEqual(@as(?u64, 0), empty.used);

    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "one", test_unix_seconds);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expect(admission.admit);
    try testing.expect(!admission.maintained);
    try testing.expect(admission.used.? > 0);
    const usage = try TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" }));
    try testing.expect(std.mem.startsWith(u8, usage, try repos.arena.print("v2 {d} ", .{admission.used.?})));
}

test "capture retention: a store's kept measure decides, and maintenance waits its interval over the budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "old", test_unix_seconds);
    const name = try storeName(repos, repo);
    try settle(repos);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    // Once more, with the usage file itself counted beside the store.
    const real = (try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;
    const store_bytes = try std.fmt.parseInt(u64, (try usageField(repos, name, 1)).?, 10);

    // The store did not change, so its kept bytes count, not a walk.
    try setUsageField(repos, name, 1, "100");
    const kept = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expectEqual(real - store_bytes + 100, kept.used.?);

    // Over the budget with maintenance run recently: refused, nothing evicted.
    try setUsageField(repos, "v2", 2, try repos.arena.print("{d}", .{io_mod.milliTimestamp()}));
    const over = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, 1, 1));
    try testing.expect(!over.admit);
    try testing.expect(!over.maintained);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "old"))) != null);

    // A store measured an interval ago is walked again.
    try setUsageField(repos, name, 2, try repos.arena.print("{d}", .{io_mod.milliTimestamp() - retention.measure_interval_ms - 1}));
    try testing.expectEqual(real, (try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes))).used.?);
    // So is every store when the file is not one.
    try TestRepos.writeAbsolute(try usagePath(repos), "garbage\n");
    try testing.expectEqual(real, (try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes))).used.?);
}

test "capture retention: over the budget evicts orphans, then the longest unused, never the current or an open session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    try repos.initRepo("other");
    try repos.write("other/b.txt", "b\n");
    const other = try repos.repository("other");

    // Oldest first: the open session, then "old" in two repositories, the
    // orphan last, and the current session in between.
    _ = try captureAt(repos, repo, "open", test_unix_seconds);
    _ = try captureAt(repos, repo, "old", test_unix_seconds + 10);
    _ = try captureAt(repos, other, "old", test_unix_seconds + 20);
    _ = try captureAt(repos, repo, "current", test_unix_seconds + 30);
    _ = try captureAt(repos, repo, "newer", test_unix_seconds + 40);
    _ = try captureAt(repos, repo, "gone", test_unix_seconds + 50);

    var sessions: TestSessions = .{ .arena = repos.arena, .missing = &.{"gone"}, .busy_ids = &.{"open"} };
    // A one-byte budget: everything that may go, goes.
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expect(!admission.admit);
    const expected = [_]struct { []const u8, retention.EvictionReason, usize }{
        .{ "gone", .orphan, 1 },
        .{ "old", .budget, 2 },
        .{ "newer", .budget, 1 },
    };
    try testing.expectEqual(expected.len, admission.evicted.len);
    for (expected, admission.evicted) |want, got| {
        try testing.expectEqualStrings(try sessionKey(repos.arena, want[0]), got.key);
        try testing.expectEqual(want[1], got.reason);
        try testing.expectEqual(want[2], got.refs);
    }
    for ([_][]const u8{ "gone", "old", "newer" }) |id| {
        try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, id))) == null);
    }
    try testing.expect((try repos.storeRef(other, try repos.sessionRef(other, "old"))) == null);
    for ([_][]const u8{ "current", "open" }) |id| {
        try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, id))) != null);
    }
    // Every eviction is in the journal, in order: its intent before its refs
    // went, then what the deletes did.
    const lines = try journalLines(repos);
    try testing.expectEqual(expected.len * 2, lines.len);
    for (expected, 0..) |want, i| {
        for ([_][]const u8{ "intent", "done" }, lines[i * 2 ..][0..2]) |phase, line| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, repos.arena, line, .{});
            try testing.expectEqualStrings(phase, parsed.object.get("phase").?.string);
            try testing.expectEqualStrings(try sessionKey(repos.arena, want[0]), parsed.object.get("session_key").?.string);
            try testing.expectEqualStrings(@tagName(want[1]), parsed.object.get("reason").?.string);
            try testing.expectEqual(@as(i64, @intCast(want[2])), parsed.object.get("refs").?.integer);
        }
    }
    // The capture index went with the prune; the next capture starts again
    // from the user's index and still extends the current chain.
    const parent = (try repos.storeRef(repo, try repos.sessionRef(repo, "current"))).?;
    try repos.write("repo/a.txt", "changed\n");
    var request = repos.request(repo, "current", .{});
    request.unix_seconds = test_unix_seconds + 60;
    const next = try capture(repos.arena, request);
    _ = try expectStored(next);
    try testing.expectEqual(IndexStart.copied, next.index.?);
    try testing.expectEqualStrings("changed", try repos.storedFile(repo, next.tree.?, "a.txt"));
    try testing.expectEqualStrings(parent, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}^", .{next.commit.?}) }));
}

test "capture retention: an evicted session's own objects leave the store and the space drops" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "shared\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");

    _ = try captureAt(repos, repo, "kept", test_unix_seconds);
    // Only the old session saw this file: its blob is the old session's own.
    try repos.write("repo/big.bin", try repos.randomBytes(1024 * 1024, 7));
    _ = try captureAt(repos, repo, "old", test_unix_seconds - 100);
    const blob = std.mem.trimEnd(u8, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:big.bin", .{(try repos.storeRef(repo, try repos.sessionRef(repo, "old"))).?}) }), "\n");
    try repos.remove("repo/big.bin");
    var sessions: TestSessions = .{ .arena = repos.arena };

    const before = (try retention.admit(repos.arena, try retentionConfig(repos, "kept", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;
    try testing.expect(before > 1024 * 1024);
    // Over a budget just under the space now, with the target half a MiB
    // below: one eviction is enough, and the kept session is untouched.
    std.Io.Dir.deleteFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" })) catch {};
    try ageLooseObjects(repos, repo);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "kept", &sessions, before - 1, before - 512 * 1024));
    try testing.expect(admission.maintained);
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expect(admission.admit);
    try testing.expect(admission.used.? < before - 512 * 1024);
    try testing.expect(!try storeHasObject(repos, repo, blob));
    const kept = (try repos.storeRef(repo, try repos.sessionRef(repo, "kept"))).?;
    try testing.expectEqualStrings("shared", try repos.storedFile(repo, kept, "a.txt"));
}

test "capture retention: a prune a crash stopped is finished, and a held worktree leaves its store unpruned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    try repos.write("repo/big.bin", try repos.randomBytes(256 * 1024, 9));
    const old_commit = try captureAt(repos, repo, "old", test_unix_seconds);
    const blob = std.mem.trimEnd(u8, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:big.bin", .{old_commit}) }), "\n");
    // The marker, the journal line and the ref deletion happened; the prune
    // did not.
    try TestRepos.writeAbsolute(try markerPath(repos, repo), "");
    _ = try repos.storeGit(repo, &.{ "update-ref", "-d", try repos.sessionRef(repo, "old") });
    var sessions: TestSessions = .{ .arena = repos.arena };

    // A capture holds the worktree past the deadline: the store stays.
    const worktree_lock = try std.Io.Dir.path.join(repos.arena, &.{ try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir), "lock" });
    {
        const held = try std.Io.Dir.createFileAbsolute(testing.io, worktree_lock, .{ .truncate = false, .read = true });
        defer held.close(testing.io);
        try testing.expect(try held.tryLock(testing.io, .exclusive));
        var config = try retentionConfig(repos, "current", &sessions, 1, 1);
        config.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(300) });
        const blocked = try retention.admit(repos.arena, config);
        try testing.expect(blocked.maintained);
        try testing.expect(try storeHasObject(repos, repo, blob));
    }
    // A capture between its worktree lock and its first object holds the
    // store's init lock: the store stays too.
    {
        const init_lock = try std.Io.Dir.path.join(repos.arena, &.{ try storeDir(repos.arena, repos.profile, repo.common_dir), "init.lock" });
        const held = try std.Io.Dir.createFileAbsolute(testing.io, init_lock, .{ .truncate = false, .read = true });
        defer held.close(testing.io);
        try testing.expect(try held.tryLock(testing.io, .exclusive));
        std.Io.Dir.deleteFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" })) catch {};
        var config = try retentionConfig(repos, "current", &sessions, 1, 1);
        config.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(300) });
        _ = try retention.admit(repos.arena, config);
        try testing.expect(try storeHasObject(repos, repo, blob));
    }
    // Released: the next maintenance prunes what the stopped one left.
    std.Io.Dir.deleteFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" })) catch {};
    try ageLooseObjects(repos, repo);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expectEqual(@as(usize, 0), admission.evicted.len);
    try testing.expect(!try storeHasObject(repos, repo, blob));
    try testing.expect(!try TestRepos.existsAbsolute(try markerPath(repos, repo)));
}

test "capture retention: a store that cannot be pruned stops eviction after the session whose refs left it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "oldest", test_unix_seconds - 200);
    _ = try captureAt(repos, repo, "older", test_unix_seconds - 100);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);

    // git cannot write a pack, so every prune of the store fails.
    const pack = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "pack" });
    var pack_dir = try std.Io.Dir.openDirAbsolute(testing.io, pack, .{ .iterate = true });
    defer pack_dir.close(testing.io);
    try pack_dir.setPermissions(testing.io, .fromMode(0o500));
    defer pack_dir.setPermissions(testing.io, .fromMode(0o700)) catch {};
    const probe = try std.Io.Dir.path.join(repos.arena, &.{ pack, "probe" });
    if (std.Io.Dir.createFileAbsolute(testing.io, probe, .{})) |file| {
        // A user that ignores permissions, such as root, can still write.
        file.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}

    var sessions: TestSessions = .{ .arena = repos.arena };
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expect(!admission.admit);
    // The first eviction's space never drops, so the next session stays.
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expectEqualStrings(try sessionKey(repos.arena, "oldest"), admission.evicted[0].key);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "oldest"))) == null);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "older"))) != null);
    try testing.expectEqual(@as(usize, 2), (try journalLines(repos)).len);
    try testing.expectEqual(@as(?retention.Refusal, .maintenance_failed), admission.refusal);
    // The store stays marked, so the next maintenance prunes it first.
    try testing.expect(try TestRepos.existsAbsolute(try markerPath(repos, repo)));
    // The usage kept is the last measure taken.
    const usage = try TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures", "usage" }));
    try testing.expect(std.mem.startsWith(u8, usage, try repos.arena.print("v2 {d} ", .{admission.used.?})));
}

test "capture retention: a session a capture reopens keeps its refs, and the journal and result say so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "reopened", test_unix_seconds - 200);
    try repos.write("repo/a.txt", "b\n");
    const newer = try captureAt(repos, repo, "newer", test_unix_seconds - 100);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);

    // The oldest session moves its ref after the inventory listed it.
    var sessions: TestSessions = .{ .arena = repos.arena, .moved = .{ .repos = repos, .repo = repo, .id = "reopened", .to = newer } };
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expectEqualStrings(try sessionKey(repos.arena, "newer"), admission.evicted[0].key);
    try testing.expectEqual(@as(usize, 1), admission.evicted[0].refs);
    try testing.expectEqualStrings(newer, (try repos.storeRef(repo, try repos.sessionRef(repo, "reopened"))).?);

    const expected = [_]struct { []const u8, []const u8, i64, ?i64 }{
        .{ "reopened", "intent", 1, null },
        .{ "reopened", "done", 0, 1 },
        .{ "newer", "intent", 1, null },
        .{ "newer", "done", 1, 0 },
    };
    const lines = try journalLines(repos);
    try testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| {
        const parsed = (try std.json.parseFromSliceLeaky(std.json.Value, repos.arena, line, .{})).object;
        try testing.expectEqualStrings(try sessionKey(repos.arena, want[0]), parsed.get("session_key").?.string);
        try testing.expectEqualStrings(want[1], parsed.get("phase").?.string);
        try testing.expectEqual(want[2], parsed.get("refs").?.integer);
        try testing.expectEqual(want[3], if (parsed.get("kept")) |kept| kept.integer else null);
    }
}

test "capture retention: only a store that wrote objects since its measure is walked again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    try repos.initRepo("other");
    try repos.write("other/b.txt", "b\n");
    const other = try repos.repository("other");
    _ = try captureAt(repos, repo, "one", test_unix_seconds);
    _ = try captureAt(repos, other, "one", test_unix_seconds);
    try settle(repos);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    const written = try storeName(repos, repo);
    const untouched = try storeName(repos, other);
    const written_before = try std.fmt.parseInt(u64, (try usageField(repos, written, 1)).?, 10);
    // A walk of the other store would replace this.
    try setUsageField(repos, untouched, 1, "4096");

    try repos.write("repo/big.bin", try repos.randomBytes(256 * 1024, 11));
    _ = try captureAt(repos, repo, "one", test_unix_seconds + 1);
    // Settled, so the fingerprint, not a recent folder time, sends the walk.
    try settle(repos);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expect(admission.admit);
    try testing.expectEqualStrings("4096", (try usageField(repos, untouched, 1)).?);
    const written_after = try std.fmt.parseInt(u64, (try usageField(repos, written, 1)).?, 10);
    try testing.expect(written_after >= written_before + 256 * 1024);
    try testing.expect(std.mem.startsWith(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), try repos.arena.print("v2 {d} ", .{admission.used.?})));
}

test "capture retention: a usage file in the one-line format walks every store again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "one", test_unix_seconds);
    try settle(repos);
    try TestRepos.writeAbsolute(try usagePath(repos), try repos.arena.print("100 {d}\n", .{io_mod.milliTimestamp()}));

    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expect(admission.used.? > 100);
    try testing.expect(std.mem.startsWith(u8, try TestRepos.readAbsolute(repos.arena, try usagePath(repos)), try repos.arena.print("v2 {d} ", .{admission.used.?})));
    try testing.expect((try usageField(repos, try storeName(repos, repo), 1)) != null);
}

test "capture retention: a store that is gone drops out of the space" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    try repos.initRepo("other");
    try repos.write("other/big.bin", try repos.randomBytes(256 * 1024, 13));
    const other = try repos.repository("other");
    _ = try captureAt(repos, repo, "one", test_unix_seconds);
    _ = try captureAt(repos, other, "one", test_unix_seconds);
    try settle(repos);
    const before = (try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;
    const gone = try storeName(repos, other);
    const gone_bytes = try std.fmt.parseInt(u64, (try usageField(repos, gone, 1)).?, 10);
    try testing.expect(gone_bytes > 0);

    try std.Io.Dir.cwd().deleteTree(testing.io, try storeDir(repos.arena, repos.profile, other.common_dir));
    const after = (try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;
    try testing.expect(after + gone_bytes <= before + 4096);
    try testing.expect(after < before);
    try testing.expect((try usageField(repos, gone, 1)) == null);
    try testing.expect((try usageField(repos, try storeName(repos, repo), 1)) != null);
}

test "capture retention: eviction does not wait on stores that lost no refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    try repos.write("repo/big.bin", try repos.randomBytes(256 * 1024, 17));
    const old_commit = try captureAt(repos, repo, "old", test_unix_seconds - 100);
    const blob = std.mem.trimEnd(u8, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:big.bin", .{old_commit}) }), "\n");
    try repos.remove("repo/big.bin");
    _ = try captureAt(repos, repo, "current", test_unix_seconds);

    // Stores of other repositories, each held by a capture past the
    // deadline: pruning every store first would spend it all on them.
    var held: std.ArrayList(std.Io.File) = .empty;
    defer for (held.items) |file| file.close(testing.io);
    for ([_][]const u8{ "one", "two", "three" }) |name| {
        try repos.initRepo(name);
        try repos.write(try repos.arena.print("{s}/b.txt", .{name}), "b\n");
        const other = try repos.repository(name);
        _ = try captureAt(repos, other, "current", test_unix_seconds);
        const lock = try std.Io.Dir.createFileAbsolute(testing.io, try initLockPath(repos.arena, try storeDir(repos.arena, repos.profile, other.common_dir)), .{ .truncate = false, .read = true });
        try held.append(repos.arena, lock);
        try testing.expect(try lock.tryLock(testing.io, .exclusive));
    }

    var sessions: TestSessions = .{ .arena = repos.arena };
    var config = try retentionConfig(repos, "current", &sessions, 1, 1);
    config.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) });
    try ageLooseObjects(repos, repo);
    const admission = try retention.admit(repos.arena, config);
    try testing.expect(admission.maintained);
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expectEqualStrings(try sessionKey(repos.arena, "old"), admission.evicted[0].key);
    // Only the store the refs left was pruned, and its space dropped.
    try testing.expect(!try storeHasObject(repos, repo, blob));
    try testing.expect(!try TestRepos.existsAbsolute(try markerPath(repos, repo)));
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "current"))) != null);
}

test "capture retention: a measure that fails after finishing a stopped prune evicts nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "old", test_unix_seconds - 100);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    var sessions: TestSessions = .{ .arena = repos.arena };
    // The store's measure is kept, so the admit before maintenance does not
    // walk it.
    try settle(repos);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, retention.budget_bytes, retention.target_bytes));

    // A stopped maintenance left the store marked, and the walk after its
    // prune fails.
    try TestRepos.writeAbsolute(try markerPath(repos, repo), "");
    const blocked = (try blockedFolder(repos, try storeDir(repos.arena, repos.profile, repo.common_dir))) orelse return error.SkipZigTest;
    defer unblock(blocked);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expect(!admission.admit);
    try testing.expectEqual(@as(?retention.Refusal, .measure_failed), admission.refusal);
    try testing.expectEqual(@as(usize, 0), admission.evicted.len);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "old"))) != null);
    try testing.expectEqual(@as(usize, 0), (try journalLines(repos)).len);
    // The prune itself went through.
    try testing.expect(!try TestRepos.existsAbsolute(try markerPath(repos, repo)));
}

test "capture retention: a measure that fails after an eviction stops the next one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "oldest", test_unix_seconds - 200);
    _ = try captureAt(repos, repo, "older", test_unix_seconds - 100);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    var sessions: TestSessions = .{ .arena = repos.arena };
    try settle(repos);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, retention.budget_bytes, retention.target_bytes));

    // The kept measure lets maintenance start; the walk after the first
    // eviction's prune fails.
    const blocked = (try blockedFolder(repos, try storeDir(repos.arena, repos.profile, repo.common_dir))) orelse return error.SkipZigTest;
    defer unblock(blocked);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expectEqual(@as(?retention.Refusal, .measure_failed), admission.refusal);
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expectEqualStrings(try sessionKey(repos.arena, "oldest"), admission.evicted[0].key);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "older"))) != null);
    try testing.expectEqual(@as(usize, 2), (try journalLines(repos)).len);
}

test "capture retention: a held maintenance lock refuses as busy, and a journal that cannot be written stops eviction before any ref goes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "old", test_unix_seconds - 100);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    var sessions: TestSessions = .{ .arena = repos.arena };
    const captures = try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" });

    // Another process runs maintenance.
    {
        const held = try std.Io.Dir.createFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ captures, "maintenance.lock" }), .{ .truncate = false, .read = true });
        defer held.close(testing.io);
        try testing.expect(try held.tryLock(testing.io, .exclusive));
        const busy = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
        try testing.expect(!busy.admit);
        try testing.expect(!busy.maintained);
        try testing.expectEqual(@as(?retention.Refusal, .busy), busy.refusal);
    }

    // The journal's place is taken by a folder.
    try std.Io.Dir.cwd().createDirPath(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ captures, "evictions.jsonl" }));
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expect(!admission.admit);
    try testing.expectEqual(@as(?retention.Refusal, .maintenance_failed), admission.refusal);
    try testing.expectEqual(@as(usize, 0), admission.evicted.len);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "old"))) != null);
}

test "capture retention: a write in the same tick of a coarse file clock is not missed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    var sessions: TestSessions = .{ .arena = repos.arena };
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "one", test_unix_seconds);
    const name = try storeName(repos, repo);
    const objects = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects" });

    // A 2 s file clock shows this tick's writes at the tick's start, up to
    // 2 s before now.
    const tick: i96 = @intCast(io_mod.nanoTimestamp() - std.time.ns_per_s);
    try setObjectTimes(objects, tick, false);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expectEqualStrings("0000000000000000", (try usageField(repos, name, 3)).?);
    const before = try std.fmt.parseInt(u64, (try usageField(repos, name, 1)).?, 10);

    // A pack written later in the same tick leaves every folder time as it
    // was.
    try TestRepos.writeAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ objects, "pack", "late.pack" }), try repos.randomBytes(256 * 1024, 19));
    try setObjectTimes(objects, tick, false);
    _ = try retention.admit(repos.arena, try retentionConfig(repos, "one", &sessions, retention.budget_bytes, retention.target_bytes));
    try testing.expect(try std.fmt.parseInt(u64, (try usageField(repos, name, 1)).?, 10) >= before + 256 * 1024);
}

test "capture retention: a kept ref leaves a prune a stopped maintenance owes, and the next maintenance finishes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    const current_commit = try captureAt(repos, repo, "current", test_unix_seconds);
    _ = try captureAt(repos, repo, "y", test_unix_seconds - 100);
    try repos.write("repo/big.bin", try repos.randomBytes(256 * 1024, 23));
    const old_commit = try captureAt(repos, repo, "old", test_unix_seconds);
    const blob = std.mem.trimEnd(u8, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:big.bin", .{old_commit}) }), "\n");
    // A stopped maintenance marked the store and deleted "old"'s ref, then
    // stopped before its prune.
    try TestRepos.writeAbsolute(try markerPath(repos, repo), "");
    _ = try repos.storeGit(repo, &.{ "update-ref", "-d", try repos.sessionRef(repo, "old") });

    // A capture holds the worktree past the share of the deadline finishing
    // that prune may take, so it fails again; the candidate "y" keeps its
    // only ref there because a capture moves it meanwhile.
    var sessions: TestSessions = .{ .arena = repos.arena, .moved = .{ .repos = repos, .repo = repo, .id = "y", .to = current_commit } };
    const worktree_lock = try std.Io.Dir.path.join(repos.arena, &.{ try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir), "lock" });
    {
        const held = try std.Io.Dir.createFileAbsolute(testing.io, worktree_lock, .{ .truncate = false, .read = true });
        defer held.close(testing.io);
        try testing.expect(try held.tryLock(testing.io, .exclusive));
        var config = try retentionConfig(repos, "current", &sessions, 1, 1);
        config.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(2000) });
        const blocked = try retention.admit(repos.arena, config);
        try testing.expect(blocked.maintained);
        try testing.expectEqual(@as(usize, 0), blocked.evicted.len);
        try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "y"))) != null);
    }
    // The store still owes "old"'s prune, so it stays marked.
    try testing.expect(try storeHasObject(repos, repo, blob));
    try testing.expect(try TestRepos.existsAbsolute(try markerPath(repos, repo)));

    // Released: the next maintenance prunes what the stopped one left.
    sessions.moved = null;
    std.Io.Dir.deleteFileAbsolute(testing.io, try usagePath(repos)) catch {};
    try ageLooseObjects(repos, repo);
    const admission = try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, 1, 1));
    try testing.expect(admission.maintained);
    try testing.expect(!try storeHasObject(repos, repo, blob));
    try testing.expect(!try TestRepos.existsAbsolute(try markerPath(repos, repo)));
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "current"))) != null);
}

/// `count` captures of `repo` for `session_id`, one second apart from
/// `first_seconds`, each a small edit of one 64 KiB file of random bytes:
/// loose, each version takes the whole file; packed, a version is a delta.
fn editingCaptures(repos: TestRepos, repo: Repository, session_id: []const u8, count: usize, first_seconds: i64, seed: u64) ![]const u8 {
    const path = try repos.arena.print("{s}/edited.bin", .{std.Io.Dir.path.basename(repo.work_tree)});
    const bytes = try repos.arena.dupe(u8, try repos.randomBytes(64 * 1024, seed));
    var last: []const u8 = "";
    for (0..count) |i| {
        bytes[(i * 4099) % bytes.len] +%= 1;
        try repos.write(path, bytes);
        last = try captureAt(repos, repo, session_id, first_seconds + @as(i64, @intCast(i)));
    }
    return last;
}

/// Whether the store still holds loose objects. A capture packs only the
/// objects it copies from the user's repository; those it writes stay loose.
fn storeUnpacked(repos: TestRepos, repo: Repository) !bool {
    return !std.mem.startsWith(u8, try repos.storeGit(repo, &.{ "count-objects", "-v" }), "count: 0\n");
}

test "capture retention: a store of loose objects is packed before eviction, and nothing is evicted when the pack is enough" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    const old_last = try editingCaptures(repos, repo, "old", 24, test_unix_seconds - 100, 29);
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    try testing.expect(try storeUnpacked(repos, repo));
    var sessions: TestSessions = .{ .arena = repos.arena };
    const before = (try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;
    try testing.expect(before > 24 * 64 * 1024);

    // Over the budget with the target at half the space: evicting "old"
    // would get there, but packing its loose versions does too.
    std.Io.Dir.deleteFileAbsolute(testing.io, try usagePath(repos)) catch {};
    var config = try retentionConfig(repos, "current", &sessions, before - 1, before / 2);
    config.repack_loose = 16;
    const admission = try retention.admit(repos.arena, config);
    try testing.expect(admission.maintained);
    try testing.expect(admission.admit);
    try testing.expectEqual(@as(usize, 0), admission.evicted.len);
    try testing.expect(admission.used.? < before / 2);
    try testing.expectEqual(@as(usize, 0), (try journalLines(repos)).len);
    try testing.expect(!try storeUnpacked(repos, repo));
    // Every capture of "old" is still there, the first version included.
    try testing.expectEqualStrings(old_last, (try repos.storeRef(repo, try repos.sessionRef(repo, "old"))).?);
    _ = try repos.storeGit(repo, &.{ "cat-file", "-e", try repos.arena.print("{s}~23:edited.bin", .{old_last}) });
    try testing.expect(!try TestRepos.existsAbsolute(try markerPath(repos, repo)));
}

test "capture retention: a loose store that cannot be packed evicts only what the measured space needs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    // A store of loose objects that only the current session has captured.
    try repos.initRepo("loose");
    try repos.write("loose/a.txt", "a\n");
    const loose = try repos.repository("loose");
    _ = try editingCaptures(repos, loose, "current", 12, test_unix_seconds, 31);
    // A store with two old sessions, each with half a MiB of its own.
    try repos.initRepo("repo");
    try repos.write("repo/a.txt", "a\n");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commitAll("repo", "first");
    const repo = try repos.repository("repo");
    _ = try captureAt(repos, repo, "current", test_unix_seconds);
    try repos.write("repo/older.bin", try repos.randomBytes(512 * 1024, 37));
    _ = try captureAt(repos, repo, "older", test_unix_seconds - 200);
    try repos.remove("repo/older.bin");
    try repos.write("repo/old.bin", try repos.randomBytes(512 * 1024, 41));
    _ = try captureAt(repos, repo, "old", test_unix_seconds - 100);
    try repos.remove("repo/old.bin");
    var sessions: TestSessions = .{ .arena = repos.arena };
    const before = (try retention.admit(repos.arena, try retentionConfig(repos, "current", &sessions, retention.budget_bytes, retention.target_bytes))).used.?;

    // A capture holds the loose store past the share of the deadline
    // packing may take; one eviction gets under the target.
    const held = try std.Io.Dir.createFileAbsolute(testing.io, try initLockPath(repos.arena, try storeDir(repos.arena, repos.profile, loose.common_dir)), .{ .truncate = false, .read = true });
    defer held.close(testing.io);
    try testing.expect(try held.tryLock(testing.io, .exclusive));
    std.Io.Dir.deleteFileAbsolute(testing.io, try usagePath(repos)) catch {};
    var config = try retentionConfig(repos, "current", &sessions, before - 1, before - 300 * 1024);
    config.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) });
    config.repack_loose = 16;
    const admission = try retention.admit(repos.arena, config);
    try testing.expect(admission.maintained);
    try testing.expect(admission.admit);
    try testing.expectEqual(@as(usize, 1), admission.evicted.len);
    try testing.expectEqualStrings(try sessionKey(repos.arena, "older"), admission.evicted[0].key);
    try testing.expect((try repos.storeRef(repo, try repos.sessionRef(repo, "old"))) != null);
    try testing.expect(try storeUnpacked(repos, loose));
    try testing.expect((try repos.storeRef(loose, try repos.sessionRef(loose, "current"))) != null);
}
