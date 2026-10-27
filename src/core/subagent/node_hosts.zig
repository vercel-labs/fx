//! The hosts of a tree's nodes below the root (D96). One registry per tree
//! owns every node host: the node's open log, its children, and the host
//! that runs them. A host opens on demand, when the node runs a turn, takes
//! a message, or serves a command, and closes once it is idle past a TTL or
//! the tree holds more open hosts than its cap, least recently used first.
//!
//! Every open host holds a lease on its parent's, so a host never outlives
//! its ancestors, and only a leaf with no lease and no running work closes
//! (`tests/tla/session_manager/NodeHosts.tla` HostsNest, BusyHostsStayOpen).
//! The root host closes the tree: every node's turn stops, then the hosts
//! close deepest first.
//!
//! Lock order: the registry mutex may be taken before a host's own locks,
//! never after. A host closes with the registry unlocked, marked closing so
//! no lease or reader reaches it.
const std = @import("std");
const child_state = @import("child_state.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_adapter = @import("../session/session_adapter.zig");
const tool_host = @import("tool_host.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const idle_env = "PROTO_FX_NODE_HOST_IDLE_MS";
pub const max_open_env = "PROTO_FX_MAX_NODE_HOSTS";

pub const Limits = struct {
    /// How long a host with no lease and no running work stays open.
    /// Zero closes it at the next sweep.
    idle_ms: i64 = 5 * 60 * 1000,
    /// Open hosts one tree keeps before it closes idle ones early.
    max_open: usize = 16,

    pub fn fromEnv() Limits {
        var value: Limits = .{};
        if (io_mod.getenv(idle_env)) |raw| {
            if (std.fmt.parseInt(i64, raw, 10)) |ms| {
                if (ms >= 0) value.idle_ms = ms;
            } else |_| {}
        }
        if (io_mod.getenv(max_open_env)) |raw| {
            if (std.fmt.parseInt(usize, raw, 10)) |count| {
                if (count > 0) value.max_open = @min(count, 256);
            } else |_| {}
        }
        return value;
    }

    /// How often the sweeper looks: often enough to keep a short TTL.
    fn pulseMs(self: Limits) u64 {
        const quarter: u64 = @intCast(@divTrunc(@max(self.idle_ms, 0), 4));
        return std.math.clamp(quarter, 10, 1000);
    }
};

/// Why a lease holds a host open.
pub const Use = enum {
    /// The node's own turn, run by its parent: at most one at a time.
    turn,
    /// A command, a message to one of its children, or a child's host.
    use,
};

pub const LeaseError = error{
    OutOfMemory,
    /// The node has no log yet, so there is nothing to serve.
    NodeUnavailable,
    /// A rewind of an ancestor, or of the node, holds the subtree.
    NodeBusy,
    /// The tree is closing.
    TreeClosed,
    HostUnavailable,
};

pub const Entry = struct {
    id: []u8,
    depth: u8,
    /// Ids from the tree's root down to this node, owned.
    path: [][]u8,
    /// The parent's host entry; null when the parent is the root.
    parent: ?*Entry,
    /// The node's only writable handle in this process.
    session: *session_adapter.Session,
    children: child_state.V2Children,
    runtime: *tool_host.Runtime,
    /// Turns, commands, messages and child hosts holding it open.
    leases: usize = 0,
    turn: bool = false,
    last_used: i64,
    closing: bool = false,

    fn busy(entry: *Entry) bool {
        return entry.turn or !entry.runtime.idle();
    }

    fn inSubtree(entry: *const Entry, id: []const u8) bool {
        for (entry.path) |hop| if (std.mem.eql(u8, hop, id)) return true;
        return false;
    }

    /// Closes the host, its children and its log. The entry itself, its id
    /// and path stay readable until `free`: other threads read a closing
    /// entry under the registry's lock until it leaves the list.
    fn shut(entry: *Entry) void {
        entry.runtime.deinit();
        entry.children.deinit();
        entry.session.close();
    }

    fn free(entry: *Entry, alloc: Allocator) void {
        for (entry.path) |hop| alloc.free(hop);
        alloc.free(entry.path);
        alloc.free(entry.id);
        alloc.destroy(entry);
    }
};

pub const Registry = struct {
    alloc: Allocator,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    entries: std.ArrayList(*Entry) = .empty,
    /// The node a rewind holds: no host at or below it may be leased.
    frozen: ?[]const u8 = null,
    closed: bool = false,
    sweeper: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Hosts opened and closed so far, for tests and diagnostics.
    opened_total: u64 = 0,
    closed_total: u64 = 0,

    pub fn init(alloc: Allocator, limits: Limits) Registry {
        return .{ .alloc = alloc, .limits = limits };
    }

    /// Leases node `id`'s host, a child of `parent`'s node, opening it when
    /// none is open. A `.turn` lease opens the node's log for its work and
    /// takes `instructions`; a `.use` lease serves a node that has a log.
    /// Release with `release` and the same `use`.
    pub fn lease(self: *Registry, parent: *tool_host.Runtime, id: []const u8, use: Use, instructions: []const u8) LeaseError!*Entry {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.closed) return error.TreeClosed;
            const found = self.findLocked(id) orelse break;
            if (found.closing) {
                self.changed.waitUncancelable(io, &self.mutex);
                continue;
            }
            if (self.frozenLocked(found.path)) return error.NodeBusy;
            if (use == .turn) {
                found.session.useInstructions(instructions) catch |err| {
                    debug_trace.logf("subagent", "node instructions kept node_id={s} err={s}", .{ id, @errorName(err) });
                };
                found.turn = true;
            }
            found.leases += 1;
            found.last_used = io_mod.monotonicMilliTimestamp();
            return found;
        }
        const entry = self.openLocked(parent, id, use, instructions) catch |err| {
            debug_trace.logf("subagent", "node host not opened node_id={s} err={s}", .{ id, @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.NodeUnavailable => error.NodeUnavailable,
                error.NodeBusy => error.NodeBusy,
                else => error.HostUnavailable,
            };
        };
        self.startSweeperLocked();
        return entry;
    }

    fn openLocked(self: *Registry, parent: *tool_host.Runtime, id: []const u8, use: Use, instructions: []const u8) !*Entry {
        const alloc = self.alloc;
        const parent_entry = parent.node_entry;
        const depth = parent.depth + 1;
        const store = parent.children.parent.store;
        const path = try alloc.alloc([]u8, parent.node_path.len + 1);
        var built: usize = 0;
        errdefer {
            for (path[0..built]) |hop| alloc.free(hop);
            alloc.free(path);
        }
        for (parent.node_path) |hop| {
            path[built] = try alloc.dupe(u8, hop);
            built += 1;
        }
        path[built] = try alloc.dupe(u8, id);
        built += 1;
        if (self.frozenLocked(path)) return error.NodeBusy;
        // A command or a message serves a node that exists; only its own
        // work starts a log (D34).
        if (use == .use) {
            var peeked = store.manager.peek(alloc, id) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NodeUnavailable,
            };
            peeked.deinit(alloc);
        }
        var seed = (try parent.children.seedFor(alloc, id)) orelse child_state.V2Children.ChildSeed{
            .preferences = try parent.children.parent.currentPreferences(alloc),
            .language = types.ConversationLanguage.default(),
        };
        defer seed.preferences.deinit(alloc);
        const session = try session_adapter.Session.openChild(alloc, store, parent.node_id, id, parent.children.workspace, .{
            .preferences = seed.preferences,
            .language = seed.language,
            .permission_state = .{},
            .instructions = if (use == .turn) instructions else "",
            // Line 1 records the node's place in its tree (D91).
            .node = .{ .root = parent.tree.root_id, .depth = depth },
        });
        errdefer session.close();
        const entry = try alloc.create(Entry);
        errdefer alloc.destroy(entry);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        entry.* = .{
            .id = owned_id,
            .depth = depth,
            .path = path,
            .parent = parent_entry,
            .session = session,
            .children = child_state.V2Children.init(alloc, session, parent.children.workspace),
            .runtime = undefined,
            .leases = 1,
            .turn = use == .turn,
            .last_used = io_mod.monotonicMilliTimestamp(),
        };
        errdefer entry.children.deinit();
        entry.runtime = try parent.openChildHost(entry);
        errdefer entry.runtime.deinit();
        try self.entries.append(alloc, entry);
        // A host holds its parent's open for as long as it is open itself.
        if (parent_entry) |above| above.leases += 1;
        self.opened_total += 1;
        debug_trace.logf("subagent", "node host opened node_id={s} depth={d} open={d}", .{ id, depth, self.entries.items.len });
        return entry;
    }

    /// Gives back one lease. Past the cap, idle hosts close at once.
    pub fn release(self: *Registry, entry: *Entry, use: Use) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        std.debug.assert(entry.leases > 0);
        entry.leases -= 1;
        if (use == .turn) entry.turn = false;
        entry.last_used = io_mod.monotonicMilliTimestamp();
        const over = self.entries.items.len > self.limits.max_open;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
        if (over) self.sweep(io_mod.monotonicMilliTimestamp());
    }

    /// Runs `visit(context, runtime)` on node `id`'s open host, which cannot
    /// close until `visit` returns. Null when no host of it is open.
    pub fn visit(self: *Registry, id: []const u8, comptime R: type, context: anytype, comptime visitFn: fn (@TypeOf(context), *tool_host.Runtime) R) ?R {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.findLocked(id) orelse return null;
        if (entry.closing) return null;
        return visitFn(context, entry.runtime);
    }

    /// Whether node `id`, or any node below it, runs a turn or has work of
    /// its children running, as far as open hosts show. Every running turn
    /// holds its node's host, so a closed host means none runs.
    /// Whether node `id` has an open host now.
    pub fn isOpen(self: *Registry, id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.findLocked(id) orelse return false;
        return !entry.closing;
    }

    pub fn subtreeBusy(self: *Registry, id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.subtreeBusyLocked(id);
    }

    /// Whether any node host of the tree runs work.
    pub fn anyBusy(self: *Registry) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (!entry.closing and entry.busy()) return true;
        return false;
    }

    fn subtreeBusyLocked(self: *Registry, id: []const u8) bool {
        for (self.entries.items) |entry| {
            if (entry.closing or !entry.inSubtree(id)) continue;
            if (entry.busy()) return true;
        }
        return false;
    }

    /// Holds node `id`'s subtree for a rewind: no host at or below it is
    /// leased until `thaw`. False, holding nothing, while any of it runs or
    /// another rewind holds the tree (`tests/tla/session_manager/Rewind.tla`
    /// NoRewindWhileBusy).
    pub fn freeze(self: *Registry, id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.frozen != null or self.subtreeBusyLocked(id)) return false;
        self.frozen = id;
        return true;
    }

    pub fn thaw(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.frozen = null;
        self.changed.broadcast(io_mod.getIo());
    }

    fn frozenLocked(self: *const Registry, path: []const []const u8) bool {
        const held = self.frozen orelse return false;
        for (path) |hop| if (std.mem.eql(u8, hop, held)) return true;
        return false;
    }

    pub fn openCount(self: *Registry) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.entries.items.len;
    }

    /// Points every host at a host context that moved.
    pub fn rebind(self: *Registry, child_runner_context: ?*anyopaque, host_authority: @import("authority.zig").HostResolver) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (!entry.closing) entry.runtime.rebindHost(child_runner_context, host_authority);
    }

    fn findLocked(self: *Registry, id: []const u8) ?*Entry {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    /// Closes every closable host idle past the TTL, then the least recently
    /// used closable ones while more than the cap are open. A closable host
    /// has no lease, so no open child host, and no running work.
    pub fn sweep(self: *Registry, now: i64) void {
        const io = io_mod.getIo();
        var victims: std.ArrayList(*Entry) = .empty;
        defer victims.deinit(self.alloc);
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            var open: usize = 0;
            for (self.entries.items) |entry| {
                if (!entry.closing) open += 1;
            }
            for (self.entries.items) |entry| {
                if (!self.closableLocked(entry)) continue;
                if (now - entry.last_used < self.limits.idle_ms) continue;
                victims.append(self.alloc, entry) catch break;
                entry.closing = true;
                open -= 1;
            }
            while (open > self.limits.max_open) {
                var oldest: ?*Entry = null;
                for (self.entries.items) |entry| {
                    if (!self.closableLocked(entry)) continue;
                    if (oldest == null or entry.last_used < oldest.?.last_used) oldest = entry;
                }
                const victim = oldest orelse break;
                victims.append(self.alloc, victim) catch break;
                victim.closing = true;
                open -= 1;
            }
        }
        for (victims.items) |entry| self.close(entry);
    }

    fn closableLocked(self: *const Registry, entry: *Entry) bool {
        _ = self;
        return !entry.closing and entry.leases == 0 and !entry.busy();
    }

    /// Closes `entry`, already marked closing, with the registry unlocked.
    fn close(self: *Registry, entry: *Entry) void {
        const io = io_mod.getIo();
        debug_trace.logf("subagent", "node host closed node_id={s} depth={d}", .{ entry.id, entry.depth });
        const parent = entry.parent;
        // The host joins whatever its children left; none runs.
        entry.shut();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items, 0..) |candidate, index| if (candidate == entry) {
            _ = self.entries.swapRemove(index);
            break;
        };
        // Freed only once no reader can reach it: a concurrent sweep reads
        // `closing` of every listed entry.
        entry.free(self.alloc);
        if (parent) |above| {
            above.leases -= 1;
            above.last_used = io_mod.monotonicMilliTimestamp();
        }
        self.closed_total += 1;
        self.changed.broadcast(io);
    }

    fn startSweeperLocked(self: *Registry) void {
        if (self.sweeper != null or self.stopping.load(.acquire)) return;
        self.sweeper = std.Thread.spawn(.{}, sweeperMain, .{self}) catch |err| blk: {
            debug_trace.logf("subagent", "node host sweeper not started err={s}", .{@errorName(err)});
            break :blk null;
        };
    }

    fn sweeperMain(self: *Registry) void {
        const pulse = self.limits.pulseMs();
        while (!self.stopping.load(.acquire)) {
            io_mod.sleep(pulse * std.time.ns_per_ms);
            if (self.stopping.load(.acquire)) return;
            self.sweep(io_mod.monotonicMilliTimestamp());
        }
    }

    /// Closes the tree's hosts as the root host closes, after the root's own
    /// children have joined: every node's work stops, every node's turn
    /// ends, and then the hosts close deepest first, so no host outlives
    /// its parent and none closes while a descendant runs.
    pub fn closeAll(self: *Registry) void {
        const io = io_mod.getIo();
        self.stopping.store(true, .release);
        if (self.sweeper) |thread| thread.join();
        self.sweeper = null;
        self.mutex.lockUncancelable(io);
        self.closed = true;
        for (self.entries.items) |entry| entry.runtime.managed.requestShutdown();
        while (true) {
            var turns = false;
            for (self.entries.items) |entry| {
                if (entry.turn) turns = true;
            }
            if (!turns) break;
            self.changed.waitUncancelable(io, &self.mutex);
        }
        while (self.entries.items.len > 0) {
            var deepest: ?*Entry = null;
            for (self.entries.items) |entry| {
                if (entry.closing or entry.leases != 0) continue;
                if (deepest == null or entry.depth > deepest.?.depth) deepest = entry;
            }
            const victim = deepest orelse {
                // A lease outlives its user only through a bug; wait for it
                // rather than close a host something still reads.
                debug_trace.logf("subagent", "node hosts closing wait leased={d}", .{self.entries.items.len});
                self.changed.waitUncancelable(io, &self.mutex);
                continue;
            };
            victim.closing = true;
            self.mutex.unlock(io);
            self.close(victim);
            self.mutex.lockUncancelable(io);
        }
        self.mutex.unlock(io);
        self.entries.deinit(self.alloc);
    }
};

test "limits read the environment's TTL and cap, and a short TTL sweeps often" {
    const limits = Limits{ .idle_ms = 40 };
    try std.testing.expectEqual(@as(u64, 10), limits.pulseMs());
    try std.testing.expectEqual(@as(u64, 1000), (Limits{}).pulseMs());
}
