//! One agent shell command's right to use its node's harness. The command's
//! environment carries the lease's token; the token is checked on every
//! connection and dies with the lease when the command ends, so a process the
//! command left behind cannot act for a later turn.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const kernel_slot = @import("../kernel/slot.zig");
const services_mod = @import("services.zig");
const channel_mod = @import("channel.zig");
const command_runner = @import("../execution/command_runner.zig");
const Allocator = std.mem.Allocator;

pub const socket_env = "PROTO_FX_HARNESS_SOCKET";
pub const token_env = "PROTO_FX_HARNESS_TOKEN";
pub const depth_env = "PROTO_FX_HARNESS_DEPTH";
pub const python_path_env = "PYTHONPATH";

/// Harness requests one command may make, a bound on automatic reviews and
/// on a runaway loop.
pub const max_calls_per_lease: u32 = 1024;

pub const Options = struct {
    /// The node this command belongs to: its session id, or a key unique to
    /// an unsaved session's runtime.
    node_id: []const u8,
    /// Profile home; the socket and the staged package live under it.
    home: []const u8,
    cwd: []const u8,
    /// The node's kernel slot, for `kernel.*` ops; null offers no kernels.
    kernel: ?*kernel_slot.Slot = null,
    /// The saved session the kernels belong to; null keeps no snapshots.
    kernel_session_id: ?[]const u8 = null,
    /// Thread-safe and outliving the slot, as `Slot.ensure` requires.
    kernel_allocator: Allocator = std.heap.c_allocator,
    /// The node's running turn; null offers no tool, agent or completion ops.
    services: ?services_mod.Services = null,
    cancel: ?*const std.atomic.Value(bool) = null,
    /// The shell call this command runs in; harness call ids extend it.
    parent_call_id: []const u8 = "",
};

pub const Lease = struct {
    alloc: Allocator,
    channel: *channel_mod.Channel = undefined,
    token: [64]u8,
    node_id: []u8,
    cwd: []u8,
    parent_call_id: []u8,
    kernel: ?*kernel_slot.Slot,
    kernel_session_id: ?[]u8,
    kernel_allocator: Allocator,
    services: ?services_mod.Services,
    cancel: ?*const std.atomic.Value(bool),
    /// The staged folder that holds `sitecustomize.py` and `proto_fx`.
    python_dir: []u8,
    /// Guarded by the channel's mutex.
    in_flight: usize = 0,
    closing: bool = false,
    calls: std.atomic.Value(u32) = .init(0),
    processes: std.atomic.Value(u32) = .init(0),
    /// Kernels this lease's token was handed to, by manager and generation,
    /// so a cell's own `import proto_fx` reaches this node.
    bound_lock: std.Io.Mutex = .init,
    bound: std.ArrayList(Bound) = .empty,
    /// The socket and token variables, set once the channel names the socket.
    env_pairs: [2][2][]const u8 = undefined,

    pub const Bound = struct { manager: *const anyopaque, generation: u64 };

    pub fn create(alloc: Allocator, options: Options, python_dir: []const u8) !*Lease {
        const lease = try alloc.create(Lease);
        errdefer alloc.destroy(lease);
        var raw: [32]u8 = undefined;
        io_mod.getIo().random(&raw);
        const node_id = try alloc.dupe(u8, options.node_id);
        errdefer alloc.free(node_id);
        const cwd = try alloc.dupe(u8, options.cwd);
        errdefer alloc.free(cwd);
        const parent = try alloc.dupe(u8, options.parent_call_id);
        errdefer alloc.free(parent);
        const session = if (options.kernel_session_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (session) |id| alloc.free(id);
        lease.* = .{
            .alloc = alloc,
            .token = std.fmt.bytesToHex(raw, .lower),
            .node_id = node_id,
            .cwd = cwd,
            .parent_call_id = parent,
            .kernel = options.kernel,
            .kernel_session_id = session,
            .kernel_allocator = options.kernel_allocator,
            .services = options.services,
            .cancel = options.cancel,
            .python_dir = try alloc.dupe(u8, python_dir),
        };
        return lease;
    }

    pub fn destroy(self: *Lease) void {
        const alloc = self.alloc;
        self.bound.deinit(alloc);
        alloc.free(self.node_id);
        alloc.free(self.cwd);
        alloc.free(self.parent_call_id);
        if (self.kernel_session_id) |id| alloc.free(id);
        alloc.free(self.python_dir);
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Whether `candidate` is this lease's token, in constant time.
    pub fn matches(self: *const Lease, candidate: []const u8) bool {
        if (candidate.len != self.token.len) return false;
        return std.crypto.timing_safe.eql([64]u8, self.token, candidate[0..64].*);
    }

    pub fn cancelled(self: *const Lease) bool {
        return if (self.cancel) |flag| flag.load(.acquire) else false;
    }

    /// The next harness call id, or null once the lease spent its calls.
    pub fn nextCallId(self: *Lease, arena: Allocator) !?[]u8 {
        const n = self.calls.fetchAdd(1, .monotonic) + 1;
        if (n > max_calls_per_lease) return null;
        return try arena.print("harness:{s}:{d}", .{ if (self.parent_call_id.len > 0) self.parent_call_id else "cmd", n });
    }

    pub fn bindChannel(self: *Lease, channel: *channel_mod.Channel) void {
        self.channel = channel;
        self.env_pairs = .{ .{ socket_env, channel.socket_path }, .{ token_env, &self.token } };
    }

    pub fn socketPath(self: *const Lease) []const u8 {
        return self.channel.socket_path;
    }

    /// Puts the harness into a command's environment: the staged folder first
    /// on PYTHONPATH, keeping any value after it, the socket and token, and a
    /// reset depth so the command's top-level Python reports itself. The
    /// slices borrow the lease.
    pub fn environment(self: *const Lease) command_runner.EnvironmentExtension {
        return .{
            .python_path_prefix = self.python_dir,
            .set = &self.env_pairs,
            .unset = &.{depth_env},
        };
    }

    /// Whether `manager`, at `generation`, already has this lease's token.
    pub fn isBound(self: *Lease, manager: *const anyopaque, generation: u64) bool {
        const io = io_mod.getIo();
        self.bound_lock.lockUncancelable(io);
        defer self.bound_lock.unlock(io);
        for (self.bound.items) |item| if (item.manager == manager) return item.generation == generation;
        return false;
    }

    pub fn setBound(self: *Lease, manager: *const anyopaque, generation: u64) void {
        const io = io_mod.getIo();
        self.bound_lock.lockUncancelable(io);
        defer self.bound_lock.unlock(io);
        for (self.bound.items) |*item| if (item.manager == manager) {
            item.generation = generation;
            return;
        };
        self.bound.append(self.alloc, .{ .manager = manager, .generation = generation }) catch {};
    }
};

test "a lease prepends the staged folder and names its socket and token" {
    const alloc = std.testing.allocator;
    var channel: channel_mod.Channel = undefined;
    channel.socket_path = @constCast("/tmp/h/1.sock");
    const lease = try Lease.create(alloc, .{ .node_id = "n", .home = "/Users/example", .cwd = "/tmp" }, "/Users/example/py");
    defer lease.destroy();
    lease.bindChannel(&channel);
    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put("PYTHONPATH", "/project/src");
    try map.put(depth_env, "3");
    const copy = try lease.environment().dupe(alloc);
    defer {
        for (copy.set) |pair| {
            alloc.free(pair[0]);
            alloc.free(pair[1]);
        }
        alloc.free(copy.set);
        for (copy.unset) |name| alloc.free(name);
        alloc.free(copy.unset);
        alloc.free(copy.python_path_prefix);
    }
    try copy.apply(&map);
    try std.testing.expectEqualStrings("/Users/example/py:/project/src", map.get("PYTHONPATH").?);
    try std.testing.expectEqualStrings("/tmp/h/1.sock", map.get(socket_env).?);
    try std.testing.expectEqualStrings(&lease.token, map.get(token_env).?);
    try std.testing.expect(map.get(depth_env) == null);
    try std.testing.expect(lease.matches(&lease.token));
    var other = lease.token;
    other[0] = if (other[0] == 'a') 'b' else 'a';
    try std.testing.expect(!lease.matches(&other));
    try std.testing.expect(!lease.matches("short"));
}
