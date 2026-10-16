//! The one way fx runs git itself: the `fx pr` and `fx issue` snapshot and the
//! agent's auto-run `git status`, `git diff`, `git log` and `git show`. A
//! repository's own config can name programs: fsmonitor, hooks, a pager, diff
//! drivers, filter drivers and a signature verifier. Every invocation turns
//! those off, while the user's global and system config stay trusted, so a
//! global Git LFS still works. When fx cannot establish that, `prepare`
//! refuses and git does not run. `appendAgentEnvironment` carries the same
//! protection, hooks aside, to every git an agent shell command starts.
//!
//! TLA+ model: `tests/tla/shell_command/GitAdmission.tla`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const indexer = @import("../indexer/indexer.zig");

const Allocator = std.mem.Allocator;

/// The oldest git these settings were checked against with planted programs
/// for every route: 2.25.1, 2.34.1 and 2.54.0. `core.fsmonitor` became a
/// boolean in git 2.36; older git runs the value as a hook command, and the
/// fixed PATH resolves `false` to the system `false`, which does nothing.
const minimum_major: u32 = 2;
const minimum_minor: u32 = 25;
/// git 2.31 added `GIT_CONFIG_COUNT`. Older git ignores it, so the agent
/// environment cannot turn off a repository's programs there.
const config_environment_major: u32 = 2;
const config_environment_minor: u32 = 31;

/// `--no-lazy-fetch` arrived in git 2.45.
const no_lazy_fetch_major: u32 = 2;
const no_lazy_fetch_minor: u32 = 45;

const max_probe_output: usize = 4096;

pub const Refusal = enum {
    git_missing,
    git_version_unknown,
    git_too_old,
    repo_config_unavailable,
    /// `-c` splits at the first `=`, so such a driver cannot be blanked.
    unsupported_filter_name,
    /// The repository marks a remote as a promisor, so git would fetch a
    /// missing object from it on demand, and this git cannot be told not to.
    lazy_fetch_unsupported,
    /// git would use a different repository than the one whose config fx read.
    repository_mismatch,
};

pub const Ready = struct {
    /// Static path from `trustedExecutable`.
    executable: []const u8,
    /// Filter drivers defined by repository-scope config.
    filter_names: []const []const u8,
    /// This git takes `--no-lazy-fetch`, so a promisor remote cannot start
    /// its transport program for a missing object.
    no_lazy_fetch: bool,
    /// Whether this git reads the overrides `appendAgentEnvironment` adds.
    honors_config_environment: bool = true,
};

pub const Prepared = union(enum) {
    ready: Ready,
    refused: Refusal,
};

pub const Subcommand = enum { status, diff, log, show, branch, rev_parse };

/// Decides whether git may run in the absolute directory `cwd`: reads the
/// repository's config as data, checks the trusted git's version once per
/// process, and confirms git resolves the same repository fx read. All memory
/// belongs to `arena`.
pub fn prepare(arena: Allocator, cwd: []const u8) Allocator.Error!Prepared {
    const programs = indexer.repoPrograms(arena, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => return refuse(.repo_config_unavailable, cwd),
    };
    for (programs.names) |name| {
        if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null) return refuse(.unsupported_filter_name, cwd);
    }
    const executable = trustedExecutable() orelse return refuse(.git_missing, cwd);
    const probe = try versionCheck(arena, executable);
    switch (probe.check) {
        .supported => {},
        .too_old => return refuse(.git_too_old, cwd),
        .unknown => return refuse(.git_version_unknown, cwd),
    }
    if (lazyFetchRefusal(programs.promisor, probe.no_lazy_fetch)) |reason| return refuse(reason, cwd);
    const ready: Ready = .{
        .executable = executable,
        .filter_names = programs.names,
        .no_lazy_fetch = probe.no_lazy_fetch,
        .honors_config_environment = probe.honors_config_environment,
    };
    if (!try sameRepository(arena, ready, cwd, programs.git_dir)) return refuse(.repository_mismatch, cwd);
    return .{ .ready = ready };
}

/// A promisor remote makes git fetch a missing object on demand, and that
/// fetch starts the transport program the remote's config names. Git 2.45
/// added `--no-lazy-fetch`, which turns that off; older git cannot be told,
/// so fx refuses instead of running an inspection that could start a program.
fn lazyFetchRefusal(promisor: bool, no_lazy_fetch: bool) ?Refusal {
    if (!promisor or no_lazy_fetch) return null;
    return .lazy_fetch_unsupported;
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
        // A repository's own `format.pretty` can name a signature placeholder
        // such as `%G?`, which makes git run the verifier its config names.
        // Naming the format here, before any argument a caller appends, keeps
        // that config out while an allowed `--oneline` still wins.
        .log => &.{ "log", "--pretty=medium", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .show => &.{ "show", "--pretty=medium", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .branch => &.{"branch"},
        .rev_parse => &.{"rev-parse"},
    });
}

fn appendPrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: Ready) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
    });
    if (ready.no_lazy_fetch) try argv.append(arena, "--no-lazy-fetch");
    try argv.appendSlice(arena, &.{
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
            try argv.append(arena, try arena.print("filter.{s}.{s}=", .{ name, program }));
        }
    }
}

/// The child environment for every safe git call: a fixed PATH and locale, no
/// prompts, pagers, optional locks or lazy fetches, and only the variables that
/// locate the user's own git config. Nothing else from fx's environment, such
/// as `GIT_DIR` or `GIT_CONFIG_PARAMETERS`, reaches git.
pub fn environment(alloc: Allocator) Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("LC_ALL", "C");
    try map.put("LANG", "C");
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_NO_LAZY_FETCH", "1");
    try map.put("GIT_PAGER", "cat");
    try map.put("PAGER", "cat");
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM" }) |key| {
        if (io_mod.getenv(key)) |value| try map.put(key, value);
    }
    return map;
}

/// Most `GIT_CONFIG_COUNT` entries an inherited environment may already hold
/// before fx appends its own after them.
const max_inherited_config_entries: usize = 256;

/// Adds settings to an agent command's environment so every git process the
/// command starts, however it is invoked, runs no program a repository's own
/// config names for reading. git reads `GIT_CONFIG_COUNT` entries at
/// command-line scope, above every config file. Settings that never change a
/// result apply everywhere: fsmonitor off, no signature display, `cat` as the
/// pager and no optional locks. The rest apply only to programs the
/// repository's own config names, read as data from the repository
/// containing the absolute `cwd`: its filter drivers are blanked, its
/// textconv drivers become `cat`, which shows the file's own content, its
/// external diff programs and signature verifiers are emptied, so git reports
/// that it cannot run them instead of starting them, and its own
/// `format.pretty` gives way to `medium`, so no format it names asks for a
/// signature check. A promisor repository whose config names a transport
/// program gets `GIT_NO_LAZY_FETCH`, which git 2.45 and later read, so a
/// missing object cannot start that program. Hooks stay on, so a commit runs
/// the same hooks it ran before. When the repository's config cannot be read
/// only the fixed settings apply. `arena` holds temporary strings and
/// `env_map` copies what it stores.
pub fn appendAgentEnvironment(
    arena: Allocator,
    env_map: *std.process.Environ.Map,
    cwd: []const u8,
) Allocator.Error!void {
    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    for ([_][2][]const u8{
        .{ "core.fsmonitor", "false" },
        .{ "log.showSignature", "false" },
    }) |setting| {
        try keys.append(arena, setting[0]);
        try values.append(arena, setting[1]);
    }
    var no_lazy_fetch = false;
    if (indexer.repoPrograms(arena, cwd)) |drivers| {
        for (drivers.names) |name| {
            for ([_][]const u8{ "clean", "smudge", "process" }) |program| {
                try keys.append(arena, try arena.print("filter.{s}.{s}", .{ name, program }));
                try values.append(arena, "");
            }
        }
        for (drivers.textconv_driver_names) |name| {
            try keys.append(arena, try arena.print("diff.{s}.textconv", .{name}));
            try values.append(arena, "cat");
        }
        for (drivers.diff_command_driver_names) |name| {
            try keys.append(arena, try arena.print("diff.{s}.command", .{name}));
            try values.append(arena, "");
        }
        if (drivers.external_diff) {
            try keys.append(arena, "diff.external");
            try values.append(arena, "");
        }
        for (drivers.gpg_program_keys) |key| {
            try keys.append(arena, key);
            try values.append(arena, "");
        }
        if (drivers.format_pretty) {
            try keys.append(arena, "format.pretty");
            try values.append(arena, "medium");
        }
        no_lazy_fetch = drivers.promisor and drivers.transport_program;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => debug_trace.logf(
            "core",
            "agent git environment kept fixed settings only reason=repo_config_unavailable cwd={s}",
            .{cwd},
        ),
    }

    var index: usize = 0;
    if (env_map.get("GIT_CONFIG_COUNT")) |inherited| {
        index = std.fmt.parseInt(usize, inherited, 10) catch 0;
        if (index > max_inherited_config_entries) index = 0;
    }
    for (keys.items, values.items) |key, value| {
        try env_map.put(try arena.print("GIT_CONFIG_KEY_{d}", .{index}), key);
        try env_map.put(try arena.print("GIT_CONFIG_VALUE_{d}", .{index}), value);
        index += 1;
    }
    try env_map.put("GIT_CONFIG_COUNT", try arena.print("{d}", .{index}));
    // The pager variable outranks `core.pager` and `pager.<command>`, and
    // turning off optional locks keeps `git status` from rewriting the index,
    // which would start a `post-index-change` hook.
    try env_map.put("GIT_PAGER", "cat");
    try env_map.put("GIT_OPTIONAL_LOCKS", "0");
    if (no_lazy_fetch) try env_map.put("GIT_NO_LAZY_FETCH", "1");
}

test "agent environment turns off repository programs and keeps inherited entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".git/config",
        .data = "[filter \"evil\"]\n\tclean = run-me\n[diff \"evil\"]\n\ttextconv = run-me\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(std.testing.io, ".git/objects");
    try tmp.dir.createDirPath(std.testing.io, ".git/refs");
    const cwd = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("GIT_CONFIG_COUNT", "1");
    try env_map.put("GIT_CONFIG_KEY_0", "user.name");
    try env_map.put("GIT_CONFIG_VALUE_0", "kept");
    try appendAgentEnvironment(arena, &env_map, cwd);

    try std.testing.expectEqualStrings("user.name", env_map.get("GIT_CONFIG_KEY_0").?);
    try std.testing.expectEqualStrings("core.fsmonitor", env_map.get("GIT_CONFIG_KEY_1").?);
    try std.testing.expectEqualStrings("false", env_map.get("GIT_CONFIG_VALUE_1").?);
    const count = try std.fmt.parseInt(usize, env_map.get("GIT_CONFIG_COUNT").?, 10);
    var saw_filter = false;
    var saw_textconv = false;
    for (1..count) |index| {
        const key = env_map.get(try arena.print("GIT_CONFIG_KEY_{d}", .{index})).?;
        const value = env_map.get(try arena.print("GIT_CONFIG_VALUE_{d}", .{index})).?;
        if (std.mem.eql(u8, key, "filter.evil.clean")) saw_filter = true;
        if (std.mem.eql(u8, key, "diff.evil.textconv")) {
            saw_textconv = true;
            try std.testing.expectEqualStrings("cat", value);
        }
        // An empty `diff.external` makes every `git diff` fail, so it is set
        // only when the repository names one.
        try std.testing.expect(!std.mem.eql(u8, key, "diff.external"));
        try std.testing.expect(!std.mem.startsWith(u8, key, "core.hooksPath"));
    }
    try std.testing.expect(saw_filter and saw_textconv);
    try std.testing.expectEqualStrings("cat", env_map.get("GIT_PAGER").?);
    try std.testing.expect(env_map.get("GIT_NO_LAZY_FETCH") == null);
}

/// The value the agent environment gives `key`, or null when it sets none.
fn agentOverride(arena: Allocator, env_map: *const std.process.Environ.Map, key: []const u8) !?[]const u8 {
    const count = try std.fmt.parseInt(usize, env_map.get("GIT_CONFIG_COUNT").?, 10);
    for (0..count) |index| {
        const name = env_map.get(try arena.print("GIT_CONFIG_KEY_{d}", .{index})).?;
        if (std.mem.eql(u8, name, key)) return env_map.get(try arena.print("GIT_CONFIG_VALUE_{d}", .{index})).?;
    }
    return null;
}

test "agent environment stops lazy fetch, signature checks and a repository format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "named", "plain" }) |repo| {
        try tmp.dir.createDirPath(std.testing.io, try arena.print("{s}/.git/objects", .{repo}));
        try tmp.dir.createDirPath(std.testing.io, try arena.print("{s}/.git/refs", .{repo}));
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = try arena.print("{s}/.git/HEAD", .{repo}),
            .data = "ref: refs/heads/main\n",
        });
    }
    // A promisor remote whose config names its transport program, a format
    // that asks for a signature check, and the verifier that check would run.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "named/.git/config",
        .data = "[remote \"origin\"]\n\tpromisor = true\n\tuploadpack = run-me\n" ++
            "[format]\n\tpretty = %G?\n[gpg]\n\tprogram = run-me\n[gpg \"ssh\"]\n\tprogram = run-me\n",
    });
    // A partial clone as git writes it names no program, so lazy fetch stays.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain/.git/config",
        .data = "[remote \"origin\"]\n\turl = https://example.com/repo.git\n\tpromisor = true\n\tpartialclonefilter = blob:none\n",
    });

    var named = std.process.Environ.Map.init(std.testing.allocator);
    defer named.deinit();
    try appendAgentEnvironment(arena, &named, try io_mod.dirRealpathAlloc(arena, tmp.dir, "named"));
    try std.testing.expectEqualStrings("1", named.get("GIT_NO_LAZY_FETCH").?);
    try std.testing.expectEqualStrings("medium", (try agentOverride(arena, &named, "format.pretty")).?);
    try std.testing.expectEqualStrings("", (try agentOverride(arena, &named, "gpg.program")).?);
    try std.testing.expectEqualStrings("", (try agentOverride(arena, &named, "gpg.ssh.program")).?);

    var plain = std.process.Environ.Map.init(std.testing.allocator);
    defer plain.deinit();
    try appendAgentEnvironment(arena, &plain, try io_mod.dirRealpathAlloc(arena, tmp.dir, "plain"));
    try std.testing.expect(plain.get("GIT_NO_LAZY_FETCH") == null);
    try std.testing.expect((try agentOverride(arena, &plain, "format.pretty")) == null);
    try std.testing.expect((try agentOverride(arena, &plain, "gpg.program")) == null);
}

/// The first git found at a fixed system location. git from PATH is never
/// used, because PATH can include directories a repository controls.
fn trustedExecutable() ?[]const u8 {
    const candidates = switch (builtin.target.os.tag) {
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

/// What the trusted git's version reported, and whether it takes the options
/// fx needs beyond its minimum.
pub const Probe = struct {
    check: VersionCheck,
    /// Git 2.45 added the global `--no-lazy-fetch`, which keeps a promisor
    /// remote from starting its transport program for a missing object.
    no_lazy_fetch: bool = false,
    /// Git 2.31 added `GIT_CONFIG_COUNT`, which carries the overrides
    /// `appendAgentEnvironment` adds.
    honors_config_environment: bool = false,
};

var version_lock: std.Io.Mutex = .init;
var cached_probe: ?struct { executable: []const u8, probe: Probe } = null;

/// Runs `git --version` once per executable and process. A failed probe is not
/// cached, so a transient spawn failure does not disable git for the session.
fn versionCheck(arena: Allocator, executable: []const u8) Allocator.Error!Probe {
    const io = io_mod.getIo();
    version_lock.lockUncancelable(io);
    defer version_lock.unlock(io);
    if (cached_probe) |cached| {
        if (std.mem.eql(u8, cached.executable, executable)) return cached.probe;
    }
    const output = try runCaptured(arena, &.{ executable, "--version" }, "/") orelse return .{ .check = .unknown };
    const probe = classifyVersion(output);
    cached_probe = .{ .executable = executable, .probe = probe };
    return probe;
}

fn classifyVersion(output: []const u8) Probe {
    const prefix = "git version ";
    if (!std.mem.startsWith(u8, output, prefix)) return .{ .check = .unknown };
    var parts = std.mem.splitScalar(u8, output[prefix.len..], '.');
    const major = leadingNumber(parts.next() orelse "") orelse return .{ .check = .unknown };
    const minor = leadingNumber(parts.next() orelse "") orelse return .{ .check = .unknown };
    return .{
        .check = if (atLeastVersion(major, minor, minimum_major, minimum_minor)) .supported else .too_old,
        .no_lazy_fetch = atLeastVersion(major, minor, no_lazy_fetch_major, no_lazy_fetch_minor),
        .honors_config_environment = atLeastVersion(major, minor, config_environment_major, config_environment_minor),
    };
}

fn atLeastVersion(major: u32, minor: u32, want_major: u32, want_minor: u32) bool {
    if (major != want_major) return major > want_major;
    return minor >= want_minor;
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

test "git version check requires 2.25 and reads vendor suffixes" {
    const cases = [_]struct { output: []const u8, check: VersionCheck, no_lazy_fetch: bool, environment: bool }{
        .{ .output = "git version 2.50.1 (Apple Git-155)\n", .check = .supported, .no_lazy_fetch = true, .environment = true },
        .{ .output = "git version 2.45.0\n", .check = .supported, .no_lazy_fetch = true, .environment = true },
        .{ .output = "git version 2.44.4\n", .check = .supported, .no_lazy_fetch = false, .environment = true },
        .{ .output = "git version 2.36.0\n", .check = .supported, .no_lazy_fetch = false, .environment = true },
        .{ .output = "git version 2.34.1\n", .check = .supported, .no_lazy_fetch = false, .environment = true },
        .{ .output = "git version 2.31.0\n", .check = .supported, .no_lazy_fetch = false, .environment = true },
        .{ .output = "git version 2.30.9\n", .check = .supported, .no_lazy_fetch = false, .environment = false },
        .{ .output = "git version 2.25.0\n", .check = .supported, .no_lazy_fetch = false, .environment = false },
        .{ .output = "git version 2.39.3.windows.1\n", .check = .supported, .no_lazy_fetch = false, .environment = true },
        .{ .output = "git version 3.0.0\n", .check = .supported, .no_lazy_fetch = true, .environment = true },
        .{ .output = "git version 2.24.4\n", .check = .too_old, .no_lazy_fetch = false, .environment = false },
        .{ .output = "git version 1.9.5\n", .check = .too_old, .no_lazy_fetch = false, .environment = false },
        .{ .output = "hub version 2.14\n", .check = .unknown, .no_lazy_fetch = false, .environment = false },
        .{ .output = "git version x.y\n", .check = .unknown, .no_lazy_fetch = false, .environment = false },
    };
    for (cases) |case| {
        const probe = classifyVersion(case.output);
        try std.testing.expectEqual(case.check, probe.check);
        try std.testing.expectEqual(case.no_lazy_fetch, probe.no_lazy_fetch);
        try std.testing.expectEqual(case.environment, probe.honors_config_environment);
    }
}

test "a promisor remote is refused until this git can stop lazy fetching" {
    // Git 2.45 takes `--no-lazy-fetch`, which stops a promisor remote from
    // starting its transport program for a missing object. Older git cannot,
    // so the command does not run at all.
    try std.testing.expectEqual(
        Refusal.lazy_fetch_unsupported,
        lazyFetchRefusal(true, false).?,
    );
    try std.testing.expectEqual(@as(?Refusal, null), lazyFetchRefusal(true, true));
    try std.testing.expectEqual(@as(?Refusal, null), lazyFetchRefusal(false, false));
}

test "safe git argv turns off repository programs for every subcommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{ "lfs", "evil.x" }, .no_lazy_fetch = true };
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .diff);
    const expected = [_][]const u8{
        "/usr/bin/git",            "--no-pager",               "--no-optional-locks",
        "--no-lazy-fetch",         "-c",                       "core.fsmonitor=false",
        "-c",                      "core.hooksPath=/dev/null", "-c",
        "log.showSignature=false", "-c",                       "filter.lfs.clean=",
        "-c",                      "filter.lfs.smudge=",       "-c",
        "filter.lfs.process=",     "-c",                       "filter.evil.x.clean=",
        "-c",                      "filter.evil.x.smudge=",    "-c",
        "filter.evil.x.process=",  "diff",                     "--no-ext-diff",
        "--no-textconv",           "--ignore-submodules=all",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "safe git argv leaves out the lazy fetch option an older git lacks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{}, .no_lazy_fetch = false };
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .log);
    var found_log = false;
    for (argv.items) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--no-lazy-fetch"));
        if (std.mem.eql(u8, arg, "log")) found_log = true;
    }
    try std.testing.expect(found_log);
}

test "safe git names a format for log and show" {
    // A repository's `format.pretty` can request signature verification, which
    // runs the verifier its config names, so the format is always named here.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{}, .no_lazy_fetch = true };
    for ([_]Subcommand{ .log, .show }) |subcommand| {
        var argv: std.ArrayList([]const u8) = .empty;
        try appendCommand(arena, &argv, ready, subcommand);
        var format_index: ?usize = null;
        var subcommand_index: ?usize = null;
        for (argv.items, 0..) |arg, index| {
            if (std.mem.eql(u8, arg, "--pretty=medium")) format_index = index;
            if (std.mem.eql(u8, arg, "log") or std.mem.eql(u8, arg, "show")) subcommand_index = index;
        }
        try std.testing.expectEqual(subcommand_index.? + 1, format_index.?);
    }
}

test "safe git environment keeps only fixed values and user config locations" {
    var env = try environment(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_OPTIONAL_LOCKS").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("1", env.get("GIT_NO_LAZY_FETCH").?);
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
        if ((try versionCheck(arena, git)).check != .supported) return error.SkipZigTest;
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const self: SentinelRepo = .{
            .arena = arena,
            .git = git,
            .root = root,
            .repo = try std.Io.Dir.path.join(arena, &.{ root, "repo" }),
            .home = try std.Io.Dir.path.join(arena, &.{ root, "home" }),
            .log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
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
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    fn writeExecutable(self: SentinelRepo, absolute: []const u8) !void {
        const script = try self.arena.print("#!/bin/sh\necho ran >> '{s}'\ncat\n", .{self.log});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    }

    /// A transport program, which records its run and exits instead of
    /// speaking the upload-pack protocol, so a lazy fetch attempt is
    /// observable and does not wait on stdin.
    fn writeTransport(self: SentinelRepo, absolute: []const u8) !void {
        const script = try self.arena.print("#!/bin/sh\necho ran >> '{s}'\nexit 0\n", .{self.log});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    }

    fn write(self: SentinelRepo, sub_path: []const u8, data: []const u8) !void {
        const absolute = try self.path(sub_path);
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
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
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".gitconfig" }));
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

// A partial clone fetches a missing object from its promisor remote on
// demand, and that fetch starts the transport program the remote's config
// names. `git show` reaches for a blob, so it is the shortest route: fx must
// either turn lazy fetching off or refuse the command.
test "safe git never lazy fetches a missing object from a promisor remote" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena, tmp.dir);
    const transport = try repo.path("transport.sh");
    try repo.writeTransport(transport);

    const blob = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD:a.txt" });
    const blob_path = try std.Io.Dir.path.join(arena, &.{ repo.repo, ".git/objects", blob[0..2], blob[2..] });
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, blob_path);

    try repo.plain(repo.repo, &.{ "config", "remote.origin.url", "file:///fixture-origin" });
    try repo.plain(repo.repo, &.{ "config", "remote.origin.promisor", "true" });
    try repo.plain(repo.repo, &.{ "config", "remote.origin.partialclonefilter", "blob:none" });
    try repo.plain(repo.repo, &.{ "config", "remote.origin.uploadpack", transport });
    try repo.plain(repo.repo, &.{ "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" });

    switch (try prepare(arena, repo.repo)) {
        .ready => |ready| {
            try std.testing.expect(ready.no_lazy_fetch);
            _ = try repo.run(repo.repo, try repo.helperArgv(repo.repo, .show, &.{"HEAD:a.txt"}), .{ .safe = null });
            try std.testing.expectEqual(@as(usize, 0), try repo.runs());
        },
        // A git older than 2.45 cannot be told to stop, so fx must refuse.
        .refused => |reason| try std.testing.expectEqual(Refusal.lazy_fetch_unsupported, reason),
    }

    // The control proves the route is live: plain git starts the program.
    _ = try repo.run(repo.repo, try repo.plainArgv(&.{ "show", "HEAD:a.txt" }), .plain);
    try std.testing.expect(try repo.runs() > 0);
}

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
    const object = try repo.arena.print(
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
        .data = try repo.arena.print("[filter \"trusted\"]\n\tclean = {s}\n", .{repo.sentinel}),
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

    // An inner repository whose `HEAD` is a symlink into `refs/`. git uses
    // it; fx's discovery rejects it and reads the outer repository, so the two
    // disagree and safe git refuses instead of running with the wrong config.
    const linked = try repo.path("repo/linked");
    try repo.plain(repo.repo, &.{ "init", "-q", "--template=", linked });
    const linked_head = try repo.path("repo/linked/.git/HEAD");
    try std.Io.Dir.cwd().deleteFile(std.testing.io, linked_head);
    try std.Io.Dir.cwd().symLink(std.testing.io, "refs/heads/main", linked_head, .{ .is_directory = false });
    try std.testing.expectEqual(Refusal.repository_mismatch, (try prepare(repo.arena, linked)).refused);

    try repo.plain(repo.repo, &.{ "config", "filter.a=b.clean", repo.sentinel });
    try std.testing.expectEqual(Refusal.unsupported_filter_name, (try prepare(repo.arena, repo.repo)).refused);
}
