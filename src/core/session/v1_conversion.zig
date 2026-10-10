//! The v1 side of converting v1 sessions to v2 when they are opened (D55,
//! D56, D59 to D61, `tla/V1Conversion.tla`).
//!
//! It locks a v1 family (the root and the children in its registry) with
//! v1's own writer lock, reads every member read-only through v1's readers,
//! fingerprints what it read, and removes a converted member's v1 folder by
//! renaming it into `trash_dir_name` and deleting it there (D60). It writes
//! no v1 file: taking a lock may create a missing `session.lock`, which is
//! not content (D61). `session_adapter.zig` writes what this reads into v2;
//! this file never sees the session manager.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_event = @import("session_event.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");
const session_store = @import("session_store.zig");
const session_catalog_cache = @import("session_catalog_cache.zig");
const session_layout = @import("session_layout.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const result_store = @import("result_store.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const usage_recovery = @import("usage_recovery.zig");
const child_state = @import("../subagent/child_state.zig");

const Allocator = std.mem.Allocator;
const Event = session_event.ConversationEvent;

/// Where a converted member's v1 folder goes before it is deleted (D60),
/// beside the v1 folders. No v1 scan lists it: `+` is not a v1 id byte, as
/// in v1's own `creating+{hex}` staging.
const trash_dir_name = "trash+v1";
/// The writer lock v1 takes in every session folder.
const lock_file = "session.lock";
/// v1's writer and the picker's waits (`session_log.zig` `lock_deadline_ms`).
pub const lock_wait_ms: u64 = 2000;

/// Why a member could not be read, for the user: the file and the reason
/// (D61), such as "events.jsonl line 812 is not valid JSON".
pub const Problem = struct {
    /// The longest reason kept, in bytes.
    pub const capacity = 512;

    buffer: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn text(problem: *const Problem) []const u8 {
        return problem.buffer[0..problem.len];
    }

    /// Records the reason, cut at the buffer's size, and returns the error
    /// that carries it.
    pub fn set(problem: *Problem, comptime fmt: []const u8, args: anytype) error{InvalidSessionFormat} {
        problem.len = if (std.fmt.bufPrint(&problem.buffer, fmt, args)) |written| written.len else |_| problem.buffer.len;
        return error.InvalidSessionFormat;
    }
};

// ---------------------------------------------------------------------------
// Finding v1 sessions

const Kind = enum { absent, root, child };

/// What v1 holds under `id`, as v1's listing tells it: nothing (no folder,
/// or one with no `session.json`), a root, or a child that only its parent
/// opens. An error when that cannot be told.
pub fn kindOf(store: *session_store.Store, alloc: Allocator, id: []const u8) !Kind {
    session_layout.validateSessionId(id) catch return .absent;
    var dir = (try openMemberDir(store, id)) orelse return .absent;
    defer dir.close();
    const marked: ?bool = switch (try readMetadata(alloc, &dir)) {
        .missing => return .absent,
        // A legacy snapshot, which holds its whole history: v1's listing
        // records no child bit for one either (`session_discovery.zig`).
        .too_large => null,
        .bytes => |bytes| blk: {
            defer alloc.free(bytes);
            const Probe = struct { subagent_child: ?bool = null };
            const parsed = std.json.parseFromSlice(Probe, alloc, bytes, .{ .ignore_unknown_fields = true }) catch break :blk null;
            defer parsed.deinit();
            break :blk parsed.value.subagent_child;
        },
    };
    return if (try child_state.isDiscoveredManagedChildSession(store.*, alloc, id, marked)) .child else .root;
}

/// Why v1 cannot tell the kind of its folder `id` (`kindOf` failed with
/// `err`), for the user (D61): what is wrong with `session.json` when that
/// is the cause, else the child marker `err` came from. Always
/// `error.InvalidSessionFormat`, with `problem` set.
pub fn kindProblem(store: *session_store.Store, alloc: Allocator, id: []const u8, err: anyerror, problem: *Problem) error{InvalidSessionFormat}!void {
    var dir = (openMemberDir(store, id) catch |open_err| return problem.set("its folder can't be opened ({s})", .{@errorName(open_err)})) orelse
        return problem.set("its folder is gone", .{});
    defer dir.close();
    const metadata = readMetadata(alloc, &dir) catch |read_err| return problem.set("session.json can't be read ({s})", .{@errorName(read_err)});
    switch (metadata) {
        .missing => return problem.set("session.json is missing", .{}),
        .too_large => {},
        .bytes => |bytes| {
            defer alloc.free(bytes);
            if (!(std.json.validate(alloc, bytes) catch false)) return problem.set("session.json is not valid JSON", .{});
            if (isConversationMetadata(alloc, bytes)) return problem.set("its subagent marker can't be read ({s})", .{@errorName(err)});
        },
    }
    return problem.set("session.json can't be read in any format this fx knows ({s})", .{@errorName(err)});
}

/// A v1 root, or a folder whose kind could not be told, with why.
const Root = struct {
    id: []u8,
    /// Why v1's folder could not be read to tell its kind; it is reported
    /// unreadable rather than converted (D61). Owned.
    unreadable: ?[]u8 = null,

    pub fn deinit(root: Root, alloc: Allocator) void {
        alloc.free(root.id);
        if (root.unreadable) |reason| alloc.free(reason);
    }
};

/// Every v1 root in the order v1's folder lists them, with each folder
/// whose kind could not be told, traced (D61). A child converts with its
/// root. Fails only when v1's sessions folder itself cannot be listed.
/// Caller owns the ids and the slice.
pub fn rootIds(alloc: Allocator, home: []const u8) ![]Root {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    var roots: std.ArrayList(Root) = .empty;
    errdefer {
        for (roots.items) |root| root.deinit(alloc);
        roots.deinit(alloc);
    }
    var candidates = store.readOnlyCandidates();
    while (true) {
        try roots.ensureUnusedCapacity(alloc, 1);
        const id = (try candidates.nextId(alloc, null)) orelse break;
        errdefer alloc.free(id);
        const kind = kindOf(&store, alloc, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("convert", "action=KindUnknown session={s} err={s}", .{ id, @errorName(err) });
                var problem: Problem = .{};
                kindProblem(&store, alloc, id, err, &problem) catch {};
                roots.appendAssumeCapacity(.{ .id = id, .unreadable = try alloc.dupe(u8, problem.text()) });
                continue;
            },
        };
        if (kind != .root) {
            alloc.free(id);
            continue;
        }
        roots.appendAssumeCapacity(.{ .id = id });
    }
    return roots.toOwnedSlice(alloc);
}

/// The session v1 remembered for `workspace` (`-c`), or null. Reads only.
/// Caller owns it.
pub fn rememberedId(alloc: Allocator, home: []const u8, workspace: []const u8) !?[]u8 {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    return store.readRememberedSessionId(alloc) catch |err| switch (err) {
        error.InvalidRememberedSession => null,
        else => err,
    };
}

/// v1's read-only detail of the root `id`, for `fx session {id}` (D61), or
/// null when v1 holds no such root. It converts and writes nothing. Caller
/// owns the result.
pub fn readDetail(alloc: Allocator, home: []const u8, id: []const u8) !?session_store.ReadOnlyDetail {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    if (try kindOf(&store, alloc, id) != .root) return null;
    return try store.loadReadOnlyDetail(alloc, id, .{ .allow_large_legacy = true });
}

/// Every v1 root as v1's own listing shows it, but `active_id`, without
/// refreshing v1's listing cache. A root v1 cannot read is listed too
/// (`tla/V1Conversion.tla` Listed), with its folder's time and nothing
/// else, so opening it can say why it is refused; so is a folder whose
/// kind cannot be told. Caller owns the result.
pub fn listRoots(alloc: Allocator, home: []const u8, active_id: ?[]const u8) !session_catalog_cache.ActionableSessionCatalog {
    var store = try session_store.Store.initReadOnlyFromHome(alloc, home, "/");
    defer store.deinit(alloc);
    const sessions = &(store.canonical_root.sessions orelse return .{});
    var catalog = try session_catalog_cache.listActionableCatalog(store, alloc, active_id, null, null);
    errdefer catalog.deinit(alloc);
    for (catalog.invalid_ids.items) |id| {
        const kind = kindOf(&store, alloc, id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                debug_trace.logf("convert", "action=KindUnknown session={s} err={s}", .{ id, @errorName(err) });
                break :blk .root;
            },
        };
        if (kind != .root) continue;
        const changed_ms: i64 = if (sessions.dir.statFile(io_mod.getIo(), id, .{ .follow_symlinks = false })) |stat|
            std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse 0
        else |err| blk: {
            debug_trace.logf("convert", "action=ListedWithoutTime session={s} err={s}", .{ id, @errorName(err) });
            break :blk 0;
        };
        const owned_id = try alloc.dupe(u8, id);
        catalog.summaries.append(alloc, .{
            .id = owned_id,
            .created_at_ms = changed_ms,
            .updated_at_ms = changed_ms,
            .conversation_language = types.ConversationLanguage.default(),
            .history_len = 0,
        }) catch |err| {
            alloc.free(owned_id);
            return err;
        };
    }
    return catalog;
}

fn openMemberDir(store: *session_store.Store, id: []const u8) !?io_mod.VerifiedDir {
    const sessions = &(store.canonical_root.sessions orelse return null);
    // Read whatever its mode: an old release left v1's folders readable by
    // others (D61).
    return io_mod.openRealDirIfPresent(sessions, id);
}

/// Whether v1 has a folder named `id` in `home`'s profile. An error for
/// anything but its absence, so a new v2 id never takes a v1 id that could
/// not be checked (`tla/V1Conversion.tla` NoShadow).
pub fn hasFolder(home: []const u8, id: []const u8) !bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/{s}/{s}/{s}", .{ home, profile_paths.root_dir_name, profile_paths.sessions_dir_name, id });
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => false,
        else => err,
    };
    return true;
}

// ---------------------------------------------------------------------------
// Locking a family (TLA `CBegin`)

pub const Locked = struct {
    id: []u8,
    dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
};

/// Releases `locked`'s lock and folder, and frees its id.
pub fn releaseLocked(alloc: Allocator, locked: *Locked) void {
    locked.lock.release();
    locked.dir.close();
    alloc.free(locked.id);
}

/// A v1 family under every present member's writer lock: the root first,
/// then each child its root names whose folder exists. Release with
/// `release`, which keeps no lock.
pub const Family = struct {
    alloc: Allocator,
    /// `members[0]` is the root.
    members: std.ArrayList(Locked) = .empty,
    /// The root's `subagent/children.json`, read under its lock; empty in
    /// schema 3, whose relationship index names children but keeps no
    /// registry.
    registry: child_state.Registry,
    /// The children the root names whose folder is gone: recorded lost
    /// (D33), and their staging swept with the family's.
    absent: std.ArrayList([]u8) = .empty,

    pub fn release(family: *Family) void {
        for (family.members.items) |*member| releaseLocked(family.alloc, member);
        family.members.deinit(family.alloc);
        family.registry.deinit(family.alloc);
        for (family.absent.items) |id| family.alloc.free(id);
        family.absent.deinit(family.alloc);
        family.* = undefined;
    }

    /// Whether `id` is a locked member; a registry child that is not has no
    /// v1 folder left (D61: recorded lost).
    pub fn isMember(family: *const Family, id: []const u8) bool {
        for (family.members.items) |member| if (std.mem.eql(u8, member.id, id)) return true;
        return false;
    }
};

/// Locks `root_id`'s family within `wait_ms`, all members or none:
/// `error.SessionBusy` when any is held, `error.SessionNotFound` when the
/// root's folder is gone (another process may have converted it meanwhile),
/// `error.InvalidSessionFormat` with `problem` set when the registry or
/// relationship index cannot be read.
pub fn lockFamily(alloc: Allocator, store: *session_store.Store, root_id: []const u8, wait_ms: u64, problem: *Problem) !Family {
    const started = io_mod.milliTimestamp();
    var family: Family = .{ .alloc = alloc, .registry = try child_state.Registry.init(alloc, root_id) };
    errdefer family.release();
    try family.members.ensureUnusedCapacity(alloc, 1);
    family.members.appendAssumeCapacity((try lockMember(alloc, store, root_id, started, wait_ms)) orelse return error.SessionNotFound);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var child_ids: std.ArrayList([]const u8) = .empty;
    if (try readRegistry(alloc, a, &family.members.items[0].dir, root_id, problem)) |registry| {
        family.registry.deinit(alloc);
        family.registry = registry;
        for (registry.children) |child| try child_ids.append(a, child.id);
    } else try indexedChildren(a, &family.members.items[0].dir, &child_ids, problem);
    for (child_ids.items) |child_id| {
        try family.members.ensureUnusedCapacity(alloc, 1);
        try family.absent.ensureUnusedCapacity(alloc, 1);
        if (try lockMember(alloc, store, child_id, started, wait_ms)) |locked| {
            family.members.appendAssumeCapacity(locked);
        } else family.absent.appendAssumeCapacity(try alloc.dupe(u8, child_id));
    }
    return family;
}

/// The locked root's `subagent/children.json`, read from its folder with
/// v1's own parser, or null when it has none. Owned by `alloc`.
fn readRegistry(alloc: Allocator, a: Allocator, root: *io_mod.VerifiedDir, root_id: []const u8, problem: *Problem) !?child_state.Registry {
    var subagent = (try io_mod.openRealDirIfPresent(root, subagent_dir)) orelse return null;
    defer subagent.close();
    const bytes = (try readFileIfPresent(a, &subagent, "children.json", child_state.max_state_bytes + 1)) orelse return null;
    return child_state.parseRegistry(alloc, bytes, root_id) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("subagent/children.json {s}", .{describe(a, bytes, err)}),
    };
}

/// The children schema 3's relationship index names, read only when the
/// root has no `children.json`, as v1's `sessionHasManagedChildren`
/// (`session_store.zig`) reads it, with v1's own codec. That format keeps
/// no registry beside it, so v1 itself has no child lines for them. In `a`.
fn indexedChildren(a: Allocator, root: *io_mod.VerifiedDir, ids: *std.ArrayList([]const u8), problem: *Problem) !void {
    var subagent = (try io_mod.openRealDirIfPresent(root, subagent_dir)) orelse return;
    defer subagent.close();
    const index_file = session_child_store.subagent_relationship_index_file;
    const header_bytes = (try readFileIfPresent(a, &subagent, index_file, relationship_index_codec.max_header_bytes + 1)) orelse return;
    const header = relationship_index_codec.decodeHeader(header_bytes) catch |err|
        return problem.set("subagent/{s} can't be read ({s})", .{ index_file, @errorName(err) });
    var offset: u64 = 0;
    var page_number: u64 = 0;
    while (offset < header.high_watermark) : (page_number += 1) {
        const page_name = relationship_index_codec.pageFileName(page_number);
        const page_bytes = (try readFileIfPresent(a, &subagent, &page_name, relationship_index_codec.max_page_bytes + 1)) orelse
            return problem.set("subagent/{s} is missing", .{&page_name});
        const page = relationship_index_codec.decodePage(page_bytes, page_number, header.storage_epoch) catch |err|
            return problem.set("subagent/{s} can't be read ({s})", .{ &page_name, @errorName(err) });
        const slots: usize = @intCast(@min(header.high_watermark - offset, relationship_index_codec.page_slots));
        for (page.slots[0..slots]) |*slot| {
            if (!slot.occupied) continue;
            const id = slot.childId();
            // Locked once: a second lock on the same folder would be busy.
            const known = for (ids.items) |known_id| {
                if (std.mem.eql(u8, known_id, id)) break true;
            } else false;
            if (!known) try ids.append(a, try a.dupe(u8, id));
        }
        offset += slots;
    }
}

const subagent_dir = "subagent";

/// One member's lock within what is left of the family's wait; null when
/// its folder is gone, including when another process converted it and
/// removed the folder while this one waited for the lock (D61).
fn lockMember(alloc: Allocator, store: *session_store.Store, id: []const u8, started: i64, wait_ms: u64) !?Locked {
    var dir = (try openMemberDir(store, id)) orelse return null;
    errdefer dir.close();
    const spent: u64 = @intCast(@max(io_mod.milliTimestamp() - started, 0));
    var lock = io_mod.acquireTimedAdvisoryLock(&dir, lock_file, wait_ms -| spent) catch |err| return switch (err) {
        error.LockBusy => error.SessionBusy,
        else => err,
    };
    errdefer lock.release();
    if (!try stillInPlace(store, id, &dir)) {
        debug_trace.logf("convert", "action=Vanished session={s}", .{id});
        lock.release();
        dir.close();
        return null;
    }
    return .{ .id = try alloc.dupe(u8, id), .dir = dir, .lock = lock };
}

/// Whether the folder `dir` is still the one v1's sessions folder names
/// `id`: a removal renames it into the trash first.
fn stillInPlace(store: *session_store.Store, id: []const u8, dir: *io_mod.VerifiedDir) !bool {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return false);
    const named = sessions.dir.statFile(io, id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return named.kind == .directory and named.inode == (try dir.dir.stat(io)).inode;
}

/// One lock with no wait, for a leftover (TLA `CClean`): null when another
/// process holds it or the folder is gone.
pub fn tryLockLeftover(alloc: Allocator, store: *session_store.Store, id: []const u8) !?Locked {
    return lockMember(alloc, store, id, io_mod.milliTimestamp(), 0) catch |err| switch (err) {
        error.SessionBusy => null,
        else => err,
    };
}

// ---------------------------------------------------------------------------
// Reading a member

/// One step of a member's history, in the order v2 writes it.
const Step = union(enum) {
    /// A turn as v1 framed it: its pieces, and its end piece when it ended.
    framed: Framed,
    /// A whole turn: an older format's, or the one a recovery checkpoint
    /// keeps, which v1 shows as interrupted (D56).
    whole: Whole,
    compacted: Compacted,
};

const Framed = struct {
    events: []const Event,
    /// No end piece: v1 closes it as failed on its next writable open.
    open: bool,
    ts_ms: u64,
};

const Whole = struct {
    turn: types.HistoryTurn,
    ts_ms: u64,
};

const Compacted = struct {
    summary: []const u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// The member's turn (from 0) the compaction keeps from when that turn
    /// precedes this step; null keeps the turns after it.
    keep_from: ?usize,
    ts_ms: u64,
};

/// One member as v1 shows it. Everything lives in `arena`.
pub const Member = struct {
    arena: std.heap.ArenaAllocator,
    workspace: []const u8,
    created_ms: u64,
    /// The time v1's listing shows (`session_discovery.zig`), which the
    /// converted log's newest line keeps (D20).
    listed_ms: u64,
    /// The `updated_at_ms` v1's usage recovery reads, which the converted
    /// usage checkpoint keeps (D20).
    usage_at_ms: i64,
    language: types.ConversationLanguage,
    preferences: session_codec.DurableSessionPreferences,
    title: ?[]const u8,
    permissions: session_permission_state.State,
    usage: ?session_usage.Snapshot,
    steps: []const Step,
    turns: usize,
    /// Results an older format kept inline, which v1's migration stores as
    /// side files under the handles `steps` now name.
    stored: []const Stored,
    /// SHA-256 of the member's content files, lowercase hex (D60).
    fingerprint: [64]u8,

    pub fn deinit(member: *Member) void {
        member.arena.deinit();
        member.* = undefined;
    }
};

/// A side file's bytes, named `key` (`tool-results/{handle}`).
pub const Stored = struct {
    key: []const u8,
    bytes: []const u8,
};

/// Reads a locked member read-only. `error.InvalidSessionFormat` with
/// `problem` set when v1 could not read it either.
pub fn readMember(gpa: Allocator, store: *session_store.Store, locked: *Locked, problem: *Problem) !Member {
    var member: Member = undefined;
    member.arena = .init(gpa);
    errdefer member.arena.deinit();
    const a = member.arena.allocator();
    member.stored = &.{};
    member.fingerprint = fingerprintOf(a, &locked.dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("its folder can't be read ({s})", .{@errorName(err)}),
    };
    const metadata = readMetadata(a, &locked.dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json can't be read ({s})", .{@errorName(err)}),
    };
    switch (metadata) {
        .missing => return problem.set("session.json is missing", .{}),
        // A legacy snapshot: v1's older reader reads it whole.
        .too_large => try readOlderFormat(a, store, locked, &member, problem),
        .bytes => |bytes| {
            if (!(std.json.validate(a, bytes) catch false)) return problem.set("session.json is not valid JSON", .{});
            if (isConversationMetadata(a, bytes)) {
                try readConversation(a, locked, bytes, &member, problem);
            } else try readOlderFormat(a, store, locked, &member, problem);
        },
    }
    var turns: usize = 0;
    for (member.steps) |step| {
        if (step != .compacted) turns += 1;
    }
    member.turns = turns;
    return member;
}

/// `session.json`, unless it is missing or larger than the current
/// format's metadata ever is, as a legacy snapshot can be.
const Metadata = union(enum) { missing, too_large, bytes: []u8 };

fn readMetadata(alloc: Allocator, dir: *io_mod.VerifiedDir) !Metadata {
    const bytes = readFileIfPresent(alloc, dir, "session.json", session_codec.max_session_metadata_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => return .too_large,
        else => return err,
    };
    return if (bytes) |value| .{ .bytes = value } else .missing;
}

fn isConversationMetadata(a: Allocator, bytes: []const u8) bool {
    const Probe = struct { schema_version: u64 = 0 };
    const probe = std.json.parseFromSliceLeaky(Probe, a, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    return probe.schema_version == session_codec.session_metadata_schema_version;
}

/// The current format: `session.json` and `events.jsonl` frames, read as
/// v1's state load reads them.
fn readConversation(a: Allocator, locked: *Locked, metadata_bytes: []const u8, member: *Member, problem: *Problem) !void {
    const metadata = session_codec.decodeSessionMetadata(a, metadata_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json {s}", .{describe(a, metadata_bytes, err)}),
    };
    const value = metadata.value;
    if (!std.mem.eql(u8, value.id, locked.id)) return problem.set("session.json names another session", .{});
    member.workspace = value.workspace_root;
    member.created_ms = @intCast(@max(value.created_at_ms, 0));
    member.usage_at_ms = value.updated_at_ms;
    member.language = types.ConversationLanguage.fromSlice(value.conversation_language) catch
        return problem.set("session.json has an unknown conversation language", .{});
    member.preferences = .{
        .provider = value.provider,
        .model = try a.dupe(u8, value.model),
        .effort = types.ReasoningEffort.parse(value.effort) orelse return problem.set("session.json has an unknown effort", .{}),
        .fast_mode = value.fast_mode,
        .ultrafast_mode = value.ultrafast_mode orelse false,
    };
    member.title = value.title;
    member.permissions = try readPermissions(a, &locked.dir, problem);
    member.usage = session_usage_sidecar.loadConversation(a, &locked.dir, locked.id, value.updated_at_ms) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("usage-v2.json can't be read ({s})", .{@errorName(err)}),
    };

    var frames: FrameReader = .{ .arena = a, .dir = &locked.dir, .id = locked.id, .problem = problem, .builder = .init(a) };
    defer frames.builder.deinit();
    try frames.readAll();
    try frames.finish();
    member.steps = frames.steps.items;
    member.listed_ms = listedTime(&locked.dir, value.updated_at_ms, frames.steps.items.len > 0);
}

fn readPermissions(a: Allocator, dir: *io_mod.VerifiedDir, problem: *Problem) !session_permission_state.State {
    const state = session_log.loadConversationPermissionState(a, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("permissions.json can't be read ({s})", .{@errorName(err)}),
    };
    // v1 migrates an older schema on its first writable open.
    if (state.version == session_permission_state.schema_version) return state;
    return session_permission_state.migrateV1ToV2(a, state) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("permissions.json can't be migrated ({s})", .{@errorName(err)}),
    };
}

/// v1's listing time: `session.json`'s, or the log's change time once the
/// session has history (`session_discovery.zig`).
fn listedTime(dir: *io_mod.VerifiedDir, updated_at_ms: i64, has_history: bool) u64 {
    var listed = updated_at_ms;
    if (has_history) {
        if (dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{ .follow_symlinks = false })) |stat| {
            const changed = std.math.cast(i64, @divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)) orelse std.math.maxInt(i64);
            listed = @max(listed, changed);
        } else |_| {}
    }
    return @intCast(@max(listed, 0));
}

/// Reads `events.jsonl` frame by frame into steps, checking each turn with
/// the builder v1's reader and v2's replay share, so a log v1 can read
/// converts and one it cannot is refused.
const FrameReader = struct {
    arena: Allocator,
    dir: *io_mod.VerifiedDir,
    id: []const u8,
    problem: *Problem,
    builder: session_log.ConversationTurnBuilder,
    steps: std.ArrayList(Step) = .empty,
    /// The seq of each written turn's last frame, for compaction coverage.
    turn_last_seq: std.ArrayList(u64) = .empty,
    /// The open turn's events, and the compactions inside it, which go
    /// before it (`Compacted.keep_from`).
    open: std.ArrayList(Event) = .empty,
    open_user_seq: ?u64 = null,
    deferred: std.ArrayList(Step) = .empty,
    compactions: usize = 0,
    last_seq: u64 = 0,
    last_ts: u64 = 0,
    line: usize = 0,

    /// The whole log in the arena, so each frame's strings can borrow from
    /// it rather than be copied.
    fn readAll(reader: *FrameReader) !void {
        const io = io_mod.getIo();
        var file = reader.dir.dir.openFile(io, "events.jsonl", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return reader.problem.set("events.jsonl can't be opened ({s})", .{@errorName(err)}),
        };
        defer file.close(io);
        const log = blk: {
            const length = file.length(io) catch |err| return reader.problem.set("events.jsonl can't be read ({s})", .{@errorName(err)});
            // One byte past the length, so the read sees the end.
            const limit = std.math.cast(usize, length +| 1) orelse return error.OutOfMemory;
            break :blk io_mod.readFileToEnd(reader.arena, &file, limit) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return reader.problem.set("events.jsonl can't be read ({s})", .{@errorName(err)}),
            };
        };
        // A torn last line, with no newline, is left out: v1's reader stops
        // before it, and its next writable open cuts it.
        var rest = log;
        while (std.mem.findScalar(u8, rest, '\n')) |newline| {
            reader.line += 1;
            try reader.frame(rest[0 .. newline + 1]);
            rest = rest[newline + 1 ..];
        }
    }

    fn frame(reader: *FrameReader, bytes: []const u8) !void {
        const envelope = session_event.decodeConversationFrameLeaky(reader.arena, bytes, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidConversationFrame => return reader.problem.set("events.jsonl line {d} {s}", .{
                reader.line,
                if (std.json.validate(reader.arena, std.mem.trimEnd(u8, bytes, "\n")) catch false) "is not a valid event" else "is not valid JSON",
            }),
        };
        if (envelope.seq != reader.last_seq + 1) return reader.problem.set("events.jsonl line {d} is out of order", .{reader.line});
        reader.last_seq = envelope.seq;
        const ts: u64 = @intCast(envelope.timestamp_ms);
        reader.last_ts = @max(reader.last_ts, ts);
        reader.apply(envelope.event, envelope.seq) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `problem` already names the file, as for a prompt image.
            error.InvalidSessionFormat => return error.InvalidSessionFormat,
            else => return reader.problem.set("events.jsonl line {d} does not fit its turn ({s})", .{ reader.line, @errorName(err) }),
        };
    }

    fn apply(reader: *FrameReader, event: Event, seq: u64) !void {
        const a = reader.arena;
        switch (event) {
            .user => |value| {
                if (reader.open_user_seq != null) return error.InvalidConversationFrame;
                try reader.builder.begin(value);
                reader.open_user_seq = seq;
                var user = value;
                user.images = try withImages(a, reader.dir, reader.id, value.images, reader.problem);
                try reader.open.append(a, .{ .user = user });
            },
            .assistant => |value| {
                try reader.requireOpen();
                try reader.builder.appendAssistant(value);
                try reader.open.append(a, event);
            },
            .tool_call => |value| {
                try reader.requireOpen();
                try reader.builder.appendToolCall(value);
                try reader.open.append(a, event);
            },
            .tool_result => |value| {
                try reader.requireOpen();
                try reader.builder.appendToolResult(value);
                try reader.open.append(a, event);
            },
            .steering => |value| {
                try reader.requireOpen();
                try reader.builder.appendSteering(value.text);
                try reader.open.append(a, event);
            },
            // The builder only checks the turn; its copy lives in the arena.
            .turn_completed => |value| {
                try reader.requireOpen();
                _ = try reader.builder.finishAssistant(value);
                try reader.end(event, seq);
            },
            .interrupted => |value| {
                try reader.requireOpen();
                _ = try reader.builder.finishInterrupted(value);
                try reader.end(event, seq);
            },
            .context_checkpoint => |checkpoint| {
                try reader.builder.finishStandalone();
                reader.compactions += 1;
                // v1's window: the turns that end at or before the coverage
                // are summarized; the first turn with a frame after it stays
                // (`session_log.zig` `ConversationReplayScan`).
                var prior: usize = 0;
                var keep_from: ?usize = null;
                for (reader.turn_last_seq.items, 0..) |last, index| {
                    if (last <= checkpoint.covers_through_seq) {
                        prior += 1;
                    } else if (keep_from == null) keep_from = index;
                }
                const step: Step = .{ .compacted = .{
                    .summary = checkpoint.summary,
                    .removed_turn_count = prior,
                    .compaction_count = reader.compactions,
                    .keep_from = keep_from,
                    .ts_ms = reader.last_ts,
                } };
                // Inside a turn it goes before that turn, which v2 keeps whole.
                if (reader.open_user_seq != null) try reader.deferred.append(a, step) else try reader.steps.append(a, step);
            },
        }
    }

    fn requireOpen(reader: *const FrameReader) error{InvalidConversationFrame}!void {
        if (reader.open_user_seq == null) return error.InvalidConversationFrame;
    }

    /// Ends the open turn with `event`, its end piece.
    fn end(reader: *FrameReader, event: Event, seq: u64) !void {
        try reader.open.append(reader.arena, event);
        try reader.flushDeferred();
        try reader.steps.append(reader.arena, .{ .framed = .{ .events = try reader.open.toOwnedSlice(reader.arena), .open = false, .ts_ms = reader.last_ts } });
        try reader.turn_last_seq.append(reader.arena, seq);
        reader.open_user_seq = null;
    }

    fn flushDeferred(reader: *FrameReader) !void {
        try reader.steps.appendSlice(reader.arena, reader.deferred.items);
        reader.deferred.clearRetainingCapacity();
    }

    /// The log's end. An open turn is the recovery checkpoint's when its
    /// seq is the log's last (D56), else its pieces, ended as v1's next
    /// writable open ends it. A checkpoint with no open turn is dropped,
    /// as v1 never shows one.
    fn finish(reader: *FrameReader) !void {
        const a = reader.arena;
        const checkpoint = session_log.loadConversationRecoveryCheckpoint(a, reader.dir, reader.last_seq) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return reader.problem.set("recovery.json can't be read ({s})", .{@errorName(err)}),
        };
        try reader.flushDeferred();
        if (reader.open_user_seq == null) {
            if (checkpoint != null) debug_trace.logf("convert", "action=RecoveryDropped session={s} reason=turn_not_open", .{reader.id});
            return;
        }
        if (checkpoint) |value| {
            var kept = value;
            // As v1's load joins a checkpoint to its open turn's work.
            if (kept.user.work_id == null) {
                if (reader.open.items[0].user.work_id) |work_id| kept.user.work_id = try a.dupe(u8, work_id);
            }
            kept.user.images = try withImages(a, reader.dir, reader.id, kept.user.images, reader.problem);
            try reader.steps.append(a, .{ .whole = .{ .turn = kept.interruptedTurn(), .ts_ms = reader.last_ts } });
            return;
        }
        try reader.steps.append(a, .{ .framed = .{ .events = try reader.open.toOwnedSlice(a), .open = true, .ts_ms = reader.last_ts } });
    }
};

/// Schema 3 and the legacy snapshots, through v1's older reader (D61).
fn readOlderFormat(a: Allocator, store: *session_store.Store, locked: *Locked, member: *Member, problem: *Problem) !void {
    var detail = store.loadReadOnlyDetail(a, locked.id, .{ .allow_large_legacy = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("session.json can't be read in any format this fx knows ({s})", .{@errorName(err)}),
    };
    const state = &detail.state;
    member.workspace = state.workspace_root;
    member.created_ms = @intCast(@max(state.created_at_ms, 0));
    member.usage_at_ms = state.updated_at_ms;
    member.listed_ms = @intCast(@max(detail.summary.updated_at_ms, 0));
    member.language = state.conversation_language;
    member.preferences = state.preferences;
    member.title = detail.summary.title;
    member.permissions = state.permission_state;
    if (state.permission_state.version != session_permission_state.schema_version) {
        member.permissions = session_permission_state.migrateV1ToV2(a, state.permission_state) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return problem.set("permissions can't be migrated ({s})", .{@errorName(err)}),
        };
    }
    member.usage = state.usage;
    // As v1's migration leaves it (`session_log.zig`
    // `importLegacySnapshotStateWithOps`): a history-only checkpoint kept as
    // an interrupted turn, the rest dropped; empty file evidence dropped;
    // each result kept inline stored under v1's handle.
    if (!try state.archive_legacy_recovery(a) and state.recovery_checkpoint != null)
        debug_trace.logf("convert", "action=RecoveryDropped session={s} reason=older_format", .{locked.id});
    _ = try session_log.discardEmptyLegacyFileEvidence(a, state.history);
    // Schema 3 keeps its history in its log, a legacy session in its
    // snapshot.
    const history_file: []const u8 = if (locked.dir.dir.statFile(io_mod.getIo(), "authority.json", .{ .follow_symlinks = false })) |_| "events.jsonl" else |_| "session.json";
    var stored: std.ArrayList(Stored) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    const ts_floor: u64 = member.created_ms;
    var last_ts: u64 = ts_floor;
    for (state.history, 1..) |*turn, number| {
        switch (turn.*) {
            inline .assistant, .interrupted => |*entry| {
                entry.user.images = try withImages(a, &locked.dir, locked.id, entry.user.images, problem);
                try storeInline(a, &entry.execution, &stored);
            },
            .compacted_summary => {},
        }
        try requireKeepable(a, turn.*, history_file, number, problem);
        last_ts = @max(last_ts, turnTime(turn.*));
        try steps.append(a, switch (turn.*) {
            .compacted_summary => |summary| .{ .compacted = .{
                .summary = summary.summary,
                .removed_turn_count = summary.removed_turn_count,
                .compaction_count = summary.compaction_count,
                .keep_from = null,
                .ts_ms = last_ts,
            } },
            .assistant, .interrupted => .{ .whole = .{ .turn = turn.*, .ts_ms = last_ts } },
        });
    }
    member.steps = steps.items;
    member.stored = stored.items;
}

/// Refuses an older format's turn that the current event format cannot
/// keep, as v1's own migration refuses it when it continues the session:
/// a prompt with bytes that are not UTF-8, which schema 3 kept, or another
/// field past an event rule (`session_event.validateConversationEventShape`).
fn requireKeepable(a: Allocator, turn: types.HistoryTurn, file: []const u8, number: usize, problem: *Problem) !void {
    const user = switch (turn) {
        .assistant => |entry| entry.user,
        .interrupted => |entry| entry.user,
        .compacted_summary => return,
    };
    if (!std.unicode.utf8ValidateSlice(user.text))
        return problem.set("{s} turn {d} has a prompt that is not valid UTF-8, which the current format can't keep", .{ file, number });
    var events: std.ArrayList(Event) = .empty;
    session_event.appendHistoryTurnConversationEvents(a, &events, turn) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return problem.set("{s} turn {d} has a field the current format can't keep ({s})", .{ file, number, @errorName(err) }),
    };
    for (events.items) |event| session_event.validateConversationEventShape(event, session_event.conversation_schema_version) catch |err|
        return problem.set("{s} turn {d} has a field the current format can't keep ({s})", .{ file, number, @errorName(err) });
}

/// v1's migration of an older format's results, whose completeness that
/// format did not record (`session_log.externalizeExecutionResults`): each
/// inline result goes to a side file under v1's handle and is marked
/// truncated, so v1's next load shows its preview wrapped with that handle;
/// each result gets its preview. In `a`.
fn storeInline(a: Allocator, execution: *types.ExecutionMemory, stored: *std.ArrayList(Stored)) !void {
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        if (result.output_handle == null) {
            const handle = try result_store.makeHandle(a, result.tool_call_id, result.tool_name, result.output);
            try stored.append(a, .{ .key = try std.fmt.allocPrint(a, "tool-results/{s}", .{handle}), .bytes = result.output });
            result.output_handle = handle;
            result.truncated = true;
            result.stored_output_bytes = result.output.len;
        }
        if (result.preview == null) result.preview = try result_store.previewText(a, result.output, result_store.preview_bytes);
    };
}

fn turnTime(turn: types.HistoryTurn) u64 {
    const summary = switch (turn) {
        .assistant => |entry| entry.execution.turn_summary,
        .interrupted => |entry| entry.execution.turn_summary,
        .compacted_summary => null,
    } orelse return 0;
    return @intCast(@max(summary.completed_at_ms, 0));
}

/// `images` with each v1 prompt image's bytes inside, as a v2 prompt keeps
/// them (D44), since its v1 folder goes once the conversion lands. One
/// whose file is gone keeps its path, as v1 shows a lost snapshot; one that
/// cannot be read refuses the member, `problem` set, so its v1 folder
/// stays. In `a`.
fn withImages(a: Allocator, dir: *io_mod.VerifiedDir, id: []const u8, images: []const types.ImageAttachment, problem: *Problem) ![]types.ImageAttachment {
    const copy = try a.dupe(types.ImageAttachment, images);
    for (copy) |*image| {
        if (image.inline_data != null) continue;
        const leaf = snapshotLeaf(image.snapshot_path orelse continue, id) orelse continue;
        const bytes = blk: {
            var images_dir = (io_mod.openRealDirIfPresent(dir, "images") catch |err|
                return problem.set("images can't be opened ({s})", .{@errorName(err)})) orelse break :blk null;
            defer images_dir.close();
            break :blk readFileIfPresent(a, &images_dir, leaf, max_image_bytes + 1) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return problem.set("images/{s} can't be read ({s})", .{ leaf, @errorName(err) }),
            };
        };
        image.inline_data = bytes orelse {
            debug_trace.logf("convert", "action=ImageLost session={s} image={s}", .{ id, leaf });
            continue;
        };
        image.snapshot_path = null;
    }
    return copy;
}

const max_image_bytes = 64 * 1024 * 1024;

/// The file name of a snapshot v1 kept in session `id`'s `images` folder:
/// its log names it `images/{leaf}`, and its older reader resolves that
/// under the session's folder.
fn snapshotLeaf(path: []const u8, id: []const u8) ?[]const u8 {
    const prefix = "images/";
    const leaf = if (std.mem.startsWith(u8, path, prefix)) path[prefix.len..] else blk: {
        const at = std.mem.findLast(u8, path, "/" ++ prefix) orelse return null;
        const folder = path[0..at];
        if (!std.mem.endsWith(u8, folder, id) or (folder.len > id.len and folder[folder.len - id.len - 1] != '/')) return null;
        break :blk path[at + 1 + prefix.len ..];
    };
    if (leaf.len == 0 or std.mem.findAny(u8, leaf, "/\\") != null or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return null;
    return leaf;
}

// ---------------------------------------------------------------------------
// Fingerprint (D60)

/// Files that are not a session's content: locks, liveness and caches,
/// which v1 rewrites without changing the session.
const not_content = [_][]const u8{ lock_file, "owner.live", "recovery.asked", "commit.lock", "history-cache.bin" };

/// SHA-256 over the member's content files, by name, as lowercase hex: its
/// top-level files but `not_content`, its registry and its client files.
pub fn fingerprintOf(a: Allocator, dir: *io_mod.VerifiedDir) ![64]u8 {
    const io = io_mod.getIo();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const skip = for (not_content) |name| {
            if (std.mem.eql(u8, name, entry.name)) break true;
        } else false;
        if (!skip) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for ([_][]const u8{ "subagent/children.json", "client/system-prompt.txt", "client/mcp-tool-identities.json" }) |name| try names.append(a, name);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    for (names.items) |name| {
        var file = dir.dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io);
        hash.update(name);
        hash.update(&.{0});
        var offset: u64 = 0;
        while (true) {
            const n = try file.readPositional(io, &.{&buffer}, offset);
            if (n == 0) break;
            hash.update(buffer[0..n]);
            offset += n;
        }
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, offset, .little);
        hash.update(&size);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// ---------------------------------------------------------------------------
// Removing a converted member's v1 state (TLA `CDelete`, `CClean`)

/// Renames the locked member's folder into the trash, then deletes it
/// there, while its lock is still held, so a v1 writer waiting on that lock
/// finds an emptied folder and fails instead of writing into the trash.
/// The rename is the first call that touches the folder. A refused step is
/// traced and left for a later open (D60); it never fails the caller.
pub fn removeFolder(store: *session_store.Store, id: []const u8, why: []const u8) bool {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return false);
    var trash = io_mod.openOrCreateVerifiedPrivateDir(sessions, trash_dir_name) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=trash err={s}", .{ id, why, @errorName(err) });
        return false;
    };
    defer trash.close();
    // A same-id entry left by an earlier removal; if it stays, the rename
    // below fails and says so.
    trash.dir.deleteTree(io, id) catch |err|
        debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ id, @errorName(err) });
    std.Io.Dir.rename(sessions.dir, id, trash.dir, id, io) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=rename err={s}", .{ id, why, @errorName(err) });
        return false;
    };
    trash.dir.deleteTree(io, id) catch |err| {
        debug_trace.logf("convert", "action=DeleteRefused session={s} why={s} step=remove err={s}", .{ id, why, @errorName(err) });
        return true;
    };
    debug_trace.logf("convert", "action=Deleted session={s} why={s}", .{ id, why });
    return true;
}

/// Empties the trash a refused or interrupted removal left (D60). What it
/// cannot remove stays for a later open, traced.
pub fn emptyTrash(alloc: Allocator, store: *session_store.Store) void {
    const io = io_mod.getIo();
    const sessions = &(store.canonical_root.sessions orelse return);
    var trash = (io_mod.openVerifiedPrivateDirIfPresent(sessions, trash_dir_name) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry=- err={s}", .{@errorName(err)});
        return;
    }) orelse return;
    defer trash.close();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var it = trash.dir.iterate();
    while (it.next(io) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry=- err={s}", .{@errorName(err)});
        return;
    }) |entry| {
        names.ensureUnusedCapacity(alloc, 1) catch |err| {
            debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ entry.name, @errorName(err) });
            return;
        };
        names.appendAssumeCapacity(alloc.dupe(u8, entry.name) catch |err| {
            debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ entry.name, @errorName(err) });
            return;
        });
    }
    for (names.items) |name| trash.dir.deleteTree(io, name) catch |err| {
        debug_trace.logf("convert", "action=TrashKept entry={s} err={s}", .{ name, @errorName(err) });
    };
}

// ---------------------------------------------------------------------------
// Usage markers (D20, D56)

/// What v1's verdict on a usage-recovery marker reads from it: the update
/// it protects and the time it was written. Another marker for the same
/// session differs in one of them.
pub const MarkerId = struct {
    protected_ms: ?i64,
    modified_ns: i128,

    pub fn eql(x: MarkerId, y: MarkerId) bool {
        return x.protected_ms == y.protected_ms and x.modified_ns == y.modified_ns;
    }
};

/// v1's usage-recovery marker of `id` as it stands, or null when there is
/// none; an error when it cannot be read.
pub fn markerOf(store: *session_store.Store, id: []const u8) !?MarkerId {
    var recovery = (try openUsageRecovery(store)) orelse return null;
    defer recovery.close();
    const protected = session_store.validateUsageRecoveryMarker(&recovery, id) catch |err| switch (err) {
        error.UsageRecoveryMarkerNotFound => return null,
        else => return err,
    };
    const marker_stat = try recovery.dir.statFile(io_mod.getIo(), id, .{ .follow_symlinks = false });
    return .{ .protected_ms = protected, .modified_ns = marker_stat.mtime.nanoseconds };
}

/// v1's marker of a member and v1's verdict on it
/// (`usage_recovery.checkpointIsNewer`): whether the member's checkpoint is
/// at least as new as what the marker protects.
const Marker = struct { id: MarkerId, newer: bool };

/// Null when there is no marker; an error when it cannot be read (D20).
pub fn readMarker(store: *session_store.Store, id: []const u8, member: *const Member) !?Marker {
    const marker = (try markerOf(store, id)) orelse return null;
    const usage = member.usage orelse return .{ .id = marker, .newer = false };
    // As v1's own recovery reads it: no checkpoint time is an old one.
    const checkpoint_modified = store.usageCheckpointModifiedAtNs(id) catch null;
    return .{ .id = marker, .newer = usage_recovery.checkpointIsNewer(usage, member.usage_at_ms, checkpoint_modified, marker.modified_ns, marker.protected_ms) };
}

/// Removes v1's marker of `id` once v2 holds the session's usage: false,
/// traced, when it stays.
pub fn removeMarker(store: *session_store.Store, id: []const u8) bool {
    var recovery = (openUsageRecovery(store) catch |err| {
        debug_trace.logf("convert", "action=MarkerKept session={s} err={s}", .{ id, @errorName(err) });
        return false;
    }) orelse return true;
    defer recovery.close();
    recovery.dir.deleteFile(io_mod.getIo(), id) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            debug_trace.logf("convert", "action=MarkerKept session={s} err={s}", .{ id, @errorName(err) });
            return false;
        },
    };
    return true;
}

/// v1's `~/.fx/usage-recovery`, or null when it has none.
fn openUsageRecovery(store: *session_store.Store) !?io_mod.VerifiedDir {
    var home: io_mod.VerifiedDir = .{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), store.home_dir, .{}) };
    defer home.close();
    var fx = (try io_mod.openRealDirIfPresent(&home, profile_paths.root_dir_name)) orelse return null;
    defer fx.close();
    return io_mod.openVerifiedPrivateDirIfPresent(&fx, profile_paths.usage_recovery_dir_name);
}

// ---------------------------------------------------------------------------
// Helpers

fn readFileIfPresent(a: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, max_bytes: usize) !?[]u8 {
    var file = dir.dir.openFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(a, &file, max_bytes);
}

/// The reason a file failed to decode, for `Problem`.
fn describe(a: Allocator, bytes: []const u8, err: anyerror) []const u8 {
    if (!(std.json.validate(a, bytes) catch false)) return "is not valid JSON";
    return @errorName(err);
}

test "an older turn the current event format cannot keep names its file, turn and cause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    // Schema 3 kept a prompt's bytes even when they were not UTF-8.
    const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("bad \xff byte") }, .assistant = @constCast("answer") } };
    try std.testing.expectError(error.InvalidSessionFormat, requireKeepable(arena.allocator(), turn, "events.jsonl", 3, &problem));
    try std.testing.expectEqualStrings("events.jsonl turn 3 has a prompt that is not valid UTF-8, which the current format can't keep", problem.text());
    const fine: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = @constCast("fine") }, .assistant = @constCast("answer") } };
    try requireKeepable(arena.allocator(), fine, "events.jsonl", 1, &problem);
}
