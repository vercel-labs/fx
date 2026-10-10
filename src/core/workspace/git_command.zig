//! Builds git invocations for fx's own read-only work: workspace discovery,
//! search, prompt snapshots, and shell commands fx runs without review.
//!
//! Repository config is untrusted when fx starts in a directory that arrived
//! with its `.git` directory, such as an extracted archive. Several config
//! keys name programs that ordinary read commands run. Configuration passed
//! with `-c` takes precedence over repository config, so every invocation
//! starts with `global_options`, and commands that compare file contents also
//! add `repositoryFilterOverrides`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Options placed before the subcommand of every fx-owned git invocation.
/// `core.fsmonitor` and `core.hooksPath` otherwise run configured programs
/// while git reads or refreshes the index. `safe.bareRepository=explicit`
/// keeps git from adopting a bare repository nested inside a checkout.
pub const global_options = [_][]const u8{
    "--no-pager",
    "--no-optional-locks",
    "-c",
    "core.fsmonitor=",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "safe.bareRepository=explicit",
};

/// Fixed-length argv holding the executable, `global_options`, and a tail.
pub fn Argv(comptime tail_len: usize) type {
    return [1 + global_options.len + tail_len][]const u8;
}

/// Returns `executable`, `global_options`, then `tail`. The result borrows
/// `executable`.
pub fn argv(executable: []const u8, comptime tail: []const []const u8) Argv(tail.len) {
    return [_][]const u8{executable} ++ global_options ++ tail[0..tail.len].*;
}

/// Appends `executable` and `global_options` to `list`. The appended entries
/// borrow `executable` and static strings.
pub fn appendPrefix(
    alloc: Allocator,
    list: *std.ArrayList([]const u8),
    executable: []const u8,
) Allocator.Error!void {
    try list.append(alloc, executable);
    try list.appendSlice(alloc, &global_options);
}

/// Returns the first git executable at a fixed system location, so a
/// directory on PATH cannot substitute its own `git`.
pub fn trustedExecutable() ?[]const u8 {
    const candidates = switch (builtin.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
        },
        else => &[_][]const u8{
            "/usr/bin/git",
            "/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/opt/local/bin/git",
            "/run/current-system/sw/bin/git",
        },
    };
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file) return candidate;
    }
    return null;
}

/// Child-only environment for fx-owned git reads. Blocking all transports
/// prevents lazy object fetches even on Git versions that do not honor
/// GIT_NO_LAZY_FETCH, without changing the user's environment or shell.
/// Caller owns and deinitializes the result.
pub fn readOnlyEnvironment(alloc: Allocator, base: ?*const std.process.Environ.Map) !std.process.Environ.Map {
    var environment = if (base) |map|
        try map.clone(alloc)
    else
        io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
            error.EnvironmentUnavailable => std.process.Environ.Map.init(alloc),
            else => return err,
        };
    errdefer environment.deinit();
    try hardenEnvironment(&environment);
    return environment;
}

/// Adds transport and lazy-fetch guards to an already owned child environment.
pub fn hardenEnvironment(environment: *std.process.Environ.Map) Allocator.Error!void {
    try environment.put("GIT_ALLOW_PROTOCOL", "");
    try environment.put("GIT_NO_LAZY_FETCH", "1");
    try environment.put("GIT_TERMINAL_PROMPT", "0");
}

const FilterOverrideError = Allocator.Error || error{ RepositoryFiltersUnverified, Cancelled, TimeoutExpired };

pub const QueryControl = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    started_ms: ?i64 = null,
    timeout_ms: ?usize = null,
};

const default_query_timeout_ms: usize = 5_000;

const filter_query_stdout_limit: usize = 64 * 1024;
const filter_driver_settings = [_][]const u8{ "clean=", "process=", "required=false" };

/// Returns `-c` options that disable each filter driver defined in repository
/// config: `.git/config`, worktree config, and files either one includes.
/// `git status` and `git diff` otherwise run a driver's clean or process
/// command while comparing file contents. User-configured drivers remain
/// active when the caller inherits user git config; the direct command route
/// intentionally disables global config. Returns `error.RepositoryFiltersUnverified`
/// when the config cannot be read or names a driver that `-c` cannot address.
///
/// Runs `executable` in `cwd` with `environ_map`, or with the inherited
/// environment when it is null, so the query sees the same config as the
/// caller's command. The returned slice and its strings are owned by `arena`.
pub fn repositoryFilterOverrides(
    arena: Allocator,
    executable: []const u8,
    cwd: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) FilterOverrideError![]const []const u8 {
    return repositoryFilterOverridesControlled(arena, executable, cwd, environ_map, .{});
}

/// The query checks cancellation and its deadline while waiting on Git.
/// An additional fixed bound protects snapshot generation without a caller
/// deadline from a repository config that includes a blocking FIFO.
pub fn repositoryFilterOverridesControlled(
    arena: Allocator,
    executable: []const u8,
    cwd: []const u8,
    environ_map: ?*const std.process.Environ.Map,
    control: QueryControl,
) FilterOverrideError![]const []const u8 {
    const query = argv(executable, &.{
        "config",
        "-z",
        "--show-scope",
        "--name-only",
        "--get-regexp",
        "^filter\\..*\\.(clean|process)$",
    });
    const started_ms = io_mod.milliTimestamp();
    try checkQueryControl(control, started_ms);
    var environment = readOnlyEnvironment(arena, environ_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RepositoryFiltersUnverified,
    };
    defer environment.deinit();
    const zio = io_mod.getIo();
    var child = std.process.spawn(zio, .{
        .argv = &query,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.RepositoryFiltersUnverified;
    defer child.kill(zio);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, zio, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const stdout = reader.reader(0);
    const stderr = reader.reader(1);
    const poll: std.Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 8_000_000 }, .clock = .awake } };
    while (true) {
        try checkQueryControl(control, started_ms);
        const keep_reading = if (reader.fill(64, poll))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => return error.RepositoryFiltersUnverified,
        };
        if (stdout.buffered().len > filter_query_stdout_limit or stderr.buffered().len > 1024)
            return error.RepositoryFiltersUnverified;
        if (!keep_reading) break;
    }
    reader.checkAnyError() catch return error.RepositoryFiltersUnverified;
    try checkQueryControl(control, started_ms);
    const term = child.wait(zio) catch return error.RepositoryFiltersUnverified;
    return switch (term) {
        .exited => |code| switch (code) {
            0 => try parseFilterOverrides(arena, stdout.buffered()),
            // No filter keys, including when running outside a repository.
            1 => &.{},
            else => error.RepositoryFiltersUnverified,
        },
        .signal, .stopped, .unknown => error.RepositoryFiltersUnverified,
    };
}

fn checkQueryControl(control: QueryControl, started_ms: i64) FilterOverrideError!void {
    if (control.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const now = io_mod.milliTimestamp();
    if (control.started_ms) |start| {
        if (control.timeout_ms) |ms| {
            if (now -| start >= @as(i64, @intCast(@min(ms, std.math.maxInt(i64)))))
                return error.TimeoutExpired;
        }
    }
    if (now -| started_ms >= @as(i64, default_query_timeout_ms)) return error.RepositoryFiltersUnverified;
}

/// Parses `git config -z --show-scope --name-only` output, a sequence of
/// NUL-terminated scope and key pairs.
fn parseFilterOverrides(arena: Allocator, output: []const u8) FilterOverrideError![]const []const u8 {
    var overrides: std.ArrayList([]const u8) = .empty;
    var drivers: std.ArrayList([]const u8) = .empty;
    var fields = std.mem.splitScalar(u8, output, 0);
    while (fields.next()) |scope| {
        if (scope.len == 0 and fields.peek() == null) break;
        const key = fields.next() orelse return error.RepositoryFiltersUnverified;
        if (!isRepositoryScope(scope)) continue;

        const driver = filterDriver(key) orelse return error.RepositoryFiltersUnverified;
        // `-c` splits the key from the value at the first '='.
        if (std.mem.findScalar(u8, driver, '=') != null) return error.RepositoryFiltersUnverified;
        if (containsString(drivers.items, driver)) continue;
        try drivers.append(arena, driver);

        for (filter_driver_settings) |setting| {
            try overrides.append(arena, "-c");
            try overrides.append(arena, try std.fmt.allocPrint(arena, "filter.{s}.{s}", .{ driver, setting }));
        }
    }
    return overrides.toOwnedSlice(arena);
}

fn isRepositoryScope(scope: []const u8) bool {
    return std.mem.eql(u8, scope, "local") or std.mem.eql(u8, scope, "worktree");
}

fn filterDriver(key: []const u8) ?[]const u8 {
    const prefix = "filter.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const last_dot = std.mem.findScalarLast(u8, key, '.') orelse return null;
    if (last_dot <= prefix.len) return null;
    return key[prefix.len..last_dot];
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// A repository whose config makes each known git read path run a program
/// that appends to `marker`. Tests assert that the marker never appears.
pub const TrapRepositoryForTest = struct {
    root: []u8,
    marker: []u8,

    pub fn deinit(self: TrapRepositoryForTest, alloc: Allocator) void {
        alloc.free(self.marker);
        alloc.free(self.root);
    }

    /// Rewrites the tracked file with changed content for the next git read.
    pub fn touchTrackedFile(tmp: *std.testing.TmpDir, content: []const u8) !void {
        try writeFileForTest(tmp.dir, "repo/tracked.txt", content, .default_file);
    }

    pub fn markerExists(self: TrapRepositoryForTest) bool {
        _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), self.marker, .{}) catch return false;
        return true;
    }
};

/// Creates `repo/` in `tmp` with a committed `tracked.txt`, then configures
/// an fsmonitor and a required clean filter that append to `<tmp>/marker`.
/// Returns `error.SkipZigTest` when git is unavailable.
pub fn createTrapRepositoryForTest(alloc: Allocator, tmp: *std.testing.TmpDir) !TrapRepositoryForTest {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const executable = trustedExecutable() orelse return error.SkipZigTest;

    try tmp.dir.createDir(std.testing.io, "repo", .default_dir);
    try writeFileForTest(tmp.dir, "repo/.gitattributes", "*.txt filter=trap\n", .default_file);
    try writeFileForTest(tmp.dir, "repo/tracked.txt", "needle\n", .default_file);

    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const root = try std.fs.path.join(alloc, &.{ base, "repo" });
    errdefer alloc.free(root);
    const marker = try std.fs.path.join(alloc, &.{ base, "marker" });
    errdefer alloc.free(marker);

    try runGitForTest(alloc, executable, root, &.{ "init", "--quiet" });
    try runGitForTest(alloc, executable, root, &.{ "add", "." });
    try runGitForTest(alloc, executable, root, &.{
        "-c", "user.name=fx", "-c", "user.email=fx@example.invalid", "commit", "--quiet", "-m", "trap",
    });

    const fsmonitor = try std.fmt.allocPrint(alloc, "echo fsmonitor >> '{s}'; false", .{marker});
    defer alloc.free(fsmonitor);
    const clean = try std.fmt.allocPrint(alloc, "sh -c 'echo filter >> \"{s}\"; cat'", .{marker});
    defer alloc.free(clean);
    const settings = [_][2][]const u8{
        .{ "core.fsmonitor", fsmonitor },
        .{ "filter.trap.clean", clean },
        .{ "filter.trap.required", "true" },
    };
    for (settings) |setting| {
        try runGitForTest(alloc, executable, root, &.{ "config", setting[0], setting[1] });
    }

    return .{ .root = root, .marker = marker };
}

fn writeFileForTest(
    dir: std.Io.Dir,
    sub_path: []const u8,
    content: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    var file = try dir.createFile(std.testing.io, sub_path, .{ .permissions = permissions });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn runGitForTest(alloc: Allocator, executable: []const u8, cwd: []const u8, args: []const []const u8) !void {
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(alloc);
    try command.append(alloc, executable);
    try command.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = command.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        .signal, .stopped, .unknown => return error.SkipZigTest,
    }
}

fn runHardenedForTest(
    alloc: Allocator,
    cwd: []const u8,
    overrides: []const []const u8,
    args: []const []const u8,
) !u8 {
    const executable = trustedExecutable() orelse return error.SkipZigTest;
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(alloc);
    try appendPrefix(alloc, &command, executable);
    try command.appendSlice(alloc, overrides);
    try command.appendSlice(alloc, args);

    const result = try std.process.run(alloc, std.testing.io, .{
        .argv = command.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => error.TestUnexpectedResult,
    };
}

test "git argv pins hardening options before the subcommand" {
    const command = argv("/usr/bin/git", &.{ "ls-files", "-z" });
    const expected = [_][]const u8{
        "/usr/bin/git",
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "safe.bareRepository=explicit",
        "ls-files",
        "-z",
    };
    try std.testing.expectEqual(expected.len, command.len);
    for (expected, command) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "git read-only environment forbids transports and lazy fetch without mutating caller" {
    const alloc = std.testing.allocator;
    var base = std.process.Environ.Map.init(alloc);
    defer base.deinit();
    try base.put("GIT_ALLOW_PROTOCOL", "ssh");
    try base.put("HOME", "/tmp");
    var child = try readOnlyEnvironment(alloc, &base);
    defer child.deinit();
    try std.testing.expectEqualStrings("", child.get("GIT_ALLOW_PROTOCOL").?);
    try std.testing.expectEqualStrings("1", child.get("GIT_NO_LAZY_FETCH").?);
    try std.testing.expectEqualStrings("0", child.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("/tmp", child.get("HOME").?);
    try std.testing.expectEqualStrings("ssh", base.get("GIT_ALLOW_PROTOCOL").?);
}

test "filter overrides disable repository drivers once and keep user drivers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const overrides = try parseFilterOverrides(
        arena_state.allocator(),
        "global\x00filter.lfs.clean\x00local\x00filter.Trap.clean\x00local\x00filter.Trap.process\x00" ++
            "worktree\x00filter.dotted.name.process\x00command\x00filter.cli.clean\x00",
    );
    const expected = [_][]const u8{
        "-c", "filter.Trap.clean=",
        "-c", "filter.Trap.process=",
        "-c", "filter.Trap.required=false",
        "-c", "filter.dotted.name.clean=",
        "-c", "filter.dotted.name.process=",
        "-c", "filter.dotted.name.required=false",
    };
    try std.testing.expectEqual(expected.len, overrides.len);
    for (expected, overrides) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "filter overrides reject output they cannot address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(usize, 0), (try parseFilterOverrides(arena, "")).len);
    const rejected = [_][]const u8{
        "local\x00filter.a=b.clean\x00",
        "local\x00filter.clean\x00",
        "local\x00core.fsmonitor\x00",
        "local\x00",
    };
    for (rejected) |output| {
        try std.testing.expectError(error.RepositoryFiltersUnverified, parseFilterOverrides(arena, output));
    }
}

test "filter query stops when a repository include blocks on a FIFO" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const executable = trustedExecutable() orelse return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "repo", .default_dir);
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const root = try std.fs.path.join(alloc, &.{ base, "repo" });
    defer alloc.free(root);
    const fifo = try std.fs.path.join(alloc, &.{ base, "included-config" });
    defer alloc.free(fifo);
    try runGitForTest(alloc, executable, root, &.{ "init", "--quiet" });
    const mkfifo = try std.process.run(alloc, std.testing.io, .{ .argv = &.{ "/usr/bin/mkfifo", fifo } });
    defer alloc.free(mkfifo.stdout);
    defer alloc.free(mkfifo.stderr);
    if (mkfifo.term != .exited or mkfifo.term.exited != 0) return error.SkipZigTest;
    try runGitForTest(alloc, executable, root, &.{ "config", "include.path", fifo });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const started = io_mod.milliTimestamp();
    try std.testing.expectError(error.TimeoutExpired, repositoryFilterOverridesControlled(
        arena_state.allocator(),
        executable,
        root,
        null,
        .{ .started_ms = started, .timeout_ms = 200 },
    ));
    try std.testing.expect(io_mod.milliTimestamp() - started < 3_000);

    var cancelled = std.atomic.Value(bool).init(false);
    const cancellation = try std.Thread.spawn(.{}, struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    }.run, .{&cancelled});
    defer cancellation.join();
    try std.testing.expectError(error.Cancelled, repositoryFilterOverridesControlled(
        arena_state.allocator(),
        executable,
        root,
        null,
        .{ .cancel_flag = &cancelled },
    ));
}

test "trap repository runs programs through plain git but not hardened git" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trap = try createTrapRepositoryForTest(alloc, &tmp);
    defer trap.deinit(alloc);

    // Plain git runs the configured monitor, which proves the trap is armed.
    try runGitForTest(alloc, trustedExecutable().?, trap.root, &.{ "ls-files", "-z" });
    try std.testing.expect(trap.markerExists());
    try tmp.dir.deleteFile(std.testing.io, "marker");

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const overrides = try repositoryFilterOverrides(arena_state.allocator(), trustedExecutable().?, trap.root, null);
    try std.testing.expect(overrides.len > 0);

    const commands = [_][]const []const u8{
        &.{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        &.{ "status", "--short", "--ignore-submodules=dirty" },
        &.{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty" },
        &.{ "diff", "--no-ext-diff", "--no-textconv", "--stat", "--ignore-submodules=dirty" },
    };
    for (commands, 0..) |command, index| {
        const changed = try std.fmt.allocPrint(alloc, "needle changed {d}\n", .{index});
        defer alloc.free(changed);
        try TrapRepositoryForTest.touchTrackedFile(&tmp, changed);
        try std.testing.expectEqual(@as(u8, 0), try runHardenedForTest(alloc, trap.root, overrides, command));
        try std.testing.expect(!trap.markerExists());
    }
}
