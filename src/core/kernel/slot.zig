//! The kernel front door for sessions: one `Slot` per session runtime holds the session
//! node's lazily created Python kernel from the process-wide pool (`pool.zig`), decides
//! where its snapshots live, and runs the recovery controls that the tool, the `/kernel`
//! command, and ACP resume share.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_paths = @import("../session/session_store_paths.zig");
const kernel = @import("kernel.zig");
const session_layout = @import("../session/session_layout.zig");
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
    /// The node's other kernels, which `proto_fx` names, keyed by name and
    /// guarded by `lock`. Each is a pool kernel of its own, saved beside the
    /// default one under `<session id>@<name>`.
    named: std.ArrayList(Named) = .empty,

    pub const Named = struct { name: []u8, manager: *Manager };

    /// Only the owning session calls this, after tool callers have joined. The
    /// pool stops the kernel unless the retainer or another slot still keeps it.
    pub fn deinit(self: *Slot) void {
        if (self.manager) |manager| pool.release(manager);
        self.manager = null;
        for (self.named.items) |entry| {
            pool.release(entry.manager);
            std.heap.c_allocator.free(entry.name);
        }
        self.named.deinit(std.heap.c_allocator);
        // A session resets its slot and may deinit it again later.
        self.named = .empty;
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
        const blobs = try self.blobDir(alloc, owner.session_id);
        defer alloc.free(blobs);
        const manager = try pool.acquire(alloc, self.options(owner, artifacts, blobs, default_name), self.retainer);
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

    /// The kernel called `name`, created on first use: `default` is the
    /// one `ensure` gives. `alloc` must be thread-safe and outlive the slot.
    pub fn ensureNamed(self: *Slot, alloc: Allocator, owner: Owner, name: []const u8) !*Manager {
        if (std.mem.eql(u8, name, default_name)) return self.ensure(alloc, owner);
        if (!validName(name)) return error.InvalidKernelName;
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        for (self.named.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.manager;
        if (self.named.items.len >= max_named) return error.TooManyKernels;
        const artifacts = try self.namedArtifactDir(alloc, owner.session_id, name);
        defer alloc.free(artifacts);
        const blobs = try self.blobDir(alloc, owner.session_id);
        defer alloc.free(blobs);
        try self.named.ensureUnusedCapacity(std.heap.c_allocator, 1);
        const owned = try std.heap.c_allocator.dupe(u8, name);
        errdefer std.heap.c_allocator.free(owned);
        const manager = try pool.acquire(alloc, self.options(owner, artifacts, blobs, name), self.retainer);
        self.named.appendAssumeCapacity(.{ .name = owned, .manager = manager });
        return manager;
    }

    /// The kernel called `name` if this slot holds it.
    pub fn currentNamed(self: *Slot, name: []const u8) ?*Manager {
        if (std.mem.eql(u8, name, default_name)) return self.current();
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        for (self.named.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.manager;
        return null;
    }

    /// `control` for the kernel called `name`; null when it never started here.
    pub fn controlNamed(self: *Slot, alloc: Allocator, owner: Owner, name: []const u8, action: Action) !?State {
        if (std.mem.eql(u8, name, default_name)) return self.control(alloc, owner, action);
        const manager = if (action == .prewarm) try self.ensureNamed(alloc, owner, name) else self.currentNamed(name) orelse return null;
        switch (action) {
            .status => {},
            .interrupt => manager.interrupt(),
            .stop => manager.stop(true),
            .restart => manager.restart(),
            .prewarm => try manager.prewarm(),
        }
        return manager.status();
    }

    /// What `/kernel` shows: the default kernel's diagnostics, then one line
    /// naming every other kernel of the node, live in this slot or the pool,
    /// or saved on disk. Caller owns the text.
    pub fn report(self: *Slot, alloc: Allocator, owner: Owner) ![]u8 {
        const base = try self.diagnostics(alloc);
        defer alloc.free(base);
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        var states: std.ArrayList([]const u8) = .empty;
        {
            self.lock.lockUncancelable(io_mod.getIo());
            defer self.lock.unlock(io_mod.getIo());
            for (self.named.items) |entry| {
                try names.append(arena, try arena.dupe(u8, entry.name));
                try states.append(arena, @tagName(entry.manager.status()));
            }
        }
        if (owner.session_id) |id| saved: {
            const root = self.artifactDir(arena, id) catch break :saved;
            const parent = std.Io.Dir.path.dirname(root) orelse break :saved;
            var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent, .{ .iterate = true }) catch break :saved;
            defer dir.close(io_mod.getIo());
            const prefix = try arena.print("{s}@", .{id});
            var it = dir.iterate();
            while (it.next(io_mod.getIo()) catch null) |entry| {
                if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, prefix)) continue;
                const name = entry.name[prefix.len..];
                if (!validName(name)) continue;
                const known = for (names.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) break true;
                } else false;
                if (known) continue;
                const path = try std.Io.Dir.path.join(arena, &.{ parent, entry.name });
                try names.append(arena, try arena.dupe(u8, name));
                try states.append(arena, if (pool.stateOf(path)) |state| @tagName(state) else "saved");
            }
        }
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try out.writer.writeAll(base);
        if (names.items.len > 0) {
            if (base.len > 0 and base[base.len - 1] != '\n') try out.writer.writeByte('\n');
            try out.writer.writeAll("named kernels:");
            for (names.items, states.items) |name, state| try out.writer.print(" {s} ({s})", .{ name, state });
        }
        if (owner.session_id != null) try self.writeUsage(arena, &out.writer, owner, names.items);
        return out.toOwnedSlice();
    }

    /// A saved node's kernel keeps its globals as records of its own session
    /// and restores from the session's log (D99).
    fn options(_: *const Slot, owner: Owner, artifacts: []const u8, blobs: []const u8, name: []const u8) kernel.Options {
        return .{
            .cwd = owner.cwd,
            .artifact_dir = artifacts,
            .persist = owner.session_id != null,
            .blob_dir = blobs,
            .node_id = owner.session_id orelse "",
            .name = name,
            .resolver = state_resolver,
        };
    }

    /// The node's session blob folder, or empty for an unsaved session.
    fn blobDir(self: *const Slot, alloc: Allocator, session_id: ?[]const u8) ![]u8 {
        const id = session_id orelse return alloc.dupe(u8, "");
        try session_paths.validateSessionId(id);
        const home = self.home_override orelse io_mod.homeDir() orelse return error.HomeNotSet;
        return nodeBlobDir(alloc, home, id);
    }

    /// `<home>/<profile root>/kernels/<session id>`, or empty for an unsaved session.
    fn artifactDir(self: *const Slot, alloc: Allocator, session_id: ?[]const u8) ![]u8 {
        const id = session_id orelse return alloc.dupe(u8, "");
        try session_paths.validateSessionId(id);
        const home = self.home_override orelse io_mod.homeDir() orelse return error.HomeNotSet;
        return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, "kernels", id });
    }

    /// One line per kernel of the node naming the snapshots its log keeps
    /// and the disk their records take, shared records counted once (D99).
    fn writeUsage(self: *Slot, arena: Allocator, w: *std.Io.Writer, owner: Owner, named: []const []const u8) !void {
        const id = owner.session_id orelse return;
        const blobs = self.blobDir(arena, id) catch return;
        const all = try arena.alloc([]const u8, named.len + 1);
        all[0] = default_name;
        @memcpy(all[1..], named);
        for (all) |name| {
            const usage_fn = state_usage orelse return;
            const use = usage_fn(arena, blobs, id, name) catch continue;
            if (use.snapshots == 0) continue;
            var size: [32]u8 = undefined;
            try w.print("\nsnapshots {s}: {d} turns, {d} records, {s} on disk", .{ name, use.snapshots, use.records, formatBytes(&size, use.bytes) });
            const manager = self.currentNamed(name) orelse continue;
            const stats = manager.snapshotStats();
            if (stats.ms > 0 or stats.written > 0) {
                var wrote: [32]u8 = undefined;
                try w.print(" (last took {d} ms, wrote {s})", .{ stats.ms, formatBytes(&wrote, stats.written) });
            }
        }
    }

    /// The default kernel's directory with `@<name>` appended.
    fn namedArtifactDir(self: *const Slot, alloc: Allocator, session_id: ?[]const u8, name: []const u8) ![]u8 {
        const base = try self.artifactDir(alloc, session_id);
        if (base.len == 0) return base;
        defer alloc.free(base);
        return std.mem.concat(alloc, u8, &.{ base, "@", name });
    }
};

fn formatBytes(buffer: []u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.mem.print(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1 << 20) return std.mem.print(buffer, "{d:.1} KiB", .{value / 1024}) catch "";
    if (bytes < 1 << 30) return std.mem.print(buffer, "{d:.1} MiB", .{value / (1 << 20)}) catch "";
    return std.mem.print(buffer, "{d:.2} GiB", .{value / (1 << 30)}) catch "";
}

/// Finds a kernel's snapshot in its node's log (D99). The session layer
/// installs it (`session/python_state.zig`) when it opens a session, so the
/// kernel never depends on the session manager.
pub var state_resolver: ?kernel.Resolver = null;
/// What a kernel's snapshots keep on disk, for `/kernel`; installed with it.
pub var state_usage: ?*const fn (alloc: Allocator, blob_dir: []const u8, node_id: []const u8, name: []const u8) anyerror!Usage = null;
pub const Usage = struct { snapshots: usize = 0, records: usize = 0, bytes: u64 = 0 };

/// `<home>/.proto-fx/sessions/v2/<id>/blobs`: where a node's kernels write
/// their records. Caller owns it.
pub fn nodeBlobDir(alloc: Allocator, home: []const u8, id: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, profile_paths.sessions_dir_name, session_layout.sessions_v2_dir, id, "blobs" });
}

/// The kernel a node gets without naming one.
pub const default_name = "default";
/// Named kernels one node may hold besides its default one.
pub const max_named: usize = 16;

/// A kernel name: 1 to 32 of lowercase letters, digits, `_` and `-`,
/// starting with a letter or digit.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name, 0..) |c, i| switch (c) {
        'a'...'z', '0'...'9' => {},
        '_', '-' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

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

test "named kernels are validated and saved beside the default one" {
    const alloc = std.testing.allocator;
    try std.testing.expect(validName("a"));
    try std.testing.expect(validName("data-2"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("-x"));
    try std.testing.expect(!validName("A"));
    try std.testing.expect(!validName("../x"));
    try std.testing.expect(!validName("abcdefghijklmnopqrstuvwxyz0123456"));
    var slot: Slot = .{ .home_override = "/Users/example" };
    const dir = try slot.namedArtifactDir(alloc, "abc-123", "a");
    defer alloc.free(dir);
    const expected = try std.Io.Dir.path.join(alloc, &.{ "/Users/example", profile_paths.root_dir_name, "kernels", "abc-123@a" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, dir);
    const unsaved = try slot.namedArtifactDir(alloc, null, "a");
    defer alloc.free(unsaved);
    try std.testing.expectEqualStrings("", unsaved);
    try std.testing.expectError(error.InvalidKernelName, slot.ensureNamed(alloc, .{ .cwd = "/", .session_id = null }, "Bad"));
    try std.testing.expectEqual(@as(?State, null), try slot.controlNamed(alloc, .{ .cwd = "/", .session_id = null }, "a", .status));
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
