//! The kernel front door for sessions: one `Slot` per session runtime holds the session
//! node's lazily created Python kernel from the process-wide pool (`pool.zig`), decides
//! where its snapshots live, and runs the recovery controls that the tool, the `/kernel`
//! command, and ACP resume share.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_paths = @import("../session/session_store_paths.zig");
const kernel = @import("kernel.zig");
pub const pool = @import("pool.zig");
const Allocator = std.mem.Allocator;

pub const Manager = kernel.Manager;
pub const State = kernel.State;
pub const Stream = kernel.Stream;

/// Recovery controls. Execution goes through `Manager.execute` on the ensured kernel.
pub const Action = enum { status, interrupt, stop, restart, prewarm };

/// Who the kernel belongs to. Only the first call that creates the kernel uses it.
pub const Owner = struct {
    /// Working directory for the Python process.
    cwd: []const u8,
    /// A saved session keeps snapshots under the profile; null is an unsaved session
    /// whose namespace ends with the process.
    session_id: ?[]const u8,
};

pub const Slot = struct {
    lock: std.Io.Mutex = .init,
    manager: ?*Manager = null,
    /// Profile home for snapshots; null uses `$HOME`. Borrowed from the host
    /// configuration, which outlives the session.
    home_override: ?[]const u8 = null,
    /// Keeps the kernel's live process past this slot, until `pool.releaseRetained`,
    /// so a subagent finds it warm on its next turn. Idle TTLs and the live cap still
    /// park it. Null stops the kernel when the slot lets go.
    retainer: ?pool.Retainer = null,

    /// Only the owning session calls this, after tool callers have joined. The
    /// pool stops the kernel unless the retainer or another slot still keeps it.
    pub fn deinit(self: *Slot) void {
        if (self.manager) |manager| pool.release(manager);
        self.manager = null;
    }

    /// The kernel if one was acquired. It stays valid until `deinit`.
    pub fn current(self: *Slot) ?*Manager {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        return self.manager;
    }

    /// Creates the kernel on first use. `alloc` must be thread-safe and outlive the slot.
    pub fn ensure(self: *Slot, alloc: Allocator, owner: Owner) !*Manager {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.manager) |manager| return manager;
        const artifacts = try self.artifactDir(alloc, owner.session_id);
        defer alloc.free(artifacts);
        const manager = try pool.acquire(alloc, .{ .cwd = owner.cwd, .artifact_dir = artifacts, .persist = owner.session_id != null }, self.retainer);
        self.manager = manager;
        return manager;
    }

    /// Resume hook for a saved session. It only allocates state; the kernel's warm
    /// thread checks for a snapshot and does any Python setup.
    pub fn prewarmIfSaved(self: *Slot, alloc: Allocator, owner: Owner) !void {
        if (owner.session_id == null) return;
        try (try self.ensure(alloc, owner)).prewarmIfSaved();
    }

    /// Runs one recovery control. Only `prewarm` creates a kernel; the others report
    /// null when none exists, since a kernel that never started has nothing to control.
    pub fn control(self: *Slot, alloc: Allocator, owner: Owner, action: Action) !?State {
        const manager = if (action == .prewarm) try self.ensure(alloc, owner) else self.current() orelse return null;
        switch (action) {
            .status => {},
            .interrupt => manager.interrupt(),
            .stop => manager.stop(true),
            .restart => manager.restart(),
            .prewarm => try manager.prewarm(),
        }
        return manager.status();
    }

    /// Caller owns the returned diagnostics; empty when no kernel exists.
    pub fn diagnostics(self: *Slot, alloc: Allocator) ![]u8 {
        const manager = self.current() orelse return alloc.dupe(u8, "");
        return manager.diagnostics(alloc);
    }

    /// `<home>/<profile root>/kernels/<session id>`, or empty for an unsaved session.
    fn artifactDir(self: *const Slot, alloc: Allocator, session_id: ?[]const u8) ![]u8 {
        const id = session_id orelse return alloc.dupe(u8, "");
        try session_paths.validateSessionId(id);
        const home = self.home_override orelse io_mod.homeDir() orelse return error.HomeNotSet;
        return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, "kernels", id });
    }
};

test "kernel slot derives snapshots from the bound home and rejects unsafe ids" {
    const alloc = std.testing.allocator;
    var slot: Slot = .{ .home_override = "/Users/example" };
    const dir = try slot.artifactDir(alloc, "abc-123");
    defer alloc.free(dir);
    const expected = try std.Io.Dir.path.join(alloc, &.{ "/Users/example", profile_paths.root_dir_name, "kernels", "abc-123" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, dir);
    const unsaved = try slot.artifactDir(alloc, null);
    defer alloc.free(unsaved);
    try std.testing.expectEqualStrings("", unsaved);
    try std.testing.expectError(error.InvalidSessionId, slot.artifactDir(alloc, "../escape"));
}

test "kernel slot controls report no kernel until one is created" {
    var slot: Slot = .{};
    defer slot.deinit();
    const owner: Owner = .{ .cwd = "/Users/example", .session_id = null };
    try std.testing.expectEqual(@as(?State, null), try slot.control(std.testing.allocator, owner, .status));
    try std.testing.expectEqual(@as(?State, null), try slot.control(std.testing.allocator, owner, .restart));
    try std.testing.expect(slot.current() == null);
}

test {
    _ = kernel;
    _ = pool;
}
