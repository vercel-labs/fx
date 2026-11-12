//! A turn's workspace captures, while `experimental.workspace_capture` is
//! on: the repository holding the session's folder, at the turn's start and
//! end, and each other repository a tool acts in, saved as the session's
//! `workspace_capture` items (D98).
//!
//! A host keeps one `TurnCapture` per session. `begin` runs where the turn
//! starts, beside the prompt's images, then the host saves the user's
//! prompt, then `start` takes the start capture, all before the first
//! request. `end` runs on the turn's thread before the turn's commit and
//! returns the token that commit uses; a host that commits on that thread
//! may ask `token` instead. A failed commit keeps both the token and the end capture,
//! so a retry of the same turn writes each once; `committed` ends the turn
//! once a commit lands. A capture that fails, times out, or finds no
//! repository still records what happened, and nothing here ever fails the
//! turn.
//!
//! A repository whose worktree root is `/`, the home folder, or an
//! ancestor of it is never captured, so a home folder kept as a dotfiles
//! repository never enters fx's store: a tool that reaches one captures
//! nothing, and a session whose folder lies in one records its start and end
//! as unavailable with reason `private_root`. The trace records each skip
//! (`isPrivateRoot`).
//!
//! In the app, a prompt sent while the previous answer is still drawn
//! arrives after that turn's end capture and before the UI commits it, as a
//! steering message or as an ordinary prompt: either begins a new capture
//! turn, and the session keeps the ended turn's captures for its late
//! commit (`Session.beginCaptureTurnKeeping`). The worker hands
//! each ended turn's token to the UI with its finished prompt
//! (`types.FinishedPrompt.capture_turn`), so every commit uses its own
//! turn's token. The session holds at most one ended turn: when another
//! ends first, the older one's captures are dropped, and its commit, still
//! with its own token, writes none rather than another turn's.
//!
//! A capture waits for no maintenance. Retention's `check` decides whether
//! the profile's captures leave room, within the capture's own deadline;
//! when maintenance is due it starts in the background, one per process
//! (`Maintenance`), and the capture is refused as `budget` at once. Captures
//! stay refused while it runs, and are admitted again once it brings the
//! space under the target. Hosts call `finishMaintenance` as the process
//! ends, which gives it `exit_grace_ms` to finish and then cancels it.
//!
//! The host's cancel flag (`Context.cancel`) ends a capture early, recorded
//! as unavailable with reason `cancelled`. It is set only by a cancel that
//! stops the turn, such as Ctrl+C, an ACP cancel, an `fx ask` interrupt, or
//! a subagent run's cancel, never by a steer or a subagent's report that
//! interrupts the model, so a follow-up sent during a capture leaves it
//! running. Each capture runs as a `std.Io` task that the turn's thread
//! watches; on cancel the task is cancelled, which stops the git run in
//! flight (safe_git ends its process group and passes the cancel on), so the
//! capture ends within a git spawn rather than at its deadline. A capture
//! begun after the cancel is recorded as cancelled without running, so a
//! cancelled turn's end capture is too.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const capture_store = @import("capture_store.zig");
const capture_retention = @import("capture_retention.zig");
const capture_policy = @import("workspace_capture.zig");
const session_adapter = @import("../session/session_adapter.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const repo_root = @import("repo_root.zig");

const Allocator = std.mem.Allocator;
const Session = session_adapter.Session;

/// Whether this build can capture: it needs processes for git and threads
/// for the indexer, which the libfx WebAssembly builds do not have. Hosts
/// leave the start hook unset and skip the end capture when it is false.
pub const supported = !builtin.single_threaded and switch (builtin.target.os.tag) {
    .wasi, .freestanding => false,
    else => true,
};

/// One budget for a whole capture, every git run included, so a slow
/// repository delays the turn by at most this much. A worktree's first
/// capture, which creates its store or capture index, runs on the store's
/// longer one-time budget instead (`capture_store.zig`).
pub const deadline_ms: i64 = 2000;

/// Bounds background maintenance, measuring included. It runs at most every
/// `capture_retention.measure_interval_ms`, and no turn waits for it.
pub const maintenance_deadline_ms: i64 = 30_000;

/// How long `finishMaintenance` lets a maintenance running at process end
/// finish before it cancels it.
pub const exit_grace_ms: i64 = 3000;

/// How often a turn waiting for its capture looks at the cancel flag.
const cancel_poll_ms: i64 = 10;

pub const Context = struct {
    session: *Session,
    /// The home the session store uses; captures go under fx's folder in it,
    /// `~/.fx` or `$FX_HOME` (`profile_paths.rootDir`).
    home: []const u8,
    /// The folder the session works in; its repository is captured.
    path: []const u8,
    /// Thread-safe, for the indexer's folder threads; nothing allocated
    /// with it outlives the call.
    alloc: Allocator,
    /// The host's flag for a cancel that stops the turn; once set, a capture
    /// in flight ends and later ones record `cancelled` without running.
    /// Never a flag a steer sets to interrupt the model, such as
    /// `WorkerRuntime.worker_cancel_requested`. Null for a host with none.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Where a host's captures go: the session store's home and the folder whose
/// repository is captured. A subagent run borrows its parent's.
pub const Target = struct {
    home: []const u8,
    path: []const u8,

    pub fn context(target: Target, session: *Session, cancel: ?*const std.atomic.Value(bool)) Context {
        return .{ .session = session, .home = target.home, .path = target.path, .alloc = std.heap.c_allocator, .cancel = cancel };
    }
};

/// Repositories beyond the session's own that one turn captures, so a turn
/// that wanders through many repositories delays its tools a bounded time.
pub const max_reached = 8;

/// Takes, encodes and saves one capture; `record` outside tests. A `skip`
/// reason saves the capture as unavailable for that reason without taking it.
const Recorder = fn (context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?capture_policy.Reason) void;

/// A repository a tool reached, by worktree root. Owned,
/// `std.heap.c_allocator`.
const Reached = struct {
    root: []u8,
    /// Its start capture is running; a parallel call that reaches the same
    /// repository waits on `settled` until it is saved.
    saving: bool,
};

/// One session's turn captures. Hosts call `begin` and `start` on the turn's
/// thread, `reach` from any tool call, possibly in parallel, `end` on the
/// turn's thread, and `token` and `committed` from the thread that commits,
/// which in the app is the UI thread for `committed` only. Every field is read and
/// written under `mutex`, and no capture runs while it is held.
pub const TurnCapture = struct {
    mutex: std.Io.Mutex = .init,
    /// Broadcast whenever a reached repository's start capture is saved.
    settled: std.Io.Condition = .init,
    current: ?Session.CaptureTurn = null,
    /// `begin` ran and the turn's own start capture has not.
    start_pending: bool = false,
    /// Whether this turn's end capture is taken, so a retried commit does
    /// not take a second one.
    ended: bool = false,
    /// The worktree root holding the session's folder, found as the turn
    /// began; null outside a repository. Owned, `std.heap.c_allocator`.
    main_root: ?[]u8 = null,
    /// `main_root` is private (`isPrivateRoot`): the turn's own start and
    /// end are recorded as unavailable without a capture.
    main_private: bool = false,
    /// Other worktree roots the turn's tools reached, each with a start
    /// capture taken before the first action that reached it (D98).
    reached: std.ArrayList(Reached) = .empty,
    /// Bumped whenever the turn's repositories are forgotten, so a reach
    /// that finishes after its turn ended never marks a later turn's entry.
    generation: u64 = 0,
    /// The capture seam for tests; null takes real captures. A default of
    /// `&record` would compile captures into builds that cannot take them.
    recorder: ?*const Recorder = null,

    /// Begins the turn's captures: takes the session's capture token. A
    /// steering message inside a turn still running (`fresh` false) adds
    /// nothing. A prompt that arrives once the current turn's end capture
    /// is taken, but before its commit, begins a new turn whether it is
    /// steering or fresh, as the app delivers a prompt sent while the answer
    /// is still drawn: the session keeps the ended turn's captures for its
    /// commit, which carries its own token from `end`, and drops an ended
    /// turn it kept before (`Session.beginCaptureTurnKeeping`). A fresh
    /// prompt after a turn that never took its end capture, one abandoned,
    /// drops that turn's captures. `token` never lends an ended turn's
    /// token to the next turn. The host saves the user's prompt after this
    /// and before `start`, so a kill during the start capture keeps the
    /// prompt.
    pub fn begin(self: *TurnCapture, context: Context, fresh: bool) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!fresh and self.current != null and !self.ended) return;
        const ended_turn = if (self.ended) self.current else null;
        self.forgetLocked();
        // The session keeps the ended turn's captures for its commit.
        self.current = context.session.beginCaptureTurnKeeping(ended_turn);
        self.ended = false;
        self.start_pending = true;
    }

    /// Saves the start capture of the turn `begin` began, once.
    pub fn start(self: *TurnCapture, context: Context, lock: *std.Io.Mutex) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const turn = self.current orelse {
            self.mutex.unlock(io);
            return;
        };
        const pending = self.start_pending;
        self.start_pending = false;
        self.mutex.unlock(io);
        if (!pending) return;
        const root = worktreeRoot(context.path);
        const private = if (root) |value| isPrivateRoot(value, &.{ io_mod.getenv("HOME"), context.home }) else false;
        self.mutex.lockUncancelable(io);
        if (self.current == turn and self.main_root == null) {
            self.main_root = root;
            self.main_private = private;
        } else if (root) |value| std.heap.c_allocator.free(value);
        self.mutex.unlock(io);
        if (private) debug_trace.logf("workspace", "event=workspace_capture_private session={s} reason=private_root", .{context.session.id()});
        self.capture(context, turn, .start, lock, null, if (private) .private_root else null);
    }

    /// A tool is about to act in `dir`: the first action of the turn in a
    /// repository other than the session's takes that repository's start
    /// capture first. `dir` is a command's working folder or the folder of
    /// a file a mutation writes; it may not exist yet. A parallel call that
    /// reaches the same repository waits until that capture is saved; calls
    /// that reach different repositories capture at once. A repository at
    /// the filesystem root, at the home folder, or above it is never
    /// captured (`isPrivateRoot`). The trace names every skip but the
    /// session's own repository and one already captured.
    pub fn reach(self: *TurnCapture, context: Context, dir: []const u8, tool: []const u8, lock: *std.Io.Mutex) void {
        const io = io_mod.getIo();
        const root = worktreeRoot(dir) orelse {
            traceReachSkipped(context, tool, "no_repository");
            return;
        };
        defer std.heap.c_allocator.free(root);
        const private = isPrivateRoot(root, &.{ io_mod.getenv("HOME"), context.home });
        self.mutex.lockUncancelable(io);
        const Claim = struct { turn: Session.CaptureTurn, generation: u64 };
        var skipped: ?[]const u8 = null;
        const claim: ?Claim = while (true) {
            const turn = self.current orelse {
                skipped = "no_turn";
                break null;
            };
            if (self.ended) {
                skipped = "turn_ended";
                break null;
            }
            if (self.main_root) |main| if (std.mem.eql(u8, main, root)) break null;
            if (self.findLocked(root)) |known| {
                if (!known.saving) break null;
                self.settled.waitUncancelable(io, &self.mutex);
                continue;
            }
            if (private) {
                skipped = "private_root";
                break null;
            }
            if (self.reached.items.len >= max_reached) {
                skipped = "limit";
                break null;
            }
            const owned = std.heap.c_allocator.dupe(u8, root) catch break null;
            self.reached.append(std.heap.c_allocator, .{ .root = owned, .saving = true }) catch {
                std.heap.c_allocator.free(owned);
                break null;
            };
            break .{ .turn = turn, .generation = self.generation };
        };
        self.mutex.unlock(io);
        if (skipped) |reason| traceReachSkipped(context, tool, reason);
        const claimed = claim orelse return;
        var reached_context = context;
        reached_context.path = root;
        self.capture(reached_context, claimed.turn, .start, lock, tool, null);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.generation == claimed.generation) {
            if (self.findLocked(root)) |known| known.saving = false;
        }
        self.settled.broadcast(io);
    }

    /// Saves the end capture once per turn, held for the commit that uses
    /// the token, and returns that token: null when no turn began. Runs on
    /// the turn's thread: in the app, as the turn finishes and before its
    /// finished prompt reaches the UI, which carries the token so the UI's
    /// commit writes only this turn's captures. A retried commit's second
    /// call returns the same token without a second capture.
    pub fn end(self: *TurnCapture, context: Context, lock: *std.Io.Mutex) ?Session.CaptureTurn {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const turn = self.current orelse {
            self.mutex.unlock(io);
            return null;
        };
        if (self.ended) {
            self.mutex.unlock(io);
            return turn;
        }
        // A reached repository's start capture comes before its end.
        while (self.anySavingLocked()) self.settled.waitUncancelable(io, &self.mutex);
        self.ended = true;
        const private = self.main_private;
        var roots: std.ArrayList([]u8) = .empty;
        defer {
            for (roots.items) |root| std.heap.c_allocator.free(root);
            roots.deinit(std.heap.c_allocator);
        }
        for (self.reached.items) |known| {
            const copy = std.heap.c_allocator.dupe(u8, known.root) catch continue;
            roots.append(std.heap.c_allocator, copy) catch std.heap.c_allocator.free(copy);
        }
        self.mutex.unlock(io);
        debug_trace.logf("workspace", "event=workspace_capture_end session={s} reached={d} thread={d}", .{ context.session.id(), roots.items.len, std.Thread.getCurrentId() });
        // The end follows the start: a private repository stays uncaptured.
        self.capture(context, turn, .end, lock, null, if (private) .private_root else null);
        for (roots.items) |root| {
            var reached_context = context;
            reached_context.path = root;
            self.capture(reached_context, turn, .end, lock, null, null);
        }
        return turn;
    }

    /// The token of the current turn once its end capture is taken, for a
    /// host that commits on the turn's own thread right after `end`. Null
    /// when no turn began or it has not ended. The app's UI never asks: a
    /// turn there may commit after the next has begun, so it uses the token
    /// `end` returned, which rides on its finished prompt (D98).
    pub fn token(self: *TurnCapture) ?Session.CaptureTurn {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.ended) self.current else null;
    }

    /// The commit that used `used` landed: its captures are written. A
    /// commit that used no token, or the token of a turn no longer
    /// current, such as an ended turn a steering message replaced, changes
    /// nothing here.
    pub fn committed(self: *TurnCapture, used: ?Session.CaptureTurn) void {
        const turn = used orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.current != turn) return;
        self.current = null;
        self.ended = false;
        self.start_pending = false;
        self.forgetLocked();
    }

    /// Frees what the turn's repositories hold. The owner calls it once no
    /// thread uses the captures.
    pub fn deinit(self: *TurnCapture) void {
        self.forgetLocked();
        self.reached.deinit(std.heap.c_allocator);
        self.* = .{};
    }

    fn capture(self: *const TurnCapture, context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?capture_policy.Reason) void {
        (self.recorder orelse &record)(context, turn, phase, lock, trigger_tool, skip);
    }

    fn findLocked(self: *TurnCapture, root: []const u8) ?*Reached {
        for (self.reached.items) |*known| if (std.mem.eql(u8, known.root, root)) return known;
        return null;
    }

    fn anySavingLocked(self: *const TurnCapture) bool {
        for (self.reached.items) |known| if (known.saving) return true;
        return false;
    }

    fn forgetLocked(self: *TurnCapture) void {
        if (self.main_root) |root| std.heap.c_allocator.free(root);
        self.main_root = null;
        self.main_private = false;
        for (self.reached.items) |known| std.heap.c_allocator.free(known.root);
        self.reached.clearRetainingCapacity();
        self.generation +%= 1;
        // A reach waiting on a forgotten repository looks again and finds
        // its turn over.
        self.settled.broadcast(io_mod.getIo());
    }
};

fn traceReachSkipped(context: Context, tool: []const u8, reason: []const u8) void {
    debug_trace.logf("workspace", "event=workspace_capture_reach_skipped session={s} tool={s} reason={s}", .{ context.session.id(), tool, reason });
}

/// Whether a repository at `root` is never captured, the session's own or
/// one a tool reaches: the filesystem root, or a root that is one of `homes` or an ancestor of
/// one, such as a home folder kept as a dotfiles repository. Each home is
/// compared by its real path; an unset or unresolvable one is skipped.
fn isPrivateRoot(root: []const u8, homes: []const ?[]const u8) bool {
    if (std.mem.eql(u8, std.mem.trimEnd(u8, root, "/"), "")) return true;
    for (homes) |maybe| {
        const home = maybe orelse continue;
        if (home.len == 0) continue;
        const real = io_mod.realpathAlloc(std.heap.c_allocator, home) catch |err| {
            keepCancel(err);
            continue;
        };
        defer std.heap.c_allocator.free(real);
        if (capture_store.isWithin(root, real)) return true;
    }
    return false;
}

/// The session ids whose captures one fork copies, source first.
const ForkPair = struct { from: []const u8, to: []const u8 };

const ForkPlan = struct { profile_root: []const u8, pairs: []const ForkPair };

/// Which captures a fork copies, read from the fork's state on the caller's
/// thread, owned by `arena`; null, traced, when it cannot be read.
fn forkPlan(arena: Allocator, home: []const u8, source_id: []const u8, fork: *Session, copies: []const Session.ChildCopy) ?ForkPlan {
    const built = buildForkPlan(arena, home, source_id, fork, copies) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ source_id, fork.id(), @errorName(err) });
        return null;
    };
    return built;
}

fn buildForkPlan(arena: Allocator, home: []const u8, source_id: []const u8, fork: *Session, copies: []const Session.ChildCopy) !ForkPlan {
    const profile_root = try profile_paths.rootDir(arena, home);
    var pairs: std.ArrayList(ForkPair) = .empty;
    try pairs.append(arena, .{ .from = try arena.dupe(u8, source_id), .to = try arena.dupe(u8, fork.id()) });
    if (copies.len > 0) {
        const forked = try fork.children(arena);
        for (copies) |copy| {
            for (forked) |child| if (std.mem.eql(u8, child.work_id, copy.work_id)) {
                try pairs.append(arena, .{ .from = try arena.dupe(u8, copy.id), .to = child.id });
                break;
            };
        }
    }
    return .{ .profile_root = profile_root, .pairs = pairs.items };
}

/// Gives a fork the source's workspace captures, so retention keeps them
/// while the fork's log refers to them (D98): the source session's under the
/// fork's id, and each copied subagent's under its copy's id. A failure is
/// traced and the fork stands without those captures. Runs as a `std.Io`
/// task, so a fork never waits on git or on a store lock another fx holds: each copy
/// may take up to `deadline_ms`. The owner keeps it until `done`, or until
/// its own teardown, then calls `finish`, which skips the copies not begun
/// and waits for the one running. Only the plan is read on the caller's
/// thread; the task touches no session.
pub const ForkCopy = struct {
    arena: std.heap.ArenaAllocator,
    plan: ForkPlan,
    cancel: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(void) = undefined,

    /// Starts the copy for a fork just made; null, traced, when it cannot
    /// start. Owned by the caller until `finish`.
    pub fn start(home: []const u8, source_id: []const u8, fork: *Session, copies: []const Session.ChildCopy) ?*ForkCopy {
        const task = std.heap.c_allocator.create(ForkCopy) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ source_id, fork.id(), @errorName(err) });
            return null;
        };
        task.* = .{ .arena = .init(std.heap.c_allocator), .plan = undefined };
        task.plan = forkPlan(task.arena.allocator(), home, source_id, fork, copies) orelse {
            task.arena.deinit();
            std.heap.c_allocator.destroy(task);
            return null;
        };
        task.future = io_mod.getIo().concurrent(run, .{task}) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ source_id, fork.id(), @errorName(err) });
            task.arena.deinit();
            std.heap.c_allocator.destroy(task);
            return null;
        };
        return task;
    }

    fn run(self: *ForkCopy) void {
        defer self.finished.store(true, .release);
        for (self.plan.pairs) |pair| {
            if (self.cancel.load(.acquire)) {
                debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err=Canceled", .{ pair.from, pair.to });
                continue;
            }
            var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer scratch.deinit();
            copyRefs(scratch.allocator(), self.plan.profile_root, pair.from, pair.to);
        }
    }

    /// Whether every copy has run, so `finish` returns at once.
    pub fn done(self: *const ForkCopy) bool {
        return self.finished.load(.acquire);
    }

    /// Skips the copies not begun, waits for the one running, and frees
    /// the task.
    pub fn finish(self: *ForkCopy) void {
        self.cancel.store(true, .release);
        self.future.await(io_mod.getIo());
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

fn copyRefs(arena: Allocator, profile_root: []const u8, from: []const u8, to: []const u8) void {
    const copied = capture_store.copySessionRefs(arena, .{
        .profile_root = profile_root,
        .from_session_id = from,
        .to_session_id = to,
        .deadline = .fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
    }) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ from, to, @errorName(err) });
        return;
    };
    debug_trace.logf("workspace", "event=workspace_capture_fork_refs from={s} to={s} copied={d} existing={d} conflicting={d} failed_refs={d} failed_stores={d}", .{ from, to, copied.copied, copied.existing, copied.conflicting, copied.failed_refs, copied.failed_stores });
}

/// Captures, encodes and saves one phase. The capture runs without `lock`,
/// the host's session write lock, which only the save takes. One deadline
/// bounds the space check and the capture.
fn record(context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?capture_policy.Reason) void {
    const io = io_mod.getIo();
    var arena_state = std.heap.ArenaAllocator.init(context.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = context.session.id();
    const profile_root = profile_paths.rootDir(arena, context.home) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_skipped session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) });
    // A skipped capture, a cancelled one, or one over the space budget
    // records why and writes nothing.
    const refused: ?capture_policy.Reason = skip orelse if (cancelRequested(context.cancel)) .cancelled else admitCapture(arena, &process_maintenance, .{
        .home = context.home,
        .profile_root = profile_root,
        .session_id = id,
        .deadline = deadline,
    });
    const outcome: capture_store.Outcome = if (refused) |reason| .{ .status = .unavailable, .reason = reason } else runCapture(arena, context.cancel, .{
        .profile_root = profile_root,
        .path = context.path,
        .session_id = id,
        .phase = phase,
        .unix_seconds = @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s),
        .deadline = deadline,
        .scan_allocator = context.alloc,
    }, &capture_store.capture) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_skipped session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    debug_trace.logf("workspace", "event=workspace_capture session={s} phase={s} status={s} reason={s} commit={s}", .{
        id, @tagName(phase), @tagName(outcome.status), if (outcome.reason) |reason| @tagName(reason) else "none", outcome.commit orelse "none",
    });
    var triggered = outcome;
    triggered.trigger_tool = trigger_tool;
    const payload = capture_store.encodeRecord(arena, phase, triggered) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_unsaved session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    _ = context.session.saveWorkspaceCapture(turn, payload, switch (phase) {
        .start => .start,
        .end => .end,
    }) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_unsaved session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
    };
}

fn cancelRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.acquire);
}

/// Takes one capture (`capture_store.capture` outside tests).
const Capturer = fn (arena: Allocator, request: capture_store.Request) Allocator.Error!capture_store.Outcome;

/// One capture running as a `std.Io` task; `done` is set as it returns.
const CaptureJob = struct {
    arena: Allocator,
    request: capture_store.Request,
    capturer: *const Capturer,
    done: std.Io.Event = .unset,

    fn run(job: *CaptureJob) Allocator.Error!capture_store.Outcome {
        defer job.done.set(io_mod.getIo());
        return job.capturer(job.arena, job.request);
    }
};

/// Takes the capture, ending it early once `cancel` is set. It runs as a
/// `std.Io` task while this thread waits, looking at `cancel` every
/// `cancel_poll_ms`; on cancel, the task is cancelled and awaited. The git
/// run in flight then stops at once (safe_git ends its process group and
/// passes the cancel on to the capture's next step), and the capture ends;
/// one that wrote no commit is recorded as unavailable with reason
/// `cancelled`. A cancel that reaches the capture outside a git run stops it
/// at its next one, or at the deadline. A cancel already set runs nothing.
/// `arena` belongs to the task until it returns. Without a cancel flag, or
/// when no task can start, the capture runs on this thread.
fn runCapture(arena: Allocator, cancel: ?*const std.atomic.Value(bool), request_in: capture_store.Request, capturer: *const Capturer) Allocator.Error!capture_store.Outcome {
    const flag = cancel orelse return capturer(arena, request_in);
    // The store also polls the flag inside each git run, so a cancel stops
    // a running git even when the task's own cancel was already spent.
    var request = request_in;
    request.cancel = flag;
    if (flag.load(.acquire)) return .{ .status = .unavailable, .reason = .cancelled };
    const io = io_mod.getIo();
    var job: CaptureJob = .{ .arena = arena, .request = request, .capturer = capturer };
    var future = io.concurrent(CaptureJob.run, .{&job}) catch return capturer(arena, request);
    var cancelled = false;
    while (!job.done.isSet()) {
        if (flag.load(.acquire)) {
            cancelled = true;
            break;
        }
        job.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(cancel_poll_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            // This thread's own task was cancelled: end the capture too,
            // and leave the cancel for this thread's next step.
            error.Canceled => {
                io.recancel();
                cancelled = true;
                break;
            },
        };
    }
    var outcome = try (if (cancelled) future.cancel(io) else future.await(io));
    if (cancelled and outcome.commit == null) {
        debug_trace.logf("workspace", "event=workspace_capture_cancelled session={s} phase={s} reason={s}", .{
            request.session_id, @tagName(request.phase), if (outcome.reason) |reason| @tagName(reason) else "none",
        });
        outcome.status = .unavailable;
        outcome.reason = .cancelled;
        outcome.tree = null;
    }
    return outcome;
}

/// The worktree root holding `dir`, symlinks resolved, by `repo_root.zig`'s
/// rules. Reads names and small metadata files only and never runs git, so
/// a tool's every action can ask. Null outside a repository or for a
/// relative `dir`. Owned, `std.heap.c_allocator`.
fn worktreeRoot(dir: []const u8) ?[]u8 {
    if (!std.Io.Dir.path.isAbsolute(dir)) return null;
    const found = (repo_root.find(std.heap.c_allocator, dir) catch |err| {
        keepCancel(err);
        return null;
    }) orelse return null;
    defer std.heap.c_allocator.free(found.git_dir);
    return io_mod.realpathAlloc(std.heap.c_allocator, found.root) catch |err| {
        keepCancel(err);
        return null;
    };
}

/// Hands a cancel a helper swallowed back to the calling task, so its next
/// step sees it.
fn keepCancel(err: anyerror) void {
    if (err == error.Canceled) io_mod.getIo().recancel();
}

/// What `admitCapture` checks for one capture.
const Admit = struct {
    home: []const u8,
    profile_root: []const u8,
    session_id: []const u8,
    /// The capture's own deadline; the check never waits past it.
    deadline: std.Io.Clock.Timestamp,
};

/// Why the profile's captures leave no room for this one, or null when they
/// do. Never runs maintenance: while `maintenance` runs, every capture is
/// refused without measuring, and when retention's `check` finds
/// maintenance due, it starts `maintenance` and refuses this capture. Any
/// failure here refuses the capture.
fn admitCapture(arena: Allocator, maintenance: *Maintenance, request: Admit) ?capture_policy.Reason {
    const id = request.session_id;
    if (maintenance.running()) {
        debug_trace.logf("workspace", "event=workspace_capture_budget session={s} admit=false refusal=maintenance_running", .{id});
        return .budget;
    }
    const key = capture_store.sessionKey(arena, id) catch return .budget;
    const admission = capture_retention.check(arena, .{
        .profile_root = request.profile_root,
        .current_key = key,
        .sessions = .unknown,
        .now_ms = io_mod.milliTimestamp(),
        .deadline = request.deadline,
        .budget = maintenance.budget,
        .target = maintenance.target,
    }) catch return .budget;
    if (admission.due) {
        const started = maintenance.start(request.home, request.profile_root, key);
        debug_trace.logf("workspace", "event=workspace_capture_maintenance session={s} maintenance={s} refusal={s} used={?d}", .{
            id, @tagName(started), if (admission.refusal) |why| @tagName(why) else "none", admission.used,
        });
    } else if (!admission.admit) {
        debug_trace.logf("workspace", "event=workspace_capture_budget session={s} admit=false refusal={s} used={?d}", .{
            id, if (admission.refusal) |why| @tagName(why) else "none", admission.used,
        });
    }
    if (admission.admit) return null;
    // The record keeps `budget` for everything over the budget; the trace
    // above has the precise refusal.
    return switch (admission.refusal orelse .over_budget) {
        .over_budget, .busy, .maintenance_failed => .budget,
        // A measure that ran out of time goes on in the background.
        .measure_failed => if (admission.due) .timeout else .io_error,
        .git_refused => .git_refused,
    };
}

/// What a request to start maintenance did.
const Started = enum { started, already_running, failed };

/// Retention's maintenance, run off the turn as a `std.Io` task, one at a
/// time (`process_maintenance`). The owner calls `finish` before the
/// process ends.
const Maintenance = struct {
    mutex: std.Io.Mutex = .init,
    task: ?*MaintenanceTask = null,
    /// The budget and target checks and maintenance use; tests lower them.
    budget: u64 = capture_retention.budget_bytes,
    target: u64 = capture_retention.target_bytes,
    /// Runs one maintenance (`capture_retention.admit` outside tests).
    work: *const fn (arena: Allocator, config: capture_retention.Config) Allocator.Error!capture_retention.Admission = &capture_retention.admit,

    /// Whether a maintenance this owner started is still running.
    fn running(self: *Maintenance) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const task = self.task orelse return false;
        return !task.finished.load(.acquire);
    }

    /// Starts maintenance of `profile_root` unless one is running. A
    /// finished one is reaped first.
    fn start(self: *Maintenance, home: []const u8, profile_root: []const u8, key: []const u8) Started {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.task) |task| {
            if (!task.finished.load(.acquire)) return .already_running;
            self.task = null;
            task.reap();
        }
        const task = MaintenanceTask.create(self, home, profile_root, key) catch return .failed;
        task.future = io.concurrent(MaintenanceTask.run, .{task}) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_maintenance_failed reason=task err={s}", .{@errorName(err)});
            task.destroy();
            return .failed;
        };
        self.task = task;
        return .started;
    }

    /// Lets a running maintenance finish for up to `grace_ms`, then cancels
    /// it: it stops at its next step, and its git run in flight stops at
    /// once. Returns once it has ended and is freed.
    fn finish(self: *Maintenance, grace_ms: i64) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const task = self.task orelse {
            self.mutex.unlock(io);
            return;
        };
        self.task = null;
        self.mutex.unlock(io);
        const until: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(grace_ms) });
        while (!task.finished.load(.acquire) and !capture_store.pastDeadline(io, until)) {
            task.done.waitTimeout(io, .{ .deadline = until }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    io.recancel();
                    break;
                },
            };
        }
        if (!task.finished.load(.acquire)) debug_trace.logf("workspace", "event=workspace_capture_maintenance_cancelled", .{});
        task.cancel.store(true, .release);
        task.future.cancel(io);
        task.destroy();
    }
};

/// The process's one maintenance owner.
var process_maintenance: Maintenance = .{};

/// Ends the process's maintenance, if one runs: it has `exit_grace_ms` to
/// finish, then is cancelled. Hosts call it once their turns have stopped,
/// as the process ends: `fx ask`, the app, and the ACP server.
pub fn finishMaintenance() void {
    if (comptime !supported) return;
    process_maintenance.finish(exit_grace_ms);
}

/// One maintenance and what it needs, owned by its `Maintenance` until
/// reaped. It opens its own session store, so it touches no host's.
const MaintenanceTask = struct {
    arena: std.heap.ArenaAllocator,
    home: []const u8,
    profile_root: []const u8,
    key: []const u8,
    budget: u64,
    target: u64,
    work: *const fn (arena: Allocator, config: capture_retention.Config) Allocator.Error!capture_retention.Admission,
    cancel: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    done: std.Io.Event = .unset,
    future: std.Io.Future(void) = undefined,

    fn create(owner: *const Maintenance, home: []const u8, profile_root: []const u8, key: []const u8) Allocator.Error!*MaintenanceTask {
        const task = try std.heap.c_allocator.create(MaintenanceTask);
        task.* = .{ .arena = .init(std.heap.c_allocator), .home = "", .profile_root = "", .key = "", .budget = owner.budget, .target = owner.target, .work = owner.work };
        errdefer task.destroy();
        const arena = task.arena.allocator();
        task.home = try arena.dupe(u8, home);
        task.profile_root = try arena.dupe(u8, profile_root);
        task.key = try arena.dupe(u8, key);
        return task;
    }

    fn destroy(task: *MaintenanceTask) void {
        task.arena.deinit();
        std.heap.c_allocator.destroy(task);
    }

    /// Frees a task that has finished.
    fn reap(task: *MaintenanceTask) void {
        task.future.await(io_mod.getIo());
        task.destroy();
    }

    fn run(task: *MaintenanceTask) void {
        const io = io_mod.getIo();
        defer {
            task.finished.store(true, .release);
            task.done.set(io);
        }
        const arena = task.arena.allocator();
        var store = session_adapter.Store.open(std.heap.c_allocator, task.home) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_maintenance_failed reason=sessions err={s}", .{@errorName(err)});
            return;
        };
        defer store.deinit(std.heap.c_allocator);
        var lookup: SessionLookup = .{ .store = &store, .arena = arena };
        const admission = task.work(arena, .{
            .profile_root = task.profile_root,
            .current_key = task.key,
            .sessions = lookup.view(),
            .now_ms = io_mod.milliTimestamp(),
            .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(maintenance_deadline_ms) }),
            .budget = task.budget,
            .target = task.target,
            .cancel = &task.cancel,
        }) catch |err| {
            debug_trace.logf("workspace", "event=workspace_capture_maintenance_failed reason=memory err={s}", .{@errorName(err)});
            return;
        };
        debug_trace.logf("workspace", "event=workspace_capture_maintenance_done admit={} refusal={s} used={?d} maintained={} evicted={d}", .{
            admission.admit, if (admission.refusal) |why| @tagName(why) else "none", admission.used, admission.maintained, admission.evicted.len,
        });
    }
};

/// The profile's sessions by capture key, listed only when maintenance asks.
const SessionLookup = struct {
    store: *session_adapter.Store,
    arena: Allocator,
    ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    loaded: bool = false,
    /// The catalog could not be read: every session counts as present and
    /// open, so nothing is evicted.
    unknown: bool = false,

    fn view(self: *SessionLookup) capture_retention.Sessions {
        return .{ .ctx = self, .exists = exists, .busy = busy };
    }

    fn load(self: *SessionLookup) void {
        if (self.loaded) return;
        self.loaded = true;
        const ids = self.store.sessionIds(self.arena) orelse {
            self.unknown = true;
            return;
        };
        for (ids) |id| {
            const key = capture_store.sessionKey(self.arena, id) catch {
                self.unknown = true;
                return;
            };
            self.ids.put(self.arena, key, id) catch {
                self.unknown = true;
                return;
            };
        }
    }

    fn exists(ctx: *anyopaque, key: []const u8) bool {
        const self: *SessionLookup = @ptrCast(@alignCast(ctx));
        self.load();
        return self.unknown or self.ids.contains(key);
    }

    fn busy(ctx: *anyopaque, key: []const u8) bool {
        const self: *SessionLookup = @ptrCast(@alignCast(ctx));
        self.load();
        if (self.unknown) return true;
        const id = self.ids.get(key) orelse return false;
        return self.store.sessionBusy(id);
    }
};

/// A session in a temporary home, and repositories beside it, for the
/// tests below.
const TestSession = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    store: session_adapter.Store,
    session: *Session,
    model: [1]u8 = "m".*,

    fn init(t: *TestSession) !void {
        t.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer t.tmp.cleanup();
        t.home = try io_mod.dirRealpathAlloc(std.testing.allocator, t.tmp.dir, ".");
        errdefer std.testing.allocator.free(t.home);
        t.store = try session_adapter.Store.open(std.testing.allocator, t.home);
        errdefer t.store.deinit(std.testing.allocator);
        t.model = "m".*;
        t.session = try Session.create(std.testing.allocator, &t.store, "/w", .ask, .{
            .preferences = .{ .model = &t.model, .effort = .auto, .fast_mode = false },
            .language = @import("../shared/types.zig").ConversationLanguage.default(),
            .permission_state = .{},
        });
    }

    fn deinit(t: *TestSession) void {
        t.session.close();
        t.store.deinit(std.testing.allocator);
        std.testing.allocator.free(t.home);
        t.tmp.cleanup();
    }

    /// Makes `<tmp>/<name>` a repository and returns a folder inside it.
    fn repository(t: *TestSession, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        try t.tmp.dir.createDirPath(std.testing.io, try std.mem.print(&buf, "repos/{s}/.git", .{name}));
        try t.tmp.dir.createDirPath(std.testing.io, try std.mem.print(&buf, "repos/{s}/src", .{name}));
        return std.Io.Dir.path.join(std.testing.allocator, &.{ t.home, "repos", name, "src" });
    }

    /// A context whose home is not above the repositories, so reaching
    /// them is allowed.
    fn context(t: *TestSession) Context {
        return .{ .session = t.session, .home = "/nonexistent-fx-test-home", .path = t.home, .alloc = std.heap.c_allocator };
    }
};

/// What the fake recorder saw; the tests run one at a time.
const FakeRecorder = struct {
    var starts: std.atomic.Value(usize) = .init(0);
    var ends: std.atomic.Value(usize) = .init(0);
    var active: std.atomic.Value(usize) = .init(0);
    var max_active: std.atomic.Value(usize) = .init(0);
    var saved: std.atomic.Value(bool) = .init(false);
    var skipped: std.atomic.Value(usize) = .init(0);
    /// Each start capture waits until this many run at once, or 2 s.
    var wait_for: usize = 1;

    fn reset(concurrent: usize) void {
        starts.store(0, .seq_cst);
        ends.store(0, .seq_cst);
        active.store(0, .seq_cst);
        max_active.store(0, .seq_cst);
        saved.store(false, .seq_cst);
        skipped.store(0, .seq_cst);
        wait_for = concurrent;
    }

    fn record(context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?capture_policy.Reason) void {
        _ = .{ context, turn, lock, trigger_tool };
        if (skip != null) _ = skipped.fetchAdd(1, .seq_cst);
        if (phase == .end) {
            _ = ends.fetchAdd(1, .seq_cst);
            return;
        }
        _ = starts.fetchAdd(1, .seq_cst);
        const now = active.fetchAdd(1, .seq_cst) + 1;
        _ = max_active.fetchMax(now, .seq_cst);
        var waited: usize = 0;
        while (active.load(.seq_cst) < wait_for and waited < 2000) : (waited += 1) io_mod.sleep(std.time.ns_per_ms);
        saved.store(true, .seq_cst);
        _ = active.fetchSub(1, .seq_cst);
    }
};

fn reachIn(captures: *TurnCapture, context: Context, dir: []const u8, lock: *std.Io.Mutex) void {
    captures.reach(context, dir, "write_file", lock);
}

test "the worktree root follows the shared finder and resolves symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);
    const dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo/src/new" });
    defer std.testing.allocator.free(dir);
    const got = worktreeRoot(dir).?;
    defer std.heap.c_allocator.free(got);
    const want = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo" });
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(worktreeRoot("relative/path") == null);
}

test "a reached repository at the filesystem root, the home folder, or above it is private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "users/me/work");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);
    const home = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/me" });
    defer std.testing.allocator.free(home);
    const users = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users" });
    defer std.testing.allocator.free(users);
    const work = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/me/work" });
    defer std.testing.allocator.free(work);
    const sibling = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/meme" });
    defer std.testing.allocator.free(sibling);
    const homes = [_]?[]const u8{ null, home };
    try std.testing.expect(isPrivateRoot("/", &homes));
    try std.testing.expect(isPrivateRoot(home, &homes));
    try std.testing.expect(isPrivateRoot(users, &homes));
    try std.testing.expect(!isPrivateRoot(work, &homes));
    try std.testing.expect(!isPrivateRoot(sibling, &homes));
}

test "reach skips a repository at the home folder and captures one beside it" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    var context = t.context();
    const home_dir = try t.repository("home");
    defer std.testing.allocator.free(home_dir);
    const other_dir = try t.repository("other");
    defer std.testing.allocator.free(other_dir);
    context.home = std.Io.Dir.path.dirname(home_dir).?;
    captures.begin(context, true);
    captures.reach(context, home_dir, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 0), FakeRecorder.starts.load(.seq_cst));
    captures.reach(context, other_dir, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "parallel reaches of different repositories capture at once" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    const b = try t.repository("b");
    defer std.testing.allocator.free(b);
    captures.begin(context, true);
    const first = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    const second = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, b, &lock });
    first.join();
    second.join();
    // Serialized captures would each wait 2 s alone and never overlap.
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.max_active.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.starts.load(.seq_cst));
}

test "a parallel reach of the same repository waits for its one start capture" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    // Never two at once, so each start capture waits its full 2 s cap,
    // long enough for the second call to arrive while the first runs.
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    captures.begin(context, true);
    const first = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    while (FakeRecorder.starts.load(.seq_cst) == 0) io_mod.sleep(std.time.ns_per_ms);
    captures.reach(context, a, "write_file", &lock);
    // The second call returned only after the start capture was saved.
    try std.testing.expect(FakeRecorder.saved.load(.seq_cst));
    first.join();
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "a reach racing the turn's commit leaves no repository behind" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    captures.begin(context, true);
    const turn = captures.current;
    const racer = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    while (FakeRecorder.starts.load(.seq_cst) == 0) io_mod.sleep(std.time.ns_per_ms);
    captures.committed(turn);
    racer.join();
    try std.testing.expect(captures.current == null);
    try std.testing.expectEqual(@as(usize, 0), captures.reached.items.len);
    // A reach after the commit has no turn to capture for.
    captures.reach(context, a, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "a turn captures at most max_reached other repositories, and its end captures each" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    captures.begin(context, true);
    var index: usize = 0;
    while (index < max_reached + 1) : (index += 1) {
        var buf: [16]u8 = undefined;
        const dir = try t.repository(try std.mem.print(&buf, "r{d}", .{index}));
        defer std.testing.allocator.free(dir);
        captures.reach(context, dir, "write_file", &lock);
    }
    try std.testing.expectEqual(@as(usize, max_reached), FakeRecorder.starts.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, max_reached), captures.reached.items.len);
    try std.testing.expect(captures.token() == null);
    _ = captures.end(context, &lock);
    const turn = captures.token();
    try std.testing.expect(turn != null);
    // The session's own repository and each reached one.
    try std.testing.expectEqual(@as(usize, max_reached + 1), FakeRecorder.ends.load(.seq_cst));
    // A retried commit reuses the end capture.
    _ = captures.end(context, &lock);
    try std.testing.expectEqual(@as(usize, max_reached + 1), FakeRecorder.ends.load(.seq_cst));
    captures.committed(turn);
    try std.testing.expect(captures.token() == null);
}

test "a steering message after the turn ended begins a new capture turn, and each commit uses the token its end returned" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    captures.begin(context, true);
    captures.start(context, &lock);
    // Steering while the turn runs adds nothing.
    const first = captures.current.?;
    captures.begin(context, false);
    captures.start(context, &lock);
    try std.testing.expectEqual(first, captures.current.?);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
    try std.testing.expectEqual(first, captures.end(context, &lock).?);
    // A retried end returns the same token without a second capture.
    try std.testing.expectEqual(first, captures.end(context, &lock).?);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.ends.load(.seq_cst));
    // The app's next prompt arrives as steering before the UI commits the
    // first turn: it takes its own start capture under a new token.
    captures.begin(context, false);
    captures.start(context, &lock);
    const second = captures.current.?;
    try std.testing.expect(second != first);
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.starts.load(.seq_cst));
    try std.testing.expectEqual(second, captures.end(context, &lock).?);
    // The UI's late commit of the first turn carries the first token and
    // leaves the second turn alone.
    captures.committed(first);
    try std.testing.expectEqual(second, captures.current.?);
    try std.testing.expectEqual(second, captures.token().?);
    captures.committed(second);
    try std.testing.expect(captures.token() == null);
    try std.testing.expect(captures.current == null);
}

/// Saves each capture as a real `workspace_capture` item named by `label`
/// and its phase, such as `A-start`, for tests that read the session's log.
const SavingRecorder = struct {
    var label: []const u8 = "";

    fn record(context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8, skip: ?capture_policy.Reason) void {
        _ = .{ trigger_tool, skip };
        var buf: [64]u8 = undefined;
        const payload = std.mem.print(&buf, "{{\"capture\":\"{s}-{t}\"}}", .{ label, phase }) catch return;
        lock.lockUncancelable(io_mod.getIo());
        defer lock.unlock(io_mod.getIo());
        _ = context.session.saveWorkspaceCapture(turn, payload, switch (phase) {
            .start => .start,
            .end => .end,
        }) catch {};
    }
};

/// Which committed turn, counted from 1 in the order written, holds the
/// capture of `name` and `phase` (`SavingRecorder`) in session `id`'s log under
/// `home`; 0 when none does. A turn closed by `turn_interrupted`, as a
/// superseded one is, holds nothing, since readers drop it whole.
fn committedTurnOf(home: []const u8, id: []const u8, name: []const u8, phase: capture_store.Phase) !usize {
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ home, ".fx", "sessions", "v2", id, "log.jsonl" });
    defer std.testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(bytes);
    var needle_buf: [64]u8 = undefined;
    const needle = try std.mem.print(&needle_buf, "\"{s}-{t}\"", .{ name, phase });
    var committed: usize = 0;
    var pending = false;
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "turn_committed") != null) {
            committed += 1;
            if (pending) found = committed;
            pending = false;
        } else if (std.mem.find(u8, line, "turn_interrupted") != null) {
            pending = false;
        } else if (std.mem.find(u8, line, "workspace_capture") != null and std.mem.find(u8, line, needle) != null) {
            pending = true;
        }
    }
    return found;
}

test "two turns that end before the UI commits the first: each commit writes only its own turn's captures" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &SavingRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const language = @import("../shared/types.zig").ConversationLanguage.default();
    // Prompt A's answer is still drawn when B arrives as steering after A's
    // end capture, and C after B's, all before the UI commits A. Each
    // finished prompt carries the token its end returned.
    const prompts = [_][]const u8{ "A", "B", "C" };
    var tokens: [prompts.len]Session.CaptureTurn = undefined;
    for (prompts, &tokens, 0..) |name, *token, index| {
        captures.begin(context, index == 0);
        try t.session.appendProgress(.{ .text = @constCast(name) }, .{}, .{});
        SavingRecorder.label = name;
        captures.start(context, &lock);
        token.* = captures.end(context, &lock).?;
    }
    // The UI commits each finished prompt in order with its own token.
    for (prompts, tokens) |name, token| {
        lock.lockUncancelable(std.testing.io);
        defer lock.unlock(std.testing.io);
        try t.session.commitTurnWithCaptures(.{ .assistant = .{ .user = .{ .text = @constCast(name) }, .assistant = @constCast("ok") } }, language, token);
        captures.committed(token);
    }
    try std.testing.expect(captures.current == null);
    // The session holds one ended turn, so C's begin dropped A's captures:
    // A commits none, never B's, and B and C each commit their own.
    try std.testing.expectEqual(@as(usize, 0), try committedTurnOf(t.home, t.session.id(), "A", .start));
    try std.testing.expectEqual(@as(usize, 0), try committedTurnOf(t.home, t.session.id(), "A", .end));
    try std.testing.expectEqual(@as(usize, 2), try committedTurnOf(t.home, t.session.id(), "B", .start));
    try std.testing.expectEqual(@as(usize, 2), try committedTurnOf(t.home, t.session.id(), "B", .end));
    try std.testing.expectEqual(@as(usize, 3), try committedTurnOf(t.home, t.session.id(), "C", .start));
    try std.testing.expectEqual(@as(usize, 3), try committedTurnOf(t.home, t.session.id(), "C", .end));
}

test "an ordinary prompt after an ended, uncommitted turn keeps that turn's captures for its own commit, and one after an abandoned turn drops them" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &SavingRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const language = @import("../shared/types.zig").ConversationLanguage.default();
    // A ended and waits for the UI's late commit when B arrives as an
    // ordinary prompt, not as steering. C begins fresh after B began but
    // before B took its end capture: B is abandoned. D then runs alone.
    SavingRecorder.label = "A";
    captures.begin(context, true);
    try t.session.appendProgress(.{ .text = @constCast("A") }, .{}, .{});
    captures.start(context, &lock);
    const a = captures.end(context, &lock).?;
    SavingRecorder.label = "B";
    captures.begin(context, true);
    try t.session.appendProgress(.{ .text = @constCast("B") }, .{}, .{});
    captures.start(context, &lock);
    const b = captures.current.?;
    try std.testing.expect(b != a);
    // `token` never lends A's token to B's turn.
    try std.testing.expect(captures.token() == null);
    {
        lock.lockUncancelable(std.testing.io);
        defer lock.unlock(std.testing.io);
        try t.session.commitTurnWithCaptures(.{ .assistant = .{ .user = .{ .text = @constCast("A") }, .assistant = @constCast("ok") } }, language, a);
    }
    captures.committed(a);
    try std.testing.expectEqual(b, captures.current.?);
    SavingRecorder.label = "C";
    captures.begin(context, true);
    try t.session.appendProgress(.{ .text = @constCast("C") }, .{}, .{});
    captures.start(context, &lock);
    const c = captures.end(context, &lock).?;
    {
        lock.lockUncancelable(std.testing.io);
        defer lock.unlock(std.testing.io);
        // B's late commit, had it come, takes nothing.
        try t.session.commitTurnWithCaptures(.{ .assistant = .{ .user = .{ .text = @constCast("C") }, .assistant = @constCast("ok") } }, language, c);
    }
    captures.committed(c);
    try std.testing.expect(captures.current == null);
    // The abandoned B was never kept as an ended turn: the session holds
    // nothing of it, waiting for a commit that never comes.
    try std.testing.expectEqual(@as(usize, 0), t.session.captures.items.len);
    // A, committed after B began, keeps its own start and end; B's start
    // was dropped with it abandoned; C keeps its own.
    try std.testing.expectEqual(@as(usize, 1), try committedTurnOf(t.home, t.session.id(), "A", .start));
    try std.testing.expectEqual(@as(usize, 1), try committedTurnOf(t.home, t.session.id(), "A", .end));
    try std.testing.expectEqual(@as(usize, 0), try committedTurnOf(t.home, t.session.id(), "B", .start));
    try std.testing.expectEqual(@as(usize, 0), try committedTurnOf(t.home, t.session.id(), "B", .end));
    try std.testing.expectEqual(@as(usize, 2), try committedTurnOf(t.home, t.session.id(), "C", .start));
    try std.testing.expectEqual(@as(usize, 2), try committedTurnOf(t.home, t.session.id(), "C", .end));
}

test "a session whose folder lies in a private repository records its start and end without capturing" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    var context = t.context();
    const work_dir = try t.repository("home");
    defer std.testing.allocator.free(work_dir);
    // The repository is the home folder; the session works in a folder
    // inside it.
    context.home = std.Io.Dir.path.dirname(work_dir).?;
    context.path = work_dir;
    captures.begin(context, true);
    captures.start(context, &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.skipped.load(.seq_cst));
    // A tool acting there captures nothing either.
    captures.reach(context, work_dir, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
    _ = captures.end(context, &lock);
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.skipped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.ends.load(.seq_cst));
    // A repository that is not private captures as before.
    FakeRecorder.reset(1);
    const other_dir = try t.repository("other");
    defer std.testing.allocator.free(other_dir);
    context.path = other_dir;
    captures.begin(context, true);
    captures.start(context, &lock);
    _ = captures.end(context, &lock);
    try std.testing.expectEqual(@as(usize, 0), FakeRecorder.skipped.load(.seq_cst));
}

/// Plain git for the fork test's fixture, isolated from the user's config.
const TestGit = struct {
    arena: Allocator,
    env: *std.process.Environ.Map,

    fn init(arena: Allocator, home: []const u8) !TestGit {
        const env = try arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(arena);
        const config = try std.Io.Dir.path.join(arena, &.{ home, ".gitconfig" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config, .data = "[init]\n\tdefaultBranch = main\n" });
        try env.put("HOME", home);
        try env.put("GIT_CONFIG_GLOBAL", config);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("PATH", "/usr/bin:/bin");
        return .{ .arena = arena, .env = env };
    }

    fn runGit(self: TestGit, cwd: []const u8, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "/usr/bin/git", "-c", "user.name=fx", "-c", "user.email=fx@example.com", "-c", "commit.gpgsign=false" });
        try argv.appendSlice(self.arena, args);
        const result = try std.process.run(self.arena, std.testing.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
            .environ_map = self.env,
        });
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git failed: {s}\n", .{result.stderr});
        return error.FixtureGitFailed;
    }
};

test "a fork copy finished at once skips what it has not begun and leaves no task behind" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var model = "m".*;
    const fork = try Session.create(std.testing.allocator, &t.store, "/w", .ask, .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = @import("../shared/types.zig").ConversationLanguage.default(),
        .permission_state = .{},
    });
    defer fork.close();
    // The app's teardown finishes a copy still running: `finish` cancels
    // the copies not begun, waits for the one running, and frees the task.
    // The source has no captures, so whatever ran copies nothing.
    const task = ForkCopy.start(t.home, t.session.id(), fork, &.{}) orelse return error.TestUnexpectedResult;
    task.finish();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile_root = try profile_paths.rootDir(arena, t.home);
    const stores = try capture_store.listStoreDirs(arena, std.testing.io, try std.Io.Dir.path.join(arena, &.{ profile_root, "captures" }));
    try std.testing.expectEqual(@as(usize, 0), stores.len);
}

test "a fork keeps the source's and a copied subagent's captures, even once the source's are evicted" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git: TestGit = try .init(arena, t.home);
    const repo = try std.Io.Dir.path.join(arena, &.{ t.home, "repo" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, repo);
    _ = git.runGit(repo, &.{ "init", "-q" }) catch return error.SkipZigTest;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.Io.Dir.path.join(arena, &.{ repo, "a.txt" }), .data = "one\n" });
    _ = try git.runGit(repo, &.{ "add", "a.txt" });
    _ = try git.runGit(repo, &.{ "commit", "-q", "-m", "one" });

    const profile_root = try profile_paths.rootDir(arena, t.home);
    const source_child = "1786460757753-child";
    const fork_child = "1786460757754-copy";
    var commits: [2][]const u8 = undefined;
    for ([_][]const u8{ t.session.id(), source_child }, &commits) |id, *commit| {
        const outcome = try capture_store.capture(arena, .{
            .profile_root = profile_root,
            .path = repo,
            .session_id = id,
            .phase = .start,
            .unix_seconds = 1,
            .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(60_000) }),
            .scan_allocator = std.testing.allocator,
        });
        try std.testing.expectEqual(capture_store.Status.complete, outcome.status);
        commit.* = outcome.commit.?;
    }

    var model = "m".*;
    const fork = try Session.create(std.testing.allocator, &t.store, "/w", .ask, .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = @import("../shared/types.zig").ConversationLanguage.default(),
        .permission_state = .{},
    });
    defer fork.close();
    // A fork holds the source's turns; its subagent copy is registered
    // after them.
    try fork.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("delegate") }, .assistant = @constCast("ok") } }, @import("../shared/types.zig").ConversationLanguage.default());
    try fork.appendChildLines(&.{.{ .spawned = .{ .child = fork_child, .work_id = "w1" } }});
    // The app's fork copy: started as a task, finished once done.
    const task = ForkCopy.start(t.home, t.session.id(), fork, &.{.{ .id = source_child, .work_id = "w1", .outcome = .ok }}) orelse return error.TestUnexpectedResult;
    var waited: usize = 0;
    while (!task.done() and waited < 60_000) : (waited += 1) io_mod.sleep(std.time.ns_per_ms);
    try std.testing.expect(task.done());
    task.finish();

    const stores = try capture_store.listStoreDirs(arena, std.testing.io, try std.Io.Dir.path.join(arena, &.{ profile_root, "captures" }));
    try std.testing.expectEqual(@as(usize, 1), stores.len);
    const store = try capture_store.storeGitDir(arena, stores[0]);
    const prefix = struct {
        fn of(a: Allocator, id: []const u8) ![]const u8 {
            return a.print("refs/fx/sessions/{s}/", .{try capture_store.sessionKey(a, id)});
        }
    }.of;
    const pairs = [_]struct { []const u8, []const u8, []const u8 }{
        .{ t.session.id(), fork.id(), commits[0] },
        .{ source_child, fork_child, commits[1] },
    };
    for (pairs) |pair| {
        try std.testing.expectEqualStrings(pair[2], try git.runGit(t.home, &.{ "--git-dir", store, "for-each-ref", "--format=%(objectname)", try prefix(arena, pair[1]) }));
    }
    // Retention evicts the source's refs; the fork's commits still resolve.
    for (pairs) |pair| {
        const refs = try git.runGit(t.home, &.{ "--git-dir", store, "for-each-ref", "--format=%(refname)", try prefix(arena, pair[0]) });
        var lines = std.mem.splitScalar(u8, refs, '\n');
        while (lines.next()) |ref| if (ref.len > 0) {
            _ = try git.runGit(t.home, &.{ "--git-dir", store, "update-ref", "-d", ref });
        };
    }
    _ = try git.runGit(t.home, &.{ "--git-dir", store, "reflog", "expire", "--expire=now", "--all" });
    _ = try git.runGit(t.home, &.{ "--git-dir", store, "gc", "--quiet", "--prune=now" });
    for (pairs) |pair| {
        try std.testing.expectEqualStrings("", try git.runGit(t.home, &.{ "--git-dir", store, "for-each-ref", try prefix(arena, pair[0]) }));
        try std.testing.expectEqualStrings("commit", try git.runGit(t.home, &.{ "--git-dir", store, "cat-file", "-t", pair[2] }));
    }
}

test "retention finds a subagent's captures under a saved session, never as an orphan" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.session.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("delegate") }, .assistant = @constCast("ok") } }, @import("../shared/types.zig").ConversationLanguage.default());
    const child = "1786460757753-child";
    try t.session.appendChildLines(&.{.{ .spawned = .{ .child = child, .work_id = "w1" } }});
    var lookup: SessionLookup = .{ .store = &t.store, .arena = arena };
    const sessions = lookup.view();
    try std.testing.expect(sessions.exists(sessions.ctx, try capture_store.sessionKey(arena, t.session.id())));
    try std.testing.expect(sessions.exists(sessions.ctx, try capture_store.sessionKey(arena, child)));
    try std.testing.expect(!lookup.unknown);
    try std.testing.expect(!sessions.exists(sessions.ctx, try capture_store.sessionKey(arena, "1786460757755-gone")));
}

/// A maintenance for the tests below: it waits until `release` or until
/// cancelled, then removes `filler` and runs retention's own.
const TestMaintenance = struct {
    var runs: std.atomic.Value(usize) = .init(0);
    var release: std.atomic.Value(bool) = .init(false);
    var saw_cancel: std.atomic.Value(bool) = .init(false);

    fn reset() void {
        runs.store(0, .seq_cst);
        release.store(false, .seq_cst);
        saw_cancel.store(false, .seq_cst);
    }

    fn work(arena: Allocator, config: capture_retention.Config) Allocator.Error!capture_retention.Admission {
        _ = runs.fetchAdd(1, .seq_cst);
        var waited: usize = 0;
        while (!release.load(.seq_cst) and waited < 10_000) : (waited += 1) {
            if (config.cancel.?.load(.acquire)) {
                saw_cancel.store(true, .seq_cst);
                return .{ .admit = false, .refusal = .over_budget, .maintained = true };
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        const filler = try std.Io.Dir.path.join(arena, &.{ config.profile_root, "captures", "filler" });
        std.Io.Dir.deleteFileAbsolute(std.testing.io, filler) catch {};
        return capture_retention.admit(arena, config);
    }

    /// Waits up to 5 s for `done`.
    fn waitFor(comptime done: fn (*Maintenance) bool, maintenance: *Maintenance) bool {
        var waited: usize = 0;
        while (!done(maintenance) and waited < 5000) : (waited += 1) io_mod.sleep(std.time.ns_per_ms);
        return done(maintenance);
    }

    fn entered(_: *Maintenance) bool {
        return runs.load(.seq_cst) > 0;
    }

    fn stopped(maintenance: *Maintenance) bool {
        return !maintenance.running();
    }
};

/// A profile whose captures folder holds 64 KiB beside the stores, over the
/// 16 KiB budget the tests below give their `Maintenance`.
fn overBudgetProfile(arena: Allocator, home: []const u8) ![]const u8 {
    const profile_root = try profile_paths.rootDir(arena, home);
    const captures = try std.Io.Dir.path.join(arena, &.{ profile_root, "captures" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, captures);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.Io.Dir.path.join(arena, &.{ captures, "filler" }), .data = &@as([64 * 1024]u8, @splat('x')) });
    return profile_root;
}

test "an over-budget capture is refused at once while one maintenance runs in the background, and admitted once it gets under" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile_root = try overBudgetProfile(arena, t.home);
    TestMaintenance.reset();
    var maintenance: Maintenance = .{ .budget = 16 * 1024, .target = 16 * 1024, .work = &TestMaintenance.work };
    defer maintenance.finish(0);
    const request: Admit = .{
        .home = t.home,
        .profile_root = profile_root,
        .session_id = t.session.id(),
        .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
    };

    // The capture does not wait for the maintenance it starts, which stays
    // running until released.
    const began = io_mod.milliTimestamp();
    try std.testing.expectEqual(@as(?capture_policy.Reason, .budget), admitCapture(arena, &maintenance, request));
    try std.testing.expect(io_mod.milliTimestamp() - began < 500);
    try std.testing.expect(TestMaintenance.waitFor(TestMaintenance.entered, &maintenance));
    // A capture while it runs is refused too, and starts no other.
    try std.testing.expectEqual(@as(?capture_policy.Reason, .budget), admitCapture(arena, &maintenance, request));
    try std.testing.expectEqual(maintenance.start(t.home, profile_root, "k"), .already_running);
    try std.testing.expectEqual(@as(usize, 1), TestMaintenance.runs.load(.seq_cst));

    // Once it brings the space under the target, the next capture is
    // admitted, and no maintenance runs again.
    TestMaintenance.release.store(true, .seq_cst);
    try std.testing.expect(TestMaintenance.waitFor(TestMaintenance.stopped, &maintenance));
    try std.testing.expectEqual(@as(?capture_policy.Reason, null), admitCapture(arena, &maintenance, request));
    try std.testing.expectEqual(@as(usize, 1), TestMaintenance.runs.load(.seq_cst));
}

test "finishing maintenance at teardown cancels one still running and frees it" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile_root = try overBudgetProfile(arena, t.home);
    TestMaintenance.reset();
    var maintenance: Maintenance = .{ .budget = 16 * 1024, .target = 16 * 1024, .work = &TestMaintenance.work };
    try std.testing.expectEqual(Started.started, maintenance.start(t.home, profile_root, try capture_store.sessionKey(arena, t.session.id())));
    try std.testing.expect(TestMaintenance.waitFor(TestMaintenance.entered, &maintenance));
    const began = io_mod.milliTimestamp();
    maintenance.finish(50);
    try std.testing.expect(io_mod.milliTimestamp() - began < 1000);
    try std.testing.expect(TestMaintenance.saw_cancel.load(.seq_cst));
    try std.testing.expect(maintenance.task == null);
    // Nothing runs, so finishing again returns at once.
    maintenance.finish(exit_grace_ms);
}

test "a maintenance that finishes within the grace is awaited, not cancelled" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile_root = try overBudgetProfile(arena, t.home);
    TestMaintenance.reset();
    TestMaintenance.release.store(true, .seq_cst);
    var maintenance: Maintenance = .{ .budget = 16 * 1024, .target = 16 * 1024, .work = &TestMaintenance.work };
    try std.testing.expectEqual(Started.started, maintenance.start(t.home, profile_root, try capture_store.sessionKey(arena, t.session.id())));
    maintenance.finish(exit_grace_ms);
    try std.testing.expect(!TestMaintenance.saw_cancel.load(.seq_cst));
    // It ran to the end: the filler is gone and the space measured.
    const usage = try std.Io.Dir.path.join(arena, &.{ profile_root, "captures", "usage" });
    try std.Io.Dir.accessAbsolute(std.testing.io, usage, .{});
}

/// A capture that takes 10 s unless its task is cancelled, which it reports
/// as an I/O failure, as a git run a cancel stopped can.
const SlowCapture = struct {
    var saw_cancel: std.atomic.Value(bool) = .init(false);
    var calls: std.atomic.Value(usize) = .init(0);

    fn capture(arena: Allocator, request: capture_store.Request) Allocator.Error!capture_store.Outcome {
        _ = .{ arena, request };
        _ = calls.fetchAdd(1, .seq_cst);
        std.testing.io.sleep(.fromSeconds(10), .awake) catch |err| switch (err) {
            error.Canceled => {
                saw_cancel.store(true, .seq_cst);
                return .{ .status = .failed, .reason = .io_error };
            },
        };
        return .{ .status = .complete, .commit = "0123456789abcdef0123456789abcdef01234567" };
    }

    fn cancelSoon(flag: *std.atomic.Value(bool)) void {
        io_mod.sleep(50 * std.time.ns_per_ms);
        flag.store(true, .seq_cst);
    }
};

test "a cancel ends a capture in flight, recorded as unavailable with reason cancelled" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    SlowCapture.saw_cancel.store(false, .seq_cst);
    var cancel: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, SlowCapture.cancelSoon, .{&cancel});
    defer thread.join();
    const began = io_mod.milliTimestamp();
    const outcome = try runCapture(arena_state.allocator(), &cancel, .{
        .profile_root = "/p",
        .path = "/w",
        .session_id = "s",
        .phase = .start,
        .unix_seconds = 1,
        .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
        .scan_allocator = std.testing.allocator,
    }, &SlowCapture.capture);
    // The cancel reached the capture's task, well before its 10 s.
    try std.testing.expect(io_mod.milliTimestamp() - began < 1000);
    try std.testing.expect(SlowCapture.saw_cancel.load(.seq_cst));
    try std.testing.expectEqual(capture_store.Status.unavailable, outcome.status);
    try std.testing.expectEqual(@as(?capture_policy.Reason, .cancelled), outcome.reason);
}

/// A capture that takes 300 ms unless its task is cancelled, for a turn
/// whose worker a test steers or cancels meanwhile.
const BriefCapture = struct {
    fn capture(arena: Allocator, request: capture_store.Request) Allocator.Error!capture_store.Outcome {
        _ = .{ arena, request };
        std.testing.io.sleep(.fromMilliseconds(300), .awake) catch |err| switch (err) {
            error.Canceled => return .{ .status = .failed, .reason = .io_error },
        };
        return .{ .status = .complete, .commit = "0123456789abcdef0123456789abcdef01234567" };
    }
};

test "a follow-up sent during a capture leaves it running, and the user's cancel still ends it" {
    if (!supported) return error.SkipZigTest;
    const worker_runtime = @import("../agent/worker_runtime.zig");
    const types = @import("../shared/types.zig");
    const Turn = struct {
        fn followUp(worker: *worker_runtime.WorkerRuntime) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            const alloc = std.testing.allocator;
            const history = alloc.alloc(types.HistoryTurn, 0) catch return;
            const grants = alloc.alloc(types.PermissionGrant, 0) catch return;
            worker.admitInteractivePrompt(alloc, .{
                .prompt = alloc.dupe(u8, "follow-up") catch return,
                .images = &.{},
                .model = alloc.dupe(u8, "model") catch return,
                .api_key = alloc.dupe(u8, "key") catch return,
                .permission_mode = .auto,
                .history = history,
                .grants = grants,
            }) catch return;
        }

        fn cancel(worker: *worker_runtime.WorkerRuntime) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            worker.requestInteractiveCancel();
        }
    };
    inline for (.{ false, true }) |user_cancels| {
        var worker: worker_runtime.WorkerRuntime = .{};
        defer worker.deinit(std.testing.allocator);
        try std.testing.expect(worker.beginDirectProcessing(41));
        defer worker.finishProcessing();
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const thread = try std.Thread.spawn(.{}, if (user_cancels) Turn.cancel else Turn.followUp, .{&worker});
        const outcome = runCapture(arena_state.allocator(), &worker.turn_cancel_requested, .{
            .profile_root = "/p",
            .path = "/w",
            .session_id = "s",
            .phase = .start,
            .unix_seconds = 1,
            .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
            .scan_allocator = std.testing.allocator,
        }, &BriefCapture.capture);
        thread.join();
        const finished = try outcome;
        // The follow-up did interrupt the model.
        try std.testing.expect(worker.isCancelRequested());
        if (user_cancels) {
            try std.testing.expectEqual(capture_store.Status.unavailable, finished.status);
            try std.testing.expectEqual(@as(?capture_policy.Reason, .cancelled), finished.reason);
        } else {
            try std.testing.expectEqual(capture_store.Status.complete, finished.status);
            try std.testing.expect(finished.commit != null);
        }
    }
}

test "a capture asked for after the cancel never runs" {
    if (!supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    SlowCapture.calls.store(0, .seq_cst);
    var cancel: std.atomic.Value(bool) = .init(true);
    const outcome = try runCapture(arena_state.allocator(), &cancel, .{
        .profile_root = "/p",
        .path = "/w",
        .session_id = "s",
        .phase = .end,
        .unix_seconds = 1,
        .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
        .scan_allocator = std.testing.allocator,
    }, &SlowCapture.capture);
    try std.testing.expectEqual(@as(usize, 0), SlowCapture.calls.load(.seq_cst));
    try std.testing.expectEqual(@as(?capture_policy.Reason, .cancelled), outcome.reason);
}

test "a capture begun after the turn's cancel saves cancelled without capturing" {
    if (!supported) return error.SkipZigTest;
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    var context = t.context();
    context.cancel = &cancel;
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{};
    defer captures.deinit();
    captures.begin(context, true);
    const turn = captures.current.?;
    record(context, turn, .start, &lock, null, null);
    try std.testing.expectEqual(@as(usize, 1), t.session.captures.items.len);
    const saved = t.session.captures.items[0].data;
    try std.testing.expect(std.mem.find(u8, saved, "\"reason\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.find(u8, saved, "\"status\":\"unavailable\"") != null);
    // Nothing reached fx's store.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const captures_dir = try std.Io.Dir.path.join(arena, &.{ try profile_paths.rootDir(arena, t.home), "captures" });
    try std.testing.expect(!capture_store.exists(std.testing.io, captures_dir));
}
