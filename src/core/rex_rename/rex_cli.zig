//! Runs the `rex` command for the session rename. Every call has a deadline
//! and a cancel flag. Each child leads its own process group, and every exit
//! path kills that group and reaps the child before the call returns.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

/// A `rex` call talks to a local socket; a slower one is treated as failed.
pub const default_deadline_ms: u64 = 5000;

const trace_scope = "rex_rename";
const poll_step_ms: u64 = 20;
const read_buf_bytes = 4096;
const max_argv = 8;

pub const Cli = struct {
    rex_path: []const u8,
    deadline_ms: u64 = default_deadline_ms,
    cancel: *const std.atomic.Value(bool),

    /// Runs `rex <args>` and returns its stdout when it exits 0 and the
    /// output fits in `out`. Null otherwise. The result points into `out`.
    pub fn capture(self: *const Cli, args: []const []const u8, out: []u8) ?[]const u8 {
        var argv_buf: [max_argv][]const u8 = undefined;
        if (args.len + 1 > argv_buf.len) return null;
        argv_buf[0] = self.rex_path;
        @memcpy(argv_buf[1 .. args.len + 1], args);
        return self.run(argv_buf[0 .. args.len + 1], out);
    }

    fn run(self: *const Cli, argv: []const []const u8, out: []u8) ?[]const u8 {
        if (self.cancel.load(.acquire)) return null;
        const io = io_mod.getIo();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            traceFailure("spawn", err);
            return null;
        };
        defer reap(io, &child);

        const pid = child.id orelse return null;
        const stdout = child.stdout orelse return null;
        const budget_ms: i64 = std.math.cast(i64, self.deadline_ms) orelse std.math.maxInt(i64);
        var watch: Watch = .{
            .pid = pid,
            .deadline_at_ms = io_mod.awakeMilliTimestamp() +| budget_ms,
            .cancel = self.cancel,
        };
        var watcher = io.concurrent(Watch.run, .{&watch}) catch |err| {
            traceFailure("watch task", err);
            return null;
        };
        const bytes = readBounded(io, stdout, out);
        watch.done.store(true, .release);
        watcher.await(io);

        killGroup(pid);
        const captured = bytes orelse return null;
        const term = child.wait(io) catch |err| {
            traceFailure("wait", err);
            return null;
        };
        return switch (term) {
            .exited => |code| if (code == 0) captured else blk: {
                debug_trace.logf(trace_scope, "rex call failed step=exit code={d}", .{code});
                break :blk null;
            },
            .signal, .stopped, .unknown => blk: {
                debug_trace.logf(trace_scope, "rex call failed step=exit reason=signal", .{});
                break :blk null;
            },
        };
    }
};

/// Kills the child's process group when the deadline passes or the cancel
/// flag turns true. It runs as its own task, and the caller awaits it before
/// the group is killed again, so no pid is signalled after it was reaped.
const Watch = struct {
    pid: std.process.Child.Id,
    deadline_at_ms: i64,
    cancel: *const std.atomic.Value(bool),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            if (self.cancel.load(.acquire) or io_mod.awakeMilliTimestamp() >= self.deadline_at_ms) {
                killGroup(self.pid);
                return;
            }
            // A blocked read has no deadline of its own, so the watcher checks
            // the clock and the cancel flag in short steps.
            io_mod.sleep(poll_step_ms * std.time.ns_per_ms);
        }
    }
};

/// Kills every process in the group that the child leads. The child was
/// spawned with `pgid = 0`, so the group id is the child's pid.
fn killGroup(pid: std.process.Child.Id) void {
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
        // The group is gone. macOS returns EPERM for a group whose only
        // member has exited but is not reaped yet.
        error.ProcessNotFound, error.PermissionDenied => {},
        else => traceFailure("kill group", err),
    };
}

/// Ends the call's process group, then reaps the child. A child that was
/// already waited for has no id, so its pid is not signalled once it is free.
fn reap(io: std.Io, child: *std.process.Child) void {
    if (child.id) |pid| killGroup(pid);
    child.kill(io);
}

/// Reads at most `out.len` bytes. Null when the output is longer, or on a read error.
fn readBounded(io: std.Io, file: std.Io.File, out: []u8) ?[]const u8 {
    var read_buf: [read_buf_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const got = reader.interface.readSliceShort(out) catch |err| {
        traceFailure("read", err);
        return null;
    };
    if (got < out.len) return out[0..got];
    _ = reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => return out[0..got],
        else => {
            traceFailure("read", err);
            return null;
        },
    };
    debug_trace.logf(trace_scope, "rex output over the cap bytes={d}", .{out.len});
    return null;
}

fn traceFailure(step: []const u8, err: anyerror) void {
    debug_trace.logf(trace_scope, "rex call failed step={s} error={s}", .{ step, @errorName(err) });
}

const testing = std.testing;

/// A fake `rex` script in its own tmp folder.
const Fake = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    rex_path: []const u8,

    fn create(script: []const u8) !Fake {
        const io = io_mod.getIo();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        try tmp.dir.writeFile(io, .{ .sub_path = "rex", .data = script });
        try tmp.dir.setFilePermissions(io, "rex", std.Io.File.Permissions.fromMode(0o755), .{});
        const root = try io_mod.dirRealpathAlloc(arena.allocator(), tmp.dir, ".");
        const rex_path = try std.Io.Dir.path.join(arena.allocator(), &.{ root, "rex" });
        return .{ .tmp = tmp, .arena = arena, .rex_path = rex_path };
    }

    fn deinit(self: *Fake) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "a rex call returns its output only when rex exits 0" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var ok = try Fake.create("#!/bin/sh\nprintf '%s|' \"$@\"\n");
    defer ok.deinit();
    var out: [256]u8 = undefined;
    const cli: Cli = .{ .rex_path = ok.rex_path, .cancel = &cancel };
    try testing.expectEqualStrings("session|rename|--|block:1|a b|", cli.capture(&.{ "session", "rename", "--", "block:1", "a b" }, &out).?);

    var failing = try Fake.create("#!/bin/sh\necho partial\nexit 1\n");
    defer failing.deinit();
    const bad: Cli = .{ .rex_path = failing.rex_path, .cancel = &cancel };
    try testing.expect(bad.capture(&.{"ls"}, &out) == null);

    const missing: Cli = .{ .rex_path = "/nonexistent/fx-test/rex", .cancel = &cancel };
    try testing.expect(missing.capture(&.{"ls"}, &out) == null);
}

test "a rex call that prints more than the cap is refused" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var fake = try Fake.create("#!/bin/sh\nprintf '0123456789'\n");
    defer fake.deinit();
    var out: [4]u8 = undefined;
    const cli: Cli = .{ .rex_path = fake.rex_path, .cancel = &cancel };
    try testing.expect(cli.capture(&.{"ls"}, &out) == null);
}

test "a rex call that hangs past its deadline is killed with its group" {
    var cancel: std.atomic.Value(bool) = .init(false);
    // The child keeps stdout open in a grandchild, so only a group kill ends the read.
    var fake = try Fake.create("#!/bin/sh\nsleep 30 &\nsleep 30\n");
    defer fake.deinit();
    var out: [64]u8 = undefined;
    const cli: Cli = .{ .rex_path = fake.rex_path, .cancel = &cancel, .deadline_ms = 200 };
    const started = io_mod.awakeMilliTimestamp();
    try testing.expect(cli.capture(&.{"ls"}, &out) == null);
    try testing.expect(io_mod.awakeMilliTimestamp() - started < 10_000);
}

test "a cancelled rex call does not start" {
    var cancel: std.atomic.Value(bool) = .init(true);
    var fake = try Fake.create("#!/bin/sh\necho ran\n");
    defer fake.deinit();
    var out: [64]u8 = undefined;
    const cli: Cli = .{ .rex_path = fake.rex_path, .cancel = &cancel };
    try testing.expect(cli.capture(&.{"ls"}, &out) == null);
}
