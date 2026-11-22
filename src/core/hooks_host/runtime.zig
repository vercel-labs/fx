//! fx's hooks runtime for one process: the loaded hook files, reloaded when
//! they change, and the one call every fx event makes.

const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const loader = @import("loader.zig");
const NativeHost = @import("native.zig").NativeHost;
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const trust = @import("trust.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const process = @import("process.zig");
const live_groups = @import("live_groups.zig");
const test_signal = @import("test_signal.zig");

pub const Options = struct {
    /// The `experimental.hooks` setting. When false, fx reads no hook file and only builtins run.
    enabled: bool,
    home: ?[]const u8,
    workspace_root: []const u8,
    /// fx's own in-process handlers. Borrowed; they must outlive the runtime.
    builtins: []const hooks.Builtin = &.{},
};

/// Counts for notices, `fx hook list`, and `fx status`.
pub const Summary = struct { hooks: usize = 0, pending: usize = 0, problems: usize = 0, disabled: usize = 0 };

/// What a surface knows about a session when it starts; copied by the runtime.
pub const SessionInfo = struct {
    session_id: []const u8,
    surface: hooks.Surface,
    cwd: []const u8,
    permission_mode: []const u8,
    /// Whether this surface's hooks must be trusted before they run.
    trust_required: bool,
};

/// A session that started in this process and has not ended. Its strings and context are owned.
const SessionEntry = struct {
    info: SessionInfo,
    /// The start context, already cut to the text limit.
    context: ?[]u8 = null,
    /// The waiting-hook count the person was last told about in this session. Changes only under `mutex`.
    trust_notice_count: usize = 0,
};

/// A note for one session's next turn. Both strings are owned.
const PendingNote = struct {
    session_id: []u8,
    text: []u8,
};

/// One answer an InstructionsLoaded hook gave. The session id and the path are owned.
const InstructionDecision = struct {
    session_id: []u8,
    path: []u8,
    stamp: u64,
    allow: bool,
};

/// One loaded snapshot and how many threads hold it. `refs` changes only under the runtime's mutex.
const Shared = struct { snapshot: loader.Snapshot, refs: u32 = 0 };

/// Notes queued for sessions' next turns, across every session. Past the cap a new note is dropped and
/// traced. A note waits only for its session's next turn, and a turn takes them all, so a long-lived ACP
/// server must not grow the queue without bound when some sessions never take theirs.
const max_pending_notes: usize = 64;

/// Answers InstructionsLoaded hooks remember, across every session and path. Past the cap the oldest
/// answer is forgotten. A forgotten answer only makes its hook run again for that file.
const max_instruction_decisions: usize = 512;

/// Background runs from `dispatchDetached` that may run at once. Past the cap a new run is dropped and
/// traced, so a burst of observe-only events cannot start a thread for each one.
const max_detached_runs: usize = 8;

/// How long the SessionEnd hooks of one exit may run together, in milliseconds (R2.5). A SessionEnd hook
/// that needs longer is stopped at this budget. The sessions of one exit share it, so exit waits at most
/// this long for them.
const session_end_exit_budget_ms: i64 = 1500;

/// Do not copy a Runtime after `init`: the host it gives the engine points into it.
pub const Runtime = struct {
    alloc: std.mem.Allocator,
    enabled: bool,
    home: ?[]u8,
    workspace_root: []u8,
    builtins: []const hooks.Builtin,
    /// Tests set `native.base_env`.
    native: NativeHost = .{},
    mutex: std.Io.Mutex = .init,
    /// Serializes appends to the run log. Separate from `mutex`, so a slow disk never holds the registry. Changes only under `log_mutex`.
    log_mutex: std.Io.Mutex = .init,
    current: ?*Shared = null,
    /// The workspace changed; the next refresh reloads whatever the files say.
    dirty: bool = true,
    /// Sessions that started here and have not ended. Changes only under `mutex`.
    sessions: std.ArrayList(SessionEntry) = .empty,
    /// Notes queued for a session's next turn, in the order they were queued. Changes only under `mutex`.
    pending_notes: std.ArrayList(PendingNote) = .empty,
    /// The answers InstructionsLoaded hooks gave, one per session and path. Changes only under `mutex`.
    instruction_decisions: std.ArrayList(InstructionDecision) = .empty,
    /// Background runs from `dispatchDetached` that have not finished, for the cap. Changes only under `mutex`.
    detached_running: usize = 0,
    /// Every background run from `dispatchDetached`. `waitDetached` awaits it, so `deinit` waits for the last one.
    detached_group: std.Io.Group = .init,
    /// Set when `deinit` begins. A background run that sees it stops at once, so exit does not wait out its timeout.
    exiting: std.atomic.Value(bool) = .init(false),
    /// The awake-clock time this runtime's exit SessionEnd hooks must finish by. Zero until the first exit sets it.
    exit_deadline_ms: std.atomic.Value(i64) = .init(0),

    /// Copies the paths. Reads no file; the first `refresh` does.
    pub fn init(alloc: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Runtime {
        const workspace_root = try alloc.dupe(u8, options.workspace_root);
        errdefer alloc.free(workspace_root);
        const home = if (options.home) |path| try alloc.dupe(u8, path) else null;
        return .{
            .alloc = alloc,
            .enabled = options.enabled,
            .home = home,
            .workspace_root = workspace_root,
            .builtins = options.builtins,
        };
    }

    /// The awake-clock time an exit's SessionEnd hooks must finish by, or null for a session that does not end
    /// at exit. The first exit sets the deadline, and every later exit of this runtime uses it, so the runtime
    /// shares one budget (R2.5). TUI and ACP reach it through `endSession`, and `deinit` through `endOpenSessions`.
    fn exitDeadline(self: *Runtime, reason: []const u8) ?i64 {
        if (!std.mem.eql(u8, reason, "exit")) return null;
        const proposed = awakeMs() + session_end_exit_budget_ms;
        // Zero means not set yet. A failed swap means another exit set it first, so its deadline is the one to use.
        if (self.exit_deadline_ms.cmpxchgStrong(0, proposed, .acq_rel, .acquire)) |set| return set;
        return proposed;
    }

    pub fn deinit(self: *Runtime) void {
        // Exit stays fast (R2.5): background runs stop at once, and the SessionEnd hooks run under a budget.
        // `exiting` is set under `mutex`, the lock `dispatchDetached` holds while it starts a run, so no run starts after this.
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.exiting.store(true, .release);
        self.mutex.unlock(io);
        // A background run still reads this runtime, so wait for it before anything is freed.
        self.waitDetached();
        self.endOpenSessions();
        // Stops the hook groups still live (R3.9). The registry is process-wide, so this assumes one runtime
        // at a time: ACP frees the old runtime before it creates the new one (server.zig:3170-3171).
        live_groups.killAll();
        self.freePendingNotes();
        self.freeInstructionDecisions();
        if (self.current) |shared| {
            std.debug.assert(shared.refs == 0);
            shared.snapshot.deinit(self.alloc);
            self.alloc.destroy(shared);
        }
        if (self.home) |path| self.alloc.free(path);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    /// Reads the hook files on the first call, after `setWorkspace`, and whenever a
    /// watched file changed. Otherwise it only stats files. It never fails: an
    /// allocation failure keeps the old snapshot and writes a trace line.
    pub fn refresh(self: *Runtime) void {
        if (!self.enabled) return;
        const io = io_mod.getIo();

        var dirty = false;
        var current: ?*Shared = null;
        self.mutex.lockUncancelable(io);
        dirty = self.dirty;
        current = self.current;
        if (current) |shared| shared.refs += 1;
        self.mutex.unlock(io);

        var need = false;
        if (current) |shared| {
            need = dirty or loader.changed(&shared.snapshot);
            self.release(shared);
        } else {
            need = true;
        }
        if (!need) return;

        // Copy the paths under the lock so a concurrent setWorkspace cannot free
        // them while the files are read.
        var home_copy: ?[]u8 = null;
        var root_copy: ?[]u8 = null;
        self.mutex.lockUncancelable(io);
        copyPaths(self.alloc, self.home, self.workspace_root, &home_copy, &root_copy) catch {
            self.mutex.unlock(io);
            debug_trace.logf("hooks", "could not reload hook files: out of memory; keeping the last ones", .{});
            return;
        };
        self.mutex.unlock(io);
        defer if (home_copy) |text| self.alloc.free(text);
        defer if (root_copy) |text| self.alloc.free(text);

        var snapshot = loader.load(self.alloc, .{
            .home = home_copy,
            .workspace_root = root_copy.?,
        }) catch {
            debug_trace.logf("hooks", "could not reload hook files: out of memory; keeping the last ones", .{});
            return;
        };

        var dropped = false;
        var out_of_memory = false;
        var old: ?*Shared = null;
        var free_old = false;
        self.mutex.lockUncancelable(io);
        if (!std.mem.eql(u8, self.workspace_root, root_copy.?)) {
            dropped = true;
        } else if (self.alloc.create(Shared)) |shared| {
            shared.* = .{ .snapshot = snapshot };
            old = self.current;
            self.current = shared;
            self.dirty = false;
            // Decided under the lock: at zero references no thread can take a new
            // one, since the snapshot is no longer current. Above zero, the last
            // release frees it.
            free_old = if (old) |value| value.refs == 0 else false;
        } else |_| {
            out_of_memory = true;
        }
        self.mutex.unlock(io);

        if (dropped) {
            snapshot.deinit(self.alloc);
            return;
        }
        if (out_of_memory) {
            snapshot.deinit(self.alloc);
            debug_trace.logf("hooks", "could not reload hook files: out of memory; keeping the last ones", .{});
            return;
        }
        if (free_old) {
            const finished = old.?;
            finished.snapshot.deinit(self.alloc);
            self.alloc.destroy(finished);
        }
    }

    /// Points the runtime at another workspace; the next refresh reloads.
    pub fn setWorkspace(self: *Runtime, workspace_root: []const u8) std.mem.Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, workspace_root);
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const old = self.workspace_root;
        self.workspace_root = copy;
        self.dirty = true;
        self.mutex.unlock(io);
        self.alloc.free(old);
    }

    /// Whether any builtin or runnable hook listens for this event.
    pub fn wants(self: *Runtime, name: hooks.EventName, match_value: ?[]const u8, trust_required: bool) bool {
        if (!self.enabled) return builtinWants(self.builtins, name);

        const shared = self.acquire() orelse return builtinWants(self.builtins, name);
        defer self.release(shared);

        const runnable = shared.snapshot.runnable(self.alloc, trust_required) catch {
            debug_trace.logf("hooks", "could not list runnable hooks: out of memory", .{});
            return true;
        };
        defer self.alloc.free(runnable);

        var engine = hooks.Engine{ .host = self.native.host(), .builtins = self.builtins };
        return engine.wants(runnable, name, match_value);
    }

    /// Whether an enabled, trusted hook listens for this event, so a run would wait for it. Builtins are left out,
    /// since they never wait. Reuses the matching in `Engine.countMatching`, as `countWaiting` does.
    pub fn hasTrustedMatch(self: *Runtime, name: hooks.EventName, match_value: ?[]const u8) std.mem.Allocator.Error!bool {
        if (!self.enabled) return false;
        const shared = self.acquire() orelse return false;
        defer self.release(shared);
        const trusted = try shared.snapshot.runnable(self.alloc, true);
        defer self.alloc.free(trusted);
        return hooks.Engine.countMatching(trusted, name, match_value) > 0;
    }

    /// How many hooks that fit this event wait for trust: they match, and a run that needs trust skips
    /// them. Zero when hooks are off or nothing is loaded.
    pub fn countWaiting(self: *Runtime, name: hooks.EventName, match_value: ?[]const u8) std.mem.Allocator.Error!usize {
        const shared = if (self.enabled) self.acquire() else null;
        defer if (shared) |value| self.release(value);
        const value = shared orelse return 0;

        const all = try value.snapshot.runnable(self.alloc, false);
        defer self.alloc.free(all);
        const trusted = try value.snapshot.runnable(self.alloc, true);
        defer self.alloc.free(trusted);
        return hooks.Engine.countMatching(all, name, match_value) - hooks.Engine.countMatching(trusted, name, match_value);
    }

    /// Runs every builtin and runnable hook for `ev` and merges their answers.
    /// Null when nothing listens. The caller owns the outcome, allocated with `alloc`.
    pub fn dispatch(
        self: *Runtime,
        alloc: std.mem.Allocator,
        ev: hooks.Event,
        trust_required: bool,
        cancel: ?*const std.atomic.Value(bool),
    ) std.mem.Allocator.Error!?hooks.Outcome {
        return self.dispatchOn(alloc, ev, trust_required, cancel, self.native.host());
    }

    /// `dispatch` through `host`, which starts the hook processes. The exit path passes an `ExitBudget` host.
    fn dispatchOn(
        self: *Runtime,
        alloc: std.mem.Allocator,
        ev: hooks.Event,
        trust_required: bool,
        cancel: ?*const std.atomic.Value(bool),
        host: hooks.Host,
    ) std.mem.Allocator.Error!?hooks.Outcome {
        const shared = if (self.enabled) self.acquire() else null;
        defer if (shared) |value| self.release(value);

        var runnable: []*const hooks.config.Hook = &.{};
        var allocated = false;
        if (shared) |value| {
            runnable = try value.snapshot.runnable(alloc, trust_required);
            allocated = true;
        }
        defer if (allocated) alloc.free(runnable);

        var engine = hooks.Engine{ .host = host, .builtins = self.builtins };
        if (!engine.wants(runnable, ev.name, ev.match_value)) return null;
        const outcome = try engine.run(alloc, runnable, ev, cancel);
        // Background runs come through here too, so one call logs both.
        if (outcome.ran > 0) self.logRun(ev, &outcome);
        return outcome;
    }

    /// Appends one line for a run where a user hook ran. It takes only `log_mutex`, never `mutex`,
    /// so a slow disk cannot hold up the registry. A failure drops the line and traces why.
    fn logRun(self: *Runtime, ev: hooks.Event, outcome: *const hooks.Outcome) void {
        const home = self.home orelse {
            debug_trace.logf("hooks", "dropped hook run log line: no home directory", .{});
            return;
        };
        const line = runLogLine(self.alloc, ev, outcome) catch |err| {
            debug_trace.logf("hooks", "dropped hook run log line: {s}", .{@errorName(err)});
            return;
        };
        defer self.alloc.free(line);

        const io = io_mod.getIo();
        self.log_mutex.lockUncancelable(io);
        defer self.log_mutex.unlock(io);
        appendRunLog(self.alloc, home, line) catch |err| {
            if (err == error.TrustFileBusy) {
                debug_trace.logf("hooks", "dropped kind=run log line bytes={d} reason=busy", .{line.len});
                return;
            }
            debug_trace.logf("hooks", "dropped hook run log line: {s}", .{@errorName(err)});
        };
    }

    /// Runs the hooks for an observe-only event as a background `std.Io` task and returns at once. The
    /// outcome is not used; its notices are traced. `deinit` waits for every run started here.
    pub fn dispatchDetached(self: *Runtime, ev: hooks.Event, trust_required: bool) void {
        if (!self.wants(ev.name, ev.match_value, trust_required)) return;
        const label = ev.name.fileName();

        // The exit check, the cap, and the group call share one lock hold. `deinit` sets `exiting` under the same
        // lock before it awaits the group, so every run this call starts is one that `deinit` waits for.
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.exiting.load(.acquire)) {
            debug_trace.logf("hooks", "dropped background {s} hooks: the runtime is exiting", .{label});
            return;
        }
        if (self.detached_running >= max_detached_runs) {
            debug_trace.logf("hooks", "dropped kind=background hook run event={s} bytes={d} reason=too many running", .{ label, eventBytes(ev) });
            return;
        }

        // The job copies every string the event borrows, so the caller's buffers may go away.
        const job = self.alloc.create(DetachedJob) catch {
            debug_trace.logf("hooks", "dropped background {s} hooks: out of memory", .{label});
            return;
        };
        job.arena = std.heap.ArenaAllocator.init(self.alloc);
        job.event = copyEvent(job.arena.allocator(), ev) catch {
            job.arena.deinit();
            self.alloc.destroy(job);
            debug_trace.logf("hooks", "dropped background {s} hooks: out of memory", .{label});
            return;
        };
        job.trust_required = trust_required;

        // The count is taken before the task starts, so the cap sees this run. A task that cannot start is
        // dropped the way a failed spawn was: its copies are freed, and the run is traced.
        self.detached_running += 1;
        self.detached_group.concurrent(io, detachedMain, .{ self, job }) catch |err| {
            self.detached_running -= 1;
            job.arena.deinit();
            self.alloc.destroy(job);
            debug_trace.logf("hooks", "dropped background {s} hooks: {s}", .{ label, @errorName(err) });
            return;
        };
    }

    /// Waits until every background run started by `dispatchDetached` has finished.
    pub fn waitDetached(self: *Runtime) void {
        // Only a task that is itself cancelled gets error.Canceled from `await`, and this caller is never one.
        self.detached_group.await(io_mod.getIo()) catch {};
    }

    /// Keeps `note` for the session's next turn only. It works whether or not the session has had a
    /// turn yet. The note is cut to the text limit, with a trace when it is cut.
    pub fn queueSessionNote(self: *Runtime, session_id: []const u8, note: []const u8) std.mem.Allocator.Error!void {
        const cut = hooks.limits.cutChars(note, hooks.limits.text_chars);
        if (cut.was_cut) debug_trace.logf("hooks", "note for {s} cut to {d} characters", .{ session_id, hooks.limits.text_chars });
        const owned_id = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(owned_id);
        const owned_text = try self.alloc.dupe(u8, cut.text);
        errdefer self.alloc.free(owned_text);

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.pending_notes.items.len >= max_pending_notes) {
            self.alloc.free(owned_id);
            self.alloc.free(owned_text);
            debug_trace.logf("hooks", "dropped kind=queued hook note bytes={d} reason=queue full", .{note.len});
            return;
        }
        try self.pending_notes.append(self.alloc, .{ .session_id = owned_id, .text = owned_text });
    }

    /// Takes every note queued for `session_id`, joined by a blank line in the order they were
    /// queued. Null when there are none. The taken notes leave the queue, so each reaches one turn.
    pub fn takeSessionNotes(self: *Runtime, alloc: std.mem.Allocator, session_id: []const u8) std.mem.Allocator.Error!?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // The text is built before any note leaves the queue, so an allocation failure keeps them all.
        var joined: std.ArrayList(u8) = .empty;
        errdefer joined.deinit(alloc);
        var found = false;
        for (self.pending_notes.items) |note| {
            if (!std.mem.eql(u8, note.session_id, session_id)) continue;
            if (found) try joined.appendSlice(alloc, "\n\n");
            try joined.appendSlice(alloc, note.text);
            found = true;
        }
        if (!found) {
            joined.deinit(alloc);
            return null;
        }
        const text = try joined.toOwnedSlice(alloc);
        _ = self.removeSessionNotesLocked(session_id);
        return text;
    }

    /// The answer the session's InstructionsLoaded hooks gave for `path` at `stamp`, or null when none
    /// was given at that stamp. A changed stamp is no answer, so the file is asked again.
    pub fn instructionDecision(self: *Runtime, session_id: []const u8, path: []const u8, stamp: u64) ?bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.instruction_decisions.items) |decision| {
            if (!std.mem.eql(u8, decision.session_id, session_id)) continue;
            if (!std.mem.eql(u8, decision.path, path)) continue;
            return if (decision.stamp == stamp) decision.allow else null;
        }
        return null;
    }

    /// Remembers the answer for `path` in `session_id` at `stamp`. A new stamp for the same path
    /// replaces the answer kept for it.
    pub fn rememberInstructionDecision(self: *Runtime, session_id: []const u8, path: []const u8, stamp: u64, allow: bool) std.mem.Allocator.Error!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.instruction_decisions.items) |*decision| {
            if (!std.mem.eql(u8, decision.session_id, session_id)) continue;
            if (!std.mem.eql(u8, decision.path, path)) continue;
            decision.stamp = stamp;
            decision.allow = allow;
            return;
        }
        const owned_session = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(owned_session);
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);
        try self.instruction_decisions.append(self.alloc, .{
            .session_id = owned_session,
            .path = owned_path,
            .stamp = stamp,
            .allow = allow,
        });
        if (self.instruction_decisions.items.len > max_instruction_decisions) {
            const oldest = self.instruction_decisions.orderedRemove(0);
            debug_trace.logf("hooks", "dropped kind=instruction answer bytes={d} reason=cache full", .{oldest.path.len});
            freeInstructionDecision(self.alloc, oldest);
        }
    }

    /// Removes and frees the queued notes for `session_id`. Returns how many. Caller holds `mutex`.
    fn removeSessionNotesLocked(self: *Runtime, session_id: []const u8) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.pending_notes.items.len) {
            if (std.mem.eql(u8, self.pending_notes.items[index].session_id, session_id)) {
                freePendingNote(self.alloc, self.pending_notes.orderedRemove(index));
                removed += 1;
            } else {
                index += 1;
            }
        }
        return removed;
    }

    /// Removes and frees the instruction answers for `session_id`. Returns how many. Caller holds `mutex`.
    fn removeInstructionDecisionsLocked(self: *Runtime, session_id: []const u8) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.instruction_decisions.items.len) {
            if (std.mem.eql(u8, self.instruction_decisions.items[index].session_id, session_id)) {
                freeInstructionDecision(self.alloc, self.instruction_decisions.orderedRemove(index));
                removed += 1;
            } else {
                index += 1;
            }
        }
        return removed;
    }

    /// Drops what an ended session left here: its queued notes and its instruction answers.
    /// Caller holds `mutex`. Traces the counts when anything was dropped.
    fn dropSessionStateLocked(self: *Runtime, session_id: []const u8) void {
        const notes = self.removeSessionNotesLocked(session_id);
        const decisions = self.removeInstructionDecisionsLocked(session_id);
        if (notes + decisions > 0) {
            debug_trace.logf("hooks", "ended session dropped {d} queued notes and {d} instruction answers", .{ notes, decisions });
        }
    }

    /// Frees the answers InstructionsLoaded hooks gave. Only `deinit` calls it, after the background runs finish.
    fn freeInstructionDecisions(self: *Runtime) void {
        for (self.instruction_decisions.items) |decision| freeInstructionDecision(self.alloc, decision);
        self.instruction_decisions.deinit(self.alloc);
    }

    /// Frees the notes that nothing took. Only `deinit` calls it, after the background runs finish.
    fn freePendingNotes(self: *Runtime) void {
        for (self.pending_notes.items) |note| freePendingNote(self.alloc, note);
        self.pending_notes.deinit(self.alloc);
    }

    /// How many hooks wait for trust and do not run here, in any layer. Zero when hooks are off.
    pub fn waitingHooks(self: *Runtime) usize {
        if (!self.enabled) return 0;
        const shared = self.acquire() orelse return 0;
        defer self.release(shared);
        return shared.snapshot.pending();
    }

    /// Records `count` as the waiting count this session was last told about, and returns it when it rose
    /// past the count told before. Null when the session did not start here or the count did not rise.
    /// Changes only under `mutex`, and runs no hook.
    pub fn trustNoticeDue(self: *Runtime, session_id: []const u8, count: usize) ?usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.sessionIndexLocked(session_id) orelse return null;
        const entry = &self.sessions.items[index];
        const told = entry.trust_notice_count;
        entry.trust_notice_count = count;
        return if (count > told) count else null;
    }

    pub fn summary(self: *Runtime) Summary {
        if (!self.enabled) return .{};
        const shared = self.acquire() orelse return .{};
        defer self.release(shared);
        return .{
            .hooks = shared.snapshot.hooks.len,
            .pending = shared.snapshot.pending(),
            .problems = shared.snapshot.problems.len,
            .disabled = shared.snapshot.disabledCount(),
        };
    }

    /// Records that `info.session_id` started in this process. True only the first time for an id.
    pub fn beginSession(self: *Runtime, info: SessionInfo) std.mem.Allocator.Error!bool {
        const entry = try copySession(self.alloc, info);
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.sessionIndexLocked(info.session_id) != null) {
            self.mutex.unlock(io);
            freeSession(self.alloc, entry);
            return false;
        }
        self.sessions.append(self.alloc, entry) catch |err| {
            self.mutex.unlock(io);
            freeSession(self.alloc, entry);
            return err;
        };
        self.mutex.unlock(io);
        return true;
    }

    /// Keeps `context` as the session's start context, cut to the text limit. A session that did not
    /// start here gets no context, and the drop is traced.
    pub fn setSessionContext(self: *Runtime, session_id: []const u8, context: []const u8) std.mem.Allocator.Error!void {
        const cut = hooks.limits.cutChars(context, hooks.limits.text_chars);
        if (cut.was_cut) debug_trace.logf("hooks", "session context for {s} cut to {d} characters", .{ session_id, hooks.limits.text_chars });
        const copy = try self.alloc.dupe(u8, cut.text);
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const index = self.sessionIndexLocked(session_id) orelse {
            self.mutex.unlock(io);
            self.alloc.free(copy);
            debug_trace.logf("hooks", "dropped session context: {s} did not start in this process", .{session_id});
            return;
        };
        const old = self.sessions.items[index].context;
        self.sessions.items[index].context = copy;
        self.mutex.unlock(io);
        if (old) |text| self.alloc.free(text);
    }

    /// A copy, in `alloc`, of the session's start context; null when it has none.
    pub fn sessionContext(self: *Runtime, alloc: std.mem.Allocator, session_id: []const u8) std.mem.Allocator.Error!?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.sessionIndexLocked(session_id) orelse return null;
        const text = self.sessions.items[index].context orelse return null;
        return try alloc.dupe(u8, text);
    }

    /// Ends a session that started here: removes it and what it left in the queued notes and the
    /// instruction answers, runs its SessionEnd hooks with `reason`, and frees it. An exit runs them under
    /// the exit budget and waits for them; any other reason (a switch) runs them in the background and returns
    /// at once. An unknown session does nothing.
    pub fn endSession(self: *Runtime, session_id: []const u8, reason: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const index = self.sessionIndexLocked(session_id) orelse {
            self.mutex.unlock(io);
            return;
        };
        const entry = self.sessions.swapRemove(index);
        self.dropSessionStateLocked(session_id);
        const project_dir = self.alloc.dupe(u8, self.workspace_root);
        self.mutex.unlock(io);
        defer if (project_dir) |text| self.alloc.free(text) else |_| {};
        self.finishSession(entry, project_dir, reason, self.exitDeadline(reason));
    }

    /// Ends every session still open, with reason "exit". The list and the workspace copy are taken
    /// under the lock; the hooks run after it is released.
    fn endOpenSessions(self: *Runtime) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        var open = self.sessions;
        self.sessions = .empty;
        const project_dir = self.alloc.dupe(u8, self.workspace_root);
        self.mutex.unlock(io);
        defer if (project_dir) |text| self.alloc.free(text) else |_| {};
        defer open.deinit(self.alloc);
        // One deadline for all of them, so exit with many open sessions still waits at most one budget.
        const deadline = self.exitDeadline("exit");
        for (open.items) |entry| self.finishSession(entry, project_dir, "exit", deadline);
    }

    /// Runs SessionEnd for an ended session, then frees it. `project_dir` is the workspace copy the caller
    /// made under the lock; it is borrowed here.
    /// `deadline` is the exit budget's end on the awake clock, or null when the session does not end at exit, in
    /// which case the hooks run in the background.
    fn finishSession(self: *Runtime, entry: SessionEntry, project_dir: std.mem.Allocator.Error![]u8, reason: []const u8, deadline: ?i64) void {
        defer freeSession(self.alloc, entry);
        // Subagent sessions end with SubagentStop, not SessionEnd.
        if (entry.info.surface == .subagent) return;
        if (!self.enabled) return;
        const project = project_dir catch |err| {
            debug_trace.logf("hooks", "dropped SessionEnd hooks for {s}: {s}", .{ entry.info.session_id, @errorName(err) });
            return;
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const fields = [_]hooks.Field{.{ .key = "reason", .value = .{ .string = reason } }};
        const event = hooks.Event{
            .name = .session_end,
            .scope = .{
                .surface = entry.info.surface,
                .session_id = entry.info.session_id,
                .cwd = entry.info.cwd,
                .project_dir = project,
                .permission_mode = entry.info.permission_mode,
            },
            .match_value = reason,
            .fields = &fields,
        };
        // A switch is not an exit, so its hooks run on a background thread and the caller returns at once (R2.1).
        // `dispatchDetached` copies the event before it returns, so `project` and the arena may go away after it.
        if (deadline == null) {
            self.dispatchDetached(event, entry.info.trust_required);
            return;
        }
        // Only an exit reaches here: the early return above took every other end, so the deadline is set.
        var budget = ExitBudget{ .inner = self.native.host(), .deadline_ms = deadline.? };
        const outcome = self.dispatchOn(arena.allocator(), event, entry.info.trust_required, null, budget.host()) catch |err| {
            debug_trace.logf("hooks", "dropped SessionEnd hooks for {s}: {s}", .{ entry.info.session_id, @errorName(err) });
            return;
        };
        // No surface can show a notice once its session has ended, so each notice is traced instead.
        if (outcome) |value| {
            for (value.notices) |notice| debug_trace.logf("hooks", "SessionEnd notice for {s}: kind={s} bytes={d}", .{ entry.info.session_id, @tagName(notice.kind), notice.text.len });
        }
    }

    /// The index of the session with this id. The caller holds `mutex`.
    fn sessionIndexLocked(self: *const Runtime, session_id: []const u8) ?usize {
        for (self.sessions.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.info.session_id, session_id)) return index;
        }
        return null;
    }

    fn acquire(self: *Runtime) ?*Shared {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const shared = self.current orelse return null;
        shared.refs += 1;
        return shared;
    }

    fn release(self: *Runtime, shared: *Shared) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        shared.refs -= 1;
        const free_now = shared.refs == 0 and shared != self.current;
        self.mutex.unlock(io);
        if (free_now) {
            shared.snapshot.deinit(self.alloc);
            self.alloc.destroy(shared);
        }
    }
};

/// One background run: its event, with every string the event borrows copied into `arena`.
const DetachedJob = struct {
    arena: std.heap.ArenaAllocator,
    event: hooks.Event,
    trust_required: bool,
};

/// The background thread's body. Runs one job's hooks, traces their notices, and releases the job.
/// The run log is kept at most about this size. Past it, the log moves to `hooks.jsonl.1` before the next line.
const run_log_max_bytes: u64 = 1024 * 1024;
const run_log_name = "hooks.jsonl";
/// How long a run log line waits for the log lock. Zero means one try, and a busy log drops the
/// line with a trace. A hook run can happen on the UI loop, which never waits on another process.
const run_log_lock_wait_ms: u32 = 0;
const run_log_old_name = "hooks.jsonl.1";
/// How many characters of a decision's reason one log line keeps.
const run_log_reason_chars: usize = 200;

/// `<profile>/logs/hooks.jsonl`: one JSON line for each event where at least one user hook ran.
pub fn logPath(alloc: std.mem.Allocator, home: []const u8) ![]u8 {
    const dir = try profile_paths.logsDir(alloc, home);
    defer alloc.free(dir);
    return std.Io.Dir.path.join(alloc, &.{ dir, run_log_name });
}

/// `<profile>/logs/hooks.jsonl.1`: the older run log, moved aside when the current one reached the cap.
pub fn oldLogPath(alloc: std.mem.Allocator, home: []const u8) ![]u8 {
    const dir = try profile_paths.logsDir(alloc, home);
    defer alloc.free(dir);
    return std.Io.Dir.path.join(alloc, &.{ dir, run_log_old_name });
}

/// One JSON line for a run: when it happened, the event and match, what decided it, and how many notices.
fn runLogLine(alloc: std.mem.Allocator, ev: hooks.Event, outcome: *const hooks.Outcome) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{{\"time_ms\":{d},\"event\":", .{io_mod.milliTimestamp()});
    try std.json.Stringify.value(ev.name.fileName(), .{}, w);
    try w.writeAll(",\"match\":");
    try writeOptionalJsonText(w, ev.match_value);
    try w.print(",\"surface\":\"{s}\",\"session_id\":", .{@tagName(ev.scope.surface)});
    try writeOptionalJsonText(w, ev.scope.session_id);
    try w.print(",\"ran\":{d},\"decision\":\"{s}\",\"decided_by\":", .{ outcome.ran, @tagName(outcome.decision) });
    try writeOptionalJsonText(w, outcome.decided_by);
    try w.writeAll(",\"reason\":");
    if (outcome.reason) |reason| {
        try std.json.Stringify.value(hooks.limits.cutChars(reason, run_log_reason_chars).text, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"notices\":{d}}}\n", .{outcome.notices.len});
    return try out.toOwnedSlice();
}

/// Writes a string as JSON, or `null` when it is absent.
fn writeOptionalJsonText(writer: *std.Io.Writer, text: ?[]const u8) !void {
    if (text) |value| {
        try std.json.Stringify.value(value, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

/// Appends `line` to the run log in the profile. When the log is past the cap, it moves to `hooks.jsonl.1`
/// first, replacing the older file. A failed move skips the line, so the cap always holds.
fn appendRunLog(alloc: std.mem.Allocator, home: []const u8, line: []const u8) !void {
    const io = io_mod.getIo();
    const dir = try profile_paths.logsDir(alloc, home);
    defer alloc.free(dir);
    try io_mod.makeDirRecursive(dir);
    const log_path = try std.Io.Dir.path.join(alloc, &.{ dir, run_log_name });
    defer alloc.free(log_path);

    // One lock covers the size check, the move to the old file, and the append, so
    // two fx processes never rotate or write the log at the same time. `log_mutex`
    // already keeps the threads of this process apart.
    const lock = try trust.lockWriters(alloc, log_path, run_log_lock_wait_ms);
    defer lock.release();

    if (runLogTooLarge(io, log_path)) {
        const old_path = try std.Io.Dir.path.join(alloc, &.{ dir, run_log_old_name });
        defer alloc.free(old_path);
        try std.Io.Dir.renameAbsolute(log_path, old_path, io);
    }
    var file = try std.Io.Dir.createFileAbsolute(io, log_path, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(trust.private_file_mode),
    });
    defer file.close(io);
    _ = std.c.lseek(file.handle, 0, std.posix.SEEK.END);
    try file.writeStreamingAll(io, line);
}

/// Whether the run log is past the cap. A log that cannot be read is treated as small, and the append decides.
fn runLogTooLarge(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    return stat.size > run_log_max_bytes;
}

/// The bytes of text an event carries: its match value, and each field's key and text. A trace reports
/// this size for a dropped event, never the text.
fn eventBytes(ev: hooks.Event) usize {
    var total: usize = if (ev.match_value) |value| value.len else 0;
    for (ev.fields) |field| {
        total += field.key.len;
        total += switch (field.value) {
            .string, .json => |text| text.len,
            else => 0,
        };
    }
    return total;
}

/// Caps the hook processes of one exit's SessionEnd runs at a shared deadline (R2.5). A process that would
/// start after the deadline does not start, and one that runs past it is stopped there. The engine reaches
/// processes only through `Host.run_process`, so this host wraps the native one and changes no engine code.
const ExitBudget = struct {
    inner: hooks.Host,
    /// The awake-clock time, in milliseconds, when the budget ends.
    deadline_ms: i64,

    fn host(self: *ExitBudget) hooks.Host {
        return .{ .ctx = self, .run_process = runProcess, .now_ms = nowMs, .trace = trace };
    }

    fn runProcess(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        request: hooks.host.ProcessRequest,
    ) std.mem.Allocator.Error!hooks.host.ProcessResult {
        const self: *ExitBudget = @ptrCast(@alignCast(ctx));
        const left_ms = self.deadline_ms - awakeMs();
        if (left_ms <= 0) {
            debug_trace.logf("hooks", "dropped kind=session end hook bytes={d} reason=exit budget spent", .{process.argvBytes(request.argv)});
            return .timed_out;
        }
        var capped = request;
        capped.timeout_ms = @intCast(@min(left_ms, request.timeout_ms));
        return self.inner.run_process(self.inner.ctx, alloc, capped);
    }

    fn nowMs(ctx: *anyopaque) u64 {
        const self: *ExitBudget = @ptrCast(@alignCast(ctx));
        return self.inner.now_ms(self.inner.ctx);
    }

    fn trace(ctx: *anyopaque, line: []const u8) void {
        const self: *ExitBudget = @ptrCast(@alignCast(ctx));
        self.inner.trace(self.inner.ctx, line);
    }
};

/// The awake clock in milliseconds: the clock process.zig waits on, so a budget and a timeout agree.
fn awakeMs() i64 {
    return std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds();
}

fn detachedMain(self: *Runtime, job: *DetachedJob) void {
    const io = io_mod.getIo();
    const label = job.event.name.fileName();
    defer {
        job.arena.deinit();
        self.alloc.destroy(job);
        self.mutex.lockUncancelable(io);
        self.detached_running -= 1;
        self.mutex.unlock(io);
    }

    var run_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer run_arena.deinit();
    // The exit cancels a background run (see `deinit`), so exit does not wait out the hook's timeout.
    const maybe_outcome = self.dispatch(run_arena.allocator(), job.event, job.trust_required, &self.exiting) catch |err| {
        debug_trace.logf("hooks", "dropped background {s} hooks: {s}", .{ label, @errorName(err) });
        return;
    };
    const outcome = maybe_outcome orelse return;
    for (outcome.notices) |notice| debug_trace.logf("hooks", "{s} notice: kind={s} bytes={d}", .{ label, @tagName(notice.kind), notice.text.len });
}

/// Copies every string an event borrows, so the copy does not depend on the caller's memory.
fn copyEvent(alloc: std.mem.Allocator, ev: hooks.Event) std.mem.Allocator.Error!hooks.Event {
    const fields = try alloc.alloc(hooks.Field, ev.fields.len);
    for (ev.fields, fields) |source, *target| {
        target.* = .{ .key = try alloc.dupe(u8, source.key), .value = try copyValue(alloc, source.value) };
    }
    return .{
        .name = ev.name,
        .scope = .{
            .surface = ev.scope.surface,
            .session_id = try dupeOptional(alloc, ev.scope.session_id),
            .turn_id = ev.scope.turn_id,
            .subagent_id = ev.scope.subagent_id,
            .cwd = try alloc.dupe(u8, ev.scope.cwd),
            .project_dir = try alloc.dupe(u8, ev.scope.project_dir),
            .permission_mode = try alloc.dupe(u8, ev.scope.permission_mode),
            .transcript_path = try dupeOptional(alloc, ev.scope.transcript_path),
        },
        .match_value = try dupeOptional(alloc, ev.match_value),
        .fields = fields,
    };
}

fn copyValue(alloc: std.mem.Allocator, value: hooks.Value) std.mem.Allocator.Error!hooks.Value {
    return switch (value) {
        .string => |text| .{ .string = try alloc.dupe(u8, text) },
        .json => |text| .{ .json = try alloc.dupe(u8, text) },
        .boolean, .integer, .null_value => value,
    };
}

fn dupeOptional(alloc: std.mem.Allocator, text: ?[]const u8) std.mem.Allocator.Error!?[]u8 {
    const value = text orelse return null;
    return try alloc.dupe(u8, value);
}

/// Copies a session's strings, so the registry owns them.
fn copySession(alloc: std.mem.Allocator, info: SessionInfo) std.mem.Allocator.Error!SessionEntry {
    const session_id = try alloc.dupe(u8, info.session_id);
    errdefer alloc.free(session_id);
    const cwd = try alloc.dupe(u8, info.cwd);
    errdefer alloc.free(cwd);
    const permission_mode = try alloc.dupe(u8, info.permission_mode);
    errdefer alloc.free(permission_mode);
    return .{ .info = .{
        .session_id = session_id,
        .surface = info.surface,
        .cwd = cwd,
        .permission_mode = permission_mode,
        .trust_required = info.trust_required,
    } };
}

fn freeInstructionDecision(alloc: std.mem.Allocator, decision: InstructionDecision) void {
    alloc.free(decision.session_id);
    alloc.free(decision.path);
}

fn freePendingNote(alloc: std.mem.Allocator, note: PendingNote) void {
    alloc.free(note.session_id);
    alloc.free(note.text);
}

fn freeSession(alloc: std.mem.Allocator, entry: SessionEntry) void {
    alloc.free(entry.info.session_id);
    alloc.free(entry.info.cwd);
    alloc.free(entry.info.permission_mode);
    if (entry.context) |text| alloc.free(text);
}

fn builtinWants(builtins: []const hooks.Builtin, name: hooks.EventName) bool {
    for (builtins) |builtin| {
        if (builtin.events.contains(name)) return true;
    }
    return false;
}

/// Copies the two paths under the caller's lock. Sets both outputs only on success.
fn copyPaths(
    alloc: std.mem.Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    home_out: *?[]u8,
    root_out: *?[]u8,
) std.mem.Allocator.Error!void {
    if (home) |path| {
        const copied_home = try alloc.dupe(u8, path);
        root_out.* = alloc.dupe(u8, workspace_root) catch |err| {
            alloc.free(copied_home);
            return err;
        };
        home_out.* = copied_home;
    } else {
        root_out.* = try alloc.dupe(u8, workspace_root);
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        return .{ .tmp = tmp, .home = home, .workspace = workspace };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn writeFixture(alloc: std.mem.Allocator, file_path: []const u8, text: []const u8) !void {
    try io_mod.writeFileAtomic(alloc, file_path, text);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
}

fn writeProfile(alloc: std.mem.Allocator, fixture: *const Fixture, text: []const u8) !void {
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const file_path = try profilePath(alloc, fixture);
    defer alloc.free(file_path);
    try writeFixture(alloc, file_path, text);
}

fn profilePath(alloc: std.mem.Allocator, fixture: *const Fixture) ![]u8 {
    return profile_paths.rootPath(alloc, fixture.home, &.{"hooks.json"});
}

fn writeProject(alloc: std.mem.Allocator, fixture: *const Fixture, text: []const u8) !void {
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    const file_path = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, ".fx/hooks.json" });
    defer alloc.free(file_path);
    try writeFixture(alloc, file_path, text);
}

fn testEnv(alloc: std.mem.Allocator) std.mem.Allocator.Error!std.process.Environ.Map {
    var env = std.process.Environ.Map.init(alloc);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    return env;
}

fn testEvent(workspace: []const u8, fields: []const hooks.Field) hooks.Event {
    return .{
        .name = .pre_tool_use,
        .scope = .{
            .surface = .interactive,
            .cwd = workspace,
            .project_dir = workspace,
            .permission_mode = "auto",
        },
        .match_value = "shell",
        .fields = fields,
    };
}

const profile_deny_text =
    \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no\"}}'"}]}]}}
;

test "a disabled runtime runs only builtins" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);

    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();

    const fields = [_]hooks.Field{
        .{ .key = "tool_name", .value = .{ .string = "shell" } },
    };
    const outcome = try runtime.dispatch(alloc, testEvent(fixture.workspace, &fields), true, null);
    try std.testing.expect(outcome == null);

    const counts = runtime.summary();
    try std.testing.expectEqual(@as(usize, 0), counts.hooks);
    try std.testing.expectEqual(@as(usize, 0), counts.pending);
    try std.testing.expectEqual(@as(usize, 0), counts.problems);
}

fn dingRun(ctx: *anyopaque, ev: *const hooks.Event) hooks.Answer {
    _ = ctx;
    _ = ev;
    return .{ .system_message = "ding" };
}

test "a disabled runtime still runs its builtins" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);

    const builtins = [_]hooks.Builtin{
        .{
            .name = "fx.ding",
            .events = std.EnumSet(hooks.EventName).initOne(.notification),
            .ctx = undefined,
            .run = dingRun,
        },
    };
    var runtime = try Runtime.init(alloc, .{
        .enabled = false,
        .home = fixture.home,
        .workspace_root = fixture.workspace,
        .builtins = &builtins,
    });
    defer runtime.deinit();

    const fields = [_]hooks.Field{
        .{ .key = "message", .value = .{ .string = "hello" } },
    };
    var event = testEvent(fixture.workspace, &fields);
    event.name = .notification;
    event.match_value = null;

    var outcome = (try runtime.dispatch(alloc, event, true, null)).?;
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqualStrings("ding", outcome.notices[0].text);
}

test "waiting hooks count every untrusted hook, in any layer" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);
    try writeProject(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();

    // The profile's hook and the project's hook both wait, and both count.
    try std.testing.expectEqual(@as(usize, 2), runtime.summary().pending);
    try std.testing.expectEqual(@as(usize, 2), runtime.waitingHooks());
}

test "trust decides which hooks run" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);
    try writeProject(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var parsed = try hooks.config.parse(alloc, profile_deny_text, .{ .layer = .profile, .workspace_root = fixture.workspace });
    defer parsed.deinit(alloc);
    var named = try trust.namedFiles(alloc, parsed.hooks[0].command, fixture.workspace, fixture.home);
    defer named.deinit(alloc);
    const value = try trust.digest(alloc, &parsed.hooks[0], fixture.workspace, named.files);
    var store = trust.Store{};
    defer store.deinit(alloc);
    try store.add(alloc, value, "deny hook");
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try trust.save(alloc, trust_file, &store);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const counts = runtime.summary();
    try std.testing.expectEqual(@as(usize, 2), counts.hooks);
    try std.testing.expectEqual(@as(usize, 1), counts.pending);

    const fields = [_]hooks.Field{
        .{ .key = "tool_name", .value = .{ .string = "shell" } },
    };
    const event = testEvent(fixture.workspace, &fields);

    var trusted_only = (try runtime.dispatch(alloc, event, true, null)).?;
    defer trusted_only.deinit(alloc);
    try std.testing.expectEqual(hooks.Decision.deny, trusted_only.decision);
    try std.testing.expectEqualStrings("no", trusted_only.reason.?);
    try std.testing.expectEqual(@as(usize, 1), trusted_only.ran);
    // The project hook waits for trust: a run that needs trust skips it, and the count says so.
    try std.testing.expectEqual(@as(usize, 1), try runtime.countWaiting(event.name, event.match_value));

    var everything = (try runtime.dispatch(alloc, event, false, null)).?;
    defer everything.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), everything.ran);
}

/// The run log's text, read in full.
fn readRunLog(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    return io_mod.readFileToEnd(alloc, &file, run_log_max_bytes * 4);
}

fn countLines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

test "a hook run writes one log line" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const fields = [_]hooks.Field{.{ .key = "tool_name", .value = .{ .string = "shell" } }};
    var outcome = (try runtime.dispatch(alloc, testEvent(fixture.workspace, &fields), false, null)).?;
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(hooks.Decision.deny, outcome.decision);

    const path = try logPath(alloc, fixture.home);
    defer alloc.free(path);
    const text = try readRunLog(alloc, path);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 1), countLines(text));

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, text, "\n"), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("PreToolUse", object.get("event").?.string);
    try std.testing.expectEqual(@as(i64, 1), object.get("ran").?.integer);
    try std.testing.expectEqualStrings("deny", object.get("decision").?.string);
    try std.testing.expectEqualStrings(outcome.decided_by.?, object.get("decided_by").?.string);
    try std.testing.expectEqualStrings(outcome.reason.?, object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 0), object.get("notices").?.integer);
}

test "no hook run writes no log line" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();

    var event = testEvent(fixture.workspace, &.{});
    event.name = .stop;
    event.match_value = null;
    const outcome = try runtime.dispatch(alloc, event, false, null);
    try std.testing.expect(outcome == null);

    const path = try logPath(alloc, fixture.home);
    defer alloc.free(path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}));
}

test "a run log line is not written while another writer holds the log lock" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const log = try logPath(alloc, home);
    defer alloc.free(log);

    const held = try trust.lockWriters(alloc, log, 0);
    defer held.release();
    try std.testing.expectError(error.TrustFileBusy, appendRunLog(alloc, home, "line\n"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, log, .{}));
}

test "a run log append holds a lock beside the log, so two processes never rotate at once" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    try appendRunLog(alloc, home, "first\n");

    const log = try logPath(alloc, home);
    defer alloc.free(log);
    const lock_path = try alloc.print("{s}.lock", .{log});
    defer alloc.free(lock_path);
    var lock_file = try std.Io.Dir.openFileAbsolute(io, lock_path, .{});
    lock_file.close(io);
}

test "the run log is cut at 1 MiB" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/logs");

    const path = try logPath(alloc, fixture.home);
    defer alloc.free(path);
    const old_path = try std.Io.Dir.path.join(alloc, &.{ std.Io.Dir.path.dirname(path).?, run_log_old_name });
    defer alloc.free(old_path);
    // An earlier run filled the log to one byte past the cap.
    const filler = try alloc.alloc(u8, run_log_max_bytes + 1);
    defer alloc.free(filler);
    @memset(filler, 'x');
    try writeFixture(alloc, path, filler);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const fields = [_]hooks.Field{.{ .key = "tool_name", .value = .{ .string = "shell" } }};
    var outcome = (try runtime.dispatch(alloc, testEvent(fixture.workspace, &fields), false, null)).?;
    defer outcome.deinit(alloc);

    // The full log moved aside unchanged, and the new log holds the one line.
    const old_text = try readRunLog(alloc, old_path);
    defer alloc.free(old_text);
    try std.testing.expectEqual(filler.len, old_text.len);
    const text = try readRunLog(alloc, path);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 1), countLines(text));
}

test "an event nothing listens for has no outcome" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, profile_deny_text);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();

    try std.testing.expect(!runtime.wants(.stop, null, true));
    var event = testEvent(fixture.workspace, &.{});
    event.name = .stop;
    event.match_value = null;
    const outcome = try runtime.dispatch(alloc, event, true, null);
    try std.testing.expect(outcome == null);
}

test "a changed file reloads, an unchanged one does not" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();
    try std.testing.expectEqual(@as(usize, 2), runtime.summary().hooks);

    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"},{\"type\":\"command\",\"command\":\"exit 0 --again\"}]}]}}");
    runtime.refresh();
    try std.testing.expectEqual(@as(usize, 3), runtime.summary().hooks);

    const before = runtime.current;
    runtime.refresh();
    try std.testing.expectEqual(before, runtime.current);
    try std.testing.expectEqual(@as(usize, 3), runtime.summary().hooks);
}

test "another workspace replaces the project hooks" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();
    try std.testing.expectEqual(@as(usize, 2), runtime.summary().hooks);

    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "second/.fx");
    const second = try io_mod.dirRealpathAlloc(alloc, fixture.tmp.dir, "second");
    defer alloc.free(second);
    const second_file = try std.Io.Dir.path.join(alloc, &.{ second, ".fx/hooks.json" });
    defer alloc.free(second_file);
    try writeFixture(alloc, second_file, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]},{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    try runtime.setWorkspace(second);
    runtime.refresh();
    try std.testing.expectEqual(@as(usize, 2), runtime.summary().hooks);
    try std.testing.expect(runtime.wants(.stop, null, false));
    try std.testing.expect(!runtime.wants(.stop, null, true));
}

const DispatchJob = struct {
    runtime: *Runtime,
    event: hooks.Event,
    failures: usize = 0,

    fn run(self: *DispatchJob) void {
        var index: usize = 0;
        while (index < 10) : (index += 1) {
            var outcome = self.runtime.dispatch(std.testing.allocator, self.event, false, null) catch {
                self.failures += 1;
                continue;
            };
            if (outcome) |*value| value.deinit(std.testing.allocator);
        }
    }
};

const RefreshJob = struct {
    runtime: *Runtime,
    fixture: *const Fixture,

    fn run(self: *RefreshJob) void {
        var index: usize = 0;
        while (index < 10) : (index += 1) {
            // A round whose text or write fails is skipped: the other rounds still race the refresh.
            const text = std.testing.allocator.print(
                "{{\"hooks\":{{\"Stop\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"exit 0 # {d}\"}}]}}]}}}}",
                .{index},
            ) catch continue;
            defer std.testing.allocator.free(text);
            writeProject(std.testing.allocator, self.fixture, text) catch continue;
            self.runtime.refresh();
        }
    }
};

test "many threads may dispatch while files reload" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const fields = [_]hooks.Field{
        .{ .key = "tool_name", .value = .{ .string = "shell" } },
    };
    var first = DispatchJob{ .runtime = &runtime, .event = testEvent(fixture.workspace, &fields) };
    var second = DispatchJob{ .runtime = &runtime, .event = testEvent(fixture.workspace, &fields) };
    var reloads = RefreshJob{ .runtime = &runtime, .fixture = &fixture };

    const one = try std.Thread.spawn(.{}, DispatchJob.run, .{&first});
    const two = try std.Thread.spawn(.{}, DispatchJob.run, .{&second});
    const three = try std.Thread.spawn(.{}, RefreshJob.run, .{&reloads});
    one.join();
    two.join();
    three.join();

    try std.testing.expectEqual(@as(usize, 0), first.failures);
    try std.testing.expectEqual(@as(usize, 0), second.failures);
    try std.testing.expect(runtime.summary().hooks >= 1);
}

fn testSession(session_id: []const u8, cwd: []const u8, trust_required: bool) SessionInfo {
    return .{
        .session_id = session_id,
        .surface = .interactive,
        .cwd = cwd,
        .permission_mode = "auto",
        .trust_required = trust_required,
    };
}

/// Writes a profile whose one SessionEnd hook appends its input to `out_path`.
fn writeSessionEndProfile(alloc: std.mem.Allocator, fixture: *const Fixture, out_path: []const u8) !void {
    const command = try std.mem.concat(alloc, u8, &.{ "cat >> '", out_path, "'" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"SessionEnd\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeProfile(alloc, fixture, text);
}

/// What the SessionEnd hook wrote under the fixture's tmp dir, or empty when nothing was written.
fn readSessionEndOutput(alloc: std.mem.Allocator, fixture: *const Fixture) ![]u8 {
    var file = fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/session_end.txt", .{}) catch |err| switch (err) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 65536);
}

test "beginSession is true only the first time for a session id" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();

    try std.testing.expect(try runtime.beginSession(testSession("s-1", fixture.workspace, false)));
    try std.testing.expect(!(try runtime.beginSession(testSession("s-1", fixture.workspace, false))));
    try std.testing.expect(try runtime.beginSession(testSession("s-2", fixture.workspace, false)));
}

test "a session start context is kept, cut to the text limit, and unknown ids get none" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    _ = try runtime.beginSession(testSession("s-1", fixture.workspace, false));

    try runtime.setSessionContext("s-1", "use British spelling");
    const kept = (try runtime.sessionContext(alloc, "s-1")).?;
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("use British spelling", kept);
    try std.testing.expect((try runtime.sessionContext(alloc, "unknown")) == null);

    const long = try alloc.alloc(u8, hooks.limits.text_chars + 5);
    defer alloc.free(long);
    @memset(long, 'a');
    try runtime.setSessionContext("s-1", long);
    const cut = (try runtime.sessionContext(alloc, "s-1")).?;
    defer alloc.free(cut);
    try std.testing.expectEqual(hooks.limits.text_chars, cut.len);
}

test "endSession runs the SessionEnd hooks once, with the reason" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const out = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "session_end.txt" });
    defer alloc.free(out);
    try writeSessionEndProfile(alloc, &fixture, out);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-1", fixture.workspace, false));

    runtime.endSession("s-1", "clear");
    // The session is gone after the first end, so a second end runs no hook.
    runtime.endSession("s-1", "clear");
    // A switch runs its hook in the background, so the test waits for that run before it reads what the hook wrote.
    runtime.waitDetached();

    const written = try readSessionEndOutput(alloc, &fixture);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "\"hook_event_name\":\"SessionEnd\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"reason\":\"clear\"") != null);
    const first = std.mem.find(u8, written, "SessionEnd") orelse return error.MissingSessionEnd;
    try std.testing.expect(std.mem.find(u8, written[first + 1 ..], "SessionEnd") == null);
}

test "deinit ends a session that is still open, with the reason exit" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const out = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "session_end.txt" });
    defer alloc.free(out);
    try writeSessionEndProfile(alloc, &fixture, out);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-2", fixture.workspace, false));
    // No defer: the test ends the runtime itself, and the hook must already have run.
    runtime.deinit();

    const written = try readSessionEndOutput(alloc, &fixture);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "\"reason\":\"exit\"") != null);
}

test "a subagent session never runs SessionEnd, when it ends or when the runtime is freed" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const out = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "session_end.txt" });
    defer alloc.free(out);
    try writeSessionEndProfile(alloc, &fixture, out);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    runtime.refresh();

    // A control: an interactive session's end runs its hook, so the subagent checks below are not vacuous.
    _ = try runtime.beginSession(testSession("s-1", fixture.workspace, false));
    runtime.endSession("s-1", "clear");
    runtime.waitDetached();
    const control = try readSessionEndOutput(alloc, &fixture);
    defer alloc.free(control);
    try std.testing.expect(std.mem.find(u8, control, "SessionEnd") != null);

    var child = testSession("child-1", fixture.workspace, false);
    child.surface = .subagent;
    _ = try runtime.beginSession(child);
    runtime.endSession("child-1", "clear");

    var open_child = testSession("child-2", fixture.workspace, false);
    open_child.surface = .subagent;
    _ = try runtime.beginSession(open_child);
    // No defer: the runtime is freed here, and the subagent still open must not run a hook either.
    runtime.deinit();

    const written = try readSessionEndOutput(alloc, &fixture);
    defer alloc.free(written);
    try std.testing.expectEqualStrings(control, written);
}

/// What a background Notification hook wrote under the fixture's workspace, or empty when nothing was written.
fn readBackgroundOutput(alloc: std.mem.Allocator, fixture: *const Fixture) ![]u8 {
    var file = fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/background.txt", .{}) catch |err| switch (err) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 65536);
}

test "a background run reaches the hook, and waitDetached waits for it" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "background.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "sleep 0.3; echo ran > '", marker, "'" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeProfile(alloc, &fixture, text);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    // The event's strings live in buffers the test overwrites right after the call, so the job must hold its own copies.
    const cwd = try alloc.dupe(u8, fixture.workspace);
    defer alloc.free(cwd);
    const mode = try alloc.dupe(u8, "auto");
    defer alloc.free(mode);
    const message = try alloc.dupe(u8, "build finished");
    defer alloc.free(message);
    const fields = [_]hooks.Field{.{ .key = "message", .value = .{ .string = message } }};
    const ev: hooks.Event = .{
        .name = .notification,
        .scope = .{ .surface = .interactive, .cwd = cwd, .project_dir = cwd, .permission_mode = mode },
        .fields = &fields,
    };
    runtime.dispatchDetached(ev, false);
    @memset(cwd, 'x');
    @memset(mode, 'x');
    @memset(message, 'x');

    // Exit cancels background runs (see `deinit`), so this test waits for the run before it exits.
    runtime.waitDetached();
    runtime.deinit();
    runtime_live = false;

    const written = try readBackgroundOutput(alloc, &fixture);
    defer alloc.free(written);
    try std.testing.expectEqualStrings("ran\n", written);
}

test "a background run for an event nothing listens to starts no thread" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}");

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const ev: hooks.Event = .{
        .name = .notification,
        .scope = .{ .surface = .interactive, .cwd = fixture.workspace, .project_dir = fixture.workspace, .permission_mode = "auto" },
    };
    runtime.dispatchDetached(ev, false);

    const io = io_mod.getIo();
    runtime.mutex.lockUncancelable(io);
    const running = runtime.detached_running;
    runtime.mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 0), running);
}

test "a queued note past the cap is dropped, and the earlier notes stay" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();

    var index: usize = 0;
    while (index <= max_pending_notes) : (index += 1) {
        var buf: [32]u8 = undefined;
        const note = try std.mem.print(&buf, "note {d}", .{index});
        try runtime.queueSessionNote("s", note);
    }
    try std.testing.expectEqual(max_pending_notes, runtime.pending_notes.items.len);

    const taken = (try runtime.takeSessionNotes(alloc, "s")).?;
    defer alloc.free(taken);
    try std.testing.expect(std.mem.find(u8, taken, "note 0\n\n") != null);
    try std.testing.expect(std.mem.find(u8, taken, "note 63") != null);
    try std.testing.expect(std.mem.find(u8, taken, "note 64") == null);
}

test "the instruction answer cache forgets its oldest answer past the cap" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();

    var index: usize = 0;
    while (index <= max_instruction_decisions) : (index += 1) {
        var buf: [48]u8 = undefined;
        const path = try std.mem.print(&buf, "/fixture/AGENTS-{d}.md", .{index});
        try runtime.rememberInstructionDecision("s", path, 1, true);
    }
    try std.testing.expectEqual(max_instruction_decisions, runtime.instruction_decisions.items.len);
    try std.testing.expectEqual(@as(?bool, null), runtime.instructionDecision("s", "/fixture/AGENTS-0.md", 1));
    try std.testing.expectEqual(@as(?bool, true), runtime.instructionDecision("s", "/fixture/AGENTS-1.md", 1));
    try std.testing.expectEqual(@as(?bool, true), runtime.instructionDecision("s", "/fixture/AGENTS-512.md", 1));
}

test "a background run past the cap does not start, and the earlier runs still finish" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const gate = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "gate" });
    defer alloc.free(gate);
    const ran = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "ran.txt" });
    defer alloc.free(ran);
    // Each run waits for the gate file, then appends one line to ran.txt. The gate stays closed until
    // every dispatch has returned, so no run finishes early and the running count is the cap.
    const command = try std.mem.concat(alloc, u8, &.{ "while [ ! -e '", gate, "' ]; do sleep 0.01; done; echo ran >> '", ran, "'" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeProfile(alloc, &fixture, text);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const fields = [_]hooks.Field{.{ .key = "message", .value = .{ .string = "build finished" } }};
    const ev: hooks.Event = .{
        .name = .notification,
        .scope = .{ .surface = .interactive, .cwd = fixture.workspace, .project_dir = fixture.workspace, .permission_mode = "auto" },
        .fields = &fields,
    };
    var index: usize = 0;
    while (index <= max_detached_runs) : (index += 1) runtime.dispatchDetached(ev, false);

    const io = io_mod.getIo();
    runtime.mutex.lockUncancelable(io);
    const running = runtime.detached_running;
    runtime.mutex.unlock(io);
    try std.testing.expectEqual(max_detached_runs, running);

    try writeFixture(alloc, gate, "open");
    runtime.waitDetached();
    runtime.deinit();
    runtime_live = false;

    var file = try fixture.tmp.dir.openFile(io, "workspace/ran.txt", .{});
    defer file.close(io);
    const written = try io_mod.readFileToEnd(alloc, &file, 65536);
    defer alloc.free(written);
    var lines: usize = 0;
    for (written) |byte| {
        if (byte == '\n') lines += 1;
    }
    try std.testing.expectEqual(max_detached_runs, lines);
}

/// How long a test waits for a hook to write its pid. The hook writes it before anything else, so the
/// write is the signal that the hook is running.
const hook_start_deadline_ms = 5000;
/// The longest an exit may take in the tests below. Each of their hooks sleeps 30 s, so this is far below that.
const exit_limit_ms = 5000;

/// The pid that a hook wrote to `signal` with `echo $$ > path`. Gives up after `hook_start_deadline_ms`, so a
/// hook that never starts fails the test instead of hanging it.
fn waitForHookPid(signal: *test_signal.Signal) !std.posix.pid_t {
    var buf: [64]u8 = undefined;
    const line = signal.waitLine(&buf, hook_start_deadline_ms) catch |err| switch (err) {
        error.Timeout => return error.HookDidNotStart,
        else => return err,
    };
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, line, " \n"), 10);
}

/// Whether a process group has no members left, by the kernel's answer to signal 0 (the same check as process.zig's `groupGone`).
fn groupGone(group: std.posix.pid_t) bool {
    std.posix.kill(-group, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// Writes a SessionEnd hook that records its pid in `pid_path` and then sleeps 30 s.
fn writeSleepingSessionEnd(alloc: std.mem.Allocator, fixture: *const Fixture, pid_path: []const u8) !void {
    const command = try std.mem.concat(alloc, u8, &.{ "echo $$ > '", pid_path, "'; exec sleep 30" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"SessionEnd\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeProfile(alloc, fixture, text);
}

test "deinit stops a background run at once, and its group is gone" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try test_signal.Signal.create(alloc, fixture.workspace, "background.pid");
    defer pid_signal.deinit(alloc);
    const command = try std.mem.concat(alloc, u8, &.{ "echo $$ > '", pid_signal.path, "'; exec sleep 30" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeProfile(alloc, &fixture, text);

    var env = try testEnv(alloc);
    defer env.deinit();
    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    runtime.native.base_env = &env;
    runtime.refresh();

    const fields = [_]hooks.Field{.{ .key = "message", .value = .{ .string = "build finished" } }};
    const ev: hooks.Event = .{
        .name = .notification,
        .scope = .{ .surface = .interactive, .cwd = fixture.workspace, .project_dir = fixture.workspace, .permission_mode = "auto" },
        .fields = &fields,
    };
    runtime.dispatchDetached(ev, false);
    const pid = try waitForHookPid(&pid_signal);

    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.deinit();
    runtime_live = false;
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;

    try std.testing.expect(elapsed < exit_limit_ms);
    try std.testing.expect(groupGone(pid));
}

test "a SessionEnd hook that outlives the exit budget is stopped at it, and its group is gone" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try test_signal.Signal.create(alloc, fixture.workspace, "session_end.pid");
    defer pid_signal.deinit(alloc);
    try writeSleepingSessionEnd(alloc, &fixture, pid_signal.path);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-5", fixture.workspace, false));
    // No defer: the test ends the runtime itself, so the time it takes is the exit.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.deinit();
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;

    const pid = try waitForHookPid(&pid_signal);
    try std.testing.expect(elapsed < exit_limit_ms);
    try std.testing.expect(groupGone(pid));
}

test "endSession with reason exit runs its SessionEnd hook under the same budget" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try test_signal.Signal.create(alloc, fixture.workspace, "session_end_exit.pid");
    defer pid_signal.deinit(alloc);
    try writeSleepingSessionEnd(alloc, &fixture, pid_signal.path);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-6", fixture.workspace, false));
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.endSession("s-6", "exit");
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;

    const pid = try waitForHookPid(&pid_signal);
    try std.testing.expect(elapsed < exit_limit_ms);
    try std.testing.expect(groupGone(pid));
}

test "endSession with reason other returns at once, and deinit stops its SessionEnd hook" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try test_signal.Signal.create(alloc, fixture.workspace, "switch_session_end.pid");
    defer pid_signal.deinit(alloc);
    try writeSleepingSessionEnd(alloc, &fixture, pid_signal.path);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-9", fixture.workspace, false));

    // A switch is not an exit: its SessionEnd hook runs in the background, so the call returns before the hook's 30 s sleep.
    const switched = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.endSession("s-9", "other");
    const switch_elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - switched;
    try std.testing.expect(switch_elapsed < exit_limit_ms);

    // The hook does run: it writes its pid, then sleeps, so its group is alive when the switch has returned.
    const pid = try waitForHookPid(&pid_signal);
    try std.testing.expect(!groupGone(pid));

    // Exit cancels the background run at once, and the hook's group is gone.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.deinit();
    runtime_live = false;
    const exit_elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expect(exit_elapsed < exit_limit_ms);
    try std.testing.expect(groupGone(pid));
}

/// What the shared-budget test allows on top of one budget, for the hook's start-up and the trace lines.
const exit_budget_margin_ms = 1000;

test "exit SessionEnd runs of one runtime share one budget, not one budget each" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try test_signal.Signal.create(alloc, fixture.workspace, "shared_budget.pid");
    defer pid_signal.deinit(alloc);
    try writeSleepingSessionEnd(alloc, &fixture, pid_signal.path);

    var runtime = try Runtime.init(alloc, .{ .enabled = true, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    runtime.refresh();
    _ = try runtime.beginSession(testSession("s-7", fixture.workspace, false));
    _ = try runtime.beginSession(testSession("s-8", fixture.workspace, false));
    // Each session's SessionEnd hook would sleep 30 s. With one shared budget, the second exit finds it spent.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    runtime.endSession("s-7", "exit");
    runtime.endSession("s-8", "exit");
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;

    const pid = try waitForHookPid(&pid_signal);
    try std.testing.expect(elapsed < session_end_exit_budget_ms + exit_budget_margin_ms);
    try std.testing.expect(groupGone(pid));
}

test "queued session notes reach one session's next turn, in order, and are taken once" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();

    try runtime.queueSessionNote("s-1", "first");
    try runtime.queueSessionNote("s-2", "other session");
    try runtime.queueSessionNote("s-1", "second");
    // Nothing takes this note, so deinit must free it.
    try runtime.queueSessionNote("s-3", "left for deinit");

    const both = (try runtime.takeSessionNotes(alloc, "s-1")) orelse return error.MissingNotes;
    defer alloc.free(both);
    try std.testing.expectEqualStrings("first\n\nsecond", both);
    try std.testing.expect((try runtime.takeSessionNotes(alloc, "s-1")) == null);

    const other = (try runtime.takeSessionNotes(alloc, "s-2")) orelse return error.MissingNotes;
    defer alloc.free(other);
    try std.testing.expectEqualStrings("other session", other);
}

test "ending a session drops its queued notes and instruction answers, and keeps another session's" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    try std.testing.expect(try runtime.beginSession(testSession("s-1", fixture.workspace, false)));
    try std.testing.expect(try runtime.beginSession(testSession("s-2", fixture.workspace, false)));
    try runtime.queueSessionNote("s-1", "first session note");
    try runtime.queueSessionNote("s-2", "second session note");
    try runtime.rememberInstructionDecision("s-1", "/workspace/AGENTS.md", 3, true);
    try runtime.rememberInstructionDecision("s-2", "/workspace/AGENTS.md", 3, false);

    runtime.endSession("s-1", "exit");

    try std.testing.expect((try runtime.takeSessionNotes(alloc, "s-1")) == null);
    try std.testing.expectEqual(@as(?bool, null), runtime.instructionDecision("s-1", "/workspace/AGENTS.md", 3));
    const kept = (try runtime.takeSessionNotes(alloc, "s-2")) orelse return error.MissingNotes;
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("second session note", kept);
    try std.testing.expectEqual(@as(?bool, false), runtime.instructionDecision("s-2", "/workspace/AGENTS.md", 3));
}

test "an instruction decision is remembered per session, path, and stamp" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();
    const path = "/workspace/sub/AGENTS.md";

    try runtime.rememberInstructionDecision("s-1", path, 7, false);
    try std.testing.expectEqual(@as(?bool, false), runtime.instructionDecision("s-1", path, 7));
    // A changed stamp is no answer, so the file is asked again.
    try std.testing.expectEqual(@as(?bool, null), runtime.instructionDecision("s-1", path, 8));

    // A new stamp replaces the answer kept for the same path.
    try runtime.rememberInstructionDecision("s-1", path, 8, true);
    try std.testing.expectEqual(@as(?bool, true), runtime.instructionDecision("s-1", path, 8));
    try std.testing.expectEqual(@as(?bool, null), runtime.instructionDecision("s-1", path, 7));

    // Another session keeps its own answer for the same path and stamp.
    try std.testing.expectEqual(@as(?bool, null), runtime.instructionDecision("s-2", path, 8));
    try runtime.rememberInstructionDecision("s-2", path, 8, false);
    try std.testing.expectEqual(@as(?bool, false), runtime.instructionDecision("s-2", path, 8));
    try std.testing.expectEqual(@as(?bool, true), runtime.instructionDecision("s-1", path, 8));
}

test "a queued session note is cut to the text limit" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    var runtime = try Runtime.init(alloc, .{ .enabled = false, .home = fixture.home, .workspace_root = fixture.workspace });
    defer runtime.deinit();

    const long = try alloc.alloc(u8, hooks.limits.text_chars + 5);
    defer alloc.free(long);
    @memset(long, 'x');
    try runtime.queueSessionNote("s-1", long);

    const taken = (try runtime.takeSessionNotes(alloc, "s-1")) orelse return error.MissingNotes;
    defer alloc.free(taken);
    try std.testing.expectEqual(@as(usize, hooks.limits.text_chars), taken.len);
}
