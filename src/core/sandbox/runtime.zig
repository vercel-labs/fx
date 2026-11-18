//! The sandbox runtime, one per fx process while
//! `experimental.sandbox_execution` is on. It owns the HTTP transport, the
//! config from `$FX_HOME/sandbox/config.json`, the workspace leases, and the
//! startup sweep, and it runs the commands that settings place in a sandbox.
const std = @import("std");
const api = @import("api.zig");
const client_mod = @import("client.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const executor = @import("executor.zig");
const http_transport = @import("http_transport.zig");
const io_mod = @import("../shared/io.zig");
const isolated = @import("isolated.zig");
const local_git = @import("local_git.zig");
const placement = @import("../execution/placement.zig");
const snapshots = @import("snapshots.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;

/// The largest config file fx reads.
const max_config_bytes = 1024 * 1024;

/// What the runtime needs from the rest of fx. Tests replace each one.
pub const Hooks = struct {
    context: *anyopaque,
    /// The Vercel token, or a credentials error.
    token: *const fn (context: *anyopaque, arena: Allocator) credentials.Error![]const u8,
    /// The files to copy from `cwd` into an isolated sandbox, relative to it.
    /// Null with `problem` set when the folder cannot be listed in full.
    list_files: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8, problem: *[]const u8) anyerror!?[]const []const u8,
    /// Absolute files outside `cwd` that `command` names.
    named_inputs: *const fn (context: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8) anyerror![]const []const u8,
    getenv: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,
    /// A client transport for the tests; null uses the runtime's HTTP transport.
    transport: ?client_mod.Transport = null,
};

/// One command to place and run.
pub const Request = struct {
    command: []const u8,
    /// The folder the command runs in, on this machine.
    cwd: []const u8,
    placement: placement.Placement,
    /// The isolated profile to use. Null means `default`.
    profile: ?[]const u8 = null,
};

/// What happened to one command. `problem` set and `outcome` null mean the
/// command did not run.
pub const Report = struct {
    placement: placement.Placement,
    outcome: ?executor.Outcome = null,
    problem: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
    sync: ?workspace.SyncReport = null,
    bring_back: ?workspace.BringBack = null,
    bring_back_problem: ?[]const u8 = null,
    warm_problem: ?[]const u8 = null,
    /// Profile env names that are not set on this machine; fx sent the rest.
    env_missing: []const []const u8 = &.{},
    isolated: ?isolated.Result = null,
    profile: ?[]const u8 = null,
    network: ?config.Network = null,
};

/// A placement policy kept for one workspace root. Its rules live in the
/// runtime's policy arena, so they stay valid until the runtime is destroyed.
const CachedPolicy = struct {
    root: []const u8,
    policy: placement.Policy,
};

/// The policy when the runtime cannot read its rules: every command is placed
/// in a sandbox, and none runs on this machine.
pub const fail_closed: placement.Policy = .{ .default = .{ .placement = .workspace } };

/// The sandbox runtime for one fx process. It is heap-allocated, so the
/// transport keeps its address for as long as the runtime lives.
pub const Runtime = struct {
    alloc: Allocator,
    sandbox_dir: []const u8,
    config_path: []const u8,
    /// Owns the config, its path, and the copies of `sandbox_dir`, `user`, and `host`.
    config_arena: std.heap.ArenaAllocator,
    config: ?config.Config = null,
    /// Set when the config file exists but cannot be used.
    config_problem: ?[]const u8 = null,
    transport: http_transport.HttpTransport,
    hooks: Hooks,
    leases_mutex: std.Io.Mutex = .init,
    leases: std.ArrayList(*workspace.Lease) = .empty,
    user: []const u8,
    host: []const u8,
    pid: u32,
    sweep_thread: ?std.Thread = null,
    /// The policies computed so far, one per workspace root. Guarded by
    /// `policies_mutex`; their rules live in `policy_arena`.
    policies_mutex: std.Io.Mutex = .init,
    policy_arena: std.heap.ArenaAllocator,
    policies: std.ArrayList(CachedPolicy) = .empty,

    /// `sandbox_dir` is `$FX_HOME/sandbox`, and `user` and `host` name this
    /// machine. The runtime copies all three into its own memory, so the caller
    /// may free them after the call. A config that cannot be read, other than
    /// a missing one, makes the runtime refuse every command.
    pub fn create(
        alloc: Allocator,
        sandbox_dir: []const u8,
        user: []const u8,
        host: []const u8,
        pid: u32,
        hooks: Hooks,
    ) error{OutOfMemory}!*Runtime {
        const self = try alloc.create(Runtime);
        self.* = .{
            .alloc = alloc,
            .sandbox_dir = "",
            .config_path = "",
            .config_arena = std.heap.ArenaAllocator.init(alloc),
            .policy_arena = std.heap.ArenaAllocator.init(alloc),
            .transport = http_transport.HttpTransport.init(alloc),
            .hooks = hooks,
            .user = "",
            .host = "",
            .pid = pid,
        };
        errdefer self.destroy();
        const owned = self.config_arena.allocator();
        self.sandbox_dir = try owned.dupe(u8, sandbox_dir);
        self.user = try owned.dupe(u8, user);
        self.host = try owned.dupe(u8, host);
        self.config_path = try owned.print("{s}/config.json", .{self.sandbox_dir});
        try self.loadConfig();
        return self;
    }

    /// Joins the sweep thread, frees the leases, the config, and the copies of
    /// the folder and names, then frees the runtime.
    pub fn destroy(self: *Runtime) void {
        if (self.sweep_thread) |thread| thread.join();
        for (self.leases.items) |lease| {
            lease.deinit();
            self.alloc.destroy(lease);
        }
        self.leases.deinit(self.alloc);
        self.policies.deinit(self.alloc);
        self.policy_arena.deinit();
        self.config_arena.deinit();
        self.transport.deinit();
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Reads and parses the config file. A missing file means no sandbox
    /// settings. A file that cannot be used sets `config_problem`.
    fn loadConfig(self: *Runtime) error{OutOfMemory}!void {
        const arena = self.config_arena.allocator();
        const zio = io_mod.getIo();
        var file = std.Io.Dir.cwd().openFile(zio, self.config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                debug_trace.logf("sandbox", "no sandbox config at {s}; every command stays local", .{self.config_path});
                return;
            },
            else => {
                // The folder is there but cannot be read, so the runtime refuses every command.
                self.config_problem = try arena.print("the sandbox runtime could not start: {s}", .{@errorName(err)});
                return;
            },
        };
        defer file.close(zio);
        const bytes = io_mod.readFileToEnd(arena, &file, max_config_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.config_problem = try arena.print("{s} cannot be used: the file is larger than 1 MiB or cannot be read", .{self.config_path});
                return;
            },
        };
        var diagnostic: config.Diagnostic = .{};
        const parsed = config.parse(arena, bytes, io_mod.getenv("HOME") orelse "", &diagnostic) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSandboxConfig => {
                self.config_problem = try arena.print("{s} cannot be used: {s}", .{ self.config_path, diagnostic.message });
                return;
            },
        };
        self.config = parsed;
    }

    /// The placement policy for commands run in `workspace_root`. It lives as
    /// long as the runtime, so a context may keep it after the call. A config
    /// file that cannot be used sends every command to a refusal, never to
    /// this machine.
    pub fn policyFor(self: *Runtime, workspace_root: []const u8) error{OutOfMemory}!placement.Policy {
        const zio = io_mod.getIo();
        self.policies_mutex.lockUncancelable(zio);
        defer self.policies_mutex.unlock(zio);
        for (self.policies.items) |cached| {
            if (std.mem.eql(u8, cached.root, workspace_root)) return cached.policy;
        }
        const arena = self.policy_arena.allocator();
        const root = try arena.dupe(u8, workspace_root);
        const policy = try self.computePolicy(arena, root);
        try self.policies.append(self.alloc, .{ .root = root, .policy = policy });
        return policy;
    }

    /// Builds the policy for one root. Its rules come from `arena`, or from
    /// the config, which lives as long as the runtime.
    fn computePolicy(self: *Runtime, arena: Allocator, workspace_root: []const u8) error{OutOfMemory}!placement.Policy {
        if (self.config_problem != null) return fail_closed;
        const cfg = self.config orelse return .{};
        return config.policyFor(cfg, arena, workspace_root);
    }

    /// Starts the one-time sweep of sandboxes that dead fx processes left
    /// behind. It runs on its own thread, so startup does not wait for the network.
    pub fn startSweep(self: *Runtime) void {
        if (self.config == null) return;
        self.sweep_thread = std.Thread.spawn(.{}, sweepMain, .{self}) catch |err| {
            debug_trace.logf("sandbox", "startup sweep did not start: {s}", .{@errorName(err)});
            return;
        };
    }

    /// Runs one command as its placement says, and reports what happened.
    pub fn run(
        self: *Runtime,
        arena: Allocator,
        request: Request,
        controls: executor.Controls,
        output: ?executor.Output,
    ) error{OutOfMemory}!Report {
        var report: Report = .{ .placement = request.placement };
        if (request.placement == .local) {
            report.problem = "a local command reached the sandbox runtime";
            return report;
        }
        if (self.config_problem) |problem| {
            report.problem = problem;
            return report;
        }
        const cfg = self.config orelse {
            report.problem = try arena.print("no sandbox config at {s}", .{self.config_path});
            return report;
        };
        const token = self.hooks.token(self.hooks.context, arena) catch |err| {
            report.problem = credentials.describe(err);
            return report;
        };
        const client = self.clientFor(cfg, token);
        switch (request.placement) {
            .local => unreachable,
            .workspace => try self.runWorkspace(arena, cfg, client, request, controls, output, &report),
            .isolated => try self.runIsolated(arena, cfg, client, request, controls, output, &report),
        }
        return report;
    }

    /// The API client for `cfg`, with this call's token.
    fn clientFor(self: *Runtime, cfg: config.Config, token: []const u8) client_mod.Client {
        return .{
            .transport = self.hooks.transport orelse self.transport.transport(),
            .base_url = cfg.api_url,
            .team = cfg.team,
            .project = cfg.project,
            .token = token,
        };
    }

    /// The bytes of `path` in a workspace sandbox that this process holds a
    /// session for, cut to `max_bytes`, or null. A read never starts or resumes
    /// a sandbox. A sandbox without the file, and any API failure, give null.
    pub fn readSandboxFile(self: *Runtime, arena: Allocator, path: []const u8, max_bytes: usize) error{OutOfMemory}!?[]const u8 {
        if (self.config_problem != null) return null;
        const cfg = self.config orelse return null;
        const lease = self.leaseCovering(path) orelse return null;
        const session = (try sessionOf(arena, lease)) orelse return null;
        const token = self.hooks.token(self.hooks.context, arena) catch |err| {
            debug_trace.logf("sandbox", "read of {s} from the sandbox skipped: {s}", .{ path, @errorName(err) });
            return null;
        };
        const client = self.clientFor(cfg, token);
        const remote = try workspace.remotePath(arena, cfg.remote_root, path);
        var failure: client_mod.Failure = .{};
        const fetched = client.readFile(arena, session, remote, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("sandbox", "read of {s} from the sandbox failed: {s}", .{ path, @errorName(err) });
                return null;
            },
        };
        const bytes = fetched orelse return null;
        return bytes[0..@min(bytes.len, max_bytes)];
    }

    /// The lease of the repository that holds `path`. When repositories nest,
    /// the most specific one wins. Null when no lease holds it.
    fn leaseCovering(self: *Runtime, path: []const u8) ?*workspace.Lease {
        const zio = io_mod.getIo();
        self.leases_mutex.lockUncancelable(zio);
        defer self.leases_mutex.unlock(zio);
        var best: ?*workspace.Lease = null;
        for (self.leases.items) |lease| {
            if (!covers(lease.top, path)) continue;
            if (best == null or lease.top.len > best.?.top.len) best = lease;
        }
        return best;
    }

    /// A copy of the lease's session id, or null when it has none. A sync, a
    /// bring-back, or a warm run that holds the lease makes this wait for it.
    fn sessionOf(arena: Allocator, lease: *workspace.Lease) error{OutOfMemory}!?[]const u8 {
        const zio = io_mod.getIo();
        lease.mutex.lockUncancelable(zio);
        defer lease.mutex.unlock(zio);
        const session = lease.session orelse return null;
        return try arena.dupe(u8, session);
    }

    /// True when `path` is `top` or lies under it.
    fn covers(top: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, path, top)) return true;
        return std.mem.startsWith(u8, path, top) and path.len > top.len and path[top.len] == '/';
    }

    /// The lease for the repository at `top`. It is made once and kept.
    fn leaseFor(self: *Runtime, top: []const u8) error{OutOfMemory}!*workspace.Lease {
        const zio = io_mod.getIo();
        self.leases_mutex.lockUncancelable(zio);
        defer self.leases_mutex.unlock(zio);
        for (self.leases.items) |lease| {
            if (std.mem.eql(u8, lease.top, top)) return lease;
        }
        const lease = try self.alloc.create(workspace.Lease);
        errdefer self.alloc.destroy(lease);
        lease.* = try workspace.Lease.init(self.alloc, top, self.user, self.host);
        errdefer lease.deinit();
        try self.leases.append(self.alloc, lease);
        return lease;
    }

    /// Runs one command in the repository's workspace sandbox: sync, warm
    /// when needed, run, and bring the changes back.
    fn runWorkspace(
        self: *Runtime,
        arena: Allocator,
        cfg: config.Config,
        client: client_mod.Client,
        request: Request,
        controls: executor.Controls,
        output: ?executor.Output,
        report: *Report,
    ) error{OutOfMemory}!void {
        const top = local_git.topLevel(arena, request.cwd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotARepository => {
                report.problem = try arena.print("The workspace placement needs a git repository, and {s} is not in one. Change the rule in {s}, or use isolated.", .{ request.cwd, self.config_path });
                return;
            },
            error.GitFailed => {
                report.problem = try arena.print("fx could not check whether {s} is in a git repository", .{request.cwd});
                return;
            },
        };
        const lease = try self.leaseFor(top);
        const names = try self.envPairs(arena, cfg.workspace.env);
        report.env_missing = names.missing;
        var resolving: Resolving = .{ .runtime = self, .client = client, .remote_root = cfg.remote_root, .output = output };
        const env: workspace.Env = .{
            .client = client,
            .profile = cfg.workspace,
            .remote_root = cfg.remote_root,
            .sandbox_dir = self.sandbox_dir,
            .user = self.user,
            .host = self.host,
            .resolver = .{ .context = &resolving, .resolve = resolveSource },
        };

        var failure: client_mod.Failure = .{};
        var synced = workspace.sync(lease, env, arena, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.problem = try arena.print("fx could not sync {s} to its workspace sandbox: {s}", .{ top, failureText(&failure, err) });
                return;
            },
        };
        report.sandbox = lease.name();
        report.sync = synced;

        // Bring-back compares against this baseline. A warm run that started
        // moves it to the commit it recorded, so the warm script's writes never
        // come back to this machine.
        var bring_back_baseline: ?[]const u8 = synced.baseline;
        if (cfg.workspace.warm) |script| {
            if (synced.created or !(try isWarmed(arena, self.sandbox_dir, lease))) {
                if (workspace.runWarm(lease, env, arena, script, output, controls.cancel_flag, &failure)) |warm| {
                    bring_back_baseline = warm.baseline;
                    report.warm_problem = warm.problem;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        report.warm_problem = try arena.print("fx could not warm the workspace sandbox with {s}: {s}", .{ script, failureText(&failure, err) });
                    },
                }
            }
        }

        const remote_cwd = try workspace.remotePath(arena, cfg.remote_root, request.cwd);
        var command_run: executor.Run = .{
            .session = synced.session,
            .command = request.command,
            .remote_cwd = remote_cwd,
            .env = names.pairs,
            .login = true,
        };
        var outcome = try executor.execute(client, arena, command_run, controls, output);
        if (startRefused(outcome)) {
            // The API refused the start with a client error, so no command ran.
            // One retry on a fresh session cannot start the command twice.
            lease.dropSession();
            synced = workspace.sync(lease, env, arena, &failure) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    report.problem = try arena.print("fx could not sync {s} to its workspace sandbox: {s}", .{ top, failureText(&failure, err) });
                    return;
                },
            };
            report.sync = synced;
            bring_back_baseline = synced.baseline;
            command_run.session = synced.session;
            outcome = try executor.execute(client, arena, command_run, controls, output);
        }
        report.outcome = outcome;

        if (outcome.started and !outcome.connection_lost) {
            if (bring_back_baseline) |baseline| {
                var back_failure: client_mod.Failure = .{};
                if (workspace.bringBack(lease, env, arena, baseline, &back_failure)) |back| {
                    report.bring_back = back;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        report.bring_back_problem = try arena.print("fx could not bring the changes back from {s}: {s}", .{ top, failureText(&back_failure, err) });
                    },
                }
            } else {
                report.bring_back_problem = "the warm script's result could not be recorded, so no changes come back for this command";
            }
        }
    }

    /// Runs one command in a fresh isolated sandbox, with its named profile.
    fn runIsolated(
        self: *Runtime,
        arena: Allocator,
        cfg: config.Config,
        client: client_mod.Client,
        request: Request,
        controls: executor.Controls,
        output: ?executor.Output,
        report: *Report,
    ) error{OutOfMemory}!void {
        const profile = config.isolatedProfile(cfg, request.profile) orelse {
            report.problem = try arena.print("isolated profile \"{s}\" is not defined in {s}", .{ request.profile orelse "default", self.config_path });
            return;
        };
        report.profile = profile.name;
        report.network = profile.network;

        var list_problem: []const u8 = "";
        const listed = self.hooks.list_files(self.hooks.context, arena, request.cwd, &list_problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.problem = try arena.print("fx could not list {s}: {s}", .{ request.cwd, @errorName(err) });
                return;
            },
        };
        const files = listed orelse {
            report.problem = if (list_problem.len > 0) list_problem else "fx could not list the folder for the isolated sandbox";
            return;
        };
        const inputs = self.hooks.named_inputs(self.hooks.context, arena, request.cwd, request.command) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.problem = try arena.print("fx could not read the files that {s} names: {s}", .{ request.command, @errorName(err) });
                return;
            },
        };

        var resolving: Resolving = .{ .runtime = self, .client = client, .remote_root = cfg.remote_root, .output = output };
        const env: isolated.Env = .{
            .client = client,
            .remote_root = cfg.remote_root,
            .sandbox_dir = self.sandbox_dir,
            .host = self.host,
            .pid = self.pid,
            .random = randomU32(),
            .now_s = @divFloor(io_mod.milliTimestamp(), 1000),
            .resolver = .{ .context = &resolving, .resolve = resolveSource },
        };
        var failure: client_mod.Failure = .{};
        const result = isolated.run(env, arena, .{
            .command = request.command,
            .cwd = request.cwd,
            .files = files,
            .inputs = inputs,
            .profile = profile,
        }, controls, output, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.problem = failureText(&failure, err);
                return;
            },
        };
        report.isolated = result;
        report.sandbox = result.sandbox;
        report.outcome = result.outcome;
    }

    /// The profile's env names, with their values where this machine sets them.
    fn envPairs(self: *Runtime, arena: Allocator, names: []const []const u8) error{OutOfMemory}!EnvSet {
        var pairs: std.ArrayList(api.Pair) = .empty;
        var missing: std.ArrayList([]const u8) = .empty;
        for (names) |name| {
            if (self.hooks.getenv(self.hooks.context, name)) |value| {
                try pairs.append(arena, .{ .name = name, .value = value });
            } else {
                try missing.append(arena, name);
            }
        }
        return .{ .pairs = try pairs.toOwnedSlice(arena), .missing = try missing.toOwnedSlice(arena) };
    }
};

/// The env pairs a command sends, and the names this machine did not set.
const EnvSet = struct {
    pairs: []const api.Pair,
    missing: []const []const u8,
};

/// What the source resolver needs while one command runs.
const Resolving = struct {
    runtime: *Runtime,
    client: client_mod.Client,
    remote_root: []const u8,
    output: ?executor.Output,
};

fn resolveSource(context: *anyopaque, arena: Allocator, source: config.Source, failure: *client_mod.Failure) anyerror!config.Source {
    const resolving: *Resolving = @ptrCast(@alignCast(context));
    return snapshots.resolve(.{
        .client = resolving.client,
        .remote_root = resolving.remote_root,
        .sandbox_dir = resolving.runtime.sandbox_dir,
        .host = resolving.runtime.host,
        .pid = resolving.runtime.pid,
        .random = randomU32(),
        .output = resolving.output,
    }, arena, source, failure);
}

/// Runs the startup sweep once, on its own thread. A missing token skips it.
fn sweepMain(self: *Runtime) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = self.config orelse return;
    const token = self.hooks.token(self.hooks.context, arena) catch |err| {
        debug_trace.logf("sandbox", "startup sweep skipped: {s}", .{credentials.describe(err)});
        return;
    };
    var failure: client_mod.Failure = .{};
    const removed = isolated.sweep(self.clientFor(cfg, token), arena, self.host, self.pid, isolated.processAlive, &failure) catch |err| {
        debug_trace.logf("sandbox", "startup sweep failed: {s} {s}", .{ @errorName(err), failure.message });
        return;
    };
    debug_trace.logf("sandbox", "startup sweep removed {d} sandboxes", .{removed});
}

/// True when the lease's saved record says the warm script already ran here.
fn isWarmed(arena: Allocator, sandbox_dir: []const u8, lease: *const workspace.Lease) error{OutOfMemory}!bool {
    const record_path = try workspace.recordPath(arena, sandbox_dir, lease.name());
    const saved = (try workspace.loadRecord(arena, record_path)) orelse return false;
    return saved.warmed and std.mem.eql(u8, saved.top, lease.top);
}

/// True when the API refused the command's start with a client error. The
/// command did not run, so one retry cannot start it twice. A server error or
/// a lost answer does not count: the start may have run.
fn startRefused(outcome: executor.Outcome) bool {
    if (outcome.started or outcome.connection_lost) return false;
    const status = outcome.start_status orelse return false;
    return status >= 400 and status < 500;
}

/// The failure's message, or the error's name when no message was set.
fn failureText(failure: *const client_mod.Failure, err: anyerror) []const u8 {
    return if (failure.message.len > 0) failure.message else @errorName(err);
}

/// Four random bytes from the process's random source, as a number.
fn randomU32() u32 {
    var bytes: [4]u8 = undefined;
    io_mod.getIo().random(&bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

// ---- tests ----

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");
const FakeSandbox = test_sandbox.FakeSandbox;
const test_folder_mode = std.Io.File.Permissions.fromMode(0o755);
const test_controls: executor.Controls = .{ .max_output_bytes = 1 << 20 };
const missing_start_json = "{\"error\":{\"message\":\"no such session\"}}";
const no_space_json = "{\"error\":{\"message\":\"no space left\"}}";

/// Records every call the runtime sends, refuses a user command's start when
/// asked, and passes every other call to the shared fake.
const Recorder = struct {
    fake: *FakeSandbox,
    /// Every call the runtime sent, refused or answered.
    calls: usize = 0,
    /// Starts of the user's commands (login shells), counted before any refusal.
    user_starts: usize = 0,
    refuse_first_start: bool = false,
    /// The status the refused start answers with.
    refuse_status: u16 = 404,
    refused: bool = false,
    /// Answers every sandbox file write with a 500, so a sync fails.
    fail_writes: bool = false,
    /// What the last user start carried in its body.
    start_saw_set: bool = false,
    start_saw_missing: bool = false,

    fn send(context: *anyopaque, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (isUserStart(call)) {
            self.user_starts += 1;
            self.start_saw_set = std.mem.find(u8, call.request.body, "FX_T_SET") != null;
            self.start_saw_missing = std.mem.find(u8, call.request.body, "FX_T_MISSING") != null;
            if (self.refuse_first_start and !self.refused) {
                self.refused = true;
                return .{ .status = self.refuse_status, .body = missing_start_json };
            }
        }
        if (self.fail_writes and std.mem.find(u8, call.request.target, "/fs/write") != null) {
            return .{ .status = 500, .body = no_space_json };
        }
        return FakeSandbox.send(self.fake, arena, call);
    }
};

/// A user command's start: a POST to a command route with a login shell.
fn isUserStart(call: client_mod.Call) bool {
    if (call.request.method != .POST) return false;
    if (std.mem.find(u8, call.request.target, "/cmd") == null) return false;
    return std.mem.find(u8, call.request.body, "\"-lc\"") != null;
}

fn transportOf(recorder: *Recorder) client_mod.Transport {
    return .{ .context = recorder, .send = Recorder.send };
}

/// The hooks a test uses: a fixed token, a fixed file list, and a small table of env values.
const TestHooks = struct {
    token_error: ?credentials.Error = null,
    environment: []const api.Pair = &.{},
    list: []const []const u8 = &.{"in.txt"},

    fn token(context: *anyopaque, arena: Allocator) credentials.Error![]const u8 {
        _ = arena;
        const self: *TestHooks = @ptrCast(@alignCast(context));
        if (self.token_error) |err| return err;
        return "test-token";
    }

    fn listFiles(context: *anyopaque, arena: Allocator, cwd: []const u8, problem: *[]const u8) anyerror!?[]const []const u8 {
        _ = arena;
        _ = cwd;
        _ = problem;
        const self: *TestHooks = @ptrCast(@alignCast(context));
        return self.list;
    }

    fn namedInputs(context: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8) anyerror![]const []const u8 {
        _ = context;
        _ = arena;
        _ = cwd;
        _ = command;
        return &.{};
    }

    fn getenv(context: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *TestHooks = @ptrCast(@alignCast(context));
        for (self.environment) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }
};

fn hooksFor(state: *TestHooks, transport: ?client_mod.Transport) Hooks {
    return .{
        .context = state,
        .token = TestHooks.token,
        .list_files = TestHooks.listFiles,
        .named_inputs = TestHooks.namedInputs,
        .getenv = TestHooks.getenv,
        .transport = transport,
    };
}

/// Counts the output lines that start with `prefix`.
const LineCounter = struct {
    prefix: []const u8,
    matches: usize = 0,

    fn onLine(context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void {
        _ = stream;
        const self: *LineCounter = @ptrCast(@alignCast(context));
        if (std.mem.startsWith(u8, line, self.prefix)) self.matches += 1;
    }
};

/// The folders one test uses. `disk` stands in for the sandbox disk.
const Fixture = struct {
    state: []const u8,
    disk: []const u8,
    repo: []const u8,
    plain: []const u8,
    base: []const u8,
};

fn makeFixture(arena: Allocator, tmp: *testing.TmpDir) !Fixture {
    const zio = io_mod.getIo();
    try tmp.dir.createDir(zio, "state", test_folder_mode);
    try tmp.dir.createDir(zio, "disk", test_folder_mode);
    try tmp.dir.createDir(zio, "repo", test_folder_mode);
    try tmp.dir.createDir(zio, "plain", test_folder_mode);
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    return .{
        .state = try arena.print("{s}/state", .{base}),
        .disk = try arena.print("{s}/disk", .{base}),
        .repo = try arena.print("{s}/repo", .{base}),
        .plain = try arena.print("{s}/plain", .{base}),
        .base = base,
    };
}

fn writeText(path: []const u8, text: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{});
    defer file.close(zio);
    try file.writeStreamingAll(zio, text);
}

fn readText(arena: Allocator, path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

/// Writes `config.json` with the test team, project, and remote root, plus
/// `workspace_part`, a JSON fragment that starts with a comma or is empty.
fn writeConfig(arena: Allocator, fixture: Fixture, workspace_part: []const u8) !void {
    const text = try arena.print("{{\"team\":\"team\",\"project\":\"project\",\"api_url\":\"https://sandbox.test\",\"remote_root\":\"{s}\",\"default\":\"workspace\"{s}}}", .{ fixture.disk, workspace_part });
    try writeText(try arena.print("{s}/config.json", .{fixture.state}), text);
}

fn expectGit(arena: Allocator, path: []const u8, argv: []const []const u8) !void {
    const ran = try test_sandbox.runCommand(arena, path, argv);
    if (ran.code != 0) return error.TestUnexpectedResult;
}

/// A git repository in `path` with `a.txt` committed.
fn makeRepo(arena: Allocator, path: []const u8) !void {
    try expectGit(arena, path, &.{ "git", "init", "-q" });
    try expectGit(arena, path, &.{ "git", "config", "user.email", "t@t" });
    try expectGit(arena, path, &.{ "git", "config", "user.name", "t" });
    try writeText(try arena.print("{s}/a.txt", .{path}), "one\n");
    try expectGit(arena, path, &.{ "git", "add", "a.txt" });
    try expectGit(arena, path, &.{ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" });
}

fn fileExists(path: []const u8) bool {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return false;
    file.close(zio);
    return true;
}

/// Removes a folder under `parent_path`, if it is there.
fn removeAbsoluteFolder(parent_path: []const u8, name: []const u8) void {
    const zio = io_mod.getIo();
    var parent = std.Io.Dir.openDirAbsolute(zio, parent_path, .{}) catch return;
    defer parent.close(zio);
    parent.deleteTree(zio, name) catch {};
}

fn listHas(list: []const []const u8, text: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

fn openRuntime(fixture: Fixture, hooks: Hooks) !*Runtime {
    return Runtime.create(testing.allocator, fixture.state, "tester", "host.test", 42, hooks);
}

test "no config file means every command stays local" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    try testing.expect(runtime.config == null);
    try testing.expect(runtime.config_problem == null);
    const policy = try runtime.policyFor(fixture.repo);
    try testing.expectEqual(placement.Placement.local, placement.decide(policy, "ls").placement);
}

test "a broken config file sends every command to a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try writeText(try arena.print("{s}/config.json", .{fixture.state}), "{");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    try testing.expect(std.mem.find(u8, runtime.config_problem.?, "config.json cannot be used") != null);
    const policy = try runtime.policyFor(fixture.repo);
    try testing.expectEqual(placement.Placement.workspace, placement.decide(policy, "ls").placement);

    const report = try runtime.run(arena, .{ .command = "ls", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "config.json cannot be used") != null);
    try testing.expect(report.outcome == null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "a policy outlives the root it was computed for and is computed once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    // An untrusted workspace keeps only the rules that choose an isolated
    // profile, so its policy is a filtered copy.
    try writeConfig(arena, fixture, try arena.print(
        ",\"rules\":[{{\"command\":\"zig build*\",\"placement\":\"isolated:media\"}},{{\"command\":\"ls\",\"placement\":\"local\"}}],\"workspaces\":{{\"{s}\":\"isolated\"}},\"isolated\":{{\"media\":{{}}}}",
        .{fixture.repo},
    ));
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    // The runtime copies the root, so the caller's buffer may go after the call.
    const first = blk: {
        const root = try testing.allocator.dupe(u8, fixture.repo);
        defer testing.allocator.free(root);
        break :blk try runtime.policyFor(root);
    };
    const second = try runtime.policyFor(fixture.repo);
    try testing.expectEqual(first.rules.ptr, second.rules.ptr);
    try testing.expectEqual(@as(usize, 1), first.rules.len);
    const zig_build = placement.decide(first, "zig build test");
    try testing.expectEqual(placement.Placement.isolated, zig_build.placement);
    try testing.expectEqualStrings("media", zig_build.profile.?);
}

test "a runtime that could not start refuses every command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    // A file stands where the sandbox folder should be, so opening its config
    // fails with something other than a missing file.
    try writeText(try arena.print("{s}/blocker", .{fixture.state}), "not a folder");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    // The runtime copies its folder and names, so the caller's copies go first.
    const runtime = blk: {
        const folder = try testing.allocator.dupe(u8, try arena.print("{s}/blocker/sandbox", .{fixture.state}));
        defer testing.allocator.free(folder);
        const host = try testing.allocator.dupe(u8, "host.test");
        defer testing.allocator.free(host);
        break :blk try Runtime.create(testing.allocator, folder, "tester", host, 42, hooksFor(&state, transportOf(&recorder)));
    };
    defer runtime.destroy();

    try testing.expect(std.mem.find(u8, runtime.config_problem.?, "the sandbox runtime could not start: ") != null);
    const policy = try runtime.policyFor(fixture.repo);
    try testing.expectEqual(placement.Placement.workspace, placement.decide(policy, "ls").placement);
    try testing.expectEqual(@as(usize, 0), policy.rules.len);

    const report = try runtime.run(arena, .{ .command = "ls", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "the sandbox runtime could not start: ") != null);
    try testing.expect(report.outcome == null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "a missing login stops the command before any sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{ .token_error = error.VercelLoginMissing };
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "ls", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "vercel login") != null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "a read of the workspace sandbox returns what it holds, and never starts one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    // zig-out is ignored, so a command's output there never comes back to this machine.
    try writeText(try arena.print("{s}/.gitignore", .{fixture.repo}), "zig-out/\n");
    try expectGit(arena, fixture.repo, &.{ "git", "add", ".gitignore" });
    try expectGit(arena, fixture.repo, &.{ "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "ignore" });
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const log_path = try arena.print("{s}/zig-out/log.txt", .{fixture.repo});
    // No workspace sandbox exists yet, so the read finds nothing and starts none.
    try testing.expect((try runtime.readSandboxFile(arena, log_path, 1024)) == null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);

    const report = try runtime.run(arena, .{ .command = "mkdir -p zig-out && echo built > zig-out/log.txt", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expectEqual(@as(?i64, 0), report.outcome.?.exit_code);
    try testing.expect(!fileExists(log_path));

    try testing.expectEqualStrings("built\n", (try runtime.readSandboxFile(arena, log_path, 1024)).?);
    // The cap cuts the bytes.
    try testing.expectEqualStrings("bui", (try runtime.readSandboxFile(arena, log_path, 3)).?);
    // A file the sandbox does not hold is null.
    try testing.expect((try runtime.readSandboxFile(arena, try arena.print("{s}/zig-out/missing.txt", .{fixture.repo}), 1024)) == null);

    // A path under no workspace sandbox is never asked of the API.
    const reads_before = fake.reads;
    try testing.expect((try runtime.readSandboxFile(arena, "/nowhere/else.txt", 1024)) == null);
    try testing.expectEqual(reads_before, fake.reads);
}

test "a workspace command syncs, runs, and brings changes back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo b > b.txt", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(report.problem == null);
    try testing.expect(report.sync.?.created);
    try testing.expectEqual(@as(?i64, 0), report.outcome.?.exit_code);
    try testing.expect(listHas(report.bring_back.?.taken, "b.txt"));
    try testing.expectEqualStrings("b\n", try readText(arena, try arena.print("{s}/b.txt", .{fixture.repo})));
}

test "a workspace command outside a repository does not run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    // The test folder sits inside this worktree's own repository, so the plain
    // folder is made under the system temp folder instead.
    const system_tmp = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    const plain_name = try arena.print("fx-runtime-plain-{x}", .{randomU32()});
    try std.Io.Dir.createDirAbsolute(io_mod.getIo(), try arena.print("{s}/{s}", .{ system_tmp, plain_name }), std.Io.File.Permissions.fromMode(0o700));
    defer removeAbsoluteFolder(system_tmp, plain_name);
    const report = try runtime.run(arena, .{ .command = "ls", .cwd = try arena.print("{s}/{s}", .{ system_tmp, plain_name }), .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "git repository") != null);
    try testing.expect(report.outcome == null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "profile env names are sent, and missing ones are named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeConfig(arena, fixture, ",\"workspace\":{\"env\":[\"FX_T_SET\",\"FX_T_MISSING\"]}");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{ .environment = &[_]api.Pair{.{ .name = "FX_T_SET", .value = "set-value" }} };
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo ok", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(report.problem == null);
    try testing.expectEqual(@as(usize, 1), report.env_missing.len);
    try testing.expectEqualStrings("FX_T_MISSING", report.env_missing[0]);
    try testing.expect(recorder.start_saw_set);
    try testing.expect(!recorder.start_saw_missing);
}

test "the warm script runs once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    const warm_path = try arena.print("{s}/warm.sh", .{fixture.base});
    try writeText(warm_path, "echo warmed\n");
    try writeConfig(arena, fixture, try arena.print(",\"workspace\":{{\"warm\":\"{s}\"}}", .{warm_path}));
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();
    var counter: LineCounter = .{ .prefix = "fx: warming the workspace sandbox" };
    const output: executor.Output = .{ .context = &counter, .on_line = LineCounter.onLine };

    const first = try runtime.run(arena, .{ .command = "echo one", .cwd = fixture.repo, .placement = .workspace }, test_controls, output);
    const second = try runtime.run(arena, .{ .command = "echo two", .cwd = fixture.repo, .placement = .workspace }, test_controls, output);
    try testing.expect(first.warm_problem == null);
    try testing.expect(first.sync.?.created);
    try testing.expect(!second.sync.?.created);
    try testing.expectEqual(@as(usize, 1), counter.matches);

    const lease = runtime.leases.items[0];
    const record_path = try workspace.recordPath(arena, fixture.state, lease.name());
    try testing.expect((try workspace.loadRecord(arena, record_path)).?.warmed);
}

test "an isolated command runs in a fresh sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try writeText(try arena.print("{s}/in.txt", .{fixture.plain}), "hi\n");
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "cp in.txt out.txt", .cwd = fixture.plain, .placement = .isolated }, test_controls, null);
    try testing.expect(report.problem == null);
    const result = report.isolated.?;
    try testing.expect(result.removed);
    try testing.expectEqual(@as(?i64, 0), result.outcome.exit_code);
    try testing.expectEqualStrings("hi\n", try readText(arena, try arena.print("{s}/out.txt", .{result.run_folder.?})));
    try testing.expectEqualStrings("default", report.profile.?);
    try testing.expectEqual(std.meta.Tag(config.Network).deny_all, std.meta.activeTag(report.network.?));
}

test "an unknown isolated profile does not run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "ls", .cwd = fixture.plain, .placement = .isolated, .profile = "nope" }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "isolated profile \"nope\" is not defined") != null);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "a start failure retries once on a fresh session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake, .refuse_first_start = true };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo ok", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(report.problem == null);
    try testing.expectEqual(@as(?i64, 0), report.outcome.?.exit_code);
    try testing.expectEqual(@as(usize, 2), recorder.user_starts);
}

test "a 500 start is not retried" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake, .refuse_first_start = true, .refuse_status = 500 };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo ok", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(report.problem == null);
    const outcome = report.outcome.?;
    try testing.expect(!outcome.started);
    try testing.expectEqual(@as(?u16, 500), outcome.start_status);
    try testing.expect(std.mem.find(u8, outcome.failure.?, "HTTP 500") != null);
    try testing.expectEqual(@as(usize, 1), recorder.user_starts);
}

test "warm output never comes back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeText(try arena.print("{s}/.gitignore", .{fixture.repo}), "zig-out/\n");
    const warm_path = try arena.print("{s}/warm.sh", .{fixture.base});
    try writeText(warm_path, "echo gen > gen.txt\nmkdir -p zig-out\necho x > zig-out/x\n");
    try writeConfig(arena, fixture, try arena.print(",\"workspace\":{{\"warm\":\"{s}\"}}", .{warm_path}));
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const first = try runtime.run(arena, .{ .command = "true", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(first.warm_problem == null);
    try testing.expectEqual(@as(usize, 0), first.bring_back.?.taken.len);
    try testing.expect(!fileExists(try arena.print("{s}/gen.txt", .{fixture.repo})));

    // The next sync sees that the sandbox copy differs from this machine, and restores it.
    const second = try runtime.run(arena, .{ .command = "true", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(second.problem == null);
    try testing.expect(!fileExists(try arena.print("{s}{s}/gen.txt", .{ fixture.disk, fixture.repo })));
    try testing.expectEqualStrings("one\n", try readText(arena, try arena.print("{s}{s}/a.txt", .{ fixture.disk, fixture.repo })));
    try testing.expect(!fileExists(try arena.print("{s}/zig-out/x", .{fixture.repo})));
}

test "a failing warm script is reported and the command still runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    const warm_path = try arena.print("{s}/warm.sh", .{fixture.base});
    try writeText(warm_path, "exit 4\n");
    try writeConfig(arena, fixture, try arena.print(",\"workspace\":{{\"warm\":\"{s}\"}}", .{warm_path}));
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo ok", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.warm_problem.?, "exit 4") != null);
    try testing.expectEqual(@as(?i64, 0), report.outcome.?.exit_code);

    const lease = runtime.leases.items[0];
    const saved = (try workspace.loadRecord(arena, try workspace.recordPath(arena, fixture.state, lease.name()))).?;
    try testing.expect(!saved.warmed);
}

test "a sync failure stops the command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try makeRepo(arena, fixture.repo);
    try writeConfig(arena, fixture, "");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var recorder: Recorder = .{ .fake = &fake, .fail_writes = true };
    var state: TestHooks = .{};
    const runtime = try openRuntime(fixture, hooksFor(&state, transportOf(&recorder)));
    defer runtime.destroy();

    const report = try runtime.run(arena, .{ .command = "echo ok", .cwd = fixture.repo, .placement = .workspace }, test_controls, null);
    try testing.expect(std.mem.find(u8, report.problem.?, "could not sync") != null);
    try testing.expect(report.outcome == null);
    try testing.expectEqual(@as(usize, 0), recorder.user_starts);
}
