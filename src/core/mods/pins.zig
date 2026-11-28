//! Shared version pins for mod readers (`tests/tla/mods/ModUse.tla` design "pin").
//!
//! Pin files live under `<root>/.locks/pins/<name>-<token>`. A reader resolves
//! `<root>/<name>`, takes a shared advisory lock (`flock`) on that version's
//! pin file, and checks that `<root>/.store/<name>-<token>` still exists as a
//! directory before reading from it. A reload pins the new version before
//! releasing the old pin. Cleanup (`store.zig`) takes an exclusive `tryLock` on
//! the same pin file and keeps any version whose pin is held.
//!
//! Imports only `std` and `manifest.zig` so `store.zig` and TLA+ labs stay
//! standalone (`RULES.md` R1.7, R3.9).

const std = @import("std");
const manifest = @import("manifest.zig");

pub const default_lock_deadline_ms: u64 = 2_000;
pub const default_max_resolve_attempts: usize = 8;
pub const lock_poll_interval_ms: u64 = 5;
pub const token_hex_bytes: usize = 16;

pub const store_dir_name = ".store";
pub const locks_dir_name = ".locks";
pub const pins_dir_name = "pins";
const off_suffix = ".off";

pub const Step = enum { resolved, locked, checked, retry };

pub const Ops = struct {
    io: std.Io,
    ctx: ?*anyopaque = null,
    lock_deadline_ms: u64 = default_lock_deadline_ms,
    max_resolve_attempts: usize = default_max_resolve_attempts,
    step: *const fn (ctx: ?*anyopaque, step: Step) void = defaultStep,
    /// Optional hook to open/create `<root>/.locks/pins` with host-specific
    /// private-directory verification (`mods.zig` uses `io.zig`).
    prepare_pins_dir: ?*const fn (ctx: ?*anyopaque, io: std.Io, root_dir: std.Io.Dir) anyerror!std.Io.Dir = null,
};

fn defaultStep(_: ?*anyopaque, _: Step) void {}

/// Active shared pin on `<root>/.store/<name>-<token>/`. Caller owns `name`
/// and `path` (allocated from `alloc`) and `file`, and must call `release`.
pub const Pin = struct {
    name: []const u8,
    token: [token_hex_bytes]u8,
    path: []const u8,
    file: std.Io.File,

    pub fn release(self: *Pin, alloc: std.mem.Allocator, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
        alloc.free(self.name);
        alloc.free(self.path);
        self.* = undefined;
    }
};

pub const PinResult = union(enum) {
    pinned: Pin,
    not_installed,
    bad_link,
    busy,
};

pub const ExclusiveAttempt = union(enum) {
    acquired: std.Io.File,
    busy,
};

pub fn isLowerHex(bytes: []const u8) bool {
    for (bytes) |byte| {
        const ok = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn isVersionFolderForMod(entry_name: []const u8, mod_name: []const u8) bool {
    if (entry_name.len != mod_name.len + 1 + token_hex_bytes) return false;
    if (!std.mem.startsWith(u8, entry_name, mod_name)) return false;
    if (entry_name[mod_name.len] != '-') return false;
    return isLowerHex(entry_name[mod_name.len + 1 ..]);
}

pub fn formatVersionFolder(
    buf: *[manifest.max_name_bytes + 1 + token_hex_bytes]u8,
    name: []const u8,
    token_hex: *const [token_hex_bytes]u8,
) []const u8 {
    return std.mem.print(buf, "{s}-{s}", .{ name, token_hex }) catch unreachable;
}

/// Checks that `target` has the store link shape `.store/<name>-<16 hex>` and
/// returns the 16-byte lowercase hex token.
pub fn parseLinkTarget(target: []const u8, mod_name: []const u8) ?[token_hex_bytes]u8 {
    const prefix = store_dir_name ++ "/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const folder = target[prefix.len..];
    if (!isVersionFolderForMod(folder, mod_name)) return null;
    var token: [token_hex_bytes]u8 = undefined;
    @memcpy(&token, folder[mod_name.len + 1 ..]);
    return token;
}

/// Opens or creates `<root>/.locks/pins` with private `0o700` permissions,
/// rejecting symlinks. Caller owns the returned directory handle.
pub fn openOrCreatePrivatePinsDir(root_dir: std.Io.Dir, io: std.Io) !std.Io.Dir {
    root_dir.createDir(io, locks_dir_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var locks_dir = try root_dir.openDir(io, locks_dir_name, .{
        .iterate = false,
        .follow_symlinks = false,
    });
    defer locks_dir.close(io);

    locks_dir.createDir(io, pins_dir_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return try locks_dir.openDir(io, pins_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
}

/// Opens `<root>/.locks/pins` if it exists, or returns `null`. Caller owns the
/// returned directory handle.
pub fn openPrivatePinsDirIfPresent(root_dir: std.Io.Dir, io: std.Io) !?std.Io.Dir {
    var locks_dir = root_dir.openDir(io, locks_dir_name, .{
        .iterate = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer locks_dir.close(io);

    return locks_dir.openDir(io, pins_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Attempts an immediate non-blocking exclusive `flock` on `pins_dir/<folder_name>`.
/// When acquired, caller owns the returned file and must unlock and close it.
pub fn tryAcquireExclusive(
    io: std.Io,
    pins_dir: std.Io.Dir,
    folder_name: []const u8,
) !ExclusiveAttempt {
    const file = try pins_dir.createFile(io, folder_name, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    if (try file.tryLock(io, .exclusive)) {
        return .{ .acquired = file };
    }
    file.close(io);
    return .busy;
}

/// Resolves the enabled link `<root>/<name>`, takes a shared lock on its
/// version's pin file, and verifies `<root>/.store/<name>-<token>` still
/// exists as a directory. Retries up to `ops.max_resolve_attempts` if cleanup
/// removed the folder between resolve and lock (`ModUse.tla` design "pin").
pub fn pin(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    name: []const u8,
    ops: Ops,
) !PinResult {
    if (!manifest.validName(name)) return .bad_link;
    const io = ops.io;

    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .not_installed,
        else => return err,
    };
    defer root_dir.close(io);

    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = std.mem.print(&off_name_buf, "{s}{s}", .{ name, off_suffix }) catch unreachable;

    const attempts = @max(@as(usize, 1), ops.max_resolve_attempts);
    for (0..attempts) |_| {
        const on_kind = try entryKindNoFollow(root_dir, io, name);
        const off_kind = try entryKindNoFollow(root_dir, io, off_name);
        if (on_kind != null and off_kind != null) return .bad_link;
        const kind = on_kind orelse return .not_installed;
        if (kind != .sym_link) return .bad_link;

        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link_len = root_dir.readLink(io, name, &link_buf) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.NotLink, error.SymLinkLoop => return .bad_link,
            else => return err,
        };
        if (link_len >= link_buf.len) return .bad_link;
        const token = parseLinkTarget(link_buf[0..link_len], name) orelse return .bad_link;

        ops.step(ops.ctx, .resolved);

        var folder_buf: [manifest.max_name_bytes + 1 + token_hex_bytes]u8 = undefined;
        const folder_name = formatVersionFolder(&folder_buf, name, &token);

        var pins_dir = if (ops.prepare_pins_dir) |prepare|
            try prepare(ops.ctx, io, root_dir)
        else
            try openOrCreatePrivatePinsDir(root_dir, io);
        defer pins_dir.close(io);

        var lock_file = switch (try acquireSharedWithDeadline(io, pins_dir, folder_name, ops.lock_deadline_ms)) {
            .acquired => |f| f,
            .busy => return .busy,
        };
        var keep_lock = false;
        defer if (!keep_lock) {
            lock_file.unlock(io);
            lock_file.close(io);
        };

        ops.step(ops.ctx, .locked);

        if (!try versionDirExists(root_dir, io, folder_name)) {
            lock_file.unlock(io);
            lock_file.close(io);
            keep_lock = true; // already unlocked and closed above
            ops.step(ops.ctx, .retry);
            continue;
        }

        const abs_path = try resolveVersionAbsPath(alloc, root_dir, io, root_path, folder_name);
        errdefer alloc.free(abs_path);
        const owned_name = try alloc.dupe(u8, name);

        ops.step(ops.ctx, .checked);
        keep_lock = true;
        return .{ .pinned = .{
            .name = owned_name,
            .token = token,
            .path = abs_path,
            .file = lock_file,
        } };
    }
    return .busy;
}

/// Pins the current enabled version of `name` first, then releases `old_pin`
/// (never the reverse order). When `name` is no longer installed or enabled,
/// releases `old_pin` and returns `.not_installed` (`ModUse.tla` `Check`/`Resolve`).
pub fn reload(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    name: []const u8,
    old_pin: *?Pin,
    ops: Ops,
) !PinResult {
    const res = try pin(alloc, root_path, name, ops);
    switch (res) {
        .pinned, .not_installed => {
            if (old_pin.*) |*old| {
                old.release(alloc, ops.io);
                old_pin.* = null;
            }
        },
        .bad_link, .busy => {},
    }
    return res;
}

const SharedAttempt = union(enum) {
    acquired: std.Io.File,
    busy,
};

fn acquireSharedWithDeadline(
    io: std.Io,
    pins_dir: std.Io.Dir,
    folder_name: []const u8,
    deadline_ms: u64,
) !SharedAttempt {
    const file = try pins_dir.createFile(io, folder_name, .{ .read = true, .truncate = false });
    errdefer file.close(io);

    const started = std.Io.Timestamp.now(io, .awake);
    const deadline_ns = started.nanoseconds + @as(i96, @intCast(deadline_ms)) * std.time.ns_per_ms;

    while (true) {
        if (try file.tryLock(io, .shared)) {
            return .{ .acquired = file };
        }
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline_ns) {
            file.close(io);
            return .busy;
        }
        io.sleep(.fromMilliseconds(lock_poll_interval_ms), .awake) catch {};
    }
}

fn versionDirExists(root_dir: std.Io.Dir, io: std.Io, folder_name: []const u8) !bool {
    var store_dir = root_dir.openDir(io, store_dir_name, .{
        .iterate = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer store_dir.close(io);

    const stat = store_dir.statFile(io, folder_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return false,
        else => return err,
    };
    return stat.kind == .directory;
}

fn resolveVersionAbsPath(
    alloc: std.mem.Allocator,
    root_dir: std.Io.Dir,
    io: std.Io,
    root_path: []const u8,
    folder_name: []const u8,
) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(root_path)) {
        return std.Io.Dir.path.join(alloc, &.{ root_path, store_dir_name, folder_name });
    }
    var store_dir = try root_dir.openDir(io, store_dir_name, .{ .follow_symlinks = false });
    defer store_dir.close(io);
    const real = try store_dir.realPathFileAlloc(io, folder_name, alloc);
    defer alloc.free(real);
    return try alloc.dupe(u8, real);
}

fn entryKindNoFollow(dir: std.Io.Dir, io: std.Io, name: []const u8) !?std.Io.File.Kind {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return .sym_link,
        else => return err,
    };
    return stat.kind;
}

test "pin takes shared flock, rejects disabled/missing/bad links, and reload swaps order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods/.store/glm-0000000000000001");
    try tmp.dir.createDirPath(std.testing.io, "mods/.store/glm-0000000000000002");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);

    // Missing -> not_installed.
    const missing = try pin(alloc, root, "glm", .{ .io = std.testing.io, .lock_deadline_ms = 20 });
    try std.testing.expect(missing == .not_installed);

    // Disabled `.off` link -> not_installed.
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000001", "glm.off", .{ .is_directory = true });
    const off = try pin(alloc, root, "glm", .{ .io = std.testing.io, .lock_deadline_ms = 20 });
    try std.testing.expect(off == .not_installed);
    try root_dir.deleteFile(std.testing.io, "glm.off");

    // Bad link target -> bad_link.
    try root_dir.symLink(std.testing.io, "/tmp/escape", "glm", .{ .is_directory = true });
    const bad = try pin(alloc, root, "glm", .{ .io = std.testing.io, .lock_deadline_ms = 20 });
    try std.testing.expect(bad == .bad_link);
    try root_dir.deleteFile(std.testing.io, "glm");

    // Valid link -> pinned with shared lock; exclusive second open is busy; reload moves to v2.
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000001", "glm", .{ .is_directory = true });

    const StepLog = struct {
        steps: std.ArrayList(Step) = .empty,
        fn hook(ctx: ?*anyopaque, s: Step) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(std.testing.allocator, s) catch {};
        }
    };
    var log: StepLog = .{};
    defer log.steps.deinit(alloc);

    const res1 = try pin(alloc, root, "glm", .{
        .io = std.testing.io,
        .ctx = &log,
        .lock_deadline_ms = 20,
        .step = StepLog.hook,
    });
    try std.testing.expect(res1 == .pinned);
    try std.testing.expectEqualSlices(Step, &.{ .resolved, .locked, .checked }, log.steps.items);
    var p1: ?Pin = res1.pinned;
    defer if (p1) |*p| p.release(alloc, std.testing.io);

    try std.testing.expectEqualStrings("0000000000000001", &p1.?.token);
    try std.testing.expect(std.mem.endsWith(u8, p1.?.path, "/.store/glm-0000000000000001"));

    // A second open of the same pin file in this process sees exclusive tryLock busy.
    var pins_dir = try openOrCreatePrivatePinsDir(root_dir, std.testing.io);
    defer pins_dir.close(std.testing.io);
    const dir_stat = try pins_dir.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);

    try std.testing.expectEqual(ExclusiveAttempt.busy, try tryAcquireExclusive(std.testing.io, pins_dir, "glm-0000000000000001"));

    // Exclusive lock held externally causes pin to return busy at deadline.
    var ex = switch (try tryAcquireExclusive(std.testing.io, pins_dir, "glm-0000000000000002")) {
        .acquired => |f| f,
        .busy => return error.TestUnexpectedResult,
    };
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000002", ".glm.tmp", .{ .is_directory = true });
    try root_dir.rename(".glm.tmp", root_dir, "glm", std.testing.io);

    const busy_res = try reload(alloc, root, "glm", &p1, .{ .io = std.testing.io, .lock_deadline_ms = 15 });
    try std.testing.expect(busy_res == .busy);
    try std.testing.expect(p1 != null);

    // Release exclusive lock -> reload succeeds, pins v2, and releases v1.
    ex.unlock(std.testing.io);
    ex.close(std.testing.io);

    const res2 = try reload(alloc, root, "glm", &p1, .{ .io = std.testing.io, .lock_deadline_ms = 50 });
    try std.testing.expect(res2 == .pinned);
    p1 = res2.pinned;
    try std.testing.expectEqualStrings("0000000000000002", &p1.?.token);

    // v1's pin is now released so exclusive try-lock succeeds.
    var ex1 = switch (try tryAcquireExclusive(std.testing.io, pins_dir, "glm-0000000000000001")) {
        .acquired => |f| f,
        .busy => return error.TestUnexpectedResult,
    };
    ex1.unlock(std.testing.io);
    ex1.close(std.testing.io);
}

test "pin retries when cleanup removes resolved folder before lock (ModUse no-check race)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "mods/.store/glm-0000000000000001");
    try tmp.dir.createDirPath(std.testing.io, "mods/.store/glm-0000000000000002");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "mods", alloc);
    defer alloc.free(root);

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000001", "glm", .{ .is_directory = true });

    const RaceCtx = struct {
        root_dir: std.Io.Dir,
        raced: bool = false,
        steps: std.ArrayList(Step) = .empty,

        fn onStep(ctx: ?*anyopaque, s: Step) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(std.testing.allocator, s) catch {};
            // Between resolve (of v1) and lock, changer switches to v2 and deletes v1.
            if (s == .resolved and !self.raced) {
                self.raced = true;
                self.root_dir.symLink(std.testing.io, ".store/glm-0000000000000002", ".glm.tmp", .{ .is_directory = true }) catch unreachable;
                self.root_dir.rename(".glm.tmp", self.root_dir, "glm", std.testing.io) catch unreachable;
                self.root_dir.deleteTree(std.testing.io, ".store/glm-0000000000000001") catch unreachable;
            }
        }
    };

    var ctx: RaceCtx = .{ .root_dir = root_dir };
    defer ctx.steps.deinit(alloc);

    const res = try pin(alloc, root, "glm", .{
        .io = std.testing.io,
        .ctx = &ctx,
        .lock_deadline_ms = 50,
        .step = RaceCtx.onStep,
    });
    try std.testing.expect(res == .pinned);
    var p = res.pinned;
    defer p.release(alloc, std.testing.io);

    try std.testing.expectEqualStrings("0000000000000002", &p.token);
    try std.testing.expectEqualSlices(Step, &.{ .resolved, .locked, .retry, .resolved, .locked, .checked }, ctx.steps.items);
}
