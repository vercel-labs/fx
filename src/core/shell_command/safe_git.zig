//! The one way fx runs git itself: the `fx pr` and `fx issue` snapshot and the
//! agent's auto-run `git status`, `git diff` and `git log`. A repository's own
//! config can name programs: fsmonitor, hooks, a pager, diff drivers, filter
//! drivers and a signature verifier. Every invocation turns those off, while
//! the user's global and system config stay trusted, so a global Git LFS still
//! works. When fx cannot establish that, `prepare` refuses and git does not run.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const indexer = @import("../indexer/indexer.zig");

const Allocator = std.mem.Allocator;

/// `core.fsmonitor` became a boolean in git 2.36. Older git reads the value
/// as a hook program.
const minimum_major: u32 = 2;
const minimum_minor: u32 = 36;

const max_probe_output: usize = 4096;

pub const Refusal = enum {
    git_missing,
    git_version_unknown,
    git_too_old,
    repo_config_unavailable,
    /// `-c` splits at the first `=`, so such a driver cannot be blanked.
    unsupported_filter_name,
    /// git would use a different repository than the one whose config fx read.
    repository_mismatch,
};

pub const Ready = struct {
    /// Static path from `trustedExecutable`.
    executable: []const u8,
    /// Filter drivers defined by repository-scope config.
    filter_names: []const []const u8,
};

pub const Prepared = union(enum) {
    ready: Ready,
    refused: Refusal,
};

pub const Subcommand = enum { status, diff, log, branch, rev_parse };

/// Decides whether git may run in the absolute directory `cwd`: reads the
/// repository's config as data, checks the trusted git's version once per
/// process, and confirms git resolves the same repository fx read. All memory
/// belongs to `arena`.
pub fn prepare(arena: Allocator, cwd: []const u8) Allocator.Error!Prepared {
    const filters = indexer.repoFilters(arena, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => return refuse(.repo_config_unavailable, cwd),
    };
    for (filters.names) |name| {
        if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null) return refuse(.unsupported_filter_name, cwd);
    }
    const executable = trustedExecutable() orelse return refuse(.git_missing, cwd);
    switch (try versionCheck(arena, executable)) {
        .supported => {},
        .too_old => return refuse(.git_too_old, cwd),
        .unknown => return refuse(.git_version_unknown, cwd),
    }
    const ready: Ready = .{ .executable = executable, .filter_names = filters.names };
    if (!try sameRepository(arena, ready, cwd, filters.git_dir)) return refuse(.repository_mismatch, cwd);
    return .{ .ready = ready };
}

fn refuse(reason: Refusal, cwd: []const u8) Prepared {
    debug_trace.logf("core", "safe git refused reason={s} cwd={s}", .{ @tagName(reason), cwd });
    return .{ .refused = reason };
}

/// Appends the trusted executable, the global options and `-c` overrides that
/// turn off repository programs, then `subcommand` with its own safety flags.
/// Callers append the remaining arguments. Formatted overrides are allocated
/// with `arena`; the other strings are static or borrowed from `ready`.
pub fn appendCommand(
    arena: Allocator,
    argv: *std.ArrayList([]const u8),
    ready: Ready,
    subcommand: Subcommand,
) Allocator.Error!void {
    try appendPrelude(arena, argv, ready);
    try argv.appendSlice(arena, switch (subcommand) {
        .status => &.{ "status", "--ignore-submodules=all" },
        .diff => &.{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .log => &.{ "log", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .branch => &.{"branch"},
        .rev_parse => &.{"rev-parse"},
    });
}

fn appendPrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: Ready) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "log.showSignature=false",
    });
    for (ready.filter_names) |name| {
        for ([_][]const u8{ "clean", "smudge", "process" }) |program| {
            try argv.append(arena, "-c");
            try argv.append(arena, try std.fmt.allocPrint(arena, "filter.{s}.{s}=", .{ name, program }));
        }
    }
}

/// The child environment for every safe git call: a fixed PATH and locale, no
/// prompts, pagers or optional locks, and only the variables that locate the
/// user's own git config. Nothing else from fx's environment, such as
/// `GIT_DIR` or `GIT_CONFIG_PARAMETERS`, reaches git.
pub fn environment(alloc: Allocator) Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("LC_ALL", "C");
    try map.put("LANG", "C");
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_PAGER", "cat");
    try map.put("PAGER", "cat");
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM" }) |key| {
        if (io_mod.getenv(key)) |value| try map.put(key, value);
    }
    return map;
}

/// The first git found at a fixed system location. git from PATH is never
/// used, because PATH can include directories a repository controls.
fn trustedExecutable() ?[]const u8 {
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

const VersionCheck = enum { supported, too_old, unknown };

var version_lock: std.Io.Mutex = .init;
var cached_version: ?struct { executable: []const u8, check: VersionCheck } = null;

/// Runs `git --version` once per executable and process. A failed probe is not
/// cached, so a transient spawn failure does not disable git for the session.
fn versionCheck(arena: Allocator, executable: []const u8) Allocator.Error!VersionCheck {
    const io = io_mod.getIo();
    version_lock.lockUncancelable(io);
    defer version_lock.unlock(io);
    if (cached_version) |cached| {
        if (std.mem.eql(u8, cached.executable, executable)) return cached.check;
    }
    const output = try runCaptured(arena, &.{ executable, "--version" }, "/") orelse return .unknown;
    const check = classifyVersion(output);
    cached_version = .{ .executable = executable, .check = check };
    return check;
}

fn classifyVersion(output: []const u8) VersionCheck {
    const prefix = "git version ";
    if (!std.mem.startsWith(u8, output, prefix)) return .unknown;
    var parts = std.mem.splitScalar(u8, output[prefix.len..], '.');
    const major = leadingNumber(parts.next() orelse "") orelse return .unknown;
    const minor = leadingNumber(parts.next() orelse "") orelse return .unknown;
    if (major != minimum_major) return if (major > minimum_major) .supported else .too_old;
    return if (minor >= minimum_minor) .supported else .too_old;
}

fn leadingNumber(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseUnsigned(u32, text[0..end], 10) catch null;
}

/// Confirms git resolves the repository whose config fx read. git accepts a
/// git directory used as the workspace, and fx's discovery does not, so
/// without this check git could run with config fx never read. `rev-parse`
/// reads config but runs none of the programs above.
fn sameRepository(arena: Allocator, ready: Ready, cwd: []const u8, expected: ?[]const u8) Allocator.Error!bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .rev_parse);
    try argv.append(arena, "--absolute-git-dir");
    const output = try runCaptured(arena, argv.items, cwd);
    const expected_dir = expected orelse return output == null;
    const reported = std.mem.trimEnd(u8, output orelse return false, "\r\n");
    const expected_real = io_mod.realpathAlloc(arena, expected_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const reported_real = io_mod.realpathAlloc(arena, reported) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.mem.eql(u8, expected_real, reported_real);
}

/// Standard output of a successful run, or null when git could not start or
/// failed. Memory belongs to `arena`.
fn runCaptured(arena: Allocator, argv: []const []const u8, cwd: []const u8) Allocator.Error!?[]const u8 {
    var env = try environment(arena);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(max_probe_output),
        .stderr_limit = .limited(max_probe_output),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

test "git version check requires 2.36 and reads vendor suffixes" {
    const cases = [_]struct { output: []const u8, expected: VersionCheck }{
        .{ .output = "git version 2.50.1 (Apple Git-155)\n", .expected = .supported },
        .{ .output = "git version 2.36.0\n", .expected = .supported },
        .{ .output = "git version 2.39.3.windows.1\n", .expected = .supported },
        .{ .output = "git version 3.0.0\n", .expected = .supported },
        .{ .output = "git version 2.35.8\n", .expected = .too_old },
        .{ .output = "git version 1.9.5\n", .expected = .too_old },
        .{ .output = "hub version 2.14\n", .expected = .unknown },
        .{ .output = "git version x.y\n", .expected = .unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, classifyVersion(case.output));
}

test "safe git argv turns off repository programs for every subcommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{ "lfs", "evil.x" } };
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .diff);
    const expected = [_][]const u8{
        "/usr/bin/git",             "--no-pager",           "--no-optional-locks",
        "-c",                       "core.fsmonitor=false", "-c",
        "core.hooksPath=/dev/null", "-c",                   "log.showSignature=false",
        "-c",                       "filter.lfs.clean=",    "-c",
        "filter.lfs.smudge=",       "-c",                   "filter.lfs.process=",
        "-c",                       "filter.evil.x.clean=", "-c",
        "filter.evil.x.smudge=",    "-c",                   "filter.evil.x.process=",
        "diff",                     "--no-ext-diff",        "--no-textconv",
        "--ignore-submodules=all",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "safe git environment keeps only fixed values and user config locations" {
    var env = try environment(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_OPTIONAL_LOCKS").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("cat", env.get("GIT_PAGER").?);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_EXEC_PATH" }) |key| {
        try std.testing.expect(env.get(key) == null);
    }
}

/// A real repository with a sentinel program that appends to a log whenever
/// git runs it. Setup and control runs use plain git; helper runs use the
/// helper's environment. Both are isolated from the developer's git config.
/// There is no pager route here: git never pages when its output is not a
/// terminal, and fx always pipes it, so `--no-pager` and `GIT_PAGER=cat` are
/// covered by the argv and environment tests above.
const SentinelRepo = struct {
    arena: Allocator,
    git: []const u8,
    root: []const u8,
    repo: []const u8,
    home: []const u8,
    log: []const u8,
    sentinel: []const u8,

    const Mode = union(enum) {
        plain,
        /// The helper's environment, optionally reading this system config.
        safe: ?[]const u8,
    };

    fn init(arena: Allocator, dir: std.Io.Dir) !SentinelRepo {
        const git = trustedExecutable() orelse return error.SkipZigTest;
        if (try versionCheck(arena, git) != .supported) return error.SkipZigTest;
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const self: SentinelRepo = .{
            .arena = arena,
            .git = git,
            .root = root,
            .repo = try std.fs.path.join(arena, &.{ root, "repo" }),
            .home = try std.fs.path.join(arena, &.{ root, "home" }),
            .log = try std.fs.path.join(arena, &.{ root, "sentinel.log" }),
            .sentinel = try std.fs.path.join(arena, &.{ root, "sentinel.sh" }),
        };
        try dir.createDirPath(std.testing.io, "home");
        try dir.createDirPath(std.testing.io, "repo");
        try self.writeExecutable(self.sentinel);
        try self.plain(self.repo, &.{ "init", "-q", "--template=", "-b", "main" });
        try self.write("repo/a.txt", "one\n");
        try self.plain(self.repo, &.{ "add", "a.txt" });
        try self.commit(self.repo);
        return self;
    }

    fn path(self: SentinelRepo, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena, &.{ self.root, sub_path });
    }

    fn writeExecutable(self: SentinelRepo, absolute: []const u8) !void {
        const script = try std.fmt.allocPrint(self.arena, "#!/bin/sh\necho ran >> '{s}'\ncat\n", .{self.log});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    }

    fn write(self: SentinelRepo, sub_path: []const u8, data: []const u8) !void {
        const absolute = try self.path(sub_path);
        if (std.fs.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn commit(self: SentinelRepo, cwd: []const u8) !void {
        try self.plain(cwd, &.{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "fixture" });
    }

    fn childEnvironment(self: SentinelRepo, mode: Mode) !std.process.Environ.Map {
        var env = switch (mode) {
            .plain => blk: {
                var plain_env = std.process.Environ.Map.init(self.arena);
                try plain_env.put("PATH", "/usr/bin:/bin");
                try plain_env.put("LC_ALL", "C");
                break :blk plain_env;
            },
            .safe => try environment(self.arena),
        };
        try env.put("HOME", self.home);
        try env.put("XDG_CONFIG_HOME", try std.fs.path.join(self.arena, &.{ self.home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", try std.fs.path.join(self.arena, &.{ self.home, ".gitconfig" }));
        const system: ?[]const u8 = switch (mode) {
            .plain => null,
            .safe => |value| value,
        };
        if (system) |config_path| {
            try env.put("GIT_CONFIG_SYSTEM", config_path);
            try env.put("GIT_CONFIG_NOSYSTEM", "0");
        } else try env.put("GIT_CONFIG_NOSYSTEM", "1");
        return env;
    }

    fn run(self: SentinelRepo, cwd: []const u8, argv: []const []const u8, mode: Mode) !std.process.RunResult {
        var env = try self.childEnvironment(mode);
        return std.process.run(self.arena, std.testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
    }

    fn plainArgv(self: SentinelRepo, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, self.git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    fn plainOutput(self: SentinelRepo, cwd: []const u8, args: []const []const u8) ![]const u8 {
        const result = try self.run(cwd, try self.plainArgv(args), .plain);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git {s} failed: {s}\n", .{ args[0], result.stderr });
        return error.FixtureGitFailed;
    }

    fn plain(self: SentinelRepo, cwd: []const u8, args: []const []const u8) !void {
        _ = try self.plainOutput(cwd, args);
    }

    fn runs(self: SentinelRepo) !usize {
        var file = std.Io.Dir.openFileAbsolute(std.testing.io, self.log, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        const data = try io_mod.readFileToEnd(self.arena, &file, 1 << 16);
        file.close(std.testing.io);
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, self.log);
        return std.mem.count(u8, data, "ran\n");
    }

    fn ready(self: SentinelRepo, cwd: []const u8) !Ready {
        return switch (try prepare(self.arena, cwd)) {
            .ready => |value| value,
            .refused => |reason| {
                std.debug.print("safe git refused: {s}\n", .{@tagName(reason)});
                return error.TestUnexpectedRefusal;
            },
        };
    }

    fn helperArgv(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try appendCommand(self.arena, &argv, try self.ready(cwd), subcommand);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs `subcommand` through the helper, then `control` through plain
    /// git. The helper must never run the sentinel; the control must, or the
    /// fixture does not exercise the route. The helper runs first because it
    /// never refreshes the index, which would hide the change from the control.
    fn expectBlocked(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8, control: []const []const u8) !void {
        _ = try self.run(cwd, try self.helperArgv(cwd, subcommand, args), .{ .safe = null });
        try std.testing.expectEqual(@as(usize, 0), try self.runs());
        _ = try self.run(cwd, try self.plainArgv(control), .plain);
        try std.testing.expect(try self.runs() > 0);
    }
};

test "safe git blocks a repository fsmonitor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.plain(repo.repo, &.{ "config", "core.fsmonitor", repo.sentinel });
    try repo.write("repo/a.txt", "one\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git blocks repository hooks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const hooks = try repo.path("hooks");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hooks);
    try repo.writeExecutable(try repo.path("hooks/post-index-change"));
    try repo.plain(repo.repo, &.{ "config", "core.hooksPath", hooks });
    try repo.write("repo/a.txt", "one\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git blocks a repository external diff and textconv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.plain(repo.repo, &.{ "config", "diff.external", repo.sentinel });
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{"diff"});

    try repo.plain(repo.repo, &.{ "config", "--unset", "diff.external" });
    try repo.write("repo/.git/info/attributes", "a.txt diff=tc\n");
    try repo.plain(repo.repo, &.{ "config", "diff.tc.textconv", repo.sentinel });
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{"diff"});
}

test "safe git blocks repository clean, process and smudge filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.write("repo/.git/info/attributes", "a.txt filter=evil\n");

    try repo.plain(repo.repo, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
    try repo.write("repo/a.txt", "three\n");
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{ "diff", "--stat" });
    try repo.plain(repo.repo, &.{ "config", "--unset", "filter.evil.clean" });

    try repo.plain(repo.repo, &.{ "config", "filter.evil.process", repo.sentinel });
    // Same size as the committed "one\n": with a different size, git status
    // can report the change from the index stat alone and skip the filter.
    try repo.write("repo/a.txt", "ten\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
    try repo.plain(repo.repo, &.{ "config", "--unset", "filter.evil.process" });

    // No read-only command checks files out, so smudge is shown through the
    // shared prelude on `checkout`, where git would run it.
    try repo.plain(repo.repo, &.{ "config", "filter.evil.smudge", repo.sentinel });
    const file = try repo.path("repo/a.txt");
    var argv: std.ArrayList([]const u8) = .empty;
    try appendPrelude(repo.arena, &argv, try repo.ready(repo.repo));
    try argv.appendSlice(repo.arena, &.{ "checkout", "--", "a.txt" });
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, file);
    _ = try repo.run(repo.repo, argv.items, .{ .safe = null });
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, file);
    _ = try repo.run(repo.repo, try repo.plainArgv(&.{ "checkout", "--", "a.txt" }), .plain);
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git blocks a repository signature program" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const object = try std.fmt.allocPrint(repo.arena,
        \\tree {s}
        \\parent {s}
        \\author fixture <fixture@example.invalid> 1 +0000
        \\committer fixture <fixture@example.invalid> 1 +0000
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ 
        \\ AAAA
        \\ -----END PGP SIGNATURE-----
        \\
        \\signed
        \\
    , .{ try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD^{tree}" }), try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" }) });
    const object_path = try repo.path("signed-commit");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = object_path, .data = object });
    const signed = try repo.plainOutput(repo.repo, &.{ "hash-object", "-t", "commit", "-w", object_path });
    try repo.plain(repo.repo, &.{ "update-ref", "refs/heads/main", signed });
    try repo.plain(repo.repo, &.{ "config", "log.showSignature", "true" });
    try repo.plain(repo.repo, &.{ "config", "gpg.program", repo.sentinel });
    try repo.expectBlocked(repo.repo, .log, &.{ "--oneline", "-1" }, &.{ "log", "-1" });
}

test "safe git does not enter submodules, whose config it never read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const sub = try repo.path("repo/sub");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub);
    try repo.plain(sub, &.{ "init", "-q", "--template=", "-b", "main" });
    try repo.write("repo/sub/b.txt", "one\n");
    try repo.plain(sub, &.{ "add", "b.txt" });
    try repo.commit(sub);
    try repo.plain(repo.repo, &.{ "add", "sub" });
    try repo.commit(repo.repo);
    try repo.write("repo/sub/.git/info/attributes", "b.txt filter=evil\n");
    try repo.plain(sub, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/sub/b.txt", "two\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git keeps trusted system config filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const system = try repo.path("system.gitconfig");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = system,
        .data = try std.fmt.allocPrint(repo.arena, "[filter \"trusted\"]\n\tclean = {s}\n", .{repo.sentinel}),
    });
    try repo.write("repo/.git/info/attributes", "a.txt filter=trusted\n");
    try repo.write("repo/a.txt", "two\n");
    _ = try repo.run(repo.repo, try repo.helperArgv(repo.repo, .status, &.{"--short"}), .{ .safe = system });
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git follows git's repository choice and refuses what it cannot blank" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);

    // git skips an inner `.git` without `refs` and uses the outer repository.
    // fx makes the same choice, so the outer repository's filter is blanked.
    try repo.write("repo/.git/info/attributes", "a.txt filter=evil\n");
    try repo.plain(repo.repo, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/inner/.git/HEAD", "ref: refs/heads/main\n");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try repo.path("repo/inner/.git/objects"));
    const inner = try repo.path("repo/inner");
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(inner, .status, &.{"--short"}, &.{ "status", "--short" });

    // A git directory used as the workspace, with a separate work tree. git
    // uses it; fx's discovery does not, so safe git refuses.
    const gitdir = try repo.path("gitdir");
    try repo.plain(repo.root, &.{ "init", "-q", "--bare", "--template=", gitdir });
    try repo.plain(gitdir, &.{ "config", "core.bare", "false" });
    try repo.plain(gitdir, &.{ "config", "core.worktree", repo.repo });
    try std.testing.expectEqual(Refusal.repository_mismatch, (try prepare(repo.arena, gitdir)).refused);

    try repo.plain(repo.repo, &.{ "config", "filter.a=b.clean", repo.sentinel });
    try std.testing.expectEqual(Refusal.unsupported_filter_name, (try prepare(repo.arena, repo.repo)).refused);
}
