const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const protocol = @import("protocol.zig");
const terminal_operation = @import("operation.zig");
const policy = @import("host_policy.zig");
const native_session = @import("native_session.zig");
const terminal_store = @import("store.zig");
const host_capabilities = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const process_identity = @import("../execution/process_identity.zig");

const Allocator = std.mem.Allocator;

pub const internal_mode = "--fx-internal-terminal-host";
pub const endpoint_name = "host.sock";
pub const lock_name = "host.lock";
const identity_name = "host.json";
const host_dir_name = "terminal-host-v7";
const default_idle_grace_ms: u64 = 30_000;
const identity_max_bytes: usize = 1024;
// macOS GUI apps commonly inherit 256, below the host's 64-session budget.
const desired_file_descriptor_limit: u64 = 1024;
const max_connection_requests: usize = 32;
const listener_poll_ms = 50;
const transport_hash_bytes: usize = 16;
const transport_hash_context = "fx.terminal.transport.v3\x00";
const socket_permissions: std.Io.File.Permissions = switch (builtin.os.tag) {
    .macos, .linux => .fromMode(0o600),
    else => .default_file,
};

pub fn isSupported() bool {
    return isSupportedForOs(builtin.os.tag);
}

fn isSupportedForOs(os_tag: std.Target.Os.Tag) bool {
    return host_capabilities.terminalSupportForOs(os_tag).isSupported();
}

pub fn isInternalModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 2 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), internal_mode);
}

pub fn validateEndpointPath(path: []const u8) !void {
    return validateEndpointPathForTarget(builtin.os.tag, path);
}

fn nativeEndpointPathLimit(target: std.Target.Os.Tag) ?usize {
    return switch (target) {
        .macos => 104,
        .linux => 108,
        else => null,
    };
}

fn runtimeBase(target: std.Target.Os.Tag) ?[]const u8 {
    return switch (target) {
        .macos => "/private/tmp",
        .linux => "/tmp",
        else => null,
    };
}

fn validateEndpointPathForTarget(
    target: std.Target.Os.Tag,
    path: []const u8,
) !void {
    const limit = nativeEndpointPathLimit(target) orelse
        return error.TerminalHostUnsupported;
    if (path.len >= limit) return error.NameTooLong;
}

const EndpointSelection = struct {
    authority_root: []u8,
    transport_root: []u8,
    endpoint_path: []u8,
    uses_fallback: bool,

    fn deinit(self: *EndpointSelection, alloc: Allocator) void {
        alloc.free(self.endpoint_path);
        alloc.free(self.transport_root);
        alloc.free(self.authority_root);
        self.* = undefined;
    }
};

fn resolveEndpointSelection(
    alloc: Allocator,
    target: std.Target.Os.Tag,
    home: []const u8,
    uid: std.c.uid_t,
) !EndpointSelection {
    const runtime_base = runtimeBase(target) orelse
        return error.TerminalHostUnsupported;
    const authority_root = try std.fs.path.join(
        alloc,
        &.{ home, profile_paths.root_dir_name, host_dir_name },
    );
    errdefer alloc.free(authority_root);
    const profile_endpoint = try std.fs.path.join(
        alloc,
        &.{ authority_root, endpoint_name },
    );
    if (validateEndpointPathForTarget(target, profile_endpoint)) {
        errdefer alloc.free(profile_endpoint);
        const transport_root = try alloc.dupe(u8, authority_root);
        return .{
            .authority_root = authority_root,
            .transport_root = transport_root,
            .endpoint_path = profile_endpoint,
            .uses_fallback = false,
        };
    } else |err| switch (err) {
        error.NameTooLong => alloc.free(profile_endpoint),
        else => {
            alloc.free(profile_endpoint);
            return err;
        },
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(transport_hash_context);
    hasher.update(home);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(
        digest[0..transport_hash_bytes].*,
        .lower,
    );
    const runtime_name = try std.fmt.allocPrint(
        alloc,
        "fx-terminal-{d}-{s}",
        .{ uid, digest_hex },
    );
    defer alloc.free(runtime_name);
    const transport_root = try std.fs.path.join(
        alloc,
        &.{ runtime_base, runtime_name },
    );
    errdefer alloc.free(transport_root);
    const endpoint_path = try std.fs.path.join(
        alloc,
        &.{ transport_root, endpoint_name },
    );
    errdefer alloc.free(endpoint_path);
    try validateEndpointPathForTarget(target, endpoint_path);
    return .{
        .authority_root = authority_root,
        .transport_root = transport_root,
        .endpoint_path = endpoint_path,
        .uses_fallback = true,
    };
}

pub const Config = struct {
    process_provider: process_provider_mod.Provider =
        process_provider_mod.unavailable_provider,
    hello: contracts.ProtocolHello = .{
        .range = contracts.local_protocol_range,
        .capabilities = contracts.known_protocol_capabilities,
    },
    idle_grace_ms: u64 = default_idle_grace_ms,

    pub fn fromEnvironment(
        process_provider: process_provider_mod.Provider,
    ) !Config {
        var config: Config = .{ .process_provider = process_provider };
        if (io_mod.getenv("FX_TERMINAL_HOST_PROTOCOL_MIN")) |value| {
            config.hello.range.minimum = try std.fmt.parseInt(u16, value, 10);
        }
        if (io_mod.getenv("FX_TERMINAL_HOST_PROTOCOL_CURRENT")) |value| {
            config.hello.range.current = try std.fmt.parseInt(u16, value, 10);
        }
        if (io_mod.getenv("FX_TERMINAL_HOST_PROTOCOL_CAPABILITIES")) |value| {
            config.hello.capabilities = try std.fmt.parseInt(u64, value, 10);
        }
        if (io_mod.getenv("FX_TERMINAL_HOST_IDLE_MS")) |value| {
            config.idle_grace_ms = try std.fmt.parseInt(u64, value, 10);
        }
        try config.hello.validate();
        if (config.idle_grace_ms == 0) return error.InvalidIdleGrace;
        return config;
    }
};

pub const Paths = struct {
    home_dir: io_mod.VerifiedDir,
    fx_dir: io_mod.VerifiedDir,
    host_dir: io_mod.VerifiedDir,
    transport_dir: ?io_mod.VerifiedDir,
    authority_root_path: []u8,
    transport_root_path: []u8,
    endpoint_path: []u8,

    pub fn open(alloc: Allocator, home: []const u8) !Paths {
        if (!isSupported()) return error.TerminalHostUnsupported;
        var selection = try resolveEndpointSelection(
            alloc,
            builtin.os.tag,
            home,
            std.c.getuid(),
        );
        var selection_owned = true;
        errdefer if (selection_owned) selection.deinit(alloc);
        var home_dir = io_mod.VerifiedDir{
            .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
                .iterate = true,
                .follow_symlinks = false,
            }),
        };
        errdefer home_dir.close();
        var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &home_dir,
            profile_paths.root_dir_name,
        );
        errdefer fx_dir.close();
        var host_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &fx_dir,
            host_dir_name,
        );
        errdefer host_dir.close();
        var transport_dir: ?io_mod.VerifiedDir = null;
        errdefer if (transport_dir) |*dir| dir.close();
        if (selection.uses_fallback) {
            transport_dir = try openRuntimeTransportDir(
                selection.transport_root,
                std.c.getuid(),
            );
        }
        selection_owned = false;
        return .{
            .home_dir = home_dir,
            .fx_dir = fx_dir,
            .host_dir = host_dir,
            .transport_dir = transport_dir,
            .authority_root_path = selection.authority_root,
            .transport_root_path = selection.transport_root,
            .endpoint_path = selection.endpoint_path,
        };
    }

    pub fn endpointDir(self: *Paths) *io_mod.VerifiedDir {
        if (self.transport_dir) |*dir| return dir;
        return &self.host_dir;
    }

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        alloc.free(self.endpoint_path);
        alloc.free(self.transport_root_path);
        alloc.free(self.authority_root_path);
        if (self.transport_dir) |*dir| dir.close();
        self.host_dir.close();
        self.fx_dir.close();
        self.home_dir.close();
        self.* = undefined;
    }
};

fn openRuntimeTransportDir(
    transport_root: []const u8,
    uid: std.c.uid_t,
) !io_mod.VerifiedDir {
    const parent_path = std.fs.path.dirname(transport_root) orelse
        return error.RuntimeDirectoryUnsafe;
    const name = std.fs.path.basename(transport_root);
    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer parent.close(io_mod.getIo());
    return openVerifiedPrivateRuntimeDir(parent, name, uid);
}

fn openVerifiedPrivateRuntimeDir(
    parent: std.Io.Dir,
    name: []const u8,
    uid: std.c.uid_t,
) !io_mod.VerifiedDir {
    const zio = io_mod.getIo();
    var dir = parent.openDir(zio, name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(
                zio,
                name,
                std.Io.File.Permissions.fromMode(0o700),
            ) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            break :blk parent.openDir(zio, name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |open_err| switch (open_err) {
                error.SymLinkLoop, error.NotDir => return error.RuntimeDirectoryUnsafe,
                else => return open_err,
            };
        },
        error.SymLinkLoop, error.NotDir => return error.RuntimeDirectoryUnsafe,
        else => return err,
    };
    errdefer dir.close(zio);
    try verifyPrivateRuntimeDir(dir, uid);
    return .{ .dir = dir };
}

fn verifyPrivateRuntimeDir(dir: std.Io.Dir, uid: std.c.uid_t) !void {
    const stat = try dir.stat(io_mod.getIo());
    const owner_uid = try directoryOwner(dir);
    try validatePrivateRuntimeDir(stat, owner_uid, uid);
}

fn directoryOwner(dir: std.Io.Dir) !std.c.uid_t {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var stat = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    dir.handle,
                    "",
                    linux.AT.EMPTY_PATH,
                    .{ .UID = true },
                    &stat,
                ))) {
                    .SUCCESS => {
                        if (!stat.mask.UID) {
                            return error.RuntimeDirectoryOwnershipUnavailable;
                        }
                        break :blk stat.uid;
                    },
                    .INTR => {},
                    else => return error.RuntimeDirectoryOwnershipUnavailable,
                }
            }
        },
        .macos => blk: {
            while (true) {
                var stat = std.mem.zeroes(std.c.Stat);
                switch (std.c.errno(std.c.fstat(dir.handle, &stat))) {
                    .SUCCESS => break :blk stat.uid,
                    .INTR => {},
                    else => return error.RuntimeDirectoryOwnershipUnavailable,
                }
            }
        },
        else => error.TerminalHostUnsupported,
    };
}

fn validatePrivateRuntimeDir(
    stat: std.Io.File.Stat,
    owner_uid: std.c.uid_t,
    uid: std.c.uid_t,
) !void {
    if (stat.kind != .directory) return error.RuntimeDirectoryUnsafe;
    if (owner_uid != uid) return error.RuntimeDirectoryOwnerMismatch;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

const IdentityRecord = struct {
    pid: []const u8,
    process_token: []const u8,
    instance: []const u8,
    protocol_minimum: u16,
    protocol_current: u16,
};

pub fn run(alloc: Allocator, config: Config) !void {
    if (comptime !isSupported()) return error.TerminalHostUnsupported;
    ensureFileDescriptorBudget();
    return runSupported(alloc, config) catch |err| {
        debug_trace.logf(
            "terminal_host",
            "host startup failed err={s}",
            .{@errorName(err)},
        );
        return err;
    };
}

fn fileDescriptorLimitTarget(current: u64, maximum: u64) ?u64 {
    const target = @min(maximum, desired_file_descriptor_limit);
    return if (current < target) target else null;
}

fn ensureFileDescriptorBudget() void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var limits = std.posix.getrlimit(.NOFILE) catch |err| {
        debug_trace.logf(
            "terminal_host",
            "host file descriptor limit unavailable err={s}",
            .{@errorName(err)},
        );
        return;
    };
    const target = fileDescriptorLimitTarget(
        @intCast(limits.cur),
        @intCast(limits.max),
    ) orelse return;
    limits.cur = @intCast(target);
    std.posix.setrlimit(.NOFILE, limits) catch |err| {
        debug_trace.logf(
            "terminal_host",
            "host file descriptor limit unchanged target={d} err={s}",
            .{ target, @errorName(err) },
        );
        return;
    };
    debug_trace.logf(
        "terminal_host",
        "host file descriptor limit raised soft={d}",
        .{target},
    );
}

fn runSupported(alloc: Allocator, config: Config) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var paths = try Paths.open(alloc, home);
    defer paths.deinit(alloc);

    var authority_lock = io_mod.acquireTimedAdvisoryLock(
        &paths.host_dir,
        lock_name,
        0,
    ) catch |err| switch (err) {
        error.LockBusy => return,
        else => return err,
    };
    defer authority_lock.release();

    const identity_evidence = identityEvidence(
        alloc,
        config.process_provider,
        &paths.host_dir,
    );
    if (identity_evidence == .live or identity_evidence == .unverifiable) {
        return error.HostIdentityConflict;
    }
    cleanupEndpoint(paths.endpointDir());
    cleanupIdentity(&paths.host_dir);

    const address = try std.Io.net.UnixAddress.init(paths.endpoint_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());
    var endpoint_created = true;
    defer if (endpoint_created) cleanupEndpoint(paths.endpointDir());
    try paths.endpointDir().dir.setFilePermissions(
        io_mod.getIo(),
        endpoint_name,
        socket_permissions,
        .{ .follow_symlinks = false },
    );
    try verifyEndpointPermissions(paths.endpointDir());

    var instance_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&instance_bytes);
    const host_instance = std.fmt.bytesToHex(instance_bytes, .lower);
    try writeIdentity(
        alloc,
        config.process_provider,
        &paths.host_dir,
        config.hello.range,
        &host_instance,
    );
    var identity_created = true;
    defer if (identity_created) cleanupIdentity(&paths.host_dir);

    var state = HostState{
        .idle_grace_ms = config.idle_grace_ms,
    };
    var startup = HostStartup{};
    var accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{
        alloc,
        &server,
        config.process_provider,
        config.hello,
        &state,
        &startup,
    });
    var startup_complete = false;
    var accept_joined = false;
    errdefer if (!startup_complete) {
        state.stopping.store(true, .release);
        startup.ready.set(io_mod.getIo());
        accept_thread.join();
        accept_joined = true;
        if (!drainConnectedClients(&state, client_drain_timeout_ms)) {
            debug_trace.logf(
                "terminal_host",
                "host startup failed with {d} client thread(s) still running; preserving shared state until process exit",
                .{state.connected_clients.load(.acquire)},
            );
            std.process.exit(1);
        }
    };

    debug_trace.logf(
        "terminal_host",
        "host listening pid={d} protocol={d}-{d}",
        .{ std.c.getpid(), config.hello.range.minimum, config.hello.range.current },
    );
    maybeDelayForTest("FX_TERMINAL_TEST_STARTUP_RECOVERY_DELAY_MS");
    if (io_mod.getenv("FX_TERMINAL_TEST_STARTUP_RECOVERY_FAILURE") != null) {
        return error.TerminalHostStartupRecoveryFailed;
    }
    var persistent_store = try terminal_store.ProfileStore.init(
        alloc,
        home,
        config.process_provider,
    );
    // Both of these are reached by detached client threads through `state` and
    // `registry`, so they may only be torn down once those threads are gone.
    // On a path that exits with clients still live, leaving them allocated is
    // strictly safer than freeing memory another thread is still reading; the
    // process is on its way out and the OS reclaims it.
    var clients_drained = false;
    defer if (clients_drained) persistent_store.deinit();
    var registry = try native_session.Registry.init(alloc, .{
        .context = &state,
        .update_fn = updateLiveWork,
    }, &persistent_store, &host_instance, paths.authority_root_path, paths.transport_root_path);
    defer if (clients_drained) registry.deinit();
    defer {
        clients_drained = drainConnectedClients(&state, client_drain_timeout_ms);
        if (!clients_drained) {
            debug_trace.logf(
                "terminal_host",
                "host exiting immediately with {d} client thread(s) still running; preserving shared state until process exit",
                .{state.connected_clients.load(.acquire)},
            );
            // The registry cannot be freed while detached clients still hold
            // pointers into this frame. Signal its child processes, then stop
            // this dedicated host process before returning through the stack or
            // deinitializing the threaded I/O runtime that those clients use.
            // The next host startup removes the stale endpoint and identity.
            registry.shutdownSessionsOnly();
            std.process.exit(1);
        }
    }
    defer if (!accept_joined) {
        state.stopping.store(true, .release);
        state.changed.set(io_mod.getIo());
        startup.ready.set(io_mod.getIo());
        accept_thread.join();
        accept_joined = true;
    };
    startup.registry = &registry;
    startup.ready.set(io_mod.getIo());
    startup_complete = true;
    var idle_thread = try std.Thread.spawn(.{}, idleOwner, .{&state});
    defer {
        state.stopping.store(true, .release);
        state.changed.set(io_mod.getIo());
        idle_thread.join();
    }

    debug_trace.logf("terminal_host", "host recovery ready", .{});
    accept_thread.join();
    accept_joined = true;
    if (startup.accept_failed.load(.acquire)) {
        return error.HostAcceptFailed;
    }

    debug_trace.logf("terminal_host", "host retiring idle=true", .{});
    maybeDelayForTest("FX_TERMINAL_TEST_IDLE_EXIT_DELAY_MS");
    identity_created = false;
    cleanupIdentity(&paths.host_dir);
    endpoint_created = false;
    cleanupEndpoint(paths.endpointDir());
    debug_trace.logf("terminal_host", "host exited idle=true", .{});
}

/// How long a fatal host exit waits for client threads before giving up on
/// freeing the state they share. Long enough for a client mid-request to
/// finish, short enough that a broken host still exits.
const client_drain_timeout_ms: u64 = 2_000;

const HostState = struct {
    idle_grace_ms: u64,
    connected_clients: std.atomic.Value(usize) = .init(0),
    pending_requests: std.atomic.Value(usize) = .init(0),
    live_work: std.atomic.Value(usize) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    changed: std.Io.Event = .unset,
    ordered_mutex: std.Io.Mutex = .init,
    ordered_changed: std.Io.Condition = .init,
    next_ordered_ticket: u64 = 0,
    serving_ordered_ticket: u64 = 0,

    fn facts(self: *const HostState) policy.IdleFacts {
        return .{
            .connected_clients = self.connected_clients.load(.acquire),
            .pending_requests = self.pending_requests.load(.acquire),
            .live_work = self.live_work.load(.acquire),
        };
    }

    fn noteChanged(self: *HostState) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.changed.set(io_mod.getIo());
    }

    fn issueOrderedMutation(self: *HostState) u64 {
        const zio = io_mod.getIo();
        self.ordered_mutex.lockUncancelable(zio);
        defer self.ordered_mutex.unlock(zio);
        const ticket = self.next_ordered_ticket;
        self.next_ordered_ticket += 1;
        return ticket;
    }

    fn awaitOrderedMutation(self: *HostState, ticket: u64) void {
        const zio = io_mod.getIo();
        self.ordered_mutex.lockUncancelable(zio);
        while (self.serving_ordered_ticket != ticket) {
            self.ordered_changed.waitUncancelable(zio, &self.ordered_mutex);
        }
        self.ordered_mutex.unlock(zio);
    }

    fn completeOrderedMutation(self: *HostState, ticket: u64) void {
        const zio = io_mod.getIo();
        self.ordered_mutex.lockUncancelable(zio);
        std.debug.assert(self.serving_ordered_ticket == ticket);
        self.serving_ordered_ticket += 1;
        self.ordered_changed.broadcast(zio);
        self.ordered_mutex.unlock(zio);
    }

    fn abandonOrderedMutation(self: *HostState, ticket: u64) void {
        self.awaitOrderedMutation(ticket);
        self.completeOrderedMutation(ticket);
    }
};

const HostStartup = struct {
    ready: std.Io.Event = .unset,
    registry: ?*native_session.Registry = null,
    accept_failed: std.atomic.Value(bool) = .init(false),
};

fn acceptLoop(
    alloc: Allocator,
    server: *std.Io.net.Server,
    process_provider: process_provider_mod.Provider,
    hello: contracts.ProtocolHello,
    state: *HostState,
    startup: *HostStartup,
) void {
    while (!state.stopping.load(.acquire)) {
        if (testAcceptFailureRequested()) {
            startup.accept_failed.store(true, .release);
            state.stopping.store(true, .release);
            return;
        }
        if (!(listenerReady(server.socket.handle) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "host listener failed err={s}",
                .{@errorName(err)},
            );
            startup.accept_failed.store(true, .release);
            state.stopping.store(true, .release);
            return;
        })) continue;
        if (state.stopping.load(.acquire)) break;
        var stream = server.accept(io_mod.getIo()) catch |err| switch (err) {
            error.SocketNotListening => break,
            else => {
                debug_trace.logf(
                    "terminal_host",
                    "host accept failed err={s}",
                    .{@errorName(err)},
                );
                startup.accept_failed.store(true, .release);
                state.stopping.store(true, .release);
                return;
            },
        };
        if (state.stopping.load(.acquire)) {
            stream.close(io_mod.getIo());
            break;
        }
        _ = state.connected_clients.fetchAdd(1, .acq_rel);
        state.noteChanged();
        var thread = std.Thread.spawn(.{}, clientMain, .{
            alloc,
            stream,
            process_provider,
            hello,
            state,
            startup,
        }) catch |err| {
            stream.close(io_mod.getIo());
            _ = state.connected_clients.fetchSub(1, .acq_rel);
            state.noteChanged();
            debug_trace.logf(
                "terminal_host",
                "host client thread failed err={s}",
                .{@errorName(err)},
            );
            continue;
        };
        thread.detach();
    }
}

fn updateLiveWork(raw: ?*anyopaque, live: bool) void {
    const state: *HostState = @ptrCast(@alignCast(raw.?));
    if (live) {
        _ = state.live_work.fetchAdd(1, .acq_rel);
    } else {
        const previous = state.live_work.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
    }
    state.noteChanged();
}

/// Waits for every client thread to leave before the host frame that owns their
/// shared state is destroyed. Client threads are detached and hold pointers to
/// `HostState` and the session registry, so freeing either while one is still
/// running is a use-after-free.
///
/// Bounded on purpose: a client parked in `readFrame` does not observe `stopping`
/// until its peer speaks or disconnects, and a fatal host path must not hang
/// waiting for it. Returns whether the drain completed; the caller keeps the
/// shared state alive when it did not.
fn drainConnectedClients(state: *HostState, timeout_ms: u64) bool {
    state.stopping.store(true, .release);
    state.noteChanged();

    const poll_ns: u64 = 5 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const limit_ns = std.math.mul(u64, timeout_ms, std.time.ns_per_ms) catch
        std.math.maxInt(u64);
    while (true) {
        if (state.connected_clients.load(.acquire) == 0) return true;
        if (waited_ns >= limit_ns) return false;
        std.Io.sleep(
            io_mod.getIo(),
            .{ .nanoseconds = @intCast(@min(poll_ns, limit_ns - waited_ns)) },
            .awake,
        ) catch return state.connected_clients.load(.acquire) == 0;
        waited_ns += poll_ns;
    }
}

fn idleOwner(state: *HostState) void {
    const timeout_ns = std.math.mul(u64, state.idle_grace_ms, std.time.ns_per_ms) catch
        std.math.maxInt(u64);
    while (!state.stopping.load(.acquire)) {
        const generation = state.generation.load(.acquire);
        state.changed.reset();
        if (state.generation.load(.acquire) != generation) continue;
        if (!policy.idleEligible(state.facts())) {
            state.changed.waitUncancelable(io_mod.getIo());
            continue;
        }
        state.changed.waitTimeout(
            io_mod.getIo(),
            .{ .duration = .{
                .clock = .awake,
                .raw = .{ .nanoseconds = @intCast(@min(
                    timeout_ns,
                    std.math.maxInt(i64),
                )) },
            } },
        ) catch |err| switch (err) {
            error.Timeout => {
                if (state.generation.load(.acquire) != generation) continue;
                if (!policy.idleEligible(state.facts())) continue;
                state.stopping.store(true, .release);
                return;
            },
            error.Canceled => return,
        };
    }
}

fn listenerReady(handle: std.Io.net.Socket.Handle) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&poll_fds, listener_poll_ms) == 0) return false;
    if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) return true;
    return error.SocketNotListening;
}

fn clientMain(
    alloc: Allocator,
    stream: std.Io.net.Stream,
    process_provider: process_provider_mod.Provider,
    host_hello: contracts.ProtocolHello,
    state: *HostState,
    startup: *HostStartup,
) void {
    defer {
        _ = state.connected_clients.fetchSub(1, .acq_rel);
        state.noteChanged();
    }
    handleClient(
        alloc,
        stream,
        process_provider,
        host_hello,
        state,
        startup,
    ) catch |err| {
        debug_trace.logf(
            "terminal_host",
            "client disconnected err={s}",
            .{@errorName(err)},
        );
    };
}

fn handleClient(
    alloc: Allocator,
    stream: std.Io.net.Stream,
    process_provider: process_provider_mod.Provider,
    host_hello: contracts.ProtocolHello,
    state: *HostState,
    startup: *HostStartup,
) !void {
    defer stream.close(io_mod.getIo());
    if (!peerMatchesCurrentUser(stream.socket.handle)) {
        return error.ForeignTerminalHostPeer;
    }
    const peer_process_owner = try peerProcessOwner(
        alloc,
        process_provider,
        stream.socket.handle,
    );
    applySocketTimeout(stream);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &write_buffer);

    var client_frame = try protocol.readFrame(alloc, &reader.interface);
    defer client_frame.deinit();
    const client_message = client_frame.message();
    const client_hello = switch (client_message.payload) {
        .hello => |hello| hello,
        else => return error.HandshakeRequired,
    };
    const negotiation = try contracts.negotiate_protocol(client_hello, host_hello);
    const reply_revision = switch (negotiation) {
        .compatible => |compatible| compatible.revision,
        .incompatible => @min(
            contracts.current_protocol_revision,
            client_message.envelope.revision,
        ),
    };
    var hello_frame = try protocol.encodeFrame(
        alloc,
        reply_revision,
        0,
        null,
        .{ .hello = host_hello },
    );
    defer hello_frame.deinit(alloc);
    try protocol.writeFrame(&writer.interface, hello_frame);

    const negotiated = switch (negotiation) {
        .compatible => |compatible| compatible,
        .incompatible => return,
    };
    startup.ready.waitUncancelable(io_mod.getIo());
    const registry = startup.registry orelse return error.TerminalHostStartupFailed;

    var connection = Connection{
        .alloc = alloc,
        .stream = stream,
        .revision = negotiated.revision,
        .capabilities = negotiated.capabilities,
        .state = state,
        .registry = registry,
        .peer_process_owner = peer_process_owner,
    };
    defer connection.finish();
    var seen: policy.PendingRequests = .{};
    while (!state.stopping.load(.acquire)) {
        var frame = protocol.readFrame(alloc, &reader.interface) catch |err| switch (err) {
            error.TruncatedFrame, error.EndOfStream => return,
            else => return err,
        };
        defer frame.deinit();
        const message = frame.message();
        if (message.envelope.revision != negotiated.revision) {
            return error.ProtocolRevisionChanged;
        }
        switch (message.payload) {
            .request => |request| {
                const correlation_id = message.envelope.correlation_id.?;
                try seen.add(correlation_id);
                const authority_capability =
                    contracts.protocol_capability_authority_generations;
                const tmux_recovery_capability =
                    contracts.protocol_capability_tmux_recovery;
                const rejection: ?contracts.StructuredErrorCode = if (message.envelope.required_capabilities & authority_capability == 0)
                    .protocol_incompatible
                else if (message.envelope.required_capabilities &
                    ~negotiated.capabilities != 0)
                    .unsupported_host
                else if (request == .start and
                    request.start.backend == .tmux and
                    negotiated.capabilities & tmux_recovery_capability == 0)
                    .protocol_incompatible
                else
                    null;
                try connection.start(
                    correlation_id,
                    request,
                    rejection,
                );
            },
            .cancel => {
                const correlation_id = message.envelope.correlation_id.?;
                connection.cancel(correlation_id);
            },
            .hello, .response => return error.InvalidClientMessage,
        }
    }
}

const Connection = struct {
    alloc: Allocator,
    stream: std.Io.net.Stream,
    revision: u16,
    capabilities: u64,
    state: *HostState,
    registry: *native_session.Registry,
    peer_process_owner: contracts.ProcessOwner,
    mutex: std.Io.Mutex = .init,
    done: std.Io.Condition = .init,
    writer_mutex: std.Io.Mutex = .init,
    tasks: [max_connection_requests]?*RequestTask = @splat(null),
    active: usize = 0,

    fn start(
        self: *Connection,
        correlation_id: contracts.CorrelationId,
        request: contracts.ActionRequest,
        rejection: ?contracts.StructuredErrorCode,
    ) !void {
        if (testRequestFailureRequested("task_allocation", correlation_id)) {
            return error.OutOfMemory;
        }
        const task = try self.alloc.create(RequestTask);
        var owned_request = contracts.OwnedActionRequest.init(
            self.alloc,
            request,
        ) catch |err| {
            self.alloc.destroy(task);
            return err;
        };
        terminal_operation.attachProcessOwner(
            &owned_request.value,
            self.peer_process_owner,
        );
        task.* = .{
            .connection = self,
            .correlation_id = correlation_id,
            .request = owned_request,
            .rejection = rejection,
        };

        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const slot = for (&self.tasks, 0..) |*entry, index| {
            if (entry.* == null) break index;
        } else {
            self.mutex.unlock(zio);
            task.request.deinit(self.alloc);
            self.alloc.destroy(task);
            return error.CapacityExceeded;
        };
        self.tasks[slot] = task;
        task.slot = slot;
        if (terminal_operation.requiresOrderedMutation(task.request.value)) {
            task.ordered_ticket = self.state.issueOrderedMutation();
        }
        self.active += 1;
        _ = self.state.pending_requests.fetchAdd(1, .acq_rel);
        self.state.noteChanged();
        self.mutex.unlock(zio);

        if (testRequestFailureRequested("worker_start", correlation_id)) {
            if (task.ordered_ticket) |ticket| {
                self.state.abandonOrderedMutation(ticket);
            }
            self.complete(task);
            task.request.deinit(self.alloc);
            self.alloc.destroy(task);
            return error.ThreadQuotaExceeded;
        }
        var thread = std.Thread.spawn(.{}, RequestTask.run, .{task}) catch |err| {
            if (task.ordered_ticket) |ticket| {
                self.state.abandonOrderedMutation(ticket);
            }
            self.complete(task);
            task.request.deinit(self.alloc);
            self.alloc.destroy(task);
            return err;
        };
        thread.detach();
    }

    fn cancel(
        self: *Connection,
        correlation_id: contracts.CorrelationId,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.tasks) |entry| {
            const task = entry orelse continue;
            if (task.correlation_id.value == correlation_id.value) {
                task.cancelled.store(true, .release);
                return;
            }
        }
    }

    fn finish(self: *Connection) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        for (self.tasks) |entry| {
            const task = entry orelse continue;
            task.cancelled.store(true, .release);
        }
        while (self.active != 0) {
            self.done.waitUncancelable(zio, &self.mutex);
        }
        self.mutex.unlock(zio);
    }

    fn complete(self: *Connection, task: *RequestTask) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        std.debug.assert(self.tasks[task.slot] == task);
        self.tasks[task.slot] = null;
        self.active -= 1;
        _ = self.state.pending_requests.fetchSub(1, .acq_rel);
        self.state.noteChanged();
        self.done.broadcast(zio);
        self.mutex.unlock(zio);
    }

    fn fail(self: *Connection) void {
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
    }

    fn send(
        self: *Connection,
        correlation_id: contracts.CorrelationId,
        result: contracts.Result,
    ) !void {
        if (testRequestFailureRequested("response_encoding", correlation_id)) {
            return error.OutOfMemory;
        }
        const compatible_result = protocol.projectResultForCapabilities(
            result,
            self.capabilities,
        );
        var frame = try protocol.encodeFrame(
            self.alloc,
            self.revision,
            0,
            correlation_id,
            .{ .response = compatible_result },
        );
        defer frame.deinit(self.alloc);
        const zio = io_mod.getIo();
        self.writer_mutex.lockUncancelable(zio);
        defer self.writer_mutex.unlock(zio);
        var write_buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(zio, &write_buffer);
        if (testRequestFailureRequested("response_write", correlation_id)) {
            return error.WriteFailed;
        }
        try protocol.writeFrame(&writer.interface, frame);
    }
};

const RequestTask = struct {
    connection: *Connection,
    correlation_id: contracts.CorrelationId,
    request: contracts.OwnedActionRequest,
    rejection: ?contracts.StructuredErrorCode,
    slot: usize = 0,
    ordered_ticket: ?u64 = null,
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *RequestTask) void {
        var response_sent = false;
        var cancellation_persisted = false;
        defer {
            self.connection.complete(self);
            self.request.deinit(self.connection.alloc);
            self.connection.alloc.destroy(self);
        }
        defer if (self.ordered_ticket) |ticket| {
            self.connection.state.completeOrderedMutation(ticket);
        };
        if (self.ordered_ticket) |ticket| {
            noteTestOrderedAdmission(self.correlation_id) catch {
                self.connection.state.awaitOrderedMutation(ticket);
                self.connection.fail();
                return;
            };
            self.connection.state.awaitOrderedMutation(ticket);
            awaitTestOrderedBoundary(self.correlation_id, &self.cancelled) catch {
                self.connection.fail();
                return;
            };
        }
        defer if (!response_sent and !cancellation_persisted and
            self.rejection == null and
            self.cancelled.load(.acquire))
        {
            self.persistCancellation() catch |err| {
                self.logCancellationFailure(err);
                self.connection.fail();
            };
        };
        if (self.cancelled.load(.acquire)) return;
        if (testRequestFailureRequested("result_allocation", self.correlation_id)) {
            self.connection.fail();
            return;
        }
        var result = if (self.rejection) |code|
            contracts.OwnedResult.init(
                self.connection.alloc,
                .{ .failure = .{
                    .action = self.request.value.action(),
                    .code = code,
                } },
            ) catch {
                self.connection.fail();
                return;
            }
        else
            self.execute() catch |err| switch (err) {
                error.MissingTerminalAuthority,
                error.InvalidAuthorityClaim,
                error.InvalidAuthorityGeneration,
                error.InvalidPrincipal,
                => contracts.OwnedResult.init(
                    self.connection.alloc,
                    .{ .failure = .{
                        .action = self.request.value.action(),
                        .code = .authority_denied,
                    } },
                ) catch {
                    self.connection.fail();
                    return;
                },
                else => {
                    debug_trace.logf(
                        "terminal_host",
                        "request execution failed action={s} err={s}",
                        .{
                            @tagName(self.request.value.action()),
                            @errorName(err),
                        },
                    );
                    self.connection.fail();
                    return;
                },
            };
        if (self.rejection == null and self.cancelled.load(.acquire)) {
            cancellation_persisted = true;
            self.persistCancellation() catch |err| {
                self.logCancellationFailure(err);
                result.deinit(self.connection.alloc);
                result = contracts.OwnedResult.init(
                    self.connection.alloc,
                    .{ .failure = .{
                        .action = self.request.value.action(),
                        .code = .invalid_request,
                        .session_id = terminal_operation.authoritySessionId(
                            self.request.value,
                        ),
                    } },
                ) catch {
                    self.connection.fail();
                    return;
                };
            };
        }
        defer result.deinit(self.connection.alloc);
        self.connection.send(self.correlation_id, result.view()) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "response failed correlation={d} err={s}",
                .{ self.correlation_id.value, @errorName(err) },
            );
            self.connection.fail();
            return;
        };
        response_sent = true;
    }

    fn execute(self: *RequestTask) !contracts.OwnedResult {
        if (testRequestFailureRequested("operation_execution", self.correlation_id)) {
            return error.RequestExecutionFailed;
        }
        return terminal_operation.execute(
            self.connection.registry,
            self.request.value,
            &self.cancelled,
        );
    }

    fn persistCancellation(self: *RequestTask) !void {
        const request = self.request.value;
        const claim = terminal_operation.claim(request) orelse return;
        const session_id = terminal_operation.authoritySessionId(request) orelse return;
        try self.connection.registry.cancelAuthorized(session_id, claim);
    }

    fn logCancellationFailure(self: *RequestTask, err: anyerror) void {
        const session_id = terminal_operation.authoritySessionId(
            self.request.value,
        ) orelse "none";
        debug_trace.logf(
            "terminal_host",
            "cancellation persistence failed correlation={d} session={s} err={s}",
            .{ self.correlation_id.value, session_id, @errorName(err) },
        );
    }
};

fn testRequestFailureRequested(
    point: []const u8,
    correlation_id: contracts.CorrelationId,
) bool {
    const requested_point = io_mod.getenv("FX_TERMINAL_TEST_HOST_FAILURE_POINT") orelse
        return false;
    if (!std.mem.eql(u8, requested_point, point)) return false;
    const requested_correlation = io_mod.getenv(
        "FX_TERMINAL_TEST_HOST_FAILURE_CORRELATION",
    ) orelse return false;
    const value = std.fmt.parseInt(u64, requested_correlation, 10) catch return false;
    return value == correlation_id.value;
}

fn maybeDelayForTest(name: []const u8) void {
    const value = io_mod.getenv(name) orelse return;
    const delay_ms = std.fmt.parseInt(u64, value, 10) catch return;
    const delay_ns = std.math.mul(
        u64,
        @min(delay_ms, 5_000),
        std.time.ns_per_ms,
    ) catch return;
    io_mod.sleep(delay_ns);
}

fn testAcceptFailureRequested() bool {
    const path = io_mod.getenv("FX_TERMINAL_TEST_ACCEPT_FAILURE_PATH") orelse
        return false;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn noteTestOrderedAdmission(correlation_id: contracts.CorrelationId) !void {
    const prefix = io_mod.getenv("FX_TERMINAL_TEST_ORDER_BARRIER") orelse return;
    var path_buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}.{d}.admitted",
        .{ prefix, correlation_id.value },
    );
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{});
    file.close(io_mod.getIo());
}

fn awaitTestOrderedBoundary(
    correlation_id: contracts.CorrelationId,
    cancelled: *const std.atomic.Value(bool),
) !void {
    const prefix = io_mod.getenv("FX_TERMINAL_TEST_ORDER_BARRIER") orelse return;
    const first_target = testCorrelationFromEnvironment(
        "FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION",
    );
    const second_target = testCorrelationFromEnvironment(
        "FX_TERMINAL_TEST_ORDER_HOLD_CORRELATION_2",
    );
    if ((first_target == null or first_target.? != correlation_id.value) and
        (second_target == null or second_target.? != correlation_id.value))
    {
        return;
    }

    var ready_buffer: [4096]u8 = undefined;
    const ready_path = try std.fmt.bufPrint(
        &ready_buffer,
        "{s}.{d}.ready",
        .{ prefix, correlation_id.value },
    );
    var ready = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        ready_path,
        .{},
    );
    ready.close(io_mod.getIo());

    var release_buffer: [4096]u8 = undefined;
    const release_path = try std.fmt.bufPrint(
        &release_buffer,
        "{s}.{d}.release",
        .{ prefix, correlation_id.value },
    );
    while (!cancelled.load(.acquire)) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), release_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                io_mod.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn testCorrelationFromEnvironment(name: []const u8) ?u64 {
    const text = io_mod.getenv(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn applySocketTimeout(stream: std.Io.net.Stream) void {
    if (comptime !isSupported()) return;
    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
}

fn peerMatchesCurrentUser(handle: std.Io.net.Socket.Handle) bool {
    if (comptime builtin.os.tag == .macos) {
        var peer_uid: std.c.uid_t = undefined;
        var peer_gid: std.c.gid_t = undefined;
        const Peer = struct {
            extern "c" fn getpeereid(
                socket: std.c.fd_t,
                effective_uid: *std.c.uid_t,
                effective_gid: *std.c.gid_t,
            ) c_int;
        };
        if (Peer.getpeereid(handle, &peer_uid, &peer_gid) != 0) return false;
        return peer_uid == std.c.getuid();
    }
    if (comptime builtin.os.tag == .linux) {
        const UCred = extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        };
        var credentials: UCred = undefined;
        var credentials_len: std.c.socklen_t = @sizeOf(UCred);
        if (std.c.getsockopt(
            handle,
            std.c.SOL.SOCKET,
            std.c.SO.PEERCRED,
            &credentials,
            &credentials_len,
        ) != 0) return false;
        return credentials_len == @sizeOf(UCred) and
            credentials.uid == std.c.getuid();
    }
    return false;
}

fn peerProcessOwner(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    handle: std.Io.net.Socket.Handle,
) !contracts.ProcessOwner {
    const pid: std.c.pid_t = if (comptime builtin.os.tag == .macos) blk: {
        const local_peer_pid = 0x002;
        var peer_pid: std.c.pid_t = undefined;
        var peer_pid_len: std.c.socklen_t = @sizeOf(std.c.pid_t);
        if (std.c.getsockopt(
            handle,
            0,
            local_peer_pid,
            &peer_pid,
            &peer_pid_len,
        ) != 0 or peer_pid_len != @sizeOf(std.c.pid_t)) {
            return error.TerminalPeerIdentityUnavailable;
        }
        break :blk peer_pid;
    } else if (comptime builtin.os.tag == .linux) blk: {
        const UCred = extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        };
        var credentials: UCred = undefined;
        var credentials_len: std.c.socklen_t = @sizeOf(UCred);
        if (std.c.getsockopt(
            handle,
            std.c.SOL.SOCKET,
            std.c.SO.PEERCRED,
            &credentials,
            &credentials_len,
        ) != 0 or credentials_len != @sizeOf(UCred)) {
            return error.TerminalPeerIdentityUnavailable;
        }
        break :blk credentials.pid;
    } else return error.TerminalHostUnsupported;

    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const token = try process_provider.captureToken(
        alloc,
        pid_text,
    );
    return contracts.ProcessOwner.init(@intCast(pid), token.view());
}

fn writeIdentity(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    host_dir: *io_mod.VerifiedDir,
    range: contracts.ProtocolRange,
    instance: []const u8,
) !void {
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()});
    const process_token = try process_provider.captureToken(
        alloc,
        pid,
    );
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(IdentityRecord{
        .pid = pid,
        .process_token = process_token.view(),
        .instance = instance,
        .protocol_minimum = range.minimum,
        .protocol_current = range.current,
    }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.durableReplaceVerified(
        alloc,
        host_dir,
        identity_name,
        out.written(),
    );
}

pub fn identityEvidence(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    host_dir: *io_mod.VerifiedDir,
) policy.IdentityEvidence {
    var file = host_dir.dir.openFile(io_mod.getIo(), identity_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return .unverifiable,
    };
    defer file.close(io_mod.getIo());
    var read_buffer: [identity_max_bytes]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &read_buffer);
    const bytes = reader.interface.allocRemaining(
        alloc,
        .limited(identity_max_bytes),
    ) catch return .unverifiable;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        IdentityRecord,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch return .unverifiable;
    defer parsed.deinit();
    const token = process_identity.ProcessInstanceToken.parse(
        parsed.value.process_token,
    ) catch return .unverifiable;
    return switch (process_provider.matchToken(
        alloc,
        parsed.value.pid,
        token,
    )) {
        .matched => .live,
        .missing, .mismatched => .dead,
        .unavailable => .unverifiable,
    };
}

/// The caller must hold `host.lock` and must have classified the identity as
/// absent or dead. This keeps destructive stale cleanup behind both proofs.
pub fn removeStaleArtifacts(
    host_dir: *io_mod.VerifiedDir,
    endpoint_dir: *io_mod.VerifiedDir,
) void {
    cleanupEndpoint(endpoint_dir);
    cleanupIdentity(host_dir);
}

fn cleanupEndpoint(host_dir: *io_mod.VerifiedDir) void {
    const stat = host_dir.dir.statFile(
        io_mod.getIo(),
        endpoint_name,
        .{ .follow_symlinks = false },
    ) catch return;
    if (stat.kind != .unix_domain_socket) return;
    host_dir.dir.deleteFile(io_mod.getIo(), endpoint_name) catch {};
}

fn cleanupIdentity(host_dir: *io_mod.VerifiedDir) void {
    const stat = host_dir.dir.statFile(
        io_mod.getIo(),
        identity_name,
        .{ .follow_symlinks = false },
    ) catch return;
    if (stat.kind != .file or stat.nlink != 1) return;
    host_dir.dir.deleteFile(io_mod.getIo(), identity_name) catch {};
}

fn verifyEndpointPermissions(host_dir: *io_mod.VerifiedDir) !void {
    const stat = try host_dir.dir.statFile(
        io_mod.getIo(),
        endpoint_name,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .unix_domain_socket or
        stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.PrivateEndpointPermissionsUnsupported;
    }
}

test "hidden host mode is exact and remains private" {
    const exact = [_][*:0]const u8{ "fx", internal_mode };
    try std.testing.expect(isInternalModeRaw(&exact));
    const public_like = [_][*:0]const u8{ "fx", "terminal-host" };
    try std.testing.expect(!isInternalModeRaw(&public_like));
    const extra = [_][*:0]const u8{ "fx", internal_mode, "extra" };
    try std.testing.expect(!isInternalModeRaw(&extra));
}

test "terminal host selection follows canonical platform support" {
    const os_tags = [_]std.Target.Os.Tag{
        .macos,
        .linux,
        .windows,
        .wasi,
        .freebsd,
        .emscripten,
    };
    for (os_tags) |os_tag| {
        try std.testing.expectEqual(
            host_capabilities.terminalSupportForOs(os_tag).isSupported(),
            isSupportedForOs(os_tag),
        );
    }
    try std.testing.expectEqual(isSupportedForOs(builtin.os.tag), isSupported());
}

test "terminal host file descriptor target is bounded by the hard limit" {
    try std.testing.expectEqual(
        @as(?u64, desired_file_descriptor_limit),
        fileDescriptorLimitTarget(256, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        @as(?u64, 512),
        fileDescriptorLimitTarget(256, 512),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        fileDescriptorLimitTarget(desired_file_descriptor_limit, 4096),
    );
}

test "host identity capture and reconciliation use the injected provider" {
    const Fake = struct {
        captures: usize = 0,
        matches: usize = 0,
        match_result: process_identity.TokenMatch = .matched,

        fn provider(self: *@This()) process_provider_mod.Provider {
            return .{
                .context = self,
                .capture_token_fn = captureToken,
                .match_token_fn = matchToken,
                .signal_process_fn = signalProcess,
            };
        }

        fn captureToken(
            raw: ?*anyopaque,
            _: Allocator,
            _: []const u8,
        ) process_provider_mod.ProviderError!process_identity.ProcessInstanceToken {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.captures += 1;
            return process_identity.ProcessInstanceToken.parse(
                "macos:00000000000000000000000000000000:1:2",
            ) catch unreachable;
        }

        fn matchToken(
            raw: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            _: process_identity.ProcessInstanceToken,
        ) process_identity.TokenMatch {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.matches += 1;
            return self.match_result;
        }

        fn signalProcess(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            _: process_identity.ProcessInstanceToken,
        ) process_provider_mod.ProviderError!void {
            return error.Unsupported;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var host_dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer host_dir.close();

    var fake = Fake{};
    try writeIdentity(
        std.testing.allocator,
        fake.provider(),
        &host_dir,
        contracts.local_protocol_range,
        "test-instance",
    );
    try std.testing.expectEqual(@as(usize, 1), fake.captures);

    try std.testing.expectEqual(
        policy.IdentityEvidence.live,
        identityEvidence(std.testing.allocator, fake.provider(), &host_dir),
    );
    fake.match_result = .unavailable;
    try std.testing.expectEqual(
        policy.IdentityEvidence.unverifiable,
        identityEvidence(std.testing.allocator, fake.provider(), &host_dir),
    );
    fake.match_result = .missing;
    try std.testing.expectEqual(
        policy.IdentityEvidence.dead,
        identityEvidence(std.testing.allocator, fake.provider(), &host_dir),
    );
    fake.match_result = .mismatched;
    try std.testing.expectEqual(
        policy.IdentityEvidence.dead,
        identityEvidence(std.testing.allocator, fake.provider(), &host_dir),
    );
    try std.testing.expectEqual(@as(usize, 4), fake.matches);
    try std.testing.expectError(
        error.Unsupported,
        writeIdentity(
            std.testing.allocator,
            process_provider_mod.unavailable_provider,
            &host_dir,
            contracts.local_protocol_range,
            "test-instance",
        ),
    );
}

test "endpoint paths honor the native sockaddr capacity" {
    if (!isSupported()) return error.SkipZigTest;
    const path_limit = comptime nativeEndpointPathLimit(builtin.os.tag).?;
    var maximum: [path_limit - 1]u8 = @splat('x');
    var oversized: [path_limit]u8 = @splat('x');
    try validateEndpointPath(&maximum);
    try std.testing.expectError(error.NameTooLong, validateEndpointPath(&oversized));
}

test "endpoint selection preserves short homes and deterministically separates long homes" {
    if (!isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const short_home = "/Users/terminal-short";
    var short = try resolveEndpointSelection(
        alloc,
        builtin.os.tag,
        short_home,
        501,
    );
    defer short.deinit(alloc);
    const expected_short = try std.fs.path.join(
        alloc,
        &.{ short_home, profile_paths.root_dir_name, host_dir_name },
    );
    defer alloc.free(expected_short);
    try std.testing.expect(!short.uses_fallback);
    try std.testing.expectEqualStrings(expected_short, short.authority_root);
    try std.testing.expectEqualStrings(short.authority_root, short.transport_root);

    const first_home = "/profiles/" ++ "a" ** 160;
    const second_home = "/profiles/" ++ "b" ** 160;
    var first = try resolveEndpointSelection(
        alloc,
        builtin.os.tag,
        first_home,
        501,
    );
    defer first.deinit(alloc);
    var reopened = try resolveEndpointSelection(
        alloc,
        builtin.os.tag,
        first_home,
        501,
    );
    defer reopened.deinit(alloc);
    var second = try resolveEndpointSelection(
        alloc,
        builtin.os.tag,
        second_home,
        501,
    );
    defer second.deinit(alloc);

    try std.testing.expect(first.uses_fallback);
    try std.testing.expectEqualStrings(first.transport_root, reopened.transport_root);
    try std.testing.expect(!std.mem.eql(u8, first.transport_root, second.transport_root));
    try std.testing.expect(std.mem.find(u8, first.transport_root, first_home) == null);
    try validateEndpointPath(first.endpoint_path);
    try std.testing.expect(std.mem.endsWith(
        u8,
        first.authority_root,
        "/.fx/terminal-host-v7",
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        first.authority_root,
        first.transport_root,
    ));
}

test "endpoint selection allocation and unsupported targets fail closed" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.TerminalHostUnsupported,
        resolveEndpointSelection(alloc, .windows, "C:\\profile", 501),
    );

    const long_home = "/profiles/" ++ "x" ** 160;
    var probe = std.testing.FailingAllocator.init(alloc, .{});
    var selected = try resolveEndpointSelection(
        probe.allocator(),
        .macos,
        long_home,
        501,
    );
    selected.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        if (resolveEndpointSelection(
            failing.allocator(),
            .macos,
            long_home,
            501,
        )) |value| {
            var owned = value;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "runtime transport directories reject symlinks non-private modes and foreign owners" {
    if (!isSupported()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var private = try openVerifiedPrivateRuntimeDir(
        tmp.dir,
        "private",
        std.c.getuid(),
    );
    defer private.close();
    const private_stat = try private.dir.stat(std.testing.io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o700),
        private_stat.permissions.toMode() & 0o777,
    );
    try std.testing.expectError(
        error.RuntimeDirectoryOwnerMismatch,
        validatePrivateRuntimeDir(
            private_stat,
            std.c.getuid() + 1,
            std.c.getuid(),
        ),
    );

    try tmp.dir.createDir(
        std.testing.io,
        "public",
        std.Io.File.Permissions.fromMode(0o755),
    );
    try tmp.dir.setFilePermissions(
        std.testing.io,
        "public",
        std.Io.File.Permissions.fromMode(0o755),
        .{ .follow_symlinks = false },
    );
    const public_stat = try tmp.dir.statFile(
        std.testing.io,
        "public",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o755),
        public_stat.permissions.toMode() & 0o777,
    );
    try std.testing.expectError(
        error.PrivateStatePermissionsUnsupported,
        openVerifiedPrivateRuntimeDir(tmp.dir, "public", std.c.getuid()),
    );

    try tmp.dir.symLink(
        std.testing.io,
        "private",
        "linked",
        .{ .is_directory = true },
    );
    try std.testing.expectError(
        error.RuntimeDirectoryUnsafe,
        openVerifiedPrivateRuntimeDir(tmp.dir, "linked", std.c.getuid()),
    );
}

test "client drain reports success only when every client thread has left" {
    var state = HostState{ .idle_grace_ms = 0 };

    // No clients: the happy path, and it must not wait.
    try std.testing.expect(drainConnectedClients(&state, 50));
    try std.testing.expect(state.stopping.load(.acquire));

    // A client that never leaves: the drain is bounded and reports failure
    // rather than blocking the host forever on a fatal path.
    state.stopping.store(false, .release);
    _ = state.connected_clients.fetchAdd(1, .acq_rel);
    try std.testing.expect(!drainConnectedClients(&state, 50));
    try std.testing.expect(state.stopping.load(.acquire));

    // The same client leaving makes the drain succeed.
    _ = state.connected_clients.fetchSub(1, .acq_rel);
    try std.testing.expect(drainConnectedClients(&state, 50));
}

test "a client that leaves during the drain window still drains" {
    var state = HostState{ .idle_grace_ms = 0 };
    _ = state.connected_clients.fetchAdd(1, .acq_rel);

    const Departing = struct {
        fn run(target: *HostState) void {
            std.Io.sleep(io_mod.getIo(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
            _ = target.connected_clients.fetchSub(1, .acq_rel);
            target.noteChanged();
        }
    };
    var thread = try std.Thread.spawn(.{}, Departing.run, .{&state});
    defer thread.join();

    try std.testing.expect(drainConnectedClients(&state, 2_000));
    try std.testing.expectEqual(@as(usize, 0), state.connected_clients.load(.acquire));
}
