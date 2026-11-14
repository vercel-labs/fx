//! fx doctor's network and process checks, under one deadline.
//!
//! The provider catalog request runs as a `std.Io` task and writes only its
//! own slot, then sets `done` with release. Each MCP server is checked by its
//! own `fx mcp show NAME --json` child, so one process makes one connect, and
//! at most `serverCap()` of them run at a time; the rest wait in a queue that
//! `wait` starts from as slots free. In a repository, `gh repo view --json
//! url` runs as one more child, outside that cap. Each child runs in its own
//! process group. One `std.Io` task per child reads its pipe to the end,
//! reaps it, and then kills whatever the child left in its group.
//!
//! `wait` stops and joins all of it before it returns. At the deadline, or
//! when an ending signal arrives, it notes which probes finished in time,
//! cancels the catalog request and awaits it, kills every child still running
//! together with every process it started (also those in groups of their
//! own, such as the stdio servers an `fx mcp show` child starts), and joins
//! every waiter. The signal handler only records the signal; doctor's own
//! thread does the stopping and then ends by the signal. The caller reads
//! each result once, and a probe that finished after the deadline counts as
//! not finished (`tests/tla/doctor/Doctor.tla` NoTornReport,
//! NoChildAfterExit, NoTaskAfterReport, NoStartAfterSignalSeen, Reports).
//!
//! Probes are allocated with `std.heap.c_allocator` and left to the process
//! exit, which follows the report.
const std = @import("std");
const builtin = @import("builtin");
const model_catalog = @import("../gateway/model_catalog.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_runtime = @import("../mcp_host/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const process_tree = @import("../execution/process_tree.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const child_status = @import("doctor_child_status.zig");

const Allocator = std.mem.Allocator;
const Check = doctor_runtime.Check;
const CheckStatus = doctor_runtime.CheckStatus;
const ServerResult = output_contracts.McpServerResult;
const ChildStatusReader = child_status.ChildStatusReader;
const appendCheck = doctor_runtime.appendCheckOwnedFix;

const default_deadline_ms: i64 = 5_000;
const max_test_deadline_ms: i64 = 60_000;
/// After the deadline kills the children still running, how long their
/// waiters get to reap them before `wait` cancels the ones still blocked.
const reap_grace_ms: i64 = 1_000;
/// How long the stops of the checks still running get, all together, to
/// land before doctor looks at what each one started.
const stop_land_ms: i64 = 100;
/// How often `wait` looks at the done flags and the stop signal, and starts
/// queued MCP server checks.
const poll_ms: u64 = 5;
/// The fewest and the most MCP server checks that run at once.
const min_server_checks: usize = 4;
const max_server_checks: usize = 16;
/// The most of the limit a queued MCP server check must have left to start,
/// and the part of a shorter limit it needs instead (`checkShareMs`).
const max_check_share_ms: i64 = 1_000;
const check_share_divisor: i64 = 4;
/// gh's exit code for a command that needs a sign-in (`gh help exit-codes`).
const gh_auth_required: u8 = 4;

/// The one deadline for every probe. `FX_TEST_DOCTOR_DEADLINE_MS` shortens it
/// for tests.
pub fn deadlineMs() i64 {
    return parseDeadlineMs(io_mod.getenv("FX_TEST_DOCTOR_DEADLINE_MS"));
}

fn parseDeadlineMs(raw: ?[]const u8) i64 {
    const value = std.fmt.parseInt(i64, raw orelse return default_deadline_ms, 10) catch return default_deadline_ms;
    if (value <= 0 or value > max_test_deadline_ms) return default_deadline_ms;
    return value;
}

pub const CatalogOutcome = union(enum) {
    loaded: struct {
        has_model: bool,
        refused_key: bool,
        /// Why only the public list loaded; null when the provider answered
        /// for the credential.
        public_only: ?credentials.CatalogPublicOnlyReason,
    },
    failed: model_catalog.FailureCategory,
};

pub const CatalogProbe = struct {
    provider: gateway_provider.CliModelCatalogProvider,
    access: credentials.CatalogAccess,
    endpoint: []const u8,
    model: []const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// Whether the request finished by the deadline, as `wait` saw it. A
    /// result that came later is dropped.
    in_time: bool = false,
    /// Why no task could run the request; the probe is then done at once.
    start_error: ?anyerror = null,
    outcome: CatalogOutcome = .{ .failed = .runtime },
    task: ?std.Io.Future(void) = null,

    fn run(self: *CatalogProbe) void {
        const result = self.provider.fetch(std.heap.c_allocator, .{
            .access = self.access,
            .endpoint = self.endpoint,
            .cancel_flag = &self.cancel,
        });
        self.outcome = switch (result) {
            .loaded => |loaded| .{ .loaded = .{
                .has_model = contains(loaded.ids.items, self.model),
                .refused_key = if (loaded.provenance.fallback_failure) |f| f.category == .authentication else false,
                .public_only = loaded.provenance.access.public_only_reason,
            } },
            .failure => |failed| .{ .failed = failed.failure.category },
        };
        self.done.store(true, .release);
    }

    /// Starts the request as a `std.Io` task, which `wait` awaits or
    /// cancels. `self` and everything it borrows must outlive `wait`.
    pub fn start(self: *CatalogProbe) void {
        self.task = io_mod.getIo().concurrent(run, .{self}) catch |err| {
            debug_trace.logf("doctor", "provider check could not start err={s}", .{@errorName(err)});
            self.start_error = err;
            self.done.store(true, .release);
            return;
        };
    }

    /// At the deadline: notes whether the request finished in time, and if
    /// not, cancels it. Either way, joins its task.
    fn finish(self: *CatalogProbe, io: std.Io) void {
        self.in_time = self.done.load(.acquire);
        var task = self.task orelse return;
        self.task = null;
        if (self.in_time) return task.await(io);
        // The fetch polls the flag; the Io cancel also ends a read or a
        // connect that is blocked.
        self.cancel.store(true, .release);
        task.cancel(io);
        debug_trace.logf("doctor", "provider check did not finish by the deadline; its late result is dropped", .{});
    }
};

fn contains(ids: []const []u8, model: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, model)) return true;
    return false;
}

/// One child process, in its own process group, whose exit doctor reads
/// after reaping it.
pub const ProcessProbe = struct {
    name: []const u8,
    /// What `spawn` runs. A queued check keeps it until a slot frees.
    argv: []const []const u8 = &.{},
    child: std.process.Child = undefined,
    /// Taken at spawn, before the waiter can reap the child. It is also the
    /// id of the child's process group.
    pid: std.posix.pid_t = 0,
    spawn_error: ?anyerror = null,
    /// Never started, because too little of the limit was left to start
    /// it, the limit came while it waited for a slot, or a signal came first.
    not_started: bool = false,
    /// Never started for the first of those reasons, before the limit itself
    /// was reached.
    start_cutoff: bool = false,
    /// Killed at the deadline or at an ending signal, so it did not finish
    /// in time.
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    /// Reads the child's stdout as it arrives. Null when doctor needs only
    /// the exit status, and then the child's stdout goes nowhere.
    status: ?*ChildStatusReader = null,
    /// The SIGSTOP `stopTrees` sent has landed. Doctor's own thread only.
    stop_landed: bool = false,
    /// When `spawn` started it, and, once `wait` has stopped it, how long it
    /// had run by then. Doctor's own thread only.
    started_at: i64 = 0,
    stopped_after_ms: i64 = 0,

    /// A check of `argv` that has not started. The caller adds it to the
    /// list `wait` stops before it spawns it.
    fn create(alloc: Allocator, name: []const u8, argv: []const []const u8, status: ?*ChildStatusReader) !*ProcessProbe {
        const probe = try alloc.create(ProcessProbe);
        probe.* = .{ .name = name, .argv = argv, .status = status };
        return probe;
    }

    /// Spawns `argv` in a new process group, with `environ_map` or doctor's
    /// own environment, then reads its stdout to the end and reaps it in a
    /// task of `waiters`. Its stderr, and its stdout when it has no status
    /// reader, go nowhere and are never read. A spawn that fails, or a child
    /// no task can wait for, is done at once with `spawn_error` set.
    fn spawn(self: *ProcessProbe, waiters: *std.Io.Group, environ_map: ?*const std.process.Environ.Map) void {
        // Before the first child exists, so a signal never ends doctor while
        // a child it started is left running.
        installStopHandler();
        debug_trace.logf("doctor", "starting check {s}", .{self.name});
        const io = io_mod.getIo();
        self.started_at = io_mod.milliTimestamp();
        self.child = std.process.spawn(io, .{
            .argv = self.argv,
            .environ_map = environ_map,
            .stdin = .ignore,
            .stdout = if (self.status != null) .pipe else .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            self.spawn_error = err;
            self.done.store(true, .release);
            return;
        };
        self.pid = self.child.id.?;
        waiters.concurrent(io, waitForExit, .{self}) catch |err| {
            // Nothing would read or reap it, so it stops now.
            debug_trace.logf("doctor", "check {s} has no task to wait for it err={s}; killing it with what it started", .{ self.name, @errorName(err) });
            stopTrees(&.{self});
            self.child.kill(io);
            self.spawn_error = err;
            self.done.store(true, .release);
        };
    }

    fn waitForExit(self: *ProcessProbe) void {
        const io = io_mod.getIo();
        if (self.child.stdout) |file| {
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = file.readStreaming(io, &.{&chunk}) catch |err| {
                    if (err == error.Canceled) debug_trace.logf("doctor", "check {s}: stopped reading its output, which a process outside its group held open", .{self.name});
                    break;
                };
                // A read into a buffer with room returns 0 only at the end.
                if (n == 0) break;
                if (self.status) |reader| reader.feed(chunk[0..n]);
            }
        }
        if (self.status) |reader| reader.end();
        // `wait` cancels this task only after it killed the child, so the
        // reap ends at once; it must not be cut short, or the child stays a
        // zombie.
        const protection = io.swapCancelProtection(.blocked);
        self.term = self.child.wait(io) catch null;
        _ = io.swapCancelProtection(protection);
        // Whatever the child started in its group goes with it. The group id
        // stays taken while any member lives, so this reaches only them.
        std.posix.kill(-self.pid, .KILL) catch {};
        self.done.store(true, .release);
    }
};

/// Kills each check in `probes` that is still running, with everything it
/// started, in three steps over all of them: every check's group is
/// stopped, so none starts anything more; doctor waits, `stop_land_ms` in
/// all, until each stop has landed or the check has exited, since kill(2)
/// only queues a SIGSTOP and a check still running could start a server
/// after doctor looked; then each tree is walked and killed. Their waiters
/// then reap them.
fn stopTrees(probes: []const *ProcessProbe) void {
    for (probes) |p| if (!p.done.load(.acquire) and p.pid != 0) std.posix.kill(-p.pid, .STOP) catch {};
    const limit = io_mod.milliTimestamp() + stop_land_ms;
    while (true) {
        var waiting = false;
        for (probes) |p| {
            if (p.stop_landed or p.pid == 0) continue;
            // A check that has exited can start nothing, so it counts as stopped.
            if (p.done.load(.acquire) or (process_tree.processIsStopped(std.heap.c_allocator, p.pid) catch false)) {
                p.stop_landed = true;
            } else {
                waiting = true;
            }
        }
        if (!waiting or io_mod.milliTimestamp() >= limit) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    for (probes) |p| {
        if (p.done.load(.acquire) or p.pid == 0) continue;
        if (!p.stop_landed) debug_trace.logf("doctor", "check {s} did not stop within {d} ms; killing it with what it started anyway", .{ p.name, stop_land_ms });
        killTree(p.pid);
    }
}

/// Kills the process group of `pid`, which `stopTrees` has stopped, and
/// every process `pid` started outside it, such as the stdio MCP servers an
/// `fx mcp show` child starts in groups of their own, and their helper. A
/// group kill alone would leave a server the child had started but not yet
/// told its helper about. A child that started nothing is only killed. Any
/// other tree is stopped and killed whole, and a process the kill skipped is
/// resumed (`process_tree.Tracker`). Only for a child not yet reaped, so its
/// id cannot have been reused.
fn killTree(pid: std.posix.pid_t) void {
    var tree = process_tree.Tracker.init(std.heap.c_allocator) catch return killGroup(pid);
    defer tree.deinit();
    tree.refresh(pid) catch |err| debug_trace.logf("doctor", "check {d}: could not list the processes it started err={s}", .{ pid, @errorName(err) });
    const outside_group = tree.processes.items.len > 0;
    if (outside_group) {
        tree.stopAll();
        // Anything a stop that had not landed yet let it start.
        tree.refresh(pid) catch {};
    }
    // The group goes first, so the pass below, which resumes what it
    // stopped and did not kill, cannot let the child run again.
    killGroup(pid);
    if (!outside_group) return;
    const outside = tree.signalOutsideProcessGroupChecked(.KILL, pid);
    if (outside.incomplete) debug_trace.logf("doctor", "check {d}: some processes it started outside its group could not be killed", .{pid});
}

fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
}

/// The signals that end doctor early. Each child is in its own group, so the
/// terminal's Ctrl-C reaches only doctor, which then stops the children.
const ending_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };
/// The first ending signal, or 0. The handler only records it. Doctor's own
/// thread looks at it after each child it starts and in `wait`, stops every
/// check, and then ends by it with the handler removed.
var stop_signal: std.atomic.Value(@typeInfo(std.posix.SIG).@"enum".tag_type) = .init(0);
var previous_actions: [ending_signals.len]std.posix.Sigaction = undefined;
var handles_ending_signals = false;

/// Only doctor's own thread calls this, before it starts a child.
fn installStopHandler() void {
    if (handles_ending_signals or builtin.is_test) return;
    handles_ending_signals = true;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = recordStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (ending_signals, &previous_actions) |sig, *previous| {
        std.posix.sigaction(sig, &action, previous);
        // A signal doctor was started to ignore stays ignored.
        if (previous.handler.handler == std.posix.SIG.IGN) std.posix.sigaction(sig, previous, null);
    }
}

fn restoreSignalActions() void {
    if (!handles_ending_signals) return;
    handles_ending_signals = false;
    for (ending_signals, previous_actions) |sig, previous| std.posix.sigaction(sig, &previous, null);
}

/// Async-signal-safe: one atomic compare-and-swap, on whichever thread the
/// signal reached.
fn recordStopSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = stop_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
}

fn stopRequested() bool {
    return stop_signal.load(.seq_cst) != 0;
}

/// Ends doctor by the signal `wait` returned, as the signal would have ended
/// it without doctor's handler, which `wait` has removed. Returns only when
/// what doctor found in place lets the process go on.
pub fn endBySignal(sig: std.posix.SIG) void {
    _ = std.c.raise(sig);
}

/// `fx mcp show` and the other `fx mcp` commands read a name that starts
/// with "-" as an option, and take no "--" before a name, so such a server
/// gets no child and no command in its fix.
fn readsAsOption(name: []const u8) bool {
    return name.len > 0 and name[0] == '-';
}

/// How many MCP server checks run at once on this machine (`serverCapFor`).
pub fn serverCap() usize {
    return serverCapFor(std.Thread.getCpuCount() catch min_server_checks);
}

/// One check for each of `cpus` CPUs, between `min_server_checks` and
/// `max_server_checks`, so many servers do not starve each other of the one
/// deadline.
fn serverCapFor(cpus: usize) usize {
    return std.math.clamp(cpus, min_server_checks, max_server_checks);
}

/// How much of a `limit_ms` limit must be left for a queued check to start:
/// `max_check_share_ms`, or a quarter (`check_share_divisor`) of a shorter
/// limit, so a short test limit still starts checks.
fn checkShareMs(limit_ms: i64) i64 {
    return @min(max_check_share_ms, @divTrunc(limit_ms, check_share_divisor));
}

/// Why checks still queued were never started: too little of the limit was
/// left to start one, the limit came while every slot was taken, or an
/// ending signal came.
const DropReason = enum { cutoff, limit, signal };

/// The MCP server checks, one for each idle server in config order. At most
/// `cap` of them run at a time; the ones from `next` on wait for a slot.
pub const ServerChecks = struct {
    probes: []const *ProcessProbe = &.{},
    next: usize = 0,
    cap: usize = 1,
    /// The last moment a queued check may start: the deadline less the
    /// check's share of the limit (`checkShareMs`).
    last_start: i64 = std.math.maxInt(i64),

    /// Starts the queued checks in order while fewer than `cap` run. Before
    /// each start it looks, in this order, at `last_start`, past which it
    /// drops the rest, so a check the limit cuts has had at least its share
    /// of it; then at an ending signal and the deadline. Doctor's own thread
    /// only.
    fn startMore(self: *ServerChecks, waiters: *std.Io.Group, deadline: i64) void {
        while (self.next < self.probes.len and self.running() < self.cap) {
            if (io_mod.milliTimestamp() >= self.last_start) return self.dropQueued(.cutoff);
            if (stopRequested() or io_mod.milliTimestamp() >= deadline) return;
            self.probes[self.next].spawn(waiters, null);
            self.next += 1;
        }
    }

    /// The checks started that have not ended. A check holds its slot until
    /// its waiter has reaped it.
    fn running(self: *const ServerChecks) usize {
        var count: usize = 0;
        for (self.probes[0..self.next]) |p| {
            if (!p.done.load(.acquire)) count += 1;
        }
        return count;
    }

    /// The checks still queued are never started. Each gets a trace line
    /// that names it and says why.
    fn dropQueued(self: *ServerChecks, reason: DropReason) void {
        const why = switch (reason) {
            .cutoff => "too little of doctor's limit was left to start it",
            .limit => "doctor's limit came while it waited for a slot",
            .signal => "doctor got a signal first",
        };
        for (self.probes[self.next..]) |p| {
            debug_trace.logf("doctor", "check {s} was never started, since {s}; dropping it", .{ p.name, why });
            p.start_cutoff = reason == .cutoff;
            p.not_started = true;
            p.done.store(true, .release);
        }
        self.next = self.probes.len;
    }
};

/// Queues one `fx mcp show NAME --json` check for each idle server, appends
/// each to `processes`, and starts the first ones up to `cap`, as
/// `ServerChecks.startMore` allows under `deadline`, which ends a limit of
/// `limit_ms`; `wait` starts the rest. An unapproved, rejected, or disabled
/// server is never idle, so it never gets a check. A queued check is in
/// `processes` before it can start, so `wait` always reaches it.
pub fn startServerChildren(
    alloc: Allocator,
    waiters: *std.Io.Group,
    processes: *std.ArrayList(*ProcessProbe),
    statuses: []const mcp_runtime.Status,
    self_exe: []const u8,
    deadline: i64,
    limit_ms: i64,
    cap: usize,
) !ServerChecks {
    const first = processes.items.len;
    for (statuses) |status| {
        if (status.state != .idle or readsAsOption(status.name)) continue;
        try processes.ensureUnusedCapacity(alloc, 1);
        const name = try alloc.dupe(u8, status.name);
        const argv = try alloc.dupe([]const u8, &.{ self_exe, "mcp", "show", name, "--json" });
        const reader = try alloc.create(ChildStatusReader);
        reader.init();
        processes.appendAssumeCapacity(try ProcessProbe.create(alloc, name, argv, reader));
    }
    // A copy, since gh's append may move the list.
    var servers: ServerChecks = .{
        .probes = try alloc.dupe(*ProcessProbe, processes.items[first..]),
        .cap = @max(1, cap),
        .last_start = deadline - checkShareMs(limit_ms),
    };
    servers.startMore(waiters, deadline);
    return servers;
}

/// Starts `gh repo view --json url` in the workspace, which doctor runs in,
/// unless an ending signal came first, and appends it to `processes`. gh
/// then reads the repository's remotes, the host, the active account,
/// `GH_HOST`, and `GH_REPO` itself, as it does for `fx pr` and `fx issue`.
/// It gets the environment those get, with prompts and the update check
/// turned off, so it never waits on a person or writes its update state.
pub fn startGh(alloc: Allocator, waiters: *std.Io.Group, processes: *std.ArrayList(*ProcessProbe)) !?*ProcessProbe {
    if (stopRequested()) {
        debug_trace.logf("doctor", "check gh was never started, since doctor got a signal first", .{});
        return null;
    }
    try processes.ensureUnusedCapacity(alloc, 1);
    const probe = try ProcessProbe.create(alloc, "gh", &.{ "gh", "repo", "view", "--json", "url" }, null);
    processes.appendAssumeCapacity(probe);
    var environ = io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            probe.spawn_error = err;
            probe.done.store(true, .release);
            return probe;
        },
    };
    defer environ.deinit();
    try environ.put("GH_PROMPT_DISABLED", "1");
    try environ.put("GH_NO_UPDATE_NOTIFIER", "1");
    probe.spawn(waiters, &environ);
    return probe;
}

fn allDone(catalog: ?*CatalogProbe, processes: []const *ProcessProbe) bool {
    if (catalog) |c| if (!c.done.load(.acquire)) return false;
    for (processes) |p| if (!p.done.load(.acquire)) return false;
    return true;
}

/// Waits until every probe is done, the deadline passes, or an ending signal
/// arrives, starting queued server checks as slots free, then stops and
/// joins everything doctor started, so nothing runs after it returns. It
/// notes which probes finished in time, marks the checks still queued as
/// never started, cancels and awaits a catalog request still out, kills
/// every child still running with what it started, gives the waiters a
/// short grace to reap them, and then cancels and joins the waiters. It then
/// removes the signal handler and returns the signal that arrived, if one
/// did, for `endBySignal`.
pub fn wait(deadline: i64, catalog: ?*CatalogProbe, processes: []const *ProcessProbe, waiters: *std.Io.Group, servers: ?*ServerChecks) ?std.posix.SIG {
    const io = io_mod.getIo();
    while (true) {
        if (servers) |queue| queue.startMore(waiters, deadline);
        if (io_mod.milliTimestamp() >= deadline or allDone(catalog, processes) or stopRequested()) break;
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    if (servers) |queue| queue.dropQueued(if (stopRequested()) .signal else .limit);
    const why = if (stopRequested()) "before doctor got a signal" else "by the deadline";
    if (catalog) |c| c.finish(io);
    const stopped_at = io_mod.milliTimestamp();
    for (processes) |p| if (!p.done.load(.acquire) and p.pid != 0) {
        debug_trace.logf("doctor", "check {s} did not finish {s}; killing it with what it started and dropping its late result", .{ p.name, why });
        p.stopped_after_ms = stopped_at - p.started_at;
        p.stopped.store(true, .release);
    };
    stopTrees(processes);
    const reap_deadline = io_mod.milliTimestamp() + reap_grace_ms;
    while (io_mod.milliTimestamp() < reap_deadline and !allDone(null, processes)) {
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    for (processes) |p| if (!p.done.load(.acquire)) {
        debug_trace.logf("doctor", "check {s} was not reaped within the grace; cancelling its waiter", .{p.name});
    };
    waiters.cancel(io);
    // A signal from here on takes the action doctor found in place.
    restoreSignalActions();
    const raw = stop_signal.load(.seq_cst);
    if (raw == 0) return null;
    return @fromBackingInt(raw);
}

/// The network checks doctor waits on, for its wait notice.
pub const Waiting = struct {
    /// The provider whose model list doctor asked for, if it asked.
    provider: ?model_provider.ProviderId = null,
    /// The MCP server checks started or queued.
    mcp_servers: usize = 0,
    gh: enum { not_checked, checking } = .not_checked,
};

/// The line doctor writes to a terminal's stderr while it waits on the
/// network checks it started, such as `checking AI Gateway, 3 MCP servers,
/// and gh (up to 5 s)...`, or null when it started none. The caller owns it.
pub fn waitNotice(alloc: Allocator, waiting: Waiting, deadline_ms: i64) Allocator.Error!?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var server_text: ?[]u8 = null;
    defer if (server_text) |text| alloc.free(text);
    if (waiting.provider) |id| try parts.append(alloc, providerLabel(id));
    if (waiting.mcp_servers > 0) {
        server_text = try alloc.print("{d} MCP server{s}", .{ waiting.mcp_servers, if (waiting.mcp_servers == 1) "" else "s" });
        try parts.append(alloc, server_text.?);
    }
    if (waiting.gh == .checking) try parts.append(alloc, "gh");
    const limit = seconds(deadline_ms);
    const p = parts.items;
    return switch (p.len) {
        0 => null,
        1 => try alloc.print("checking {s} (up to {d} s)...\n", .{ p[0], limit }),
        2 => try alloc.print("checking {s} and {s} (up to {d} s)...\n", .{ p[0], p[1], limit }),
        else => try alloc.print("checking {s}, {s}, and {s} (up to {d} s)...\n", .{ p[0], p[1], p[2], limit }),
    };
}

fn providerLabel(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "AI Gateway",
        .codex => "ChatGPT",
        .grok => "Grok",
        .configured => "the configured provider",
    };
}

/// The provider and model checks from the catalog slot, read after `wait`:
/// a request that had not finished by the deadline is a provider that could
/// not be reached. The credential counts as accepted only when the provider
/// answered for it; a public list says nothing about it.
pub fn catalogChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    probe: *const CatalogProbe,
    provider: model_provider.ProviderId,
    deadline_ms: i64,
) !void {
    const label = providerLabel(provider);
    const login = doctor_runtime.loginCommand(provider);
    if (probe.start_error) |err| {
        try appendCheck(checks, alloc, "provider", .fail, try alloc.print("fx could not start the check of {s} ({s})", .{ label, @errorName(err) }), try alloc.dupe(u8, "run fx doctor again"));
        return;
    }
    if (!probe.in_time) {
        try appendCheck(checks, alloc, "provider", .fail, try alloc.print("could not reach {s} in {d} s", .{ label, seconds(deadline_ms) }), try alloc.dupe(u8, "check the network connection, then run fx doctor again"));
        return;
    }
    switch (probe.outcome) {
        .failed => |category| switch (category) {
            .authentication => try appendCheck(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, login)),
            .rate_limited => try appendCheck(checks, alloc, "provider", .warn, try alloc.print("{s} rate-limited the check, so the credential is not confirmed", .{label}), try alloc.dupe(u8, "run fx doctor again in a minute")),
            .malformed_response => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("{s} sent a model list fx cannot read", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .resource_exhausted => try appendCheck(checks, alloc, "provider", .fail, try alloc.dupe(u8, "fx ran out of memory reading the model list"), try alloc.dupe(u8, "close other programs, then run fx doctor again")),
            // The provider answered, but with an error status.
            .gateway_unavailable, .http_status => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("{s} answered the check with an error", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .cancellation, .transport, .runtime => try appendCheck(checks, alloc, "provider", .fail, try alloc.print("could not reach {s}", .{label}), try alloc.dupe(u8, "check the network connection, then run fx doctor again")),
        },
        .loaded => |loaded| {
            if (loaded.refused_key) {
                try appendCheck(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, login));
            } else if (loaded.public_only) |reason| {
                const fix = if (reason == .fx_login_team_required) "fx teams" else login;
                try appendCheck(checks, alloc, "auth", .warn, try alloc.print("{s} sent only its public model list, so the credential is not confirmed", .{label}), try alloc.dupe(u8, fix));
            } else {
                try appendCheck(checks, alloc, "auth", .ok, try alloc.print("{s} accepted the credential", .{label}), null);
            }
            if (loaded.has_model) {
                try appendCheck(checks, alloc, "model", .ok, try alloc.print("{s} is available", .{probe.model}), null);
            } else if (loaded.public_only != null) {
                try appendCheck(checks, alloc, "model", .warn, try alloc.print("{s} is not in the models fx can see", .{probe.model}), try alloc.dupe(u8, "fx models"));
            } else {
                try appendCheck(checks, alloc, "model", .fail, try alloc.print("{s} is not an available model", .{probe.model}), try alloc.dupe(u8, "fx models"));
            }
        },
    }
}

fn seconds(ms: i64) i64 {
    return @max(1, @divCeil(ms, 1000));
}

/// One line for each MCP server checked by a child, read after `wait`, and
/// what doctor found for each in `results`.
pub fn serverChildChecks(
    checks: *std.ArrayList(Check),
    results: *std.ArrayList(ServerResult),
    alloc: Allocator,
    children: []const *ProcessProbe,
    deadline_ms: i64,
) !void {
    for (children) |c| {
        try results.ensureUnusedCapacity(alloc, 1);
        const found = try serverChildCheck(checks, alloc, c, deadline_ms);
        results.appendAssumeCapacity(.{ .name = c.name, .connection = found.connection, .authentication = found.authentication });
    }
}

const Found = struct {
    connection: ServerResult.Connection,
    authentication: ServerResult.Authentication = .not_checked,
};

/// `fx mcp VERB NAME` with NAME quoted for a shell, so a name from a config
/// file is always one argument and never a command of its own. The caller
/// owns it.
fn mcpCommand(alloc: Allocator, verb: []const u8, name: []const u8) Allocator.Error![]u8 {
    const quoted = try command_lex.quoteWord(alloc, name);
    defer alloc.free(quoted);
    return alloc.print("fx mcp {s} {s}", .{ verb, quoted });
}

fn serverChildCheck(checks: *std.ArrayList(Check), alloc: Allocator, c: *const ProcessProbe, deadline_ms: i64) !Found {
    const failed: Found = .{ .connection = .failed };
    const timed_out: Found = .{ .connection = .timed_out };
    if (c.not_started) {
        const detail = if (c.start_cutoff)
            try alloc.print("{s} was not checked: too little of doctor's {d} s limit was left to start it", .{ c.name, seconds(deadline_ms) })
        else
            try alloc.print("{s} was not checked: doctor reached its {d} s limit before it could start the check", .{ c.name, seconds(deadline_ms) });
        try appendCheck(checks, alloc, "mcp", .fail, detail, try mcpCommand(alloc, "show", c.name));
        return timed_out;
    }
    if (c.stopped.load(.acquire)) {
        // Its own time, which a check started late in the limit had less of.
        const tenths = @divTrunc(c.stopped_after_ms + 50, 100);
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} did not answer in {d}.{d} s, when doctor's {d} s limit ended", .{ c.name, @divTrunc(tenths, 10), @mod(tenths, 10), seconds(deadline_ms) }), try mcpCommand(alloc, "show", c.name));
        return timed_out;
    }
    if (c.spawn_error) |err| {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx could not start a check ({s})", .{ c.name, @errorName(err) }), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    const term = c.term orelse {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx lost its check", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    };
    if (term != .exited) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx crashed while checking it ({f})", .{ c.name, term }), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    const parsed = c.status.?.result() catch {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx could not read its check", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    };
    if (std.mem.eql(u8, parsed.status, "ready")) {
        try appendCheck(checks, alloc, "mcp", .ok, try alloc.print("{s} ready, {d} tool{s}", .{ c.name, parsed.tools, if (parsed.tools == 1) "" else "s" }), null);
        return .{ .connection = .ready, .authentication = .ok };
    }
    if (std.mem.eql(u8, parsed.status, "needs_login")) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} needs sign-in", .{c.name}), try mcpCommand(alloc, "login", c.name));
        return .{ .connection = .failed, .authentication = .needs_login };
    }
    if (std.mem.eql(u8, parsed.status, "connecting") or std.mem.eql(u8, parsed.status, "retrying") or std.mem.eql(u8, parsed.status, "not_started")) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start", .{c.name}), try mcpCommand(alloc, "show", c.name));
        return failed;
    }
    try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} {s}: {s}", .{ c.name, parsed.status, parsed.err orelse "no detail" }), try mcpCommand(alloc, "show", c.name));
    return failed;
}

/// Lines for servers that get no child, as the doctor process's own runtime
/// reads them without starting any.
pub fn serverStatusChecks(checks: *std.ArrayList(Check), alloc: Allocator, statuses: []const mcp_runtime.Status) !void {
    for (statuses) |s| {
        const status, const detail = (try statusLine(alloc, s)) orelse continue;
        const fix = statusFix(alloc, s) catch |err| {
            alloc.free(detail);
            return err;
        };
        try appendCheck(checks, alloc, "mcp", status, detail, fix);
    }
}

/// The status and detail of a server that gets no child, or null when it
/// gets one or needs no line. The caller owns the detail.
fn statusLine(alloc: Allocator, s: mcp_runtime.Status) Allocator.Error!?struct { CheckStatus, []u8 } {
    return switch (s.state) {
        .idle => if (readsAsOption(s.name)) .{ .warn, try alloc.print("{s} was not checked: fx mcp show reads a name that starts with \"-\" as an option", .{s.name}) } else null,
        .waiting_for_approval => .{ .warn, try alloc.print("{s} is waiting for approval", .{s.name}) },
        .missing_env, .invalid_env => .{ .fail, try alloc.print("{s} needs {s}", .{ s.name, s.missing orelse "an environment variable" }) },
        .unsupported => .{ .warn, try alloc.print("{s} uses a transport fx does not support", .{s.name}) },
        .failed => .{ .fail, try alloc.print("{s} failed: {s}", .{ s.name, s.last_error orelse "no detail" }) },
        .connecting, .ready, .retrying, .rejected, .disabled => null,
    };
}

/// The fix on a server's status line. Every `fx mcp` command reads a name
/// that starts with "-" as an option and takes no "--" before it, so such a
/// server, whatever its state, can only be renamed in the file it comes
/// from; that is decided before the state is. The caller owns it.
fn statusFix(alloc: Allocator, s: mcp_runtime.Status) Allocator.Error![]u8 {
    if (readsAsOption(s.name)) return alloc.print("rename the server in {s} so its name does not start with \"-\"", .{configFile(s.source)});
    return switch (s.state) {
        .waiting_for_approval => mcpCommand(alloc, "approve", s.name),
        .missing_env, .invalid_env => {
            const variable = if (s.missing) |name| try command_lex.quoteWord(alloc, name) else try alloc.dupe(u8, "the variable");
            defer alloc.free(variable);
            return alloc.print("set {s}, then run fx doctor again", .{variable});
        },
        .unsupported => {
            const quoted = try command_lex.quoteWord(alloc, s.name);
            defer alloc.free(quoted);
            return alloc.print("give {s} a stdio command or an HTTP URL, or run fx mcp remove {s}", .{ quoted, quoted });
        },
        .idle, .failed, .connecting, .ready, .retrying, .rejected, .disabled => mcpCommand(alloc, "show", s.name),
    };
}

/// The file a server's config comes from, as fx names it to the user. Only
/// an ACP client gives `acp` servers, and doctor never runs under one.
fn configFile(source: mcp_contract.ConfigSource) []const u8 {
    return switch (source) {
        .workspace => ".mcp.json",
        .profile, .acp => profile_paths.displayText("~/.fx/mcp.json"),
    };
}

/// The gh line, read after `wait`, from how `gh repo view --json url` ended:
/// 0 when gh can use this repository, `gh_auth_required` when it needs a
/// sign-in. gh's output is never read, since it can hold remote URLs and
/// tokens; only its exit status is traced. Null `probe`: a signal ended the
/// checks before gh started, and doctor does not report.
pub fn ghCheck(checks: *std.ArrayList(Check), alloc: Allocator, probe: ?*const ProcessProbe, deadline_ms: i64) !void {
    const p = probe orelse return;
    const see_why = "run gh repo view to see why";
    if (p.spawn_error) |err| {
        const why = "fx pr --create and fx issue --create need it";
        if (err == error.FileNotFound) {
            return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI not found on PATH; {s}", .{why}), try alloc.dupe(u8, "install gh from https://cli.github.com"));
        }
        return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI could not start ({s}); {s}", .{ @errorName(err), why }), try alloc.dupe(u8, "gh --version"));
    }
    if (p.stopped.load(.acquire)) {
        return appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh repo view did not answer in {d} s", .{seconds(deadline_ms)}), try alloc.dupe(u8, see_why));
    }
    const term = p.term orelse return appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh repo view gave no result"), try alloc.dupe(u8, see_why));
    debug_trace.logf("doctor", "gh repo view ended {f}", .{term});
    switch (term) {
        .exited => |code| switch (code) {
            0 => try appendCheck(checks, alloc, "gh", .ok, try alloc.dupe(u8, "gh can use this repository"), null),
            gh_auth_required => try appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh is not signed in for this repository"), try alloc.dupe(u8, "gh auth login")),
            else => try appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh could not use this repository"), try alloc.dupe(u8, see_why)),
        },
        else => try appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh repo view ended early ({f})", .{term}), try alloc.dupe(u8, see_why)),
    }
}

fn freeChecks(alloc: Allocator, checks: *std.ArrayList(Check)) void {
    for (checks.items) |*entry| entry.deinit(alloc);
    checks.deinit(alloc);
}

/// Gives `reader` one whole child answer, as `waitForExit` does.
fn answer(reader: *ChildStatusReader, bytes: []const u8) void {
    reader.init();
    reader.feed(bytes);
    reader.end();
}

test "catalog checks cover every outcome the slot can hold after wait" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{
        .provider = undefined,
        .access = .{ .public_only = .no_credential },
        .endpoint = "",
        .model = "m/one",
    };
    const Case = struct { done: bool, outcome: CatalogOutcome, want: []const struct { []const u8, CheckStatus } };
    const cases = [_]Case{
        // A late result counts as no answer, whatever it says.
        .{ .done = false, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = false, .public_only = null } }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .authentication }, .want = &.{.{ "auth", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .rate_limited }, .want = &.{.{ "provider", .warn }} },
        .{ .done = true, .outcome = .{ .failed = .transport }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .resource_exhausted }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = false, .public_only = null } }, .want = &.{ .{ "auth", .ok }, .{ "model", .ok } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = true, .public_only = .authenticated_credential_rejected } }, .want = &.{ .{ "auth", .fail }, .{ "model", .ok } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = false, .refused_key = false, .public_only = null } }, .want = &.{ .{ "auth", .ok }, .{ "model", .fail } } },
        // A public list, such as an fx login with no team loads, never confirms the credential.
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = false, .refused_key = false, .public_only = .fx_login_team_required } }, .want = &.{ .{ "auth", .warn }, .{ "model", .warn } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = false, .public_only = .no_credential } }, .want = &.{ .{ "auth", .warn }, .{ "model", .ok } } },
    };
    for (cases) |case| {
        probe.in_time = case.done;
        probe.outcome = case.outcome;
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try catalogChecks(&checks, alloc, &probe, .gateway, 5_000);
        try std.testing.expectEqual(case.want.len, checks.items.len);
        for (case.want, checks.items) |want, got| {
            try std.testing.expectEqualStrings(want[0], got.name);
            try std.testing.expectEqual(want[1], got.status);
            try std.testing.expectEqual(got.status != .ok, got.fix != null);
        }
    }
}

test "a public list asks for the step that would let the provider answer" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{ .provider = undefined, .access = .{ .public_only = .no_credential }, .endpoint = "", .model = "m", .in_time = true };
    const Case = struct { provider: model_provider.ProviderId, reason: credentials.CatalogPublicOnlyReason, fix: []const u8 };
    for ([_]Case{
        .{ .provider = .gateway, .reason = .fx_login_team_required, .fix = "fx teams" },
        .{ .provider = .gateway, .reason = .fx_login_refresh_required, .fix = "fx login" },
        .{ .provider = .codex, .reason = .chatgpt_subscription, .fix = "fx login codex" },
        .{ .provider = .grok, .reason = .grok_subscription, .fix = "fx login grok" },
    }) |case| {
        probe.outcome = .{ .loaded = .{ .has_model = true, .refused_key = false, .public_only = case.reason } };
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try catalogChecks(&checks, alloc, &probe, case.provider, 5_000);
        try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
        try std.testing.expect(std.mem.endsWith(u8, checks.items[0].detail, "so the credential is not confirmed"));
        try std.testing.expectEqualStrings(case.fix, checks.items[0].fix.?);
    }
}

test "a refused key never reads as accepted" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{ .provider = undefined, .access = .{ .public_only = .no_credential }, .endpoint = "", .model = "m", .in_time = true };
    probe.outcome = .{ .loaded = .{ .has_model = true, .refused_key = true, .public_only = .authenticated_credential_rejected } };
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    try catalogChecks(&checks, alloc, &probe, .gateway, 5_000);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expectEqualStrings("fx login", checks.items[0].fix.?);
}

test "deadline override accepts only a bounded positive number" {
    try std.testing.expectEqual(default_deadline_ms, parseDeadlineMs(null));
    try std.testing.expectEqual(@as(i64, 1), parseDeadlineMs("1"));
    try std.testing.expectEqual(max_test_deadline_ms, parseDeadlineMs("60000"));
    for ([_][]const u8{ "0", "-1", "abc", "", "60001" }) |raw| {
        try std.testing.expectEqual(default_deadline_ms, parseDeadlineMs(raw));
    }
    try std.testing.expectEqual(@as(i64, 1), seconds(1));
    try std.testing.expectEqual(@as(i64, 5), seconds(5_000));
    try std.testing.expectEqual(@as(i64, 2), seconds(1_001));
}

test "a catalog request still out at the deadline is cancelled and joined before wait returns" {
    const Hung = struct {
        returned: std.atomic.Value(bool) = .init(false),
        fn fetch(raw: ?*anyopaque, _: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            // Stands in for a provider that never answers: only the cancel
            // flag ends it.
            while (!input.cancel_flag.?.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            self.returned.store(true, .release);
            return .{ .failure = .{ .access = .init(input.access), .anonymous_fallback_used = false, .failure = .{ .category = .cancellation } } };
        }
    };
    var hung: Hung = .{};
    var probe: CatalogProbe = .{
        .provider = .{ .context = &hung, .fetch_fn = Hung.fetch },
        .access = .{ .public_only = .no_credential },
        .endpoint = "",
        .model = "m",
    };
    probe.start();
    try std.testing.expect(probe.start_error == null);
    var waiters: std.Io.Group = .init;
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, &probe, &.{}, &waiters, null) == null);
    try std.testing.expect(hung.returned.load(.acquire));
    try std.testing.expect(probe.task == null);
    try std.testing.expect(!probe.in_time);
    try std.testing.expect(io_mod.milliTimestamp() - started < 50 + reap_grace_ms);

    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    try catalogChecks(&checks, alloc, &probe, .gateway, 50);
    try std.testing.expectEqualStrings("could not reach AI Gateway in 1 s", checks.items[0].detail);
}

test "a child still running at the deadline is killed with its group and its waiter joined" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var waiters: std.Io.Group = .init;
    var reader: ChildStatusReader = undefined;
    reader.init();
    // The grandchild holds the pipe open, as a server a check started would.
    const probe = try ProcessProbe.create(alloc, "hung", &.{ "/bin/sh", "-c", "sleep 30 & sleep 30" }, &reader);
    probe.spawn(&waiters, null);
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters, null) == null);
    try std.testing.expect(io_mod.milliTimestamp() - started < 50 + reap_grace_ms);
    try std.testing.expect(probe.done.load(.acquire));
    try std.testing.expect(probe.stopped.load(.acquire));
    try std.testing.expect(probe.term.? == .signal);
    // Nothing is left in the child's group, once the system reaps the
    // grandchild it killed.
    var left = true;
    for (0..200) |_| {
        std.posix.kill(-probe.pid, @fromBackingInt(@intCast(0))) catch |err| {
            try std.testing.expectEqual(error.ProcessNotFound, err);
            left = false;
            break;
        };
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(!left);
}

test "a waiter blocked by a process that left the group is cancelled after the grace and still reaps" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const pid_file = try std.Io.Dir.path.join(alloc, &.{ dir, "escaped.pid" });
    defer alloc.free(pid_file);
    // A new session, so the group kill misses it, and it keeps stdout open.
    const script = "perl -MPOSIX -e 'POSIX::setsid(); open(F, \">\", $ARGV[0]) or exit 1; print F $$; close F; sleep 20' \"$0\" & exit 0";
    var waiters: std.Io.Group = .init;
    var reader: ChildStatusReader = undefined;
    reader.init();
    const probe = try ProcessProbe.create(alloc, "escaped", &.{ "/bin/sh", "-c", script, pid_file }, &reader);
    probe.spawn(&waiters, null);
    // The pid file is written after setsid, so the group kill then misses it.
    const escaped: std.posix.pid_t = for (0..2_000) |_| {
        if (tmp.dir.readFileAlloc(io_mod.getIo(), "escaped.pid", alloc, .limited(32))) |text| {
            defer alloc.free(text);
            if (std.fmt.parseInt(std.posix.pid_t, text, 10)) |pid| break pid else |_| {}
        } else |_| {}
        io_mod.sleep(5 * std.time.ns_per_ms);
    } else return error.EscapedProcessDidNotStart;
    defer std.posix.kill(escaped, .KILL) catch {};
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters, null) == null);
    const took = io_mod.milliTimestamp() - started;
    try std.testing.expect(probe.done.load(.acquire));
    // The child exited on its own; only the waiter was stuck on the pipe.
    try std.testing.expect(probe.term.? == .exited);
    try std.testing.expect(took >= reap_grace_ms and took < 50 + reap_grace_ms + 1_000);
}

test "a server whose name fx mcp would read as an option gets no child and a rename fix in every state" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    const statuses = [_]mcp_runtime.Status{
        .{ .name = "-x", .source = .profile, .transport = .stdio, .state = .idle },
        .{ .name = "--help", .source = .workspace, .transport = .stdio, .state = .idle },
        .{ .name = "normal", .source = .profile, .transport = .stdio, .state = .idle },
        .{ .name = "-w", .source = .workspace, .transport = .stdio, .state = .waiting_for_approval },
        .{ .name = "-u", .source = .profile, .transport = .sse, .state = .unsupported },
        .{ .name = "-f", .source = .profile, .transport = .stdio, .state = .failed, .last_error = "boom" },
        .{ .name = "-m", .source = .profile, .transport = .http, .state = .missing_env, .missing = "TOKEN" },
        .{ .name = "-i", .source = .workspace, .transport = .stdio, .state = .invalid_env },
    };
    try serverStatusChecks(&checks, alloc, &statuses);
    try std.testing.expectEqual(@as(usize, 7), checks.items.len);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expectEqualStrings("-x was not checked: fx mcp show reads a name that starts with \"-\" as an option", checks.items[0].detail);
    const profile_fix = "rename the server in ~/.fx/mcp.json so its name does not start with \"-\"";
    const project_fix = "rename the server in .mcp.json so its name does not start with \"-\"";
    try std.testing.expectEqualStrings(profile_fix, checks.items[0].fix.?);
    try std.testing.expectEqualStrings(project_fix, checks.items[1].fix.?);
    try std.testing.expectEqualStrings("-w is waiting for approval", checks.items[2].detail);
    try std.testing.expectEqualStrings(project_fix, checks.items[2].fix.?);
    try std.testing.expectEqualStrings("-u uses a transport fx does not support", checks.items[3].detail);
    try std.testing.expectEqualStrings(profile_fix, checks.items[3].fix.?);
    try std.testing.expectEqualStrings("-f failed: boom", checks.items[4].detail);
    try std.testing.expectEqualStrings(profile_fix, checks.items[4].fix.?);
    try std.testing.expectEqualStrings("-m needs TOKEN", checks.items[5].detail);
    try std.testing.expectEqualStrings(profile_fix, checks.items[5].fix.?);
    try std.testing.expectEqualStrings("-i needs an environment variable", checks.items[6].detail);
    try std.testing.expectEqualStrings(project_fix, checks.items[6].fix.?);

    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    defer processes.deinit(std.heap.c_allocator);
    // Past the deadline already, so no child starts for `normal` either.
    var servers = try startServerChildren(std.heap.c_allocator, &waiters, &processes, &statuses, "/nonexistent/fx", 0, 5_000, 4);
    try std.testing.expectEqual(@as(usize, 1), processes.items.len);
    try std.testing.expectEqualStrings("normal", processes.items[0].name);
    try std.testing.expect(wait(0, null, processes.items, &waiters, &servers) == null);
    try std.testing.expect(processes.items[0].not_started);
}

test "every fix line passes a name from a config file to a shell as one word" {
    const alloc = std.testing.allocator;
    const hostile = "x; touch /tmp/p #";
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    try serverStatusChecks(&checks, alloc, &.{
        .{ .name = hostile, .source = .workspace, .transport = .stdio, .state = .waiting_for_approval },
        .{ .name = "it's", .source = .profile, .transport = .sse, .state = .unsupported },
        .{ .name = "$(id)", .source = .profile, .transport = .stdio, .state = .failed },
        .{ .name = "env", .source = .profile, .transport = .stdio, .state = .missing_env, .missing = "A`id`" },
        .{ .name = "unnamed", .source = .profile, .transport = .stdio, .state = .invalid_env },
    });
    var login_reader: ChildStatusReader = undefined;
    answer(&login_reader, "{\"status\":\"needs_login\"}");
    var login: ProcessProbe = .{ .name = "a b", .term = .{ .exited = 0 }, .status = &login_reader };
    var unstarted: ProcessProbe = .{ .name = "`id`", .not_started = true };
    var results: std.ArrayList(ServerResult) = .empty;
    defer results.deinit(alloc);
    try serverChildChecks(&checks, &results, alloc, &.{ &login, &unstarted }, 5_000);
    const want = [_][]const u8{
        "fx mcp approve 'x; touch /tmp/p #'",
        "give 'it'\\''s' a stdio command or an HTTP URL, or run fx mcp remove 'it'\\''s'",
        "fx mcp show '$(id)'",
        "set 'A`id`', then run fx doctor again",
        "set the variable, then run fx doctor again",
        "fx mcp login 'a b'",
        "fx mcp show '`id`'",
    };
    try std.testing.expectEqual(want.len, checks.items.len);
    for (want, checks.items) |fix, check| try std.testing.expectEqualStrings(fix, check.fix.?);
}

test "each checked server's result matches its line" {
    const alloc = std.testing.allocator;
    var ready_reader: ChildStatusReader = undefined;
    answer(&ready_reader, "{\"status\":\"ready\",\"tools\":[{}]}");
    var login_reader: ChildStatusReader = undefined;
    answer(&login_reader, "{\"status\":\"needs_login\",\"error\":null,\"tools\":[]}");
    var ready: ProcessProbe = .{ .name = "ready", .term = .{ .exited = 0 }, .status = &ready_reader };
    var login: ProcessProbe = .{ .name = "login", .term = .{ .exited = 0 }, .status = &login_reader };
    var late: ProcessProbe = .{ .name = "late" };
    late.stopped.store(true, .release);
    var unstarted: ProcessProbe = .{ .name = "unstarted", .not_started = true };
    var crashed: ProcessProbe = .{ .name = "crashed", .term = .{ .signal = .SEGV } };
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    var results: std.ArrayList(ServerResult) = .empty;
    defer results.deinit(alloc);
    try serverChildChecks(&checks, &results, alloc, &.{ &ready, &login, &late, &unstarted, &crashed }, 5_000);
    const want = [_]struct { CheckStatus, ServerResult.Connection, ServerResult.Authentication }{
        .{ .ok, .ready, .ok },
        .{ .fail, .failed, .needs_login },
        .{ .fail, .timed_out, .not_checked },
        .{ .fail, .timed_out, .not_checked },
        .{ .fail, .failed, .not_checked },
    };
    for (want, checks.items, results.items) |w, check, result| {
        try std.testing.expectEqual(w[0], check.status);
        try std.testing.expectEqual(w[1], result.connection);
        try std.testing.expectEqual(w[2], result.authentication);
    }
}

test "a check killed at the deadline takes with it what it started in a group of its own" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const pid_file = try std.Io.Dir.path.join(alloc, &.{ dir, "server.pid" });
    defer alloc.free(pid_file);
    // Like an `fx mcp show` child and its stdio server: the server moves to a
    // group of its own, ignores SIGTERM and holds the pipe, and the child
    // waits on it.
    const script = "perl -MPOSIX -e '$SIG{TERM} = \"IGNORE\"; POSIX::setpgid(0, 0); open(F, \">\", $ARGV[0]) or exit 1; print F $$; close F; sleep 20' \"$0\" & wait";
    var waiters: std.Io.Group = .init;
    var reader: ChildStatusReader = undefined;
    reader.init();
    const probe = try ProcessProbe.create(alloc, "server", &.{ "/bin/sh", "-c", script, pid_file }, &reader);
    probe.spawn(&waiters, null);
    const server: std.posix.pid_t = for (0..2_000) |_| {
        if (tmp.dir.readFileAlloc(io_mod.getIo(), "server.pid", alloc, .limited(32))) |text| {
            defer alloc.free(text);
            if (std.fmt.parseInt(std.posix.pid_t, text, 10)) |pid| break pid else |_| {}
        } else |_| {}
        io_mod.sleep(5 * std.time.ns_per_ms);
    } else return error.ServerDidNotStart;
    defer std.posix.kill(server, .KILL) catch {};
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters, null) == null);
    // The pipe closed with the server, so no waiter needed the grace.
    try std.testing.expect(io_mod.milliTimestamp() - started < 50 + reap_grace_ms);
    try std.testing.expect(probe.stopped.load(.acquire));
    var gone = false;
    for (0..200) |_| {
        if (!try process_tree.processIsAlive(alloc, server)) {
            gone = true;
            break;
        }
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(gone);
}

test "an ending signal during the fan-out stops what started, starts nothing more, and is returned" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    defer stop_signal.store(0, .seq_cst);
    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    const first = try ProcessProbe.create(alloc, "first", &.{ "/bin/sh", "-c", "sleep 30" }, null);
    first.spawn(&waiters, null);
    try processes.append(alloc, first);
    // The handler's whole work, as if the signal reached it now.
    recordStopSignal(.TERM);
    const later = [_]mcp_runtime.Status{.{ .name = "later", .source = .profile, .transport = .stdio, .state = .idle }};
    var servers = try startServerChildren(alloc, &waiters, &processes, &later, "/nonexistent/fx", io_mod.milliTimestamp() + 60_000, 60_000, 4);
    try std.testing.expectEqual(@as(usize, 0), servers.next);
    try std.testing.expect(try startGh(alloc, &waiters, &processes) == null);
    const started = io_mod.milliTimestamp();
    try std.testing.expectEqual(std.posix.SIG.TERM, wait(started + 60_000, null, processes.items, &waiters, &servers).?);
    // It stopped at the signal, not at the deadline, and never started the
    // check that waited in the queue.
    try std.testing.expect(io_mod.milliTimestamp() - started < reap_grace_ms);
    try std.testing.expect(first.stopped.load(.acquire));
    try std.testing.expect(first.term.? == .signal);
    try std.testing.expect(processes.items[1].not_started);
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), processes.items[1].pid);
}

test "no more server checks run at once than the cap, and the next starts when one ends" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    for (0..5) |_| try processes.append(alloc, try ProcessProbe.create(alloc, "slow", &.{ "/bin/sh", "-c", "sleep 0.2" }, null));
    var servers: ServerChecks = .{ .probes = processes.items, .cap = 2 };
    const far = io_mod.milliTimestamp() + 30_000;
    servers.startMore(&waiters, far);
    try std.testing.expectEqual(@as(usize, 2), servers.next);
    // Both still run, so no slot is free.
    servers.startMore(&waiters, far);
    try std.testing.expectEqual(@as(usize, 2), servers.next);
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(far, null, processes.items, &waiters, &servers) == null);
    for (processes.items) |p| {
        try std.testing.expect(!p.not_started and !p.stopped.load(.acquire));
        try std.testing.expect(p.term.? == .exited);
    }
    // Two at a time, the last three needed two more rounds of 0.2 s.
    try std.testing.expect(io_mod.milliTimestamp() - started >= 350);
}

/// Sends the doctor trace lines a test writes to `trace.log` in `tmp`.
fn startTraceForTest(alloc: Allocator, tmp: std.testing.TmpDir) !void {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, path, "doctor");
}

/// Ends the tracing `startTraceForTest` began and returns what it wrote.
/// The caller owns it.
fn readTraceForTest(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    debug_trace.shutdown();
    return tmp.dir.readFileAlloc(io_mod.getIo(), "trace.log", alloc, .limited(1 << 20));
}

test "server checks still queued at the deadline are never started and say so" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try startTraceForTest(alloc, tmp);
    defer debug_trace.resetForTest();
    for ([_][]const u8{ "first", "second", "third" }) |name| try processes.append(alloc, try ProcessProbe.create(alloc, name, &.{ "/bin/sh", "-c", "sleep 30" }, null));
    // No start cutoff, so the one slot is still taken when the limit comes.
    var servers: ServerChecks = .{ .probes = processes.items, .cap = 1 };
    const started = io_mod.milliTimestamp();
    servers.startMore(&waiters, started + 100);
    try std.testing.expect(wait(started + 100, null, processes.items, &waiters, &servers) == null);
    try std.testing.expect(processes.items[0].stopped.load(.acquire));
    const trace = try readTraceForTest(alloc, tmp);
    for (processes.items[1..]) |p| {
        try std.testing.expect(p.not_started and !p.start_cutoff);
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), p.pid);
        const line = try alloc.print("check {s} was never started, since doctor's limit came while it waited for a slot; dropping it", .{p.name});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, line));
    }
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(std.testing.allocator, &checks);
    var results: std.ArrayList(ServerResult) = .empty;
    defer results.deinit(std.testing.allocator);
    try serverChildChecks(&checks, &results, std.testing.allocator, processes.items, 1_000);
    try std.testing.expect(std.mem.startsWith(u8, checks.items[0].detail, "first did not answer in 0."));
    try std.testing.expect(std.mem.endsWith(u8, checks.items[0].detail, " s, when doctor's 1 s limit ended"));
    try std.testing.expectEqualStrings("third was not checked: doctor reached its 1 s limit before it could start the check", checks.items[2].detail);
}

test "the cap is one check per CPU, at least 4 and at most 16" {
    for ([_][2]usize{ .{ 1, 4 }, .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 64, 16 } }) |case| {
        try std.testing.expectEqual(case[1], serverCapFor(case[0]));
    }
}

test "a queued check needs a share of the limit left to start, and one too late is never started" {
    try std.testing.expectEqual(@as(i64, 1_000), checkShareMs(5_000));
    try std.testing.expectEqual(@as(i64, 300), checkShareMs(1_200));
    try std.testing.expectEqual(@as(i64, 0), checkShareMs(1));
    const alloc = std.heap.c_allocator;
    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    for ([_][]const u8{ "first", "second" }) |name| try processes.append(alloc, try ProcessProbe.create(alloc, name, &.{ "/bin/sh", "-c", "sleep 30" }, null));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try startTraceForTest(alloc, tmp);
    defer debug_trace.resetForTest();
    // The deadline is still ahead, but the last moment to start has passed.
    const now = io_mod.milliTimestamp();
    var servers: ServerChecks = .{ .probes = processes.items, .cap = 4, .last_start = now - 1 };
    servers.startMore(&waiters, now + 60_000);
    try std.testing.expectEqual(processes.items.len, servers.next);
    for (processes.items) |p| {
        try std.testing.expect(p.not_started and p.start_cutoff and p.done.load(.acquire));
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), p.pid);
    }
    // With nothing left to wait for, the wait ends at once.
    try std.testing.expect(wait(now + 60_000, null, processes.items, &waiters, &servers) == null);
    try std.testing.expect(io_mod.milliTimestamp() - now < 1_000);
    const trace = try readTraceForTest(alloc, tmp);
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(std.testing.allocator, &checks);
    var results: std.ArrayList(ServerResult) = .empty;
    defer results.deinit(std.testing.allocator);
    try serverChildChecks(&checks, &results, std.testing.allocator, processes.items, 60_000);
    for (processes.items, checks.items) |p, check| {
        const line = try alloc.print("check {s} was never started, since too little of doctor's limit was left to start it; dropping it", .{p.name});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, line));
        const detail = try alloc.print("{s} was not checked: too little of doctor's 60 s limit was left to start it", .{p.name});
        try std.testing.expectEqualStrings(detail, check.detail);
        const fix = try alloc.print("fx mcp show {s}", .{p.name});
        try std.testing.expectEqualStrings(fix, check.fix.?);
    }
}

test "a signal drops each queued check with a trace line, and gh is never started" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try startTraceForTest(alloc, tmp);
    defer debug_trace.resetForTest();
    defer stop_signal.store(0, .seq_cst);
    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    const names = [_][]const u8{ "first", "second", "third" };
    for (names) |name| try processes.append(alloc, try ProcessProbe.create(alloc, name, &.{ "/bin/sh", "-c", "sleep 30" }, null));
    var servers: ServerChecks = .{ .probes = processes.items, .cap = 4 };
    // The handler's whole work, as if the signal reached it before any start.
    recordStopSignal(.TERM);
    try std.testing.expect(try startGh(alloc, &waiters, &processes) == null);
    try std.testing.expectEqual(std.posix.SIG.TERM, wait(io_mod.milliTimestamp() + 60_000, null, processes.items, &waiters, &servers).?);
    const trace = try readTraceForTest(alloc, tmp);
    for (names, processes.items) |name, p| {
        try std.testing.expect(p.not_started and !p.start_cutoff);
        try std.testing.expectEqual(@as(std.posix.pid_t, 0), p.pid);
        const line = try alloc.print("check {s} was never started, since doctor got a signal first; dropping it", .{name});
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, line));
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "check gh was never started, since doctor got a signal first"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "starting check"));
}

test "a check the limit cuts says how long it ran, not the whole limit" {
    const alloc = std.testing.allocator;
    var cut: ProcessProbe = .{ .name = "late", .stopped_after_ms = 1_234 };
    cut.stopped.store(true, .release);
    var whole: ProcessProbe = .{ .name = "hung", .stopped_after_ms = 4_960 };
    whole.stopped.store(true, .release);
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    var results: std.ArrayList(ServerResult) = .empty;
    defer results.deinit(alloc);
    try serverChildChecks(&checks, &results, alloc, &.{ &cut, &whole }, 5_000);
    try std.testing.expectEqualStrings("late did not answer in 1.2 s, when doctor's 5 s limit ended", checks.items[0].detail);
    try std.testing.expectEqualStrings("fx mcp show late", checks.items[0].fix.?);
    try std.testing.expectEqualStrings("hung did not answer in 5.0 s, when doctor's 5 s limit ended", checks.items[1].detail);
    try std.testing.expectEqual(ServerResult.Connection.timed_out, results.items[0].connection);
}

test "the gh line reads only how gh repo view ended" {
    const alloc = std.testing.allocator;
    var ok: ProcessProbe = .{ .name = "gh", .term = .{ .exited = 0 } };
    var signed_out: ProcessProbe = .{ .name = "gh", .term = .{ .exited = gh_auth_required } };
    var failed: ProcessProbe = .{ .name = "gh", .term = .{ .exited = 1 } };
    var crashed: ProcessProbe = .{ .name = "gh", .term = .{ .signal = .SEGV } };
    var late: ProcessProbe = .{ .name = "gh" };
    late.stopped.store(true, .release);
    var missing: ProcessProbe = .{ .name = "gh", .spawn_error = error.FileNotFound, .done = .init(true) };
    var lost: ProcessProbe = .{ .name = "gh" };
    const see_why = "run gh repo view to see why";
    const Case = struct { probe: *const ProcessProbe, status: CheckStatus, detail: []const u8, fix: ?[]const u8 };
    for ([_]Case{
        .{ .probe = &ok, .status = .ok, .detail = "gh can use this repository", .fix = null },
        .{ .probe = &signed_out, .status = .warn, .detail = "gh is not signed in for this repository", .fix = "gh auth login" },
        .{ .probe = &failed, .status = .warn, .detail = "gh could not use this repository", .fix = see_why },
        .{ .probe = &crashed, .status = .warn, .detail = "gh repo view ended early (terminated with signal SEGV)", .fix = see_why },
        .{ .probe = &late, .status = .warn, .detail = "gh repo view did not answer in 5 s", .fix = see_why },
        .{ .probe = &missing, .status = .warn, .detail = "GitHub CLI not found on PATH; fx pr --create and fx issue --create need it", .fix = "install gh from https://cli.github.com" },
        .{ .probe = &lost, .status = .warn, .detail = "gh repo view gave no result", .fix = see_why },
    }) |case| {
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try ghCheck(&checks, alloc, case.probe, 5_000);
        try std.testing.expectEqual(@as(usize, 1), checks.items.len);
        try std.testing.expectEqual(case.status, checks.items[0].status);
        try std.testing.expectEqualStrings(case.detail, checks.items[0].detail);
        if (case.fix) |fix| try std.testing.expectEqualStrings(fix, checks.items[0].fix.?) else try std.testing.expect(checks.items[0].fix == null);
    }
    // gh never started, because a signal came first: no line.
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    try ghCheck(&checks, alloc, null, 5_000);
    try std.testing.expectEqual(@as(usize, 0), checks.items.len);
}

test "the wait notice names each network check doctor started and the limit" {
    const alloc = std.testing.allocator;
    const Case = struct { waiting: Waiting, want: ?[]const u8 };
    for ([_]Case{
        .{ .waiting = .{ .provider = .gateway, .mcp_servers = 3, .gh = .checking }, .want = "checking AI Gateway, 3 MCP servers, and gh (up to 5 s)...\n" },
        .{ .waiting = .{ .mcp_servers = 1 }, .want = "checking 1 MCP server (up to 5 s)...\n" },
        .{ .waiting = .{ .provider = .grok, .gh = .checking }, .want = "checking Grok and gh (up to 5 s)...\n" },
        .{ .waiting = .{}, .want = null },
    }) |case| {
        const notice = try waitNotice(alloc, case.waiting, 5_000);
        defer if (notice) |text| alloc.free(text);
        if (case.want) |want| try std.testing.expectEqualStrings(want, notice.?) else try std.testing.expect(notice == null);
    }
}

/// The entries in `dir`, for tests.
fn entryCount(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |_| count += 1;
    return count;
}

test "stopping a check that keeps starting processes in groups of their own leaves none of them" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    // Each process it starts moves to a group of its own and writes its pid,
    // like a stdio server an `fx mcp show` child starts. It starts one every
    // 5 ms. Started as fast as the machine allows, a stop that is slow to land
    // lets thousands start, and the load they add slows the stop and the exit
    // of what it killed further, until the processes fill the machine's memory.
    const script = "while :; do /usr/bin/perl -e 'setpgrp(0, 0); open(F, \">\", \"$ARGV[0]/\" . $$) or exit 1; close F; sleep 30' \"$0\" & sleep 0.005; done";
    for (0..5) |round| {
        var waiters: std.Io.Group = .init;
        const before = try entryCount(tmp.dir);
        const probe = try ProcessProbe.create(alloc, "forker", &.{ "/bin/sh", "-c", script, dir }, null);
        probe.spawn(&waiters, null);
        // Once it has started one, so the stop meets it while it starts more.
        // On a loaded machine that takes longer than any fixed wait.
        const started_one = for (0..1_000) |_| {
            if (try entryCount(tmp.dir) > before) break true;
            io_mod.sleep(5 * std.time.ns_per_ms);
        } else false;
        io_mod.sleep((5 * round) * std.time.ns_per_ms);
        probe.stopped.store(true, .release);
        // Under load the stop can take longer than `stop_land_ms` to land,
        // which `stopTrees` allows; what it started must be gone either way.
        stopTrees(&.{probe});
        waiters.cancel(io_mod.getIo());
        // Only after the stop, so a test that fails here does not leave the
        // forker starting processes.
        try std.testing.expect(started_one);
        try std.testing.expect(probe.done.load(.acquire));
    }
    // Every process any round started is gone, once the system reaps it.
    var started: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        started += 1;
        const gone = for (0..200) |_| {
            if (!try process_tree.processIsAlive(alloc, pid)) break true;
            io_mod.sleep(5 * std.time.ns_per_ms);
        } else false;
        if (!gone) std.posix.kill(pid, .KILL) catch {};
        try std.testing.expect(gone);
    }
    try std.testing.expect(started > 0);
}

test "a check that has already exited does not hold up the stop of the others" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.heap.c_allocator;
    const io = io_mod.getIo();
    // No waiter reaps it, so it stays a zombie that can start nothing.
    var exited: ProcessProbe = .{ .name = "exited" };
    exited.child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    exited.pid = exited.child.id.?;
    defer _ = exited.child.wait(io) catch {};
    for (0..1_000) |_| {
        if (!try process_tree.processIsAlive(alloc, exited.pid)) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    const started = io_mod.milliTimestamp();
    stopTrees(&.{&exited});
    try std.testing.expect(exited.stop_landed);
    try std.testing.expect(io_mod.milliTimestamp() - started < stop_land_ms);
}
