//! Atomic mod store under `~/.fx/mods/` following `tests/tla/mods/ModStore.tla` (Design "b").
//!
//! Layout under `<root>`:
//! - `.store/<name>-<token>/`  versioned mod copy (`<token>` is 16 lowercase hex chars)
//! - `<name>`                  symlink to `.store/<name>-<token>` when enabled
//! - `<name>.off`              symlink to `.store/<name>-<token>` when disabled
//! - `.<name>.link-<token>`    temp symlink renamed over the live link during `update`
//! - `.locks/`                 advisory lock directory owned by the caller's `Ops`
//!
//! Imports only `std` and `manifest.zig` so tests and TLA+ labs can build this
//! module standalone (`RULES.md` R1.7, R3.9).

const std = @import("std");
const manifest = @import("manifest.zig");
pub const pins = @import("pins.zig");

pub const default_lock_deadline_ms: u64 = 2_000;
pub const max_copy_files: usize = 4096;
pub const max_copy_bytes: u64 = 64 * 1024 * 1024;
pub const token_hex_bytes: usize = pins.token_hex_bytes;
pub const max_record_bytes: usize = 16 * 1024;
pub const record_file_name = ".fx-mod-source.json";

const store_dir_name = pins.store_dir_name;
const isVersionFolderForMod = pins.isVersionFolderForMod;
const formatVersionFolder = pins.formatVersionFolder;
const isLowerHex = pins.isLowerHex;
/// A top-level git folder is never copied into a version, from a folder or a clone.
const source_git_dir_name = ".git";
const off_suffix = ".off";
const temp_link_infix = ".link-";
const manifest_file_name = "mod.json";
const token_create_attempts: usize = 8;
const max_copy_depth: usize = 64;
const copy_chunk_bytes: usize = 32 * 1024;

pub const Step = enum { start, locked, copy_started, copy_done, switched };

pub const Outcome = union(enum) {
    ok,
    exists,
    missing,
    busy,
    invalid: Invalid,
};

pub const Invalid = enum {
    bad_name,
    no_manifest,
    bad_manifest,
    name_mismatch,
    symlink,
    special_file,
    too_large,
    ambiguous,
    reserved_source_record,
};

pub const ModProblem = enum {
    ambiguous,
    bad_name,
    not_symlink,
    dangling,
    no_manifest,
    bad_manifest,
    name_mismatch,
    unreadable,
};

/// Borrowed slices are owned by the caller's `alloc`; call `deinit(alloc)` when not using an arena.
pub const Mod = struct {
    version: []const u8,
    on: bool,
    path: []const u8,
};

pub const BadMod = struct {
    on: bool,
    problem: ModProblem,
};

pub const Loaded = union(enum) {
    none,
    bad: BadMod,
    mod: Mod,

    pub fn deinit(self: *Loaded, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .mod => |m| {
                alloc.free(m.version);
                alloc.free(m.path);
            },
            .none, .bad => {},
        }
        self.* = .none;
    }
};

pub const ScannedEntry = struct {
    base: []const u8,
    has_on: bool = false,
    has_off: bool = false,
    on_kind: ?std.Io.File.Kind = null,
    off_kind: ?std.Io.File.Kind = null,
};

pub const ScanResult = struct {
    entries: []ScannedEntry = &.{},
    over_limit: bool = false,
};

pub const ManifestProblem = union(enum) {
    dangling,
    open_dir_failed: anyerror,
    no_manifest,
    open_file_failed: anyerror,
    unreadable_manifest,
    not_regular_file,
    too_large,
    bad_manifest: manifest.DecodeError,
    name_mismatch,
};

pub const ManifestRead = union(enum) {
    ok: manifest.Manifest,
    problem: ManifestProblem,
};

pub const ListedMod = struct {
    name: []const u8,
    on: bool,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    problem: ?ModProblem = null,
};

/// Owns all allocated slices; call `deinit(alloc)` to release them.
pub const Listing = struct {
    mods: []ListedMod = &.{},
    over_limit: bool = false,

    pub fn deinit(self: *Listing, alloc: std.mem.Allocator) void {
        for (self.mods) |item| {
            alloc.free(item.name);
            if (item.version) |v| alloc.free(v);
            if (item.path) |p| alloc.free(p);
        }
        alloc.free(self.mods);
        self.* = .{};
    }
};

pub const Lock = struct {
    ctx: ?*anyopaque = null,
    file: std.Io.File = undefined,
    id: usize = 0,
    release_fn: *const fn (self: *Lock, io: std.Io) void = noopRelease,

    pub fn release(self: *Lock, io: std.Io) void {
        self.release_fn(self, io);
        self.* = undefined;
    }

    fn noopRelease(_: *Lock, _: std.Io) void {}
};

pub const LockAttempt = union(enum) {
    acquired: Lock,
    busy,
};

pub const Ops = struct {
    io: std.Io,
    ctx: ?*anyopaque = null,
    lock_deadline_ms: u64 = default_lock_deadline_ms,
    acquire_lock: *const fn (
        ctx: ?*anyopaque,
        io: std.Io,
        root_path: []const u8,
        name: []const u8,
        deadline_ms: u64,
    ) anyerror!LockAttempt,
    fill_token: *const fn (ctx: ?*anyopaque, io: std.Io, out_hex: *[token_hex_bytes]u8) void = defaultFillToken,
    step: *const fn (ctx: ?*anyopaque, step: Step) void = defaultStep,
    collect_after_switch: bool = true,
};

pub const Store = struct {
    root_path: []const u8,
    ops: Ops,
};

const ChangeKind = enum { add, update, enable, disable, remove };
const SeenLink = enum { none, on, off };

pub fn defaultFillToken(_: ?*anyopaque, io: std.Io, out_hex: *[token_hex_bytes]u8) void {
    var raw: [token_hex_bytes / 2]u8 = undefined;
    io.random(&raw);
    out_hex.* = std.fmt.bytesToHex(raw, .lower);
}

fn defaultStep(_: ?*anyopaque, _: Step) void {}

/// `record`, when given, is written as `record_file_name` into the new version
/// folder before the switch, so the switch makes it visible with the mod.
pub fn add(alloc: std.mem.Allocator, store: Store, name: []const u8, source_dir: []const u8, record: ?[]const u8) !Outcome {
    return runChange(alloc, store, .add, name, source_dir, record);
}

pub fn update(alloc: std.mem.Allocator, store: Store, name: []const u8, source_dir: []const u8, record: ?[]const u8) !Outcome {
    return runChange(alloc, store, .update, name, source_dir, record);
}

pub fn setOn(alloc: std.mem.Allocator, store: Store, name: []const u8, on: bool) !Outcome {
    return runChange(alloc, store, if (on) .enable else .disable, name, "", null);
}

pub fn remove(alloc: std.mem.Allocator, store: Store, name: []const u8) !Outcome {
    return runChange(alloc, store, .remove, name, "", null);
}

/// Best-effort cleanup of unlinked, unpinned version folders, leftover temp
/// links, and stray pin files for `name` under the mod's lock.
pub fn collect(store: Store, name: []const u8) !Outcome {
    if (!manifest.validName(name)) return .{ .invalid = .bad_name };
    const io = store.ops.io;

    var lock = switch (try acquireModLock(store, name)) {
        .acquired => |l| l,
        .busy => return .busy,
    };
    defer lock.release(io);

    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .ok,
        else => return err,
    };
    defer root_dir.close(io);

    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = formatOffName(&off_name_buf, name);
    try collectForMod(root_dir, io, name, off_name);
    return .ok;
}

/// Cleans up one specific unlinked version `<name>-<token_hex>` under the mod's
/// lock (`ModUse.tla` `Cleanup(v)`).
pub fn collectVersion(store: Store, name: []const u8, token_hex: *const [token_hex_bytes]u8) !Outcome {
    if (!manifest.validName(name)) return .{ .invalid = .bad_name };
    const io = store.ops.io;

    var lock = switch (try acquireModLock(store, name)) {
        .acquired => |l| l,
        .busy => return .busy,
    };
    defer lock.release(io);

    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .ok,
        else => return err,
    };
    defer root_dir.close(io);

    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = formatOffName(&off_name_buf, name);
    var on_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var off_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const live_on = try readLiveStoreFolder(root_dir, io, name, &on_buf);
    const live_off = try readLiveStoreFolder(root_dir, io, off_name, &off_buf);

    var folder_buf: [manifest.max_name_bytes + 1 + token_hex_bytes]u8 = undefined;
    const folder_name = formatVersionFolder(&folder_buf, name, token_hex);
    if (isLiveStoreFolder(live_on, live_off, folder_name)) return .ok;

    var store_dir = root_dir.openDir(io, store_dir_name, .{
        .iterate = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .ok,
        else => return err,
    };
    defer store_dir.close(io);

    const stat = store_dir.statFile(io, folder_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .ok,
        else => return err,
    };
    if (stat.kind != .directory) return .ok;

    var pins_dir = try pins.openOrCreatePrivatePinsDir(root_dir, io);
    defer pins_dir.close(io);

    try collectVersionFolder(io, store_dir, pins_dir, folder_name);
    return .ok;
}

/// Reads the source record of an installed mod through its link, enabled or
/// disabled. Null when the mod is not installed or has no record. Owned by `alloc`.
pub fn readRecord(alloc: std.mem.Allocator, store: Store, name: []const u8) !?[]u8 {
    if (!manifest.validName(name)) return null;
    const io = store.ops.io;

    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer root_dir.close(io);

    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = formatOffName(&off_name_buf, name);
    const link_name = if ((try entryKindNoFollow(root_dir, io, name)) != null)
        name
    else if ((try entryKindNoFollow(root_dir, io, off_name)) != null)
        off_name
    else
        return null;

    var mod_dir = root_dir.openDir(io, link_name, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return null,
        else => return err,
    };
    defer mod_dir.close(io);

    var record_file = mod_dir.openFile(io, record_file_name, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer record_file.close(io);

    return try readBoundedRecord(alloc, io, &record_file);
}

fn readBoundedRecord(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File) ![]u8 {
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(io, &read_buf);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    r.interface.appendRemaining(alloc, &content, .limited(max_record_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.RecordTooLarge,
        else => return err,
    };
    return content.toOwnedSlice(alloc);
}

pub fn load(alloc: std.mem.Allocator, store: Store, name: []const u8) !Loaded {
    if (!manifest.validName(name)) return .{ .bad = .{ .on = false, .problem = .bad_name } };
    const io = store.ops.io;

    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    defer root_dir.close(io);

    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = formatOffName(&off_name_buf, name);

    const on_kind = try entryKindNoFollow(root_dir, io, name);
    const off_kind = try entryKindNoFollow(root_dir, io, off_name);

    if (on_kind == null and off_kind == null) return .none;
    if (on_kind != null and off_kind != null) return .{ .bad = .{ .on = false, .problem = .ambiguous } };

    const is_on = on_kind != null;
    const link_name = if (is_on) name else off_name;
    const link_kind = (on_kind orelse off_kind).?;
    if (link_kind != .sym_link) return .{ .bad = .{ .on = is_on, .problem = .not_symlink } };

    return switch (try inspectLinkedMod(alloc, root_dir, io, store.root_path, name, link_name, is_on)) {
        .ok => |m| .{ .mod = m },
        .problem => |prob| .{ .bad = .{ .on = is_on, .problem = prob } },
    };
}

/// Scans `<root>`, merges `<name>` and `<name>.off`, caps at `manifest.max_mods`,
/// and sorts entries by base name using `std.sort.insertion`.
pub fn scanEntries(scratch: std.mem.Allocator, root_dir: std.Io.Dir, io: std.Io) !ScanResult {
    var entries: std.ArrayList(ScannedEntry) = .empty;
    var over_limit = false;

    var it = root_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const is_off = std.mem.endsWith(u8, entry.name, off_suffix);
        const base = if (is_off) entry.name[0 .. entry.name.len - off_suffix.len] else entry.name;
        const kind = try resolveEntryKind(root_dir, io, entry.name, entry.kind);

        var existing_index: ?usize = null;
        for (entries.items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.base, base)) {
                existing_index = idx;
                break;
            }
        }

        if (existing_index) |idx| {
            if (is_off) {
                entries.items[idx].has_off = true;
                entries.items[idx].off_kind = kind;
            } else {
                entries.items[idx].has_on = true;
                entries.items[idx].on_kind = kind;
            }
            continue;
        }

        if (entries.items.len >= manifest.max_mods) {
            over_limit = true;
            continue;
        }

        const base_copy = try scratch.dupe(u8, base);
        try entries.append(scratch, .{
            .base = base_copy,
            .has_on = !is_off,
            .has_off = is_off,
            .on_kind = if (!is_off) kind else null,
            .off_kind = if (is_off) kind else null,
        });
    }

    std.sort.insertion(ScannedEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ScannedEntry, b: ScannedEntry) bool {
            return std.mem.order(u8, a.base, b.base) == .lt;
        }
    }.lessThan);

    return .{
        .entries = entries.items,
        .over_limit = over_limit,
    };
}

pub fn list(alloc: std.mem.Allocator, store: Store) !Listing {
    const io = store.ops.io;
    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer root_dir.close(io);

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const scanned = try scanEntries(scratch, root_dir, io);

    var result = std.ArrayList(ListedMod).empty;
    errdefer {
        for (result.items) |item| {
            alloc.free(item.name);
            if (item.version) |v| alloc.free(v);
            if (item.path) |p| alloc.free(p);
        }
        result.deinit(alloc);
    }

    for (scanned.entries) |entry| {
        const mod_name = try alloc.dupe(u8, entry.base);
        errdefer alloc.free(mod_name);

        if (!manifest.validName(entry.base)) {
            try result.append(alloc, .{
                .name = mod_name,
                .on = entry.has_on and !entry.has_off,
                .problem = .bad_name,
            });
            continue;
        }

        if (entry.has_on and entry.has_off) {
            try result.append(alloc, .{
                .name = mod_name,
                .on = false,
                .problem = .ambiguous,
            });
            continue;
        }

        const is_on = entry.has_on;
        const link_kind = (if (is_on) entry.on_kind else entry.off_kind).?;
        if (link_kind != .sym_link) {
            try result.append(alloc, .{
                .name = mod_name,
                .on = is_on,
                .problem = .not_symlink,
            });
            continue;
        }

        var off_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
        const link_name = if (is_on) entry.base else formatOffName(&off_buf, entry.base);
        switch (try inspectLinkedMod(alloc, root_dir, io, store.root_path, entry.base, link_name, is_on)) {
            .ok => |m| {
                try result.append(alloc, .{
                    .name = mod_name,
                    .on = m.on,
                    .version = m.version,
                    .path = m.path,
                    .problem = null,
                });
            },
            .problem => |prob| {
                try result.append(alloc, .{
                    .name = mod_name,
                    .on = is_on,
                    .problem = prob,
                });
            },
        }
    }

    return .{
        .mods = try result.toOwnedSlice(alloc),
        .over_limit = scanned.over_limit,
    };
}

fn runChange(
    alloc: std.mem.Allocator,
    store: Store,
    kind: ChangeKind,
    name: []const u8,
    source_dir: []const u8,
    record: ?[]const u8,
) !Outcome {
    if (!manifest.validName(name)) return .{ .invalid = .bad_name };

    const io = store.ops.io;
    var off_name_buf: [manifest.max_name_bytes + off_suffix.len]u8 = undefined;
    const off_name = formatOffName(&off_name_buf, name);

    // Order matches `tests/tla/mods/ModStore.tla` (`Start`, `TakeLock`, `CopyStart`, `CopyDone`, `Switch`, `Collect`).
    store.ops.step(store.ops.ctx, .start);

    var lock = switch (try acquireModLock(store, name)) {
        .acquired => |l| l,
        .busy => return .busy,
    };
    defer lock.release(io);

    if (kind == .add) {
        try std.Io.Dir.cwd().createDirPath(io, store.root_path);
    }

    var root_dir = std.Io.Dir.cwd().openDir(io, store.root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer root_dir.close(io);

    const on_exists = (try entryKindNoFollow(root_dir, io, name)) != null;
    const off_exists = (try entryKindNoFollow(root_dir, io, off_name)) != null;
    if (on_exists and off_exists) return .{ .invalid = .ambiguous };

    const seen: SeenLink = if (on_exists) .on else if (off_exists) .off else .none;
    if (checkMissingOrExists(kind, seen)) |outcome| return outcome;

    store.ops.step(store.ops.ctx, .locked);

    var token_hex: [token_hex_bytes]u8 = undefined;
    var folder_name_buf: [manifest.max_name_bytes + 1 + token_hex_bytes]u8 = undefined;
    var folder_name: []const u8 = "";
    var target_rel_buf: [store_dir_name.len + 1 + manifest.max_name_bytes + 1 + token_hex_bytes]u8 = undefined;
    var target_rel: []const u8 = "";

    var keep_copy = false;
    var store_rel: []const u8 = "";
    defer if (!keep_copy and store_rel.len > 0) {
        root_dir.deleteTree(io, store_rel) catch {};
    };

    if (kind == .add or kind == .update) {
        var store_dir = try root_dir.createDirPathOpen(io, store_dir_name, .{
            .open_options = .{ .iterate = true, .follow_symlinks = false },
        });
        defer store_dir.close(io);

        var dest_dir = try createVersionFolder(store, store_dir, name, &token_hex, &folder_name_buf);
        defer dest_dir.close(io);
        folder_name = formatVersionFolder(&folder_name_buf, name, &token_hex);
        target_rel = std.mem.print(&target_rel_buf, "{s}/{s}", .{ store_dir_name, folder_name }) catch unreachable;
        store_rel = target_rel;

        store.ops.step(store.ops.ctx, .copy_started);

        if (try copyAndValidateSource(alloc, io, source_dir, &dest_dir, name)) |invalid| {
            return .{ .invalid = invalid };
        }
        if (record) |bytes| try dest_dir.writeFile(io, .{ .sub_path = record_file_name, .data = bytes });

        store.ops.step(store.ops.ctx, .copy_done);
    }

    switch (kind) {
        .add => {
            createAddLink(root_dir, io, target_rel, name) catch |err| switch (err) {
                error.PathAlreadyExists => return .exists,
                else => return err,
            };
        },
        .update => {
            var temp_buf: [1 + manifest.max_name_bytes + temp_link_infix.len + token_hex_bytes]u8 = undefined;
            const temp_name = formatTempLink(&temp_buf, name, &token_hex);
            root_dir.symLink(io, target_rel, temp_name, .{ .is_directory = true }) catch |err| switch (err) {
                error.PathAlreadyExists => return error.TempLinkCollision,
                else => return err,
            };
            errdefer root_dir.deleteFile(io, temp_name) catch {};

            const live_link = if (seen == .on) name else off_name;
            try root_dir.rename(temp_name, root_dir, live_link, io);
        },
        .enable => {
            if (seen == .off) {
                try root_dir.renamePreserve(off_name, root_dir, name, io);
            }
        },
        .disable => {
            if (seen == .on) {
                try root_dir.renamePreserve(name, root_dir, off_name, io);
            }
        },
        .remove => {
            const live_link = if (seen == .on) name else off_name;
            try root_dir.deleteFile(io, live_link);
        },
    }

    keep_copy = true;
    store.ops.step(store.ops.ctx, .switched);

    // The change is done once the link switched. What collect cannot delete
    // now is never read, and the next change of this mod collects it.
    if (store.ops.collect_after_switch) {
        collectForMod(root_dir, io, name, off_name) catch {};
    }
    return .ok;
}

fn acquireModLock(store: Store, name: []const u8) !LockAttempt {
    return store.ops.acquire_lock(store.ops.ctx, store.ops.io, store.root_path, name, store.ops.lock_deadline_ms);
}

fn checkMissingOrExists(kind: ChangeKind, seen: SeenLink) ?Outcome {
    if (kind == .add and seen != .none) return .exists;
    if (kind != .add and seen == .none) return .missing;
    return null;
}

fn createAddLink(root_dir: std.Io.Dir, io: std.Io, target_rel: []const u8, name: []const u8) !void {
    try root_dir.symLink(io, target_rel, name, .{ .is_directory = true });
}

fn createVersionFolder(
    store: Store,
    store_dir: std.Io.Dir,
    name: []const u8,
    out_hex: *[token_hex_bytes]u8,
    folder_buf: *[manifest.max_name_bytes + 1 + token_hex_bytes]u8,
) !std.Io.Dir {
    const io = store.ops.io;
    for (0..token_create_attempts) |_| {
        store.ops.fill_token(store.ops.ctx, io, out_hex);
        const folder_name = formatVersionFolder(folder_buf, name, out_hex);
        store_dir.createDir(io, folder_name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer store_dir.deleteTree(io, folder_name) catch {};
        return try store_dir.openDir(io, folder_name, .{ .iterate = true, .follow_symlinks = false });
    }
    return error.VersionTokenCollision;
}

const CopyCounters = struct {
    files: usize = 0,
    bytes: u64 = 0,
};

fn copyAndValidateSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    source_dir_path: []const u8,
    dest_dir: *std.Io.Dir,
    expected_name: []const u8,
) !?Invalid {
    var src_dir = try std.Io.Dir.cwd().openDir(io, source_dir_path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer src_dir.close(io);

    var counters: CopyCounters = .{};
    if (try copyDirTree(io, src_dir, dest_dir.*, &counters, 0)) |invalid| {
        return invalid;
    }

    var mf_file = dest_dir.openFile(io, manifest_file_name, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .no_manifest,
        error.IsDir, error.NotDir => return .bad_manifest,
        error.SymLinkLoop => return .symlink,
        else => return err,
    };
    defer mf_file.close(io);

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const bytes = readBoundedManifest(scratch, io, &mf_file) catch |err| switch (err) {
        error.StreamTooLong => return .bad_manifest,
        else => return err,
    };
    const decoded = manifest.decode(scratch, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .bad_manifest,
    };
    if (!std.mem.eql(u8, decoded.name, expected_name)) return .name_mismatch;
    return null;
}

fn isSkippedSourceEntry(depth: usize, name: []const u8) bool {
    return depth == 0 and std.mem.eql(u8, name, source_git_dir_name);
}

fn isStoreAddedEntry(depth: usize, name: []const u8) bool {
    return depth == 0 and std.mem.eql(u8, name, record_file_name);
}

/// SHA-256 over the mod's regular files in sorted relative-path order.
/// Hashes each file's relative path, NUL, executable bit, size, and bytes,
/// sharing the store's skip rules (`isSkippedSourceEntry`, `isStoreAddedEntry`)
/// and never following links inside `dir_path`. Returns null on links, special
/// files, read errors, or copy limits.
pub fn treeDigest(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) ?[std.crypto.hash.sha2.Sha256.digest_length]u8 {
    return treeDigestInner(alloc, io, dir_path) catch null;
}

fn treeDigestInner(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var root_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{
        .iterate = true,
        .follow_symlinks = true,
    }) catch return null;
    defer root_dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    var file_count: usize = 0;
    if (!(try collectDigestFiles(arena, io, root_dir, "", &files, &file_count, 0))) return null;

    std.sort.insertion([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes: u64 = 0;
    var read_buf: [8192]u8 = undefined;
    var transfer_buf: [copy_chunk_bytes]u8 = undefined;

    for (files.items) |rel| {
        var file = (openRelFileNoFollow(root_dir, io, rel) catch return null) orelse return null;
        defer file.close(io);

        const st = file.stat(io) catch return null;
        if (st.kind != .file) return null;

        const exec_bit: u8 = if ((st.permissions.toMode() & 0o111) != 0) 1 else 0;
        const size_u64: u64 = @intCast(st.size);
        hasher.update(rel);
        hasher.update(&.{ 0, exec_bit });
        hasher.update(std.mem.asBytes(&size_u64));

        var reader = file.readerStreaming(io, &read_buf);
        var file_bytes: u64 = 0;
        while (true) {
            const n = reader.interface.readSliceShort(&transfer_buf) catch return null;
            if (n == 0) break;
            total_bytes += n;
            if (total_bytes > max_copy_bytes) return null;
            file_bytes += n;
            hasher.update(transfer_buf[0..n]);
        }
        if (file_bytes != size_u64) return null;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn collectDigestFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    files: *std.ArrayList([]const u8),
    file_count: *usize,
    depth: usize,
) !bool {
    if (depth >= max_copy_depth) return false;
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (isSkippedSourceEntry(depth, entry.name) or isStoreAddedEntry(depth, entry.name)) continue;
        const kind = resolveEntryKind(dir, io, entry.name, entry.kind) catch return false;
        const rel = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try arena.print("{s}/{s}", .{ prefix, entry.name });
        switch (kind) {
            .sym_link => return false,
            .directory => {
                var child = dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch return false;
                defer child.close(io);
                if (!(try collectDigestFiles(arena, io, child, rel, files, file_count, depth + 1))) return false;
            },
            .file => {
                file_count.* += 1;
                if (file_count.* > max_copy_files) return false;
                try files.append(arena, rel);
            },
            else => return false,
        }
    }
    return true;
}

fn openRelFileNoFollow(root_dir: std.Io.Dir, io: std.Io, rel: []const u8) !?std.Io.File {
    var cur = root_dir;
    var close_cur = false;
    defer if (close_cur) cur.close(io);

    var parts = std.mem.splitScalar(u8, rel, '/');
    var seg = parts.next() orelse return null;
    while (parts.next()) |next_seg| {
        const next_dir = cur.openDir(io, seg, .{ .follow_symlinks = false }) catch return null;
        if (close_cur) cur.close(io);
        cur = next_dir;
        close_cur = true;
        seg = next_seg;
    }
    return cur.openFile(io, seg, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch null;
}

fn copyDirTree(
    io: std.Io,
    src_dir: std.Io.Dir,
    dest_dir: std.Io.Dir,
    counters: *CopyCounters,
    depth: usize,
) !?Invalid {
    if (depth >= max_copy_depth) return .too_large;

    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (isSkippedSourceEntry(depth, entry.name)) continue;
        const kind = try resolveEntryKind(src_dir, io, entry.name, entry.kind);
        if (isStoreAddedEntry(depth, entry.name)) return .reserved_source_record;
        switch (kind) {
            .sym_link => return .symlink,
            .directory => {
                var child_src = src_dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.SymLinkLoop, error.NotDir => return .symlink,
                    else => return err,
                };
                defer child_src.close(io);

                try dest_dir.createDir(io, entry.name, .default_dir);
                var child_dest = try dest_dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child_dest.close(io);

                if (try copyDirTree(io, child_src, child_dest, counters, depth + 1)) |invalid| {
                    return invalid;
                }
            },
            .file => {
                counters.files += 1;
                if (counters.files > max_copy_files) return .too_large;
                if (try copySingleFile(io, src_dir, dest_dir, entry.name, counters)) |invalid| {
                    return invalid;
                }
            },
            else => return .special_file,
        }
    }
    return null;
}

fn copySingleFile(
    io: std.Io,
    src_dir: std.Io.Dir,
    dest_dir: std.Io.Dir,
    file_name: []const u8,
    counters: *CopyCounters,
) !?Invalid {
    var src_file = src_dir.openFile(io, file_name, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return .symlink,
        else => return err,
    };
    defer src_file.close(io);

    const stat = try src_file.stat(io);
    if (stat.kind != .file) return .special_file;

    var dest_file = try dest_dir.createFile(io, file_name, .{
        .exclusive = true,
        .permissions = stat.permissions,
    });
    defer dest_file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = src_file.readerStreaming(io, &read_buf);
    var transfer_buf: [copy_chunk_bytes]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&transfer_buf);
        if (n == 0) break;
        counters.bytes += n;
        if (counters.bytes > max_copy_bytes) return .too_large;
        try dest_file.writeStreamingAll(io, transfer_buf[0..n]);
    }
    return null;
}

fn collectForMod(root_dir: std.Io.Dir, io: std.Io, name: []const u8, off_name: []const u8) !void {
    var on_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var off_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const live_on = try readLiveStoreFolder(root_dir, io, name, &on_buf);
    const live_off = try readLiveStoreFolder(root_dir, io, off_name, &off_buf);

    var maybe_store: ?std.Io.Dir = root_dir.openDir(io, store_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (maybe_store) |*s| s.close(io);

    var maybe_pins: ?std.Io.Dir = try pins.openPrivatePinsDirIfPresent(root_dir, io);
    defer if (maybe_pins) |*p| p.close(io);

    if (maybe_store) |store_dir| {
        var it = store_dir.iterate();
        while (try it.next(io)) |entry| {
            if (!isVersionFolderForMod(entry.name, name)) continue;
            if (isLiveStoreFolder(live_on, live_off, entry.name)) continue;
            if (maybe_pins == null) {
                maybe_pins = try pins.openOrCreatePrivatePinsDir(root_dir, io);
            }
            try collectVersionFolder(io, store_dir, maybe_pins.?, entry.name);
        }
    }

    if (maybe_pins) |pins_dir| {
        var pin_it = pins_dir.iterate();
        while (try pin_it.next(io)) |entry| {
            if (!isVersionFolderForMod(entry.name, name)) continue;
            if (isLiveStoreFolder(live_on, live_off, entry.name)) continue;
            if (try versionFolderExists(maybe_store, io, entry.name)) continue;
            switch (try pins.tryAcquireExclusive(io, pins_dir, entry.name)) {
                .busy => {},
                .acquired => |pin_file| {
                    var f = pin_file;
                    defer {
                        f.unlock(io);
                        f.close(io);
                    }
                    pins_dir.deleteFile(io, entry.name) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    };
                },
            }
        }
    }

    var root_it = root_dir.iterate();
    while (try root_it.next(io)) |entry| {
        if (!isTempLinkForMod(entry.name, name)) continue;
        try root_dir.deleteFile(io, entry.name);
    }
}

fn collectVersionFolder(
    io: std.Io,
    store_dir: std.Io.Dir,
    pins_dir: std.Io.Dir,
    folder_name: []const u8,
) !void {
    const lock_attempt = try pins.tryAcquireExclusive(io, pins_dir, folder_name);
    switch (lock_attempt) {
        .busy => return,
        .acquired => |pin_file| {
            var f = pin_file;
            defer {
                f.unlock(io);
                f.close(io);
            }
            try store_dir.deleteTree(io, folder_name);
            pins_dir.deleteFile(io, folder_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
    }
}

fn versionFolderExists(maybe_store: ?std.Io.Dir, io: std.Io, folder_name: []const u8) !bool {
    const store_dir = maybe_store orelse return false;
    const stat = store_dir.statFile(io, folder_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .directory;
}

fn readLiveStoreFolder(
    root_dir: std.Io.Dir,
    io: std.Io,
    link_name: []const u8,
    buf: *[std.Io.Dir.max_path_bytes]u8,
) !?[]const u8 {
    const len = root_dir.readLink(io, link_name, buf) catch |err| switch (err) {
        error.FileNotFound, error.NotLink => return null,
        else => return err,
    };
    if (len >= buf.len) return null;
    const target = buf[0..len];
    const prefix = store_dir_name ++ "/";
    if (std.mem.startsWith(u8, target, prefix)) {
        return target[prefix.len..];
    }
    return std.Io.Dir.path.basename(target);
}

fn isLiveStoreFolder(live_on: ?[]const u8, live_off: ?[]const u8, candidate: []const u8) bool {
    if (live_on) |on| {
        if (std.mem.eql(u8, on, candidate)) return true;
    }
    if (live_off) |off| {
        if (std.mem.eql(u8, off, candidate)) return true;
    }
    return false;
}

fn isTempLinkForMod(entry_name: []const u8, mod_name: []const u8) bool {
    const expected_len = 1 + mod_name.len + temp_link_infix.len + token_hex_bytes;
    if (entry_name.len != expected_len) return false;
    if (entry_name[0] != '.') return false;
    if (!std.mem.eql(u8, entry_name[1 .. 1 + mod_name.len], mod_name)) return false;
    const infix_start = 1 + mod_name.len;
    if (!std.mem.eql(u8, entry_name[infix_start .. infix_start + temp_link_infix.len], temp_link_infix)) return false;
    return isLowerHex(entry_name[infix_start + temp_link_infix.len ..]);
}

const InspectedMod = union(enum) {
    ok: Mod,
    problem: ModProblem,
};

pub fn readManifestAt(
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    io: std.Io,
    link_name: []const u8,
    expected_name: []const u8,
) error{OutOfMemory}!ManifestRead {
    var mod_dir = root_dir.openDir(io, link_name, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return .{ .problem = .dangling },
        else => return .{ .problem = .{ .open_dir_failed = err } },
    };
    defer mod_dir.close(io);

    var mf_file = mod_dir.openFile(io, manifest_file_name, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .problem = .no_manifest },
        error.IsDir, error.NotDir, error.SymLinkLoop => return .{ .problem = .unreadable_manifest },
        else => return .{ .problem = .{ .open_file_failed = err } },
    };
    defer mf_file.close(io);

    const mf_stat = mf_file.stat(io) catch return .{ .problem = .unreadable_manifest };
    if (mf_stat.kind != .file) return .{ .problem = .not_regular_file };

    const bytes = readBoundedManifest(arena, io, &mf_file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .problem = .too_large },
        else => return .{ .problem = .unreadable_manifest },
    };
    const decoded = manifest.decode(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .problem = .{ .bad_manifest = err } },
    };
    if (!std.mem.eql(u8, decoded.name, expected_name)) {
        return .{ .problem = .name_mismatch };
    }
    return .{ .ok = decoded };
}

fn inspectLinkedMod(
    alloc: std.mem.Allocator,
    root_dir: std.Io.Dir,
    io: std.Io,
    root_path: []const u8,
    expected_name: []const u8,
    link_name: []const u8,
    is_on: bool,
) !InspectedMod {
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = root_dir.readLink(io, link_name, &link_buf) catch |err| switch (err) {
        error.NotLink => return .{ .problem = .not_symlink },
        error.FileNotFound, error.SymLinkLoop => return .{ .problem = .dangling },
        else => return err,
    };

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const decoded = switch (try readManifestAt(scratch, root_dir, io, link_name, expected_name)) {
        .ok => |m| m,
        .problem => |prob| return switch (prob) {
            .dangling => .{ .problem = .dangling },
            .open_dir_failed, .open_file_failed => |err| return err,
            .no_manifest => .{ .problem = .no_manifest },
            .unreadable_manifest, .not_regular_file => .{ .problem = .unreadable },
            .too_large, .bad_manifest => .{ .problem = .bad_manifest },
            .name_mismatch => .{ .problem = .name_mismatch },
        },
    };

    const version = try alloc.dupe(u8, decoded.version);
    errdefer alloc.free(version);
    const link_path = try std.Io.Dir.path.join(alloc, &.{ root_path, link_name });

    return .{ .ok = .{
        .version = version,
        .on = is_on,
        .path = link_path,
    } };
}

fn readBoundedManifest(alloc: std.mem.Allocator, io: std.Io, file: *std.Io.File) ![]u8 {
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(io, &read_buf);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try r.interface.appendRemaining(alloc, &content, .limited(manifest.max_bytes + 1));
    return content.toOwnedSlice(alloc);
}

fn entryKindNoFollow(dir: std.Io.Dir, io: std.Io, name: []const u8) !?std.Io.File.Kind {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return .sym_link,
        else => return err,
    };
    return stat.kind;
}

fn resolveEntryKind(dir: std.Io.Dir, io: std.Io, name: []const u8, hint: std.Io.File.Kind) !std.Io.File.Kind {
    if (hint != .unknown) return hint;
    return (try entryKindNoFollow(dir, io, name)) orelse .unknown;
}

fn formatOffName(buf: *[manifest.max_name_bytes + off_suffix.len]u8, name: []const u8) []const u8 {
    return std.mem.print(buf, "{s}{s}", .{ name, off_suffix }) catch unreachable;
}

fn formatTempLink(
    buf: *[1 + manifest.max_name_bytes + temp_link_infix.len + token_hex_bytes]u8,
    name: []const u8,
    token_hex: *const [token_hex_bytes]u8,
) []const u8 {
    return std.mem.print(buf, ".{s}{s}{s}", .{ name, temp_link_infix, token_hex }) catch unreachable;
}

const TestLockState = struct {
    busy: bool = false,
    held: bool = false,
    acquires: usize = 0,
    releases: usize = 0,
    steps: std.ArrayList(Step) = .empty,
    token_byte: u8 = 0x10,
};

fn testAcquireLock(
    ctx: ?*anyopaque,
    _: std.Io,
    _: []const u8,
    _: []const u8,
    _: u64,
) anyerror!LockAttempt {
    const state: *TestLockState = @ptrCast(@alignCast(ctx.?));
    state.acquires += 1;
    if (state.busy or state.held) return .busy;
    state.held = true;
    return .{ .acquired = .{
        .ctx = ctx,
        .release_fn = testReleaseLock,
    } };
}

fn testReleaseLock(self: *Lock, _: std.Io) void {
    const state: *TestLockState = @ptrCast(@alignCast(self.ctx.?));
    state.held = false;
    state.releases += 1;
}

fn testFillToken(ctx: ?*anyopaque, _: std.Io, out_hex: *[token_hex_bytes]u8) void {
    const state: *TestLockState = @ptrCast(@alignCast(ctx.?));
    const byte = state.token_byte;
    state.token_byte +%= 1;
    const raw: [token_hex_bytes / 2]u8 = @splat(byte);
    out_hex.* = std.fmt.bytesToHex(raw, .lower);
}

fn testRecordStep(ctx: ?*anyopaque, step: Step) void {
    const state: *TestLockState = @ptrCast(@alignCast(ctx.?));
    state.steps.append(std.testing.allocator, step) catch {};
}

fn testStore(root_path: []const u8, state: *TestLockState) Store {
    return .{
        .root_path = root_path,
        .ops = .{
            .io = std.testing.io,
            .ctx = state,
            .lock_deadline_ms = 0,
            .acquire_lock = testAcquireLock,
            .fill_token = testFillToken,
            .step = testRecordStep,
        },
    };
}

fn makeTempDirPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![:0]u8 {
    try tmp.dir.createDirPath(std.testing.io, sub);
    return tmp.dir.realPathFileAlloc(std.testing.io, sub, alloc);
}

fn writeFileRel(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

fn writeModSource(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    sub: []const u8,
    name: []const u8,
    version: []const u8,
) ![:0]u8 {
    const path = try makeTempDirPath(alloc, tmp, sub);
    errdefer alloc.free(path);
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer dir.close(std.testing.io);

    const json = try alloc.print("{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ name, version });
    defer alloc.free(json);
    try writeFileRel(dir, "mod.json", json);
    try writeFileRel(dir, "bin/helper", "echo ok\n");
    return path;
}

fn countEntriesInDir(dir_path: []const u8) !usize {
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

test "add, load, update, setOn and remove cover the full lifecycle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src1 = try writeModSource(alloc, &tmp, "src1", "glm", "1.0.0");
    defer alloc.free(src1);
    const src2 = try writeModSource(alloc, &tmp, "src2", "glm", "2.0.0");
    defer alloc.free(src2);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    var missing_load = try load(alloc, s, "glm");
    defer missing_load.deinit(alloc);
    try std.testing.expect(missing_load == .none);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "glm", src1, null));
    try std.testing.expectEqualSlices(Step, &.{ .start, .locked, .copy_started, .copy_done, .switched }, state.steps.items);
    try std.testing.expect(!state.held);
    try std.testing.expectEqual(@as(usize, 1), state.acquires);
    try std.testing.expectEqual(@as(usize, 1), state.releases);

    var loaded1 = try load(alloc, s, "glm");
    defer loaded1.deinit(alloc);
    try std.testing.expect(loaded1 == .mod);
    try std.testing.expectEqualStrings("1.0.0", loaded1.mod.version);
    try std.testing.expect(loaded1.mod.on);
    try std.testing.expect(std.mem.endsWith(u8, loaded1.mod.path, "/glm"));

    // A second add refuses as exists without touching the store.
    try std.testing.expectEqual(Outcome.exists, try add(alloc, s, "glm", src2, null));

    // Disable moves the link to `.off`; disabling again is a no-op ok.
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "glm", false));
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "glm", false));
    var loaded_off = try load(alloc, s, "glm");
    defer loaded_off.deinit(alloc);
    try std.testing.expect(loaded_off == .mod);
    try std.testing.expect(!loaded_off.mod.on);
    try std.testing.expect(std.mem.endsWith(u8, loaded_off.mod.path, "/glm.off"));

    // Updating while off preserves the off state and collects the old version.
    try std.testing.expectEqual(Outcome.ok, try update(alloc, s, "glm", src2, null));
    var loaded2 = try load(alloc, s, "glm");
    defer loaded2.deinit(alloc);
    try std.testing.expect(loaded2 == .mod);
    try std.testing.expectEqualStrings("2.0.0", loaded2.mod.version);
    try std.testing.expect(!loaded2.mod.on);

    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);
    try std.testing.expectEqual(@as(usize, 1), try countEntriesInDir(store_sub));

    // Enable moves the link back to `glm`; enabling again is a no-op ok.
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "glm", true));
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "glm", true));
    var loaded_on = try load(alloc, s, "glm");
    defer loaded_on.deinit(alloc);
    try std.testing.expect(loaded_on == .mod);
    try std.testing.expect(loaded_on.mod.on);

    // Remove deletes the link and the versioned copy.
    try std.testing.expectEqual(Outcome.ok, try remove(alloc, s, "glm"));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));
    var after_remove = try load(alloc, s, "glm");
    defer after_remove.deinit(alloc);
    try std.testing.expect(after_remove == .none);
}

test "missing, busy, bad_name and ambiguous outcomes are returned" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src = try writeModSource(alloc, &tmp, "src", "glm", "1.0.0");
    defer alloc.free(src);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    try std.testing.expectEqual(Outcome{ .invalid = .bad_name }, try add(alloc, s, "-bad", src, null));
    try std.testing.expectEqual(Outcome{ .invalid = .bad_name }, try update(alloc, s, "BAD", src, null));
    try std.testing.expectEqual(Outcome{ .invalid = .bad_name }, try setOn(alloc, s, "bad.off", true));
    try std.testing.expectEqual(Outcome{ .invalid = .bad_name }, try remove(alloc, s, "../escape"));

    try std.testing.expectEqual(Outcome.missing, try update(alloc, s, "glm", src, null));
    try std.testing.expectEqual(Outcome.missing, try setOn(alloc, s, "glm", false));
    try std.testing.expectEqual(Outcome.missing, try remove(alloc, s, "glm"));

    state.busy = true;
    try std.testing.expectEqual(Outcome.busy, try add(alloc, s, "glm", src, null));
    try std.testing.expectEqual(Outcome.busy, try update(alloc, s, "glm", src, null));
    try std.testing.expectEqual(Outcome.busy, try setOn(alloc, s, "glm", true));
    try std.testing.expectEqual(Outcome.busy, try remove(alloc, s, "glm"));
    state.busy = false;

    // Create both links for one mod -> ambiguous on mutations and bad on load.
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000001", "glm", .{ .is_directory = true });
    try root_dir.symLink(std.testing.io, ".store/glm-0000000000000002", "glm.off", .{ .is_directory = true });

    try std.testing.expectEqual(Outcome{ .invalid = .ambiguous }, try add(alloc, s, "glm", src, null));
    try std.testing.expectEqual(Outcome{ .invalid = .ambiguous }, try update(alloc, s, "glm", src, null));
    try std.testing.expectEqual(Outcome{ .invalid = .ambiguous }, try setOn(alloc, s, "glm", false));
    try std.testing.expectEqual(Outcome{ .invalid = .ambiguous }, try remove(alloc, s, "glm"));

    var ambig = try load(alloc, s, "glm");
    defer ambig.deinit(alloc);
    try std.testing.expect(ambig == .bad);
}

test "copy refusals: no_manifest, bad_manifest, name_mismatch, symlink, special_file and too_large" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    // 1. no_manifest
    const no_mf = try makeTempDirPath(alloc, &tmp, "no_mf");
    defer alloc.free(no_mf);
    try std.testing.expectEqual(Outcome{ .invalid = .no_manifest }, try add(alloc, s, "glm", no_mf, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 2. bad_manifest
    const bad_mf = try makeTempDirPath(alloc, &tmp, "bad_mf");
    defer alloc.free(bad_mf);
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, bad_mf, .{});
        defer dir.close(std.testing.io);
        try writeFileRel(dir, "mod.json", "{\"name\":\"glm\",\"version\":\"1\",\"extra\":1}");
    }
    try std.testing.expectEqual(Outcome{ .invalid = .bad_manifest }, try add(alloc, s, "glm", bad_mf, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 3. name_mismatch
    const mismatch = try writeModSource(alloc, &tmp, "mismatch", "other", "1.0.0");
    defer alloc.free(mismatch);
    try std.testing.expectEqual(Outcome{ .invalid = .name_mismatch }, try add(alloc, s, "glm", mismatch, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 4. symlink
    const sym_src = try writeModSource(alloc, &tmp, "sym_src", "glm", "1.0.0");
    defer alloc.free(sym_src);
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, sym_src, .{});
        defer dir.close(std.testing.io);
        try dir.symLink(std.testing.io, "mod.json", "escape", .{ .is_directory = false });
    }
    try std.testing.expectEqual(Outcome{ .invalid = .symlink }, try add(alloc, s, "glm", sym_src, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 5. special_file (FIFO)
    const fifo_src = try writeModSource(alloc, &tmp, "fifo_src", "glm", "1.0.0");
    defer alloc.free(fifo_src);
    const fifo_path = try std.Io.Dir.path.join(alloc, &.{ fifo_src, "pipe" });
    defer alloc.free(fifo_path);
    const mkfifo_res = try std.process.run(alloc, std.testing.io, .{ .argv = &.{ "mkfifo", fifo_path } });
    defer alloc.free(mkfifo_res.stdout);
    defer alloc.free(mkfifo_res.stderr);
    try std.testing.expect(mkfifo_res.term == .exited and mkfifo_res.term.exited == 0);
    try std.testing.expectEqual(Outcome{ .invalid = .special_file }, try add(alloc, s, "glm", fifo_src, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 6. too_large by file count (> 4096 files)
    const many_src = try writeModSource(alloc, &tmp, "many_src", "glm", "1.0.0");
    defer alloc.free(many_src);
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, many_src, .{});
        defer dir.close(std.testing.io);
        // writeModSource created 2 files (`mod.json` and `bin/helper`). Add 4095 more -> 4097 total.
        for (0..4095) |i| {
            var name_buf: [32]u8 = undefined;
            const file_name = try std.mem.print(&name_buf, "f{d}", .{i});
            try dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = "" });
        }
    }
    try std.testing.expectEqual(Outcome{ .invalid = .too_large }, try add(alloc, s, "glm", many_src, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));

    // 7. too_large by byte count (> 64 MiB)
    const big_src = try writeModSource(alloc, &tmp, "big_src", "glm", "1.0.0");
    defer alloc.free(big_src);
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, big_src, .{});
        defer dir.close(std.testing.io);
        var f = try dir.createFile(std.testing.io, "blob", .{});
        defer f.close(std.testing.io);
        const chunk: [64 * 1024]u8 = @splat('a');
        // 1024 * 64 KiB = 64 MiB, which combined with mod.json + bin/helper exceeds 64 MiB.
        for (0..1024) |_| {
            try f.writeStreamingAll(std.testing.io, &chunk);
        }
    }
    try std.testing.expectEqual(Outcome{ .invalid = .too_large }, try add(alloc, s, "glm", big_src, null));
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(store_sub));
}

test "a leftover version folder and temp link from a killed update are collected without touching prefix-siblings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src_foo1 = try writeModSource(alloc, &tmp, "foo1", "foo", "1.0.0");
    defer alloc.free(src_foo1);
    const src_foo2 = try writeModSource(alloc, &tmp, "foo2", "foo", "2.0.0");
    defer alloc.free(src_foo2);
    const src_sib = try writeModSource(alloc, &tmp, "foobar", "foo-bar", "1.0.0");
    defer alloc.free(src_sib);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "foo", src_foo1, null));
    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "foo-bar", src_sib, null));

    // Plant leftovers from a killed update of `foo`.
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer root_dir.close(std.testing.io);
    try root_dir.createDirPath(std.testing.io, ".store/foo-deadbeef01234567");
    try root_dir.symLink(std.testing.io, ".store/foo-deadbeef01234567", ".foo.link-deadbeef01234567", .{ .is_directory = true });

    try std.testing.expectEqual(Outcome.ok, try update(alloc, s, "foo", src_foo2, null));

    // Leftover folder and temp link are gone; `foo` v2 and `foo-bar` v1 remain.
    try std.testing.expect((try entryKindNoFollow(root_dir, std.testing.io, ".foo.link-deadbeef01234567")) == null);
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);
    try std.testing.expectEqual(@as(usize, 2), try countEntriesInDir(store_sub));

    var foo_loaded = try load(alloc, s, "foo");
    defer foo_loaded.deinit(alloc);
    try std.testing.expectEqualStrings("2.0.0", foo_loaded.mod.version);

    var sib_loaded = try load(alloc, s, "foo-bar");
    defer sib_loaded.deinit(alloc);
    try std.testing.expectEqualStrings("1.0.0", sib_loaded.mod.version);
}

test "load returns bad for dangling link, missing manifest, bad manifest and name mismatch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    // Dangling link.
    try root_dir.symLink(std.testing.io, ".store/dangling-0000000000000001", "dangling", .{ .is_directory = true });
    var d = try load(alloc, s, "dangling");
    defer d.deinit(alloc);
    try std.testing.expect(d == .bad);

    // Target directory missing mod.json.
    try root_dir.createDirPath(std.testing.io, ".store/nomf-0000000000000001");
    try root_dir.symLink(std.testing.io, ".store/nomf-0000000000000001", "nomf", .{ .is_directory = true });
    var nm = try load(alloc, s, "nomf");
    defer nm.deinit(alloc);
    try std.testing.expect(nm == .bad);

    // Target directory with invalid mod.json.
    try root_dir.createDirPath(std.testing.io, ".store/badmf-0000000000000001");
    try writeFileRel(root_dir, ".store/badmf-0000000000000001/mod.json", "{not json");
    try root_dir.symLink(std.testing.io, ".store/badmf-0000000000000001", "badmf", .{ .is_directory = true });
    var bm = try load(alloc, s, "badmf");
    defer bm.deinit(alloc);
    try std.testing.expect(bm == .bad);

    // Target directory with mismatched manifest name.
    try root_dir.createDirPath(std.testing.io, ".store/wrong-0000000000000001");
    try writeFileRel(root_dir, ".store/wrong-0000000000000001/mod.json", "{\"name\":\"other\",\"version\":\"1\"}");
    try root_dir.symLink(std.testing.io, ".store/wrong-0000000000000001", "wrong", .{ .is_directory = true });
    var wm = try load(alloc, s, "wrong");
    defer wm.deinit(alloc);
    try std.testing.expect(wm == .bad);
}

test "list handles 0 mods, 2 mods, dot entries, both links for one mod and max_mods bound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_root = try std.Io.Dir.path.join(alloc, &.{ ".", "nonexistent-mods-root" });
    defer alloc.free(missing_root);
    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);

    // 0 mods on missing root.
    var empty_missing = try list(alloc, testStore(missing_root, &state));
    defer empty_missing.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty_missing.mods.len);
    try std.testing.expect(!empty_missing.over_limit);

    // 0 mods on empty existing root with a dot entry.
    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    try writeFileRel(root_dir, ".hidden", "ignored");
    try root_dir.createDirPath(std.testing.io, ".store");

    const s = testStore(root, &state);
    var empty_list = try list(alloc, s);
    defer empty_list.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty_list.mods.len);

    // 2 mods (one on, one off) + dot entry.
    const src_a = try writeModSource(alloc, &tmp, "src_a", "alpha", "1.0.0");
    defer alloc.free(src_a);
    const src_b = try writeModSource(alloc, &tmp, "src_b", "beta", "2.0.0");
    defer alloc.free(src_b);
    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "beta", src_b, null));
    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "alpha", src_a, null));
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "beta", false));

    var two = try list(alloc, s);
    defer two.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), two.mods.len);
    try std.testing.expectEqualStrings("alpha", two.mods[0].name);
    try std.testing.expect(two.mods[0].on);
    try std.testing.expectEqualStrings("1.0.0", two.mods[0].version.?);
    try std.testing.expect(two.mods[0].problem == null);
    try std.testing.expectEqualStrings("beta", two.mods[1].name);
    try std.testing.expect(!two.mods[1].on);
    try std.testing.expectEqualStrings("2.0.0", two.mods[1].version.?);
    try std.testing.expect(two.mods[1].problem == null);

    // Both links for one mod -> ambiguous problem in list.
    try root_dir.symLink(std.testing.io, ".store/alpha-0000000000000001", "alpha.off", .{ .is_directory = true });
    var with_ambig = try list(alloc, s);
    defer with_ambig.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), with_ambig.mods.len);
    try std.testing.expectEqualStrings("alpha", with_ambig.mods[0].name);
    try std.testing.expectEqual(ModProblem.ambiguous, with_ambig.mods[0].problem.?);

    // Exceeding max_mods bounds the list to 32 and sets over_limit.
    for (0..manifest.max_mods + 1) |i| {
        var name_buf: [16]u8 = undefined;
        const m_name = try std.mem.print(&name_buf, "mod-{d:0>2}", .{i});
        try root_dir.symLink(std.testing.io, ".store/missing", m_name, .{ .is_directory = true });
    }
    var bounded = try list(alloc, s);
    defer bounded.deinit(alloc);
    try std.testing.expectEqual(manifest.max_mods, bounded.mods.len);
    try std.testing.expect(bounded.over_limit);
}

test "a source record is written with the version and read back through the link, enabled or disabled" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src_v1 = try writeModSource(alloc, &tmp, "src1", "glm", "1.0.0");
    defer alloc.free(src_v1);
    const src_v2 = try writeModSource(alloc, &tmp, "src2", "glm", "2.0.0");
    defer alloc.free(src_v2);
    const src_bare = try writeModSource(alloc, &tmp, "src3", "bar", "1.0.0");
    defer alloc.free(src_bare);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "glm", src_v1, "{\"source\":\"one\"}"));
    const first = (try readRecord(alloc, s, "glm")).?;
    defer alloc.free(first);
    try std.testing.expectEqualStrings("{\"source\":\"one\"}", first);

    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, s, "glm", false));
    const disabled = (try readRecord(alloc, s, "glm")).?;
    defer alloc.free(disabled);
    try std.testing.expectEqualStrings("{\"source\":\"one\"}", disabled);

    try std.testing.expectEqual(Outcome.ok, try update(alloc, s, "glm", src_v2, "{\"source\":\"two\"}"));
    const second = (try readRecord(alloc, s, "glm")).?;
    defer alloc.free(second);
    try std.testing.expectEqualStrings("{\"source\":\"two\"}", second);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "bar", src_bare, null));
    try std.testing.expect((try readRecord(alloc, s, "bar")) == null);
    try std.testing.expect((try readRecord(alloc, s, "missing")) == null);
}

test "a source that ships its own source record is refused as reserved" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src = try writeModSource(alloc, &tmp, "src", "glm", "1.0.0");
    defer alloc.free(src);
    {
        var src_dir = try std.Io.Dir.cwd().openDir(std.testing.io, src, .{});
        defer src_dir.close(std.testing.io);
        try writeFileRel(src_dir, record_file_name, "{}");
    }

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);
    try std.testing.expectEqual(Outcome{ .invalid = .reserved_source_record }, try add(alloc, s, "glm", src, null));

    var loaded = try load(alloc, s, "glm");
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded == .none);
}

test "pin keeps old version during cleanup until released, then cleanup deletes folder and pin file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src1 = try writeModSource(alloc, &tmp, "src1", "glm", "1.0.0");
    defer alloc.free(src1);
    const src2 = try writeModSource(alloc, &tmp, "src2", "glm", "2.0.0");
    defer alloc.free(src2);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "glm", src1, null));

    const pinned_res = try pins.pin(alloc, root, "glm", .{ .io = std.testing.io, .lock_deadline_ms = 20 });
    try std.testing.expect(pinned_res == .pinned);
    var p1 = pinned_res.pinned;
    var p1_released = false;
    defer if (!p1_released) p1.release(alloc, std.testing.io);

    // Updating while v1 is pinned keeps v1 in `.store/`.
    try std.testing.expectEqual(Outcome.ok, try update(alloc, s, "glm", src2, null));
    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);
    try std.testing.expectEqual(@as(usize, 2), try countEntriesInDir(store_sub));

    // Releasing v1 and calling `collect` removes v1 and its pin file.
    p1.release(alloc, std.testing.io);
    p1_released = true;
    try std.testing.expectEqual(Outcome.ok, try collect(s, "glm"));
    try std.testing.expectEqual(@as(usize, 1), try countEntriesInDir(store_sub));

    const pins_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".locks", "pins" });
    defer alloc.free(pins_sub);
    try std.testing.expectEqual(@as(usize, 0), try countEntriesInDir(pins_sub));
}

test "cleanup sweeps stray pin files and keeps versions held by a second open of the pin file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try makeTempDirPath(alloc, &tmp, "mods");
    defer alloc.free(root);
    const src1 = try writeModSource(alloc, &tmp, "src1", "glm", "1.0.0");
    defer alloc.free(src1);
    const src2 = try writeModSource(alloc, &tmp, "src2", "glm", "2.0.0");
    defer alloc.free(src2);

    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);

    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "glm", src1, null));

    var root_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{});
    defer root_dir.close(std.testing.io);
    var pins_dir = try pins.openOrCreatePrivatePinsDir(root_dir, std.testing.io);
    defer pins_dir.close(std.testing.io);

    // Hold a shared flock on v1's pin file via a direct open in the same process.
    const v1_folder = "glm-1010101010101010";
    var v1_pin = try pins_dir.createFile(std.testing.io, v1_folder, .{ .read = true, .truncate = false });
    defer v1_pin.close(std.testing.io);
    try v1_pin.lock(std.testing.io, .shared);

    // Create two stray pin files (no `.store` folder): one unlocked, one held by another mod's lock.
    const stray_free = "glm-aaaaaaaaaaaaaaaa";
    const stray_busy = "glm-bbbbbbbbbbbbbbbb";
    const other_stray = "other-cccccccccccccccc";
    (try pins_dir.createFile(std.testing.io, stray_free, .{ .read = true, .truncate = false })).close(std.testing.io);
    var busy_stray_file = try pins_dir.createFile(std.testing.io, stray_busy, .{ .read = true, .truncate = false });
    defer busy_stray_file.close(std.testing.io);
    try busy_stray_file.lock(std.testing.io, .shared);
    (try pins_dir.createFile(std.testing.io, other_stray, .{ .read = true, .truncate = false })).close(std.testing.io);

    try std.testing.expectEqual(Outcome.ok, try update(alloc, s, "glm", src2, null));

    const store_sub = try std.Io.Dir.path.join(alloc, &.{ root, ".store" });
    defer alloc.free(store_sub);
    // v1 is kept because its pin file is locked; v2 is live.
    try std.testing.expectEqual(@as(usize, 2), try countEntriesInDir(store_sub));

    // `stray_free` was swept; `v1_folder`, `stray_busy`, and `other_stray` stay.
    try std.testing.expectError(error.FileNotFound, pins_dir.statFile(std.testing.io, stray_free, .{}));
    _ = try pins_dir.statFile(std.testing.io, v1_folder, .{});
    _ = try pins_dir.statFile(std.testing.io, stray_busy, .{});
    _ = try pins_dir.statFile(std.testing.io, other_stray, .{});

    v1_pin.unlock(std.testing.io);
    busy_stray_file.unlock(std.testing.io);
    try std.testing.expectEqual(Outcome.ok, try collect(s, "glm"));
    try std.testing.expectEqual(@as(usize, 1), try countEntriesInDir(store_sub));
    try std.testing.expectError(error.FileNotFound, pins_dir.statFile(std.testing.io, v1_folder, .{}));
    try std.testing.expectError(error.FileNotFound, pins_dir.statFile(std.testing.io, stray_busy, .{}));
    _ = try pins_dir.statFile(std.testing.io, other_stray, .{});
}

test "treeDigest hashes regular files in sorted path order, ignores .git and source record, and matches a store copy" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src = try writeModSource(alloc, &tmp, "src", "glm", "1.0.0");
    defer alloc.free(src);
    var src_dir = try std.Io.Dir.cwd().openDir(io, src, .{});
    defer src_dir.close(io);
    try writeFileRel(src_dir, "bin/auth", "#!/bin/sh\necho ok\n");

    const base = treeDigest(alloc, io, src).?;
    // Same tree gives the same digest.
    try std.testing.expectEqualSlices(u8, &base, &treeDigest(alloc, io, src).?);

    // Skipped `.git` and store-added `.fx-mod-source.json` do not change the digest.
    try writeFileRel(src_dir, ".git/HEAD", "ref: refs/heads/main\n");
    try std.testing.expectEqualSlices(u8, &base, &treeDigest(alloc, io, src).?);

    // A fresh store copy (including its `.fx-mod-source.json` and stripped `.git`) hashes equal to its source.
    const root = try makeTempDirPath(alloc, &tmp, "root");
    defer alloc.free(root);
    var state: TestLockState = .{};
    defer state.steps.deinit(alloc);
    const s = testStore(root, &state);
    try std.testing.expectEqual(Outcome.ok, try add(alloc, s, "glm", src, "{\"source\":\"/tmp/src\",\"pinned\":false}"));
    const link_path = try std.Io.Dir.path.join(alloc, &.{ root, "glm" });
    defer alloc.free(link_path);
    const installed_digest = treeDigest(alloc, io, link_path).?;
    try std.testing.expectEqualSlices(u8, &base, &installed_digest);

    // Adding `.fx-mod-source.json` directly in a tree does not change its digest either.
    try writeFileRel(src_dir, record_file_name, "{\"source\":\"other\"}");
    try std.testing.expectEqualSlices(u8, &base, &treeDigest(alloc, io, src).?);

    // Changing the executable bit gives a new digest.
    var auth_file = try src_dir.openFile(io, "bin/auth", .{ .mode = .read_write });
    try auth_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    auth_file.close(io);
    const after_exec = treeDigest(alloc, io, src).?;
    try std.testing.expect(!std.mem.eql(u8, &base, &after_exec));

    // Changing a byte gives a new digest.
    try writeFileRel(src_dir, "bin/auth", "#!/bin/sh\necho hi\n");
    const after_byte = treeDigest(alloc, io, src).?;
    try std.testing.expect(!std.mem.eql(u8, &after_exec, &after_byte));

    // Renaming a file gives a new digest.
    try src_dir.rename("bin/auth", src_dir, "bin/auth2", io);
    const after_rename = treeDigest(alloc, io, src).?;
    try std.testing.expect(!std.mem.eql(u8, &after_byte, &after_rename));

    // A symlink inside the tree returns null.
    try src_dir.symLink(io, "mod.json", "link.json", .{});
    try std.testing.expect(treeDigest(alloc, io, src) == null);
}
