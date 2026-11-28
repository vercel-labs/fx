//! Runs `/mods` commands off the UI thread and queues output notices for the
//! transcript (`RULES.md` R2.1, R3.9). Native builds only (`build_options.libfx`).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const command_lex = @import("../shell_command/command_lex.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mod_verbs = if (build_options.libfx) struct {} else @import("../mods/verbs.zig");

const Allocator = std.mem.Allocator;

pub const ModNotice = struct {
    text: []u8,
    warning: bool,
};

pub const State = struct {
    sink_mutex: std.Io.Mutex = .init,
    notices: std.ArrayList(ModNotice) = .empty,
    active_jobs: std.atomic.Value(usize) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),
    skills_refresh_needed: std.atomic.Value(bool) = .init(false),

    pub fn pushNotice(self: *State, text: []u8, warning: bool) void {
        self.sink_mutex.lockUncancelable(io_mod.getIo());
        defer self.sink_mutex.unlock(io_mod.getIo());
        self.notices.append(std.heap.c_allocator, .{ .text = text, .warning = warning }) catch {
            std.heap.c_allocator.free(text);
        };
    }

    pub fn takeNotices(self: *State) []ModNotice {
        self.sink_mutex.lockUncancelable(io_mod.getIo());
        defer self.sink_mutex.unlock(io_mod.getIo());
        return self.notices.toOwnedSlice(std.heap.c_allocator) catch &.{};
    }

    pub fn takeSkillsRefresh(self: *State) bool {
        return self.skills_refresh_needed.swap(false, .acq_rel);
    }

    pub fn runVerbs(self: *State, home: []const u8, rest: []const u8) !void {
        if (comptime build_options.libfx) return;
        const a = std.heap.c_allocator;
        var argv = command_lex.tokenize_argv(a, rest) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.pushNotice(try a.dupe(u8, "/mods: that command line has an unmatched quote or a character fx does not take here."), true);
                return;
            },
        };
        defer argv.deinit(a);
        const args = try a.alloc([]const u8, argv.tokens.len);
        defer a.free(args);
        for (argv.tokens, args) |t, *arg| arg.* = t.value;
        return self.startVerbs(home, args);
    }

    fn startVerbs(self: *State, home: []const u8, args: []const []const u8) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        const a = std.heap.c_allocator;
        const job = try a.create(VerbJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self };
        errdefer job.free();

        const owned = try a.alloc([]const u8, args.len);
        @memset(owned, "");
        job.args = owned;
        for (args, owned) |arg, *copy| copy.* = try a.dupe(u8, arg);
        job.home = try a.dupe(u8, home);

        _ = self.active_jobs.fetchAdd(1, .acq_rel);
        errdefer _ = self.active_jobs.fetchSub(1, .acq_rel);
        const thread = try std.Thread.spawn(.{}, VerbJob.run, .{job});
        thread.detach();
    }

    pub fn deinit(self: *State) void {
        self.stop(exit_wait_loops);
    }

    const exit_wait_loops = 200;

    /// Asks every job to stop, waits up to `max_wait_loops` times 10 ms, and
    /// frees the queued notices. `closing` stays set, so a job that still
    /// runs stops its git child instead of finishing the fetch.
    fn stop(self: *State, max_wait_loops: usize) void {
        self.closing.store(true, .release);
        var wait_loops: usize = 0;
        while (self.active_jobs.load(.acquire) > 0 and wait_loops < max_wait_loops) : (wait_loops += 1) {
            io_mod.getIo().sleep(.fromMilliseconds(10), .awake) catch {};
        }
        const remaining = self.takeNotices();
        if (remaining.len > 0) debug_trace.logf("mods", "event=notices_dropped count={d} reason=exit", .{remaining.len});
        for (remaining) |n| std.heap.c_allocator.free(n.text);
        std.heap.c_allocator.free(remaining);
        const running = self.active_jobs.load(.acquire);
        if (running > 0) debug_trace.logf("mods", "event=jobs_still_running count={d} reason=exit_wait_ended", .{running});
    }

    const VerbJob = struct {
        state: *State,
        args: []const []const u8 = &.{},
        home: []const u8 = "",

        fn free(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            for (job.args) |arg| a.free(arg);
            a.free(job.args);
            a.free(job.home);
        }

        fn run(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            const self = job.state;
            const args = job.args;
            defer {
                job.free();
                a.destroy(job);
                _ = self.active_jobs.fetchSub(1, .acq_rel);
            }
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            var err: std.Io.Writer.Allocating = .init(a);
            defer err.deinit();
            var changed = false;
            _ = mod_verbs.run(.{
                .gpa = a,
                .out = &out.writer,
                .err = &err.writer,
                .surface = .shell,
                .home = job.home,
                .cancel = &self.closing,
                .changed = &changed,
            }, args);
            if (changed and !self.closing.load(.acquire)) {
                self.skills_refresh_needed.store(true, .release);
            }
            for ([_]*std.Io.Writer.Allocating{ &out, &err }, [_]bool{ false, true }) |w, warning| {
                const text = std.mem.trimEnd(u8, w.written(), "\n");
                if (text.len == 0) continue;
                self.pushNotice(a.dupe(u8, text) catch continue, warning);
            }
        }
    };
};

test "app_mods_runtime queues and drains notices" {
    var state: State = .{};
    defer state.deinit();

    const copy = try std.heap.c_allocator.dupe(u8, "Installed glm (1.0.0).");
    state.pushNotice(copy, false);
    const notices = state.takeNotices();
    defer {
        for (notices) |n| std.heap.c_allocator.free(n.text);
        std.heap.c_allocator.free(notices);
    }
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expect(!notices[0].warning);
    try std.testing.expectEqualStrings("Installed glm (1.0.0).", notices[0].text);
}

test "app_mods_runtime keeps the cancel set for a job that outlives the exit wait" {
    var state: State = .{};
    state.active_jobs.store(1, .release);
    state.pushNotice(try std.heap.c_allocator.dupe(u8, "Installed glm (1.0.0)."), false);

    state.stop(0);

    try std.testing.expect(state.closing.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.active_jobs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.notices.items.len);
}

test "app_mods_runtime records skills refresh only on a successful mod change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "src");
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src/mod.json",
        .data = "{\"name\":\"glm\",\"version\":\"1.0.0\"}",
    });
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home);
    const src = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "src");
    defer std.testing.allocator.free(src);

    var state: State = .{};
    defer state.deinit();

    const add_cmd = try std.testing.allocator.print("add {s} --yes", .{src});
    defer std.testing.allocator.free(add_cmd);
    try state.runVerbs(home, add_cmd);
    while (state.active_jobs.load(.acquire) > 0) {
        io_mod.getIo().sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(state.takeSkillsRefresh());
    try std.testing.expect(!state.takeSkillsRefresh());

    // A non-mutating command (`list`) does not request a skill refresh.
    try state.runVerbs(home, "list");
    while (state.active_jobs.load(.acquire) > 0) {
        io_mod.getIo().sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!state.takeSkillsRefresh());
}
