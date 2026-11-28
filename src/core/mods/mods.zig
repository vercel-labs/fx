//! Front door for the mod store and manifest (`RULES.md` R1.1, R1.7).
//!
//! Outside code imports only this file. It re-exports `manifest` and `store`
//! contracts and provides the production `Ops` backed by `src/core/shared/io.zig`.

const std = @import("std");
const configured_provider = @import("../config/configured_provider.zig");
const io_mod = @import("../shared/io.zig");
const bounded_process = @import("../shared/bounded_process.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const manifest = @import("manifest.zig");
pub const mcp_config = @import("mcp_config.zig");
pub const mod_pins = @import("mod_pins.zig");
pub const pins = @import("pins.zig");
pub const source = @import("source.zig");
pub const store = @import("store.zig");

pub const Manifest = manifest.Manifest;
pub const ModPins = mod_pins.ModPins;
pub const ModRoot = mod_pins.ModRoot;
pub const ModRoots = mod_pins.ModRoots;
pub const RootKind = mod_pins.RootKind;
pub const Pin = pins.Pin;
pub const PinResult = pins.PinResult;
pub const PinOps = pins.Ops;
pub const Step = store.Step;
pub const Outcome = store.Outcome;
pub const Invalid = store.Invalid;
pub const Mod = store.Mod;
pub const Loaded = store.Loaded;
pub const ListedMod = store.ListedMod;
pub const ModProblem = store.ModProblem;
pub const Listing = store.Listing;
pub const Store = store.Store;
pub const Ops = store.Ops;
pub const default_lock_deadline_ms: u64 = store.default_lock_deadline_ms;

const locks_dir_name = ".locks";

pub fn realOps() Ops {
    return .{
        .io = io_mod.getIo(),
        .lock_deadline_ms = default_lock_deadline_ms,
        .acquire_lock = acquireRealModLock,
    };
}

pub fn realPinOps() PinOps {
    return .{
        .io = io_mod.getIo(),
        .lock_deadline_ms = default_lock_deadline_ms,
        .prepare_pins_dir = prepareRealPinsDir,
    };
}

pub fn realModPinsOps() ModPins.Ops {
    return .{
        .store_ops = realOps(),
        .pin_ops = realPinOps(),
    };
}

pub fn loadModPins(alloc: std.mem.Allocator, root_path: []const u8) !ModPins {
    return ModPins.load(alloc, root_path, realModPinsOps());
}

pub fn withPinnedMods(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    ctx: anytype,
    comptime R: type,
    comptime body: fn (@TypeOf(ctx), *const ModPins) anyerror!R,
) !R {
    return mod_pins.withPinnedMods(alloc, root_path, realModPinsOps(), ctx, R, body);
}

pub fn pin(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8) !PinResult {
    return pins.pin(alloc, root_path, name, realPinOps());
}

pub fn reloadPin(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8, old_pin: *?Pin) !PinResult {
    return pins.reload(alloc, root_path, name, old_pin, realPinOps());
}

pub fn collect(root_path: []const u8, name: []const u8) !Outcome {
    return store.collect(realStore(root_path), name);
}

pub fn realStore(root_path: []const u8) Store {
    return .{
        .root_path = root_path,
        .ops = realOps(),
    };
}

pub fn add(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8, source_dir: []const u8) !Outcome {
    return store.add(alloc, realStore(root_path), name, source_dir, null);
}

pub fn update(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8, source_dir: []const u8) !Outcome {
    return store.update(alloc, realStore(root_path), name, source_dir, null);
}

pub fn readRecord(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8) !?[]u8 {
    return store.readRecord(alloc, realStore(root_path), name);
}

pub fn setOn(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8, on: bool) !Outcome {
    return store.setOn(alloc, realStore(root_path), name, on);
}

pub fn remove(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8) !Outcome {
    return store.remove(alloc, realStore(root_path), name);
}

pub fn load(alloc: std.mem.Allocator, root_path: []const u8, name: []const u8) !Loaded {
    return store.load(alloc, realStore(root_path), name);
}

pub fn list(alloc: std.mem.Allocator, root_path: []const u8) !Listing {
    return store.list(alloc, realStore(root_path));
}

pub const Installed = struct {
    name: []const u8,
    version: []const u8,
    /// The URL or the folder the mod came from, as the record keeps it.
    source: []const u8,
    /// The commit a git source was cloned at; null for a folder.
    commit: ?[]const u8,
};

pub const InstallResult = union(enum) {
    installed: Installed,
    not_a_folder: []const u8,
    source_invalid: source.Problem,
    fetch_failed: source.Failed,
    no_manifest,
    bad_manifest: manifest.DecodeError,
    /// The store said `exists`, `busy`, `missing`, or refused the copy as `invalid`.
    refused: store.Outcome,
};

pub const Updated = struct {
    old_commit: ?[]const u8,
    new_commit: []const u8,
};

pub const RefreshResult = union(enum) {
    not_installed,
    bad_mod,
    no_record,
    bad_record,
    pinned: []const u8,
    up_to_date: []const u8,
    updated: Updated,
    folder_copied,
    source_missing: []const u8,
    fetch_failed: source.Failed,
    refused: store.Outcome,
};

pub const PreparedUpdate = struct {
    name: []const u8,
    is_git: bool,
    old_commit: ?[]const u8 = null,
    new_commit: ?[]const u8 = null,
    files_changed: bool = true,
    old_providers: ?configured_provider.Registry = null,
    install: PreparedInstall,

    pub fn discard(self: *PreparedUpdate, alloc: std.mem.Allocator) void {
        if (self.old_providers) |*reg| reg.deinit(alloc);
        self.install.discard(alloc);
        self.* = undefined;
    }
};

pub const PrepareUpdateResult = union(enum) {
    prepared: PreparedUpdate,
    not_installed,
    bad_mod,
    no_record,
    bad_record,
    pinned: []const u8,
    up_to_date: []const u8,
    source_missing: []const u8,
    fetch_failed: source.Failed,
    no_manifest,
    bad_manifest: manifest.DecodeError,
    bad_providers: struct {
        path: []const u8,
        err: anyerror,
    },
    bad_mcp: struct {
        server: []const u8,
        reason: []const u8,
    },
    refused: store.Outcome,
};

pub const PreparedInstall = struct {
    manifest: manifest.Manifest,
    providers: ?configured_provider.Registry = null,
    dir: []const u8,
    source: []const u8,
    commit: ?[]const u8,
    record: []const u8,
    temp_to_discard: ?[]const u8 = null,
    arena: *std.heap.ArenaAllocator,

    pub fn discard(self: *PreparedInstall, alloc: std.mem.Allocator) void {
        if (self.temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
        if (self.providers) |*reg| reg.deinit(alloc);
        self.arena.deinit();
        alloc.destroy(self.arena);
        self.* = undefined;
    }
};

pub const PrepareResult = union(enum) {
    prepared: PreparedInstall,
    not_a_folder: []const u8,
    source_invalid: source.Problem,
    fetch_failed: source.Failed,
    no_manifest,
    bad_manifest: manifest.DecodeError,
    bad_providers: struct {
        path: []const u8,
        err: anyerror,
    },
    bad_mcp: struct {
        server: []const u8,
        reason: []const u8,
    },
};

/// Prepares `arg` (folder or git URL[@ref]) for installation without writing to
/// the mod store yet: validates the source, decodes `mod.json`, and parses any
/// `providers` with `<root_path>/<name>` as base. Caller passes an arena for
/// error slices and must call `prepared.discard(alloc)` after `commitInstall` or
/// on cancellation.
pub fn prepareInstall(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    arg: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !PrepareResult {
    sweepStaleFetches(io_mod.getIo(), root_path) catch |err| {
        debug_trace.logf("mods", "could not clear old fetches: {s}", .{@errorName(err)});
    };
    return switch (source.parse(arg)) {
        .invalid => |problem| .{ .source_invalid = problem },
        .local => |path| prepareLocal(alloc, root_path, path),
        .git => |git| prepareGit(alloc, root_path, git, cancel),
    };
}

/// Commits a prepared mod into the store under its lock. Caller still calls
/// `prepared.discard(alloc)` afterward to remove any git temp clone and free
/// memory.
pub fn commitInstall(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    prepared: *const PreparedInstall,
) !InstallResult {
    const outcome = try store.add(alloc, realStore(root_path), prepared.manifest.name, prepared.dir, prepared.record);
    return switch (outcome) {
        .ok => .{ .installed = .{
            .name = prepared.manifest.name,
            .version = prepared.manifest.version,
            .source = prepared.source,
            .commit = prepared.commit,
        } },
        else => .{ .refused = outcome },
    };
}

/// Every slice of a result lives in `alloc`; pass an arena. `cancel`, when set
/// and true, stops a running clone.
pub fn install(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    arg: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !InstallResult {
    return switch (try prepareInstall(alloc, root_path, arg, cancel)) {
        .prepared => |prep| blk: {
            var prepared = prep;
            defer prepared.discard(alloc);
            break :blk commitInstall(alloc, root_path, &prepared);
        },
        .not_a_folder => |path| .{ .not_a_folder = path },
        .source_invalid => |problem| .{ .source_invalid = problem },
        .fetch_failed => |failed| .{ .fetch_failed = failed },
        .no_manifest => .no_manifest,
        .bad_manifest => |err| .{ .bad_manifest = err },
        .bad_providers => |bad| .{ .refused = .{ .invalid = switch (bad.err) {
            else => .bad_manifest,
        } } },
        .bad_mcp => .{ .refused = .{ .invalid = .bad_manifest } },
    };
}

/// Prepares an update for installed mod `name` without modifying the store:
/// reads the currently installed providers (under a short pin when enabled),
/// fetches the new version, decodes `mod.json`, and parses any new providers.
/// On `.prepared`, caller must call `prepared.discard(alloc)` afterward.
pub fn prepareUpdate(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    name: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !PrepareUpdateResult {
    var loaded = try store.load(alloc, realStore(root_path), name);
    defer loaded.deinit(alloc);
    const old_mod = switch (loaded) {
        .none => return .not_installed,
        .bad => return .bad_mod,
        .mod => |m| m,
    };
    const old_on = old_mod.on;
    const old_path_copy = try alloc.dupe(u8, old_mod.path);
    defer alloc.free(old_path_copy);

    const maybe_bytes = store.readRecord(alloc, realStore(root_path), name) catch |err| switch (err) {
        error.RecordTooLarge => return .bad_record,
        else => return err,
    };
    const bytes = maybe_bytes orelse return .no_record;
    const record = source.decodeRecord(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRecord => return .bad_record,
    };
    if (record.pinned) return .{ .pinned = record.ref orelse "" };

    var is_git = false;
    var prep_res: PrepareResult = undefined;
    switch (source.parse(record.source)) {
        .git => |git| {
            is_git = true;
            const scratch = try std.Io.Dir.path.join(alloc, &.{ root_path, scratch_dir_name });
            defer alloc.free(scratch);
            const fetched = switch (try source.fetch(alloc, gitOps(), git, scratch, cancel)) {
                .ok => |ok| ok,
                .failed => |failed| return .{ .fetch_failed = failed },
            };
            if (record.commit) |old_commit| {
                if (std.mem.eql(u8, old_commit, fetched.commit)) {
                    source.discard(io_mod.getIo(), fetched.temp);
                    return .{ .up_to_date = fetched.commit };
                }
            }
            prep_res = try prepareFrom(alloc, root_path, fetched.dir, git.url, fetched.commit, fetched.record, fetched.temp);
        },
        .local => |path| {
            const folder = (try resolveFolder(alloc, io_mod.getIo(), path)) orelse return .{ .source_missing = path };
            defer alloc.free(folder);
            const new_record = try source.folderRecord(alloc, folder);
            defer alloc.free(new_record);
            prep_res = try prepareFrom(alloc, root_path, folder, folder, null, new_record, null);
        },
        .invalid => return .bad_record,
    }

    switch (prep_res) {
        .prepared => |p| {
            var p_mut = p;
            if (!std.mem.eql(u8, p.manifest.name, name)) {
                p_mut.discard(alloc);
                return .{ .refused = .{ .invalid = .name_mismatch } };
            }
            const owned = p.arena.allocator();
            const old_commit_copy = if (record.commit) |c| try owned.dupe(u8, c) else null;
            const old_state = readInstalledState(alloc, root_path, name, old_on, old_path_copy);
            const new_digest = store.treeDigest(alloc, io_mod.getIo(), p.dir);
            const files_changed = if (old_state.digest != null and new_digest != null)
                !std.mem.eql(u8, &old_state.digest.?, &new_digest.?)
            else
                true;
            return .{ .prepared = .{
                .name = try owned.dupe(u8, name),
                .is_git = is_git,
                .old_commit = old_commit_copy,
                .new_commit = p.commit,
                .files_changed = files_changed,
                .old_providers = old_state.providers,
                .install = p,
            } };
        },
        .not_a_folder => |path| return .{ .source_missing = path },
        .source_invalid => return .bad_record,
        .fetch_failed => |failed| return .{ .fetch_failed = failed },
        .no_manifest => return .no_manifest,
        .bad_manifest => |err| return .{ .bad_manifest = err },
        .bad_providers => |bad| return .{ .bad_providers = .{ .path = bad.path, .err = bad.err } },
        .bad_mcp => |bad| return .{ .bad_mcp = .{ .server = bad.server, .reason = bad.reason } },
    }
}

const InstalledState = struct {
    providers: ?configured_provider.Registry = null,
    digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
};

fn readInstalledState(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    name: []const u8,
    old_on: bool,
    old_link_path: []const u8,
) InstalledState {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var pinned_opt: ?Pin = null;
    defer if (pinned_opt) |*p| p.release(alloc, io_mod.getIo());

    const read_dir: []const u8 = if (old_on) blk: {
        switch (pin(alloc, root_path, name) catch return .{}) {
            .pinned => |p| {
                pinned_opt = p;
                break :blk p.path;
            },
            .not_installed, .bad_link, .busy => return .{},
        }
    } else old_link_path;

    const digest = store.treeDigest(alloc, io_mod.getIo(), read_dir);
    const decoded = switch (readManifest(scratch, io_mod.getIo(), read_dir) catch return .{ .digest = digest }) {
        .ok => |m| m,
        .missing, .bad => return .{ .digest = digest },
    };
    const providers_val = decoded.providers orelse return .{ .digest = digest };
    const canonical_link = std.Io.Dir.path.join(scratch, &.{ root_path, name }) catch return .{ .digest = digest };
    var at: configured_provider.FailurePath = .{};
    const reg = configured_provider.Registry.parse_located_for_mod(
        alloc,
        providers_val,
        &at,
        .{ .name = name, .dir = canonical_link },
    ) catch null;
    return .{ .providers = reg, .digest = digest };
}

/// Commits a prepared update into the store under its lock.
pub fn commitUpdate(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    prepared: *const PreparedUpdate,
) !RefreshResult {
    const outcome = try store.update(alloc, realStore(root_path), prepared.name, prepared.install.dir, prepared.install.record);
    return switch (outcome) {
        .ok => if (prepared.is_git)
            .{ .updated = .{ .old_commit = prepared.old_commit, .new_commit = prepared.new_commit orelse "" } }
        else
            .folder_copied,
        else => .{ .refused = outcome },
    };
}

/// A pinned mod is left alone. A git mod fetches its default branch: the same
/// commit is up to date, and a new one replaces the mod. A folder mod copies
/// the folder again when it still exists.
pub fn refresh(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    name: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !RefreshResult {
    return switch (try prepareUpdate(alloc, root_path, name, cancel)) {
        .prepared => |prep_const| blk: {
            var prep = prep_const;
            defer prep.discard(alloc);
            break :blk commitUpdate(alloc, root_path, &prep);
        },
        .not_installed => .not_installed,
        .bad_mod => .bad_mod,
        .no_record => .no_record,
        .bad_record => .bad_record,
        .pinned => |ref| .{ .pinned = ref },
        .up_to_date => |commit| .{ .up_to_date = commit },
        .source_missing => |path| .{ .source_missing = path },
        .fetch_failed => |failed| .{ .fetch_failed = failed },
        .no_manifest => .{ .refused = .{ .invalid = .no_manifest } },
        .bad_manifest => .{ .refused = .{ .invalid = .bad_manifest } },
        .bad_providers => .{ .refused = .{ .invalid = .bad_manifest } },
        .bad_mcp => .{ .refused = .{ .invalid = .bad_manifest } },
        .refused => |outcome| .{ .refused = outcome },
    };
}

const scratch_dir_name = ".fetch";

/// A fetch is at most one clone deadline long, so an entry older than an hour
/// was left by an install that was killed.
const stale_fetch_age_ns: i96 = std.time.ns_per_hour;

fn sweepStaleFetches(io: std.Io, root_path: []const u8) !void {
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root_dir.close(io);
    var fetch_dir = root_dir.openDir(io, scratch_dir_name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer fetch_dir.close(io);

    const now_ns = std.Io.Clock.real.now(io).nanoseconds;
    var entries = fetch_dir.iterate();
    while (try entries.next(io)) |entry| {
        const stat = fetch_dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (now_ns - stat.mtime.nanoseconds <= stale_fetch_age_ns) continue;
        try fetch_dir.deleteTree(io, entry.name);
    }
}

fn prepareLocal(alloc: std.mem.Allocator, root_path: []const u8, path: []const u8) !PrepareResult {
    const folder = (try resolveFolder(alloc, io_mod.getIo(), path)) orelse return .{ .not_a_folder = path };
    const record = try source.folderRecord(alloc, folder);
    return prepareFrom(alloc, root_path, folder, folder, null, record, null);
}

fn prepareGit(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    git: source.Git,
    cancel: ?*const std.atomic.Value(bool),
) !PrepareResult {
    const scratch = try std.Io.Dir.path.join(alloc, &.{ root_path, scratch_dir_name });
    const fetched = switch (try source.fetch(alloc, gitOps(), git, scratch, cancel)) {
        .ok => |ok| ok,
        .failed => |failed| return .{ .fetch_failed = failed },
    };
    return prepareFrom(alloc, root_path, fetched.dir, git.url, fetched.commit, fetched.record, fetched.temp);
}

fn prepareFrom(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    dir: []const u8,
    source_text: []const u8,
    commit: ?[]const u8,
    record: []const u8,
    temp_to_discard: ?[]const u8,
) !PrepareResult {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    errdefer {
        if (temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
        arena.deinit();
        alloc.destroy(arena);
    }
    const owned = arena.allocator();

    const decoded = switch (try readManifest(owned, io_mod.getIo(), dir)) {
        .ok => |m| m,
        .missing => {
            if (temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
            arena.deinit();
            alloc.destroy(arena);
            return .no_manifest;
        },
        .bad => |err| {
            if (temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
            arena.deinit();
            alloc.destroy(arena);
            return .{ .bad_manifest = err };
        },
    };

    var providers_reg: ?configured_provider.Registry = null;
    errdefer if (providers_reg) |*reg| reg.deinit(alloc);
    const link_path = try std.Io.Dir.path.join(owned, &.{ root_path, decoded.name });
    if (decoded.providers) |providers_val| {
        var at: configured_provider.FailurePath = .{};
        providers_reg = configured_provider.Registry.parse_located_for_mod(
            alloc,
            providers_val,
            &at,
            .{ .name = decoded.name, .dir = link_path },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
                const bad_path = try alloc.dupe(u8, at.text());
                arena.deinit();
                alloc.destroy(arena);
                return .{ .bad_providers = .{ .path = bad_path, .err = err } };
            },
        };
    }

    if (decoded.mcp) |mcp_val| {
        switch (try mcp_config.parse(alloc, mcp_val, .{ .name = decoded.name, .dir = link_path })) {
            .ok => |configs| {
                var mut = configs;
                mcp_config.deinitConfigs(alloc, &mut);
            },
            .invalid => |bad| {
                if (temp_to_discard) |temp| source.discard(io_mod.getIo(), temp);
                if (providers_reg) |*reg| {
                    reg.deinit(alloc);
                    providers_reg = null;
                }
                arena.deinit();
                alloc.destroy(arena);
                return .{ .bad_mcp = .{ .server = bad.server, .reason = bad.reason } };
            },
        }
    }

    return .{ .prepared = .{
        .manifest = decoded,
        .providers = providers_reg,
        .dir = try owned.dupe(u8, dir),
        .source = try owned.dupe(u8, source_text),
        .commit = if (commit) |c| try owned.dupe(u8, c) else null,
        .record = try owned.dupe(u8, record),
        .temp_to_discard = if (temp_to_discard) |t| try owned.dupe(u8, t) else null,
        .arena = arena,
    } };
}

/// The real path of `path` when it is a folder, null when it is not one.
fn resolveFolder(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    dir.close(io);
    return try io_mod.realpathAlloc(alloc, path);
}

const ReadManifest = union(enum) {
    ok: manifest.Manifest,
    missing,
    bad: manifest.DecodeError,
};

fn readManifest(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !ReadManifest {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, "mod.json", alloc, .limited(manifest.max_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.StreamTooLong => return .{ .bad = error.TooLarge },
        else => return err,
    };
    const decoded = manifest.decode(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |other| return .{ .bad = other },
    };
    return .{ .ok = decoded };
}

fn gitOps() source.Ops {
    return .{
        .io = io_mod.getIo(),
        .run = runGit,
        .fill_token = store.defaultFillToken,
    };
}

pub const ModMcpClash = mcp_config.ModMcpClash;
pub const LoadedModServers = mcp_config.LoadedModServers;

pub fn loadModMcpServersFromPins(
    alloc: std.mem.Allocator,
    pinned: *const ModPins,
    profile_configs: []const mcp_config.McpServerConfig,
) !LoadedModServers {
    return mcp_config.loadFromPinned(alloc, io_mod.getIo(), pinned, profile_configs);
}

pub fn findModMcpClashes(
    alloc: std.mem.Allocator,
    mods_dir: []const u8,
    profile_configs: []const mcp_config.McpServerConfig,
) ![]ModMcpClash {
    const Ctx = struct {
        alloc: std.mem.Allocator,
        profile_configs: []const mcp_config.McpServerConfig,
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const ModPins) anyerror![]ModMcpClash {
            var loaded = try mcp_config.loadFromPinned(ctx.alloc, io_mod.getIo(), pinned, ctx.profile_configs);
            const clashes = loaded.clashes;
            loaded.clashes = &.{};
            loaded.deinit(ctx.alloc);
            return clashes;
        }
    };
    return withPinnedMods(alloc, mods_dir, Ctx{
        .alloc = alloc,
        .profile_configs = profile_configs,
    }, []ModMcpClash, Body.run);
}

pub const ModProviderEntry = struct {
    mod_name: []const u8,
    link_path: []const u8,
    definition: configured_provider.Definition,
};

pub const ModProviders = struct {
    entries: []ModProviderEntry = &.{},
    problems: [][]u8 = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *ModProviders, alloc: std.mem.Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
        }
        self.* = .{};
    }
};

/// Returns the parsed providers of every enabled mod under `root_path`, in mod
/// name order, each with its mod name and link path (`<root>/<name>`).
/// Disabled, unreadable, and invalid mods contribute nothing; broken enabled
/// mods append a plain problem sentence naming the mod.
pub fn loadModProviders(alloc: std.mem.Allocator, root_path: []const u8) !ModProviders {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }
    var loaded = try loadModProvidersInto(alloc, root_path, arena);
    if (loaded.entries.len == 0 and loaded.problems.len == 0) {
        arena.deinit();
        alloc.destroy(arena);
        return .{};
    }
    loaded.arena = arena;
    return loaded;
}

/// Same as `loadModProviders`, allocating returned entries, problems, and
/// provider definitions in the caller-owned `target_arena` (`ModProviders.arena`
/// is left null so `ModProviders.deinit` does not free `target_arena`).
pub fn loadModProvidersInto(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    target_arena: *std.heap.ArenaAllocator,
) !ModProviders {
    const io = io_mod.getIo();
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{
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

    const scanned = try store.scanEntries(scratch, root_dir, io);
    if (scanned.entries.len == 0 and !scanned.over_limit) return .{};

    const owned = target_arena.allocator();
    var entries: std.ArrayList(ModProviderEntry) = .empty;
    var problems: std.ArrayList([]u8) = .empty;

    for (scanned.entries) |item| {
        if (!manifest.validName(item.base)) {
            if (item.has_on) {
                try problems.append(owned, try owned.print("mod {f}: invalid mod name.", .{text_utils.terminalSafe(item.base)}));
            }
            continue;
        }
        if (item.has_on and item.has_off) {
            try problems.append(owned, try owned.print("mod {s}: has both enabled and disabled links; skipped.", .{item.base}));
            continue;
        }
        if (!item.has_on) continue;

        if (item.on_kind.? != .sym_link) {
            try problems.append(owned, try owned.print("mod {s}: mod entry is not a symbolic link.", .{item.base}));
            continue;
        }

        var mod_scratch_state = std.heap.ArenaAllocator.init(alloc);
        defer mod_scratch_state.deinit();
        const mod_scratch = mod_scratch_state.allocator();

        const loaded = try store.readManifestAt(mod_scratch, root_dir, io, item.base, item.base);
        const decoded = switch (loaded) {
            .ok => |m| m,
            .problem => |prob| {
                const msg = manifestProblemMessage(prob);
                try problems.append(owned, try owned.print("mod {s}: {s}", .{ item.base, msg }));
                continue;
            },
        };

        const providers_val = decoded.providers orelse continue;
        const mod_name = try owned.dupe(u8, item.base);
        const link_path = try std.Io.Dir.path.join(owned, &.{ root_path, item.base });

        var at: configured_provider.FailurePath = .{};
        const defs = configured_provider.Registry.parse_definitions_for_mod(
            owned,
            providers_val,
            &at,
            .{ .name = mod_name, .dir = link_path },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const advice = configured_provider.mod_failure_advice(err) orelse "could not parse providers";
                const path_text = at.text();
                if (path_text.len > 0) {
                    try problems.append(owned, try owned.print(
                        "mod {s}: providers.{f}: {s}.",
                        .{ mod_name, text_utils.terminalSafe(path_text), advice },
                    ));
                } else {
                    try problems.append(owned, try owned.print(
                        "mod {s}: providers: {s}.",
                        .{ mod_name, advice },
                    ));
                }
                continue;
            },
        };

        for (defs) |def| {
            try entries.append(owned, .{
                .mod_name = mod_name,
                .link_path = link_path,
                .definition = def,
            });
        }
    }

    if (scanned.over_limit) {
        try problems.append(owned, try owned.print(
            "more than {d} mods are installed; extra mods were skipped.",
            .{manifest.max_mods},
        ));
    }

    return .{
        .entries = try entries.toOwnedSlice(owned),
        .problems = try problems.toOwnedSlice(owned),
        .arena = null,
    };
}

fn manifestProblemMessage(problem: store.ManifestProblem) []const u8 {
    return switch (problem) {
        .dangling => "mod link is broken.",
        .open_dir_failed => "could not open mod directory.",
        .no_manifest => "mod.json is missing.",
        .open_file_failed, .unreadable_manifest => "could not read mod.json.",
        .not_regular_file => "mod.json is not a regular file.",
        .too_large => manifest.message(error.TooLarge),
        .bad_manifest => |err| manifest.message(err),
        .name_mismatch => "mod.json names a different mod.",
    };
}

const max_git_stdout_bytes: usize = 64 * 1024;
const max_git_stderr_bytes: usize = 8 * 1024;

/// Runs one command for `source.fetch` with the full environment plus
/// `GIT_TERMINAL_PROMPT=0`, so git never waits for a prompt. The command stops
/// at `request.timeout_ms` and when `request.cancel` is set.
fn runGit(_: ?*anyopaque, alloc: std.mem.Allocator, request: source.Request) anyerror!source.Run {
    var env = try io_mod.cloneEnvironMap(alloc);
    defer env.deinit();
    try env.put("GIT_TERMINAL_PROMPT", "0");
    const outcome = bounded_process.run(alloc, io_mod.getIo(), .{
        .argv = request.argv,
        .environ_map = &env,
        .stdout_limit = max_git_stdout_bytes,
        .stderr_limit = max_git_stderr_bytes,
        .timeout_ms = request.timeout_ms,
        .cancel = request.cancel,
    });
    return switch (outcome) {
        .finished => |result| processRun(alloc, result),
        .cancelled => .cancelled,
        .unavailable => .spawn_failed,
    };
}

fn processRun(alloc: std.mem.Allocator, result: std.process.RunError!std.process.RunResult) !source.Run {
    const process = result catch |err| return switch (err) {
        error.StreamTooLong => .too_large,
        error.Timeout => .timed_out,
        error.OutOfMemory => error.OutOfMemory,
        else => .spawn_failed,
    };
    return switch (process.term) {
        .exited => |code| .{ .exited = .{
            .code = code,
            .stdout = process.stdout,
            .stderr = process.stderr,
        } },
        else => blk: {
            alloc.free(process.stdout);
            alloc.free(process.stderr);
            break :blk .signaled;
        },
    };
}

fn acquireRealModLock(
    _: ?*anyopaque,
    io: std.Io,
    root_path: []const u8,
    name: []const u8,
    deadline_ms: u64,
) anyerror!store.LockAttempt {
    try std.Io.Dir.cwd().createDirPath(io, root_path);
    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer root_dir.close(io);

    var lock_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(root_dir, locks_dir_name);
    defer lock_dir.close();

    const lock = io_mod.acquireTimedAdvisoryLockWithOps(&lock_dir, name, deadline_ms, .{}) catch |err| switch (err) {
        error.LockBusy => return .busy,
        else => return err,
    };
    return .{ .acquired = .{
        .file = lock.file,
        .release_fn = releaseRealModLock,
    } };
}

fn releaseRealModLock(self: *store.Lock, _: std.Io) void {
    var lock: io_mod.TimedAdvisoryLock = .{ .file = self.file };
    lock.release();
}

fn prepareRealPinsDir(_: ?*anyopaque, _: std.Io, root_dir: std.Io.Dir) anyerror!std.Io.Dir {
    var lock_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(root_dir, locks_dir_name);
    defer lock_dir.close();
    const pins_dir = try io_mod.openOrCreateVerifiedPrivateDir(&lock_dir, pins.pins_dir_name);
    return pins_dir.dir;
}

fn gitRun(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const run = try runGit(null, alloc, .{ .argv = argv, .timeout_ms = 30_000, .cancel = null });
    switch (run) {
        .exited => |out| {
            alloc.free(out.stderr);
            if (out.code != 0) return error.GitFailed;
            return out.stdout;
        },
        else => return error.GitFailed,
    }
}

fn gitCommit(alloc: std.mem.Allocator, repo: []const u8, message: []const u8) !void {
    _ = try gitRun(alloc, &.{ "git", "-C", repo, "add", "-A" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "git", "-C", repo, "-c", "user.name=fx test", "-c", "user.email=test@example.com" });
    try argv.appendSlice(alloc, &.{ "-c", "commit.gpgsign=false", "commit", "-q", "-m", message });
    _ = try gitRun(alloc, argv.items);
}

fn revParse(alloc: std.mem.Allocator, repo: []const u8, rev: []const u8) ![]const u8 {
    const out = try gitRun(alloc, &.{ "git", "-C", repo, "rev-parse", rev });
    return std.mem.trim(u8, out, " \t\r\n");
}

fn writeManifestText(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8, version: []const u8) !void {
    const path = try alloc.print("{s}/mod.json", .{sub});
    const text = try alloc.print("{{\"name\":\"glm\",\"version\":\"{s}\"}}", .{version});
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = path, .data = text });
}

/// A git repository under `sub` with one commit of `mod.json` at `version`.
fn makeRepo(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8, version: []const u8) ![]const u8 {
    try tmp.dir.createDirPath(io_mod.getIo(), sub);
    const repo = try tmp.dir.realPathFileAlloc(io_mod.getIo(), sub, alloc);
    _ = try gitRun(alloc, &.{ "git", "init", "-q", "-b", "main", repo });
    try writeManifestText(alloc, tmp, sub, version);
    try gitCommit(alloc, repo, "first");
    return repo;
}

fn makeRoot(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    return tmp.dir.realPathFileAlloc(io_mod.getIo(), "mods", alloc);
}

fn pathExistsForTest(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "install from a git tag pins the mod, records its commit, and keeps .git out of the store" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try makeRepo(alloc, &tmp, "repo", "1.0.0");
    _ = try gitRun(alloc, &.{ "git", "-C", repo, "tag", "v1" });
    const head = try revParse(alloc, repo, "HEAD");
    const root = try makeRoot(alloc, &tmp);
    const arg = try alloc.print("file://{s}@v1", .{repo});

    const installed = switch (try install(alloc, root, arg, null)) {
        .installed => |i| i,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("glm", installed.name);
    try std.testing.expectEqualStrings("1.0.0", installed.version);
    try std.testing.expectEqualStrings(head, installed.commit.?);

    const record = try source.decodeRecord(alloc, (try readRecord(alloc, root, "glm")).?);
    try std.testing.expect(record.pinned);
    try std.testing.expectEqualStrings("v1", record.ref.?);
    try std.testing.expectEqualStrings(head, record.commit.?);

    try std.testing.expect(pathExistsForTest(try alloc.print("{s}/glm/mod.json", .{root})));
    try std.testing.expect(!pathExistsForTest(try alloc.print("{s}/glm/.git", .{root})));
}

test "install from a full commit pins that commit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try makeRepo(alloc, &tmp, "repo", "1.0.0");
    const head = try revParse(alloc, repo, "HEAD");
    const root = try makeRoot(alloc, &tmp);
    const arg = try alloc.print("file://{s}@{s}", .{ repo, head });

    const installed = switch (try install(alloc, root, arg, null)) {
        .installed => |i| i,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(head, installed.commit.?);
    const record = try source.decodeRecord(alloc, (try readRecord(alloc, root, "glm")).?);
    try std.testing.expect(record.pinned);
    try std.testing.expectEqualStrings(head, record.ref.?);
}

test "refresh leaves a pinned mod alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try makeRepo(alloc, &tmp, "repo", "1.0.0");
    _ = try gitRun(alloc, &.{ "git", "-C", repo, "tag", "v1" });
    const root = try makeRoot(alloc, &tmp);
    _ = try install(alloc, root, try alloc.print("file://{s}@v1", .{repo}), null);

    const result = try refresh(alloc, root, "glm", null);
    try std.testing.expectEqualStrings("v1", result.pinned);
}

test "refresh of an unpinned git mod is up to date, then copies a new commit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try makeRepo(alloc, &tmp, "repo", "1.0.0");
    const first = try revParse(alloc, repo, "HEAD");
    const root = try makeRoot(alloc, &tmp);
    _ = try install(alloc, root, try alloc.print("file://{s}", .{repo}), null);

    const same = try refresh(alloc, root, "glm", null);
    try std.testing.expectEqualStrings(first, same.up_to_date);

    try writeManifestText(alloc, &tmp, "repo", "2.0.0");
    try gitCommit(alloc, repo, "second");
    const second = try revParse(alloc, repo, "HEAD");

    const changed = try refresh(alloc, root, "glm", null);
    try std.testing.expectEqualStrings(first, changed.updated.old_commit.?);
    try std.testing.expectEqualStrings(second, changed.updated.new_commit);

    var loaded = try load(alloc, root, "glm");
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("2.0.0", loaded.mod.version);

    const again = try refresh(alloc, root, "glm", null);
    try std.testing.expectEqualStrings(second, again.up_to_date);
}

test "refresh of a folder mod copies the folder again, and a missing mod is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "src");
    try writeManifestText(alloc, &tmp, "src", "1.0.0");
    const src = try tmp.dir.realPathFileAlloc(io_mod.getIo(), "src", alloc);
    const root = try makeRoot(alloc, &tmp);

    const installed = switch (try install(alloc, root, src, null)) {
        .installed => |i| i,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(installed.commit == null);

    try writeManifestText(alloc, &tmp, "src", "2.0.0");
    try std.testing.expect(std.meta.activeTag(try refresh(alloc, root, "glm", null)) == .folder_copied);
    var loaded = try load(alloc, root, "glm");
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("2.0.0", loaded.mod.version);

    try std.testing.expect(std.meta.activeTag(try refresh(alloc, root, "absent", null)) == .not_installed);
}

test "install removes .fetch entries older than an hour and keeps fresh ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeRoot(alloc, &tmp);
    try tmp.dir.createDirPath(io, "mods/.fetch/old/mod");
    try tmp.dir.createDirPath(io, "mods/.fetch/fresh/mod");
    var fetch_dir = try tmp.dir.openDir(io, "mods/.fetch", .{});
    defer fetch_dir.close(io);
    const two_hours_ago: std.Io.Timestamp = .{
        .nanoseconds = std.Io.Clock.real.now(io).nanoseconds - 2 * std.time.ns_per_hour,
    };
    try fetch_dir.setTimestamps(io, "old", .{ .modify_timestamp = .{ .new = two_hours_ago } });

    try tmp.dir.createDirPath(io, "src");
    try writeManifestText(alloc, &tmp, "src", "1.0.0");
    const src = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    _ = switch (try install(alloc, root, src, null)) {
        .installed => |i| i,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expect(!pathExistsForTest(try alloc.print("{s}/.fetch/old", .{root})));
    try std.testing.expect(pathExistsForTest(try alloc.print("{s}/.fetch/fresh", .{root})));
}

test "a folder mod with a .git folder installs without it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeRoot(alloc, &tmp);
    try tmp.dir.createDirPath(io, "src/.git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try writeManifestText(alloc, &tmp, "src", "1.0.0");
    const src = try tmp.dir.realPathFileAlloc(io, "src", alloc);

    const installed = switch (try install(alloc, root, src, null)) {
        .installed => |i| i,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("glm", installed.name);
    try std.testing.expect(pathExistsForTest(try alloc.print("{s}/glm/mod.json", .{root})));
    try std.testing.expect(!pathExistsForTest(try alloc.print("{s}/glm/.git", .{root})));
    try std.testing.expect(pathExistsForTest(try alloc.print("{s}/.git/HEAD", .{src})));
}

test "install refuses a path that is not a folder and an argument that does not parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try makeRoot(alloc, &tmp);

    try std.testing.expect(std.meta.activeTag(try install(alloc, root, "/no/such/mod/folder", null)) == .not_a_folder);
    const bad = try install(alloc, root, "https://example.com/org/glm@-x", null);
    try std.testing.expectEqual(source.Problem.bad_ref, bad.source_invalid);
}

test "the git runner stops a command at its deadline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const started_ms = io_mod.milliTimestamp();
    const run = try runGit(null, alloc, .{ .argv = &.{ "sleep", "5" }, .timeout_ms = 200, .cancel = null });
    try std.testing.expect(std.meta.activeTag(run) == .timed_out);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "the git runner stops a command when it is cancelled" {
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(100 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    const run = try runGit(null, alloc, .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 5" }, .timeout_ms = 60_000, .cancel = &cancel });
    thread.join();
    try std.testing.expect(std.meta.activeTag(run) == .cancelled);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "the git runner sets GIT_TERMINAL_PROMPT to 0 for the command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const run = try runGit(null, alloc, .{
        .argv = &.{ "/bin/sh", "-c", "printf %s \"$GIT_TERMINAL_PROMPT\"" },
        .timeout_ms = 5_000,
        .cancel = null,
    });
    switch (run) {
        .exited => |out| {
            try std.testing.expectEqual(@as(u8, 0), out.code);
            try std.testing.expectEqualStrings("0", out.stdout);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "mods front door runs real store lifecycle and enforces verified private lock dir" {
    _ = store;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "mods");
    defer alloc.free(root);

    try tmp.dir.createDirPath(io_mod.getIo(), "src");
    const src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src");
    defer alloc.free(src);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "src/mod.json", .data = "{\"name\":\"glm\",\"version\":\"1.0.0\"}" });

    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "glm", src));

    var loaded = try load(alloc, root, "glm");
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded == .mod);
    try std.testing.expectEqualStrings("1.0.0", loaded.mod.version);

    var listing = try list(alloc, root);
    defer listing.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), listing.mods.len);
    try std.testing.expectEqualStrings("glm", listing.mods[0].name);

    // Verify `.locks` was created as 0700 private dir.
    var locks_dir = try tmp.dir.openDir(io_mod.getIo(), "mods/.locks", .{ .follow_symlinks = false });
    defer locks_dir.close(io_mod.getIo());
    const locks_stat = try locks_dir.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u32, 0o700), locks_stat.permissions.toMode() & 0o777);

    // Contention while lock file is held returns `.busy` at deadline.
    {
        var lock_file = try locks_dir.openFile(io_mod.getIo(), "glm", .{ .mode = .read_write });
        defer lock_file.close(io_mod.getIo());
        try std.testing.expect(try lock_file.tryLock(io_mod.getIo(), .exclusive));
        defer lock_file.unlock(io_mod.getIo());

        var short_ops = realOps();
        short_ops.lock_deadline_ms = 10;
        try std.testing.expectEqual(Outcome.busy, try store.setOn(alloc, .{ .root_path = root, .ops = short_ops }, "glm", false));
    }

    // Real pin, reloadPin, and collect wrappers through the mods front door.
    var pinned: ?Pin = switch (try pin(alloc, root, "glm")) {
        .pinned => |p| p,
        else => return error.TestUnexpectedResult,
    };
    defer if (pinned) |*p| p.release(alloc, io_mod.getIo());
    try std.testing.expectEqual(Outcome.ok, try update(alloc, root, "glm", src));
    const reloaded = try reloadPin(alloc, root, "glm", &pinned);
    try std.testing.expect(reloaded == .pinned);
    pinned = reloaded.pinned;
    try std.testing.expectEqual(Outcome.ok, try collect(root, "glm"));
    if (pinned) |*p| {
        p.release(alloc, io_mod.getIo());
        pinned = null;
    }

    // Real ModPins verifies `.locks` with io.zig's private-dir check.
    var set = try loadModPins(alloc, root);
    defer set.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), set.pins.len);
    set.deinit(alloc);

    var mods_dir = try tmp.dir.openDir(io_mod.getIo(), "mods", .{});
    defer mods_dir.close(io_mod.getIo());
    try mods_dir.deleteTree(io_mod.getIo(), ".locks");
    try tmp.dir.createDirPath(io_mod.getIo(), "fake_locks");
    const fake_locks = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fake_locks");
    defer alloc.free(fake_locks);
    try mods_dir.symLink(io_mod.getIo(), fake_locks, ".locks", .{ .is_directory = true });
    try std.testing.expectError(error.DurablePathUnsafe, pin(alloc, root, "glm"));
}

test "loadModProviders returns sorted enabled providers, ignores disabled mods, and reports broken mods" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_root = try std.Io.Dir.path.join(alloc, &.{ ".", "missing-mods-root-for-test" });
    defer alloc.free(missing_root);
    var empty = try loadModProviders(alloc, missing_root);
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
    try std.testing.expectEqual(@as(usize, 0), empty.problems.len);

    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "mods");
    defer alloc.free(root);

    // Enabled mods `zeta` and `alpha` (to verify alphabetical mod order).
    try tmp.dir.createDirPath(io_mod.getIo(), "src_alpha");
    const src_alpha = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src_alpha");
    defer alloc.free(src_alpha);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src_alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1\",\"providers\":{\"p-a\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/a-auth\"]}}}}",
    });

    try tmp.dir.createDirPath(io_mod.getIo(), "src_zeta");
    const src_zeta = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src_zeta");
    defer alloc.free(src_zeta);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src_zeta/mod.json",
        .data = "{\"name\":\"zeta\",\"version\":\"1\",\"providers\":{\"p-z\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"}}}}",
    });

    // Disabled mod `offmod` should contribute nothing and no problem.
    try tmp.dir.createDirPath(io_mod.getIo(), "src_off");
    const src_off = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src_off");
    defer alloc.free(src_off);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src_off/mod.json",
        .data = "{\"name\":\"offmod\",\"version\":\"1\",\"providers\":{\"p-off\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"}}}}",
    });

    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "zeta", src_zeta));
    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "alpha", src_alpha));
    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "offmod", src_off));
    try std.testing.expectEqual(Outcome.ok, try setOn(alloc, root, "offmod", false));

    // Broken mod (dangling link) and mod with `..` in provider command.
    var root_dir = try tmp.dir.openDir(io_mod.getIo(), "mods", .{});
    defer root_dir.close(io_mod.getIo());
    try root_dir.symLink(io_mod.getIo(), ".store/dangling-0000000000000001", "broken", .{ .is_directory = true });

    try tmp.dir.createDirPath(io_mod.getIo(), "src_escape");
    const src_escape = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src_escape");
    defer alloc.free(src_escape);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src_escape/mod.json",
        .data = "{\"name\":\"escape\",\"version\":\"1\",\"providers\":{\"p-esc\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"../evil\"]}}}}",
    });
    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "escape", src_escape));

    var loaded = try loadModProviders(alloc, root);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("alpha", loaded.entries[0].mod_name);
    try std.testing.expectEqualStrings("p-a", loaded.entries[0].definition.id);
    const expected_alpha_link = try std.Io.Dir.path.join(alloc, &.{ root, "alpha" });
    defer alloc.free(expected_alpha_link);
    const expected_alpha_prog = try std.Io.Dir.path.join(alloc, &.{ expected_alpha_link, "bin/a-auth" });
    defer alloc.free(expected_alpha_prog);
    try std.testing.expectEqualStrings(expected_alpha_link, loaded.entries[0].link_path);
    try std.testing.expectEqualStrings(expected_alpha_prog, loaded.entries[0].definition.auth.command[0]);
    try std.testing.expectEqualStrings("zeta", loaded.entries[1].mod_name);
    try std.testing.expectEqualStrings("p-z", loaded.entries[1].definition.id);

    try std.testing.expectEqual(@as(usize, 2), loaded.problems.len);
    try std.testing.expect(std.mem.find(u8, loaded.problems[0], "broken") != null);
    try std.testing.expect(std.mem.find(u8, loaded.problems[1], "escape") != null);
    try std.testing.expect(std.mem.find(u8, loaded.problems[1], "must stay inside the mod") != null);
}

test "prepareInstall parses providers before prompt and cleans up on discard" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "mods");
    defer alloc.free(root);

    // Invalid provider (`..` escape) fails during prepareInstall before any install.
    try tmp.dir.createDirPath(io_mod.getIo(), "bad_src");
    const bad_src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "bad_src");
    defer alloc.free(bad_src);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "bad_src/mod.json",
        .data = "{\"name\":\"glm\",\"version\":\"1.0.0\",\"providers\":{\"p\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"../evil\"]}}}}",
    });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const res_bad = try prepareInstall(arena_state.allocator(), root, bad_src, null);
    try std.testing.expect(res_bad == .bad_providers);
    try std.testing.expectEqual(error.InvalidAuth, res_bad.bad_providers.err);

    // Valid provider resolves relative command in prepared preview, commits cleanly, and discards cleanly.
    try tmp.dir.createDirPath(io_mod.getIo(), "good_src");
    const good_src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "good_src");
    defer alloc.free(good_src);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "good_src/mod.json",
        .data = "{\"name\":\"glm\",\"version\":\"1.0.0\",\"description\":\"GLM plan\",\"providers\":{\"glm\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/glm-auth\",\"--token\"]}}}}",
    });

    const res_good = try prepareInstall(arena_state.allocator(), root, good_src, null);
    try std.testing.expect(res_good == .prepared);
    var prepared = res_good.prepared;
    defer prepared.discard(arena_state.allocator());

    const reg = prepared.providers.?;
    const def = reg.get("glm").?;
    try std.testing.expect(std.mem.endsWith(u8, def.auth.command[0], "/mods/glm/bin/glm-auth"));
    try std.testing.expectEqualStrings("--token", def.auth.command[1]);

    // Before commitInstall, mod is not in the store yet.
    var before_load = try load(alloc, root, "glm");
    defer before_load.deinit(alloc);
    try std.testing.expect(before_load == .none);

    const committed = try commitInstall(arena_state.allocator(), root, &prepared);
    try std.testing.expect(committed == .installed);
    var after_load = try load(alloc, root, "glm");
    defer after_load.deinit(alloc);
    try std.testing.expect(after_load == .mod);
}

test "prepareInstall and prepareUpdate strictly refuse invalid mod mcp servers" {
    _ = mcp_config;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "mods");
    defer alloc.free(root);

    try tmp.dir.createDirPath(io_mod.getIo(), "src");
    const src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src");
    defer alloc.free(src);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Authorization header is refused on add.
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1.0.0\",\"mcp\":{\"web\":{\"type\":\"http\",\"url\":\"https://example.com/mcp\",\"headers\":{\"Authorization\":\"Bearer x\"}}}}",
    });
    const bad_add = try prepareInstall(arena, root, src, null);
    try std.testing.expect(bad_add == .bad_mcp);
    try std.testing.expectEqualStrings("web", bad_add.bad_mcp.server);
    try std.testing.expect(std.mem.find(u8, bad_add.bad_mcp.reason, "Authorization header") != null);

    // Valid mod installs, then an update with `..` in stdio command is refused.
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1.0.0\",\"mcp\":{\"fs\":{\"command\":\"bin/fs\"}}}",
    });
    const good_add = try prepareInstall(arena, root, src, null);
    try std.testing.expect(good_add == .prepared);
    var prep = good_add.prepared;
    defer prep.discard(arena);
    try std.testing.expect((try commitInstall(arena, root, &prep)) == .installed);

    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"2.0.0\",\"mcp\":{\"fs\":{\"command\":\"../outside\"}}}",
    });
    const bad_upd = try prepareUpdate(arena, root, "alpha", null);
    try std.testing.expect(bad_upd == .bad_mcp);
    try std.testing.expectEqualStrings("fs", bad_upd.bad_mcp.server);
    try std.testing.expect(std.mem.find(u8, bad_upd.bad_mcp.reason, "must stay inside the mod") != null);
}

test "loadModMcpServersFromPins resolves against pinned version path, enforces clashes, and shadows profile" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "mods");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "mods");
    defer alloc.free(root);

    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.createDirPath(io, "beta");
    const alpha_src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "alpha");
    defer alloc.free(alpha_src);
    const beta_src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "beta");
    defer alloc.free(beta_src);

    try tmp.dir.writeFile(io, .{
        .sub_path = "alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1.0.0\",\"mcp\":{\"a\":{\"command\":\"bin/a\"},\"shared\":{\"command\":\"bin/sa\"},\"prof\":{\"command\":\"bin/pa\"}}}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "beta/mod.json",
        .data = "{\"name\":\"beta\",\"version\":\"1.0.0\",\"mcp\":{\"b\":{\"type\":\"http\",\"url\":\"https://b.example/mcp\"},\"shared\":{\"command\":\"bin/sb\"},\"prof\":{\"command\":\"bin/pb\"}}}",
    });

    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "alpha", alpha_src));
    try std.testing.expectEqual(Outcome.ok, try add(alloc, root, "beta", beta_src));

    var pinned = try loadModPins(alloc, root);
    defer pinned.deinit(alloc);

    const profile = [_]mcp_config.McpServerConfig{.{ .name = "prof", .command = "profile-prof" }};
    var loaded = try loadModMcpServersFromPins(alloc, &pinned, &profile);
    defer loaded.deinit(alloc);

    // `a` and `b` load in mod name order; `prof` is shadowed by profile (no clash); `shared` clashes and loads from neither.
    try std.testing.expectEqual(@as(usize, 2), loaded.configs.items.len);
    try std.testing.expectEqualStrings("a", loaded.configs.items[0].name);
    try std.testing.expectEqualStrings("alpha", loaded.configs.items[0].mod_name.?);
    try std.testing.expect(std.mem.find(u8, loaded.configs.items[0].command.?, "/.store/alpha-") != null);
    try std.testing.expect(std.mem.endsWith(u8, loaded.configs.items[0].command.?, "/bin/a"));
    try std.testing.expect(std.mem.find(u8, loaded.configs.items[0].cwd.?, "/.store/alpha-") != null);
    try std.testing.expectEqualStrings("b", loaded.configs.items[1].name);
    try std.testing.expectEqualStrings("beta", loaded.configs.items[1].mod_name.?);

    try std.testing.expectEqual(@as(usize, 1), loaded.clashes.len);
    try std.testing.expectEqualStrings("shared", loaded.clashes[0].server);
    try std.testing.expectEqual(@as(usize, 2), loaded.clashes[0].mods.len);
    try std.testing.expectEqualStrings("alpha", loaded.clashes[0].mods[0]);
    try std.testing.expectEqualStrings("beta", loaded.clashes[0].mods[1]);

    const clashes = try findModMcpClashes(alloc, root, &profile);
    defer {
        for (clashes) |*c| c.deinit(alloc);
        alloc.free(clashes);
    }
    try std.testing.expectEqual(@as(usize, 1), clashes.len);
    try std.testing.expectEqualStrings("shared", clashes[0].server);
}
