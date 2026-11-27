//! Runs the Rex resume rule once per process, on a background thread, and
//! hands back its outcome when the app asks for it. `start` does no disk work.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const apply = @import("apply.zig");
const gate = @import("gate.zig");
const rex_cli = @import("rex_cli.zig");

pub const StartArgs = struct {
    env: gate.Env,
    workspace_root: []const u8,
    state_dir: []const u8, // <fx home>/rex
    sessions_dir: []const u8, // real path of fx's sessions/v2 folder
    exe_path: ?[]const u8,
    setting_on: bool,
    pid: u32,
};

const trace_scope = "rex_rule";

pub const Installer = struct {
    started: bool = false,
    /// Set when the attempt ends with no thread, such as a failed environment check.
    immediate: ?apply.Outcome = null,
    job: ?*Job = null,
    taken: bool = false,

    /// Starts the attempt once; later calls do nothing. Copies what it needs from `args`.
    /// `alloc` must be safe to use from a second thread, since the attempt runs there.
    pub fn start(self: *Installer, alloc: std.mem.Allocator, args: StartArgs) void {
        if (self.started) return;
        self.started = true;
        if (comptime builtin.single_threaded) {
            // A single-threaded build, such as a WASM surface, has no thread to run the attempt on.
            self.immediate = .none;
            return;
        }
        const maybe_job = Job.create(alloc, args) catch |err| {
            debug_trace.logf(trace_scope, "installer did not start error={s}", .{@errorName(err)});
            self.immediate = .none;
            return;
        };
        const job = maybe_job orelse {
            self.immediate = .none;
            return;
        };
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            debug_trace.logf(trace_scope, "installer thread did not start error={s}", .{@errorName(err)});
            job.destroy();
            self.immediate = .none;
            return;
        };
        self.job = job;
    }

    /// The outcome once the attempt has ended, returned once; null before that.
    pub fn takeOutcome(self: *Installer) ?apply.Outcome {
        if (self.taken) return null;
        const outcome = if (self.job) |job| blk: {
            if (!job.finished.load(.acquire)) return null;
            break :blk job.outcome;
        } else self.immediate orelse return null;
        self.taken = true;
        return outcome;
    }

    /// Cancels the attempt, kills a running `rex` child, and joins the thread. Fast.
    pub fn stopForProcessExit(self: *Installer) void {
        if (comptime builtin.single_threaded) return;
        const job = self.job orelse return;
        job.cancel.store(true, .release);
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
    }

    /// Frees everything. Calls stopForProcessExit first.
    pub fn deinit(self: *Installer) void {
        self.stopForProcessExit();
        if (self.job) |job| job.destroy();
        self.job = null;
    }
};

/// One attempt. Its arena owns every copy and every path. The attempt thread is
/// the only user of the arena while it runs, and the starting thread frees the
/// job only after that thread has been joined.
const Job = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    env: gate.EnvPass,
    workspace_root: []const u8,
    state_dir: []const u8,
    sessions_dir: []const u8,
    exe_path: ?[]const u8,
    setting_on: bool,
    pid: u32,
    cancel: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    outcome: apply.Outcome = .none,
    thread: ?std.Thread = null,

    /// Null when the environment check fails. No thread runs then.
    fn create(alloc: std.mem.Allocator, args: StartArgs) !?*Job {
        const job = try alloc.create(Job);
        job.* = .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .env = undefined,
            .workspace_root = undefined,
            .state_dir = undefined,
            .sessions_dir = undefined,
            .exe_path = null,
            .setting_on = args.setting_on,
            .pid = args.pid,
        };
        errdefer job.destroy();

        const a = job.arena.allocator();
        job.env = gate.envAllows(a, args.env) orelse {
            job.destroy();
            return null;
        };
        job.workspace_root = try a.dupe(u8, args.workspace_root);
        job.state_dir = try a.dupe(u8, args.state_dir);
        job.sessions_dir = try a.dupe(u8, args.sessions_dir);
        job.exe_path = if (args.exe_path) |exe| try a.dupe(u8, exe) else null;
        return job;
    }

    fn destroy(job: *Job) void {
        const alloc = job.alloc;
        job.arena.deinit();
        alloc.destroy(job);
    }

    fn run(job: *Job) void {
        job.outcome = job.attempt();
        job.finished.store(true, .release);
    }

    fn attempt(job: *Job) apply.Outcome {
        const rex_path = gate.rexPath(job.arena.allocator(), job.env.rex_bin_dir, job.workspace_root) orelse return .none;
        var cli: rex_cli.Cli = .{
            .rex_path = rex_path,
            .block = job.env.block,
            .cancel = &job.cancel,
        };
        return apply.run(job.alloc, cli.rex(), .{
            .config_dir = job.env.config_dir,
            .state_dir = job.state_dir,
            .sessions_dir = job.sessions_dir,
            .exe_path = job.exe_path,
        }, job.pid, job.setting_on);
    }
};

const testing = std.testing;
const test_pid: u32 = 4242;
const wait_deadline_ms: i64 = 5000;
const poll_step_ms: u64 = 20;

/// The start args for a passing environment, with every path under `root`.
fn passingArgs(a: std.mem.Allocator, root: []const u8) !StartArgs {
    return .{
        .env = .{
            .rex_bin_dir = try std.Io.Dir.path.join(a, &.{ root, "bin" }),
            .rex_block = "fx.block",
            .rex_server = "unix:///tmp/rex.sock",
            .xdg_config_home = null,
            .home = try std.Io.Dir.path.join(a, &.{ root, "home" }),
            .token_ok = true,
        },
        .workspace_root = try std.Io.Dir.path.join(a, &.{ root, "workspace" }),
        .state_dir = try std.Io.Dir.path.join(a, &.{ root, "state" }),
        .sessions_dir = try std.Io.Dir.path.join(a, &.{ root, "sessions/v2" }),
        .exe_path = null,
        .setting_on = true,
        .pid = test_pid,
    };
}

fn waitOutcome(installer: *Installer) !apply.Outcome {
    const started = io_mod.awakeMilliTimestamp();
    while (true) {
        if (installer.takeOutcome()) |outcome| return outcome;
        if (io_mod.awakeMilliTimestamp() - started > wait_deadline_ms) return error.InstallerTimedOut;
        // The outcome is an atomic with no event to block on, so the test polls it under a deadline.
        io_mod.sleep(poll_step_ms * std.time.ns_per_ms);
    }
}

test "rex resume installer with a failed environment check starts no thread and reports none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var args = try passingArgs(arena.allocator(), root);
    args.env.token_ok = false;

    var installer: Installer = .{};
    defer installer.deinit();
    installer.start(testing.allocator, args);
    try testing.expect(installer.job == null);
    try testing.expectEqual(apply.Outcome.none, installer.takeOutcome().?);
    try testing.expect(installer.takeOutcome() == null);
}

test "rex resume installer reports none when the rex file check fails on the attempt thread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(io_mod.getIo(), "bin");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var installer: Installer = .{};
    defer installer.deinit();
    installer.start(testing.allocator, try passingArgs(arena.allocator(), root));
    try testing.expect(installer.job != null);
    try testing.expectEqual(apply.Outcome.none, try waitOutcome(&installer));
}

test "rex resume installer runs the attempt and reports a trusted record as skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const root = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "workspace");
    try tmp.dir.createDirPath(io, "state");
    const script =
        \\#!/bin/sh
        \\case "$1" in
        \\  block) printf '%s' '{"records":[{"owner":{"pid":4242},"trusted":true}]}' ;;
        \\esac
        \\exit 0
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/rex", .data = script });
    try tmp.dir.setFilePermissions(io, "bin/rex", std.Io.File.Permissions.fromMode(0o755), .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var installer: Installer = .{};
    defer installer.deinit();
    installer.start(testing.allocator, try passingArgs(arena.allocator(), root));
    try testing.expect(installer.job != null);
    try testing.expectEqual(apply.Outcome.skipped, try waitOutcome(&installer));
    try testing.expect(installer.takeOutcome() == null);
    installer.stopForProcessExit();
}
