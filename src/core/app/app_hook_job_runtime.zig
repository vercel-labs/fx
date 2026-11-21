//! The `/hook` verbs off the UI thread. A `/hook` command starts one job: an `std.Io` task that runs
//! `hook_verbs.run` on its own copies of the arguments, the home folder, and the workspace, and keeps
//! what it prints. The tick takes the finished job and shows its lines as the verbs always did. One job
//! runs at a time. Only `/hook test` can be stopped: it runs hooks, and Esc sets the flag its hooks poll,
//! so they stop within one poll (R2.1, R2.4). The App owns the job: it starts it, takes its output, and
//! cancels and awaits it on shutdown (R3.9, PR #57 lesson 2).

const std = @import("std");
const builtin = @import("builtin");
const hook_verbs = @import("../cli/hook_verbs.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const hooks_host = @import("../hooks_host/hooks_host.zig");

/// The most bytes the footer's working line holds.
const status_max = 96;

/// The one verb Esc can stop: it runs hooks, which the cancel flag reaches.
const cancelable_verb = "test";

/// What a finished job printed, and whether Esc stopped it. The text belongs to the job until `finish`.
pub const Output = struct {
    out: []const u8,
    err: []const u8,
    cancelled: bool,
};

const Job = struct {
    cancelable: bool,
    hooks_enabled: bool,
    /// Whether the job starts inside fx's own agent, which may not trust or disable a hook. Read on the UI thread.
    agent_is_fx: bool,
    home: ?[]u8,
    workspace_root: []u8,
    words: []const [:0]const u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    /// Set by Esc. The hooks of `test` poll it, so it is an atomic.
    cancel: std.atomic.Value(bool) = .init(false),
    /// Set by the job's task when it returns. The UI thread reads the output only after this is set.
    done: std.atomic.Value(bool) = .init(false),
    /// The task that runs the verbs. `finish` and `deinit` await it.
    future: ?std.Io.Future(void) = null,

    /// Copies everything the job reads, so the caller's buffers may go away. The job owns the copies.
    fn create(a: std.mem.Allocator, home: ?[]const u8, workspace_root: []const u8, hooks_enabled: bool, agent_is_fx: bool, words: []const [:0]const u8) !*Job {
        const words_copy = try copyWords(a, words);
        errdefer freeWords(a, words_copy);
        const home_copy: ?[]u8 = if (home) |text| try a.dupe(u8, text) else null;
        errdefer if (home_copy) |text| a.free(text);
        const root_copy = try a.dupe(u8, workspace_root);
        errdefer a.free(root_copy);
        const job = try a.create(Job);
        job.* = .{
            .cancelable = words.len > 0 and std.mem.eql(u8, words[0], cancelable_verb),
            .hooks_enabled = hooks_enabled,
            .agent_is_fx = agent_is_fx,
            .home = home_copy,
            .workspace_root = root_copy,
            .words = words_copy,
            .out = .init(a),
            .err = .init(a),
        };
        return job;
    }

    /// The job's task: the verbs print into the job, then `done` tells the UI thread it may read them.
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        _ = hook_verbs.run(.{
            .gpa = std.heap.c_allocator,
            .out = &self.out.writer,
            .err = &self.err.writer,
            .home = self.home,
            .workspace_root = self.workspace_root,
            .hooks_enabled = self.hooks_enabled,
            .agent_is_fx = self.agent_is_fx,
            .cancel = &self.cancel,
        }, self.words);
    }

    fn destroy(self: *Job) void {
        const a = std.heap.c_allocator;
        self.out.deinit();
        self.err.deinit();
        if (self.home) |text| a.free(text);
        a.free(self.workspace_root);
        freeWords(a, self.words);
        a.destroy(self);
    }
};

/// Copies `words`. A failure frees what was copied.
fn copyWords(a: std.mem.Allocator, words: []const [:0]const u8) ![]const [:0]const u8 {
    const copy = try a.alloc([:0]const u8, words.len);
    var made: usize = 0;
    errdefer freeWords(a, copy[0..made]);
    for (words, copy) |word, *slot| {
        const text = try a.allocSentinel(u8, word.len, 0);
        @memcpy(text, word);
        slot.* = text;
        made += 1;
    }
    return copy;
}

fn freeWords(a: std.mem.Allocator, words: []const [:0]const u8) void {
    for (words) |word| a.free(word);
    a.free(words);
}

/// The verb the first word names, when `/hook` knows it. `list` when there are no words; "" for anything else.
fn verbNameOf(words: []const [:0]const u8) []const u8 {
    if (words.len == 0) return "list";
    for (hook_verbs.verb_words) |name| {
        if (std.mem.eql(u8, words[0], name)) return name;
    }
    return "";
}

pub const State = struct {
    /// The running or finished job, or null. Only the UI thread sets it.
    job: ?*Job = null,
    /// The footer's working line, shown while a job runs. Only the UI thread writes it, so it needs no lock.
    status_buf: [status_max]u8 = undefined,
    status_len: usize = 0,

    /// Starts `/hook` with `words` (the arguments after `hook`) as an `std.Io` task. `words` is copied.
    /// Returns error.HookJobBusy while another job runs; the caller shows a notice and starts nothing.
    pub fn start(self: *State, home: ?[]const u8, workspace_root: []const u8, hooks_enabled: bool, words: []const [:0]const u8) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        if (self.job != null) return error.HookJobBusy;
        // Read here, on the UI thread, so the job carries the answer the process gives: AI_AGENT=fx means fx's own agent.
        const agent_is_fx = hooks_host.trust.refusedForAgent(io_mod.getenv("AI_AGENT"));
        const job = try Job.create(std.heap.c_allocator, home, workspace_root, hooks_enabled, agent_is_fx, words);
        errdefer job.destroy();
        job.future = try io_mod.getIo().concurrent(Job.run, .{job});
        self.job = job;
        self.setStatus(words, job.cancelable);
    }

    fn setStatus(self: *State, words: []const [:0]const u8, can_cancel: bool) void {
        const name = verbNameOf(words);
        const text = if (name.len == 0)
            std.mem.print(&self.status_buf, "Running /hook…", .{}) catch self.status_buf[0..0]
        else if (can_cancel)
            std.mem.print(&self.status_buf, "Running /hook {s}… Esc twice stops it", .{name}) catch self.status_buf[0..0]
        else
            std.mem.print(&self.status_buf, "Running /hook {s}…", .{name}) catch self.status_buf[0..0];
        self.status_len = text.len;
    }

    /// Whether a job runs, whatever its verb.
    pub fn running(self: *const State) bool {
        return self.job != null;
    }

    /// Whether a running job is one Esc can stop. Only such a job counts as an active operation, so Esc and Ctrl-C keep
    /// their normal meaning during `/hook list` and `/hook trust`.
    pub fn cancelable(self: *const State) bool {
        const job = self.job orelse return false;
        return job.cancelable;
    }

    /// Esc or Ctrl-C: sets the cancel flag of a running `test`. Returns false when no cancelable job runs.
    pub fn cancel(self: *State) bool {
        const job = self.job orelse return false;
        if (!job.cancelable) return false;
        job.cancel.store(true, .seq_cst);
        return true;
    }

    /// The working line, or "" when no job runs.
    pub fn statusText(self: *const State) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    /// The finished job's output, or null while it runs. The output is valid until `finish`. `cancelled` is whether Esc
    /// set the flag before the tick took the job.
    pub fn finished(self: *const State) ?Output {
        const job = self.job orelse return null;
        if (!job.done.load(.acquire)) return null;
        return .{
            .out = job.out.written(),
            .err = job.err.written(),
            .cancelled = job.cancel.load(.seq_cst),
        };
    }

    /// Awaits the job, frees it, and clears the working line. Call it after the output has been shown.
    pub fn finish(self: *State) void {
        const job = self.job orelse return;
        if (job.future) |*future| future.await(io_mod.getIo());
        self.job = null;
        self.status_len = 0;
        job.destroy();
    }

    /// Shutdown: cancels a running job and awaits it. Cancel stops the hooks within one poll, so exit waits on them only briefly.
    /// `trust` cannot be cancelled and may wait up to its lock deadline.
    pub fn deinit(self: *State) void {
        const job = self.job orelse return;
        job.cancel.store(true, .seq_cst);
        self.finish();
    }
};

// --- tests ---

const testing = std.testing;

/// Polls `finished` until the job ends. A job that never ends fails the test.
fn waitFinished(state: *State) !Output {
    const io = io_mod.getIo();
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        if (state.finished()) |output| return output;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return error.JobDidNotFinish;
}

/// Writes the profile hooks file under `home` (the file `hook list` and `hook test` read).
fn writeProfileHook(alloc: std.mem.Allocator, dir: std.Io.Dir, home: []const u8, text: []const u8) !void {
    try dir.createDirPath(io_mod.getIo(), ".fx");
    const file_path = try profile_paths.rootPath(alloc, home, &.{"hooks.json"});
    defer alloc.free(file_path);
    try io_mod.writeFileAtomic(alloc, file_path, text);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
}

test "a /hook job keeps its output for the tick, and the working line shows while it runs" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try writeProfileHook(alloc, tmp.dir, home, "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"id\":\"job-hook\",\"command\":\"exit 0\"}]}]}}");

    var state: State = .{};
    defer state.deinit();
    const list_words = [_][:0]const u8{"list"};
    try state.start(home, home, false, &list_words);
    try testing.expect(state.running());
    try testing.expect(!state.cancelable());
    try testing.expectEqualStrings("Running /hook list…", state.statusText());

    const output = try waitFinished(&state);
    try testing.expect(std.mem.find(u8, output.out, "job-hook") != null);
    try testing.expect(!output.cancelled);
    state.finish();
    try testing.expect(!state.running());
    try testing.expectEqualStrings("", state.statusText());
}

test "a second /hook job is refused while one runs, and Esc twice stops only a test" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    // The hook sleeps. Only the cancel flag can end this job early.
    try writeProfileHook(alloc, tmp.dir, home, "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"id\":\"slow-hook\",\"command\":\"exec sleep 30\"}]}]}}");

    var state: State = .{};
    defer state.deinit();
    const test_words = [_][:0]const u8{ "test", "PreToolUse", "--match", "shell" };
    try state.start(home, home, false, &test_words);
    try testing.expect(state.cancelable());
    try testing.expectEqualStrings("Running /hook test… Esc twice stops it", state.statusText());

    const list_words = [_][:0]const u8{"list"};
    try testing.expectError(error.HookJobBusy, state.start(home, home, false, &list_words));
    try testing.expect(state.cancel());
    const output = try waitFinished(&state);
    try testing.expect(output.cancelled);
    state.finish();
}

test "a /hook trust job started inside fx's own agent is refused, and one started outside it runs" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const trust_words = [_][:0]const u8{ "trust", "--all" };

    // The environment of fx's own agent: AI_AGENT=fx. The job reads it when it is created.
    var agent_env = std.process.Environ.Map.init(alloc);
    defer agent_env.deinit();
    try agent_env.put("AI_AGENT", "fx");
    io_mod.setEnvironMap(&agent_env);
    defer io_mod.resetEnvironForTest();
    {
        var state: State = .{};
        defer state.deinit();
        try state.start(home, home, false, &trust_words);
        const output = try waitFinished(&state);
        try testing.expect(std.mem.find(u8, output.out, "needs a person") != null or std.mem.find(u8, output.err, "needs a person") != null);
        state.finish();
    }

    // Outside fx's own agent the same words run, and the refusal is absent.
    var person_env = std.process.Environ.Map.init(alloc);
    defer person_env.deinit();
    io_mod.setEnvironMap(&person_env);
    {
        var state: State = .{};
        defer state.deinit();
        try state.start(home, home, false, &trust_words);
        const output = try waitFinished(&state);
        try testing.expect(std.mem.find(u8, output.out, "needs a person") == null);
        try testing.expect(std.mem.find(u8, output.err, "needs a person") == null);
        state.finish();
    }
}

test "cancel does nothing to a /hook job that Esc cannot stop" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try writeProfileHook(alloc, tmp.dir, home, "{}");

    var state: State = .{};
    defer state.deinit();
    const trust_words = [_][:0]const u8{ "trust", "nope" };
    try state.start(home, home, false, &trust_words);
    try testing.expect(!state.cancelable());
    try testing.expect(!state.cancel());
    const output = try waitFinished(&state);
    try testing.expect(!output.cancelled);
    state.finish();
}
