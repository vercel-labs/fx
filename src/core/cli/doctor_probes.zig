//! fx doctor's network and process checks, under one deadline.
//!
//! The provider catalog request runs as a `std.Io` task and writes only its
//! own slot, then sets `done` with release. Each MCP server is checked by its
//! own `fx mcp show NAME --json` child, so one process makes one connect, and
//! `gh auth status` runs as a child for each host the repository's remotes
//! name. Each child runs in its own process group. One `std.Io` task per
//! child reads its pipe to the end, reaps it, and then kills whatever the
//! child left in its group.
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
const gh_hosts = @import("doctor_gh_hosts.zig");

const Allocator = std.mem.Allocator;
const Check = doctor_runtime.Check;
const CheckStatus = doctor_runtime.CheckStatus;
const ServerResult = output_contracts.McpServerResult;
const ChildStatusReader = child_status.ChildStatusReader;
const appendCheck = doctor_runtime.appendCheckOwnedFix;
const GhHost = gh_hosts.GhHost;
const GhTarget = gh_hosts.GhTarget;

const default_deadline_ms: i64 = 5_000;
const max_test_deadline_ms: i64 = 60_000;
/// After the deadline kills the children still running, how long their
/// waiters get to reap them before `wait` cancels the ones still blocked.
const reap_grace_ms: i64 = 1_000;
/// How often `wait` looks at the done flags and the stop signal.
const poll_ms: u64 = 5;

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
    child: std.process.Child = undefined,
    /// Taken at spawn, before the waiter can reap the child. It is also the
    /// id of the child's process group.
    pid: std.posix.pid_t = 0,
    spawn_error: ?anyerror = null,
    /// Never started, because the deadline passed or a signal came first.
    not_started: bool = false,
    /// Killed at the deadline or at an ending signal, so it did not finish
    /// in time.
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    /// Reads the child's stdout as it arrives. Null when doctor needs only
    /// the exit status, and then the child's stdout goes nowhere.
    status: ?*ChildStatusReader = null,

    /// Spawns `argv` in a new process group, then reads its stdout to the
    /// end and reaps it in a task of `waiters`. A spawn that fails, or a
    /// child no task can wait for, is done at once with `spawn_error` set.
    /// The caller adds the probe to the list `wait` stops before it looks at
    /// the stop signal again.
    fn start(alloc: Allocator, waiters: *std.Io.Group, name: []const u8, argv: []const []const u8, status: ?*ChildStatusReader) !*ProcessProbe {
        const probe = try alloc.create(ProcessProbe);
        probe.* = .{ .name = name, .status = status };
        // Before the first child exists, so a signal never ends doctor while
        // a child it started is left running.
        installStopHandler();
        debug_trace.logf("doctor", "starting check {s}", .{name});
        const io = io_mod.getIo();
        probe.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = if (status != null) .pipe else .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            probe.spawn_error = err;
            probe.done.store(true, .release);
            return probe;
        };
        probe.pid = probe.child.id.?;
        waiters.concurrent(io, waitForExit, .{probe}) catch |err| {
            // Nothing would read or reap it, so it stops now.
            debug_trace.logf("doctor", "check {s} has no task to wait for it err={s}; killing it with what it started", .{ name, @errorName(err) });
            killTree(probe.pid);
            probe.child.kill(io);
            probe.spawn_error = err;
            probe.done.store(true, .release);
        };
        return probe;
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

    /// Kills a child that is still running with everything it started; its
    /// waiter then reaps it.
    fn stop(self: *ProcessProbe) void {
        if (self.done.load(.acquire) or self.pid == 0) return;
        self.stopped.store(true, .release);
        killTree(self.pid);
    }
};

/// Kills the process group of `pid` and every process `pid` started outside
/// it, such as the stdio MCP servers an `fx mcp show` child starts in groups
/// of their own, and their helper. A group kill alone would leave a server
/// the child had started but not yet told its helper about. The group is
/// stopped first, so the child starts nothing more while doctor looks at
/// what it started; a child that started nothing is then only killed. Any
/// other tree is stopped and killed whole, and a process the kill skipped is
/// resumed (`process_tree.Tracker`). Only for a child not yet reaped, so its
/// id cannot have been reused.
fn killTree(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .STOP) catch {};
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

/// Starts one `fx mcp show NAME --json` child for each idle server and
/// appends it to `processes`. An unapproved, rejected, or disabled server is
/// never idle, so it never gets a child. Starting stops at `deadline`, and
/// when an ending signal arrives: each server left gets a probe marked not
/// started, so the limit holds however many servers there are. Every probe
/// started is in `processes` even when this fails, so `wait` still stops it.
pub fn startServerChildren(
    alloc: Allocator,
    waiters: *std.Io.Group,
    processes: *std.ArrayList(*ProcessProbe),
    statuses: []const mcp_runtime.Status,
    self_exe: []const u8,
    deadline: i64,
) !void {
    for (statuses) |status| {
        if (status.state != .idle or readsAsOption(status.name)) continue;
        try processes.ensureUnusedCapacity(alloc, 1);
        const name = try alloc.dupe(u8, status.name);
        if (stopRequested() or io_mod.milliTimestamp() >= deadline) {
            const probe = try alloc.create(ProcessProbe);
            probe.* = .{ .name = name, .not_started = true };
            probe.done.store(true, .release);
            processes.appendAssumeCapacity(probe);
            continue;
        }
        const argv = try alloc.dupe([]const u8, &.{ self_exe, "mcp", "show", name, "--json" });
        const reader = try alloc.create(ChildStatusReader);
        reader.init();
        processes.appendAssumeCapacity(try ProcessProbe.start(alloc, waiters, name, argv, reader));
    }
}

/// The gh checks of one repository: what doctor read, and one `gh auth
/// status --hostname` child for each host, in the same order.
pub const Gh = struct {
    target: GhTarget,
    probes: []const *ProcessProbe = &.{},
};

/// Starts one `gh auth status --hostname HOST` child for each host in
/// `target`, unless an ending signal came first, and appends each to
/// `processes`.
pub fn startGh(alloc: Allocator, waiters: *std.Io.Group, processes: *std.ArrayList(*ProcessProbe), target: GhTarget) !Gh {
    const hosts = switch (target) {
        .hosts => |hosts| hosts,
        else => return .{ .target = target },
    };
    var probes: std.ArrayList(*ProcessProbe) = .empty;
    for (hosts) |entry| {
        if (stopRequested()) break;
        try processes.ensureUnusedCapacity(alloc, 1);
        try probes.ensureUnusedCapacity(alloc, 1);
        const probe = try ProcessProbe.start(alloc, waiters, "gh", &.{ "gh", "auth", "status", "--hostname", entry.host }, null);
        processes.appendAssumeCapacity(probe);
        probes.appendAssumeCapacity(probe);
    }
    return .{ .target = target, .probes = try probes.toOwnedSlice(alloc) };
}

fn allDone(catalog: ?*CatalogProbe, processes: []const *ProcessProbe) bool {
    if (catalog) |c| if (!c.done.load(.acquire)) return false;
    for (processes) |p| if (!p.done.load(.acquire)) return false;
    return true;
}

/// Waits until every probe is done, the deadline passes, or an ending signal
/// arrives, then stops and joins everything doctor started, so nothing runs
/// after it returns. It notes which probes finished in time, cancels and
/// awaits a catalog request still out, kills every child still running with
/// what it started, gives the waiters a short grace to reap them, and then
/// cancels and joins the waiters. It then removes the signal handler and
/// returns the signal that arrived, if one did, for `endBySignal`.
pub fn wait(deadline: i64, catalog: ?*CatalogProbe, processes: []const *ProcessProbe, waiters: *std.Io.Group) ?std.posix.SIG {
    const io = io_mod.getIo();
    while (io_mod.milliTimestamp() < deadline and !allDone(catalog, processes) and !stopRequested()) {
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    const why = if (stopRequested()) "before doctor got a signal" else "by the deadline";
    if (catalog) |c| c.finish(io);
    for (processes) |p| if (!p.done.load(.acquire)) {
        debug_trace.logf("doctor", "check {s} did not finish {s}; killing it with what it started and dropping its late result", .{ p.name, why });
        p.stop();
    };
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

/// The line doctor writes to a terminal's stderr while it waits on the
/// network checks it started, such as `checking AI Gateway, 3 MCP servers,
/// and gh (up to 5 s)...`, or null when it started none. The caller owns it.
pub fn waitNotice(alloc: Allocator, provider: ?model_provider.ProviderId, servers: usize, gh: bool, deadline_ms: i64) Allocator.Error!?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var server_text: ?[]u8 = null;
    defer if (server_text) |text| alloc.free(text);
    if (provider) |id| try parts.append(alloc, providerLabel(id));
    if (servers > 0) {
        server_text = try alloc.print("{d} MCP server{s}", .{ servers, if (servers == 1) "" else "s" });
        try parts.append(alloc, server_text.?);
    }
    if (gh) try parts.append(alloc, "gh");
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
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} was not checked: doctor reached its {d} s limit before it could start the check", .{ c.name, seconds(deadline_ms) }), try mcpCommand(alloc, "show", c.name));
        return timed_out;
    }
    if (c.stopped.load(.acquire)) {
        try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start in {d} s", .{ c.name, seconds(deadline_ms) }), try mcpCommand(alloc, "show", c.name));
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

/// The fix for a server that gets no child: `fx mcp VERB NAME`, or, for a
/// name that every `fx mcp` command reads as an option, renaming it in the
/// file it comes from.
fn statusCommand(alloc: Allocator, verb: []const u8, s: mcp_runtime.Status) Allocator.Error![]u8 {
    if (readsAsOption(s.name)) return alloc.print("rename the server in {s} so its name does not start with \"-\"", .{configFile(s.source)});
    return mcpCommand(alloc, verb, s.name);
}

/// Lines for servers that get no child, as the doctor process's own runtime
/// reads them without starting any.
pub fn serverStatusChecks(checks: *std.ArrayList(Check), alloc: Allocator, statuses: []const mcp_runtime.Status) !void {
    for (statuses) |s| switch (s.state) {
        .idle => if (readsAsOption(s.name)) {
            try appendCheck(checks, alloc, "mcp", .warn, try alloc.print("{s} was not checked: fx mcp show reads a name that starts with \"-\" as an option", .{s.name}), try statusCommand(alloc, "show", s));
        },
        .waiting_for_approval => try appendCheck(checks, alloc, "mcp", .warn, try alloc.print("{s} is waiting for approval", .{s.name}), try statusCommand(alloc, "approve", s)),
        .missing_env, .invalid_env => {
            const variable = try command_lex.quoteWord(alloc, s.missing orelse "the variable");
            defer alloc.free(variable);
            try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} needs {s}", .{ s.name, s.missing orelse "an environment variable" }), try alloc.print("set {s}, then run fx doctor again", .{variable}));
        },
        .unsupported => {
            const fix = if (readsAsOption(s.name)) try statusCommand(alloc, "remove", s) else blk: {
                const quoted = try command_lex.quoteWord(alloc, s.name);
                defer alloc.free(quoted);
                break :blk try alloc.print("give {s} a stdio command or an HTTP URL, or run fx mcp remove {s}", .{ quoted, quoted });
            };
            try appendCheck(checks, alloc, "mcp", .warn, try alloc.print("{s} uses a transport fx does not support", .{s.name}), fix);
        },
        .failed => try appendCheck(checks, alloc, "mcp", .fail, try alloc.print("{s} failed: {s}", .{ s.name, s.last_error orelse "no detail" }), try statusCommand(alloc, "show", s)),
        .connecting, .ready, .retrying, .rejected, .disabled => {},
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

/// The gh line, read after `wait`: GitHub CLI is ready when it is signed in
/// to any host of the repository's remotes. Each `gh auth status --hostname`
/// child exits 1 when that host's account is missing or fails.
pub fn ghCheck(checks: *std.ArrayList(Check), alloc: Allocator, gh: Gh, deadline_ms: i64) !void {
    const why = "fx pr --create and fx issue --create need it";
    const hosts = switch (gh.target) {
        .hosts => |hosts| hosts,
        .no_remote => return appendCheck(checks, alloc, "gh", .warn, try alloc.print("this repository has no git remote, so gh has nowhere to publish; {s}", .{why}), try alloc.dupe(u8, "add the repository's remote with git remote add, then run fx doctor again")),
        .unreadable => |found| return appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh was not checked: fx could not read a host from {s} ({s})", .{ found.source, found.value }), try alloc.dupe(u8, "git remote -v")),
        .config_unavailable => return appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh was not checked: fx could not read this repository's git config"), try alloc.dupe(u8, "git config --list --show-origin")),
    };
    // A signal ended the checks before gh started; doctor does not report.
    if (gh.probes.len == 0) return;
    const first = try command_lex.quoteWord(alloc, hosts[0].host);
    defer alloc.free(first);
    if (gh.probes[0].spawn_error) |err| {
        if (err == error.FileNotFound) {
            return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI not found on PATH; {s}", .{why}), try alloc.dupe(u8, "install gh from https://cli.github.com"));
        }
        return appendCheck(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI could not start ({s}); {s}", .{ @errorName(err), why }), try alloc.dupe(u8, "gh --version"));
    }
    for (gh.probes, hosts[0..gh.probes.len]) |probe, entry| {
        const term = probe.term orelse continue;
        if (probe.stopped.load(.acquire) or term != .exited or term.exited != 0) continue;
        return appendCheck(checks, alloc, "gh", .ok, try ghHostText(alloc, "GitHub CLI is signed in to", entry, ""), null);
    }
    const status_command = try alloc.print("gh auth status --hostname {s}", .{first});
    for (gh.probes) |probe| {
        if (probe.stopped.load(.acquire)) {
            return appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh auth status did not answer in {d} s", .{seconds(deadline_ms)}), status_command);
        }
    }
    for (gh.probes) |probe| {
        const term = probe.term orelse return appendCheck(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh auth status gave no result"), status_command);
        if (term != .exited) return appendCheck(checks, alloc, "gh", .warn, try alloc.print("gh auth status ended early ({f})", .{term}), status_command);
    }
    alloc.free(status_command);
    const suffix = try alloc.print("; {s}", .{why});
    defer alloc.free(suffix);
    const detail = if (gh.probes.len == 1) try ghHostText(alloc, "GitHub CLI is not signed in to", hosts[0], suffix) else blk: {
        const list = try hostList(alloc, hosts[0..gh.probes.len]);
        defer alloc.free(list);
        break :blk try alloc.print("GitHub CLI is not signed in to any host of this repository's remotes ({s}){s}", .{ list, suffix });
    };
    try appendCheck(checks, alloc, "gh", .warn, detail, try alloc.print("gh auth login --hostname {s}", .{first}));
}

/// `lead HOST, the host of remote NAME` (or `that GH_HOST names`), then
/// `suffix`. The caller owns it.
fn ghHostText(alloc: Allocator, lead: []const u8, entry: GhHost, suffix: []const u8) Allocator.Error![]u8 {
    if (entry.remote) |remote| return alloc.print("{s} {s}, the host of remote {s}{s}", .{ lead, entry.host, remote, suffix });
    return alloc.print("{s} {s}, the host GH_HOST names{s}", .{ lead, entry.host, suffix });
}

/// The hosts, comma-separated. The caller owns it.
fn hostList(alloc: Allocator, hosts: []const GhHost) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (hosts, 0..) |entry, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, entry.host);
    }
    return out.toOwnedSlice(alloc);
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
    try std.testing.expect(wait(started + 50, &probe, &.{}, &waiters) == null);
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
    const probe = try ProcessProbe.start(alloc, &waiters, "hung", &.{ "/bin/sh", "-c", "sleep 30 & sleep 30" }, &reader);
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters) == null);
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
    const probe = try ProcessProbe.start(alloc, &waiters, "escaped", &.{ "/bin/sh", "-c", script, pid_file }, &reader);
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
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters) == null);
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
    };
    try serverStatusChecks(&checks, alloc, &statuses);
    try std.testing.expectEqual(@as(usize, 5), checks.items.len);
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

    var waiters: std.Io.Group = .init;
    var processes: std.ArrayList(*ProcessProbe) = .empty;
    defer processes.deinit(std.heap.c_allocator);
    // Past the deadline already, so no child starts for `normal` either.
    try startServerChildren(std.heap.c_allocator, &waiters, &processes, &statuses, "/nonexistent/fx", 0);
    try std.testing.expectEqual(@as(usize, 1), processes.items.len);
    try std.testing.expectEqualStrings("normal", processes.items[0].name);
    try std.testing.expect(processes.items[0].not_started);
    waiters.cancel(io_mod.getIo());
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
    const probe = try ProcessProbe.start(alloc, &waiters, "server", &.{ "/bin/sh", "-c", script, pid_file }, &reader);
    const server: std.posix.pid_t = for (0..2_000) |_| {
        if (tmp.dir.readFileAlloc(io_mod.getIo(), "server.pid", alloc, .limited(32))) |text| {
            defer alloc.free(text);
            if (std.fmt.parseInt(std.posix.pid_t, text, 10)) |pid| break pid else |_| {}
        } else |_| {}
        io_mod.sleep(5 * std.time.ns_per_ms);
    } else return error.ServerDidNotStart;
    defer std.posix.kill(server, .KILL) catch {};
    const started = io_mod.milliTimestamp();
    try std.testing.expect(wait(started + 50, null, &.{probe}, &waiters) == null);
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
    const first = try ProcessProbe.start(alloc, &waiters, "first", &.{ "/bin/sh", "-c", "sleep 30" }, null);
    try processes.append(alloc, first);
    // The handler's whole work, as if the signal reached it now.
    recordStopSignal(.TERM);
    const later = [_]mcp_runtime.Status{.{ .name = "later", .source = .profile, .transport = .stdio, .state = .idle }};
    try startServerChildren(alloc, &waiters, &processes, &later, "/nonexistent/fx", io_mod.milliTimestamp() + 60_000);
    try std.testing.expect(processes.items[1].not_started);
    const gh = try startGh(alloc, &waiters, &processes, .{ .hosts = &.{.{ .host = "github.com", .remote = "origin" }} });
    try std.testing.expectEqual(@as(usize, 0), gh.probes.len);
    const started = io_mod.milliTimestamp();
    try std.testing.expectEqual(std.posix.SIG.TERM, wait(started + 60_000, null, processes.items, &waiters).?);
    // It stopped at the signal, not at the deadline.
    try std.testing.expect(io_mod.milliTimestamp() - started < reap_grace_ms);
    try std.testing.expect(first.stopped.load(.acquire));
    try std.testing.expect(first.term.? == .signal);
}

test "gh is ready when it is signed in to any host of the remotes" {
    const alloc = std.testing.allocator;
    const hosts = [_]GhHost{ .{ .host = "github.com", .remote = "upstream" }, .{ .host = "ghe.example.com", .remote = "origin" } };
    var out: ProcessProbe = .{ .name = "gh", .term = .{ .exited = 1 } };
    var in: ProcessProbe = .{ .name = "gh", .term = .{ .exited = 0 } };
    var late: ProcessProbe = .{ .name = "gh" };
    late.stopped.store(true, .release);
    var missing: ProcessProbe = .{ .name = "gh", .spawn_error = error.FileNotFound, .done = .init(true) };
    const why = "; fx pr --create and fx issue --create need it";
    const Case = struct { gh: Gh, status: CheckStatus, detail: []const u8, fix: ?[]const u8 };
    for ([_]Case{
        .{ .gh = .{ .target = .{ .hosts = &hosts }, .probes = &.{ &out, &in } }, .status = .ok, .detail = "GitHub CLI is signed in to ghe.example.com, the host of remote origin", .fix = null },
        .{ .gh = .{ .target = .{ .hosts = hosts[0..1] }, .probes = &.{&out} }, .status = .warn, .detail = "GitHub CLI is not signed in to github.com, the host of remote upstream" ++ why, .fix = "gh auth login --hostname github.com" },
        .{ .gh = .{ .target = .{ .hosts = &hosts }, .probes = &.{ &out, &out } }, .status = .warn, .detail = "GitHub CLI is not signed in to any host of this repository's remotes (github.com, ghe.example.com)" ++ why, .fix = "gh auth login --hostname github.com" },
        .{ .gh = .{ .target = .{ .hosts = &hosts }, .probes = &.{ &out, &late } }, .status = .warn, .detail = "gh auth status did not answer in 5 s", .fix = "gh auth status --hostname github.com" },
        .{ .gh = .{ .target = .{ .hosts = hosts[0..1] }, .probes = &.{&missing} }, .status = .warn, .detail = "GitHub CLI not found on PATH" ++ why, .fix = "install gh from https://cli.github.com" },
        .{ .gh = .{ .target = .{ .hosts = &.{.{ .host = "ghe.example.com", .remote = null }} }, .probes = &.{&in} }, .status = .ok, .detail = "GitHub CLI is signed in to ghe.example.com, the host GH_HOST names", .fix = null },
        .{ .gh = .{ .target = .no_remote }, .status = .warn, .detail = "this repository has no git remote, so gh has nowhere to publish" ++ why, .fix = "add the repository's remote with git remote add, then run fx doctor again" },
        .{ .gh = .{ .target = .{ .unreadable = .{ .source = "remote origin", .value = "/srv/repo" } } }, .status = .warn, .detail = "gh was not checked: fx could not read a host from remote origin (/srv/repo)", .fix = "git remote -v" },
    }) |case| {
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try ghCheck(&checks, alloc, case.gh, 5_000);
        try std.testing.expectEqual(@as(usize, 1), checks.items.len);
        try std.testing.expectEqual(case.status, checks.items[0].status);
        try std.testing.expectEqualStrings(case.detail, checks.items[0].detail);
        if (case.fix) |fix| try std.testing.expectEqualStrings(fix, checks.items[0].fix.?) else try std.testing.expect(checks.items[0].fix == null);
    }
}

test "the wait notice names each network check doctor started and the limit" {
    const alloc = std.testing.allocator;
    const Case = struct { provider: ?model_provider.ProviderId, servers: usize, gh: bool, want: ?[]const u8 };
    for ([_]Case{
        .{ .provider = .gateway, .servers = 3, .gh = true, .want = "checking AI Gateway, 3 MCP servers, and gh (up to 5 s)...\n" },
        .{ .provider = null, .servers = 1, .gh = false, .want = "checking 1 MCP server (up to 5 s)...\n" },
        .{ .provider = .grok, .servers = 0, .gh = true, .want = "checking Grok and gh (up to 5 s)...\n" },
        .{ .provider = null, .servers = 0, .gh = false, .want = null },
    }) |case| {
        const notice = try waitNotice(alloc, case.provider, case.servers, case.gh, 5_000);
        defer if (notice) |text| alloc.free(text);
        if (case.want) |want| try std.testing.expectEqualStrings(want, notice.?) else try std.testing.expect(notice == null);
    }
}
