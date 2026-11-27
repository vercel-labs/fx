//! Process-wide runtime for custom model connections with `"auth": {"type": "command"}`.
//! Holds one token per connection across the process, keeps at most one helper
//! run in flight per connection, and follows `command_token.zig`
//! (`tests/tla/configured_provider/ConfiguredAuth.tla`, design "b").

const std = @import("std");
const command_helper = @import("command_helper.zig");
const command_token = @import("command_token.zig");
const configured_provider = @import("../config/configured_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");

const expiry_margin_s: i64 = 60;
const wait_poll_ms: i64 = 25;

pub const Connection = struct {
    identity: [32]u8,
    /// Borrowed for the call.
    argv: []const []const u8,
    /// Borrowed for the call; null inherits fx's own directory.
    cwd: ?[]const u8 = null,
};

pub const Lease = struct {
    /// Owned by the caller's allocator; zeroed on `deinit`.
    token: []u8,
    gen: command_token.Gen,
    /// Owned by the caller's allocator; header values are zeroed on `deinit`.
    headers: []command_helper.Header,

    pub fn deinit(self: *Lease, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        freeHeaders(alloc, self.headers);
        alloc.free(self.headers);
        self.* = undefined;
    }
};

pub const TokenError = error{
    OutOfMemory,
    Cancelled,
    Timeout,
    HelperFailed,
    TooManyConnections,
};

const Entry = struct {
    occupied: bool = false,
    identity: [32]u8 = @splat(0),
    state: command_token.State = .{},
    /// Owned; allocated with `std.heap.c_allocator`. Zeroed when replaced or dropped.
    held_token: ?[]u8 = null,
    held_expires_at_s: ?i64 = null,
    /// Owned; allocated with `std.heap.c_allocator`. Values zeroed when replaced or dropped.
    held_headers: ?[]command_helper.Header = null,
    held_gen: command_token.Gen = 0,
    /// Owned by the entry (`std.heap.c_allocator`) while a task runs or awaits collection.
    task_argv: ?[][]u8 = null,
    /// Owned; allocated with `std.heap.c_allocator`.
    task_cwd: ?[]u8 = null,
    task: ?std.Io.Future(void) = null,
    run_cancel: std.atomic.Value(bool) = .init(false),
    changed: std.Io.Condition = .init,
    completions: u64 = 0,
    active_run_id: u64 = 0,
    last_run_succeeded: bool = false,
    /// Owned; allocated with `std.heap.c_allocator`.
    failure_message: ?[]u8 = null,

    fn replaceHeld(
        self: *Entry,
        new_token: []u8,
        new_expires_at_s: ?i64,
        new_headers: []command_helper.Header,
        gen: command_token.Gen,
    ) void {
        self.clearHeld();
        self.held_token = new_token;
        self.held_expires_at_s = new_expires_at_s;
        self.held_headers = new_headers;
        self.held_gen = gen;
    }

    fn clearHeld(self: *Entry) void {
        const alloc = std.heap.c_allocator;
        if (self.held_token) |old_token| {
            secret.zeroAndFree(alloc, old_token);
            self.held_token = null;
        }
        if (self.held_headers) |old_headers| {
            freeHeaders(alloc, old_headers);
            alloc.free(old_headers);
            self.held_headers = null;
        }
        self.held_expires_at_s = null;
        self.held_gen = 0;
    }

    fn freeTaskInputs(self: *Entry) void {
        const alloc = std.heap.c_allocator;
        if (self.task_argv) |argv| {
            freeArgv(alloc, argv);
            self.task_argv = null;
        }
        if (self.task_cwd) |cwd| {
            alloc.free(cwd);
            self.task_cwd = null;
        }
    }

    fn setFailureMessage(self: *Entry, message: ?[]u8) void {
        const alloc = std.heap.c_allocator;
        if (self.failure_message) |old| alloc.free(old);
        self.failure_message = message;
    }

    fn clear(self: *Entry) void {
        self.clearHeld();
        self.freeTaskInputs();
        self.setFailureMessage(null);
        self.* = .{};
    }
};

var mutex: std.Io.Mutex = .init;
var entries: [configured_provider.max_providers]Entry = @splat(.{});

/// Returns a lease for `connection`'s current token, running the helper if
/// needed. Caller owns the returned `Lease` and calls `deinit`.
pub fn token(
    alloc: std.mem.Allocator,
    connection: Connection,
    cancel_flag: *const std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) TokenError!Lease {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const entry = try findOrCreateEntryLocked(connection.identity);
    expireIfNeededLocked(entry, io);
    return executePlanLocked(alloc, entry, io, connection, command_token.need(&entry.state), cancel_flag, deadline);
}

/// Drops `identity`'s cached token when it still matches `sent`. Called on
/// every 401; never waits and never starts a helper.
pub fn refused(identity: [32]u8, sent: command_token.Gen) void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const entry = findEntryLocked(identity) orelse return;
    const had_cached = entry.state.cached != 0;
    command_token.refused(&entry.state, sent);
    const cleared = had_cached and entry.state.cached == 0;
    if (cleared) entry.clearHeld();
    debug_trace.logf("command_auth", "event=token_refused conn={x} gen={d} cleared={}", .{
        entry.identity[0..4],
        sent,
        cleared,
    });
}

/// Returns an owned copy of the last terminal-safe helper failure message for
/// `identity`, or null when none is recorded.
pub fn lastFailure(alloc: std.mem.Allocator, identity: [32]u8) std.mem.Allocator.Error!?[]u8 {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const entry = findEntryLocked(identity) orelse return null;
    const message = entry.failure_message orelse return null;
    return try alloc.dupe(u8, message);
}

/// Signals every running helper to stop and awaits every stored task so no
/// helper process outlives fx (`RULES.md` R3.9).
pub fn shutdown() void {
    const io = io_mod.getIo();
    var tasks: [configured_provider.max_providers]?std.Io.Future(void) = @splat(null);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        for (&entries, 0..) |*entry, i| {
            entry.run_cancel.store(true, .release);
            tasks[i] = entry.task;
            entry.task = null;
        }
    }
    for (&tasks) |*maybe_task| {
        if (maybe_task.*) |*task| task.await(io);
    }
}

fn executePlanLocked(
    alloc: std.mem.Allocator,
    entry: *Entry,
    io: std.Io,
    connection: Connection,
    plan: command_token.Plan,
    cancel_flag: *const std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) TokenError!Lease {
    return switch (plan) {
        .send => |gen| buildHeldLeaseLocked(alloc, entry, gen),
        .start_and_wait => blk: {
            const start_completions = entry.completions;
            try startRunLocked(entry, io, connection, cancel_flag, deadline);
            break :blk waitLocked(alloc, entry, io, start_completions, cancel_flag, deadline);
        },
        .wait => waitLocked(alloc, entry, io, entry.completions, cancel_flag, deadline),
        .fail => |reason| switch (reason) {
            .helper => error.HelperFailed,
        },
        .deliver, .fail_waiters, .stop_run, .none => error.HelperFailed,
    };
}

fn findEntryLocked(identity: [32]u8) ?*Entry {
    for (&entries) |*entry| {
        if (entry.occupied and std.mem.eql(u8, &entry.identity, &identity)) return entry;
    }
    return null;
}

fn findOrCreateEntryLocked(identity: [32]u8) TokenError!*Entry {
    var free_slot: ?*Entry = null;
    for (&entries) |*entry| {
        if (entry.occupied) {
            if (std.mem.eql(u8, &entry.identity, &identity)) return entry;
        } else if (free_slot == null) {
            free_slot = entry;
        }
    }
    const slot = free_slot orelse return error.TooManyConnections;
    slot.* = .{ .occupied = true, .identity = identity };
    return slot;
}

fn expireIfNeededLocked(entry: *Entry, io: std.Io) void {
    if (entry.state.cached == 0 or entry.state.cached_expired) return;
    const expires_at_s = entry.held_expires_at_s orelse return;
    const now_s = std.math.cast(
        i64,
        @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s),
    ) orelse std.math.maxInt(i64);
    if (expires_at_s -| expiry_margin_s <= now_s) {
        command_token.expired(&entry.state, entry.state.cached);
        debug_trace.logf("command_auth", "event=token_expired conn={x} gen={d}", .{
            entry.identity[0..4],
            entry.state.cached,
        });
    }
}

fn startRunLocked(
    entry: *Entry,
    io: std.Io,
    connection: Connection,
    cancel_flag: *const std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) TokenError!void {
    // Unlock while awaiting the previous task because a cancelled runTask locks
    // `mutex` before returning.
    if (entry.task) |*existing| {
        var old_task = existing.*;
        entry.task = null;
        mutex.unlock(io);
        old_task.await(io);
        mutex.lockUncancelable(io);
    }

    if (entry.state.waiters == 1) {
        if (cancel_flag.load(.acquire)) {
            cancelWaiterLocked(entry);
            return error.Cancelled;
        }
        if (deadlineExpired(io, deadline)) {
            cancelWaiterLocked(entry);
            return error.Timeout;
        }
    }

    entry.freeTaskInputs();
    const c_alloc = std.heap.c_allocator;
    const argv_copy = dupeArgv(c_alloc, connection.argv) catch {
        failRunLocked(entry, io, null);
        return error.OutOfMemory;
    };
    const cwd_copy = if (connection.cwd) |cwd|
        c_alloc.dupe(u8, cwd) catch {
            freeArgv(c_alloc, argv_copy);
            failRunLocked(entry, io, null);
            return error.OutOfMemory;
        }
    else
        null;

    entry.task_argv = argv_copy;
    entry.task_cwd = cwd_copy;
    entry.run_cancel.store(false, .release);
    entry.active_run_id +%= 1;
    const run_id = entry.active_run_id;

    entry.task = std.Io.concurrent(io, runTask, .{ entry, run_id }) catch {
        entry.freeTaskInputs();
        const message = c_alloc.dupe(u8, "fx could not start the sign-in helper") catch null;
        failRunLocked(entry, io, message);
        return error.HelperFailed;
    };
    debug_trace.logf("command_auth", "event=run_started conn={x}", .{entry.identity[0..4]});
}

fn waitLocked(
    alloc: std.mem.Allocator,
    entry: *Entry,
    io: std.Io,
    start_completions: u64,
    cancel_flag: *const std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) TokenError!Lease {
    while (true) {
        if (entry.completions > start_completions) {
            if (!entry.last_run_succeeded) return error.HelperFailed;
            return buildHeldLeaseLocked(alloc, entry, entry.held_gen);
        }
        if (cancel_flag.load(.acquire)) {
            cancelWaiterLocked(entry);
            return error.Cancelled;
        }
        if (deadlineExpired(io, deadline)) {
            cancelWaiterLocked(entry);
            return error.Timeout;
        }
        entry.changed.waitTimeout(io, &mutex, .{
            .duration = .{ .raw = .fromMilliseconds(wait_poll_ms), .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => {
                cancelWaiterLocked(entry);
                return error.Cancelled;
            },
        };
    }
}

fn cancelWaiterLocked(entry: *Entry) void {
    if (command_token.cancelled(&entry.state, true) == .stop_run) {
        entry.active_run_id +%= 1;
        entry.run_cancel.store(true, .release);
        debug_trace.logf("command_auth", "event=run_stopped conn={x}", .{entry.identity[0..4]});
    }
}

fn runTask(entry: *Entry, run_id: u64) void {
    const c_alloc = std.heap.c_allocator;
    const io = io_mod.getIo();
    const argv: []const []const u8 = entry.task_argv orelse &.{};
    var result = command_helper.run(
        c_alloc,
        argv,
        entry.task_cwd,
        &entry.run_cancel,
        command_helper.run_timeout_ms,
    ) catch {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (run_id != entry.active_run_id) return;
        const message = c_alloc.dupe(u8, "fx ran out of memory running the sign-in helper") catch null;
        failRunLocked(entry, io, message);
        return;
    };
    defer result.deinit(c_alloc);

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (run_id != entry.active_run_id) return;

    switch (result) {
        .ok => |*output| switch (command_token.printed(&entry.state)) {
            .deliver => |gen| {
                entry.replaceHeld(output.token, output.expires_at_s, output.headers, gen);
                output.token = &.{};
                output.headers = &.{};
                entry.last_run_succeeded = true;
                entry.completions += 1;
                entry.changed.broadcast(io);
                debug_trace.logf("command_auth", "event=token_delivered conn={x} gen={d}", .{
                    entry.identity[0..4],
                    gen,
                });
            },
            else => {},
        },
        .failed => |*failed| switch (command_token.runEnded(&entry.state)) {
            .fail_waiters => {
                const message = failed.message;
                failed.message = &.{};
                entry.setFailureMessage(message);
                entry.last_run_succeeded = false;
                entry.completions += 1;
                entry.changed.broadcast(io);
                debug_trace.logf("command_auth", "event=run_failed conn={x} kind={s}", .{
                    entry.identity[0..4],
                    @tagName(failed.failure),
                });
            },
            else => {},
        },
    }
}

fn failRunLocked(entry: *Entry, io: std.Io, message: ?[]u8) void {
    if (command_token.runEnded(&entry.state) == .fail_waiters) {
        entry.setFailureMessage(message);
        entry.last_run_succeeded = false;
        entry.completions += 1;
        entry.changed.broadcast(io);
        debug_trace.logf("command_auth", "event=run_failed conn={x}", .{entry.identity[0..4]});
    } else if (message) |unused| {
        std.heap.c_allocator.free(unused);
    }
}

fn buildHeldLeaseLocked(alloc: std.mem.Allocator, entry: *const Entry, gen: command_token.Gen) TokenError!Lease {
    const held_token = entry.held_token orelse return error.HelperFailed;
    const held_headers = entry.held_headers orelse &.{};
    const token_copy = try alloc.dupe(u8, held_token);
    errdefer secret.zeroAndFree(alloc, token_copy);
    const headers_copy = try dupeHeaders(alloc, held_headers);
    return .{
        .token = token_copy,
        .gen = gen,
        .headers = headers_copy,
    };
}

fn deadlineExpired(io: std.Io, deadline: ?std.Io.Clock.Timestamp) bool {
    const limit = deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io, limit.clock);
    return !now.compare(.lt, limit);
}

fn dupeHeaders(alloc: std.mem.Allocator, headers: []const command_helper.Header) std.mem.Allocator.Error![]command_helper.Header {
    const copy = try alloc.alloc(command_helper.Header, headers.len);
    var filled: usize = 0;
    errdefer {
        freeHeaders(alloc, copy[0..filled]);
        alloc.free(copy);
    }
    for (headers) |header| {
        const name = try alloc.dupe(u8, header.name);
        errdefer alloc.free(name);
        const value = try alloc.dupe(u8, header.value);
        copy[filled] = .{ .name = name, .value = value };
        filled += 1;
    }
    return copy;
}

fn freeHeaders(alloc: std.mem.Allocator, headers: []command_helper.Header) void {
    for (headers) |header| {
        alloc.free(header.name);
        secret.zeroAndFree(alloc, header.value);
    }
}

fn dupeArgv(alloc: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error![][]u8 {
    const copy = try alloc.alloc([]u8, argv.len);
    var filled: usize = 0;
    errdefer freeArgv(alloc, copy[0..filled]);
    for (argv) |arg| {
        copy[filled] = try alloc.dupe(u8, arg);
        filled += 1;
    }
    return copy;
}

fn freeArgv(alloc: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

fn resetForTest() void {
    shutdown();
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    for (&entries) |*entry| entry.clear();
}

fn waiterCountForTest(identity: [32]u8) u16 {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const entry = findEntryLocked(identity) orelse return 0;
    return entry.state.waiters;
}

fn isRunningForTest(identity: [32]u8) bool {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const entry = findEntryLocked(identity) orelse return false;
    return entry.state.running;
}

fn testIdentity(tag: u8) [32]u8 {
    return @splat(tag);
}

fn readCounterFile(dir: std.Io.Dir) ![]u8 {
    const file = try dir.openFile(io_mod.getIo(), "count", .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(std.testing.allocator, @constCast(&file), 64);
}

fn expectCounter(dir: std.Io.Dir, expected: []const u8) !void {
    const raw = try readCounterFile(dir);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, raw, " \r\n\t"));
}

const counter_script =
    "n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; printf '{\"token\":\"t%s\",\"headers\":{\"X-Team\":\"blue\"}}' $n";

test "first token runs helper once and second reuses cached token" {
    resetForTest();
    defer resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const cancel = std.atomic.Value(bool).init(false);
    const conn: Connection = .{
        .identity = testIdentity(1),
        .argv = &.{ "/bin/sh", "-c", counter_script },
        .cwd = cwd,
    };

    var first = try token(std.testing.allocator, conn, &cancel, null);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", first.token);
    try std.testing.expectEqual(@as(command_token.Gen, 1), first.gen);
    try std.testing.expectEqual(@as(usize, 1), first.headers.len);
    try std.testing.expectEqualStrings("X-Team", first.headers[0].name);
    try std.testing.expectEqualStrings("blue", first.headers[0].value);
    try expectCounter(tmp.dir, "1");

    var second = try token(std.testing.allocator, conn, &cancel, null);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", second.token);
    try std.testing.expectEqual(@as(command_token.Gen, 1), second.gen);
    try expectCounter(tmp.dir, "1");
}

test "two concurrent token calls run helper once and both receive t1" {
    resetForTest();
    defer resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const script =
        "sleep 0.15; n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; printf '{\"token\":\"t%s\"}' $n";
    const cancel = std.atomic.Value(bool).init(false);
    const conn: Connection = .{
        .identity = testIdentity(2),
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = cwd,
    };

    const Worker = struct {
        conn: Connection,
        cancel: *const std.atomic.Value(bool),
        lease: ?Lease = null,
        err: ?TokenError = null,

        fn run(self: *@This()) void {
            self.lease = token(std.testing.allocator, self.conn, self.cancel, null) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var w1: Worker = .{ .conn = conn, .cancel = &cancel };
    var w2: Worker = .{ .conn = conn, .cancel = &cancel };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});
    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(?TokenError, null), w1.err);
    try std.testing.expectEqual(@as(?TokenError, null), w2.err);
    var l1 = w1.lease.?;
    defer l1.deinit(std.testing.allocator);
    var l2 = w2.lease.?;
    defer l2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", l1.token);
    try std.testing.expectEqualStrings("t1", l2.token);
    try std.testing.expectEqual(@as(command_token.Gen, 1), l1.gen);
    try std.testing.expectEqual(@as(command_token.Gen, 1), l2.gen);
    try expectCounter(tmp.dir, "1");
}

test "refused drops cached token and next token call runs helper again" {
    resetForTest();
    defer resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const cancel = std.atomic.Value(bool).init(false);
    const id = testIdentity(3);
    const conn: Connection = .{
        .identity = id,
        .argv = &.{ "/bin/sh", "-c", counter_script },
        .cwd = cwd,
    };

    var initial = try token(std.testing.allocator, conn, &cancel, null);
    initial.deinit(std.testing.allocator);
    try expectCounter(tmp.dir, "1");

    refused(id, 1);

    var refreshed = try token(std.testing.allocator, conn, &cancel, null);
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t2", refreshed.token);
    try std.testing.expectEqual(@as(command_token.Gen, 2), refreshed.gen);
    try expectCounter(tmp.dir, "2");
}

test "refused for older generation keeps newer cached token" {
    resetForTest();
    defer resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const cancel = std.atomic.Value(bool).init(false);
    const id = testIdentity(4);
    const conn: Connection = .{
        .identity = id,
        .argv = &.{ "/bin/sh", "-c", counter_script },
        .cwd = cwd,
    };

    var first = try token(std.testing.allocator, conn, &cancel, null);
    first.deinit(std.testing.allocator);
    refused(id, 1);
    var second = try token(std.testing.allocator, conn, &cancel, null);
    second.deinit(std.testing.allocator);
    try expectCounter(tmp.dir, "2");

    refused(id, 1);

    var reused = try token(std.testing.allocator, conn, &cancel, null);
    defer reused.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t2", reused.token);
    try std.testing.expectEqual(@as(command_token.Gen, 2), reused.gen);
    try expectCounter(tmp.dir, "2");
}

test "helper non-zero exit records terminal-safe lastFailure" {
    resetForTest();
    defer resetForTest();

    const cancel = std.atomic.Value(bool).init(false);
    const id = testIdentity(5);
    const conn: Connection = .{
        .identity = id,
        .argv = &.{ "/bin/sh", "-c", "printf 'no session\\n' >&2; exit 3" },
    };

    try std.testing.expectError(error.HelperFailed, token(std.testing.allocator, conn, &cancel, null));
    const message = (try lastFailure(std.testing.allocator, id)).?;
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.find(u8, message, "no session") != null);
}

test "expired token triggers another helper run on next token call" {
    resetForTest();
    defer resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const script =
        "n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; printf '{\"token\":\"t%s\",\"expires_at\":1}' $n";
    const cancel = std.atomic.Value(bool).init(false);
    const conn: Connection = .{
        .identity = testIdentity(6),
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = cwd,
    };

    var first = try token(std.testing.allocator, conn, &cancel, null);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", first.token);
    try expectCounter(tmp.dir, "1");

    var second = try token(std.testing.allocator, conn, &cancel, null);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t2", second.token);
    try std.testing.expectEqual(@as(command_token.Gen, 2), second.gen);
    try expectCounter(tmp.dir, "2");
}

test "cancelling single waiter stops slow helper within two seconds" {
    resetForTest();
    defer resetForTest();

    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(100 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var canceller: Canceller = .{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    defer thread.join();

    const conn: Connection = .{
        .identity = testIdentity(7),
        .argv = &.{ "/bin/sh", "-c", "exec sleep 5" },
    };
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(error.Cancelled, token(std.testing.allocator, conn, &cancel, null));
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "cancelling one of two waiters returns Cancelled to it while second receives token" {
    resetForTest();
    defer resetForTest();

    const id = testIdentity(8);
    const conn: Connection = .{
        .identity = id,
        .argv = &.{ "/bin/sh", "-c", "sleep 1; printf '{\"token\":\"shared-ok\"}'" },
    };

    const Worker = struct {
        conn: Connection,
        cancel: *const std.atomic.Value(bool),
        lease: ?Lease = null,
        err: ?TokenError = null,

        fn run(self: *@This()) void {
            self.lease = token(std.testing.allocator, self.conn, self.cancel, null) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var cancel1 = std.atomic.Value(bool).init(false);
    const cancel2 = std.atomic.Value(bool).init(false);
    var w1: Worker = .{ .conn = conn, .cancel = &cancel1 };
    var w2: Worker = .{ .conn = conn, .cancel = &cancel2 };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});

    const wait_start = io_mod.milliTimestamp();
    while (waiterCountForTest(id) < 2 and io_mod.milliTimestamp() - wait_start < 2_000) {
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u16, 2), waiterCountForTest(id));

    const cancel_start = io_mod.milliTimestamp();
    cancel1.store(true, .release);
    t1.join();
    try std.testing.expect(io_mod.milliTimestamp() - cancel_start < 2_000);
    try std.testing.expectEqual(@as(?TokenError, error.Cancelled), w1.err);

    t2.join();
    try std.testing.expectEqual(@as(?TokenError, null), w2.err);
    var l2 = w2.lease.?;
    defer l2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shared-ok", l2.token);
}

test "expired deadline returns error.Timeout within two seconds" {
    resetForTest();
    defer resetForTest();

    const cancel = std.atomic.Value(bool).init(false);
    const conn: Connection = .{
        .identity = testIdentity(9),
        .argv = &.{ "/bin/sh", "-c", "exec sleep 5" },
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(200),
    });

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(error.Timeout, token(std.testing.allocator, conn, &cancel, deadline));
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "shutdown during slow run returns within two seconds" {
    resetForTest();
    defer resetForTest();

    const id = testIdentity(10);
    const conn: Connection = .{
        .identity = id,
        .argv = &.{ "/bin/sh", "-c", "exec sleep 5" },
    };

    const Worker = struct {
        conn: Connection,
        cancel: std.atomic.Value(bool) = .init(false),
        err: ?TokenError = null,

        fn run(self: *@This()) void {
            var lease = token(std.testing.allocator, self.conn, &self.cancel, null) catch |err| {
                self.err = err;
                return;
            };
            lease.deinit(std.testing.allocator);
        }
    };

    var worker: Worker = .{ .conn = conn };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    const wait_start = io_mod.milliTimestamp();
    while (!isRunningForTest(id) and io_mod.milliTimestamp() - wait_start < 2_000) {
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(isRunningForTest(id));

    const shutdown_start = io_mod.milliTimestamp();
    shutdown();
    try std.testing.expect(io_mod.milliTimestamp() - shutdown_start < 2_000);

    thread.join();
    try std.testing.expectEqual(@as(?TokenError, error.HelperFailed), worker.err);
}

test "table limit rejects connection past max_providers" {
    resetForTest();
    defer resetForTest();

    const cancel = std.atomic.Value(bool).init(false);
    for (0..configured_provider.max_providers) |i| {
        const id = testIdentity(@intCast(100 + i));
        const conn: Connection = .{
            .identity = id,
            .argv = &.{ "/bin/sh", "-c", "printf '{\"token\":\"ok\"}'" },
        };
        var lease = try token(std.testing.allocator, conn, &cancel, null);
        lease.deinit(std.testing.allocator);
    }

    const extra: Connection = .{
        .identity = testIdentity(200),
        .argv = &.{ "/bin/sh", "-c", "printf '{\"token\":\"ok\"}'" },
    };
    try std.testing.expectError(error.TooManyConnections, token(std.testing.allocator, extra, &cancel, null));
}
