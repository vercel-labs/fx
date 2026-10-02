//! Best-effort native Otty lifecycle reports. The movable client owns a stable
//! heap runtime; only its joined worker spawns and waits for CLI processes.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const types = @import("../../core/shared/types.zig");
const app_session_runtime = @import("../../core/app/app_session_runtime.zig");

pub const State = enum { processing, idle, awaiting, @"error" };

const native_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
const queue_capacity = 16;
const session_prefix = "session-id=";
const child_timeout: std.Io.Clock.Duration = .{
    .clock = .awake,
    .raw = .fromMilliseconds(400),
};

pub const Client = struct {
    enabled: bool = false,
    runtime: ?*Runtime = null,

    /// Initialize before starting producers. Allocation or thread failures leave
    /// the integration disabled; ownership may move with Client afterwards.
    pub fn initFromEnv(self: *Client, alloc: std.mem.Allocator) void {
        if (comptime !native_supported) return;
        if (self.runtime != null or !should_enable(io_mod.getenv("FX_OTTY"), io_mod.getenv("TERM_PROGRAM"))) return;

        const runtime = alloc.create(Runtime) catch return;
        runtime.* = .{ .alloc = alloc, .io = io_mod.getIo() };
        runtime.pid_arg = std.fmt.bufPrint(&runtime.pid_buffer, "agent-pid={d}", .{std.c.getpid()}) catch {
            alloc.destroy(runtime);
            return;
        };
        runtime.thread = std.Thread.spawn(.{}, Runtime.run, .{runtime}) catch {
            alloc.destroy(runtime);
            return;
        };
        self.runtime = runtime;
        self.enabled = true;
    }

    /// Concurrent producers are serialized by the runtime mutex. Session bytes
    /// are copied before returning; no subprocess work happens on the caller.
    pub fn report(self: *Client, state: State, session_id: ?[]const u8) void {
        if (comptime !native_supported) return;
        if (!self.enabled) return;
        const runtime = self.runtime orelse return;
        const io = runtime.io;
        runtime.mutex.lockUncancelable(io);
        defer runtime.mutex.unlock(io);
        if (runtime.stopping) return;

        runtime.foreground_state = state;
        runtime.enqueue(if (runtime.child_approval_waiting) .awaiting else state, session_id);
    }

    /// Child approvals share the pane but do not stop the foreground worker.
    /// Keep its latest state underneath the attention indicator.
    pub fn sync_child_approval(self: *Client, waiting: bool, parent_permission_waiting: bool, session_id: ?[]const u8) void {
        if (comptime !native_supported) return;
        const runtime = self.runtime orelse return;
        runtime.mutex.lockUncancelable(runtime.io);
        defer runtime.mutex.unlock(runtime.io);
        if (runtime.stopping or runtime.child_approval_waiting == waiting) return;
        // Replacing a child prompt with a parent prompt does not reopen the UI,
        // so its usual inactive-to-active attention hook will not run.
        if (parent_permission_waiting) runtime.foreground_state = .awaiting;
        runtime.child_approval_waiting = waiting;
        runtime.enqueue(if (waiting) .awaiting else runtime.foreground_state, session_id);
    }

    fn attention(self: *Client, kind: hooks.AttentionKind, session_id: ?[]const u8) void {
        if (comptime !native_supported) return;
        const runtime = self.runtime orelse return;
        runtime.mutex.lockUncancelable(runtime.io);
        defer runtime.mutex.unlock(runtime.io);
        if (runtime.stopping) return;
        // sync_child_approval already reported this child-owned permission.
        if (kind == .permission and runtime.child_approval_waiting) return;
        runtime.foreground_state = .awaiting;
        runtime.enqueue(.awaiting, session_id);
    }

    /// Session switches happen after foreground execution settles. Register the
    /// new identity without replacing activity reports for an unchanged session.
    pub fn sync_session(self: *Client, session_id: ?[]const u8) void {
        if (comptime !native_supported) return;
        const runtime = self.runtime orelse return;
        runtime.mutex.lockUncancelable(runtime.io);
        defer runtime.mutex.unlock(runtime.io);
        if (runtime.stopping) return;
        if (runtime.latest()) |event| {
            if (event.matches_session(session_id)) return;
        }
        runtime.foreground_state = .idle;
        runtime.child_approval_waiting = false;
        runtime.enqueue(.idle, session_id);
    }

    /// Call only after all report producers (including the foreground worker)
    /// have joined. At most the active child and one final report remain to wait.
    pub fn deinit(self: *Client) void {
        if (comptime !native_supported) return;
        const runtime = self.runtime orelse return;
        const io = runtime.io;
        runtime.mutex.lockUncancelable(io);
        runtime.stopping = true;
        if (runtime.queue_len > 1) {
            const final = runtime.queue[runtime.queue_len - 1];
            runtime.queue_len -= 1;
            runtime.discard_pending();
            runtime.queue[0] = final;
            runtime.queue_len = 1;
        }
        runtime.wake.signal(io);
        runtime.mutex.unlock(io);
        runtime.thread.?.join();
        if (runtime.last) |event| event.deinit(runtime.alloc);
        const alloc = runtime.alloc;
        alloc.destroy(runtime);
        self.* = .{};
    }
};

/// Registers before the notification provider freezes the lifecycle runtime.
/// The shared terminal status provider owns the worker's single foreground
/// observer and forwards resume and settle events to `foreground_working` and
/// `foreground_settled` while Otty is enabled.
pub fn Hooks(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            app.otty.initFromEnv(app.alloc);
            if (!app.otty.enabled) return;
            app.otty.sync_session(app_session_runtime.Runtime(App).activeSessionId(app));
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.otty.turn_end",
                .ctx = app,
                .run = turn_ended,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.otty.attention_required",
                .ctx = app,
                .run = attention_required,
            });
        }

        pub fn foreground_working(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.otty.report(.processing, app_session_runtime.Runtime(App).activeSessionId(app));
        }

        pub fn foreground_settled(raw: *anyopaque, outcome: types.TurnPresentationOutcome) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.otty.report(outcome_state(outcome), app_session_runtime.Runtime(App).activeSessionId(app));
        }

        fn turn_ended(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            if (input.invocation.scope.kind != .interactive) return;
            const app: *App = @ptrCast(@alignCast(raw));
            app.otty.report(outcome_state(input.outcome), input.invocation.scope.session_id);
        }

        fn attention_required(raw: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
            if (input.invocation.scope.kind != .interactive) return;
            const app: *App = @ptrCast(@alignCast(raw));
            app.otty.attention(input.kind, input.invocation.scope.session_id);
        }
    };
}

fn outcome_state(outcome: types.TurnPresentationOutcome) State {
    return switch (outcome) {
        .completed, .interrupted => .idle,
        .failed => .@"error",
        .paused => .awaiting,
    };
}

fn should_enable(fx_otty: ?[]const u8, term_program: ?[]const u8) bool {
    if (!native_supported) return false;
    if (fx_otty) |value| {
        if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) return false;
    }
    return std.mem.eql(u8, term_program orelse return false, "otty");
}

const Event = struct {
    state: State,
    session_arg: ?[]u8,

    fn matches(self: Event, state: State, session_id: ?[]const u8) bool {
        return self.state == state and self.matches_session(session_id);
    }

    fn matches_session(self: Event, session_id: ?[]const u8) bool {
        const arg = self.session_arg orelse return session_id == null;
        return std.mem.eql(u8, arg[session_prefix.len..], session_id orelse return false);
    }

    fn deinit(self: Event, alloc: std.mem.Allocator) void {
        if (self.session_arg) |arg| alloc.free(arg);
    }
};

const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    foreground_state: State = .idle,
    child_approval_waiting: bool = false,
    queue: [queue_capacity]Event = undefined,
    queue_len: usize = 0,
    // Owns the in-flight (or most recently attempted) report. Kept until the next
    // dequeue so duplicate suppression also works when the queue is empty.
    last: ?Event = null,
    pid_buffer: [32]u8 = undefined,
    pid_arg: []const u8 = &.{},

    fn latest(self: *Runtime) ?Event {
        return if (self.queue_len > 0) self.queue[self.queue_len - 1] else self.last;
    }

    // Caller holds mutex; event ownership never escapes the runtime.
    fn enqueue(self: *Runtime, state: State, session_id: ?[]const u8) void {
        if (self.latest()) |event| {
            if (event.matches(state, session_id)) return;
        }
        const event: Event = .{
            .state = state,
            .session_arg = if (session_id) |id|
                std.fmt.allocPrint(self.alloc, session_prefix ++ "{s}", .{id}) catch return
            else
                null,
        };
        // Preserve FIFO normally; overflow retains the latest instead of blocking.
        if (self.queue_len == queue_capacity) self.discard_pending();
        self.queue[self.queue_len] = event;
        self.queue_len += 1;
        self.wake.signal(self.io);
    }

    // All event allocation/free operations are serialized by this mutex.
    fn discard_pending(self: *Runtime) void {
        for (self.queue[0..self.queue_len]) |event| event.deinit(self.alloc);
        self.queue_len = 0;
    }

    fn run(self: *Runtime) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue_len == 0 and !self.stopping) {
                self.wake.waitUncancelable(self.io, &self.mutex);
            }
            if (self.queue_len == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const event = self.queue[0];
            std.mem.copyForwards(Event, self.queue[0 .. self.queue_len - 1], self.queue[1..self.queue_len]);
            self.queue_len -= 1;
            if (self.last) |previous| previous.deinit(self.alloc);
            self.last = event;
            self.mutex.unlock(self.io);

            var argv_buffer: [9][]const u8 = undefined;
            send(self.io, report_argv(&argv_buffer, event, self.pid_arg));
        }
    }
};

// The returned argv borrows the buffer, event, and runtime PID argument.
fn report_argv(buffer: *[9][]const u8, event: Event, pid_arg: []const u8) []const []const u8 {
    const state_arg = switch (event.state) {
        inline else => |state| "state=" ++ @tagName(state),
    };
    // The colon shorthand is not recognized after global options.
    // Use the regular subcommand so the global IPC timeout is honored.
    buffer[0..7].* = .{ "otty", "--timeout", "200", "state", "fx", state_arg, pid_arg };
    var len: usize = 7;
    if (event.session_arg) |arg| {
        buffer[len] = arg;
        len += 1;
    }
    buffer[len] = "label=fx";
    return buffer[0 .. len + 1];
}

const ChildEvent = union(enum) {
    wait: std.process.Child.WaitError!std.process.Child.Term,
    timeout: std.Io.Cancelable!void,
};

fn wait_child(child: *std.process.Child, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn wait_deadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    return std.Io.Timeout.sleep(.{ .deadline = deadline }, io);
}

fn schedule_child_wait(select: *std.Io.Select(ChildEvent), child: *std.process.Child) std.Io.ConcurrentError!void {
    const io = select.io;
    select.concurrent(.wait, wait_child, .{ child, io }) catch |err| {
        // No wait task owns the child yet. Child.kill alone can block on SIGTERM.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        std.posix.kill(child.id.?, .KILL) catch {};
        _ = child.wait(io) catch {};
        return err;
    };
}

// Do not cancel the pending wait before killing: it owns collection of the
// child. Block cancellation until that wait has finished reaping the process.
fn stop_child(select: *std.Io.Select(ChildEvent), pid: std.process.Child.Id) void {
    const io = select.io;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    std.posix.kill(pid, .KILL) catch {};
    while (select.await()) |event| {
        if (event == .wait) break;
    } else |_| {}
    select.cancelDiscard();
}

fn send(io: std.Io, argv: []const []const u8) void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, child_timeout);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        debug_trace.logf("otty", "report spawn failed err={s}", .{@errorName(err)});
        return;
    };
    defer child.kill(io);
    const pid = child.id.?;
    var select_buffer: [2]ChildEvent = undefined;
    var select: std.Io.Select(ChildEvent) = .init(io, &select_buffer);
    schedule_child_wait(&select, &child) catch return;
    select.concurrent(.timeout, wait_deadline, .{ io, deadline }) catch {
        stop_child(&select, pid);
        return;
    };
    const event = select.await() catch {
        stop_child(&select, pid);
        return;
    };
    switch (event) {
        .wait => |result| {
            select.cancelDiscard();
            const term = result catch |err| {
                debug_trace.logf("otty", "report wait failed err={s}", .{@errorName(err)});
                return;
            };
            switch (term) {
                .exited => |code| debug_trace.logf("otty", "report exit status={d}", .{code}),
                else => debug_trace.logf("otty", "report terminated unexpectedly", .{}),
            }
        },
        .timeout => {
            debug_trace.logf("otty", "report timed out", .{});
            stop_child(&select, pid);
        },
    }
}

test "otty wait scheduling failure kills and reaps a SIGTERM-ignoring child" {
    if (comptime !native_supported) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf ready; exec /bin/sleep 5" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        child.kill(io);
    }
    const pid = child.id.?;
    var buffer: [16]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    var ready: [5]u8 = undefined;
    try reader.interface.readSliceAll(&ready);
    try std.testing.expectEqualStrings("ready", &ready);

    var vtable = io.vtable.*;
    vtable.groupConcurrent = struct {
        fn fail(
            _: ?*anyopaque,
            _: *std.Io.Group,
            _: []const u8,
            _: std.mem.Alignment,
            _: *const fn (*const anyopaque) void,
        ) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    }.fail;
    var select_buffer: [2]ChildEvent = undefined;
    var select: std.Io.Select(ChildEvent) = .init(.{ .userdata = io.userdata, .vtable = &vtable }, &select_buffer);
    defer select.cancelDiscard();
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.ConcurrencyUnavailable, schedule_child_wait(&select, &child));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);
    try std.testing.expectEqual(null, child.id);
    try std.testing.expectEqual(null, child.stdout);
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(waited));
}

test "otty child approval preserves foreground outcomes and other attention" {
    if (comptime !native_supported) return error.SkipZigTest;
    var runtime: Runtime = .{ .alloc = std.testing.allocator, .io = std.testing.io };
    defer runtime.discard_pending();
    var client: Client = .{ .enabled = true, .runtime = &runtime };
    client.report(.processing, "session");
    client.sync_child_approval(true, false, "session");
    client.attention(.permission, "session");
    client.sync_child_approval(false, false, "session");
    try std.testing.expectEqual(State.processing, runtime.latest().?.state);

    client.sync_child_approval(true, false, "session");
    client.attention(.question, "session");
    client.sync_child_approval(false, false, "session");
    try std.testing.expectEqual(State.awaiting, runtime.latest().?.state);

    client.report(.processing, "session");
    client.sync_child_approval(true, false, "session");
    client.sync_child_approval(false, true, "session");
    try std.testing.expectEqual(State.awaiting, runtime.latest().?.state);

    client.sync_child_approval(true, false, "session");
    client.report(.@"error", "session");
    try std.testing.expectEqual(State.awaiting, runtime.latest().?.state);
    client.sync_child_approval(false, false, "session");
    try std.testing.expectEqual(State.@"error", runtime.latest().?.state);
}

test "otty enablement requires its terminal and respects explicit opt-out" {
    std.testing.refAllDecls(Client);
    try std.testing.expectEqual(native_supported, should_enable(null, "otty"));
    try std.testing.expectEqual(native_supported, should_enable("1", "otty"));
    try std.testing.expect(!should_enable("0", "otty"));
    try std.testing.expect(!should_enable("FaLsE", "otty"));
    try std.testing.expect(!should_enable(null, null));
    try std.testing.expect(!should_enable("true", "other"));
}

test "otty argv uses fixed arguments and an optional literal session" {
    var buffer: [9][]const u8 = undefined;
    const without_session = report_argv(&buffer, .{ .state = .@"error", .session_arg = null }, "agent-pid=42");
    const expected = [_][]const u8{ "otty", "--timeout", "200", "state", "fx", "state=error", "agent-pid=42", "label=fx" };
    try std.testing.expectEqual(expected.len, without_session.len);
    for (expected, without_session) |want, actual| try std.testing.expectEqualStrings(want, actual);

    const session_arg = try std.testing.allocator.dupe(u8, "session-id=a b;$(ignored)");
    defer std.testing.allocator.free(session_arg);
    const event: Event = .{ .state = .awaiting, .session_arg = session_arg };
    const with_session = report_argv(&buffer, event, "agent-pid=42");
    try std.testing.expectEqual(@as(usize, 9), with_session.len);
    try std.testing.expectEqualStrings("state=awaiting", with_session[5]);
    try std.testing.expectEqualStrings(session_arg, with_session[7]);
    try std.testing.expectEqualStrings("label=fx", with_session[8]);
    try std.testing.expect(event.matches(.awaiting, "a b;$(ignored)"));
    try std.testing.expect(!event.matches(.awaiting, null));
    try std.testing.expect(!event.matches(.idle, "a b;$(ignored)"));
}
