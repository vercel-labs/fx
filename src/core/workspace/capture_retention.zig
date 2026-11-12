//! Retention of workspace captures: captures stay while
//! their session exists, within one budget for the whole profile.
//!
//! Before a capture writes, `check` reads the space `~/.fx/captures` takes
//! and never runs maintenance, so a turn never waits for it. When the space
//! is over the budget and maintenance is due, or the measure ran out of
//! time, `check` refuses the capture with `Admission.due` set, and the
//! caller runs `admit`, which measures again and maintains, off the turn
//! (`turn_capture.zig` runs it as a background task, one per process).
//! The space is kept per store in `captures/usage`, so a capture walks only
//! the stores that changed:
//!
//! ```text
//! v2 <total bytes> <last maintenance, unix ms or 0>
//! <store folder> <bytes> <measured, unix ms> <fingerprint, 16 hex digits>
//! ```
//!
//! one store line per folder, in name order. The fingerprint hashes the
//! times of the store's object folders: a new loose object changes its
//! fan-out folder's time, a pack the pack folder's. A store is walked again
//! when its fingerprint differs, when its measure is `measure_interval_ms`
//! old, and when it is new; a store that is gone drops out. A fingerprint
//! taken within `racy_ms` of a folder's time is written as zero and never
//! matches, since a later write in the same clock tick would leave the time
//! as it was; 2 s covers the coarsest file clocks in use. The few files
//! beside the stores are counted on every admit. `usage` is read only when
//! it is a regular file, never through a symlink, and only up to 1 MiB. A
//! negative time or one more than `future_ms` ahead of the clock, any other
//! content, and the one-line format before it are no cache: every store is
//! walked again.
//!
//! Over the budget, maintenance runs in one process at a time
//! (`captures/maintenance.lock`) and at most once per `measure_interval_ms`.
//! The interval is checked again under the lock, since another process's
//! maintenance may have finished meanwhile, and no write of `usage` brings
//! back an older maintenance time. `Config.cancel` stops maintenance at its
//! next step, as its deadline does; a maintenance stopped that way records
//! no maintenance time, so the next capture may start it again at once.
//!
//! 1. Stores a stopped maintenance left marked (step 4) are pruned first,
//!    within `prune_share_percent` of the time left, so a crash between
//!    deleting refs and pruning does not keep the space. A store still
//!    locked keeps its marker, and eviction goes on.
//! 2. Over the target, stores with at least `Config.repack_loose` loose
//!    objects are packed, within `repack_share_percent` of the time then
//!    left. Captures run git with `gc.auto=0`, so nothing else packs a store
//!    that loses no refs, and loose objects take many times the space of a
//!    pack. `git repack -a -d -k`, without `-l`, writes every object of the
//!    store into one new pack, unreachable ones included, then deletes the
//!    old packs and the loose objects. It deletes no object the new pack
//!    lacks and prunes nothing, so an object a capture has written but not
//!    yet named stays. Only the stores packed are walked
//!    again. A pack that fails or finds a store locked leaves the store as
//!    measured, and eviction goes on from that measure.
//! 3. Whole sessions are evicted until the space is under the target, 4 of
//!    the 5 GiB, so maintenance does not run every turn:
//!    first sessions that no longer exist, then those captured longest ago.
//!    The current session and sessions another process has open are never
//!    evicted. A chain cannot drop single captures and keep later ones, so a
//!    session goes whole.
//! 4. Before a session's refs are deleted, each store they are in gets a
//!    `prune_marker` file unless it has one. Once the refs are gone, only
//!    those stores are pruned, which removes the marker, and only they are
//!    walked again. A store that kept every ref has nothing of this session
//!    to prune: the marker goes again only when this eviction wrote it, and
//!    one a stopped maintenance left stays until that store's prune
//!    finishes. No other store is pruned: pruning every store first could
//!    spend the whole deadline before anything is evicted.
//! 5. Each eviction is journaled in `captures/evictions.jsonl`, two synced
//!    lines per session, so a removal is never silent: `"phase":"intent"`
//!    with the refs found, before any ref is deleted, then `"phase":"done"`
//!    with the refs deleted and those `kept` because a capture moved them
//!    meanwhile. An intent without its done line is an eviction a crash
//!    stopped. A session that kept every ref is not reported as evicted.
//! 6. Eviction stops when a marker or journal line cannot be written, a
//!    store it deleted refs from cannot be pruned, or the space cannot be
//!    measured: the space would not be seen to drop, and evicting on would
//!    remove sessions the budget does not need gone.
//!
//! Packing and pruning run under every capture lock of the store: first the
//! store's `init.lock`, which a capture passes before it writes any object,
//! then each worktree's lock, in name order. No capture of the store is then
//! running, so every unreachable object goes at once. A grace period would
//! not do: git loosens objects from the pack the first prune wrote with that
//! pack's time, so an evicted session's objects would stay an hour and the
//! space would not drop. A capture takes its worktree lock before
//! `init.lock`, the opposite order, but both wait only until a deadline, so
//! neither waits forever; a store still locked at the deadline is left
//! unpacked or unpruned this time, and marked when it awaits a prune.
//!
//! A worktree's capture index names blobs a prune may remove, and git trusts
//! the index for files that did not change, so a pruned blob could end up in
//! a later tree. Maintenance deletes each index before pruning; the next
//! capture starts it again from the user's index.
//!
//! Captures stop while the space stays over the budget, and
//! `Admission.refusal` says why a capture was refused; nothing is deleted
//! beyond whole inactive sessions.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const capture_store = @import("capture_store.zig");

const Allocator = std.mem.Allocator;

pub const budget_bytes: u64 = 5 << 30;
/// Eviction stops under this, so the next maintenance waits for the space
/// to grow by the difference.
pub const target_bytes: u64 = 4 << 30;
pub const measure_interval_ms: i64 = 10 * std.time.ms_per_min;
/// Folder times this close to the clock are too recent to fingerprint: it
/// covers the coarsest file clock's tick, 2 s on FAT.
const racy_ms: i64 = 2 * std.time.ms_per_s;
/// A time in `usage` further ahead of the clock than this is no measure.
const future_ms: i64 = std.time.ms_per_day;
/// `usage` is no cache past this size.
const max_usage_bytes = 1 << 20;
/// Files count in whole blocks of this size.
const block_bytes: u64 = 4096;
/// Hex digits in a session or store key (`capture_store.sessionKey`).
const key_len = 32;
/// In a store's folder from before any of its refs is deleted until the
/// store is pruned.
pub const prune_marker = "prune.pending";
/// A store with this many loose objects is packed before any session is
/// evicted. Git's own `gc.auto` default is 6700; a capture writes a few
/// objects, so this is some hundreds of captures.
const repack_loose_objects: usize = 1024;
/// The share of the time left that finishing stopped prunes may take.
const prune_share_percent = 50;
/// The share of the time left after that which packing loose stores may
/// take; the rest is for eviction.
const repack_share_percent = 50;

/// What maintenance asks about the profile's sessions, by ref key
/// (`capture_store.sessionKey`).
pub const Sessions = struct {
    ctx: *anyopaque,
    /// Whether a session with this key still exists. When unsure, true.
    exists: *const fn (ctx: *anyopaque, key: []const u8) bool,
    /// Whether another process has the session open. When unsure, true.
    busy: *const fn (ctx: *anyopaque, key: []const u8) bool,

    /// Every session exists and is open, so nothing would be evicted; for
    /// `check`, which never asks.
    pub const unknown: Sessions = .{ .ctx = undefined, .exists = always, .busy = always };

    fn always(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

pub const Config = struct {
    profile_root: []const u8,
    /// The capturing session's key: never evicted.
    current_key: []const u8,
    sessions: Sessions,
    now_ms: i64,
    /// Bounds measuring and maintenance, every git run included.
    deadline: std.Io.Clock.Timestamp,
    budget: u64 = budget_bytes,
    target: u64 = target_bytes,
    /// A store with at least this many loose objects is packed before any
    /// session is evicted.
    repack_loose: usize = repack_loose_objects,
    /// Set to stop maintenance at its next step, such as when the process
    /// ends; a git run in flight is stopped by cancelling the task instead.
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const EvictionReason = enum { orphan, budget };

pub const Eviction = struct {
    key: []const u8,
    reason: EvictionReason,
    /// Refs deleted; a ref a capture moved meanwhile stays.
    refs: usize,
};

/// Why a capture was refused.
pub const Refusal = enum {
    /// Over the budget after maintenance, or with maintenance run within
    /// `measure_interval_ms`.
    over_budget,
    /// The captures folder could not be read, or not before the deadline.
    measure_failed,
    /// Over the budget while another process runs maintenance.
    busy,
    /// Over the budget, and git cannot run maintenance.
    git_refused,
    /// Over the budget, and maintenance could not start, or stopped on a
    /// marker, journal line, or prune that failed.
    maintenance_failed,
};

pub const Admission = struct {
    admit: bool,
    /// Null when admitted.
    refusal: ?Refusal = null,
    /// The space measured or read from `usage`; null when unknown.
    used: ?u64 = null,
    maintained: bool = false,
    evicted: []const Eviction = &.{},
    /// From `check` only: `admit` should run, off the turn. Set over the
    /// budget once maintenance is due, and when the measure ran out of
    /// time, so `admit`'s longer deadline measures and saves it.
    due: bool = false,
};

/// Whether a capture may write now, without maintenance: reads `usage` and
/// walks only the stores that changed, within `config.deadline`. Never asks
/// `config.sessions`. Memory belongs to `arena`.
pub fn check(arena: Allocator, config: Config) Allocator.Error!Admission {
    return switch (try measureNow(arena, config)) {
        .decided => |admission| admission,
        .due => |over| .{ .admit = false, .refusal = .over_budget, .used = over.usage.total, .due = true },
    };
}

/// Whether a capture may write now; runs maintenance when the space is over
/// the budget and maintenance is due. It can take until `config.deadline`,
/// so it never runs on a turn: `check` first. Memory belongs to `arena`.
pub fn admit(arena: Allocator, config: Config) Allocator.Error!Admission {
    return switch (try measureNow(arena, config)) {
        .decided => |admission| admission,
        .due => |over| maintain(arena, io_mod.getIo(), config, over.captures, over.usage_path, over.usage),
    };
}

/// What measuring decided: an admission, or the measure over the budget
/// with maintenance due.
const Measured = union(enum) {
    decided: Admission,
    due: struct { captures: []const u8, usage_path: []const u8, usage: Usage },
};

fn measureNow(arena: Allocator, config: Config) Allocator.Error!Measured {
    const io = io_mod.getIo();
    const captures = try std.Io.Dir.path.join(arena, &.{ config.profile_root, "captures" });
    if (!capture_store.exists(io, captures)) return .{ .decided = .{ .admit = true, .used = 0 } };
    const usage_path = try std.Io.Dir.path.join(arena, &.{ captures, "usage" });
    const cached = try readUsage(arena, io, usage_path, config.now_ms);
    const fresh = try refresh(arena, io, captures, cached, config.now_ms, config.deadline) orelse {
        const late = capture_store.pastDeadline(io, config.deadline);
        debug_trace.logf("workspace", "event=workspace_capture_measure_failed captures={s} deadline={}", .{ captures, late });
        return .{ .decided = .{ .admit = false, .refusal = .measure_failed, .due = late } };
    };
    var usage = fresh.usage;
    usage.maintained_ms = if (cached) |value| value.maintained_ms else 0;
    if (fresh.changed) writeUsage(arena, io, usage_path, usage, config.now_ms);
    if (usage.total <= config.budget) return .{ .decided = .{ .admit = true, .used = usage.total } };
    // Maintenance that could not get under the budget is not retried until
    // the interval has passed.
    if (maintainedWithin(config.now_ms, usage.maintained_ms)) return .{ .decided = .{ .admit = false, .refusal = .over_budget, .used = usage.total } };
    return .{ .due = .{ .captures = captures, .usage_path = usage_path, .usage = usage } };
}

fn maintainedWithin(now_ms: i64, maintained_ms: i64) bool {
    const since = now_ms -| maintained_ms;
    return since >= 0 and since < measure_interval_ms;
}

/// Why eviction stopped before the space was under the target.
const Stop = enum { deadline, cancelled, mark_failed, journal_failed, prune_failed, measure_failed };

/// Whether maintenance should stop before its next step: its deadline
/// passed or `config.cancel` is set.
fn halted(io: std.Io, config: Config) ?Stop {
    if (config.cancel) |flag| if (flag.load(.acquire)) return .cancelled;
    if (capture_store.pastDeadline(io, config.deadline)) return .deadline;
    return null;
}

/// Hands a cancel that a helper swallowed back to the task, so its next
/// step, such as a git run, sees it too. Without this, a cancel that lands
/// while maintenance reads a folder or a file is lost, and
/// `turn_capture.finishMaintenance` waits for it to reach its deadline.
fn keepCancel(io: std.Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

fn maintain(arena: Allocator, io: std.Io, config: Config, captures: []const u8, usage_path: []const u8, measured: Usage) Allocator.Error!Admission {
    // One maintenance per profile; another process's leaves this capture out.
    const lock_path = try std.Io.Dir.path.join(arena, &.{ captures, "maintenance.lock" });
    const lock = std.Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false, .read = true }) catch |err| {
        keepCancel(io, err);
        debug_trace.logf("workspace", "event=workspace_capture_maintenance_failed reason=lock_unavailable", .{});
        return .{ .admit = false, .refusal = .maintenance_failed, .used = measured.total };
    };
    defer lock.close(io);
    if (!(lock.tryLock(io, .exclusive) catch |err| refused: {
        keepCancel(io, err);
        break :refused false;
    })) return .{ .admit = false, .refusal = .busy, .used = measured.total };
    // The interval was decided on `usage` as read before the lock; another
    // process's maintenance may have finished since.
    if (try readUsage(arena, io, usage_path, config.now_ms)) |latest| {
        if (maintainedWithin(config.now_ms, latest.maintained_ms)) {
            const fits = latest.total <= config.budget;
            return .{ .admit = fits, .refusal = if (fits) null else .over_budget, .used = latest.total };
        }
    }

    const ready = switch (try safe_git.prepareStore(arena, .{ .deadline = config.deadline })) {
        .ready => |value| value,
        .refused => {
            debug_trace.logf("workspace", "event=workspace_capture_maintenance_failed reason=git_refused", .{});
            return .{ .admit = false, .refusal = .git_refused, .used = measured.total };
        },
    };
    const pass: Pass = .{
        .arena = arena,
        .io = io,
        .ready = ready,
        .stores = try capture_store.listStoreDirs(arena, io, captures),
        .journal = try std.Io.Dir.path.join(arena, &.{ captures, "evictions.jsonl" }),
        .now_ms = config.now_ms,
        .deadline = config.deadline,
        .cancel = config.cancel,
    };
    var usage = measured;
    var stopped: ?Stop = null;
    // What a stopped maintenance left, within its share of the time: the
    // rest is for packing and eviction.
    if (try pass.finishPrunes(partway(io, config.deadline, prune_share_percent))) {
        if (try refresh(arena, io, captures, usage, config.now_ms, config.deadline)) |fresh| usage = fresh.usage else stopped = .measure_failed;
    }
    // A pack frees space without losing a capture, so it comes before any
    // eviction. Only the stores packed are walked again.
    if (stopped == null) stopped = halted(io, config);
    if (stopped == null and usage.total > config.target) {
        if (try pass.packLoose(partway(io, config.deadline, repack_share_percent), config.repack_loose)) {
            if (try refresh(arena, io, captures, usage, config.now_ms, config.deadline)) |fresh| usage = fresh.usage else stopped = .measure_failed;
        }
    }

    var evicted: std.ArrayList(Eviction) = .empty;
    if (stopped == null) stopped = halted(io, config);
    if (stopped == null and usage.total > config.target) {
        const candidates = try inventory(arena, ready, pass.stores, config.current_key, .{ .deadline = config.deadline });
        // Sessions that no longer exist first, then the longest unused.
        for (candidates) |*candidate| candidate.orphan = !config.sessions.exists(config.sessions.ctx, candidate.key);
        sort_utils.sort(Candidate, candidates, {}, Candidate.before);
        for (candidates) |candidate| {
            if (usage.total <= config.target) break;
            if (halted(io, config)) |why| {
                stopped = why;
                break;
            }
            if (!candidate.orphan and config.sessions.busy(config.sessions.ctx, candidate.key)) continue;
            const result = try pass.evict(candidate);
            if (result.eviction) |eviction| try evicted.append(arena, eviction);
            stopped = result.stopped;
            if (stopped != null) break;
            // Only the stores the refs left were pruned, so only they are
            // walked again.
            usage = (try refresh(arena, io, captures, usage, config.now_ms, config.deadline) orelse {
                stopped = .measure_failed;
                break;
            }).usage;
        }
    }
    if (stopped) |why| debug_trace.logf("workspace", "event=workspace_capture_maintenance_stopped reason={s} used={d}", .{ @tagName(why), usage.total });
    // The last measure that succeeded. A cancelled maintenance keeps the
    // time of the one before, so the next capture can start it again.
    usage.maintained_ms = if (stopped == .cancelled) measured.maintained_ms else config.now_ms;
    writeUsage(arena, io, usage_path, usage, config.now_ms);
    const fits = usage.total <= config.budget;
    const refusal: ?Refusal = if (fits) null else if (stopped) |why| switch (why) {
        .deadline, .cancelled => .over_budget,
        .measure_failed => .measure_failed,
        .mark_failed, .journal_failed, .prune_failed => .maintenance_failed,
    } else .over_budget;
    return .{ .admit = fits, .refusal = refusal, .used = usage.total, .maintained = true, .evicted = evicted.items };
}

/// The time `percent` of the way from now to `deadline`.
fn partway(io: std.Io, deadline: std.Io.Clock.Timestamp, comptime percent: comptime_int) std.Io.Clock.Timestamp {
    comptime std.debug.assert(percent > 0 and percent <= 100);
    const now: std.Io.Clock.Timestamp = .now(io, deadline.clock);
    const left = now.durationTo(deadline);
    return now.addDuration(.{ .raw = .fromNanoseconds(@divTrunc(@max(left.raw.nanoseconds, 0) * percent, 100)), .clock = deadline.clock });
}

/// What one maintenance works on.
const Pass = struct {
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    /// Complete stores, in name order (`capture_store.listStoreDirs`).
    stores: []const []const u8,
    journal: []const u8,
    now_ms: i64,
    deadline: std.Io.Clock.Timestamp,
    cancel: ?*const std.atomic.Value(bool) = null,

    fn cancelled(pass: Pass) bool {
        const flag = pass.cancel orelse return false;
        return flag.load(.acquire);
    }

    /// Prunes the stores that carry `prune_marker`; whether any was.
    fn finishPrunes(pass: Pass, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
        var pruned = false;
        for (pass.stores) |store| {
            if (pass.cancelled()) break;
            if (!capture_store.exists(pass.io, try markerPath(pass.arena, store))) continue;
            if (try collect(pass.arena, pass.io, pass.ready, store, deadline)) pruned = true;
        }
        return pruned;
    }

    /// Packs each store with at least `threshold` loose objects, until
    /// `deadline`; whether any pack ran, even one that failed.
    fn packLoose(pass: Pass, deadline: std.Io.Clock.Timestamp, threshold: usize) Allocator.Error!bool {
        var ran = false;
        for (pass.stores) |store| {
            if (pass.cancelled() or capture_store.pastDeadline(pass.io, deadline)) break;
            if (try countLoose(pass.arena, pass.io, store, threshold) < threshold) continue;
            ran = true;
            _ = try pack(pass.arena, pass.io, pass.ready, store, deadline);
        }
        return ran;
    }

    const Evicted = struct {
        /// Null when no ref was deleted.
        eviction: ?Eviction = null,
        stopped: ?Stop = null,
    };

    /// Evicts one session: marks the stores its refs are in, journals the
    /// intent, deletes each ref that still names what the inventory saw,
    /// journals what the deletes did, and prunes the stores the refs left.
    fn evict(pass: Pass, candidate: Candidate) Allocator.Error!Evicted {
        const arena = pass.arena;
        const limits: safe_git.Limits = .{ .deadline = pass.deadline };
        var marked: std.ArrayList(usize) = .empty;
        for (candidate.refs.items) |ref| {
            if (std.mem.findScalar(usize, marked.items, ref.store) == null) try marked.append(arena, ref.store);
        }
        // Marked before the intent: a crash after it leaves at most a prune
        // the next maintenance does without need. A marker already there is
        // a prune a stopped maintenance still owes, and stays.
        var created: std.ArrayList(usize) = .empty;
        for (marked.items) |index| {
            switch (try mark(arena, pass.io, pass.stores[index])) {
                .created => try created.append(arena, index),
                .existed => {},
                .failed => return .{ .stopped = .mark_failed },
            }
        }
        const reason: EvictionReason = if (candidate.orphan) .orphan else .budget;
        const line: JournalLine = .{ .phase = .intent, .at_ms = pass.now_ms, .key = candidate.key, .reason = reason, .refs = candidate.refs.items.len };
        // The intent is recorded before any ref goes; a failed record stops
        // maintenance.
        appendJournal(arena, pass.io, pass.journal, line) catch |err| {
            keepCancel(pass.io, err);
            return .{ .stopped = .journal_failed };
        };
        var deleted: usize = 0;
        var left: std.ArrayList(usize) = .empty;
        for (candidate.refs.items) |ref| {
            switch (try capture_store.storeOutput(arena, pass.ready, try capture_store.refStore(arena, pass.stores[ref.store]), .{ .delete_ref = .{ .ref = ref.name, .old = ref.oid } }, limits)) {
                .ok => {
                    deleted += 1;
                    if (std.mem.findScalar(usize, left.items, ref.store) == null) try left.append(arena, ref.store);
                },
                .failed => |failure| debug_trace.logf("workspace", "event=workspace_capture_ref_kept ref={s} failure={s}", .{ ref.name, @tagName(failure) }),
            }
        }
        // What the deletes did: a ref a capture moved meanwhile stays.
        var done = line;
        done.phase = .done;
        done.refs = deleted;
        done.kept = candidate.refs.items.len - deleted;
        const recorded = if (appendJournal(arena, pass.io, pass.journal, done)) true else |err| unrecorded: {
            keepCancel(pass.io, err);
            break :unrecorded false;
        };
        var result: Evicted = .{};
        if (deleted > 0) {
            debug_trace.logf("workspace", "event=workspace_capture_evicted session_key={s} reason={s} refs={d}", .{ candidate.key, @tagName(reason), deleted });
            result.eviction = .{ .key = candidate.key, .reason = reason, .refs = deleted };
        }
        if (!recorded) {
            result.stopped = .journal_failed;
            return result;
        }
        // The space drops only once the stores the refs left are pruned and
        // measured; without that, eviction would go on past what the budget
        // needs. A store that kept every ref has nothing of this session to
        // prune; its marker goes only when this eviction wrote it.
        for (marked.items) |index| {
            const store = pass.stores[index];
            if (std.mem.findScalar(usize, left.items, index) == null) {
                if (std.mem.findScalar(usize, created.items, index) != null) {
                    std.Io.Dir.deleteFileAbsolute(pass.io, try markerPath(arena, store)) catch |err| keepCancel(pass.io, err);
                }
            } else if (!try collect(arena, pass.io, pass.ready, store, pass.deadline)) {
                result.stopped = .prune_failed;
                return result;
            }
        }
        return result;
    }
};

fn markerPath(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, prune_marker });
}

const Marked = enum { created, existed, failed };

/// Writes the store's `prune_marker` and syncs it, and says whether this
/// call created it.
fn mark(arena: Allocator, io: std.Io, store_dir: []const u8) Allocator.Error!Marked {
    const path = try markerPath(arena, store_dir);
    var result: Marked = .created;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
        error.PathAlreadyExists => existing: {
            result = .existed;
            break :existing std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) }) catch |existing_err| {
                keepCancel(io, existing_err);
                return .failed;
            };
        },
        else => {
            keepCancel(io, err);
            return .failed;
        },
    };
    defer file.close(io);
    file.sync(io) catch |err| {
        keepCancel(io, err);
        return .failed;
    };
    return result;
}

const Ref = struct { store: usize, name: []const u8, oid: []const u8 };

const Candidate = struct {
    key: []const u8,
    /// The newest capture's time across the session's refs.
    last: i64,
    orphan: bool = false,
    refs: std.ArrayList(Ref) = .empty,

    fn before(_: void, a: Candidate, b: Candidate) bool {
        if (a.orphan != b.orphan) return a.orphan;
        if (a.last != b.last) return a.last < b.last;
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

/// Every session with captures, but `current_key`'s, with its refs. A store
/// whose refs cannot be listed offers none.
fn inventory(arena: Allocator, ready: safe_git.StoreReady, stores: []const []const u8, current_key: []const u8, limits: safe_git.Limits) Allocator.Error![]Candidate {
    var by_key: std.StringArrayHashMapUnmanaged(Candidate) = .empty;
    for (stores, 0..) |store, index| {
        const listing = switch (try capture_store.storeOutput(arena, ready, try capture_store.refStore(arena, store), .list_refs, limits)) {
            .ok => |stdout| stdout,
            .failed => continue,
        };
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const parsed = parseRefLine(line) orelse continue;
            if (std.mem.eql(u8, parsed.key, current_key)) continue;
            const entry = try by_key.getOrPut(arena, parsed.key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .key = parsed.key, .last = parsed.seconds };
            entry.value_ptr.last = @max(entry.value_ptr.last, parsed.seconds);
            try entry.value_ptr.refs.append(arena, .{ .store = index, .name = parsed.name, .oid = parsed.oid });
        }
    }
    return by_key.values();
}

const RefLine = struct { name: []const u8, key: []const u8, oid: []const u8, seconds: i64 };

/// `refs/fx/sessions/<key>/<worktree> <object> <seconds>`; null for anything
/// else.
fn parseRefLine(line: []const u8) ?RefLine {
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
    if (segments.next() != null or !isKey(key) or !isKey(worktree)) return null;
    if (!safe_git.isOid(oid, .sha1) and !safe_git.isOid(oid, .sha256)) return null;
    return .{ .name = name, .key = key, .oid = oid, .seconds = seconds };
}

fn isKey(text: []const u8) bool {
    return isLowerHex(text, key_len);
}

fn isLowerHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Packs and prunes one store under all its capture locks, with the capture
/// indexes deleted first, and removes its `prune_marker`. False when a lock
/// stayed held or git failed; the store is then left unpruned.
fn collect(arena: Allocator, io: std.Io, ready: safe_git.StoreReady, store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
    var locks: std.ArrayList(std.Io.File) = .empty;
    defer for (locks.items) |file| file.close(io);
    const names = try lockStore(arena, io, &locks, store_dir, deadline) orelse return false;
    // No capture writes an object from here until the locks go, so the
    // prune takes only objects older than this.
    const locked_unix_seconds = @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s);
    const worktrees = try capture_store.worktreesDir(arena, store_dir);
    for (names) |name| {
        const index = try std.Io.Dir.path.join(arena, &.{ worktrees, name, capture_store.worktree_index_name });
        std.Io.Dir.deleteFileAbsolute(io, index) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                keepCancel(io, err);
                return false;
            },
        };
    }
    switch (try capture_store.storeOutput(arena, ready, try capture_store.refStore(arena, store_dir), gcCommand(locked_unix_seconds), .{ .deadline = deadline })) {
        .ok => {
            // A marker left behind only costs the next maintenance a prune.
            std.Io.Dir.deleteFileAbsolute(io, try markerPath(arena, store_dir)) catch |err| keepCancel(io, err);
            return true;
        },
        .failed => |failure| {
            debug_trace.logf("workspace", "event=workspace_capture_gc_failed store={s} failure={s}", .{ store_dir, @tagName(failure) });
            return false;
        },
    }
}

/// The store command that packs and prunes, pruning only unreachable
/// objects older than `locked_unix_seconds`, when maintenance took the
/// store's every capture lock. A prune still running after fx dies, its locks
/// gone, then never deletes an object a new capture wrote.
fn gcCommand(locked_unix_seconds: i64) safe_git.StoreCommand {
    return .{ .gc_locked = .{ .locked_unix = locked_unix_seconds } };
}

/// Packs one store's loose objects under all its capture locks; deletes no
/// object a pack does not hold and prunes nothing. False when a lock stayed
/// held or git failed.
fn pack(arena: Allocator, io: std.Io, ready: safe_git.StoreReady, store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
    var locks: std.ArrayList(std.Io.File) = .empty;
    defer for (locks.items) |file| file.close(io);
    _ = try lockStore(arena, io, &locks, store_dir, deadline) orelse return false;
    switch (try capture_store.storeOutput(arena, ready, try capture_store.refStore(arena, store_dir), .repack, .{ .deadline = deadline })) {
        .ok => return true,
        .failed => |failure| {
            debug_trace.logf("workspace", "event=workspace_capture_repack_failed store={s} failure={s}", .{ store_dir, @tagName(failure) });
            return false;
        },
    }
}

/// Takes every capture lock of the store, waiting until `deadline`: its
/// `init.lock`, then each worktree's lock in name order. The files join
/// `locks`, which the caller closes. The worktree names, or null when a lock
/// stayed held.
fn lockStore(arena: Allocator, io: std.Io, locks: *std.ArrayList(std.Io.File), store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!?[]const []const u8 {
    // `init.lock` first: a capture that has not passed it has written
    // nothing, and the worktrees listed after it are all there are.
    if (!try lockFile(arena, io, locks, try capture_store.initLockPath(arena, store_dir), store_dir, deadline)) return null;
    const worktrees = try capture_store.worktreesDir(arena, store_dir);
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.openDirAbsolute(io, worktrees, .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch |err| listed: {
            keepCancel(io, err);
            break :listed null;
        }) |entry| {
            if (entry.kind == .directory) try names.append(arena, try arena.dupe(u8, entry.name));
        }
    } else |err| keepCancel(io, err);
    // One order for every maintenance, so two never wait on each other.
    sort_utils.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        if (!try lockFile(arena, io, locks, try std.Io.Dir.path.join(arena, &.{ worktrees, name, capture_store.worktree_lock_name }), store_dir, deadline)) return null;
    }
    return names.items;
}

/// The store's loose objects, the files in its `objects/??` folders,
/// counted up to `limit`; a folder that cannot be read counts none.
fn countLoose(arena: Allocator, io: std.Io, store_dir: []const u8, limit: usize) Allocator.Error!usize {
    const objects = try std.Io.Dir.path.join(arena, &.{ try capture_store.storeGitDir(arena, store_dir), "objects" });
    var dir = std.Io.Dir.openDirAbsolute(io, objects, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return 0;
    };
    defer dir.close(io);
    var count: usize = 0;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        return count;
    }) |entry| {
        if (entry.kind != .directory or !isLowerHex(entry.name, 2)) continue;
        var fan_out = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
            keepCancel(io, err);
            continue;
        };
        defer fan_out.close(io);
        var files = fan_out.iterate();
        while (files.next(io) catch |err| listed: {
            keepCancel(io, err);
            break :listed null;
        }) |file| {
            if (file.kind != .file) continue;
            count += 1;
            if (count >= limit) return count;
        }
    }
    return count;
}

/// Takes an exclusive lock on `path`, waiting until `deadline`; the file
/// joins `locks`, which the caller closes.
fn lockFile(arena: Allocator, io: std.Io, locks: *std.ArrayList(std.Io.File), path: []const u8, store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
    const lock = capture_store.acquireLock(io, path, deadline) catch |err| {
        keepCancel(io, err);
        if (err == error.Busy) debug_trace.logf("workspace", "event=workspace_capture_store_busy store={s}", .{store_dir});
        return false;
    };
    locks.append(arena, lock.file) catch |err| {
        lock.file.close(io);
        return err;
    };
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One store's measure in `usage`.
const StoreUsage = struct {
    name: []const u8,
    bytes: u64,
    at_ms: i64,
    fingerprint: u64,

    fn before(_: void, a: StoreUsage, b: StoreUsage) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const Usage = struct {
    /// The stores and the files beside them.
    total: u64,
    /// When maintenance last ran; 0 when it never did.
    maintained_ms: i64 = 0,
    /// In name order.
    stores: []const StoreUsage,
};

const Refreshed = struct {
    usage: Usage,
    /// Whether `usage` differs from the cache it started from.
    changed: bool,
};

/// The space the captures folder takes now. A store whose measure in
/// `cached` still holds keeps it; the others are walked. Null when a walk
/// fails or the deadline passes. Memory belongs to `arena`.
fn refresh(arena: Allocator, io: std.Io, captures: []const u8, cached: ?Usage, now_ms: i64, deadline: std.Io.Clock.Timestamp) Allocator.Error!?Refreshed {
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return null;
    };
    defer dir.close(io);
    var stores: std.ArrayList(StoreUsage) = .empty;
    var beside: u64 = 0;
    var walked = false;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        return null;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                    keepCancel(io, err);
                    continue;
                };
                beside +|= std.mem.alignForward(u64, stat.size, block_bytes);
                continue;
            },
            .directory => {},
            else => continue,
        }
        const path = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        if (!isKey(entry.name)) {
            beside +|= measure(arena, io, path, deadline) orelse return null;
            continue;
        }
        const fingerprint = try fingerprintStore(arena, io, path);
        if (reusable(cached, entry.name, fingerprint, now_ms)) |kept| {
            try stores.append(arena, kept);
            continue;
        }
        walked = true;
        try stores.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .bytes = measure(arena, io, path, deadline) orelse return null,
            .at_ms = now_ms,
            .fingerprint = fingerprint,
        });
    }
    sort_utils.sort(StoreUsage, stores.items, {}, StoreUsage.before);
    var total = beside;
    for (stores.items) |store| total +|= store.bytes;
    const changed = if (cached) |value| walked or value.stores.len != stores.items.len or value.total != total else true;
    return .{ .usage = .{ .total = total, .stores = stores.items }, .changed = changed };
}

/// The store's measure in `cached` when its objects have not changed since
/// and it is younger than `measure_interval_ms`.
fn reusable(cached: ?Usage, name: []const u8, fingerprint: u64, now_ms: i64) ?StoreUsage {
    if (fingerprint == 0) return null;
    const usage = cached orelse return null;
    for (usage.stores) |store| {
        if (!std.mem.eql(u8, store.name, name)) continue;
        const age = now_ms -| store.at_ms;
        if (store.fingerprint != fingerprint or age < 0 or age >= measure_interval_ms) return null;
        return store;
    }
    return null;
}

/// A hash of the times of the store's object folders: the objects folder
/// and each folder in it. Zero when they cannot be read or one changed
/// within `racy_ms`, so the store is walked next time too.
fn fingerprintStore(arena: Allocator, io: std.Io, store_dir: []const u8) Allocator.Error!u64 {
    const objects = try std.Io.Dir.path.join(arena, &.{ try capture_store.storeGitDir(arena, store_dir), "objects" });
    // The clock first: a write after it shows as racy.
    const now_ns = io_mod.nanoTimestamp();
    var dir = std.Io.Dir.openDirAbsolute(io, objects, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return 0;
    };
    defer dir.close(io);
    var newest: i128 = (dir.stat(io) catch |err| {
        keepCancel(io, err);
        return 0;
    }).mtime.nanoseconds;
    var sum = folderHash("", newest);
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        keepCancel(io, err);
        return 0;
    }) |entry| {
        if (entry.kind != .directory) continue;
        const mtime: i128 = (dir.statFile(io, entry.name, .{}) catch |err| {
            keepCancel(io, err);
            return 0;
        }).mtime.nanoseconds;
        sum +%= folderHash(entry.name, mtime);
        newest = @max(newest, mtime);
    }
    if (newest >= now_ns - racy_ms * std.time.ns_per_ms) return 0;
    return @max(sum, 1);
}

fn folderHash(name: []const u8, mtime: i128) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    hasher.update(std.mem.asBytes(&mtime));
    return hasher.final();
}

/// Bytes the folder's files take, each rounded up to `block_bytes`; null
/// when the folder cannot be read or the deadline passes.
fn measure(arena: Allocator, io: std.Io, root: []const u8, deadline: std.Io.Clock.Timestamp) ?u64 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| {
        keepCancel(io, err);
        return null;
    };
    defer dir.close(io);
    var walker = dir.walk(arena) catch return null;
    defer walker.deinit();
    var total: u64 = 0;
    var seen: usize = 0;
    while (walker.next(io) catch |err| {
        keepCancel(io, err);
        return null;
    }) |entry| {
        seen += 1;
        if (seen % 1024 == 0 and capture_store.pastDeadline(io, deadline)) return null;
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| {
            keepCancel(io, err);
            continue;
        };
        total +|= std.mem.alignForward(u64, stat.size, block_bytes);
    }
    return total;
}

/// `captures/usage`. Null when missing, not a regular file, a symlink, too
/// large, or in any other format. A FIFO is opened without blocking and
/// never read.
fn readUsage(arena: Allocator, io: std.Io, path: []const u8, now_ms: i64) Allocator.Error!?Usage {
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .no_follow) catch |err| {
        keepCancel(io, err);
        return null;
    };
    defer file.close(io);
    const text = io_mod.readFileToEnd(arena, &file, max_usage_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            keepCancel(io, err);
            return null;
        },
    };
    return parseUsage(arena, text, now_ms);
}

/// The text `formatUsage` writes; null for anything else, such as stores
/// out of order, bytes that add up to more than the total, or a time that
/// is negative or more than `future_ms` after `now_ms`.
fn parseUsage(arena: Allocator, text: []const u8, now_ms: i64) Allocator.Error!?Usage {
    if (text.len == 0 or text[text.len - 1] != '\n') return null;
    const latest = now_ms +| future_ms;
    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    var header = std.mem.splitScalar(u8, lines.first(), ' ');
    if (!std.mem.eql(u8, header.first(), "v2")) return null;
    const total = std.fmt.parseInt(u64, header.next() orelse return null, 10) catch return null;
    const maintained_ms = parseTime(header.next() orelse return null, latest) orelse return null;
    if (header.next() != null) return null;
    var stores: std.ArrayList(StoreUsage) = .empty;
    var sum: u64 = 0;
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const name = fields.first();
        if (!isKey(name)) return null;
        if (stores.items.len > 0 and std.mem.order(u8, stores.items[stores.items.len - 1].name, name) != .lt) return null;
        const bytes = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        const at_ms = parseTime(fields.next() orelse return null, latest) orelse return null;
        const fingerprint_text = fields.next() orelse return null;
        if (!isLowerHex(fingerprint_text, 16)) return null;
        const fingerprint = std.fmt.parseInt(u64, fingerprint_text, 16) catch return null;
        if (fields.next() != null) return null;
        sum = std.math.add(u64, sum, bytes) catch return null;
        try stores.append(arena, .{ .name = name, .bytes = bytes, .at_ms = at_ms, .fingerprint = fingerprint });
    }
    if (sum > total) return null;
    return .{ .total = total, .maintained_ms = maintained_ms, .stores = stores.items };
}

/// A unix time in milliseconds from 0 to `latest`.
fn parseTime(text: []const u8, latest: i64) ?i64 {
    const value = std.fmt.parseInt(i64, text, 10) catch return null;
    if (value < 0 or value > latest) return null;
    return value;
}

fn formatUsage(arena: Allocator, usage: Usage) Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.print(arena, "v2 {d} {d}\n", .{ usage.total, usage.maintained_ms });
    for (usage.stores) |store| try text.print(arena, "{s} {d} {d} {x:0>16}\n", .{ store.name, store.bytes, store.at_ms, store.fingerprint });
    return text.items;
}

/// Replaces `usage` through a temporary file; a failure only means the next
/// capture walks the stores again. The maintenance time written is never
/// older than the file's: an admit that read `usage` before another
/// process's maintenance wrote it must not bring the old time back.
fn writeUsage(arena: Allocator, io: std.Io, path: []const u8, usage: Usage, now_ms: i64) void {
    var latest = usage;
    if (readUsage(arena, io, path, now_ms) catch null) |disk| latest.maintained_ms = @max(latest.maintained_ms, disk.maintained_ms);
    const text = formatUsage(arena, latest) catch return;
    const temporary = arena.print("{s}.tmp-{d}", .{ path, io_mod.nanoTimestamp() }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = text, .flags = .{ .permissions = .fromMode(0o600) } }) catch |err| {
        keepCancel(io, err);
        return;
    };
    std.Io.Dir.renameAbsolute(temporary, path, io) catch |err| {
        keepCancel(io, err);
        // Cleared even once cancelled; the cancel stays for the next step.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    };
}

/// One line of `evictions.jsonl`. The intent's `refs` are the refs found;
/// the done line's are the refs deleted, and `kept` those a capture moved.
const JournalLine = struct {
    phase: enum { intent, done },
    at_ms: i64,
    key: []const u8,
    reason: EvictionReason,
    refs: usize,
    kept: usize = 0,
};

/// Appends one line to the journal and syncs it.
fn appendJournal(arena: Allocator, io: std.Io, path: []const u8, entry: JournalLine) !void {
    const head = try arena.print("{{\"v\":1,\"phase\":\"{s}\",\"at_ms\":{d},\"session_key\":\"{s}\",\"reason\":\"{s}\",\"refs\":{d}", .{ @tagName(entry.phase), entry.at_ms, entry.key, @tagName(entry.reason), entry.refs });
    const line = switch (entry.phase) {
        .intent => try arena.print("{s}}}\n", .{head}),
        .done => try arena.print("{s},\"kept\":{d}}}\n", .{ head, entry.kept }),
    };
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    const end = (try file.stat(io)).size;
    try file.writePositionalAll(io, line, end);
    try file.sync(io);
}

test "capture retention reads only well-formed capture refs" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const key = "00112233445566778899aabbccddeeff";
    const wt = "ffeeddccbbaa99887766554433221100";
    const good = try std.testing.allocator.print("refs/fx/sessions/{s}/{s} {s} 1700000000", .{ key, wt, oid });
    defer std.testing.allocator.free(good);
    const parsed = parseRefLine(good).?;
    try std.testing.expectEqualStrings(key, parsed.key);
    try std.testing.expectEqualStrings(oid, parsed.oid);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), parsed.seconds);
    for ([_][]const u8{
        "",
        "refs/heads/main " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ " " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ "/x " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " nothex 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " soon",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " 1 extra",
        "refs/fx/sessions/ABCDEF33445566778899aabbccddeeff/" ++ wt ++ " " ++ oid ++ " 1",
    }) |line| try std.testing.expect(parseRefLine(line) == null);
}

test "capture retention evicts orphans first, then the longest unused, ties by key" {
    var items = [_]Candidate{
        .{ .key = "b", .last = 10 },
        .{ .key = "a", .last = 10 },
        .{ .key = "c", .last = 5 },
        .{ .key = "d", .last = 99, .orphan = true },
    };
    sort_utils.sort(Candidate, &items, {}, Candidate.before);
    const expected = [_][]const u8{ "d", "c", "a", "b" };
    for (expected, items) |key, item| try std.testing.expectEqualStrings(key, item.key);
}

test "capture retention takes no negative or far future time from usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now: i64 = 1_800_000_000_000;
    const store = "00112233445566778899aabbccddeeff";
    for ([_][]const u8{
        "v2 9999999999 -9223372036854775808\n",
        "v2 9999999999 -1\n",
        "v2 9999999999 9223372036854775807\n",
        "v2 1 0\n" ++ store ++ " 1 -9223372036854775808 0123456789abcdef\n",
        "v2 1 0\n" ++ store ++ " 1 -1 0123456789abcdef\n",
        "v2 1 0\n" ++ store ++ " 1 9223372036854775807 0123456789abcdef\n",
    }) |text| try std.testing.expect((try parseUsage(arena, text, now)) == null);
    // Up to `future_ms` ahead stays a measure: a clock a little behind
    // another process's does not throw the cache away.
    const ahead = try arena.print("v2 1 {d}\n{s} 1 {d} 0123456789abcdef\n", .{ now + future_ms, store, now + future_ms });
    const usage = (try parseUsage(arena, ahead, now)).?;
    try std.testing.expectEqual(now + future_ms, usage.maintained_ms);
    try std.testing.expect((try parseUsage(arena, "v2 1 1\n", std.math.maxInt(i64))) != null);
    // Ages saturate, whatever a caller passes.
    try std.testing.expect(!maintainedWithin(std.math.maxInt(i64), std.math.minInt(i64)));
    try std.testing.expect(!maintainedWithin(std.math.minInt(i64), std.math.maxInt(i64)));
    const stores = [_]StoreUsage{.{ .name = store, .bytes = 1, .at_ms = std.math.minInt(i64), .fingerprint = 1 }};
    try std.testing.expect(reusable(.{ .total = 1, .stores = &stores }, store, 1, std.math.maxInt(i64)) == null);
}

/// A profile whose captures folder holds no store, only `filler_bytes` of
/// files beside the stores, so `admit` runs without git stores.
const TestProfile = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    captures: []const u8,
    usage: []const u8,

    const filler_bytes = 8 * block_bytes;

    fn init(arena: Allocator) !TestProfile {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "captures");
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "captures/filler", .data = &@as([filler_bytes]u8, @splat('x')) });
        const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
        const captures = try std.Io.Dir.path.join(arena, &.{ root, "captures" });
        return .{ .tmp = tmp, .root = root, .captures = captures, .usage = try std.Io.Dir.path.join(arena, &.{ captures, "usage" }) };
    }

    fn deinit(self: *TestProfile) void {
        self.tmp.cleanup();
    }

    fn config(self: TestProfile, budget: u64) Config {
        return .{
            .profile_root = self.root,
            .current_key = "00112233445566778899aabbccddeeff",
            .sessions = .{ .ctx = undefined, .exists = yes, .busy = yes },
            .now_ms = io_mod.milliTimestamp(),
            .deadline = .fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(10_000) }),
            .budget = budget,
            .target = budget,
        };
    }

    fn yes(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};

test "capture retention: a second maintainer with a stale usage neither maintains again nor brings back the old time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile = try TestProfile.init(arena);
    defer profile.deinit();
    const io = std.testing.io;

    // Both processes measured before either maintained: the copy B holds.
    const config = profile.config(1);
    const stale: Usage = .{ .total = TestProfile.filler_bytes, .maintained_ms = 0, .stores = &.{} };
    // A runs maintenance first and records its time.
    const first = try admit(arena, config);
    try std.testing.expect(first.maintained);
    const maintained_ms = (try readUsage(arena, io, profile.usage, config.now_ms)).?.maintained_ms;
    try std.testing.expectEqual(config.now_ms, maintained_ms);

    // B reaches the lock after A released it: the interval A started holds.
    const second = try maintain(arena, io, config, profile.captures, profile.usage, stale);
    try std.testing.expect(!second.maintained);
    try std.testing.expectEqual(@as(?Refusal, .over_budget), second.refusal);
    // B's write outside the lock keeps A's time.
    writeUsage(arena, io, profile.usage, stale, config.now_ms);
    try std.testing.expectEqual(maintained_ms, (try readUsage(arena, io, profile.usage, config.now_ms)).?.maintained_ms);
    // So the next admit, in any process, waits the interval too.
    const third = try admit(arena, profile.config(1));
    try std.testing.expect(!third.maintained);
    try std.testing.expectEqual(@as(?Refusal, .over_budget), third.refusal);
}

test "capture retention: check never maintains, and a cancelled maintenance records no time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile = try TestProfile.init(arena);
    defer profile.deinit();
    const io = std.testing.io;

    // Over the budget, `check` refuses with maintenance due, and runs none.
    const checked = try check(arena, profile.config(1));
    try std.testing.expect(!checked.admit);
    try std.testing.expect(checked.due);
    try std.testing.expect(!checked.maintained);
    try std.testing.expectEqual(@as(?Refusal, .over_budget), checked.refusal);
    try std.testing.expectEqual(@as(i64, 0), (try readUsage(arena, io, profile.usage, io_mod.milliTimestamp())).?.maintained_ms);

    // A maintenance cancelled before its first step stops there and keeps
    // the earlier time, so maintenance is still due.
    var cancel: std.atomic.Value(bool) = .init(true);
    var cancelled_config = profile.config(1);
    cancelled_config.cancel = &cancel;
    const cancelled = try admit(arena, cancelled_config);
    try std.testing.expect(cancelled.maintained);
    try std.testing.expect(!cancelled.admit);
    try std.testing.expectEqual(@as(i64, 0), (try readUsage(arena, io, profile.usage, io_mod.milliTimestamp())).?.maintained_ms);
    try std.testing.expect((try check(arena, profile.config(1))).due);

    // One that runs records its time: within the interval, `check` refuses
    // without asking for another.
    const ran = try admit(arena, profile.config(1));
    try std.testing.expect(ran.maintained);
    const after = try check(arena, profile.config(1));
    try std.testing.expect(!after.due);
    try std.testing.expectEqual(@as(?Refusal, .over_budget), after.refusal);
    // Under the budget, `check` admits.
    try std.testing.expect((try check(arena, profile.config(budget_bytes))).admit);
}

test "capture retention: a usage file with times out of range is no cache and nothing overflows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile = try TestProfile.init(arena);
    defer profile.deinit();
    const io = std.testing.io;
    // A folder with a store's name and settled object folders, so its line
    // in `usage` is looked at.
    const name = "00112233445566778899aabbccddeeff";
    try profile.tmp.dir.createDirPath(io, "captures/" ++ name ++ "/store.git/objects/pack");
    const old: std.Io.Timestamp = .{ .nanoseconds = @as(i96, io_mod.milliTimestamp() - 60 * std.time.ms_per_s) * std.time.ns_per_ms };
    for ([_][]const u8{ "captures/" ++ name ++ "/store.git/objects", "captures/" ++ name ++ "/store.git/objects/pack" }) |path| {
        try profile.tmp.dir.setTimestamps(io, path, .{ .modify_timestamp = .{ .new = old } });
    }
    const fingerprint = try fingerprintStore(arena, io, try std.Io.Dir.path.join(arena, &.{ profile.captures, name }));
    try std.testing.expect(fingerprint != 0);

    for ([_][]const u8{
        "v2 9999999999 -9223372036854775808\n",
        try arena.print("v2 9999999999 0\n{s} 1 -9223372036854775808 {x:0>16}\n", .{ name, fingerprint }),
        try arena.print("v2 9999999999 0\n{s} 1 9223372036854775807 {x:0>16}\n", .{ name, fingerprint }),
    }) |text| {
        try profile.tmp.dir.writeFile(io, .{ .sub_path = "captures/usage", .data = text });
        // Over the budget, so the maintenance time is looked at too.
        const admission = try admit(arena, profile.config(1));
        try std.testing.expect(admission.maintained);
        try std.testing.expect(admission.used.? >= TestProfile.filler_bytes);
    }
}

test "capture retention: a FIFO at captures/usage is no cache and does not block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile = try TestProfile.init(arena);
    defer profile.deinit();
    const made = std.process.run(arena, std.testing.io, .{ .argv = &.{ "mkfifo", profile.usage } }) catch return error.SkipZigTest;
    switch (made.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
    try std.testing.expect((try readUsage(arena, std.testing.io, profile.usage, io_mod.milliTimestamp())) == null);
    const admission = try admit(arena, profile.config(budget_bytes));
    try std.testing.expect(admission.admit);
    try std.testing.expect(admission.used.? >= TestProfile.filler_bytes);
}

/// A maintenance task cancelled while one of its helpers reads a folder or
/// a file: it waits, shielded from the cancel, until `go`, runs the helper,
/// which meets the cancel, then stands in for the next git run with a 10 s
/// sleep that only a cancel ends early.
const CancelInHelper = struct {
    const Helper = enum { refresh, count_loose, measure, read_usage };

    profile: *const TestProfile,
    store: []const u8,
    go: std.atomic.Value(bool) = .init(false),
    saw_cancel: bool = false,

    fn run(self: *CancelInHelper, helper: Helper) void {
        const io = std.testing.io;
        {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            while (!self.go.load(.acquire)) io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(10_000) });
        switch (helper) {
            .refresh => _ = refresh(arena, io, self.profile.captures, null, io_mod.milliTimestamp(), deadline) catch {},
            .count_loose => _ = countLoose(arena, io, self.store, 100) catch {},
            .measure => _ = measure(arena, io, self.store, deadline),
            .read_usage => _ = readUsage(arena, io, self.profile.usage, io_mod.milliTimestamp()) catch {},
        }
        io.sleep(.fromSeconds(10), .awake) catch |err| switch (err) {
            error.Canceled => self.saw_cancel = true,
        };
    }

    fn release(self: *CancelInHelper) void {
        io_mod.sleep(100 * std.time.ns_per_ms);
        self.go.store(true, .release);
    }
};

test "capture retention: a cancel that lands in a helper still reaches maintenance's next step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile = try TestProfile.init(arena);
    defer profile.deinit();
    const io = std.testing.io;
    const name = "00112233445566778899aabbccddeeff";
    try profile.tmp.dir.createDirPath(io, "captures/" ++ name ++ "/store.git/objects/ab");
    try profile.tmp.dir.writeFile(io, .{ .sub_path = "captures/" ++ name ++ "/store.git/objects/ab/cdef", .data = "x" });
    try profile.tmp.dir.writeFile(io, .{ .sub_path = "captures/usage", .data = "v2 0 0\n" });
    const store = try std.Io.Dir.path.join(arena, &.{ profile.captures, name });
    for ([_]CancelInHelper.Helper{ .refresh, .count_loose, .measure, .read_usage }) |helper| {
        var task: CancelInHelper = .{ .profile = &profile, .store = store };
        var future = try io.concurrent(CancelInHelper.run, .{ &task, helper });
        const releaser = try std.Thread.spawn(.{}, CancelInHelper.release, .{&task});
        const began = io_mod.milliTimestamp();
        // As `turn_capture.finishMaintenance` cancels one past its grace.
        future.cancel(io);
        releaser.join();
        try std.testing.expect(task.saw_cancel);
        try std.testing.expect(io_mod.milliTimestamp() - began < 2000);
    }
}

test "capture retention reads back every ref line and usage it accepts on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzParse, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100 0123456789abcdef0123456789abcdef01234567 1700000000",
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef -0_1",
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100/x 0123456789abcdef0123456789abcdef01234567 1",
            "refs/fx/sessions/0011/ffee 0123 +1",
            "v2 5368709120 0\n00112233445566778899aabbccddeeff 4096 1700000000000 0123456789abcdef\nffeeddccbbaa99887766554433221100 8192 1700000000001 0000000000000000\n",
            "v2 +1_0 -7\n00112233445566778899aabbccddeeff 1_0 -0 ffffffffffffffff\n",
            "v2 1 0\n00112233445566778899aabbccddeeff 4096 1 0123456789abcdef\n",
            "v2 9000 0\nffeeddccbbaa99887766554433221100 1 1 0123456789abcdef\n00112233445566778899aabbccddeeff 1 1 0123456789abcdef\n",
            "v2 0 0\n",
            "v2 9999999999 -9223372036854775808\n",
            "v2 9999999999 9223372036854775807\n",
            "v2 1 0\n00112233445566778899aabbccddeeff 1 -9223372036854775808 0123456789abcdef\n",
            "v2 1 0\n00112233445566778899aabbccddeeff 1 9223372036854775807 0123456789abcdef\n",
            "v2 1 1800086400000\n",
            "5368709120 1700000000000\n",
            "v2 1 2 3\n",
            " ",
        }) ++ @import("fuzz_corpus").capture_retention_parse.*),
    });
}

/// The clock `fuzzParse` reads usage against.
const fuzz_now_ms: i64 = 1_800_000_000_000;

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [1024]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    // An accepted ref line written back the way git lists it reads the same.
    if (parseRefLine(bytes)) |parsed| {
        try std.testing.expect(std.mem.startsWith(u8, parsed.name, "refs/fx/sessions/"));
        try std.testing.expectEqualStrings(parsed.key, parsed.name["refs/fx/sessions/".len..][0..key_len]);
        const again = try alloc.print("{s} {s} {d}", .{ parsed.name, parsed.oid, parsed.seconds });
        defer alloc.free(again);
        const reparsed = parseRefLine(again) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(parsed.name, reparsed.name);
        try std.testing.expectEqualStrings(parsed.key, reparsed.key);
        try std.testing.expectEqualStrings(parsed.oid, reparsed.oid);
        try std.testing.expectEqual(parsed.seconds, reparsed.seconds);
    }
    // So does an accepted usage written back the way `writeUsage` writes it,
    // and every time in it is one an age can be taken from.
    if (try parseUsage(arena, bytes, fuzz_now_ms)) |usage| {
        var sum: u64 = 0;
        for (usage.stores) |store| {
            sum += store.bytes;
            try std.testing.expect(store.at_ms >= 0 and store.at_ms <= fuzz_now_ms + future_ms);
            _ = reusable(usage, store.name, store.fingerprint, fuzz_now_ms);
        }
        try std.testing.expect(sum <= usage.total);
        try std.testing.expect(usage.maintained_ms >= 0 and usage.maintained_ms <= fuzz_now_ms + future_ms);
        _ = maintainedWithin(fuzz_now_ms, usage.maintained_ms);
        const again = try formatUsage(arena, usage);
        const reparsed = (try parseUsage(arena, again, fuzz_now_ms)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(usage.total, reparsed.total);
        try std.testing.expectEqual(usage.maintained_ms, reparsed.maintained_ms);
        try std.testing.expectEqual(usage.stores.len, reparsed.stores.len);
        for (usage.stores, reparsed.stores) |a, b| {
            try std.testing.expectEqualStrings(a.name, b.name);
            try std.testing.expectEqual(a.bytes, b.bytes);
            try std.testing.expectEqual(a.at_ms, b.at_ms);
            try std.testing.expectEqual(a.fingerprint, b.fingerprint);
        }
        try std.testing.expectEqualStrings(again, try formatUsage(arena, reparsed));
    }
}
