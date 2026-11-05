//! fx doctor's network and process checks, under one deadline.
//!
//! The provider catalog request runs on its own thread and writes only its
//! own slot, then sets `done` with release. Each MCP server is checked by its
//! own `fx mcp show NAME --json` child, so one process makes one connect, and
//! `gh auth status` runs as a child too. The caller reads every result once,
//! when all are done or at the deadline, after it kills and reaps every child
//! still running (`tests/tla/doctor/Doctor.tla` NoTornReport,
//! NoChildAfterExit, Reports).
//!
//! Probes and children live until the process exits: a late probe may still
//! write its slot after the report, so nothing here is freed.
const std = @import("std");
const model_catalog = @import("../gateway/model_catalog.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const mcp_runtime = @import("../mcp_host/runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const doctor_runtime = @import("doctor_runtime.zig");

const Allocator = std.mem.Allocator;
const Check = doctor_runtime.Check;
const CheckStatus = doctor_runtime.CheckStatus;

const default_deadline_ms: i64 = 5_000;
const max_test_deadline_ms: i64 = 60_000;
/// After the deadline kills the children still running, how long their
/// waiters get to reap them.
const reap_grace_ms: i64 = 1_000;
const output_limit = 64 * 1024;

/// The one deadline for every probe. `FX_TEST_DOCTOR_DEADLINE_MS` shortens it
/// for tests.
pub fn deadlineMs() i64 {
    const raw = io_mod.getenv("FX_TEST_DOCTOR_DEADLINE_MS") orelse return default_deadline_ms;
    const value = std.fmt.parseInt(i64, raw, 10) catch return default_deadline_ms;
    if (value <= 0 or value > max_test_deadline_ms) return default_deadline_ms;
    return value;
}

pub const CatalogOutcome = union(enum) {
    loaded: struct { has_model: bool, refused_key: bool, private_hidden: bool },
    failed: model_catalog.FailureCategory,
};

pub const CatalogProbe = struct {
    provider: gateway_provider.CliModelCatalogProvider,
    access: credentials.CatalogAccess,
    endpoint: []const u8,
    model: []const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    outcome: CatalogOutcome = .{ .failed = .runtime },

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
                .private_hidden = loaded.provenance.access.private_models_may_be_hidden,
            } },
            .failure => |failed| .{ .failed = failed.failure.category },
        };
        self.done.store(true, .release);
    }

    /// Starts the request on its own thread. `self` and everything it
    /// borrows must live until the process exits.
    pub fn start(self: *CatalogProbe) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.detach();
    }
};

fn contains(ids: []const []u8, model: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, model)) return true;
    return false;
}

/// One child process whose stdout and exit doctor reads after reaping it.
pub const ProcessProbe = struct {
    name: []const u8,
    child: std.process.Child = undefined,
    /// Taken at spawn, before the waiter can reap the child.
    pid: std.posix.pid_t = 0,
    spawn_error: ?anyerror = null,
    /// Never started, because the deadline passed first.
    not_started: bool = false,
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    output: []const u8 = "",
    term: ?std.process.Child.Term = null,

    /// Spawns `argv`, then reads its stdout to the end on a waiter thread,
    /// keeping the first 64 KiB, and reaps it. A spawn that fails is done at
    /// once, with `spawn_error` set.
    pub fn start(alloc: Allocator, name: []const u8, argv: []const []const u8) !*ProcessProbe {
        const probe = try alloc.create(ProcessProbe);
        probe.* = .{ .name = name };
        debug_trace.logf("doctor", "starting check {s}", .{name});
        probe.child = std.process.spawn(io_mod.getIo(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            probe.spawn_error = err;
            probe.done.store(true, .release);
            return probe;
        };
        probe.pid = probe.child.id.?;
        const thread = try std.Thread.spawn(.{}, waitForExit, .{probe});
        thread.detach();
        return probe;
    }

    fn waitForExit(self: *ProcessProbe) void {
        const io = io_mod.getIo();
        var kept: std.ArrayList(u8) = .empty;
        if (self.child.stdout) |file| {
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = file.readStreaming(io, &.{&chunk}) catch break;
                if (n == 0) {
                    io_mod.sleep(std.time.ns_per_ms);
                    continue;
                }
                const room = output_limit -| kept.items.len;
                kept.appendSlice(std.heap.c_allocator, chunk[0..@min(n, room)]) catch {};
            }
        }
        self.term = self.child.wait(io) catch null;
        self.output = kept.items;
        self.done.store(true, .release);
    }

    /// Kills a child that is still running; its waiter then reaps it.
    fn stop(self: *ProcessProbe) void {
        if (self.done.load(.acquire) or self.pid == 0) return;
        self.stopped.store(true, .release);
        std.posix.kill(self.pid, .KILL) catch {};
    }
};

/// Starts one `fx mcp show NAME --json` child for each idle server. An
/// unapproved, rejected, or disabled server is never idle, so it never gets
/// a child. Starting stops at `deadline`: each server left gets a probe
/// marked not started, so the limit holds however many servers there are.
pub fn startServerChildren(alloc: Allocator, statuses: []const mcp_runtime.Status, self_exe: []const u8, deadline: i64) ![]*ProcessProbe {
    var probes: std.ArrayList(*ProcessProbe) = .empty;
    for (statuses) |status| {
        if (status.state != .idle) continue;
        const name = try alloc.dupe(u8, status.name);
        if (io_mod.milliTimestamp() >= deadline) {
            const probe = try alloc.create(ProcessProbe);
            probe.* = .{ .name = name, .not_started = true };
            probe.done.store(true, .release);
            try probes.append(alloc, probe);
            continue;
        }
        const argv = try alloc.dupe([]const u8, &.{ self_exe, "mcp", "show", name, "--json" });
        try probes.append(alloc, try ProcessProbe.start(alloc, name, argv));
    }
    return probes.items;
}

pub fn startGh(alloc: Allocator) !*ProcessProbe {
    return ProcessProbe.start(alloc, "gh", &.{ "gh", "auth", "status" });
}

fn allDone(catalog: ?*CatalogProbe, processes: []const *ProcessProbe) bool {
    if (catalog) |c| if (!c.done.load(.acquire)) return false;
    for (processes) |p| if (!p.done.load(.acquire)) return false;
    return true;
}

/// Waits until every probe is done or the deadline passes. Then cancels a
/// catalog request still out, kills every child still running, and gives the
/// waiters a short time to reap them.
pub fn wait(deadline: i64, catalog: ?*CatalogProbe, processes: []const *ProcessProbe) void {
    while (io_mod.milliTimestamp() < deadline and !allDone(catalog, processes)) {
        io_mod.sleep(20 * std.time.ns_per_ms);
    }
    if (catalog) |c| if (!c.done.load(.acquire)) {
        c.cancel.store(true, .release);
        debug_trace.logf("doctor", "catalog probe did not finish by the deadline; its late result is dropped", .{});
    };
    for (processes) |p| if (!p.done.load(.acquire)) {
        debug_trace.logf("doctor", "probe {s} did not finish by the deadline; killing it", .{p.name});
        p.stop();
    };
    const reap_deadline = io_mod.milliTimestamp() + reap_grace_ms;
    while (io_mod.milliTimestamp() < reap_deadline) {
        var reaped = true;
        for (processes) |p| reaped = reaped and p.done.load(.acquire);
        if (reaped) return;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
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

/// The provider and model checks from the catalog slot as read at the
/// deadline: an unfinished slot is a provider that could not be reached.
pub fn catalogChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    probe: *CatalogProbe,
    provider: model_provider.ProviderId,
    deadline_ms: i64,
) !void {
    const label = providerLabel(provider);
    if (!probe.done.load(.acquire)) {
        try add(checks, alloc, "provider", .fail, try alloc.print("could not reach {s} in {d} s", .{ label, seconds(deadline_ms) }), try alloc.dupe(u8, "check the network connection, then run fx doctor again"));
        return;
    }
    switch (probe.outcome) {
        .failed => |category| switch (category) {
            .authentication => try add(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, "fx login")),
            .rate_limited => try add(checks, alloc, "provider", .warn, try alloc.print("{s} rate-limited the check, so the credential is not confirmed", .{label}), try alloc.dupe(u8, "run fx doctor again in a minute")),
            .malformed_response => try add(checks, alloc, "provider", .fail, try alloc.print("{s} sent a model list fx cannot read", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .resource_exhausted => try add(checks, alloc, "provider", .fail, try alloc.dupe(u8, "fx ran out of memory reading the model list"), null),
            // The provider answered, but with an error status.
            .gateway_unavailable, .http_status => try add(checks, alloc, "provider", .fail, try alloc.print("{s} answered the check with an error", .{label}), try alloc.dupe(u8, "run fx doctor again later")),
            .cancellation, .transport, .runtime => try add(checks, alloc, "provider", .fail, try alloc.print("could not reach {s}", .{label}), try alloc.dupe(u8, "check the network connection, then run fx doctor again")),
        },
        .loaded => |loaded| {
            if (loaded.refused_key) {
                try add(checks, alloc, "auth", .fail, try alloc.print("{s} refused the credential", .{label}), try alloc.dupe(u8, "fx login"));
            } else {
                try add(checks, alloc, "auth", .ok, try alloc.print("{s} accepted the credential", .{label}), null);
            }
            if (loaded.has_model) {
                try add(checks, alloc, "model", .ok, try alloc.print("{s} is available", .{probe.model}), null);
            } else if (loaded.private_hidden or loaded.refused_key) {
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

pub const ChildStatus = struct {
    status: []const u8,
    err: ?[]const u8 = null,
    tools: usize = 0,
};

/// Reads the fields doctor needs from `fx mcp show NAME --json` output. Any
/// other input is `error.Unreadable`. Strings are owned by `arena`.
pub fn parseChildStatus(arena: Allocator, bytes: []const u8) error{ Unreadable, OutOfMemory }!ChildStatus {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreadable,
    };
    if (value != .object) return error.Unreadable;
    const status = value.object.get("status") orelse return error.Unreadable;
    if (status != .string) return error.Unreadable;
    var out: ChildStatus = .{ .status = status.string };
    if (value.object.get("error")) |e| if (e == .string) {
        out.err = e.string;
    };
    if (value.object.get("tools")) |t| if (t == .array) {
        out.tools = t.array.items.len;
    };
    return out;
}

/// One line for each MCP server checked by a child, as read after reaping.
pub fn serverChildChecks(checks: *std.ArrayList(Check), alloc: Allocator, children: []const *ProcessProbe, deadline_ms: i64) !void {
    for (children) |c| try serverChildCheck(checks, alloc, c, deadline_ms);
}

fn serverChildCheck(checks: *std.ArrayList(Check), alloc: Allocator, c: *ProcessProbe, deadline_ms: i64) !void {
    const show = try alloc.print("fx mcp show {s}", .{c.name});
    if (c.not_started) {
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s} was not checked: doctor reached its {d} s limit before it could start the check", .{ c.name, seconds(deadline_ms) }), show);
    }
    if (!c.done.load(.acquire) or c.stopped.load(.acquire)) {
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start in {d} s", .{ c.name, seconds(deadline_ms) }), show);
    }
    if (c.spawn_error) |err| {
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx could not start a check ({s})", .{ c.name, @errorName(err) }), show);
    }
    const term = c.term orelse return add(checks, alloc, "mcp", .fail, try alloc.print("{s} could not be checked: fx lost its check", .{c.name}), show);
    if (term != .exited) {
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx crashed while checking it ({f})", .{ c.name, term }), show);
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const parsed = parseChildStatus(arena_state.allocator(), c.output) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Unreadable => return add(checks, alloc, "mcp", .fail, try alloc.print("{s}: fx could not read its check", .{c.name}), show),
    };
    if (std.mem.eql(u8, parsed.status, "ready")) {
        alloc.free(show);
        return add(checks, alloc, "mcp", .ok, try alloc.print("{s} ready, {d} tool{s}", .{ c.name, parsed.tools, if (parsed.tools == 1) "" else "s" }), null);
    }
    if (std.mem.eql(u8, parsed.status, "needs_login")) {
        alloc.free(show);
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s} needs sign-in", .{c.name}), try alloc.print("fx mcp login {s}", .{c.name}));
    }
    if (std.mem.eql(u8, parsed.status, "connecting") or std.mem.eql(u8, parsed.status, "retrying") or std.mem.eql(u8, parsed.status, "not_started")) {
        return add(checks, alloc, "mcp", .fail, try alloc.print("{s} did not start", .{c.name}), show);
    }
    return add(checks, alloc, "mcp", .fail, try alloc.print("{s} {s}: {s}", .{ c.name, parsed.status, parsed.err orelse "no detail" }), show);
}

/// Lines for servers that get no child, as the doctor process's own runtime
/// reads them without starting any.
pub fn serverStatusChecks(checks: *std.ArrayList(Check), alloc: Allocator, statuses: []const mcp_runtime.Status) !void {
    for (statuses) |s| switch (s.state) {
        .waiting_for_approval => try add(checks, alloc, "mcp", .warn, try alloc.print("{s} is waiting for approval", .{s.name}), try alloc.print("fx mcp approve {s}", .{s.name})),
        .missing_env, .invalid_env => try add(checks, alloc, "mcp", .fail, try alloc.print("{s} needs {s}", .{ s.name, s.missing orelse "an environment variable" }), try alloc.print("set {s}, then run fx doctor again", .{s.missing orelse "the variable"})),
        .unsupported => try add(checks, alloc, "mcp", .warn, try alloc.print("{s} uses a transport fx does not support", .{s.name}), null),
        .failed => try add(checks, alloc, "mcp", .fail, try alloc.print("{s} failed: {s}", .{ s.name, s.last_error orelse "no detail" }), try alloc.print("fx mcp show {s}", .{s.name})),
        .idle, .connecting, .ready, .retrying, .rejected, .disabled => {},
    };
}

/// The gh line from `gh auth status`, as read after reaping.
pub fn ghCheck(checks: *std.ArrayList(Check), alloc: Allocator, gh: *ProcessProbe, deadline_ms: i64) !void {
    const why = "fx pr --create and fx issue --create need it";
    if (gh.spawn_error) |err| {
        if (err == error.FileNotFound) {
            return add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI not found on PATH; {s}", .{why}), try alloc.dupe(u8, "install gh from https://cli.github.com"));
        }
        return add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI could not start ({s}); {s}", .{ @errorName(err), why }), null);
    }
    if (!gh.done.load(.acquire) or gh.stopped.load(.acquire)) {
        return add(checks, alloc, "gh", .warn, try alloc.print("gh auth status did not answer in {d} s", .{seconds(deadline_ms)}), try alloc.dupe(u8, "gh auth status"));
    }
    const term = gh.term orelse return add(checks, alloc, "gh", .warn, try alloc.dupe(u8, "gh auth status gave no result"), try alloc.dupe(u8, "gh auth status"));
    switch (term) {
        .exited => |code| if (code == 0) {
            try add(checks, alloc, "gh", .ok, try alloc.dupe(u8, "GitHub CLI is signed in"), null);
        } else {
            try add(checks, alloc, "gh", .warn, try alloc.print("GitHub CLI is not signed in; {s}", .{why}), try alloc.dupe(u8, "gh auth login"));
        },
        else => try add(checks, alloc, "gh", .warn, try alloc.print("gh auth status ended early ({f})", .{term}), try alloc.dupe(u8, "gh auth status")),
    }
}

fn freeChecks(alloc: Allocator, checks: *std.ArrayList(Check)) void {
    for (checks.items) |*entry| entry.deinit(alloc);
    checks.deinit(alloc);
}

test "catalog checks cover every outcome the slot can hold at the deadline" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{
        .provider = undefined,
        .access = .{ .public_only = .no_credential },
        .endpoint = "",
        .model = "m/one",
    };
    const Case = struct { done: bool, outcome: CatalogOutcome, want: []const struct { []const u8, CheckStatus } };
    const cases = [_]Case{
        .{ .done = false, .outcome = .{ .failed = .runtime }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .authentication }, .want = &.{.{ "auth", .fail }} },
        .{ .done = true, .outcome = .{ .failed = .rate_limited }, .want = &.{.{ "provider", .warn }} },
        .{ .done = true, .outcome = .{ .failed = .transport }, .want = &.{.{ "provider", .fail }} },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = false, .private_hidden = false } }, .want = &.{ .{ "auth", .ok }, .{ "model", .ok } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = true, .refused_key = true, .private_hidden = false } }, .want = &.{ .{ "auth", .fail }, .{ "model", .ok } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = false, .refused_key = false, .private_hidden = false } }, .want = &.{ .{ "auth", .ok }, .{ "model", .fail } } },
        .{ .done = true, .outcome = .{ .loaded = .{ .has_model = false, .refused_key = false, .private_hidden = true } }, .want = &.{ .{ "auth", .ok }, .{ "model", .warn } } },
    };
    for (cases) |case| {
        probe.done.store(case.done, .release);
        probe.outcome = case.outcome;
        var checks: std.ArrayList(Check) = .empty;
        defer freeChecks(alloc, &checks);
        try catalogChecks(&checks, alloc, &probe, .gateway, 5_000);
        try std.testing.expectEqual(case.want.len, checks.items.len);
        for (case.want, checks.items) |want, got| {
            try std.testing.expectEqualStrings(want[0], got.name);
            try std.testing.expectEqual(want[1], got.status);
            if (got.status != .ok) try std.testing.expect(got.fix != null or std.mem.eql(u8, got.name, "provider"));
        }
    }
}

test "a refused key never reads as accepted" {
    const alloc = std.testing.allocator;
    var probe: CatalogProbe = .{ .provider = undefined, .access = .{ .public_only = .no_credential }, .endpoint = "", .model = "m" };
    probe.done.store(true, .release);
    probe.outcome = .{ .loaded = .{ .has_model = true, .refused_key = true, .private_hidden = true } };
    var checks: std.ArrayList(Check) = .empty;
    defer freeChecks(alloc, &checks);
    try catalogChecks(&checks, alloc, &probe, .gateway, 5_000);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expectEqualStrings("fx login", checks.items[0].fix.?);
}

test "child status parser reads fx mcp show output and refuses anything else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready = try parseChildStatus(arena, "{\"name\":\"a\",\"status\":\"ready\",\"error\":null,\"tools\":[{\"name\":\"x\"},{\"name\":\"y\"}]}\n");
    try std.testing.expectEqualStrings("ready", ready.status);
    try std.testing.expectEqual(@as(usize, 2), ready.tools);
    const failed = try parseChildStatus(arena, "{\"status\":\"failed\",\"error\":\"boom\"}");
    try std.testing.expectEqualStrings("boom", failed.err.?);
    for ([_][]const u8{ "", "null", "[]", "{\"status\":1}", "{\"tools\":[]}", "{\"status\":\"ready\"", "\xff" }) |bad| {
        try std.testing.expectError(error.Unreadable, parseChildStatus(arena, bad));
    }
}

fn fuzzChildStatus(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = parseChildStatus(arena_state.allocator(), bytes) catch |err| switch (err) {
        error.Unreadable => return,
        error.OutOfMemory => return err,
    };
    // A status fx reads came from the bytes, so it is no longer than them.
    try std.testing.expect(parsed.status.len <= bytes.len);
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
    try std.testing.expectEqual(default_deadline_ms, deadlineMs());
    try std.testing.expectEqual(@as(i64, 1), seconds(1));
    try std.testing.expectEqual(@as(i64, 5), seconds(5_000));
    try std.testing.expectEqual(@as(i64, 2), seconds(1_001));
}
