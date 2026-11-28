//! Reader-owned set of shared pins across every enabled mod (`ModUse.tla` design "pin").
//!
//! Each loader (skills, profiles, themes) owns its own `ModPins` instance,
//! checks `changed(root)` cheaply without locking or reading `mod.json`, and
//! calls `reload` (which pins new versions before releasing old ones and runs
//! best-effort cleanup only for changed or removed mods).
//!
//! Imports only `std` and the sibling mod-store modules so it stays outside
//! libfx and builds standalone in unit tests (`RULES.md` R1.7, R3.9).

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const manifest = @import("manifest.zig");
const pins = @import("pins.zig");
const store = @import("store.zig");

const off_suffix = ".off";

pub const RootKind = enum {
    skills,
    agents,
    themes,

    fn subDir(self: RootKind) []const u8 {
        return switch (self) {
            .skills => "skills",
            .agents => "agents",
            .themes => "themes",
        };
    }
};

/// Borrowed slices are owned by `ModRoots`; call `deinit(alloc)`.
pub const ModRoot = struct {
    mod_name: []const u8,
    path: []const u8,
};

pub const ModRoots = struct {
    items: []ModRoot = &.{},

    pub fn deinit(self: *ModRoots, alloc: std.mem.Allocator) void {
        for (self.items) |item| {
            alloc.free(item.mod_name);
            alloc.free(item.path);
        }
        alloc.free(self.items);
        self.* = .{};
    }
};

pub const ModPins = struct {
    io: std.Io = undefined,
    resolved_root: ?[:0]u8 = null,
    pins: []pins.Pin = &.{},
    problems: [][]u8 = &.{},
    stamp: u64 = 0,

    pub const Ops = struct {
        store_ops: store.Ops,
        pin_ops: pins.Ops,
    };

    pub fn deinit(self: *ModPins, alloc: std.mem.Allocator) void {
        for (self.pins) |*p| p.release(alloc, self.io);
        if (self.pins.len > 0) alloc.free(self.pins);
        for (self.problems) |msg| alloc.free(msg);
        if (self.problems.len > 0) alloc.free(self.problems);
        if (self.resolved_root) |r| alloc.free(r);
        self.* = .{};
    }

    /// Resolves `root_path` once (no symlinks in any pinned path), captures the
    /// directory stamp before pinning, lists mods via `store.list` in name
    /// order (up to `manifest.max_mods`), and pins each enabled mod.
    pub fn load(alloc: std.mem.Allocator, root_path: []const u8, ops: Ops) !ModPins {
        const io = ops.pin_ops.io;
        const resolved_root = std.Io.Dir.cwd().realPathFileAlloc(io, root_path, alloc) catch |err| switch (err) {
            error.FileNotFound => return .{
                .io = io,
                .stamp = computeStamp(io, root_path),
            },
            else => return err,
        };
        errdefer alloc.free(resolved_root);

        // Capture stamp before pinning so a concurrent change between load and
        // pin still reads as changed on the next check.
        const initial_stamp = computeStamp(io, resolved_root);

        var listing = try store.list(alloc, .{
            .root_path = resolved_root,
            .ops = ops.store_ops,
        });
        defer listing.deinit(alloc);

        var pinned: std.ArrayList(pins.Pin) = .empty;
        errdefer {
            for (pinned.items) |*p| p.release(alloc, io);
            pinned.deinit(alloc);
        }
        var problems: std.ArrayList([]u8) = .empty;
        errdefer {
            for (problems.items) |msg| alloc.free(msg);
            problems.deinit(alloc);
        }

        if (listing.over_limit) {
            try problems.append(alloc, try alloc.print(
                "more than {d} mods are installed; extra mods were skipped.",
                .{manifest.max_mods},
            ));
        }

        for (listing.mods) |entry| {
            if (entry.problem) |problem| {
                // Disabled broken mods are not loaded and stay silent unless ambiguous.
                if (!entry.on and problem != .ambiguous) continue;
                try problems.append(alloc, try formatListingProblem(alloc, entry.name, problem));
                continue;
            }
            if (!entry.on) continue;

            switch (try pins.pin(alloc, resolved_root, entry.name, ops.pin_ops)) {
                .pinned => |p| {
                    var mutable = p;
                    pinned.append(alloc, mutable) catch |err| {
                        mutable.release(alloc, io);
                        return err;
                    };
                },
                .not_installed => {
                    try problems.append(alloc, try alloc.print(
                        "mod {s}: was removed or disabled while loading.",
                        .{entry.name},
                    ));
                },
                .bad_link => {
                    try problems.append(alloc, try alloc.print(
                        "mod {s}: mod link is invalid.",
                        .{entry.name},
                    ));
                },
                .busy => {
                    try problems.append(alloc, try alloc.print(
                        "mod {s}: mod is busy and could not be pinned.",
                        .{entry.name},
                    ));
                },
            }
        }

        const owned_pins = try pinned.toOwnedSlice(alloc);
        errdefer {
            for (owned_pins) |*p| p.release(alloc, io);
            alloc.free(owned_pins);
        }
        const owned_problems = try problems.toOwnedSlice(alloc);

        return .{
            .io = io,
            .resolved_root = resolved_root,
            .pins = owned_pins,
            .problems = owned_problems,
            .stamp = initial_stamp,
        };
    }

    /// Cheap check without locking, pinning, or reading files inside mods:
    /// true when the set of enabled mods or any link target changed.
    pub fn changed(self: *const ModPins, root_path: []const u8) bool {
        return computeStamp(self.io, root_path) != self.stamp;
    }

    /// Acquires independent shared locks for the exact same pinned versions held
    /// by `self`. Used when a copy of `ModPins` must outlive the caller's set.
    pub fn clone(self: *const ModPins, alloc: std.mem.Allocator, ops: Ops) !ModPins {
        const root = self.resolved_root orelse return .{ .io = self.io, .stamp = self.stamp };
        const root_copy = try alloc.dupeSentinel(u8, root, 0);
        errdefer alloc.free(root_copy);

        var cloned: std.ArrayList(pins.Pin) = .empty;
        errdefer {
            for (cloned.items) |*p| p.release(alloc, self.io);
            cloned.deinit(alloc);
        }
        try cloned.ensureTotalCapacity(alloc, self.pins.len);
        for (self.pins) |p| {
            switch (try pins.pinVersion(alloc, root_copy, p.name, p.token, ops.pin_ops)) {
                .pinned => |np| cloned.appendAssumeCapacity(np),
                .not_installed, .bad_link, .busy => {},
            }
        }
        return .{
            .io = self.io,
            .resolved_root = root_copy,
            .pins = try cloned.toOwnedSlice(alloc),
            .stamp = self.stamp,
        };
    }

    /// Pins the current enabled versions into a new set first, releases `self`'s
    /// old pins (never the reverse order), and runs best-effort `store.collect`
    /// only for mods whose pinned version changed or disappeared.
    pub fn reload(self: *ModPins, alloc: std.mem.Allocator, root_path: []const u8, ops: Ops) !void {
        var next = try ModPins.load(alloc, root_path, ops);
        errdefer next.deinit(alloc);
        try self.replaceWith(alloc, root_path, ops, next);
    }

    /// Makes `next` this set, then releases the old pins and runs a best-effort
    /// cleanup for each mod whose version changed or disappeared. A loader that
    /// rebuilds from the new roots in steps calls `load`, installs what it
    /// built, and only then calls this, so nothing reads an old pinned path
    /// after its pin goes (`tests/tla/mods/ModUse.tla` Check). On error `next`
    /// still belongs to the caller; on success it belongs to this set.
    pub fn replaceWith(self: *ModPins, alloc: std.mem.Allocator, root_path: []const u8, ops: Ops, next: ModPins) !void {
        var collect_names: std.ArrayList([]u8) = .empty;
        defer freeNames(alloc, &collect_names);
        try self.appendNamesNotPinnedBy(alloc, &collect_names, &next);

        var old = self.*;
        self.* = next;
        old.deinit(alloc);
        collectEach(self.resolved_root orelse root_path, ops, collect_names.items);
    }

    /// Releases every pin, then runs a best-effort cleanup for each mod whose
    /// version `current` does not pin; with `current` null, for every mod. A
    /// loader that keeps each pin set with the index it built calls this when
    /// it frees that index, so an old version goes once nothing reads it
    /// (`tests/tla/mods/ModUse.tla` UnusedVersionsGo). It cannot fail: without
    /// memory for the names it skips the cleanup, and the next change collects.
    pub fn releaseAndCollect(self: *ModPins, alloc: std.mem.Allocator, root_path: []const u8, ops: Ops, current: ?*const ModPins) void {
        const names = self.releaseForCleanup(alloc, current);
        defer freeCleanupNames(alloc, names);
        collectEach(root_path, ops, names);
    }

    /// The first half of `releaseAndCollect`, for a loader on the input or
    /// render path (`RULES.md` R2.1): releases every pin, which never waits,
    /// and returns the names of the mods whose version `current` does not pin
    /// (with `current` null, every mod). The caller runs `collectNames` with
    /// them on another thread, then frees them with `freeCleanupNames`.
    /// Without memory for the names it returns none, and the next change
    /// collects.
    pub fn releaseForCleanup(self: *ModPins, alloc: std.mem.Allocator, current: ?*const ModPins) [][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        self.appendNamesNotPinnedBy(alloc, &names, current) catch {};
        self.deinit(alloc);
        return names.toOwnedSlice(alloc) catch {
            freeNames(alloc, &names);
            return &.{};
        };
    }

    /// Appends a copy of each name this set pins at a version `other` does not pin.
    fn appendNamesNotPinnedBy(self: *const ModPins, alloc: std.mem.Allocator, names: *std.ArrayList([]u8), other: ?*const ModPins) !void {
        for (self.pins) |p| {
            if (other) |o| if (findPinToken(o.pins, p.name, &p.token)) continue;
            const copy = try alloc.dupe(u8, p.name);
            errdefer alloc.free(copy);
            try names.append(alloc, copy);
        }
    }

    /// Returns `(mod_name, absolute path)` in name order for every pinned mod
    /// whose version folder contains `kind` as a real directory (not a symlink).
    pub fn roots(self: *const ModPins, alloc: std.mem.Allocator, kind: RootKind) !ModRoots {
        const sub = kind.subDir();
        var list: std.ArrayList(ModRoot) = .empty;
        errdefer {
            for (list.items) |item| {
                alloc.free(item.mod_name);
                alloc.free(item.path);
            }
            list.deinit(alloc);
        }

        for (self.pins) |p| {
            var mod_dir = std.Io.Dir.openDirAbsolute(self.io, p.path, .{
                .iterate = false,
                .follow_symlinks = false,
            }) catch continue;
            defer mod_dir.close(self.io);

            const stat = mod_dir.statFile(self.io, sub, .{ .follow_symlinks = false }) catch continue;
            if (stat.kind != .directory) continue;

            var sub_dir = mod_dir.openDir(self.io, sub, .{
                .iterate = false,
                .follow_symlinks = false,
            }) catch continue;
            sub_dir.close(self.io);

            const mod_name = try alloc.dupe(u8, p.name);
            errdefer alloc.free(mod_name);
            const full_path = try std.Io.Dir.path.join(alloc, &.{ p.path, sub });
            errdefer alloc.free(full_path);
            try list.append(alloc, .{
                .mod_name = mod_name,
                .path = full_path,
            });
        }

        return .{ .items = try list.toOwnedSlice(alloc) };
    }
};

/// Pins all enabled mods, invokes `body(ctx, &pinned)`, and releases every pin
/// before returning (on success or error).
pub fn withPinnedMods(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    ops: ModPins.Ops,
    ctx: anytype,
    comptime R: type,
    comptime body: fn (@TypeOf(ctx), *const ModPins) anyerror!R,
) !R {
    var pinned = try ModPins.load(alloc, root_path, ops);
    defer pinned.deinit(alloc);
    return try body(ctx, &pinned);
}

/// Computes an order-independent stamp from one directory listing of `root_path`
/// plus one `readLink` per non-`.off` entry (no locks, no pins, no file reads).
pub fn computeStamp(io: std.Io, root_path: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return emptyOrMissingStamp(0),
        else => return errorStamp(@errorName(err)),
    };
    defer dir.close(io);

    // Names are unique in a folder, so a wrapping sum and an xor of the entry
    // hashes describe the set in any listing order without a sort.
    var count: u64 = 0;
    var sum: u64 = 0;
    var xor: u64 = 0;

    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it = dir.iterate();
    while (it.next(io) catch return errorStamp("IterateFailed")) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        var h = std.hash.Wyhash.init(0);
        h.update(entry.name);
        if (std.mem.endsWith(u8, entry.name, off_suffix)) {
            h.update(&.{1});
        } else {
            h.update(&.{2});
            if (dir.readLink(io, entry.name, &link_buf)) |target_len| {
                h.update(&.{0});
                const clamped = @min(target_len, link_buf.len);
                h.update(link_buf[0..clamped]);
            } else |err| {
                h.update(&.{1});
                h.update(@errorName(err));
            }
        }

        const entry_hash = h.final();
        sum +%= entry_hash;
        xor ^= entry_hash;
        count += 1;
    }

    if (count == 0) return emptyOrMissingStamp(0);

    var total = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    total.update(std.mem.asBytes(&count));
    total.update(std.mem.asBytes(&sum));
    total.update(std.mem.asBytes(&xor));
    return total.final();
}

fn emptyOrMissingStamp(tag: u8) u64 {
    var h = std.hash.Wyhash.init(0x517cc1b727220a95);
    h.update(&.{tag});
    return h.final();
}

fn errorStamp(name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x94d049bb133111eb);
    h.update(name);
    return h.final();
}

fn freeNames(alloc: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |name| alloc.free(name);
    names.deinit(alloc);
}

/// The second half of `releaseAndCollect`: a best-effort store cleanup of each
/// named mod. It can wait on another fx's store lock, up to the lock deadline
/// in `ops`, so a loader on the input or render path runs it on another thread.
pub fn collectNames(root_path: []const u8, ops: ModPins.Ops, names: []const []u8) void {
    collectEach(root_path, ops, names);
}

/// Frees the names `releaseForCleanup` returned.
pub fn freeCleanupNames(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    if (names.len > 0) alloc.free(names);
}

/// Takes ownership of `root` and `names`, freeing both with `alloc` once
/// done. Runs best-effort store cleanup on a detached thread so callers on
/// input, render, or runtime threads never wait on another fx's store lock.
/// Logs under `"mods"` when the background job cannot start.
pub fn collectDetached(alloc: std.mem.Allocator, root: []u8, names: [][]u8, ops: ModPins.Ops) void {
    const job = alloc.create(CleanupJob) catch {
        dropCleanup(alloc, root, names, "out of memory");
        return;
    };
    job.* = .{ .alloc = alloc, .root = root, .names = names, .ops = ops };
    if (comptime builtin.single_threaded) {
        alloc.destroy(job);
        dropCleanup(alloc, root, names, "threads are unavailable");
        return;
    }
    const thread = std.Thread.spawn(.{}, CleanupJob.run, .{job}) catch {
        job.release();
        debug_trace.logf("mods", "mod cleanup not started: thread unavailable; the next change of the mod collects", .{});
        return;
    };
    thread.detach();
}

const CleanupJob = struct {
    alloc: std.mem.Allocator,
    root: []u8,
    names: [][]u8,
    ops: ModPins.Ops,

    fn release(job: *CleanupJob) void {
        freeCleanupNames(job.alloc, job.names);
        job.alloc.free(job.root);
        job.alloc.destroy(job);
    }

    fn run(job: *CleanupJob) void {
        collectNames(job.root, job.ops, job.names);
        job.release();
    }
};

fn dropCleanup(alloc: std.mem.Allocator, root: []u8, names: [][]u8, reason: []const u8) void {
    freeCleanupNames(alloc, names);
    alloc.free(root);
    debug_trace.logf("mods", "mod cleanup not started: {s}; the next change of the mod collects", .{reason});
}

/// Cleanup after a set's pins go is best-effort: another reader or a lock
/// holder may keep a version busy, and the next change or collect sweeps it.
fn collectEach(root_path: []const u8, ops: ModPins.Ops, names: []const []u8) void {
    for (names) |mod_name| {
        _ = store.collect(.{ .root_path = root_path, .ops = ops.store_ops }, mod_name) catch {};
    }
}

fn findPinToken(items: []const pins.Pin, name: []const u8, token: *const [pins.token_hex_bytes]u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name) and std.mem.eql(u8, &item.token, token)) {
            return true;
        }
    }
    return false;
}

fn formatListingProblem(alloc: std.mem.Allocator, name: []const u8, problem: store.ModProblem) ![]u8 {
    const reason: []const u8 = switch (problem) {
        .ambiguous => "has both enabled and disabled links",
        .bad_name => "invalid mod name",
        .not_symlink => "mod entry is not a symbolic link",
        .dangling => "mod link is broken",
        .no_manifest => "mod.json is missing",
        .bad_manifest => "mod.json could not be read",
        .name_mismatch => "mod.json names a different mod",
        .unreadable => "could not read mod",
    };
    return alloc.print("mod {s}: {s}.", .{ name, reason });
}

const TestLockState = struct {
    acquires: usize = 0,
    held: bool = false,
    token_byte: u8 = 0x10,
};

fn testAcquireLock(
    ctx: ?*anyopaque,
    _: std.Io,
    _: []const u8,
    _: []const u8,
    _: u64,
) anyerror!store.LockAttempt {
    const state: *TestLockState = @ptrCast(@alignCast(ctx.?));
    state.acquires += 1;
    if (state.held) return .busy;
    state.held = true;
    return .{ .acquired = .{
        .ctx = ctx,
        .release_fn = testReleaseLock,
    } };
}

fn testReleaseLock(self: *store.Lock, _: std.Io) void {
    const state: *TestLockState = @ptrCast(@alignCast(self.ctx.?));
    state.held = false;
}

fn testFillToken(ctx: ?*anyopaque, _: std.Io, out_hex: *[store.token_hex_bytes]u8) void {
    const state: *TestLockState = @ptrCast(@alignCast(ctx.?));
    const byte = state.token_byte;
    state.token_byte +%= 1;
    const raw: [store.token_hex_bytes / 2]u8 = @splat(byte);
    out_hex.* = std.fmt.bytesToHex(raw, .lower);
}

fn testStore(root_path: []const u8, state: *TestLockState) store.Store {
    return .{
        .root_path = root_path,
        .ops = .{
            .io = std.testing.io,
            .ctx = state,
            .lock_deadline_ms = 0,
            .acquire_lock = testAcquireLock,
            .fill_token = testFillToken,
        },
    };
}

fn writeTestMod(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    sub: []const u8,
    name: []const u8,
    version: []const u8,
    subdirs: []const []const u8,
) ![:0]u8 {
    try tmp.dir.createDirPath(std.testing.io, sub);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, sub, alloc);
    errdefer alloc.free(path);
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer dir.close(std.testing.io);
    const json = try alloc.print("{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ name, version });
    defer alloc.free(json);
    try dir.writeFile(std.testing.io, .{ .sub_path = "mod.json", .data = json });
    for (subdirs) |sd| try dir.createDirPath(std.testing.io, sd);
    return path;
}

fn countEntries(dir_path: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |_| count += 1;
    return count;
}

test "ModPins load pins only enabled mods, skips off mods, reports broken links, and checks stamp" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);

    const src_a = try writeTestMod(alloc, &tmp, "src_a", "alpha", "1.0.0", &.{"skills"});
    defer alloc.free(src_a);
    const src_b = try writeTestMod(alloc, &tmp, "src_b", "beta", "1.0.0", &.{"agents"});
    defer alloc.free(src_b);
    const src_off = try writeTestMod(alloc, &tmp, "src_off", "gamma", "1.0.0", &.{"themes"});
    defer alloc.free(src_off);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);

    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "beta", src_b, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_a, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "gamma", src_off, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.setOn(alloc, s, "gamma", false));

    // Add a dangling broken link `broken`.
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    try root_dir.symLink(std.testing.io, ".store/broken-0000000000000001", "broken", .{ .is_directory = true });

    const ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };

    var set = try ModPins.load(alloc, root, ops);
    defer set.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), set.pins.len);
    try std.testing.expectEqualStrings("alpha", set.pins[0].name);
    try std.testing.expectEqualStrings("beta", set.pins[1].name);
    try std.testing.expect(!set.changed(root));

    // Only `broken` produces a problem; `gamma` (.off) produces none.
    try std.testing.expectEqual(@as(usize, 1), set.problems.len);
    try std.testing.expect(std.mem.find(u8, set.problems[0], "broken") != null);

    // Stamp reacts to enable, disable, update, and remove.
    try std.testing.expectEqual(store.Outcome.ok, try store.setOn(alloc, s, "gamma", true));
    try std.testing.expect(set.changed(root));
    try std.testing.expectEqual(store.Outcome.ok, try store.setOn(alloc, s, "gamma", false));
    try std.testing.expect(!set.changed(root));

    const src_a2 = try writeTestMod(alloc, &tmp, "src_a2", "alpha", "2.0.0", &.{"skills"});
    defer alloc.free(src_a2);
    try std.testing.expectEqual(store.Outcome.ok, try store.update(alloc, s, "alpha", src_a2, null));
    try std.testing.expect(set.changed(root));

    var set_after_update = try ModPins.load(alloc, root, ops);
    defer set_after_update.deinit(alloc);
    try std.testing.expect(!set_after_update.changed(root));
    try std.testing.expectEqual(store.Outcome.ok, try store.remove(alloc, s, "alpha"));
    try std.testing.expect(set_after_update.changed(root));
}

test "ModPins reload pins new versions before releasing old ones and collects only changed mods" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);

    const src_a1 = try writeTestMod(alloc, &tmp, "src_a1", "alpha", "1.0.0", &.{});
    defer alloc.free(src_a1);
    const src_a2 = try writeTestMod(alloc, &tmp, "src_a2", "alpha", "2.0.0", &.{});
    defer alloc.free(src_a2);
    const src_b1 = try writeTestMod(alloc, &tmp, "src_b1", "beta", "1.0.0", &.{});
    defer alloc.free(src_b1);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_a1, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "beta", src_b1, null));

    const base_ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };
    var set = try ModPins.load(alloc, root, base_ops);
    var released_in_test = false;
    defer if (!released_in_test) set.deinit(alloc);

    const old_alpha_token = set.pins[0].token;
    try std.testing.expectEqualStrings("alpha", set.pins[0].name);
    try std.testing.expectEqualStrings("beta", set.pins[1].name);

    // Update `alpha` to v2 while `set` still pins v1; `.store` keeps alpha-v1, alpha-v2, beta-v1.
    try std.testing.expectEqual(store.Outcome.ok, try store.update(alloc, s, "alpha", src_a2, null));
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);
    try std.testing.expectEqual(@as(usize, 3), try countEntries(store_sub));

    // During reload, at `.checked` (new version pinned, old pin not yet released),
    // a cleanup attempt must find BOTH alpha-v1 and alpha-v2 busy and keep all 3 folders.
    const ProbeCtx = struct {
        root: []const u8,
        store_ops: store.Ops,
        store_sub: []const u8,
        old_alpha_token: [pins.token_hex_bytes]u8,
        checked_alpha: bool = false,
        both_kept: bool = false,

        fn onStep(ctx_ptr: ?*anyopaque, step: pins.Step) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            if (step != .checked or self.checked_alpha) return;
            self.checked_alpha = true;

            // Calling `collect` on `alpha` while both old and new pins are held must keep both.
            _ = store.collect(.{ .root_path = self.root, .ops = self.store_ops }, "alpha") catch return;
            const n = countEntries(self.store_sub) catch return;
            self.both_kept = (n == 3);
        }
    };

    var probe: ProbeCtx = .{
        .root = root,
        .store_ops = s.ops,
        .store_sub = store_sub,
        .old_alpha_token = old_alpha_token,
    };
    const acquires_before = lock_state.acquires;

    try set.reload(alloc, root, .{
        .store_ops = s.ops,
        .pin_ops = .{
            .io = std.testing.io,
            .ctx = &probe,
            .lock_deadline_ms = 20,
            .step = ProbeCtx.onStep,
        },
    });
    try std.testing.expect(probe.checked_alpha);
    try std.testing.expect(probe.both_kept);

    // After reload returns: old v1 pin was released and `reload`'s collect removed alpha-v1,
    // collecting only for `alpha` (not unchanged `beta`: 1 probe collect + 1 reload collect = 2).
    try std.testing.expectEqual(@as(usize, 2), try countEntries(store_sub));
    try std.testing.expectEqual(acquires_before + 2, lock_state.acquires);
    try std.testing.expect(!std.mem.eql(u8, &old_alpha_token, &set.pins[0].token));
    try std.testing.expect(!set.changed(root));

    // Remove `alpha` while `set` holds its pin -> `alpha` folder stays until `deinit`,
    // then `collect` removes it.
    try std.testing.expectEqual(store.Outcome.ok, try store.remove(alloc, s, "alpha"));
    try std.testing.expectEqual(@as(usize, 2), try countEntries(store_sub));

    set.deinit(alloc);
    released_in_test = true;
    try std.testing.expectEqual(store.Outcome.ok, try store.collect(s, "alpha"));
    try std.testing.expectEqual(@as(usize, 1), try countEntries(store_sub));
}

test "ModPins replaceWith keeps the old version until a loader installs the new set" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);
    const src_v1 = try writeTestMod(alloc, &tmp, "src_v1", "alpha", "1.0.0", &.{});
    defer alloc.free(src_v1);
    const src_v2 = try writeTestMod(alloc, &tmp, "src_v2", "alpha", "2.0.0", &.{});
    defer alloc.free(src_v2);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_v1, null));
    const ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };
    var set = try ModPins.load(alloc, root, ops);
    defer set.deinit(alloc);
    const old_token = set.pins[0].token;

    try std.testing.expectEqual(store.Outcome.ok, try store.update(alloc, s, "alpha", src_v2, null));
    try std.testing.expect(set.changed(root));
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);

    // The loader pins the new set and builds from it; the old set still pins v1.
    var next = try ModPins.load(alloc, root, ops);
    var next_owned = true;
    defer if (next_owned) next.deinit(alloc);
    try std.testing.expectEqual(store.Outcome.ok, try store.collect(s, "alpha"));
    try std.testing.expectEqual(@as(usize, 2), try countEntries(store_sub));

    // Once the loader installed what it built, the old pin goes and v1 is deleted.
    try set.replaceWith(alloc, root, ops, next);
    next_owned = false;
    try std.testing.expectEqual(@as(usize, 1), try countEntries(store_sub));
    try std.testing.expect(!std.mem.eql(u8, &old_token, &set.pins[0].token));
    try std.testing.expect(!set.changed(root));
}

test "ModPins releaseAndCollect frees an old index's pins and deletes only versions the current set does not pin" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);
    const src_v1 = try writeTestMod(alloc, &tmp, "src_v1", "alpha", "1.0.0", &.{});
    defer alloc.free(src_v1);
    const src_v2 = try writeTestMod(alloc, &tmp, "src_v2", "alpha", "2.0.0", &.{});
    defer alloc.free(src_v2);
    const src_b = try writeTestMod(alloc, &tmp, "src_b", "beta", "1.0.0", &.{});
    defer alloc.free(src_b);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_v1, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "beta", src_b, null));
    const ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);

    // An old index pins alpha v1; after the update the active index pins alpha v2.
    var old_index = try ModPins.load(alloc, root, ops);
    try std.testing.expectEqual(store.Outcome.ok, try store.update(alloc, s, "alpha", src_v2, null));
    var active_index = try ModPins.load(alloc, root, ops);
    defer active_index.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), try countEntries(store_sub));

    // Freeing the old index deletes alpha v1 and keeps what the active index pins.
    const acquires_before = lock_state.acquires;
    old_index.releaseAndCollect(alloc, root, ops, &active_index);
    try std.testing.expectEqual(@as(usize, 2), try countEntries(store_sub));
    // Only alpha changed, so only alpha was collected.
    try std.testing.expectEqual(acquires_before + 1, lock_state.acquires);
    try std.testing.expectEqual(@as(usize, 0), old_index.pins.len);
}

test "ModPins releaseForCleanup releases at once and leaves the cleanup to collectNames" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);
    const src_v1 = try writeTestMod(alloc, &tmp, "src_v1", "alpha", "1.0.0", &.{});
    defer alloc.free(src_v1);
    const src_v2 = try writeTestMod(alloc, &tmp, "src_v2", "alpha", "2.0.0", &.{});
    defer alloc.free(src_v2);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_v1, null));
    const ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);

    var old_index = try ModPins.load(alloc, root, ops);
    try std.testing.expectEqual(store.Outcome.ok, try store.update(alloc, s, "alpha", src_v2, null));
    var active_index = try ModPins.load(alloc, root, ops);
    defer active_index.deinit(alloc);

    // The owner's thread only releases; no lock is taken and nothing is deleted yet.
    const acquires_before = lock_state.acquires;
    const names = old_index.releaseForCleanup(alloc, &active_index);
    defer freeCleanupNames(alloc, names);
    try std.testing.expectEqual(acquires_before, lock_state.acquires);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("alpha", names[0]);
    try std.testing.expectEqual(@as(usize, 2), try countEntries(store_sub));

    // The cleanup, run elsewhere, deletes the version nothing pins any more.
    collectNames(root, ops, names);
    try std.testing.expectEqual(@as(usize, 1), try countEntries(store_sub));
}

test "ModPins roots returns only real subfolders and withPinnedMods releases on return and error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);

    const src_a = try writeTestMod(alloc, &tmp, "src_a", "alpha", "1.0.0", &.{ "skills", "themes" });
    defer alloc.free(src_a);
    const src_b = try writeTestMod(alloc, &tmp, "src_b", "beta", "1.0.0", &.{ "skills", "agents" });
    defer alloc.free(src_b);

    var lock_state: TestLockState = .{};
    const s = testStore(root, &lock_state);
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "beta", src_b, null));
    try std.testing.expectEqual(store.Outcome.ok, try store.add(alloc, s, "alpha", src_a, null));

    const ops: ModPins.Ops = .{
        .store_ops = s.ops,
        .pin_ops = .{ .io = std.testing.io, .lock_deadline_ms = 20 },
    };

    {
        var set = try ModPins.load(alloc, root, ops);
        defer set.deinit(alloc);

        // Plant a symlink `agents` inside alpha's version folder and a regular file `themes` inside beta's.
        var alpha_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, set.pins[0].path, .{});
        defer alpha_dir.close(std.testing.io);
        try alpha_dir.symLink(std.testing.io, src_b, "agents", .{ .is_directory = true });

        var beta_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, set.pins[1].path, .{});
        defer beta_dir.close(std.testing.io);
        try beta_dir.writeFile(std.testing.io, .{ .sub_path = "themes", .data = "not a dir" });

        var skill_roots = try set.roots(alloc, .skills);
        defer skill_roots.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), skill_roots.items.len);
        try std.testing.expectEqualStrings("alpha", skill_roots.items[0].mod_name);
        try std.testing.expectEqualStrings("beta", skill_roots.items[1].mod_name);
        try std.testing.expect(std.mem.endsWith(u8, skill_roots.items[0].path, "/skills"));

        var agent_roots = try set.roots(alloc, .agents);
        defer agent_roots.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), agent_roots.items.len);
        try std.testing.expectEqualStrings("beta", agent_roots.items[0].mod_name);

        var theme_roots = try set.roots(alloc, .themes);
        defer theme_roots.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), theme_roots.items.len);
        try std.testing.expectEqualStrings("alpha", theme_roots.items[0].mod_name);
    }

    // `withPinnedMods` holds pins during the callback and releases them on error too.
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    var pins_dir = try pins.openOrCreatePrivatePinsDir(root_dir, std.testing.io);
    defer pins_dir.close(std.testing.io);

    const FailBody = struct {
        pins_dir: std.Io.Dir,
        pinned_folder: []u8,
        alloc: std.mem.Allocator,
        fn run(self: *@This(), pinned: *const ModPins) !void {
            try std.testing.expectEqual(@as(usize, 2), pinned.pins.len);
            var folder_buf: [manifest.max_name_bytes + 1 + pins.token_hex_bytes]u8 = undefined;
            const f0 = pins.formatVersionFolder(&folder_buf, pinned.pins[0].name, &pinned.pins[0].token);
            self.pinned_folder = try self.alloc.dupe(u8, f0);
            try std.testing.expectEqual(pins.ExclusiveAttempt.busy, try pins.tryAcquireExclusive(std.testing.io, self.pins_dir, f0));
            return error.IntentionalTestError;
        }
    };
    var fail_body: FailBody = .{ .pins_dir = pins_dir, .pinned_folder = &.{}, .alloc = alloc };
    defer if (fail_body.pinned_folder.len > 0) alloc.free(fail_body.pinned_folder);
    try std.testing.expectError(error.IntentionalTestError, withPinnedMods(alloc, root, ops, &fail_body, void, FailBody.run));

    // After error return, pins were released.
    var ex = switch (try pins.tryAcquireExclusive(std.testing.io, pins_dir, fail_body.pinned_folder)) {
        .acquired => |f| f,
        .busy => return error.TestUnexpectedResult,
    };
    ex.unlock(std.testing.io);
    ex.close(std.testing.io);
}
