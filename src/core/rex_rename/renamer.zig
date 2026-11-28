//! Owns the background rename. The main thread asks with `request`, which
//! does no disk work. One task at a time checks the rex file, reads Rex's
//! rename option and the session's label, and renames the session. A title
//! that arrives while a call runs waits, and only the newest one is used.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const plan = @import("plan.zig");
const queue_rules = @import("queue.zig");
const answers = @import("answers.zig");
const gate = @import("gate.zig");
const rex_cli = @import("rex_cli.zig");

pub const Request = struct {
    env: gate.Env,
    workspace_root: []const u8,
    /// The `rex_session_rename` setting.
    setting_on: bool,
    /// The main chat's title.
    title: []const u8,
};

pub const Outcome = enum {
    renamed,
    already_named,
    named_by_someone_else,
    option_off,
    rex_unavailable,
    label_unreadable,
    rename_failed,
};

const trace_scope = "rex_rename";
/// `rex session rename` prints nothing when it works.
const max_rename_output_bytes = 4096;

/// One title to apply. Its strings are owned copies, freed by `destroy`.
const Pending = struct {
    label_buf: [plan.max_label_bytes]u8,
    label_len: usize,
    rex_bin_dir: []const u8,
    block: []const u8,
    workspace_root: []const u8,

    fn label(self: *const Pending) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const Renamer = struct {
    /// Guards `queue` and `pending`.
    mutex: std.Io.Mutex = .init,
    queue: queue_rules.State = .{},
    /// The waiting title, set exactly when `queue.waiting` is true.
    pending: ?*Pending = null,
    /// Set once at exit, after the queue stops. It kills a running `rex`.
    cancel: std.atomic.Value(bool) = .init(false),
    /// The main thread's handle on the task. Awaited before the next starts.
    future: ?std.Io.Future(void) = null,
    /// The allocator of the pending copies, set by the first `request` before
    /// any task starts. Safe to use from the task's thread.
    alloc: std.mem.Allocator = undefined,
    has_alloc: bool = false,
    /// The label fx asked for last. Only the task reads and writes it, and
    /// tasks run one after another.
    last_wanted_buf: [plan.max_label_bytes]u8 = undefined,
    last_wanted_len: ?usize = null,
    /// The last outcome, for tests.
    last_outcome: ?Outcome = null,
    /// A title arrived before the first frame. Main thread only.
    deferred: bool = false,

    /// Asks for the session to be named after `req.title`. Copies what it
    /// keeps. `alloc` must be safe to use from a second thread.
    pub fn request(self: *Renamer, alloc: std.mem.Allocator, req: Request) void {
        if (comptime builtin.single_threaded) return;
        if (!req.setting_on) return trace("skipped", "setting_off");
        const target = gate.envTarget(req.env) orelse return;
        var label_buf: [plan.max_label_bytes]u8 = undefined;
        const label = plan.labelFromTitle(req.title, &label_buf) orelse return trace("skipped", "empty_title");
        if (!self.has_alloc) {
            self.alloc = alloc;
            self.has_alloc = true;
        }
        const pending = createPending(self.alloc, label, target, req.workspace_root) catch |err| {
            debug_trace.logf(trace_scope, "rename request dropped error={s}", .{@errorName(err)});
            return;
        };
        if (self.enqueue(pending)) self.startTask();
    }

    /// Notes that a title arrived before the first frame, so the app asks
    /// again once the frame is on screen. Startup starts no `rex` (R2.2).
    pub fn deferUntilFirstFrame(self: *Renamer) void {
        self.deferred = true;
    }

    /// True once after `deferUntilFirstFrame`.
    pub fn takeDeferred(self: *Renamer) bool {
        const deferred = self.deferred;
        self.deferred = false;
        return deferred;
    }

    /// Cancels the work, kills a running `rex` child, and waits for the task
    /// to end. Fast: a `rex` call stops at its next watch step.
    pub fn stopForProcessExit(self: *Renamer) void {
        if (comptime builtin.single_threaded) return;
        {
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.queue = queue_rules.stop(self.queue);
        }
        self.cancel.store(true, .release);
        self.awaitTask();
    }

    /// Frees everything. Calls stopForProcessExit first.
    pub fn deinit(self: *Renamer) void {
        self.stopForProcessExit();
        if (self.pending) |pending| destroyPending(self.alloc, pending);
        self.pending = null;
    }

    /// Waits until the queued titles are applied. For tests.
    pub fn finishForTest(self: *Renamer) void {
        self.awaitTask();
    }

    /// Makes `pending` the waiting title, or drops it after the stop. True
    /// when no task runs, so the caller starts one.
    fn enqueue(self: *Renamer, pending: *Pending) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const result = queue_rules.request(self.queue);
        self.queue = result.state;
        if (!result.keep_title) {
            debug_trace.logf(trace_scope, "rename request dropped reason=stopped", .{});
            destroyPending(self.alloc, pending);
            return false;
        }
        if (self.pending) |old| destroyPending(self.alloc, old);
        self.pending = pending;
        return result.start_task;
    }

    fn startTask(self: *Renamer) void {
        // The queue marked the last task as ended, so it is ending or has ended.
        self.awaitTask();
        self.future = io_mod.getIo().concurrent(run, .{self}) catch |err| {
            debug_trace.logf(trace_scope, "rename task did not start error={s}", .{@errorName(err)});
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.queue = queue_rules.startFailed(self.queue);
            if (self.pending) |pending| destroyPending(self.alloc, pending);
            self.pending = null;
            return;
        };
    }

    fn awaitTask(self: *Renamer) void {
        if (self.future) |*future| {
            future.await(io_mod.getIo());
            self.future = null;
        }
    }

    fn run(self: *Renamer) void {
        while (self.take()) |pending| {
            defer destroyPending(self.alloc, pending);
            const outcome = self.apply(pending);
            self.last_outcome = outcome;
            trace(outcomeWord(outcome), @tagName(outcome));
        }
    }

    /// The waiting title, or null once the queue marks the task as ended.
    fn take(self: *Renamer) ?*Pending {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const result = queue_rules.take(self.queue);
        self.queue = result.state;
        const pending = self.pending;
        self.pending = null;
        if (result.apply_title) return pending;
        if (pending) |dropped| {
            debug_trace.logf(trace_scope, "rename request dropped reason=stopped", .{});
            destroyPending(self.alloc, dropped);
        }
        return null;
    }

    fn apply(self: *Renamer, pending: *const Pending) Outcome {
        const rex_path = gate.rexPath(self.alloc, pending.rex_bin_dir, pending.workspace_root) orelse return .rex_unavailable;
        defer self.alloc.free(rex_path);
        const cli: rex_cli.Cli = .{ .rex_path = rex_path, .cancel = &self.cancel };
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();

        const status_buf = a.alloc(u8, answers.max_status_bytes) catch return .rex_unavailable;
        const status = cli.capture(&.{ "skill", "status", "--json" }, status_buf) orelse return .rex_unavailable;
        if (!answers.sessionNamingOn(a, status)) return .option_off;

        const view_buf = a.alloc(u8, answers.max_inspect_bytes) catch return .rex_unavailable;
        const view = cli.capture(&.{ "session", "inspect", "--json", "--", pending.block }, view_buf) orelse return .rex_unavailable;
        var current_buf: [plan.max_label_bytes]u8 = undefined;
        const current = answers.sessionLabel(a, view, &current_buf) orelse return .label_unreadable;

        const wanted = pending.label();
        const decision = plan.decide(current, wanted, self.lastWanted());
        self.rememberWanted(wanted);
        switch (decision) {
            .already_named => return .already_named,
            .named_by_someone_else => return .named_by_someone_else,
            .rename => {},
        }
        var rename_buf: [max_rename_output_bytes]u8 = undefined;
        _ = cli.capture(&.{ "session", "rename", "--", pending.block, wanted }, &rename_buf) orelse return .rename_failed;
        return .renamed;
    }

    fn lastWanted(self: *const Renamer) ?[]const u8 {
        const len = self.last_wanted_len orelse return null;
        return self.last_wanted_buf[0..len];
    }

    fn rememberWanted(self: *Renamer, wanted: []const u8) void {
        @memcpy(self.last_wanted_buf[0..wanted.len], wanted);
        self.last_wanted_len = wanted.len;
    }
};

fn createPending(alloc: std.mem.Allocator, label: []const u8, target: gate.Target, workspace_root: []const u8) !*Pending {
    const pending = try alloc.create(Pending);
    errdefer alloc.destroy(pending);
    const rex_bin_dir = try alloc.dupe(u8, target.rex_bin_dir);
    errdefer alloc.free(rex_bin_dir);
    const block = try alloc.dupe(u8, target.block);
    errdefer alloc.free(block);
    const root = try alloc.dupe(u8, workspace_root);
    pending.* = .{
        .label_buf = undefined,
        .label_len = label.len,
        .rex_bin_dir = rex_bin_dir,
        .block = block,
        .workspace_root = root,
    };
    @memcpy(pending.label_buf[0..label.len], label);
    return pending;
}

fn destroyPending(alloc: std.mem.Allocator, pending: *Pending) void {
    alloc.free(pending.rex_bin_dir);
    alloc.free(pending.block);
    alloc.free(pending.workspace_root);
    alloc.destroy(pending);
}

fn outcomeWord(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .renamed => "renamed",
        .rex_unavailable, .label_unreadable, .rename_failed => "failed",
        .already_named, .named_by_someone_else, .option_off => "skipped",
    };
}

fn trace(word: []const u8, reason: []const u8) void {
    debug_trace.logf(trace_scope, "outcome={s} reason={s}", .{ word, reason });
}

const testing = std.testing;

/// A fake `rex` that keeps the session label in `label` and the rename
/// option's answer in `status.json`, both next to it.
const fake_rex =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\case "$1 $2" in
    \\"skill status") cat "$d/status.json" ;;
    \\"session inspect") [ "$4" = "--" ] && [ "$5" = "block:fx-test" ] || exit 4; printf '{"label":"%s","windows":[{"label":"w"}]}' "$(cat "$d/label")" ;;
    \\"session rename") [ "$3" = "--" ] && [ "$4" = "block:fx-test" ] || exit 4; printf '%s' "$5" > "$d/label" ;;
    \\*) exit 3 ;;
    \\esac
    \\
;
const naming_on = "{\"harnesses\":[{\"id\":\"pi\",\"session_naming\":true}]}";
const naming_off = "{\"harnesses\":[{\"id\":\"pi\",\"session_naming\":false}]}";

const Lab = struct {
    rex_dir: testing.TmpDir,
    work_dir: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    rex_bin_dir: []const u8,
    workspace_root: []const u8,
    renamer: Renamer = .{},

    fn create() !*Lab {
        const io = io_mod.getIo();
        const lab = try testing.allocator.create(Lab);
        errdefer testing.allocator.destroy(lab);
        lab.* = .{
            .rex_dir = testing.tmpDir(.{}),
            .work_dir = testing.tmpDir(.{}),
            .arena = .init(testing.allocator),
            .rex_bin_dir = undefined,
            .workspace_root = undefined,
        };
        const a = lab.arena.allocator();
        try lab.rex_dir.dir.writeFile(io, .{ .sub_path = "rex", .data = fake_rex });
        try lab.rex_dir.dir.setFilePermissions(io, "rex", std.Io.File.Permissions.fromMode(0o755), .{});
        lab.rex_bin_dir = try io_mod.dirRealpathAlloc(a, lab.rex_dir.dir, ".");
        lab.workspace_root = try io_mod.dirRealpathAlloc(a, lab.work_dir.dir, ".");
        try lab.write("status.json", naming_on);
        try lab.write("label", "morning-atoll");
        return lab;
    }

    fn destroy(lab: *Lab) void {
        lab.renamer.deinit();
        lab.arena.deinit();
        lab.rex_dir.cleanup();
        lab.work_dir.cleanup();
        testing.allocator.destroy(lab);
    }

    fn write(lab: *Lab, name: []const u8, data: []const u8) !void {
        try lab.rex_dir.dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = data });
    }

    fn label(lab: *Lab) ![]const u8 {
        return lab.rex_dir.dir.readFileAlloc(io_mod.getIo(), "label", lab.arena.allocator(), .limited(4096));
    }

    fn ask(lab: *Lab, title: []const u8, setting_on: bool) void {
        lab.renamer.request(testing.allocator, .{
            .env = .{ .rex_bin_dir = lab.rex_bin_dir, .rex_block = "block:fx-test", .rex_server = "unix:///tmp/fx-test-rex.sock" },
            .workspace_root = lab.workspace_root,
            .setting_on = setting_on,
            .title = title,
        });
        lab.renamer.finishForTest();
    }
};

test "fx renames Rex's made-up label, then follows its own title changes" {
    const lab = try Lab.create();
    defer lab.destroy();

    lab.ask("Fix login redirect", true);
    try testing.expectEqual(Outcome.renamed, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("Fix login redirect", try lab.label());

    lab.ask("Fix login redirect", true);
    try testing.expectEqual(Outcome.already_named, lab.renamer.last_outcome.?);

    lab.ask("Fix the logout page", true);
    try testing.expectEqual(Outcome.renamed, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("Fix the logout page", try lab.label());
}

test "fx leaves a session that a person named" {
    const lab = try Lab.create();
    defer lab.destroy();

    try lab.write("label", "my project");
    lab.ask("Fix login redirect", true);
    try testing.expectEqual(Outcome.named_by_someone_else, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("my project", try lab.label());

    // fx named it, then the person renamed it: fx leaves the new name.
    try lab.write("label", "morning-atoll");
    lab.ask("First title", true);
    try testing.expectEqualStrings("First title", try lab.label());
    try lab.write("label", "release work");
    lab.ask("Second title", true);
    try testing.expectEqual(Outcome.named_by_someone_else, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("release work", try lab.label());
}

test "fx does not rename when Rex's option or fx's setting is off" {
    const lab = try Lab.create();
    defer lab.destroy();

    try lab.write("status.json", naming_off);
    lab.ask("Fix login redirect", true);
    try testing.expectEqual(Outcome.option_off, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("morning-atoll", try lab.label());

    try lab.write("status.json", naming_on);
    lab.renamer.last_outcome = null;
    lab.ask("Fix login redirect", false);
    try testing.expect(lab.renamer.last_outcome == null);
    try testing.expectEqualStrings("morning-atoll", try lab.label());
}

test "an old rex that has no skill status leaves the session alone" {
    const lab = try Lab.create();
    defer lab.destroy();

    try lab.rex_dir.dir.deleteFile(io_mod.getIo(), "status.json");
    lab.ask("Fix login redirect", true);
    try testing.expectEqual(Outcome.rex_unavailable, lab.renamer.last_outcome.?);
    try testing.expectEqualStrings("morning-atoll", try lab.label());
}

test "outside a Rex terminal fx runs no rex" {
    const lab = try Lab.create();
    defer lab.destroy();

    lab.renamer.request(testing.allocator, .{
        .env = .{ .rex_bin_dir = lab.rex_bin_dir, .rex_block = null, .rex_server = null },
        .workspace_root = lab.workspace_root,
        .setting_on = true,
        .title = "Fix login redirect",
    });
    lab.renamer.finishForTest();
    try testing.expect(lab.renamer.last_outcome == null);
    try testing.expectEqualStrings("morning-atoll", try lab.label());
}

test "after the exit stop no rename starts" {
    const lab = try Lab.create();
    defer lab.destroy();

    lab.renamer.stopForProcessExit();
    lab.ask("Fix login redirect", true);
    try testing.expect(lab.renamer.last_outcome == null);
    try testing.expectEqualStrings("morning-atoll", try lab.label());
}
