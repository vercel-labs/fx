//! The harness: plain Python run by an agent's shell command can ask the
//! agent's host for help through `import proto_fx as harness`.
//!
//! Nothing hijacks `python`. For the agent's own shell commands only (never
//! the person's `!` commands or their own shell), the shell tool takes a
//! lease and puts three things in the command's environment: a staged folder
//! first on PYTHONPATH (keeping any value after it), PROTO_FX_HARNESS_SOCKET
//! and PROTO_FX_HARNESS_TOKEN. The folder holds `sitecustomize.py`, which
//! chains to the sitecustomize it hides, and which, only when the token is
//! set and only in the command's top-level Python (PROTO_FX_HARNESS_DEPTH
//! counts down the process tree), reports {pid, argv, cwd, version}. That is
//! how the host knows exactly that a command ran Python, whatever started
//! it. `-I`, `-E` and `-S` skip the hook, and Python older than 3.10 gets a
//! one-line notice and no harness.
//!
//! Protocol (`protocol.zig`): one JSON-line request per connection, answered
//! by event lines and one final line with a value or a typed error.
//!
//! Ops (`ops.zig`): a registry of typed handlers, one per op. `tool` runs a
//! tool through the node's admission and permissions (`services.zig`, which
//! the agent loop implements over its own turn), `agent` is the node's
//! `subagent` tool, `completion` uses the turn's model connection, and
//! `kernel.*` reaches the node's kernels through its kernel slot.
//!
//! Security:
//! - One socket per node (`channel.zig`), in a 0700 directory, itself 0600.
//! - A token per command, 32 random bytes, checked in constant time on every
//!   connection and revoked when the command ends; requests still in flight
//!   finish first.
//! - The node comes from the socket and the lease, never from the request:
//!   requests with unknown fields are refused.
//! - Every tool call takes the node's own validation, live authority and
//!   permission request, with automatic review marked as harness origin; the
//!   harness never forms an execution authority itself.
//! - Requests are bounded in size, count per command and concurrency per node.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const builtin = @import("builtin");
const kernel_slot = @import("../kernel/slot.zig");
const lease_mod = @import("lease.zig");
const channel = @import("channel.zig");
pub const services = @import("services.zig");
pub const Services = services.Services;
pub const Lease = lease_mod.Lease;
pub const Options = lease_mod.Options;
const Allocator = std.mem.Allocator;

/// The staged package, compiled into proto-fx so it never depends on a checkout.
const payload = [_]struct { path: []const u8, data: []const u8 }{
    .{ .path = "sitecustomize.py", .data = @embedFile("py/sitecustomize.py") },
    .{ .path = "proto_fx/__init__.py", .data = @embedFile("py/proto_fx/__init__.py") },
    .{ .path = "proto_fx/_client.py", .data = @embedFile("py/proto_fx/_client.py") },
    .{ .path = "proto_fx/fs.py", .data = @embedFile("py/proto_fx/fs.py") },
    .{ .path = "_proto_fx_guard.py", .data = @embedFile("py/_proto_fx_guard.py") },
    .{ .path = "proto_fx/store.py", .data = @embedFile("py/proto_fx/store.py") },
};

/// Opens a lease for one command of node `options.node_id`. The caller
/// applies `Lease.applyEnvironment` to the command and calls `close` after
/// the command ends.
pub fn open(options: Options) !*Lease {
    const alloc = std.heap.c_allocator;
    const root = try std.Io.Dir.path.join(alloc, &.{ options.home, profile_paths.root_dir_name, "harness" });
    defer alloc.free(root);
    const python_dir = try stage(alloc, root);
    defer alloc.free(python_dir);
    const socket_dir = try socketDir(alloc, root);
    defer alloc.free(socket_dir);
    const lease = try Lease.create(alloc, options, python_dir);
    errdefer lease.destroy();
    try channel.attach(lease, socket_dir);
    return lease;
}

/// Revokes the lease's token, waits for its requests in flight, and closes
/// the node's socket if no other command holds it.
pub fn close(lease: *Lease) void {
    channel.detach(lease);
    lease.destroy();
}

/// What an agent shell command knows about its node.
pub const Command = struct {
    services: ?Services,
    kernel: ?*kernel_slot.Slot,
    /// The node's saved session id; null for an unsaved session.
    session_id: ?[]const u8,
    workspace_root: []const u8,
    kernel_allocator: Allocator = std.heap.c_allocator,
    cancel: ?*const std.atomic.Value(bool) = null,
    parent_call_id: []const u8 = "",
};

/// A lease for one agent shell command, or null when this host has no turn
/// to serve it or the harness cannot open; the command then runs without
/// it, as plain Python would anyway.
pub fn openForCommand(command: Command) ?*Lease {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return null;
    const turn = command.services orelse return null;
    const home = (if (command.kernel) |slot| slot.home_override else null) orelse io_mod.homeDir() orelse return null;
    var key_buffer: [64]u8 = undefined;
    const node_id = nodeKey(&key_buffer, command.session_id, command.kernel) orelse return null;
    return open(.{
        .node_id = node_id,
        .home = home,
        .cwd = command.workspace_root,
        .kernel = command.kernel,
        .kernel_session_id = command.session_id,
        .kernel_allocator = command.kernel_allocator,
        .services = turn,
        .cancel = command.cancel,
        .parent_call_id = command.parent_call_id,
    }) catch |err| {
        debug_trace.logf("harness", "lease unavailable err={s}", .{@errorName(err)});
        return null;
    };
}

/// The key a node's harness state goes by: its session id, or for an
/// unsaved session a key unique to its runtime's kernel slot.
pub fn nodeKey(buffer: *[64]u8, session_id: ?[]const u8, kernel: ?*kernel_slot.Slot) ?[]const u8 {
    return session_id orelse
        (std.mem.print(buffer, "unsaved-{x}", .{if (kernel) |slot| @intFromPtr(slot) else 0}) catch null);
}

/// After a file tool call of a node succeeded: records the file as the agent
/// now sees it, for the stale-write guard. `path` is absolute.
pub fn noteFileTool(session_id: ?[]const u8, kernel: ?*kernel_slot.Slot, path: []const u8) void {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return;
    var key_buffer: [64]u8 = undefined;
    const node_id = nodeKey(&key_buffer, session_id, kernel) orelse return;
    seen.noteFile(node_id, path);
}

const seen = @import("seen.zig");

var stage_lock: std.Io.Mutex = .init;
var staged_roots: std.ArrayList([]u8) = .empty;

/// Writes the package under `<root>/py` once per process and root, file by
/// file through a rename so a running Python never reads half a file.
/// Caller owns the returned folder path.
fn stage(alloc: Allocator, root: []const u8) ![]u8 {
    const io = io_mod.getIo();
    const python_dir = try std.Io.Dir.path.join(alloc, &.{ root, "py" });
    errdefer alloc.free(python_dir);
    stage_lock.lockUncancelable(io);
    defer stage_lock.unlock(io);
    for (staged_roots.items) |known| if (std.mem.eql(u8, known, python_dir)) return python_dir;
    try std.Io.Dir.cwd().createDirPath(io, root);
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    try root_dir.setPermissions(io, .fromMode(0o700));
    try std.Io.Dir.cwd().createDirPath(io, python_dir);
    var dir = try std.Io.Dir.openDirAbsolute(io, python_dir, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "proto_fx");
    for (payload) |file| {
        const temporary = try alloc.print("{s}.new", .{file.path});
        defer alloc.free(temporary);
        try dir.writeFile(io, .{ .sub_path = temporary, .data = file.data, .flags = .{ .permissions = .fromMode(0o644) } });
        try dir.rename(temporary, dir, file.path, io);
    }
    const owned = try std.heap.c_allocator.dupe(u8, python_dir);
    staged_roots.append(std.heap.c_allocator, owned) catch std.heap.c_allocator.free(owned);
    debug_trace.logf("harness", "staged package at {s}", .{python_dir});
    return python_dir;
}

/// `<root>/run`, private to the user. A home so deep that a socket path in
/// it would be too long for the platform falls back to `/tmp/proto-fx-<uid>`,
/// which must already be the user's own 0700 directory if it exists.
fn socketDir(alloc: Allocator, root: []const u8) ![]u8 {
    const io = io_mod.getIo();
    const preferred = try std.Io.Dir.path.join(alloc, &.{ root, "run" });
    // Room for "/<pid>-<sequence>.sock".
    const path = if (preferred.len + 32 <= 100) preferred else blk: {
        alloc.free(preferred);
        break :blk try alloc.print("/tmp/proto-fx-{d}", .{std.c.getuid()});
    };
    errdefer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);
    const stat = try dir.stat(io);
    if (stat.kind != .directory) return error.HarnessSocketDirectoryUnsafe;
    try dir.setPermissions(io, .fromMode(0o700));
    var info: std.c.Stat = undefined;
    if (std.c.fstat(dir.handle, &info) != 0 or info.uid != std.c.getuid() or (info.mode & 0o077) != 0) return error.HarnessSocketDirectoryUnsafe;
    return path;
}

test {
    _ = @import("protocol.zig");
    _ = @import("lease.zig");
    _ = @import("ops.zig");
    _ = @import("op_agent.zig");
    _ = @import("op_kernel.zig");
    _ = @import("op_store.zig");
    _ = @import("tests.zig");
    _ = @import("seen.zig");
    _ = @import("ops/fs.zig");
}
