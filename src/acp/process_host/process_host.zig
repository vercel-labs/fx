//! The process host: the state that every connection of one `fx acp` process
//! shares. It outlives each connection's frame. It owns the session store, the
//! leader socket, the table of open sessions, and the runtimes a turn uses
//! whichever connection started it: the model catalog, web fetch, managed
//! executions, lifecycle hooks, and the credential lock. The server reaches the
//! host only through this file (R1.7); the session table beside it is internal.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const acp_runner = @import("../../core/cli/acp_runner.zig");
const host_target = @import("../../core/hosts/target.zig");
const session_adapter = @import("../../core/session/session_adapter.zig");
const gateway_provider = @import("../../core/gateway/gateway_provider.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const web_fetch_runtime = @import("../../core/tooling/web_fetch_runtime.zig");
const mcp_host = @import("../../core/mcp_host/host.zig");
const turn_capture = @import("../../core/workspace/turn_capture.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const leader_mod = @import("../leader.zig");
const session_table = @import("session_table.zig");

const Allocator = std.mem.Allocator;

/// Whether this build can serve a leader socket: native hosts with Unix sockets,
/// the same macOS and Linux set as `host.zig`'s terminal support. WASM has no
/// sockets, so it never gets a leader.
pub const leader_supported = !host_target.is_wasm and (builtin.os.tag == .macos or builtin.os.tag == .linux);

pub const SessionTable = session_table.SessionTable;

/// What a socket connection answers `initialize` with beyond the stdio answer:
/// this process's pid and the sessions it leads.
pub const LeaderInfo = struct {
    pid: i64,
    sessions: leader_mod.SessionList,
};

/// The host for sessions of type `Session`. The server owns that type, so the
/// host is built for it at comptime, and the server names the result.
pub fn ProcessHost(comptime Session: type) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        cfg: acp_runner.Config,
        /// The store the process shares. Null when it did not open (no HOME), and
        /// always null on wasm, which keeps its sessions in the JS host.
        store: ?session_adapter.Store,
        /// The leader socket this process serves while it runs (see `startLeader`
        /// in the server). Stays null on wasm and when the leader did not start.
        leader: ?*leader_mod.Leader = null,
        /// Set with `leader`, for the socket connections that answer `initialize` with it.
        leader_info: ?LeaderInfo = null,
        /// The sessions this process has open, which its connections register,
        /// find and follow.
        shared: SessionTable(Session) = .{},
        /// The model catalog, read by every turn. Held around each use.
        capability_resolver: gateway_provider.CapabilityResolver = .{},
        catalog_mutex: std.Io.Mutex = .init,
        web_fetch_runtime: web_fetch_runtime.Runtime,
        managed_executions: managed_execution.Runtime,
        lifecycle_runtime: hooks.Runtime,
        lifecycle_view: hooks.RuntimeView,
        /// Held while a session's credential is checked, refreshed or replaced. One
        /// lock for the process, so credential changes run one at a time.
        subagent_authority_mutex: std.Io.Mutex = .init,

        /// Builds the host for one process. The store opens here, once, for all
        /// connections. The host is returned by value and is then used by address.
        pub fn open(alloc: Allocator, cfg: acp_runner.Config) Self {
            var lifecycle_runtime = hooks.Runtime.init(alloc);
            const lifecycle_view = lifecycle_runtime.freeze();
            return .{
                .alloc = alloc,
                .cfg = cfg,
                .store = openStore(alloc, cfg),
                .web_fetch_runtime = web_fetch_runtime.Runtime.init(.{}),
                .managed_executions = managed_execution.Runtime.init(alloc),
                .lifecycle_runtime = lifecycle_runtime,
                .lifecycle_view = lifecycle_view,
            };
        }

        /// Ends the process's shared parts. The caller has closed every session, so no
        /// turn or subagent uses them any more. The leader stops before the store is
        /// freed, because its session list reads the store's manager. This is the only
        /// place that frees them, on every exit path, so none outlives the process (R3.9).
        pub fn deinit(self: *Self) void {
            if (comptime leader_supported) {
                if (self.leader) |leader| {
                    leader.stop(io_mod.getIo());
                    self.leader = null;
                }
            }
            // A host `session/load` replaced may still be stopping its servers; they end before this process does.
            if (comptime !host_target.is_wasm) mcp_host.waitRetired();
            // Retention's maintenance, if one runs, ends with the process.
            if (comptime turn_capture.supported) turn_capture.finishMaintenance();
            if (self.store) |*store| store.deinit(self.alloc);
            self.managed_executions.deinit();
            self.lifecycle_runtime.deinit();
            self.web_fetch_runtime.deinit(self.alloc);
            self.capability_resolver.deinit(self.alloc);
            self.shared.deinit(self.alloc);
        }
    };
}

fn openStore(alloc: Allocator, cfg: acp_runner.Config) ?session_adapter.Store {
    if (comptime host_target.is_wasm) return null;
    const opened = if (cfg.home_override) |home|
        session_adapter.Store.open(alloc, home)
    else
        session_adapter.Store.openFromEnv(alloc);
    return opened catch |err| {
        debug_trace.logf("acp", "event=sessions_v2_store_unavailable err={s}", .{@errorName(err)});
        return null;
    };
}
