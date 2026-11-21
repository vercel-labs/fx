//! The sandbox policy for one fx home: the parsed `~/.fx/sandbox/config.json`,
//! the provider that runs placed commands, and the launch for each placed
//! command. An app loads one `Policy` and calls `place` for each shell
//! command. This file does I/O, so it is native only: a WASM build must not
//! reference it.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const builtin = @import("builtin");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const launch = @import("launch.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

/// The largest config file fx reads.
const max_config_bytes: usize = 256 * 1024;

/// How long one sweep may run before std ends it.
const sweep_timeout_seconds: i64 = 60;

/// The most output one sweep keeps from each stream.
const sweep_output_limit: usize = 64 * 1024;

/// The built-in provider script. It is written to the sandbox folder under a
/// name that carries the hash of its bytes.
const builtin_provider = @embedFile("providers/vercel.sh");

pub const PlaceError = error{ SandboxConfigInvalid, SandboxProviderUnavailable, OutOfMemory };

/// Where one shell command runs. `launch` is set for a sandbox placement.
pub const Placed = struct {
    placement: command_environment.Placement,
    profile: ?[]const u8 = null,
    launch: ?*const launch.Launch = null,
};

const Loaded = union(enum) {
    /// No config file: every command runs on this machine.
    missing,
    valid: config.Config,
    /// The file could not be read or parsed. The text says why. Every shell
    /// command is refused.
    invalid: []const u8,
};

pub const Policy = struct {
    gpa: Allocator,
    /// Owns every string in this policy.
    arena: std.heap.ArenaAllocator,
    loaded: Loaded = .missing,
    /// The provider program and its first arguments.
    provider_argv: []const []const u8 = &.{},
    provider_ready: bool = false,
    /// Why the provider is not ready. Empty when it is ready.
    provider_reason: []const u8 = "",
    state_dir: []const u8 = "",
    profiles: []const launch.Profile = &.{},
    /// The argv for the provider's `sweep` subcommand, or null unless the
    /// provider is ready.
    sweep: ?[]const []const u8 = null,

    pub fn destroy(self: *Policy) void {
        const gpa = self.gpa;
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
    ) PlaceError!Placed {
        const cfg: config.Config = switch (self.loaded) {
            .missing => .{},
            .valid => |value| value,
            .invalid => return error.SandboxConfigInvalid,
        };
        const target = config.decide(&cfg, workspace_root, command);
        if (target.placement == .local) return .{ .placement = .local };
        if (!self.provider_ready) return error.SandboxProviderUnavailable;
        const run = try arena.create(launch.Launch);
        run.* = .{
            .provider = self.provider_argv,
            .provider_args = cfg.provider_args,
            .state_dir = self.state_dir,
            .workspace_root = workspace_root,
            .env = cfg.env,
            .profiles = self.profiles,
            .grace_ms = cfg.grace_ms,
        };
        return .{ .placement = target.placement, .profile = target.profile, .launch = run };
    }

    /// The provider's `sweep` argv, or null when the config is invalid or the
    /// provider is not ready. Nothing is spawned here.
    pub fn sweepArgv(self: *const Policy) ?[]const []const u8 {
        return self.sweep;
    }

    /// Runs the provider's sweep once, in a detached thread, so startup never
    /// waits for it. The thread owns a copy of the argv. Under test and on WASM
    /// this does nothing.
    pub fn startSweep(self: *const Policy) void {
        if (comptime !(builtin.is_test or host_target.is_wasm)) spawnSweep(self);
    }

    /// The text to show when `place` or `sweepArgv` refuses: the config
    /// problem, or why the provider is not ready. Empty when there is none.
    pub fn message(self: *const Policy) []const u8 {
        return switch (self.loaded) {
            .invalid => |text| text,
            .missing, .valid => self.provider_reason,
        };
    }
};

/// Loads the policy for `fx_home`. `home` expands `~/` in the config. A bare
/// provider name is looked up on `path_env`. The caller owns the result and
/// releases it with `destroy`. A problem with the config or the provider is
/// kept in the policy, so only memory failures make this return an error.
pub fn load(alloc: Allocator, fx_home: []const u8, home: []const u8, path_env: ?[]const u8) Allocator.Error!*Policy {
    const self = try alloc.create(Policy);
    errdefer alloc.destroy(self);
    self.* = .{ .gpa = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer self.arena.deinit();
    try read(self, fx_home, home, path_env);
    return self;
}

/// Loads the policy for this process's fx home, for an app that runs tools. A
/// missing config is a valid policy that places nothing. After a load, the
/// provider's sweep starts in the background. When the load runs out of memory,
/// this logs it and returns null, so the sandbox switch has no effect.
pub fn loadForProcess(alloc: Allocator) ?*Policy {
    const home = io_mod.homeDir() orelse "";
    const fx_home = (profile_paths.activeRoot(alloc, io_mod.homeDir()) catch |err| return loadFailed(err)) orelse {
        debug_trace.logf("sandbox", "event=policy_skipped reason=no_fx_home effect=sandbox_execution_ignored", .{});
        return null;
    };
    defer alloc.free(fx_home);
    const self = load(alloc, fx_home, home, io_mod.getenv("PATH")) catch |err| return loadFailed(err);
    self.startSweep();
    return self;
}

fn loadFailed(err: anyerror) ?*Policy {
    debug_trace.logf("sandbox", "event=policy_load_failed err={s} effect=sandbox_execution_ignored", .{@errorName(err)});
    return null;
}

fn spawnSweep(self: *const Policy) void {
    const argv = self.sweepArgv() orelse return;
    const gpa = std.heap.c_allocator;
    const owned = copyArgv(gpa, argv) catch |err| {
        debug_trace.logf("sandbox", "event=sweep_skipped reason=out_of_memory err={s}", .{@errorName(err)});
        return;
    };
    const thread = std.Thread.spawn(.{}, runSweep, .{owned}) catch |err| {
        freeArgv(gpa, owned);
        debug_trace.logf("sandbox", "event=sweep_skipped reason=spawn err={s}", .{@errorName(err)});
        return;
    };
    thread.detach();
}

/// Runs one sweep and logs how it ended. The thread frees `argv`.
fn runSweep(argv: []const []const u8) void {
    const gpa = std.heap.c_allocator;
    defer freeArgv(gpa, argv);
    const result = std.process.run(gpa, io_mod.getIo(), .{
        .argv = argv,
        .stdout_limit = .limited(sweep_output_limit),
        .stderr_limit = .limited(sweep_output_limit),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(sweep_timeout_seconds), .clock = .awake } },
    }) catch |err| {
        debug_trace.logf("sandbox", "event=sweep_failed err={s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| debug_trace.logf("sandbox", "event=sweep_done exit={d} stderr={s}", .{ code, result.stderr }),
        else => debug_trace.logf("sandbox", "event=sweep_done term={any} stderr={s}", .{ result.term, result.stderr }),
    }
}

/// A copy of `argv` whose strings the caller owns.
fn copyArgv(gpa: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
    const copy = try gpa.alloc([]const u8, argv.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |arg| gpa.free(arg);
        gpa.free(copy);
    }
    for (argv, copy) |arg, *slot| {
        slot.* = try gpa.dupe(u8, arg);
        done += 1;
    }
    return copy;
}

fn freeArgv(gpa: Allocator, argv: []const []const u8) void {
    for (argv) |arg| gpa.free(arg);
    gpa.free(argv);
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
    self.loaded = .{ .valid = parsed };
    try prepare(self, fx_home, &sandbox, path_env, parsed);
}

/// Creates the state folder, finds the provider, and builds the sweep argv. A
/// problem here leaves the provider not ready, with its reason. It never fails
/// the load.
fn prepare(
    self: *Policy,
    fx_home: []const u8,
    sandbox: *io_mod.VerifiedDir,
    path_env: ?[]const u8,
    cfg: config.Config,
) Allocator.Error!void {
    const arena = self.arena.allocator();
    const state_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });
    self.state_dir = state_dir;

    const profiles = try arena.alloc(launch.Profile, cfg.profiles.len);
    for (cfg.profiles, 0..) |profile, index| profiles[index] = .{ .name = profile.name, .args = profile.args };
    self.profiles = profiles;

    var state = io_mod.openOrCreateVerifiedPrivateDir(sandbox, "state") catch |err| {
        return notReady(self, arena, "could not create {s}: {s}", .{ state_dir, @errorName(err) });
    };
    state.close();

    const argv = providerArgv(arena, sandbox, fx_home, cfg.provider) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return notReady(self, arena, "could not prepare the built-in provider: {s}", .{@errorName(err)});
    };
    self.provider_argv = argv;
    if (try programProblem(arena, path_env, argv[0])) |problem| {
        self.provider_reason = problem;
        return;
    }

    self.provider_ready = true;
    var sweep: std.ArrayList([]const u8) = .empty;
    try sweep.appendSlice(arena, argv);
    try sweep.appendSlice(arena, cfg.provider_args);
    try sweep.appendSlice(arena, &.{ "sweep", "--state", state_dir });
    self.sweep = try sweep.toOwnedSlice(arena);
}

/// The provider's argv: the configured one, or the built-in script written
/// into the sandbox's providers folder.
fn providerArgv(
    arena: Allocator,
    sandbox: *io_mod.VerifiedDir,
    fx_home: []const u8,
    configured: ?[]const []const u8,
) ![]const []const u8 {
    if (configured) |argv| return argv;
    var providers = try io_mod.openOrCreateVerifiedPrivateDir(sandbox, "providers");
    defer providers.close();
    const name = try ensureBuiltinProvider(arena, &providers);
    const argv = try arena.alloc([]const u8, 1);
    argv[0] = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "providers", name });
    return argv;
}

/// Writes the built-in provider into `providers` under its hash name, unless a
/// file of that name exists. An existing file is kept as it is. The bytes go to
/// a temporary file created with mode 0700, which is then renamed into place.
fn ensureBuiltinProvider(arena: Allocator, providers: *io_mod.VerifiedDir) ![]const u8 {
    const zio = io_mod.getIo();
    const name = try builtinProviderName(arena);
    if (providers.dir.statFile(zio, name, .{ .follow_symlinks = false })) |_| {
        return name;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const temp = try arena.print(".{s}.{d}.tmp", .{ name, io_mod.nanoTimestamp() });
    errdefer providers.dir.deleteFile(zio, temp) catch {};
    {
        var file = try providers.dir.createFile(zio, temp, .{
            .exclusive = true,
            .permissions = .fromMode(0o700),
        });
        defer file.close(zio);
        try file.writeStreamingAll(zio, builtin_provider);
        try file.sync(zio);
    }
    try std.Io.Dir.rename(providers.dir, temp, providers.dir, name, zio);
    return name;
}

/// The file name of the built-in provider: `vercel-` and the first 12 hex
/// digits of the SHA-256 of its bytes.
fn builtinProviderName(arena: Allocator) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(builtin_provider, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.print("vercel-{s}.sh", .{hex[0..12]});
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

fn notReady(self: *Policy, arena: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!void {
    self.provider_ready = false;
    self.provider_reason = try arena.print(format, args);
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

    const placed = try policy.place(arena, "/Users/example/repo", "zig build test");
    try testing.expectEqual(command_environment.Placement.local, placed.placement);
    try testing.expect(placed.launch == null);
    try testing.expectEqualStrings("", policy.message());
    try testing.expect(policy.sweepArgv() == null);
}

test "an invalid config refuses every command with its diagnostic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"ls\",\"placement\":\"sandbox\"}]}");

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.SandboxConfigInvalid, policy.place(arena, "/Users/example/repo", "ls"));
    try testing.expectError(error.SandboxConfigInvalid, policy.place(arena, "/Users/example/repo", "zig build test"));
    try testing.expect(std.mem.find(u8, policy.message(), "rules[0].placement: unknown placement \"sandbox\"") != null);
    try testing.expect(policy.sweepArgv() == null);
}

test "the built-in provider is written once with mode 0700 and matches the embedded script" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"zig*\",\"placement\":\"workspace\"}]}");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expect(policy.provider_ready);
    const name = try builtinProviderName(arena);
    const provider_path = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "providers", name });
    try testing.expectEqualStrings(provider_path, policy.provider_argv[0]);

    const stat = try std.Io.Dir.cwd().statFile(testing.io, provider_path, .{});
    const mode: u32 = stat.permissions.toMode() & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, provider_path, arena, .limited(max_config_bytes));
    try testing.expectEqualStrings(builtin_provider, bytes);

    // A second load keeps the file. A rewrite would replace its inode.
    const second = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer second.destroy();
    const again = try std.Io.Dir.cwd().statFile(testing.io, provider_path, .{});
    try testing.expectEqual(stat.inode, again.inode);
}

test "an existing built-in provider file is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try writeConfigFile(tmp.dir, "{\"rules\":[{\"command\":\"zig*\",\"placement\":\"workspace\"}]}");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = try builtinProviderName(arena);
    const planted = try arena.print("fxhome/sandbox/providers/{s}", .{name});
    try tmp.dir.createDirPath(testing.io, "fxhome/sandbox/providers");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = planted,
        .data = "planted by hand\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    try testing.expect(policy.provider_ready);
    const planted_path = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "providers", name });
    try testing.expectEqualStrings(planted_path, policy.provider_argv[0]);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, planted_path, arena, .limited(max_config_bytes));
    try testing.expectEqualStrings("planted by hand\n", bytes);
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
        "{{\"provider\":[\"{s}/no-such-cli\"],\"rules\":[{{\"command\":\"zig*\",\"placement\":\"workspace\"}}]}}",
        .{fx_home},
    );
    try writeConfigFile(tmp.dir, text);
    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();

    try testing.expectError(error.SandboxProviderUnavailable, policy.place(arena, "/Users/example/repo", "zig build test"));
    try testing.expect(std.mem.find(u8, policy.message(), "is not an executable file") != null);
    const local = try policy.place(arena, "/Users/example/repo", "ls");
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
    try writeConfigFile(tmp.dir, "{\"provider\":[\"fx-sandbox-cli\"],\"rules\":[{\"command\":\"zig*\",\"placement\":\"workspace\"}]}");

    const found = try load(alloc, fx_home, "/Users/example", bin_dir);
    defer found.destroy();
    try testing.expect(found.provider_ready);

    const missing = try load(alloc, fx_home, "/Users/example", "/nonexistent");
    defer missing.destroy();
    try testing.expect(!missing.provider_ready);
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
            "\"rules\":[{{\"command\":\"convert *\",\"placement\":\"isolated:media\"}}," ++
            "{{\"command\":\"zig*\",\"placement\":\"workspace\"}}]}}",
        .{provider_path},
    );
    try writeConfigFile(tmp.dir, text);

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    const state_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });

    const isolated = try policy.place(arena, "/Users/example/repo", "convert a.png b.jpg");
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

    const workspace = try policy.place(arena, "/Users/example/repo", "zig build test");
    try testing.expectEqual(command_environment.Placement.workspace, workspace.placement);
    try testing.expect(workspace.profile == null);
    try testing.expect(workspace.launch != null);
}

test "the sweep argv names the provider, its arguments, and the state folder" {
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
        "{{\"provider\":[\"{s}\"],\"provider_args\":[\"--scope\",\"team\"],\"rules\":[{{\"command\":\"zig*\",\"placement\":\"workspace\"}}]}}",
        .{provider_path},
    );
    try writeConfigFile(tmp.dir, text);

    const policy = try load(alloc, fx_home, "/Users/example", "/usr/bin:/bin");
    defer policy.destroy();
    const state_dir = try std.Io.Dir.path.join(arena, &.{ fx_home, "sandbox", "state" });
    const sweep = policy.sweepArgv() orelse return error.TestExpectedSweepArgv;
    try testing.expectEqual(@as(usize, 6), sweep.len);
    try testing.expectEqualStrings(provider_path, sweep[0]);
    try testing.expectEqualStrings("--scope", sweep[1]);
    try testing.expectEqualStrings("team", sweep[2]);
    try testing.expectEqualStrings("sweep", sweep[3]);
    try testing.expectEqualStrings("--state", sweep[4]);
    try testing.expectEqualStrings(state_dir, sweep[5]);
}

test "the sweep argv is copied, so the thread owns its own strings" {
    const gpa = testing.allocator;
    const source = [_][]const u8{ "/opt/fx/vercel.sh", "sweep", "--state", "/Users/example/.fx/sandbox/state" };
    const owned = try copyArgv(gpa, &source);
    defer freeArgv(gpa, owned);
    try testing.expectEqual(source.len, owned.len);
    for (source, owned) |want, got| {
        try testing.expectEqualStrings(want, got);
        try testing.expect(want.ptr != got.ptr);
    }
}

test "a ready policy has a sweep argv, and starting the sweep does nothing under test" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeFxHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "fxhome/fake-cli",
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const provider_path = try std.Io.Dir.path.join(alloc, &.{ fx_home, "fake-cli" });
    defer alloc.free(provider_path);
    const text = try alloc.print("{{\"provider\":[\"{s}\"]}}", .{provider_path});
    defer alloc.free(text);
    try writeConfigFile(tmp.dir, text);

    const policy = try load(alloc, fx_home, "/Users/example", null);
    defer policy.destroy();
    try testing.expect(policy.sweepArgv() != null);
    // Under test the sweep is never spawned, so this returns with no child.
    policy.startSweep();
}
