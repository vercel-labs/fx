//! fx doctor's network and process checks, under one deadline.
//!
//! The provider catalog request runs as a `std.Io` task and writes only its
//! own slot, then sets `done` with release. Each MCP server is checked by its
//! own `fx mcp show NAME --json` child, so one process makes one connect, and
//! `gh auth status` runs as a child too. Each child runs in its own process
//! group, so killing the group also stops what the child started and closes
//! the child's pipe. One `std.Io` task per child reads its pipe to the end,
//! reaps it, and then kills whatever the child left in its group.
//!
//! `wait` stops and joins all of it before it returns. At the deadline it
//! notes which probes finished in time, cancels the catalog request and
//! awaits it, kills every child group still running, and joins every waiter.
//! The caller then reads each result once, and a probe that finished after
//! the deadline counts as not finished (`tests/tla/doctor/Doctor.tla`
//! NoTornReport, NoChildAfterExit, NoTaskAfterReport, Reports).
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
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const Check = doctor_runtime.Check;
const CheckStatus = doctor_runtime.CheckStatus;
const ServerResult = output_contracts.McpServerResult;

const default_deadline_ms: i64 = 5_000;
const max_test_deadline_ms: i64 = 60_000;
/// After the deadline kills the children still running, how long their
/// waiters get to reap them before `wait` cancels the ones still blocked.
const reap_grace_ms: i64 = 1_000;
/// How often `wait` looks at the done flags.
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
    /// Never started, because the deadline passed first.
    not_started: bool = false,
    /// Killed at the deadline, so it did not finish in time.
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    term: ?std.process.Child.Term = null,
    /// Reads the child's stdout as it arrives. Null when doctor needs only
    /// the exit status, and then the child's stdout goes nowhere.
    status: ?*ChildStatusReader = null,
    /// The child started before this one, for `stopChildrenOnSignal`.
    next: ?*ProcessProbe = null,

    /// Spawns `argv` in a new process group, then reads its stdout to the
    /// end and reaps it in a task of `waiters`. A spawn that fails, or a
    /// child no task can wait for, is done at once with `spawn_error` set.
    fn start(alloc: Allocator, waiters: *std.Io.Group, name: []const u8, argv: []const []const u8, status: ?*ChildStatusReader) !*ProcessProbe {
        const probe = try alloc.create(ProcessProbe);
        probe.* = .{ .name = name, .status = status };
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
        track(probe);
        waiters.concurrent(io, waitForExit, .{probe}) catch |err| {
            // Nothing would read or reap it, so it stops now.
            debug_trace.logf("doctor", "check {s} has no task to wait for it err={s}; killing its process group", .{ name, @errorName(err) });
            killGroup(probe.pid);
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

    /// Kills a child that is still running, and everything in its group;
    /// its waiter then reaps it.
    fn stop(self: *ProcessProbe) void {
        if (self.done.load(.acquire) or self.pid == 0) return;
        self.stopped.store(true, .release);
        killGroup(self.pid);
    }
};

/// For a child not yet reaped, so its id cannot have been reused.
fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
}

/// The signals that end doctor early. Each child is in its own group, so the
/// terminal's Ctrl-C reaches only doctor, which then stops the children.
const ending_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };
/// Each child doctor started, newest first. Only the main thread adds to it
/// and nothing leaves it, so a signal handler can walk it.
var started_children: std.atomic.Value(?*ProcessProbe) = .init(null);
var previous_actions: [ending_signals.len]std.posix.Sigaction = undefined;
var stops_children_on_signal = false;

/// Records a started child, and on the first one installs the handler that
/// stops every child when a signal ends doctor.
fn track(probe: *ProcessProbe) void {
    probe.next = started_children.load(.monotonic);
    started_children.store(probe, .release);
    if (stops_children_on_signal or builtin.is_test) return;
    stops_children_on_signal = true;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = stopChildrenOnSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (ending_signals, &previous_actions) |sig, *previous| {
        std.posix.sigaction(sig, &action, previous);
        // A signal doctor was started to ignore stays ignored.
        if (previous.handler.handler == std.posix.SIG.IGN) std.posix.sigaction(sig, previous, null);
    }
}

/// Kills every child group still running, then lets the signal do what it
/// did before doctor started a child. Async-signal-safe: it reads atomics
/// and calls only kill(2), sigaction(2), and raise(3).
fn stopChildrenOnSignal(sig: std.posix.SIG) callconv(.c) void {
    var it = started_children.load(.acquire);
    while (it) |probe| : (it = probe.next) {
        if (!probe.done.load(.acquire)) killGroup(probe.pid);
    }
    for (ending_signals, previous_actions) |ending, previous| {
        if (ending == sig) std.posix.sigaction(sig, &previous, null);
    }
    _ = std.c.raise(sig);
}

/// `fx mcp show` reads a name that starts with "-" as an option, and takes
/// no "--" before a name, so such a server gets no child.
fn showReadsAsOption(name: []const u8) bool {
    return name.len > 0 and name[0] == '-';
}

/// Starts one `fx mcp show NAME --json` child for each idle server and
/// appends it to `processes`. An unapproved, rejected, or disabled server is
/// never idle, so it never gets a child. Starting stops at `deadline`: each
/// server left gets a probe marked not started, so the limit holds however
/// many servers there are. Every probe started is in `processes` even when
/// this fails, so `wait` still stops it.
pub fn startServerChildren(
    alloc: Allocator,
    waiters: *std.Io.Group,
    processes: *std.ArrayList(*ProcessProbe),
    statuses: []const mcp_runtime.Status,
    self_exe: []const u8,
    deadline: i64,
) !void {
    for (statuses) |status| {
        if (status.state != .idle or showReadsAsOption(status.name)) continue;
        try processes.ensureUnusedCapacity(alloc, 1);
        const name = try alloc.dupe(u8, status.name);
        if (io_mod.milliTimestamp() >= deadline) {
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

/// fx pr and fx issue publish with gh in a repository whose remote fx reads
/// only on github.com, so the sign-in that matters is that host's. Without
/// `--hostname`, gh also fails when an account on another host does.
const gh_host = "github.com";

pub fn startGh(alloc: Allocator, waiters: *std.Io.Group) !*ProcessProbe {
    return ProcessProbe.start(alloc, waiters, "gh", &.{ "gh", "auth", "status", "--hostname", gh_host }, null);
}

fn allDone(catalog: ?*CatalogProbe, processes: []const *ProcessProbe) bool {
    if (catalog) |c| if (!c.done.load(.acquire)) return false;
    for (processes) |p| if (!p.done.load(.acquire)) return false;
    return true;
}

/// Waits until every probe is done or the deadline passes, then stops and
/// joins everything doctor started, so nothing runs after it returns. It
/// notes which probes finished in time, cancels and awaits a catalog request
/// still out, kills every child group still running, gives the waiters a
/// short grace to reap them, and then cancels and joins the waiters.
pub fn wait(deadline: i64, catalog: ?*CatalogProbe, processes: []const *ProcessProbe, waiters: *std.Io.Group) void {
    const io = io_mod.getIo();
    while (io_mod.milliTimestamp() < deadline and !allDone(catalog, processes)) {
        io_mod.sleep(poll_ms * std.time.ns_per_ms);
    }
    if (catalog) |c| c.finish(io);
    for (processes) |p| if (!p.done.load(.acquire)) {
        debug_trace.logf("doctor", "check {s} did not finish by the deadline; killing its process group and dropping its late result", .{p.name});
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
}

fn add(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []u8, fix: ?[]u8) !void {
    try checks.append(alloc, .{ .name = name, .status = status, .detail = detail, .owned_detail = detail, .fix = fix, .owned_fix = fix });
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
        try add(checks, alloc, "provider", .fail, try alloc.print("fx could not start the check of {s} ({s})", .{ label, @errorName(err) }), try alloc.dupe(u8, "run fx doctor again"));
        return;
    }
    if (!probe.in_time) {
        try add(checks, alloc, "provider", .fail, try alloc.print("could not reach {s} in {d} s", .{ label, seconds(deadline_ms) }), try alloc.dupe(u8, "check the network connection, then run fx doctor again"));
        return;
    }
    switch (probe.outcome) {
        .failed => |category| switch (category) {
            .authentication => try add(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, login)),
            .rate_limited => try add(checks, alloc, "provider", .warn, try alloc.print("{s} rate-limited the check, so the credential is not confirmed", .{label}), try alloc.dupe(u8, "run fx doctor again in a minute")),
            .malformed_response => try add(checks, alloc, "provider", .fail, try alloc.print("{s} sent a model list fx cannot read", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .resource_exhausted => try add(checks, alloc, "provider", .fail, try alloc.dupe(u8, "fx ran out of memory reading the model list"), try alloc.dupe(u8, "close other programs, then run fx doctor again")),
            // The provider answered, but with an error status.
            .gateway_unavailable, .http_status => try add(checks, alloc, "provider", .fail, try alloc.print("{s} answered the check with an error", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .cancellation, .transport, .runtime => try add(checks, alloc, "provider", .fail, try alloc.print("could not reach {s}", .{label}), try alloc.dupe(u8, "check the network connection, then run fx doctor again")),
        },
        .loaded => |loaded| {
            if (loaded.refused_key) {
                try add(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, login));
            } else if (loaded.public_only) |reason| {
                const fix = if (reason == .fx_login_team_required) "fx teams" else login;
                try add(checks, alloc, "auth", .warn, try alloc.print("{s} sent only its public model list, so the credential is not confirmed", .{label}), try alloc.dupe(u8, fix));
            } else {
                try add(checks, alloc, "auth", .ok, try alloc.print("{s} accepted the credential", .{label}), null);
            }
            if (loaded.has_model) {
                try add(checks, alloc, "model", .ok, try alloc.print("{s} is available", .{probe.model}), null);
            } else if (loaded.public_only != null or loaded.refused_key) {
                try add(checks, alloc, "model", .warn, try alloc.print("{s} is not in the models fx can see", .{probe.model}), try alloc.dupe(u8, "fx models"));
            } else {
                try add(checks, alloc, "model", .fail, try alloc.print("{s} is not an available model", .{probe.model}), try alloc.dupe(u8, "fx models"));
            }
        },
    }
}

fn seconds(ms: i64) i64 {
    return @max(1, @divFloor(ms + 999, 1000));
}

const ChildStatus = struct {
    status: []const u8,
    err: ?[]const u8 = null,
    tools: usize = 0,
};

/// Reads `fx mcp show NAME --json` output as it arrives and keeps only what
/// doctor reports: the status, the error, and how many tools there are. Its
/// memory is fixed, so an answer of any size is read whole. Strings longer
/// than doctor shows are cut at a whole character.
const ChildStatusReader = struct {
    /// Nesting deeper than fx mcp show writes is unreadable.
    const max_depth = 32;
    const Member = enum { other, status, err, tools };

    /// Holds the scanner's one bit for each level of nesting.
    nesting: [256]u8 = undefined,
    nesting_alloc: std.heap.FixedBufferAllocator = undefined,
    scanner: std.json.Scanner = undefined,
    unreadable: bool = false,
    ended: bool = false,
    complete: bool = false,
    began: bool = false,
    /// In the top-level object, the next string is a member name.
    want_name: bool = false,
    member: Member = .other,
    name: Text(8) = .{},
    status: Text(64) = .{},
    status_is_string: bool = false,
    err: Text(1024) = .{},
    err_is_string: bool = false,
    in_tools: bool = false,
    tools: usize = 0,

    /// Sets the reader up in place. It must not move afterward.
    pub fn init(self: *ChildStatusReader) void {
        self.* = .{};
        self.nesting_alloc = .init(&self.nesting);
        self.scanner = .initStreaming(self.nesting_alloc.allocator());
    }

    pub fn feed(self: *ChildStatusReader, bytes: []const u8) void {
        if (self.unreadable or self.ended) return;
        self.scanner.feedInput(bytes);
        self.drain();
    }

    /// Ends the input, at the end of the child's pipe.
    pub fn end(self: *ChildStatusReader) void {
        if (self.ended) return;
        self.ended = true;
        if (self.unreadable) return;
        self.scanner.endInput();
        self.drain();
    }

    /// What `end` found. Anything but the object fx mcp show writes, with a
    /// string status, is `error.Unreadable`. Strings borrow the reader.
    pub fn result(self: *const ChildStatusReader) error{Unreadable}!ChildStatus {
        if (self.unreadable or !self.complete or !self.status_is_string) return error.Unreadable;
        return .{
            .status = self.status.slice(),
            .err = if (self.err_is_string) self.err.slice() else null,
            .tools = self.tools,
        };
    }

    fn drain(self: *ChildStatusReader) void {
        while (true) {
            const token = self.scanner.next() catch |err| {
                if (err != error.BufferUnderrun) self.unreadable = true;
                return;
            };
            if (token == .end_of_document) {
                self.complete = true;
                return;
            }
            if (!self.take(token, self.scanner.stackHeight())) {
                self.unreadable = true;
                return;
            }
        }
    }

    /// Takes one token, with `height` the nesting after it. False when the
    /// output is not an object.
    fn take(self: *ChildStatusReader, token: std.json.Token, height: usize) bool {
        if (height > max_depth) return false;
        if (!self.began) {
            if (token != .object_begin) return false;
            self.began = true;
            self.want_name = true;
            return true;
        }
        switch (token) {
            .object_begin, .array_begin => {
                if (height == 2) {
                    self.in_tools = self.member == .tools and token == .array_begin;
                } else if (height == 3 and self.in_tools) {
                    self.tools += 1;
                }
            },
            .object_end, .array_end => if (height == 1) {
                self.in_tools = false;
                self.want_name = true;
            },
            .partial_string => |bytes| self.piece(bytes, height, false),
            .partial_string_escaped_1 => |bytes| self.piece(&bytes, height, false),
            .partial_string_escaped_2 => |bytes| self.piece(&bytes, height, false),
            .partial_string_escaped_3 => |bytes| self.piece(&bytes, height, false),
            .partial_string_escaped_4 => |bytes| self.piece(&bytes, height, false),
            .string => |bytes| self.piece(bytes, height, true),
            .number, .true, .false, .null => {
                if (height == 1) {
                    self.want_name = true;
                } else if (height == 2 and self.in_tools) {
                    self.tools += 1;
                }
            },
            else => {},
        }
        return true;
    }

    /// Part of a string, or its last part when `last`.
    fn piece(self: *ChildStatusReader, bytes: []const u8, height: usize, last: bool) void {
        if (height == 1 and self.want_name) {
            self.name.append(bytes);
            if (!last) return;
            self.member = memberNamed(&self.name);
            self.name = .{};
            self.want_name = false;
            switch (self.member) {
                .status => {
                    self.status = .{};
                    self.status_is_string = false;
                },
                .err => {
                    self.err = .{};
                    self.err_is_string = false;
                },
                .tools => {
                    self.tools = 0;
                    self.in_tools = false;
                },
                .other => {},
            }
            return;
        }
        if (height == 1) {
            switch (self.member) {
                .status => self.status.append(bytes),
                .err => self.err.append(bytes),
                .tools, .other => {},
            }
            if (!last) return;
            if (self.member == .status) self.status_is_string = true;
            if (self.member == .err) self.err_is_string = true;
            self.want_name = true;
            return;
        }
        if (last and height == 2 and self.in_tools) self.tools += 1;
    }

    fn memberNamed(name: *const Text(8)) Member {
        if (name.full) return .other;
        const text = name.slice();
        if (std.mem.eql(u8, text, "status")) return .status;
        if (std.mem.eql(u8, text, "error")) return .err;
        if (std.mem.eql(u8, text, "tools")) return .tools;
        return .other;
    }
};

/// Up to `capacity` bytes of a string. Past that, the rest is dropped, and a
/// character the limit cut in two is dropped too.
fn Text(comptime capacity: usize) type {
    return struct {
        /// One byte past `capacity`, so the cut can tell whether the byte
        /// after it continues a character, even when a character spans two
        /// parts.
        bytes: [capacity + 1]u8 = undefined,
        len: usize = 0,
        full: bool = false,

        fn append(self: *@This(), part: []const u8) void {
            if (self.full) return;
            const n = @min(self.bytes.len - self.len, part.len);
            @memcpy(self.bytes[self.len..][0..n], part[0..n]);
            self.len += n;
            if (self.len <= capacity) return;
            self.full = true;
            self.len = text_utils.utf8BackwardBoundary(&self.bytes, capacity);
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Reads `bytes` as one whole answer. The result borrows `reader`.
fn parseChildStatus(reader: *ChildStatusReader, bytes: []const u8) error{Unreadable}!ChildStatus {
    reader.init();
    reader.feed(bytes);
    reader.end();
    return reader.result();
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

fn serverChildCheck(checks: *std.ArrayList(Check), alloc: Allocator, c: *const ProcessProbe, deadline_ms: i64) !Found {
    const show = try alloc.print("fx mcp show {s}", .{c.name});
    const failed: Found = .{ .connection = .failed };
    const timed_out: Found = .{ .connection = .timed_out };
    if (c.not_started) {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} was not checked: doctor reached its {d} s limit before it could start the check", .{ c.name, seconds(deadline_ms) }), show);
        return timed_out;
    }
    if (c.stopped.load(.acquire)) {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start in {d} s", .{ c.name, seconds(deadline_ms) }), show);
        return timed_out;
    }
    if (c.spawn_error) |err| {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx could not start a check ({s})", .{ c.name, @errorName(err) }), show);
        return failed;
    }
    const term = c.term orelse {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx lost its check", .{c.name}), show);
        return failed;
    };
    if (term != .exited) {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx crashed while checking it ({f})", .{ c.name, term }), show);
        return failed;
    }
    const parsed = c.status.?.result() catch {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx could not read its check", .{c.name}), show);
        return failed;
    };
    if (std.mem.eql(u8, parsed.status, "ready")) {
        alloc.free(show);
        try add(checks, alloc, "mcp", .ok, try alloc.print("{s} ready, {d} tool{s}", .{ c.name, parsed.tools, if (parsed.tools == 1) "" else "s" }), null);
        return .{ .connection = .ready, .authentication = .ok };
    }
    if (std.mem.eql(u8, parsed.status, "needs_login")) {
        alloc.free(show);
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} needs sign-in", .{c.name}), try alloc.print("fx mcp login {s}", .{c.name}));
        return .{ .connection = .failed, .authentication = .needs_login };
    }
    if (std.mem.eql(u8, parsed.status, "connecting") or std.mem.eql(u8, parsed.status, "retrying") or std.mem.eql(u8, parsed.status, "not_started")) {
        try add(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start", .{c.name}), show);
        return failed;
    }
    try add(checks, alloc, "mcp", .fail, try alloc.print("{s} {s}: {s}", .{ c.name, parsed.status, parsed.err orelse "no detail" }), show);
    return failed;
}

/// Lines for servers that get no child, as the doctor process's own runtime
/// reads them without starting any.
pub fn serverStatusChecks(checks: *std.ArrayList(Check), alloc: Allocator, statuses: []const mcp_runtime.Status) !void {
    for (statuses) |s| switch (s.state) {
        .idle => if (showReadsAsOption(s.name)) {
            try add(checks, alloc, "mcp", .warn, try alloc.print("{s} was not checked: fx mcp show reads a name that starts with \"-\" as an option", .{s.name}), try alloc.print("rename the server in {s} so its name does not start with \"-\"", .{configFile(s.source)}));
        },
        .waiting_for_approval => try add(checks, alloc, "mcp", .warn, try alloc.print("{s} is waiting for approval", .{s.name}), try alloc.print("fx mcp approve {s}", .{s.name})),
        .missing_env, .invalid_env => try add(checks, alloc, "mcp", .fail, try alloc.print("{s} needs {s}", .{ s.name, s.missing orelse "an environment variable" }), try alloc.print("set {s}, then run fx doctor again", .{s.missing orelse "the variable"})),
        .unsupported => try add(checks, alloc, "mcp", .warn, try alloc.print("{s} uses a transport fx does not support", .{s.name}), try alloc.print("give {s} a stdio command or an HTTP URL, or run fx mcp remove {s}", .{ s.name, s.name })),
        .failed => try add(checks, alloc, "mcp", .fail, try alloc.print("{s} failed: {s}", .{ s.name, s.last_error orelse "no detail" }), try alloc.print("fx mcp show {s}", .{s.name})),
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

/// The gh line from `gh auth status --hostname github.com`, read after
/// `wait`. gh exits 1 when that host's account is missing or fails.
pub fn ghCheck(checks: *std.ArrayList(Check), alloc: Allocator, gh: *const ProcessProbe, deadline_ms: i64) !void {
    const why = "fx pr --create and fx issue --create need it";
    if (gh.spawn_error) |err| {
        if (err == error.FileNotFound) {
            return add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI not found on PATH; {s}", .{why}), try alloc.dupe(u8, "install gh from https://cli.github.com"));
        }
        return add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI could not start ({s}); {s}", .{ @errorName(err), why }), try alloc.dupe(u8, "gh --version"));
    }
    const status_command = "gh auth status --hostname " ++ gh_host;
    if (gh.stopped.load(.acquire)) {
        return add(checks, alloc, "gh", .warn, try alloc.print("gh auth status did not answer in {d} s", .{seconds(deadline_ms)}), try alloc.dupe(u8, status_command));
    }
    const term = gh.term orelse return add(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh auth status gave no result"), try alloc.dupe(u8, status_command));
    switch (term) {
        .exited => |code| if (code == 0) {
            try add(checks, alloc, "gh", .ok, try alloc.dupe(u8, "GitHub CLI is signed in to " ++ gh_host), null);
        } else {
            try add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI is not signed in to {s}; {s}", .{ gh_host, why }), try alloc.dupe(u8, "gh auth login --hostname " ++ gh_host));
        },
        else => try add(checks, alloc, "gh", .warn, try alloc.print("gh auth status ended early ({f})", .{term}), try alloc.dupe(u8, status_command)),
    }
}

fn freeChecks(alloc: Allocator, checks: *std.ArrayList(Check)) void {
    for (checks.items) |*entry| entry.deinit(alloc);
    checks.deinit(alloc);
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

test "child status parser reads fx mcp show output and refuses anything else" {
    var reader: ChildStatusReader = undefined;
    const ready = try parseChildStatus(&reader, "{\"name\":\"a\",\"status\":\"ready\",\"error\":null,\"tools\":[{\"name\":\"x\"},{\"name\":\"y\"}]}\n");
    try std.testing.expectEqualStrings("ready", ready.status);
    try std.testing.expect(ready.err == null);
    try std.testing.expectEqual(@as(usize, 2), ready.tools);
    const failed = try parseChildStatus(&reader, "{\"status\":\"failed\",\"error\":\"boom\"}");
    try std.testing.expectEqualStrings("boom", failed.err.?);
    const escaped = try parseChildStatus(&reader, "{\"st\\u0061tus\":\"ready\",\"tools\":[1,\"two\",[3],null,{\"tools\":[4,5]}],\"other\":{\"status\":\"no\"}}");
    try std.testing.expectEqualStrings("ready", escaped.status);
    try std.testing.expectEqual(@as(usize, 5), escaped.tools);
    for ([_][]const u8{ "", "null", "[]", "{\"status\":1}", "{\"tools\":[]}", "{\"status\":\"ready\"", "{\"status\":\"ready\"} x", "\xff" }) |bad| {
        try std.testing.expectError(error.Unreadable, parseChildStatus(&reader, bad));
    }
    const deep = "{\"status\":\"ready\",\"x\":" ++ text_utils.repeat("[", 40) ++ text_utils.repeat("]", 40) ++ "}";
    try std.testing.expectError(error.Unreadable, parseChildStatus(&reader, deep));
}

test "child status reader counts any number of tools in fixed memory" {
    var reader: ChildStatusReader = undefined;
    reader.init();
    reader.feed("{\"name\":\"big\",\"status\":\"rea");
    reader.feed("dy\",\"error\":null,\"tools\":[");
    const tool = "{\"name\":\"tool\",\"description\":\"" ++ text_utils.repeat("d", 200) ++ "\",\"inputSchema\":{\"type\":\"object\"}}";
    for (0..5_000) |i| reader.feed(if (i == 0) tool else "," ++ tool);
    reader.feed("]}\n");
    reader.end();
    const parsed = try reader.result();
    try std.testing.expectEqualStrings("ready", parsed.status);
    try std.testing.expectEqual(@as(usize, 5_000), parsed.tools);
}

test "child status reader cuts a long error at a whole character" {
    var reader: ChildStatusReader = undefined;
    const long = "{\"status\":\"failed\",\"error\":\"" ++ text_utils.repeat("a", 1023) ++ "\u{e9}tail\"}";
    const parsed = try parseChildStatus(&reader, long);
    try std.testing.expectEqual(@as(usize, 1023), parsed.err.?.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.err.?));
}

fn fuzzChildStatus(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var whole: ChildStatusReader = undefined;
    const expected = parseChildStatus(&whole, bytes);
    // The same bytes in the pieces a pipe could hand over read the same.
    var pieces: ChildStatusReader = undefined;
    pieces.init();
    var rest = bytes;
    while (rest.len > 0) {
        const n = smith.valueRangeAtMost(u32, 1, @intCast(rest.len));
        pieces.feed(rest[0..n]);
        rest = rest[n..];
    }
    pieces.end();
    const got = pieces.result();
    const want = expected catch return std.testing.expectError(error.Unreadable, got);
    const have = try got;
    try std.testing.expectEqualStrings(want.status, have.status);
    try std.testing.expectEqual(want.err == null, have.err == null);
    if (want.err) |text| try std.testing.expectEqualStrings(text, have.err.?);
    try std.testing.expectEqual(want.tools, have.tools);
    // A status fx reads came from the bytes, so it is no longer than them.
    try std.testing.expect(want.status.len <= bytes.len);
}

test "doctor child status parser tolerates arbitrary bytes" {
    try std.testing.fuzz({}, fuzzChildStatus, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"name\":\"a\",\"status\":\"ready\",\"error\":null,\"tools\":[{\"name\":\"x\"}]}",
            "{\"status\":\"needs_login\",\"error\":\"sign in\"}",
            "{\"status\":\"ready\"",
            "[]",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").doctor_child_status.*),
    });
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
    wait(started + 50, &probe, &.{}, &waiters);
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
    wait(started + 50, null, &.{probe}, &waiters);
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
    wait(started + 50, null, &.{probe}, &waiters);
    const took = io_mod.milliTimestamp() - started;
    try std.testing.expect(probe.done.load(.acquire));
    // The child exited on its own; only the waiter was stuck on the pipe.
    try std.testing.expect(probe.term.? == .exited);
    try std.testing.expect(took >= reap_grace_ms and took < 50 + reap_grace_ms + 1_000);
}

test "a server whose name fx mcp show would read as an option gets a warning, not a child" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    const statuses = [_]mcp_runtime.Status{
        .{ .name = "-x", .source = .profile, .transport = .stdio, .state = .idle },
        .{ .name = "--help", .source = .workspace, .transport = .stdio, .state = .idle },
        .{ .name = "normal", .source = .profile, .transport = .stdio, .state = .idle },
    };
    try serverStatusChecks(&checks, alloc, &statuses);
    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expectEqualStrings("-x was not checked: fx mcp show reads a name that starts with \"-\" as an option", checks.items[0].detail);
    try std.testing.expectEqualStrings("rename the server in ~/.fx/mcp.json so its name does not start with \"-\"", checks.items[0].fix.?);
    try std.testing.expectEqualStrings("rename the server in .mcp.json so its name does not start with \"-\"", checks.items[1].fix.?);

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

test "gh is checked on github.com and its exit reads as that host's sign-in" {
    const alloc = std.testing.allocator;
    const Case = struct { probe: ProcessProbe, status: CheckStatus, detail: []const u8, fix: ?[]const u8 };
    var stopped: ProcessProbe = .{ .name = "gh" };
    stopped.stopped.store(true, .release);
    for ([_]Case{
        .{ .probe = .{ .name = "gh", .term = .{ .exited = 0 } }, .status = .ok, .detail = "GitHub CLI is signed in to github.com", .fix = null },
        .{ .probe = .{ .name = "gh", .term = .{ .exited = 1 } }, .status = .warn, .detail = "GitHub CLI is not signed in to github.com; fx pr --create and fx issue --create need it", .fix = "gh auth login --hostname github.com" },
        .{ .probe = stopped, .status = .warn, .detail = "gh auth status did not answer in 5 s", .fix = "gh auth status --hostname github.com" },
    }) |case| {
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try ghCheck(&checks, alloc, &case.probe, 5_000);
        try std.testing.expectEqual(case.status, checks.items[0].status);
        try std.testing.expectEqualStrings(case.detail, checks.items[0].detail);
        if (case.fix) |fix| try std.testing.expectEqualStrings(fix, checks.items[0].fix.?) else try std.testing.expect(checks.items[0].fix == null);
    }
}

test "each checked server's result matches its line" {
    const alloc = std.testing.allocator;
    var ready_reader: ChildStatusReader = undefined;
    _ = try parseChildStatus(&ready_reader, "{\"status\":\"ready\",\"tools\":[{}]}");
    var login_reader: ChildStatusReader = undefined;
    _ = try parseChildStatus(&login_reader, "{\"status\":\"needs_login\",\"error\":null,\"tools\":[]}");
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
