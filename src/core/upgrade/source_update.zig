//! Source updates: the checkout a proto-fx binary was built from is its
//! update channel (D140). `inspect` fetches and reports how far the checkout
//! is from its upstream; `pullAndBuild` fast-forwards and rebuilds it; and
//! `installAtomic` swaps the built binary over the running one with a rename
//! in the same directory, so the running inode is never deleted or truncated.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

pub const binary_name = "proto-fx";

/// What the running binary knows about the checkout it was built from.
pub const Source = struct {
    checkout: []const u8,
    /// The compiler that built this binary; "zig" from PATH when unknown.
    zig_exe: []const u8 = "zig",
    /// The checkout's HEAD when this binary was built (12 hex digits).
    revision: []const u8 = "",
    /// `-Doptimize` for the rebuild, or empty for a Debug build.
    optimize: []const u8 = currentOptimize(),
};

pub fn currentOptimize() []const u8 {
    return switch (builtin.mode) {
        .Debug => "",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

pub const Command = struct {
    argv: []const []const u8,
    cwd: []const u8,
    /// Stream the child's output to this process's stderr instead of
    /// capturing it, for long steps such as the build.
    stream: bool = false,
};

/// Captured output, owned by the caller. Streamed commands capture nothing.
pub const Output = struct {
    ok: bool,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn deinit(self: *Output, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        self.* = undefined;
    }
};

/// Runs git and zig. Tests replace it with a scripted fake.
pub const Runner = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (?*anyopaque, Allocator, Command) anyerror!Output = runDefault,
};

fn runDefault(_: ?*anyopaque, alloc: Allocator, command: Command) anyerror!Output {
    var env = try io_mod.cloneEnvironMap(alloc);
    defer env.deinit();
    // The user's own git config and credentials apply, but nothing may
    // prompt, and a variable that names another repository must not leak in.
    try env.put("GIT_TERMINAL_PROMPT", "0");
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE" }) |key| _ = env.swapRemove(key);
    const zio = io_mod.getIo();
    if (command.stream) {
        var child = try std.process.spawn(zio, .{
            .argv = command.argv,
            .cwd = .{ .path = command.cwd },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .{ .file = std.Io.File.stderr() },
            .stderr = .inherit,
        });
        const term = try child.wait(zio);
        return .{ .ok = term.success() };
    }
    const result = try std.process.run(alloc, zio, .{
        .argv = command.argv,
        .cwd = .{ .path = command.cwd },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    return .{ .ok = result.term.success(), .stdout = result.stdout, .stderr = result.stderr };
}

/// Where the checkout stands, owned by the caller.
pub const Status = struct {
    head: []u8,
    /// The checked out branch, or "HEAD" when detached.
    branch: []u8,
    /// The branch's upstream such as `origin/main`, when it has one.
    upstream: ?[]u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// Tracked files have uncommitted changes.
    dirty: bool = false,
    /// Why `git fetch` failed; the counts then use the last fetched refs.
    fetch_error: ?[]u8 = null,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        alloc.free(self.head);
        alloc.free(self.branch);
        if (self.upstream) |value| alloc.free(value);
        if (self.fetch_error) |value| alloc.free(value);
        self.* = undefined;
    }

    /// The installed binary was built from another commit than HEAD.
    pub fn needsRebuild(self: Status, installed_revision: []const u8) bool {
        return !update_target.revisionsEqual(self.head, installed_revision);
    }

    pub fn updateAvailable(self: Status, installed_revision: []const u8) bool {
        return self.behind > 0 or self.needsRebuild(installed_revision);
    }
};

pub const Error = error{
    NotACheckout,
    DirtyCheckout,
    Diverged,
    DetachedHead,
    MergeFailed,
    BuildFailed,
    BuiltBinaryMissing,
    InstallFailed,
};

/// A one-line reason for an `Error`, for the snapshot.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotACheckout => "the recorded checkout is not a git repository",
        error.DirtyCheckout => "the checkout has uncommitted changes; commit or stash them, then update again",
        error.Diverged => "the checkout has local commits that are not on its upstream, so it cannot fast-forward; rebase or merge it, then update again",
        error.DetachedHead => "the checkout is not on a branch; check out a branch, then update again",
        error.MergeFailed => "git could not fast-forward the checkout",
        error.BuildFailed => "zig build failed; the installed binary is unchanged",
        error.BuiltBinaryMissing => "zig build finished but zig-out/bin/proto-fx is missing",
        error.InstallFailed => "the new binary could not be installed over the running one",
        else => @errorName(err),
    };
}

/// Reads the checkout's state; with `fetch`, first fetches its upstream.
pub fn inspect(alloc: Allocator, runner: Runner, source: Source, fetch: bool) !Status {
    const head = try gitLine(alloc, runner, source.checkout, &.{ "rev-parse", "HEAD" }) orelse return error.NotACheckout;
    var status: Status = .{ .head = head, .branch = &.{} };
    errdefer status.deinit(alloc);
    status.branch = try gitLine(alloc, runner, source.checkout, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse try alloc.dupe(u8, "HEAD");
    if (fetch) {
        var out = try git(alloc, runner, source.checkout, &.{ "fetch", "--quiet" });
        defer out.deinit(alloc);
        if (!out.ok) status.fetch_error = try alloc.dupe(u8, firstLine(out.stderr, "git fetch failed"));
    }
    status.upstream = try gitLine(alloc, runner, source.checkout, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" });
    if (status.upstream != null) {
        if (try gitLine(alloc, runner, source.checkout, &.{ "rev-list", "--left-right", "--count", "HEAD...@{u}" })) |counts| {
            defer alloc.free(counts);
            var parts = std.mem.tokenizeAny(u8, counts, " \t");
            status.ahead = std.fmt.parseUnsigned(u32, parts.next() orelse "0", 10) catch 0;
            status.behind = std.fmt.parseUnsigned(u32, parts.next() orelse "0", 10) catch 0;
        }
    }
    var porcelain = try git(alloc, runner, source.checkout, &.{ "status", "--porcelain", "--untracked-files=no" });
    defer porcelain.deinit(alloc);
    status.dirty = porcelain.ok and std.mem.trim(u8, porcelain.stdout, " \t\r\n").len > 0;
    return status;
}

/// Fast-forwards the checkout when it is behind, then rebuilds it. Refuses a
/// dirty, diverged, or detached checkout before it changes anything.
pub fn pullAndBuild(alloc: Allocator, runner: Runner, source: Source, status: Status, stream: bool) !void {
    if (status.behind > 0) {
        if (std.mem.eql(u8, status.branch, "HEAD")) return error.DetachedHead;
        if (status.dirty) return error.DirtyCheckout;
        if (status.ahead > 0) return error.Diverged;
        var merged = try git(alloc, runner, source.checkout, &.{ "merge", "--ff-only", "--quiet", "@{u}" });
        defer merged.deinit(alloc);
        if (!merged.ok) return error.MergeFailed;
    }
    var argv_buf: [3][]const u8 = undefined;
    argv_buf[0] = source.zig_exe;
    argv_buf[1] = "build";
    var argc: usize = 2;
    var optimize_arg: ?[]u8 = null;
    defer if (optimize_arg) |value| alloc.free(value);
    if (source.optimize.len > 0) {
        optimize_arg = try alloc.print("-Doptimize={s}", .{source.optimize});
        argv_buf[argc] = optimize_arg.?;
        argc += 1;
    }
    var built = try runner.run(runner.ctx, alloc, .{ .argv = argv_buf[0..argc], .cwd = source.checkout, .stream = stream });
    defer built.deinit(alloc);
    if (!built.ok) return error.BuildFailed;
}

/// `<checkout>/zig-out/bin/proto-fx`, owned by the caller.
pub fn builtBinaryPath(alloc: Allocator, checkout: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ checkout, "zig-out", "bin", binary_name });
}

/// Copies `built` next to `target` under a temporary name, then renames it
/// over `target`. The running process keeps its old inode; the next exec
/// gets the new file. Returns false when `built` already is `target`.
pub fn installAtomic(alloc: Allocator, built: []const u8, target: []const u8) !bool {
    const zio = io_mod.getIo();
    const built_real = io_mod.realpathAlloc(alloc, built) catch return error.BuiltBinaryMissing;
    defer alloc.free(built_real);
    const target_real = io_mod.realpathAlloc(alloc, target) catch try alloc.dupe(u8, target);
    defer alloc.free(target_real);
    if (std.mem.eql(u8, built_real, target_real)) return false;
    const dir = std.Io.Dir.path.dirname(target_real) orelse return error.InstallFailed;
    const temp = try alloc.print("{s}/.{s}.update-{d}", .{ dir, std.Io.Dir.path.basename(target_real), io_mod.nanoTimestamp() });
    defer alloc.free(temp);
    copyExecutable(zio, built_real, temp) catch {
        std.Io.Dir.deleteFileAbsolute(zio, temp) catch {};
        return error.InstallFailed;
    };
    std.Io.Dir.renameAbsolute(temp, target_real, zio) catch {
        std.Io.Dir.deleteFileAbsolute(zio, temp) catch {};
        return error.InstallFailed;
    };
    return true;
}

fn copyExecutable(zio: std.Io, src_path: []const u8, dest_path: []const u8) !void {
    var src = try std.Io.Dir.openFileAbsolute(zio, src_path, .{});
    defer src.close(zio);
    var dest = try std.Io.Dir.createFileAbsolute(zio, dest_path, .{ .exclusive = true });
    defer dest.close(zio);
    var read_buf: [8192]u8 = undefined;
    var reader = src.readerStreaming(zio, &read_buf);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try dest.writeStreamingAll(zio, chunk[0..n]);
    }
    try dest.setPermissions(zio, .fromMode(0o755));
}

fn git(alloc: Allocator, runner: Runner, checkout: []const u8, args: []const []const u8) !Output {
    var argv: [10][]const u8 = undefined;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = checkout;
    @memcpy(argv[3..][0..args.len], args);
    return runner.run(runner.ctx, alloc, .{ .argv = argv[0 .. 3 + args.len], .cwd = checkout });
}

/// The first line of a successful git command, or null when it failed.
fn gitLine(alloc: Allocator, runner: Runner, checkout: []const u8, args: []const []const u8) !?[]u8 {
    var out = try git(alloc, runner, checkout, args);
    defer out.deinit(alloc);
    if (!out.ok) return null;
    const line = firstLine(out.stdout, "");
    if (line.len == 0) return null;
    return try alloc.dupe(u8, line);
}

fn firstLine(text: []const u8, fallback: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len];
    return if (line.len == 0) fallback else std.mem.trimEnd(u8, line, "\r");
}

// Tests drive a scripted runner: each git subcommand maps to a canned answer.

pub const FakeRunner = struct {
    head: []const u8 = "1111111111111111111111111111111111111111",
    branch: []const u8 = "main",
    upstream: ?[]const u8 = "origin/main",
    counts: []const u8 = "0\t0",
    porcelain: []const u8 = "",
    fetch_ok: bool = true,
    merge_ok: bool = true,
    build_ok: bool = true,
    log: [16][]const u8 = undefined,
    log_len: usize = 0,

    pub fn runner(self: *FakeRunner) Runner {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: ?*anyopaque, alloc: Allocator, command: Command) anyerror!Output {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx.?));
        const verb = if (std.mem.eql(u8, command.argv[0], "git")) command.argv[3] else command.argv[1];
        if (self.log_len < self.log.len) {
            self.log[self.log_len] = verb;
            self.log_len += 1;
        }
        if (std.mem.eql(u8, verb, "build")) return .{ .ok = self.build_ok };
        if (std.mem.eql(u8, verb, "fetch")) return reply(alloc, self.fetch_ok, "", "fatal: unable to access remote\n");
        if (std.mem.eql(u8, verb, "merge")) return reply(alloc, self.merge_ok, "", "");
        if (std.mem.eql(u8, verb, "status")) return reply(alloc, true, self.porcelain, "");
        if (std.mem.eql(u8, verb, "rev-list")) return reply(alloc, true, self.counts, "");
        // rev-parse: HEAD, --abbrev-ref HEAD, or the upstream.
        const last = command.argv[command.argv.len - 1];
        if (std.mem.eql(u8, last, "@{u}")) return if (self.upstream) |value| reply(alloc, true, value, "") else reply(alloc, false, "", "no upstream");
        if (command.argv.len == 5) return reply(alloc, true, self.head, "");
        return reply(alloc, true, self.branch, "");
    }

    fn reply(alloc: Allocator, ok: bool, stdout: []const u8, stderr: []const u8) !Output {
        const out = try alloc.dupe(u8, stdout);
        errdefer alloc.free(out);
        return .{ .ok = ok, .stdout = out, .stderr = try alloc.dupe(u8, stderr) };
    }

    pub fn ran(self: *const FakeRunner, verb: []const u8) bool {
        for (self.log[0..self.log_len]) |entry| if (std.mem.eql(u8, entry, verb)) return true;
        return false;
    }
};

const test_source: Source = .{ .checkout = "/Users/example/proto-fx", .revision = "111111111111", .optimize = "ReleaseFast" };

test "inspect reports behind, ahead, dirty and a failed fetch" {
    const alloc = std.testing.allocator;
    var fake: FakeRunner = .{ .counts = "1\t3\n", .porcelain = " M src/main.zig\n", .fetch_ok = false };
    var status = try inspect(alloc, fake.runner(), test_source, true);
    defer status.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), status.ahead);
    try std.testing.expectEqual(@as(u32, 3), status.behind);
    try std.testing.expect(status.dirty);
    try std.testing.expectEqualStrings("origin/main", status.upstream.?);
    try std.testing.expectEqualStrings("fatal: unable to access remote", status.fetch_error.?);
    try std.testing.expect(!status.needsRebuild("111111111111"));
    try std.testing.expect(status.needsRebuild("222222222222"));
}

test "pullAndBuild refuses dirty, diverged and detached checkouts before merging" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { fake: FakeRunner, err: anyerror }{
        .{ .fake = .{ .counts = "0\t2", .porcelain = " M build.zig" }, .err = error.DirtyCheckout },
        .{ .fake = .{ .counts = "1\t2" }, .err = error.Diverged },
        .{ .fake = .{ .counts = "0\t2", .branch = "HEAD" }, .err = error.DetachedHead },
    };
    for (cases) |case| {
        var fake = case.fake;
        var status = try inspect(alloc, fake.runner(), test_source, false);
        defer status.deinit(alloc);
        try std.testing.expectError(case.err, pullAndBuild(alloc, fake.runner(), test_source, status, false));
        try std.testing.expect(!fake.ran("merge"));
        try std.testing.expect(!fake.ran("build"));
    }
}

test "pullAndBuild fast-forwards then builds, and reports a failed build" {
    const alloc = std.testing.allocator;
    var fake: FakeRunner = .{ .counts = "0\t2" };
    var status = try inspect(alloc, fake.runner(), test_source, false);
    defer status.deinit(alloc);
    try pullAndBuild(alloc, fake.runner(), test_source, status, false);
    try std.testing.expect(fake.ran("merge"));
    try std.testing.expect(fake.ran("build"));

    var failing: FakeRunner = .{ .build_ok = false };
    try std.testing.expectError(error.BuildFailed, pullAndBuild(alloc, failing.runner(), test_source, status, false));
}

test "installAtomic renames over the target and keeps the running inode" {
    const alloc = std.testing.allocator;
    const zio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(zio, .{ .sub_path = "built", .data = "new binary" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "proto-fx", .data = "old binary" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const built = try std.Io.Dir.path.join(alloc, &.{ root, "built" });
    defer alloc.free(built);
    const target = try std.Io.Dir.path.join(alloc, &.{ root, "proto-fx" });
    defer alloc.free(target);

    // A process running the old binary holds it open.
    var running = try tmp.dir.openFile(zio, "proto-fx", .{});
    defer running.close(zio);

    try std.testing.expect(try installAtomic(alloc, built, target));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("new binary", try tmp.dir.readFile(zio, "proto-fx", &buf));
    const old_len = try running.readPositionalAll(zio, &buf, 0);
    try std.testing.expectEqualStrings("old binary", buf[0..old_len]);
    const stat = try tmp.dir.statFile(zio, "proto-fx", .{});
    try std.testing.expect(stat.permissions.toMode() & 0o111 != 0);
    // Installing a file over itself changes nothing.
    try std.testing.expect(!try installAtomic(alloc, target, target));
}
