//! The sandbox policy for one fx home: the parsed `~/.fx/sandbox/config.json`,
//! the provider that runs placed commands, and the launch for each placed
//! command. An app loads one `Policy` and calls `place` for each shell
//! command. This file does I/O, so it is native only: a WASM build must not
//! reference it.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const builtin = @import("builtin");
const config = @import("config.zig");
const decide = @import("decide.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const launch = @import("launch.zig");
const remote_slot = @import("remote_slot.zig");
const runner_main = @import("runner_main.zig");
const self_exe = @import("../shared/self_exe.zig");
const sha256 = @import("sha256.zig");
const setup_host = @import("setup_host.zig");
const vercel = @import("vercel/vercel.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

/// The largest config file fx reads.
const max_config_bytes: usize = config.max_bytes;

/// Why `place` refuses. The login error is E5; its text is the one remote setup
/// gives (`login_missing_text`).
pub const PlaceError = error{
    SandboxConfigInvalid,
    SandboxProviderUnavailable,
    SandboxLoginMissing,
    /// The workspace folder cannot be resolved (E16).
    SandboxWorkspaceUnresolved,
    /// The keyed state folder cannot be created (E17).
    SandboxStateUnavailable,
    /// A built-in placement has no launch, so remote setup did not prepare the runner (E18).
    SandboxRunnerNotPrepared,
    RemoteRunnerUnavailable,
    OutOfMemory,
};

/// Why a placement failed, as text for the model. `place` fills in `path` and
/// `detail` for E16 and E17. A caller gives `reason` when the provider has no
/// reason of its own. Each field is empty when it does not apply.
pub const Refusal = struct {
    /// The workspace folder (E16), or the keyed state folder (E17).
    path: []const u8 = "",
    /// The operating-system error, by name.
    detail: []const u8 = "",
    /// Why the provider cannot be used, when the provider itself gives none.
    reason: []const u8 = "",
};

/// Where one shell command runs. `launch` is set for a sandbox placement.
pub const Placed = struct {
    placement: command_environment.Placement,
    profile: ?[]const u8 = null,
    launch: ?*const launch.Launch = null,
    reason: ?decide.Reason = null,
    /// A built-in remote run whose provider remote setup has not prepared yet.
    /// It has no launch, so a run starts only after setup (`ensureRemote`).
    needs_setup: bool = false,
};

const Loaded = union(enum) {
    /// No config file: every command runs on this machine.
    missing,
    valid: config.Config,
    /// The file could not be read or parsed. The text says why. Every shell
    /// command is refused.
    invalid: []const u8,
};

/// The built-in provider and what a run needs from it. It sits behind a pointer,
/// as the remote slot does, so `provisionBuiltin` can prepare it through a
/// `*const Policy`. `arena` owns its strings, and they are allocated only under
/// `mutex`.
const Provider = struct {
    arena: std.heap.ArenaAllocator,
    mutex: std.Io.Mutex = .init,
    state: State = .not_prepared,
    /// The provider program and its first arguments.
    argv: []const []const u8 = &.{},
    /// Why the provider is unavailable. Empty when it is ready.
    reason: []const u8 = "",
    state_dir: []const u8 = "",

    const State = enum {
        /// No config folder was present when the policy loaded. Remote setup
        /// makes the folder and the provider.
        not_prepared,
        ready,
        unavailable,
    };

    const Snapshot = struct {
        state: State,
        argv: []const []const u8,
        state_dir: []const u8,
        reason: []const u8,
    };

    /// A copy of the state, read under the lock.
    fn snapshot(self: *Provider) Snapshot {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .state = self.state,
            .argv = self.argv,
            .state_dir = self.state_dir,
            .reason = self.reason,
        };
    }
};

pub const Policy = struct {
    gpa: Allocator,
    /// Owns every string in this policy.
    arena: std.heap.ArenaAllocator,
    loaded: Loaded = .missing,
    /// The fingerprint of the config keys other than `remote`, as this process
    /// loaded them. Setup's locked write compares against it (spec U9). A missing
    /// file has the fingerprint of an empty object.
    config_fingerprint: config.Fingerprint = config.absent_fingerprint,
    /// The process's remote state: the destination, the setup in flight, and
    /// the decline marks (U3, U4, U10). A pointer, so a shared `*const Policy`
    /// still reaches the state, which is locked inside. Freed by `destroy`.
    remote: *remote_slot.Slot,
    /// Remote setup (spec R4 to R5, U1 to U11), behind a pointer for the same
    /// reason as `remote`. Freed by `destroy`.
    remote_host: *setup_host.Host,
    /// The built-in provider, behind a pointer so `provisionBuiltin` can
    /// prepare it through a `*const Policy`. Freed by `destroy`.
    provider: *Provider,
    /// The fx home and PATH this policy loaded with, to prepare the provider later.
    fx_home: []const u8 = "",
    path_env: ?[]const u8 = null,
    profiles: []const launch.Profile = &.{},

    pub fn destroy(self: *Policy) void {
        const gpa = self.gpa;
        gpa.destroy(self.remote_host);
        self.remote.destroy();
        self.provider.arena.deinit();
        gpa.destroy(self.provider);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Where a shell command runs in `workspace_root`. A command whose config
    /// target is local needs no launch. A sandbox target needs a ready
    /// provider. The launch lives in `arena`.
    pub fn place(
        self: *const Policy,
        arena: Allocator,
        workspace_root: []const u8,
        command: []const u8,
        runner: ?decide.Request,
        refusal: ?*Refusal,
    ) PlaceError!Placed {
        const cfg: config.Config = switch (self.loaded) {
            .missing => .{},
            .valid => |value| value,
            .invalid => return error.SandboxConfigInvalid,
        };
        const decision = decide.decide(&cfg, workspace_root, command, runner);
        const target = decision.target;
        const reason: ?decide.Reason = if (decision.reason) |value| switch (value) {
            .floor => |folder| .{ .floor = try arena.dupe(u8, folder) },
            .rule => |pattern| .{ .rule = try arena.dupe(u8, pattern) },
        } else null;
        if (target.placement == .local) return .{ .placement = .local, .reason = reason };
        const provider = self.provider.snapshot();
        switch (provider.state) {
            .ready => {},
            .unavailable => return error.SandboxProviderUnavailable,
            .not_prepared => {
                // Only the built-in runner's provider is made by remote setup (R1, U10).
                if (cfg.provider == null) return .{
                    .placement = target.placement,
                    .profile = target.profile,
                    .reason = reason,
                    .needs_setup = true,
                };
                return error.SandboxProviderUnavailable;
            },
        }
        const run = try arena.create(launch.Launch);
        run.* = .{
            .provider = provider.argv,
            .provider_args = cfg.provider_args,
            .state_dir = provider.state_dir,
            .workspace_root = workspace_root,
            .env = cfg.env,
            .profiles = self.profiles,
            .grace_ms = cfg.grace_ms,
        };
        if (cfg.provider == null) {
            switch (try self.builtinRun(arena, workspace_root, &cfg, provider.state_dir, refusal)) {
                .ready => |ready| {
                    run.state_dir = ready.state_dir;
                    run.builtin = ready.builtin;
                },
                .no_destination => return .{
                    .placement = target.placement,
                    .profile = target.profile,
                    .reason = reason,
                    .needs_setup = true,
                },
            }
        }
        return .{ .placement = target.placement, .profile = target.profile, .launch = run, .reason = reason };
    }

    /// The text to show when `place` refuses: the config
    /// problem, or why the provider is not ready. Empty when there is none.
    pub fn message(self: *const Policy) []const u8 {
        return switch (self.loaded) {
            .invalid => |text| text,
            .missing, .valid => self.provider.snapshot().reason,
        };
    }

    const BuiltinRun = union(enum) {
        ready: struct { state_dir: []const u8, builtin: launch.Builtin },
        no_destination,
    };

    /// What a built-in run adds to the provider: its keyed state folder (spec L5)
    /// and its L1 values. The destination comes from the in-memory slot (spec
    /// R113), not from the config file, which the run never reads again.
    fn builtinRun(
        self: *const Policy,
        arena: Allocator,
        workspace_root: []const u8,
        cfg: *const config.Config,
        state_root: []const u8,
        refusal: ?*Refusal,
    ) PlaceError!BuiltinRun {
        const destination = (try self.remote.currentDestination(arena)) orelse return .no_destination;
        const root = io_mod.realpathAlloc(arena, workspace_root) catch |err| return workspaceRefusal(refusal, workspace_root, err);
        const key = try repoKey(arena, destination.user_id, root);
        try ensureStateDir(arena, state_root, key, refusal);
        // The digest of the login that the user check passed for this destination (R5, V1). The login
        // is not read again here: a login that changed after the check must reach the runner unchanged,
        // so the runner refuses it. Before this process has passed the check, the run needs setup: remote
        // setup runs the check before the run starts, and placement is asked again then.
        const checked = self.remote.checkedHashFor(destination.user_id) orelse return .no_destination;
        const token_sha256 = try arena.dupe(u8, &std.fmt.bytesToHex(checked, .lower));
        return .{ .ready = .{
            .state_dir = try std.Io.Dir.path.join(arena, &.{ state_root, key }),
            .builtin = .{
                .team_id = destination.team_id,
                .team_slug = destination.team_slug,
                .project_id = destination.project_id,
                .project_name = destination.project_name,
                .user_id = destination.user_id,
                .token_sha256 = token_sha256,
                .include = config.includeFor(cfg, workspace_root),
                .bring_back = config.bringBackFor(cfg, workspace_root),
                .vcpus = cfg.vcpus,
            },
        } };
    }

    /// Whether `command` needs a Vercel destination on the built-in runner: a
    /// remote run or an isolated one, both of which need the team and project
    /// (A1). A third-party provider never runs setup.
    pub fn needsVercelDestination(
        self: *const Policy,
        workspace_root: []const u8,
        command: []const u8,
        runner: ?decide.Request,
    ) bool {
        const cfg: config.Config = switch (self.loaded) {
            .missing => .{},
            .valid => |value| value,
            .invalid => return false,
        };
        if (cfg.provider != null) return false;
        return decide.decide(&cfg, workspace_root, command, runner).target.placement != .local;
    }

    /// Runs remote setup for one call on the built-in runner (spec R4 to R5,
    /// U1 to U11). A ready setup prepares the built-in provider, so placement can
    /// launch the run.
    pub fn ensureRemote(self: *const Policy, call: setup_host.Call) Allocator.Error!setup_host.Result {
        const result = try setup_host.ensureReady(self.remote_host, call);
        if (std.meta.activeTag(result) == .ready) try self.provisionBuiltin();
        return result;
    }

    /// Prepares the built-in provider once remote setup has written the config
    /// (U10). It runs at most once: a provider that is ready or unavailable is
    /// left as it is. A failure leaves the provider unavailable, with its reason,
    /// so placement never asks for setup again.
    pub fn provisionBuiltin(self: *const Policy) Allocator.Error!void {
        const io = io_mod.getIo();
        self.provider.mutex.lockUncancelable(io);
        defer self.provider.mutex.unlock(io);
        if (self.provider.state != .not_prepared) return;
        var home_dir = io_mod.openDirAbsoluteNoFollow(self.fx_home, .{ .iterate = true }) catch |err| {
            return notReady(self.provider, "could not open {s}: {s}", .{ self.fx_home, @errorName(err) });
        };
        defer home_dir.close(io);
        var home_root: io_mod.VerifiedDir = .{ .dir = home_dir };
        var sandbox = (io_mod.openRealDirIfPresent(&home_root, "sandbox") catch |err| {
            return notReady(self.provider, "could not open {s}/sandbox: {s}", .{ self.fx_home, @errorName(err) });
        }) orelse return notReady(self.provider, "the sandbox folder is missing", .{});
        defer sandbox.close();
        try prepare(self.provider, self.fx_home, &sandbox, self.path_env, .{});
    }
};

/// Loads the policy for `fx_home`. `home` expands `~/` in the config. A bare
/// provider name is looked up on `path_env`. The caller owns the result and
/// releases it with `destroy`. A problem with the config or the provider is
/// kept in the policy, so only memory failures make this return an error.
pub fn load(alloc: Allocator, fx_home: []const u8, home: []const u8, path_env: ?[]const u8) Allocator.Error!*Policy {
    const self = try alloc.create(Policy);
    errdefer alloc.destroy(self);
    self.* = .{
        .gpa = alloc,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .remote = undefined,
        .remote_host = undefined,
        .provider = undefined,
    };
    errdefer self.arena.deinit();
    const owned = self.arena.allocator();
    self.fx_home = try owned.dupe(u8, fx_home);
    self.path_env = if (path_env) |value| try owned.dupe(u8, value) else null;
    self.remote = try remote_slot.Slot.create(alloc);
    errdefer self.remote.destroy();
    self.provider = try alloc.create(Provider);
    errdefer alloc.destroy(self.provider);
    self.provider.* = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer self.provider.arena.deinit();
    try read(self, fx_home, home, path_env);
    self.remote_host = try alloc.create(setup_host.Host);
    errdefer alloc.destroy(self.remote_host);
    self.remote_host.* = try hostFor(self, home);
    return self;
}

/// The remote setup host of `self`: its slot, the fx home and the config
/// fingerprint that this load read, and the login sources this process has. The
/// strings it keeps live in the policy's arena. It holds no token: the token is
/// read from the environment for each check.
fn hostFor(self: *Policy, home: []const u8) Allocator.Error!setup_host.Host {
    const owned = self.arena.allocator();
    const home_copy = try owned.dupe(u8, home);
    const base = vercel.resolveBaseUrl(io_mod.getenv(vercel.override_env));
    return .{
        .alloc = self.gpa,
        .slot = self.remote,
        .fx_home = self.fx_home,
        .home = home_copy,
        .loaded = self.config_fingerprint,
        .base = .{ .kind = base.kind, .origin = try owned.dupe(u8, base.origin) },
        .env = .{
            .vercel_token = try ownedEnv(owned, "VERCEL_TOKEN"),
            .home = home_copy,
            .xdg_data_home = try ownedEnv(owned, "XDG_DATA_HOME"),
        },
        .os = builtin.target.os.tag,
        .files = vercel.disk,
        .trace = setup_host.debug_trace_sink,
        .user_check = .{ .slot = self.remote },
    };
}

fn ownedEnv(arena: Allocator, key: []const u8) Allocator.Error!?[]const u8 {
    const value = io_mod.getenv(key) orelse return null;
    return try arena.dupe(u8, value);
}

/// Loads the policy for this process's fx home, for an app that runs tools. A
/// missing config is a valid policy that places nothing. The load starts no
/// process: no sweep runs at startup (spec I1). When the load runs out of memory,
/// this logs it and returns null, so the sandbox switch has no effect.
pub fn loadForProcess(alloc: Allocator) ?*Policy {
    const home = io_mod.homeDir() orelse "";
    const fx_home = (profile_paths.activeRoot(alloc, io_mod.homeDir()) catch |err| return loadFailed(err)) orelse {
        debug_trace.logf("sandbox", "event=policy_skipped reason=no_fx_home effect=sandbox_execution_ignored", .{});
        return null;
    };
    defer alloc.free(fx_home);
    const real_home = realFxHome(alloc, fx_home) catch |err| return loadFailed(err);
    defer alloc.free(real_home);
    return load(alloc, real_home, home, io_mod.getenv("PATH")) catch |err| return loadFailed(err);
}

/// The fx home with its links resolved. The no-follow opens below refuse a link in any
/// part of the path, and a home can reach fx through one: macOS reaches $TMPDIR through
/// /var, a link to /private/var. A home that does not exist stays as given, so its
/// "not found" answer does not change.
fn realFxHome(alloc: Allocator, fx_home: []const u8) Allocator.Error![]u8 {
    return io_mod.realpathAlloc(alloc, fx_home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return alloc.dupe(u8, fx_home),
    };
}

fn loadFailed(err: anyerror) ?*Policy {
    debug_trace.logf("sandbox", "event=policy_load_failed err={s} effect=sandbox_execution_ignored", .{@errorName(err)});
    return null;
}

/// Reads the config. When it is valid, it also prepares the folders and the
/// provider.
fn read(self: *Policy, fx_home: []const u8, home: []const u8, path_env: ?[]const u8) Allocator.Error!void {
    const arena = self.arena.allocator();
    const zio = io_mod.getIo();
    var home_dir = io_mod.openDirAbsoluteNoFollow(fx_home, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return invalid(self, arena, "could not open {s}: {s}", .{ fx_home, @errorName(err) });
    };
    defer home_dir.close(zio);
    var home_root: io_mod.VerifiedDir = .{ .dir = home_dir };
    var sandbox = (io_mod.openRealDirIfPresent(&home_root, "sandbox") catch |err| {
        return invalid(self, arena, "could not open {s}/sandbox: {s}", .{ fx_home, @errorName(err) });
    }) orelse return;
    defer sandbox.close();

    const config_path = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "config.json" });
    var file = io_mod.openExistingReadOnlyRegularFile(sandbox.dir, "config.json", .follow) catch |err| {
        if (err == error.FileNotFound) return;
        return invalid(self, arena, "could not open {s}: {s}", .{ config_path, @errorName(err) });
    };
    defer file.close(zio);
    const text = io_mod.readFileToEnd(arena, &file, max_config_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return invalid(self, arena, "could not read {s} (at most 256 KiB): {s}", .{ config_path, @errorName(err) });
    };

    var diagnostic: config.Diagnostic = .{};
    const parsed = config.parse(arena, text, home, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return invalid(self, arena, "{s}: {s}", .{ config_path, diagnostic.message });
    };
    self.config_fingerprint = config.fingerprintWithoutRemote(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSandboxConfig => return invalid(self, arena, "{s}: the keys could not be read", .{config_path}),
    };
    self.loaded = .{ .valid = parsed };
    if (parsed.remote) |remote| try self.remote.setDestination(.{
        .team_id = remote.team_id,
        .team_slug = remote.team_slug,
        .project_id = remote.project_id,
        .project_name = remote.project_name,
        .user_id = remote.user_id,
    });
    const profiles = try arena.alloc(launch.Profile, parsed.profiles.len);
    for (parsed.profiles, 0..) |profile, index| profiles[index] = .{ .name = profile.name, .args = profile.args };
    self.profiles = profiles;
    try prepare(self.provider, fx_home, &sandbox, path_env, parsed);
}

/// Creates the state folder and finds the provider. A problem here leaves the
/// provider unavailable, with its reason. It never fails the load. The caller
/// holds the provider's lock once the policy is shared.
fn prepare(
    provider: *Provider,
    fx_home: []const u8,
    sandbox: *io_mod.VerifiedDir,
    path_env: ?[]const u8,
    cfg: config.Config,
) Allocator.Error!void {
    const arena = provider.arena.allocator();
    const state_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });
    provider.state_dir = state_dir;

    var state = io_mod.openOrCreateVerifiedPrivateDir(sandbox, "state") catch |err| {
        return notReady(provider, "could not create {s}: {s}", .{ state_dir, @errorName(err) });
    };
    state.close();

    const argv = providerArgv(arena, cfg.provider) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return notReady(provider, "could not find the fx program: {s}", .{@errorName(err)});
    };
    provider.argv = argv;
    if (try programProblem(arena, path_env, argv[0])) |problem| {
        provider.state = .unavailable;
        provider.reason = problem;
        return;
    }
    provider.state = .ready;
}

/// The provider's argv: the configured one, or the built-in runner (spec L1),
/// which is this fx binary with the `__fx_runner__` subcommand. No script is
/// written.
fn providerArgv(arena: Allocator, configured: ?[]const []const u8) ![]const []const u8 {
    if (configured) |argv| return argv;
    const argv = try arena.alloc([]const u8, 2);
    // The launch runs under `/bin/sh -c`, so `/proc/self/exe` would name that shell.
    // The peer path names fx itself, as a process other than fx must launch it.
    argv[0] = try self_exe.pathForPeerReexec(arena);
    argv[1] = runner_main.subcommand;
    return argv;
}

/// Creates the keyed state folder under `state_root` (spec L5). The parent is
/// opened with `iterate = true`, as the runner opens it. Any failure leaves the
/// run unavailable.
fn ensureStateDir(arena: Allocator, state_root: []const u8, key: []const u8, refusal: ?*Refusal) PlaceError!void {
    const io = io_mod.getIo();
    var parent = io_mod.openDirAbsoluteNoFollow(state_root, .{ .iterate = true }) catch |err| {
        return stateRefusal(arena, state_root, key, refusal, err);
    };
    defer parent.close(io);
    var keyed = io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, key) catch |err| {
        return stateRefusal(arena, state_root, key, refusal, err);
    };
    keyed.close();
}

/// Records E16 for a workspace folder that cannot be resolved, and returns its error.
fn workspaceRefusal(refusal: ?*Refusal, workspace_root: []const u8, err: anyerror) PlaceError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    setRefusal(refusal, .{ .path = workspace_root, .detail = @errorName(err) });
    return error.SandboxWorkspaceUnresolved;
}

/// Records E17 for a keyed state folder that cannot be opened or created, and returns its error.
fn stateRefusal(arena: Allocator, state_root: []const u8, key: []const u8, refusal: ?*Refusal, err: anyerror) PlaceError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const path = try std.Io.Dir.path.join(arena, &.{ state_root, key });
    setRefusal(refusal, .{ .path = path, .detail = @errorName(err) });
    return error.SandboxStateUnavailable;
}

fn setRefusal(refusal: ?*Refusal, value: Refusal) void {
    if (refusal) |target| target.* = value;
}

/// The keyed folder name (spec L5): the first 16 hex digits of the SHA-256 of the
/// user id, a newline, and the canonical workspace root.
fn repoKey(arena: Allocator, user_id: []const u8, root: []const u8) Allocator.Error![]const u8 {
    const digest = sha256.hexDigest(try arena.print("{s}\n{s}", .{ user_id, root }));
    return arena.dupe(u8, digest[0..16]);
}

/// Null when `program` names a runnable file. Otherwise, the reason it does
/// not. An absolute path must be an executable file. A bare name is looked up
/// on `path_env`.
fn programProblem(arena: Allocator, path_env: ?[]const u8, program: []const u8) Allocator.Error!?[]const u8 {
    if (std.Io.Dir.path.isAbsolute(program)) {
        if (isExecutableFile(program)) return null;
        return try arena.print("the provider {s} is not an executable file", .{program});
    }
    var dirs = std.mem.splitScalar(u8, path_env orelse "", ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.Io.Dir.path.join(arena, &.{ dir, program });
        if (isExecutableFile(candidate)) return null;
    }
    return try arena.print("the provider {s} is not on PATH", .{program});
}

fn isExecutableFile(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return stat.kind == .file and stat.permissions.toMode() & 0o111 != 0;
}

fn invalid(self: *Policy, arena: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!void {
    self.loaded = .{ .invalid = try arena.print(format, args) };
}

fn notReady(provider: *Provider, comptime format: []const u8, args: anytype) Allocator.Error!void {
    provider.state = .unavailable;
    provider.reason = try provider.arena.allocator().print(format, args);
}

const testing = std.testing;

/// Creates `fxhome` under `dir` and returns its absolute path.
fn makeFxHome(alloc: Allocator, dir: std.Io.Dir) ![]u8 {
    try dir.createDirPath(testing.io, "fxhome");
    return io_mod.dirRealpathAlloc(alloc, dir, "fxhome");
}

fn writeConfigFile(dir: std.Io.Dir, text: []const u8) !void {
    try dir.createDirPath(testing.io, "fxhome/sandbox");
    try dir.writeFile(testing.io, .{ .sub_path = "fxhome/sandbox/config.json", .data = text });
}

/// A real workspace folder beside the fx home, because `place` resolves its root.
fn makeRepo(alloc: Allocator, dir: std.Io.Dir) ![]u8 {
    try dir.createDirPath(testing.io, "repo");
    return io_mod.dirRealpathAlloc(alloc, dir, "repo");
}

test "a missing config makes every command local" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    try tmp.dir.createDirPath(testing.io, "fxhome");
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const placed = try policy.place(arena, "/Users/example/repo", "zig build test", null, null);
    try testing.expectEqual(command_environment.Placement.local, placed.placement);
    try testing.expect(placed.launch == null);
    try testing.expectEqualStrings("", policy.message());
}

test "the policy keeps the fingerprint of the config keys other than remote that it loaded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"grace_ms\":2000,\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}}");

    const loaded = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer loaded.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const expected = try config.fingerprintWithoutRemote(arena_state.allocator(), "{\"grace_ms\":2000}");
    try testing.expectEqualSlices(u8, &expected, &loaded.config_fingerprint);
}

test "a missing config has the fingerprint of an empty object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    try tmp.dir.createDirPath(testing.io, "fxhome");
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);

    const loaded = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer loaded.destroy();
    try testing.expectEqualSlices(u8, &config.absent_fingerprint, &loaded.config_fingerprint);
}

test "the policy's remote slot starts from the config's remote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"grace_ms\":2000,\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}}");

    const loaded = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer loaded.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const destination = (try loaded.remote.currentDestination(arena_state.allocator())).?;
    try testing.expectEqualStrings("team_1", destination.team_id);
    try testing.expectEqualStrings("repo", destination.project_name);
}

test "a policy whose config has no remote has no destination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);

    const loaded = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer loaded.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expect((try loaded.remote.currentDestination(arena_state.allocator())) == null);
}

test "an invalid config refuses every command with its diagnostic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"ls\",\"runner\":\"sandbox\"}]}");

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.SandboxConfigInvalid, policy.place(arena, "/Users/example/repo", "ls", null, null));
    try testing.expectError(error.SandboxConfigInvalid, policy.place(arena, "/Users/example/repo", "zig build test", null, null));
    try testing.expect(std.mem.find(u8, policy.message(), "rules[0].runner: unknown runner \"sandbox\"") != null);
}

test "the built-in provider is this fx binary's runner, and no script is written" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"zig*\",\"runner\":\"remote\"}]}");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expectEqual(Provider.State.ready, policy.provider.state);
    try testing.expect(std.Io.Dir.path.isAbsolute(policy.provider.argv[0]));
    try testing.expectEqualStrings(runner_main.subcommand, policy.provider.argv[1]);
    const providers = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "providers" });
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, providers, .{}));
}

test "an fx home reached through a symlink loads a valid policy, and its state path has no link" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    try tmp.dir.createDirPath(testing.io, "real/.fx/sandbox");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real/.fx/sandbox/config.json", .data = "{\"rules\":[{\"command\":\"zig*\",\"runner\":\"remote\"}]}" });
    try tmp.dir.symLink(testing.io, "real", "home-link", .{ .is_directory = true });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const link_home = try std.Io.Dir.path.join(alloc, &.{ root, "home-link" });
    defer alloc.free(link_home);
    const real_state = try std.Io.Dir.path.join(alloc, &.{ root, "real", ".fx", "sandbox", "state" });
    defer alloc.free(real_state);

    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("HOME", link_home);
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();

    const policy = loadForProcess(alloc) orelse return error.TestUnexpectedNull;
    defer policy.destroy();
    try testing.expectEqual(Provider.State.ready, policy.provider.state);
    try testing.expectEqualStrings(real_state, policy.provider.state_dir);
    var state = try io_mod.openDirAbsoluteNoFollow(policy.provider.state_dir, .{});
    state.close(io_mod.getIo());
}

test "a missing provider makes a placed command unavailable and leaves a local one placed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try arena.print(
        "{{\"provider\":[\"{s}/no-such-cli\"],\"rules\":[{{\"command\":\"zig*\",\"runner\":\"remote\"}}]}}",
        .{fx_home},
    );
    try writeConfigFile(tmp.dir, text);
    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();

    try testing.expectError(error.SandboxProviderUnavailable, policy.place(arena, "/Users/example/repo", "zig build test", null, null));
    try testing.expect(std.mem.find(u8, policy.message(), "is not an executable file") != null);
    const local = try policy.place(arena, "/Users/example/repo", "ls", null, null);
    try testing.expectEqual(command_environment.Placement.local, local.placement);
    try testing.expect(local.launch == null);
}

test "a bare provider name is looked up on the path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(testing.io, "fxhome/bin");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "fxhome/bin/fx-sandbox-cli",
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const bin_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "bin" });
    try writeConfigFile(tmp.dir, "{\"provider\":[\"fx-sandbox-cli\"],\"rules\":[{\"command\":\"zig*\",\"runner\":\"remote\"}]}");

    const found = try load(alloc, fx_home, "/Users/example", bin_dir);
    defer found.destroy();
    try testing.expectEqual(Provider.State.ready, found.provider.state);

    const missing = try load(alloc, fx_home, "/Users/example", "/nonexistent");
    defer missing.destroy();
    try testing.expectEqual(Provider.State.unavailable, missing.provider.state);
    try testing.expect(std.mem.find(u8, missing.message(), "is not on PATH") != null);
}

test "a placed command's launch carries the root, state folder, env, profile arguments, and grace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "fxhome/fake-cli",
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const provider_path = try std.Io.Dir.path.join(arena, &.{ fx_home, "fake-cli" });
    const text = try arena.print(
        "{{\"provider\":[\"{s}\"],\"provider_args\":[\"--scope\",\"team\"],\"grace_ms\":2500," ++
            "\"env\":[\"CI_TOKEN_1\"],\"profiles\":{{\"media\":[\"--gpu\"]}}," ++
            "\"rules\":[{{\"command\":\"convert *\",\"runner\":\"isolated:media\"}}," ++
            "{{\"command\":\"zig*\",\"runner\":\"remote\"}}]}}",
        .{provider_path},
    );
    try writeConfigFile(tmp.dir, text);

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    const state_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });

    const isolated = try policy.place(arena, "/Users/example/repo", "convert a.png b.jpg", null, null);
    try testing.expectEqual(command_environment.Placement.isolated, isolated.placement);
    try testing.expectEqualStrings("media", isolated.profile.?);
    const run = isolated.launch.?;
    try testing.expectEqual(@as(usize, 1), run.provider.len);
    try testing.expectEqualStrings(provider_path, run.provider[0]);
    try testing.expectEqual(@as(usize, 2), run.provider_args.len);
    try testing.expectEqualStrings("--scope", run.provider_args[0]);
    try testing.expectEqualStrings("team", run.provider_args[1]);
    try testing.expectEqualStrings(state_dir, run.state_dir);
    try testing.expectEqualStrings("/Users/example/repo", run.workspace_root);
    try testing.expectEqual(@as(usize, 1), run.env.len);
    try testing.expectEqualStrings("CI_TOKEN_1", run.env[0]);
    try testing.expectEqualStrings("media", run.profiles[0].name);
    try testing.expectEqualStrings("--gpu", run.profiles[0].args[0]);
    try testing.expectEqual(@as(u32, 2500), run.grace_ms);

    // The state folder is created private.
    const state_stat = try std.Io.Dir.cwd().statFile(testing.io, state_dir, .{});
    const state_mode: u32 = state_stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(u32, 0o700), state_mode);

    const remote = try policy.place(arena, "/Users/example/repo", "zig build test", null, null);
    try testing.expectEqual(command_environment.Placement.remote, remote.placement);
    try testing.expect(remote.profile == null);
    try testing.expect(remote.launch != null);
}

const remote_config_text = "{\"grace_ms\":2000,\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}}";

test "a built-in remote run with no config needs setup, and places no launch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    const placed = try policy.place(arena_state.allocator(), "/Users/example/work", "zig build test", .remote, null);
    try testing.expectEqual(command_environment.Placement.remote, placed.placement);
    try testing.expect(placed.needs_setup);
    try testing.expect(placed.launch == null);
}

test "a local run with no config places locally, and needs no setup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    const placed = try policy.place(arena_state.allocator(), "/Users/example/work", "ls", .local, null);
    try testing.expectEqual(command_environment.Placement.local, placed.placement);
    try testing.expect(!placed.needs_setup);
}

test "remote setup prepares the built-in provider once the config exists, and placement then launches the runner" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const repo = try makeRepo(alloc, tmp.dir);
    defer alloc.free(repo);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expectEqual(Provider.State.not_prepared, policy.provider.state);
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.provisionBuiltin();
    try testing.expectEqual(Provider.State.ready, policy.provider.state);

    // Setup writes the destination into the slot. The login comes from the setup host's env.
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    policy.remote_host.env = .{ .vercel_token = "fx-policy-token", .home = policy.remote_host.home };
    // The user check passed for this login during setup, so the slot holds its digest and user (R5).
    var checked: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fx-policy-token", &checked, .{});
    try policy.remote_host.user_check.store(alloc, checked, "usr_1");

    const placed = try policy.place(arena, repo, "zig build test", .remote, null);
    try testing.expect(!placed.needs_setup);
    const run = placed.launch orelse return error.TestExpectedLaunch;
    try testing.expectEqualStrings(runner_main.subcommand, run.provider[1]);
    const built = run.builtin orelse return error.TestExpectedBuiltinRun;
    try testing.expectEqualStrings("team_1", built.team_id);
    try testing.expectEqualStrings("usr_1", built.user_id);
    try testing.expectEqualStrings(&sha256.hexDigest("fx-policy-token"), built.token_sha256);

    // The state folder is keyed (spec L5): 16 hex digits under the shared state folder.
    const state_root = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });
    try testing.expectEqualStrings(state_root, std.Io.Dir.path.dirname(run.state_dir).?);
    try testing.expectEqual(@as(usize, 16), std.Io.Dir.path.basename(run.state_dir).len);
    const state_stat = try std.Io.Dir.cwd().statFile(testing.io, run.state_dir, .{});
    try testing.expectEqual(@as(u32, 0o700), state_stat.permissions.toMode() & 0o777);
}

test "a built-in run with no checked login needs setup and places no launch" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const repo = try makeRepo(alloc, tmp.dir);
    defer alloc.free(repo);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.provisionBuiltin();
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    // No token in the env, and no login file under the home folder. No check has passed for this
    // destination, so the run needs setup and places no launch. Remote setup then finds no login (E5).
    policy.remote_host.env = .{ .home = policy.remote_host.home };
    const placed = try policy.place(arena_state.allocator(), repo, "zig build test", .remote, null);
    try testing.expect(placed.needs_setup);
    try testing.expect(placed.launch == null);
}

test "placement passes the digest that the user check passed, not a fresh read of the login" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.provisionBuiltin();
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    // The user check passed for the login "fx-policy-token". The login has then changed to another token.
    var checked: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fx-policy-token", &checked, .{});
    try policy.remote_host.user_check.store(alloc, checked, "usr_1");
    policy.remote_host.env = .{ .vercel_token = "fx-policy-changed", .home = policy.remote_host.home };

    const repo = try makeRepo(alloc, tmp.dir);
    defer alloc.free(repo);
    const placed = try policy.place(arena_state.allocator(), repo, "zig build test", .remote, null);
    const run = placed.launch orelse return error.TestExpectedLaunch;
    const builtin_run = run.builtin orelse return error.TestExpectedBuiltin;
    const expected = sha256.hexDigest("fx-policy-token");
    try testing.expectEqualStrings(&expected, builtin_run.token_sha256);
}

test "a built-in provider that cannot be prepared after setup is unavailable, and never asks for setup again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    // No sandbox folder exists, so preparing the provider fails.
    try policy.provisionBuiltin();
    try testing.expectEqual(Provider.State.unavailable, policy.provider.state);
    try testing.expect(std.mem.find(u8, policy.provider.reason, "the sandbox folder is missing") != null);
    try testing.expectError(
        error.SandboxProviderUnavailable,
        policy.place(arena_state.allocator(), "/Users/example/work", "zig build test", .remote, null),
    );
}

test "a third-party provider never runs remote setup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"provider\":[\"/usr/bin/true\"],\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"}]}");

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expect(!policy.needsVercelDestination("/Users/example/work", "zig build test", null));
}

test "only a built-in remote run needs remote setup, and a local run never does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"}]}");

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expect(policy.needsVercelDestination("/Users/example/work", "zig build test", null));
    try testing.expect(!policy.needsVercelDestination("/Users/example/work", "ls", null));
}

test "a built-in run in a workspace folder that does not exist refuses with E16, naming the folder and the error" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.provisionBuiltin();
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    var refusal: Refusal = .{};
    try testing.expectError(
        error.SandboxWorkspaceUnresolved,
        policy.place(arena, "/Users/example/missing", "zig build test", .remote, &refusal),
    );
    try testing.expectEqualStrings("/Users/example/missing", refusal.path);
    try testing.expectEqualStrings("FileNotFound", refusal.detail);
}

test "a built-in run whose keyed state folder cannot be created refuses with E17, naming the folder and the error" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const repo = try makeRepo(alloc, tmp.dir);
    defer alloc.free(repo);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.provisionBuiltin();
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    // A regular file where the keyed folder must go makes its creation fail.
    const root = try io_mod.realpathAlloc(arena, repo);
    const key = try repoKey(arena, "usr_1", root);
    const blocker = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state", key });
    const blocker_in_home = try arena.print("fxhome/sandbox/state/{s}", .{key});
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = blocker_in_home, .data = "not a folder" });
    var refusal: Refusal = .{};
    try testing.expectError(
        error.SandboxStateUnavailable,
        policy.place(arena, repo, "zig build test", .remote, &refusal),
    );
    try testing.expectEqualStrings(blocker, refusal.path);
    try testing.expect(refusal.detail.len > 0);
}

test "an isolated run on the built-in runner needs remote setup too, and a third-party provider never does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"isolated\"}]}");
    const on_builtin = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer on_builtin.destroy();
    try testing.expect(on_builtin.needsVercelDestination("/Users/example/work", "zig build test", null));
    try testing.expect(!on_builtin.needsVercelDestination("/Users/example/work", "ls", null));
    try writeConfigFile(tmp.dir, "{\"provider\":[\"/usr/bin/true\"],\"rules\":[{\"command\":\"zig build*\",\"runner\":\"isolated\"}]}");
    const third_party = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer third_party.destroy();
    try testing.expect(!third_party.needsVercelDestination("/Users/example/work", "zig build test", null));
}

test "the remote setup host shares the policy's slot and the fingerprint this load read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, remote_config_text);

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expect(policy.remote_host.slot == policy.remote);
    try testing.expectEqualSlices(u8, &policy.config_fingerprint, &policy.remote_host.loaded);
    try testing.expectEqualStrings(fx_home, policy.remote_host.fx_home);
}

test "ensureRemote is ready from the config's remote with no request, and then prepares the built-in provider" {
    try self_exe.requireInstalledForTest();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try writeConfigFile(tmp.dir, remote_config_text);
    try policy.remote.setDestination(.{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
    });
    // The login's user is already cached for this token, so no request is made.
    const token = "fx-policy-token";
    policy.remote_host.env = .{ .vercel_token = token, .home = policy.remote_host.home };
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    try policy.remote_host.user_check.store(alloc, digest, "usr_1");

    var cancel = std.atomic.Value(bool).init(false);
    const result = try policy.ensureRemote(setup_host.callFor(arena, true, "session-a", 5, null, &cancel));
    try testing.expectEqual(std.meta.Tag(setup_host.Result).ready, std.meta.activeTag(result));
    try testing.expectEqual(Provider.State.ready, policy.provider.state);
    const repo = try makeRepo(alloc, tmp.dir);
    defer alloc.free(repo);
    const placed = try policy.place(arena, repo, "zig build test", .remote, null);
    try testing.expect(placed.launch != null);
}
