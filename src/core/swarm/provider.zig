//! Bounded read of Puppetmaster swarm state through its own CLI.
//!
//! fx does not read Puppetmaster's state directory. The raw JSON documents that
//! `settings.json`, `artifact_index.json`, and the SQLite store hold are private
//! implementation detail, and hardcoding them would couple fx to a layout that
//! changes without notice. The supported surface is the CLI, so this module runs
//! it with a byte limit, an output limit, and a deadline: a missing binary, a
//! slow caller, or a runaway worker can never turn a read-only view into a hang.
//!
//! The process boundary is a function pointer so the App and tests can inject a
//! substitute without spawning anything.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Enough for a job with a long goal and a healthy feed, and small enough that a
/// pathological read is dropped instead of pasted into scrollback.
pub const max_stdout_bytes: usize = 512 * 1024;
pub const max_stderr_bytes: usize = 8 * 1024;
pub const default_timeout_ms: u64 = 15_000;

/// Injected so tests and the App can replace the process boundary.
pub const ReadFn = *const fn (
    Allocator,
    []const []const u8,
    u64,
) anyerror![]u8;

/// A wrapper that cannot put Puppetmaster on PATH names it here.
pub const command_env_var = "PUPPETMASTER_COMMAND";

pub fn commandName() []const u8 {
    const configured = io_mod.getenv(command_env_var) orelse return "puppetmaster";
    const trimmed = std.mem.trim(u8, configured, " \t\r\n");
    return if (trimmed.len > 0) trimmed else "puppetmaster";
}

/// Runs `argv` and returns owned stdout. The caller frees the result.
pub fn run(
    alloc: Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
) anyerror![]u8 {
    // `std.process.run` raises the deadline and the output limit rather than
    // returning them, so both are normalized here into this module's vocabulary.
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .stdout_limit = .limited(max_stdout_bytes),
        .stderr_limit = .limited(max_stderr_bytes),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@intCast(timeout_ms)) } },
    }) catch |err| return switch (err) {
        error.Timeout => error.SwarmCommandTimedOut,
        error.StreamTooLong => error.SwarmOutputTooLarge,
        else => err,
    };
    defer alloc.free(result.stderr);

    if (result.term != .exited) {
        alloc.free(result.stdout);
        return error.SwarmCommandFailed;
    }
    if (result.term.exited != 0) {
        alloc.free(result.stdout);
        return error.SwarmCommandFailed;
    }
    return result.stdout;
}

/// The read a `/swarm` view needs: one status document and, when available, its
/// feed. A failed feed is not fatal, because status alone is still a useful view.
pub const Read = struct {
    status: []u8,
    feed: ?[]u8,

    pub fn deinit(self: *Read, alloc: Allocator) void {
        alloc.free(self.status);
        if (self.feed) |feed| alloc.free(feed);
        self.* = undefined;
    }
};

pub fn readJob(
    alloc: Allocator,
    read_fn: ReadFn,
    job_id: ?[]const u8,
    timeout_ms: u64,
) anyerror!?Read {
    // `status` and `feed` both require an id, so resolve the workspace's latest
    // job first when the caller did not name one. `--json` is required here:
    // bare `last` prints only the id, which is not the object the parser reads.
    const resolved = if (job_id) |id|
        try alloc.dupe(u8, id)
    else blk: {
        const latest = read_fn(alloc, &.{ commandName(), "last", "--json" }, timeout_ms) catch |err| return normalizeMissing(err);
        defer alloc.free(latest);
        // `last --json` answered without a job id, so there is nothing to show.
        // A workspace with no Puppetmaster store exits non-zero instead, which
        // reaches the caller as a failed read rather than as absence.
        break :blk (try parseLatestJobId(alloc, latest)) orelse return null;
    };
    defer alloc.free(resolved);

    const status = readCommand(alloc, read_fn, &.{ "status", resolved }, timeout_ms) catch |err| return normalizeMissing(err);
    errdefer alloc.free(status);
    return .{
        .status = status,
        .feed = try readFeed(alloc, read_fn, resolved, timeout_ms),
    };
}

fn readCommand(
    alloc: Allocator,
    read_fn: ReadFn,
    args: []const []const u8,
    timeout_ms: u64,
) anyerror![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, commandName());
    try argv.appendSlice(alloc, args);
    return read_fn(alloc, argv.items, timeout_ms);
}

/// A missing binary is not "no job here"; it is a different answer, so it keeps
/// its own error and the caller reports that Puppetmaster is not installed.
fn normalizeMissing(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound => error.SwarmCommandMissing,
        else => err,
    };
}

/// A feed that cannot be read leaves the status view intact; the feed is
/// supporting detail, not the answer.
fn readFeed(
    alloc: Allocator,
    read_fn: ReadFn,
    job_id: []const u8,
    timeout_ms: u64,
) anyerror!?[]u8 {
    return readCommand(alloc, read_fn, &.{ "feed", job_id, "--json" }, timeout_ms) catch null;
}

/// `puppetmaster last --json` emits an object; its `job_id` names the workspace's
/// newest job. The caller owns the returned bytes.
pub fn parseLatestJobId(alloc: Allocator, json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const raw = parsed.value.object.get("job_id") orelse return null;
    const text = switch (raw) {
        .string => |s| s,
        else => return null,
    };
    if (text.len == 0) return null;
    return try alloc.dupe(u8, text);
}

test "an unset command name defaults to puppetmaster" {
    // The environment is process-global and read-only here, so assert the
    // default only when the host has not configured an override.
    if (io_mod.getenv(command_env_var) == null) {
        try std.testing.expectEqualStrings("puppetmaster", commandName());
    }
}

test "parses the latest job id, and tolerates the shapes it may emit" {
    const alloc = std.testing.allocator;
    const id = (try parseLatestJobId(alloc, "{\"job_id\":\"job_404d008539ef\",\"status\":\"failed\"}")).?;
    defer alloc.free(id);
    try std.testing.expectEqualStrings("job_404d008539ef", id);

    try std.testing.expect(try parseLatestJobId(alloc, "{\"job_id\":\"\"}") == null);
    try std.testing.expect(try parseLatestJobId(alloc, "{}") == null);
    try std.testing.expect(try parseLatestJobId(alloc, "not json") == null);
    try std.testing.expect(try parseLatestJobId(alloc, "[]") == null);
    try std.testing.expect(try parseLatestJobId(alloc, "{\"job_id\":42}") == null);
}

test "a job read resolves the latest id and pairs status with feed" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        var calls: usize = 0;
        var saw_status_job: [64]u8 = undefined;
        var saw_status_job_len: usize = 0;

        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            calls += 1;
            try std.testing.expectEqualStrings("puppetmaster", argv[0]);
            if (std.mem.eql(u8, argv[1], "last")) {
                // `last` alone prints a bare id; only `last --json` prints the
                // object this parser reads, so the flag is part of the contract.
                try std.testing.expectEqual(@as(usize, 3), argv.len);
                try std.testing.expectEqualStrings("--json", argv[2]);
                return a.dupe(u8, "{\"job_id\":\"job_latest\"}");
            }
            if (std.mem.eql(u8, argv[1], "status")) {
                saw_status_job_len = argv[2].len;
                @memcpy(saw_status_job[0..argv[2].len], argv[2]);
                return a.dupe(u8, "{\"job\":{\"id\":\"job_latest\"}}");
            }
            if (std.mem.eql(u8, argv[1], "feed")) {
                return a.dupe(u8, "[]");
            }
            return error.UnexpectedCall;
        }
    };
    Capture.calls = 0;

    var read = (try readJob(alloc, Capture.read, null, default_timeout_ms)).?;
    defer read.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), Capture.calls);
    try std.testing.expectEqualStrings("job_latest", Capture.saw_status_job[0..Capture.saw_status_job_len]);
    try std.testing.expectEqualStrings("{\"job\":{\"id\":\"job_latest\"}}", read.status);
    try std.testing.expectEqualStrings("[]", read.feed.?);
}

test "an explicit job id skips the latest lookup" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        var calls: usize = 0;

        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            calls += 1;
            try std.testing.expect(!std.mem.eql(u8, argv[1], "last"));
            return a.dupe(u8, "{\"job\":{\"id\":\"job_named\"}}");
        }
    };
    Capture.calls = 0;

    var read = (try readJob(alloc, Capture.read, "job_named", default_timeout_ms)).?;
    defer read.deinit(alloc);

    // status plus feed, with no `last` probe.
    try std.testing.expectEqual(@as(usize, 2), Capture.calls);
}

test "the latest lookup asks for JSON, because bare last is not JSON" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        var saw_json_flag: bool = false;
        var status_job: [64]u8 = undefined;
        var status_job_len: usize = 0;

        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            if (std.mem.eql(u8, argv[1], "last")) {
                saw_json_flag = argv.len == 3 and std.mem.eql(u8, argv[2], "--json");
                // The real CLI answers `last` with a bare id and `last --json`
                // with the object below.
                return a.dupe(u8, if (saw_json_flag) "{\"job_id\":\"job_404d008539ef\"}" else "job_404d008539ef\n");
            }
            if (std.mem.eql(u8, argv[1], "status")) {
                status_job_len = argv[2].len;
                @memcpy(status_job[0..argv[2].len], argv[2]);
                return a.dupe(u8, "{\"job\":{\"id\":\"job_404d008539ef\"}}");
            }
            return a.dupe(u8, "[]");
        }
    };
    Capture.saw_json_flag = false;
    Capture.status_job_len = 0;

    var read = (try readJob(alloc, Capture.read, null, default_timeout_ms)).?;
    defer read.deinit(alloc);

    // A regression that drops the flag resolves no id, so this both fails the
    // flag assertion and reports absence instead of a job.
    try std.testing.expect(Capture.saw_json_flag);
    try std.testing.expectEqualStrings("job_404d008539ef", Capture.status_job[0..Capture.status_job_len]);
}

test "a bare job id from last is not a job, so the flag is load-bearing" {
    const alloc = std.testing.allocator;
    // `puppetmaster last` prints `job_x` and nothing else; that is not the JSON
    // object `parseLatestJobId` reads, which is why the read above passes --json.
    try std.testing.expect(try parseLatestJobId(alloc, "job_404d008539ef\n") == null);
    try std.testing.expect(try parseLatestJobId(alloc, "job_404d008539ef") == null);
}

test "a missing puppetmaster binary is reported as missing, not as an empty workspace" {
    const alloc = std.testing.allocator;
    const missing = struct {
        fn read(_: Allocator, _: []const []const u8, _: u64) anyerror![]u8 {
            return error.FileNotFound;
        }
    }.read;

    try std.testing.expectError(
        error.SwarmCommandMissing,
        readJob(alloc, missing, "job_x", default_timeout_ms),
    );
}

test "an empty workspace is absence, distinct from a missing binary" {
    const alloc = std.testing.allocator;
    const no_jobs = struct {
        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            try std.testing.expect(std.mem.eql(u8, argv[1], "last"));
            // Puppetmaster answers, but this workspace has no job yet.
            return a.dupe(u8, "{}");
        }
    }.read;

    try std.testing.expect(try readJob(alloc, no_jobs, null, default_timeout_ms) == null);
}

test "a failed feed still yields the status view" {
    const alloc = std.testing.allocator;
    const flaky = struct {
        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            if (std.mem.eql(u8, argv[1], "feed")) return error.SwarmCommandFailed;
            return a.dupe(u8, "{\"job\":{\"id\":\"job_x\"}}");
        }
    }.read;

    var read = (try readJob(alloc, flaky, "job_x", default_timeout_ms)).?;
    defer read.deinit(alloc);
    try std.testing.expect(read.feed == null);
    try std.testing.expectEqualStrings("{\"job\":{\"id\":\"job_x\"}}", read.status);
}

test "a failing status read propagates rather than rendering nothing" {
    const alloc = std.testing.allocator;
    const failing = struct {
        fn read(_: Allocator, _: []const []const u8, _: u64) anyerror![]u8 {
            return error.SwarmCommandFailed;
        }
    }.read;

    try std.testing.expectError(
        error.SwarmCommandFailed,
        readJob(alloc, failing, "job_x", default_timeout_ms),
    );
}

test "a timed-out status read propagates so the view can say so" {
    const alloc = std.testing.allocator;
    const slow = struct {
        fn read(_: Allocator, _: []const []const u8, _: u64) anyerror![]u8 {
            return error.SwarmCommandTimedOut;
        }
    }.read;

    try std.testing.expectError(
        error.SwarmCommandTimedOut,
        readJob(alloc, slow, "job_x", default_timeout_ms),
    );
}

test "a missing binary mid-sequence is still reported as missing" {
    const alloc = std.testing.allocator;
    const vanished = struct {
        fn read(a: Allocator, argv: []const []const u8, _: u64) anyerror![]u8 {
            // `last` resolves, then the binary disappears before `status`.
            if (std.mem.eql(u8, argv[1], "last")) return a.dupe(u8, "{\"job_id\":\"job_x\"}");
            return error.FileNotFound;
        }
    }.read;

    try std.testing.expectError(
        error.SwarmCommandMissing,
        readJob(alloc, vanished, null, default_timeout_ms),
    );
}
