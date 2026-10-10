//! The profile usage ledger store: `~/.fx/usage.jsonl` under `~/.fx/usage.lock`.
//!
//! Older fx binaries read and write the same files at the same time, so the
//! store keeps their behavior byte for byte:
//!
//! - **Layout and modes:** `~/.fx` is a real 0700 directory and `usage.jsonl`
//!   and `usage.lock` are regular 0600 files. Readers only check; writers
//!   repair the modes. `read_only` stores never create `~/.fx`.
//! - **Lock:** writers take `usage.lock` (exclusive `tryLock`, 2 s). Readers
//!   take it when it exists, and otherwise re-check after an unlocked read.
//! - **Append:** one positional write at the last line boundary, then fsync.
//!   The first record also writes the coverage line.
//! - **Torn tail:** a file not ending in `\n` is repaired by the next writer
//!   (temp + fsync + rename + directory fsync) with an `incomplete`
//!   incident. Readers return `UsageStoreIncomplete` and repair nothing.
//! - **Dedupe:** at most two variants per generation id and per pending id:
//!   equal is `duplicate`, a second variant is a written `conflict`, a third
//!   is an unwritten `conflict`. Incidents dedupe on time and completeness.
//! - **Retention:** 35 days, with fx's compaction triggers and limits.
//!
//! Two behaviors differ on purpose:
//!
//! - A new incident while the file holds 4096 returns
//!   `error.UsageIncidentCapacity` instead of a silent `duplicate`.
//! - `read` caches the parsed ledger by file size, mtime, and inode, so
//!   repeated views of an unchanged file don't re-parse it.
//!
//! A `Store` is not thread-safe: its owner serializes calls. `abandon` may be
//! called from any thread, and a `View` may be released from any thread.

const std = @import("std");
const record = @import("../codec/record.zig");
const durable = @import("durable.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const GenerationFact = record.GenerationFact;
pub const PendingMarker = record.PendingMarker;
pub const Incident = record.Incident;
pub const Probe = durable.Probe;
pub const Point = durable.Point;
/// Usage recovery markers (`usage-recovery/`, `usage-recovery-v2/`).
pub const markers = @import("markers.zig");

pub const profile_dir_name = ".fx";
pub const usage_file_name = "usage.jsonl";
pub const lock_file_name = "usage.lock";
pub const lock_deadline_ms: u64 = 2000;
pub const max_file_bytes: usize = 32 * 1024 * 1024;
pub const max_record_bytes = record.max_record_bytes;
pub const max_records = record.max_records;
pub const compaction_threshold_bytes: u64 = 8 * 1024 * 1024;
pub const retention_ms: i64 = std.time.ms_per_day * 35;
pub const compaction_slack_ms: i64 = std.time.ms_per_day;
pub const max_file_incidents: usize = 4096;
const tail_sample_bytes: usize = 32;
const abandon_check_lines: usize = 256;
/// Bytes a ledger read takes between checks of the abandon flag, so process
/// exit never waits for a whole large file to be read.
const abandon_check_bytes: usize = 1024 * 1024;

pub const Mode = enum { read_only, read_write };

/// The answer to an append, as older fx binaries also answer it.
pub const Outcome = enum { appended, duplicate, conflict };

pub const Event = union(enum) {
    generation: GenerationFact,
    pending: PendingMarker,
    incident: Incident,

    fn timestamp(event: Event) i64 {
        return switch (event) {
            .generation => |fact| fact.created_at_ms,
            .pending => |marker| marker.observed_at_ms,
            .incident => |incident| incident.occurred_at_ms,
        };
    }

    fn asRecord(event: Event) record.Record {
        return switch (event) {
            .generation => |fact| .{ .generation = fact },
            .pending => |marker| .{ .pending = marker },
            .incident => |incident| .{ .incident = incident },
        };
    }
};

/// The parsed ledger, as fx's `Loaded`: up to two variants per id in file
/// order, and every incident, including the one fx synthesizes for each
/// second pending variant. Borrowed from a `View`.
pub const Ledger = struct {
    coverage_started_at_ms: ?i64 = null,
    facts: []const GenerationFact = &.{},
    pending: []const PendingMarker = &.{},
    incidents: []const Incident = &.{},
    record_count: usize = 0,
};

// ---------------------------------------------------------------------------
// Index: one parse of whole ledger lines

/// Copies the strings of a record parsed into scratch memory.
const Variants = struct {
    first: usize,
    second: ?usize = null,
};

const Index = struct {
    coverage: ?i64 = null,
    facts: std.ArrayList(GenerationFact) = .empty,
    pending: std.ArrayList(PendingMarker) = .empty,
    incidents: std.ArrayList(Incident) = .empty,
    /// Keys borrow the ids owned by `facts` and `pending`.
    fact_variants: std.StringHashMapUnmanaged(Variants) = .empty,
    pending_variants: std.StringHashMapUnmanaged(Variants) = .empty,
    record_count: usize = 0,
    /// Offset just past the last absorbed byte, always a line start.
    boundary: u64 = 0,
    tail: [tail_sample_bytes]u8 = undefined,
    tail_len: usize = 0,
    /// The parsed file's inode. A replace by any process changes it, which
    /// the length and tail sample alone can miss.
    inode: ?File.INode = null,

    fn deinit(index: *Index, gpa: Allocator) void {
        for (index.facts.items) |*fact| fact.deinit(gpa);
        index.facts.deinit(gpa);
        for (index.pending.items) |*marker| marker.deinit(gpa);
        index.pending.deinit(gpa);
        index.incidents.deinit(gpa);
        index.fact_variants.deinit(gpa);
        index.pending_variants.deinit(gpa);
        index.* = undefined;
    }

    fn ledger(index: *const Index) Ledger {
        return .{
            .coverage_started_at_ms = index.coverage,
            .facts = index.facts.items,
            .pending = index.pending.items,
            .incidents = index.incidents.items,
            .record_count = index.record_count,
        };
    }

    fn captureTail(index: *Index, bytes: []const u8) void {
        const n = @min(tail_sample_bytes, bytes.len);
        @memcpy(index.tail[0..n], bytes[bytes.len - n ..]);
        index.tail_len = n;
    }

    /// fx's `absorbRecord`. Takes ownership of `parsed` in every case.
    fn absorb(index: *Index, gpa: Allocator, parsed: record.Record) !void {
        var owned = parsed;
        switch (owned) {
            .coverage => |started_at_ms| {
                if (index.coverage) |existing| {
                    if (existing != started_at_ms) return error.InvalidUsageStore;
                } else index.coverage = started_at_ms;
            },
            .incident => |incident| try index.incidents.append(gpa, incident),
            .generation => |*fact| {
                errdefer fact.deinit(gpa);
                if (index.coverage == null) return error.InvalidUsageStore;
                if (index.fact_variants.getPtr(fact.id)) |variants| {
                    const known = GenerationFact.eql(index.facts.items[variants.first], fact.*) or
                        (variants.second != null and GenerationFact.eql(index.facts.items[variants.second.?], fact.*));
                    if (known or variants.second != null) {
                        fact.deinit(gpa);
                        return;
                    }
                    try index.facts.append(gpa, fact.*);
                    variants.second = index.facts.items.len - 1;
                } else {
                    try index.facts.ensureUnusedCapacity(gpa, 1);
                    try index.fact_variants.put(gpa, fact.id, .{ .first = index.facts.items.len });
                    index.facts.appendAssumeCapacity(fact.*);
                }
            },
            .pending => |*marker| {
                errdefer marker.deinit(gpa);
                if (index.coverage == null) return error.InvalidUsageStore;
                if (index.pending_variants.getPtr(marker.id)) |variants| {
                    const known = PendingMarker.eql(index.pending.items[variants.first], marker.*) or
                        (variants.second != null and PendingMarker.eql(index.pending.items[variants.second.?], marker.*));
                    if (known or variants.second != null) {
                        marker.deinit(gpa);
                        return;
                    }
                    try index.pending.ensureUnusedCapacity(gpa, 1);
                    try index.incidents.ensureUnusedCapacity(gpa, 1);
                    index.pending.appendAssumeCapacity(marker.*);
                    variants.second = index.pending.items.len - 1;
                    index.incidents.appendAssumeCapacity(.{ .occurred_at_ms = marker.observed_at_ms, .completeness = .incomplete });
                } else {
                    try index.pending.ensureUnusedCapacity(gpa, 1);
                    try index.pending_variants.put(gpa, marker.id, .{ .first = index.pending.items.len });
                    index.pending.appendAssumeCapacity(marker.*);
                }
            },
        }
    }

    /// fx's `absorbBytes`: whole lines, blank lines skipped, the record and
    /// line limits checked before each parse.
    /// A line as fx writes it is read in place; any other line parses into a
    /// scratch arena. Only the strings a kept record needs are copied into
    /// `gpa`.
    fn absorbBytes(index: *Index, gpa: Allocator, bytes: []const u8, abandoned: ?*const std.atomic.Value(bool)) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var parsed: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (abandoned) |flag| {
                if (parsed % abandon_check_lines == 0 and flag.load(.acquire)) return error.UsageLockAbandoned;
            }
            parsed += 1;
            index.record_count += 1;
            if (index.record_count > max_records or line.len > max_record_bytes) return error.UsageCapacityExceeded;
            const borrowed = record.parseCanonical(line) orelse blk: {
                _ = scratch.reset(.retain_capacity);
                break :blk try record.parseRecord(scratch.allocator(), line);
            };
            try index.absorb(gpa, try record.ownedCopy(gpa, borrowed));
        }
    }

    fn incidentKnown(index: *const Index, incident: Incident) bool {
        for (index.incidents.items) |existing| {
            if (existing.occurred_at_ms == incident.occurred_at_ms and existing.completeness == incident.completeness) return true;
        }
        return false;
    }

    fn pendingResolved(index: *const Index, id: []const u8) bool {
        return index.fact_variants.contains(id);
    }
};

// ---------------------------------------------------------------------------
// Classification, retention, and compaction rules (fx, unchanged)

const Decision = struct {
    outcome: Outcome,
    write: bool,
    /// A new incident refused because the file holds `max_file_incidents`.
    capped: bool = false,
};

fn classify(index: *const Index, event: Event) Decision {
    switch (event) {
        .generation => |fact| {
            const variants = index.fact_variants.get(fact.id) orelse return .{ .outcome = .appended, .write = true };
            if (GenerationFact.eql(index.facts.items[variants.first], fact)) return .{ .outcome = .duplicate, .write = false };
            if (variants.second) |second| {
                if (GenerationFact.eql(index.facts.items[second], fact)) return .{ .outcome = .duplicate, .write = false };
                return .{ .outcome = .conflict, .write = false };
            }
            return .{ .outcome = .conflict, .write = true };
        },
        .pending => |marker| {
            const variants = index.pending_variants.get(marker.id) orelse return .{ .outcome = .appended, .write = true };
            if (PendingMarker.eql(index.pending.items[variants.first], marker)) return .{ .outcome = .duplicate, .write = false };
            if (variants.second) |second| {
                if (PendingMarker.eql(index.pending.items[second], marker)) return .{ .outcome = .duplicate, .write = false };
                return .{ .outcome = .conflict, .write = false };
            }
            return .{ .outcome = .conflict, .write = true };
        },
        .incident => |incident| {
            // fx checks the cap before dedupe, so a known incident at the cap
            // is refused too; it is already durable, so it reads as duplicate.
            if (index.incidentKnown(incident)) return .{ .outcome = .duplicate, .write = false };
            if (index.incidents.items.len >= max_file_incidents) return .{ .outcome = .duplicate, .write = false, .capped = true };
            return .{ .outcome = .appended, .write = true };
        },
    }
}

fn retentionCutoff(now_ms: i64) i64 {
    return std.math.sub(i64, now_ms, retention_ms) catch 0;
}

fn hasExpiredRecords(index: *const Index, now_ms: i64) bool {
    const cutoff = retentionCutoff(now_ms);
    for (index.facts.items) |fact| if (fact.created_at_ms < cutoff) return true;
    for (index.pending.items) |marker| {
        if (marker.observed_at_ms < cutoff or index.pendingResolved(marker.id)) return true;
    }
    for (index.incidents.items) |incident| if (incident.occurred_at_ms < cutoff) return true;
    return false;
}

/// Age-only expiry for the after-append check, with one day of slack so
/// steady appends don't rewrite the file each time.
fn hasAgedRecords(index: *const Index, now_ms: i64) bool {
    const cutoff = std.math.sub(i64, retentionCutoff(now_ms), compaction_slack_ms) catch 0;
    for (index.facts.items) |fact| if (fact.created_at_ms < cutoff) return true;
    for (index.pending.items) |marker| if (marker.observed_at_ms < cutoff) return true;
    for (index.incidents.items) |incident| if (incident.occurred_at_ms < cutoff) return true;
    return false;
}

fn checkedRecordCount(current: usize, additional: usize) error{UsageCapacityExceeded}!usize {
    const next = std.math.add(usize, current, additional) catch return error.UsageCapacityExceeded;
    if (next > max_records) return error.UsageCapacityExceeded;
    return next;
}

fn retainedRecordCount(index: *const Index, now_ms: i64) usize {
    const cutoff = retentionCutoff(now_ms);
    var count: usize = @intFromBool(index.coverage != null);
    for (index.facts.items) |fact| count += @intFromBool(fact.created_at_ms >= cutoff);
    for (index.pending.items) |marker| {
        count += @intFromBool(marker.observed_at_ms >= cutoff and !index.pendingResolved(marker.id));
    }
    for (index.incidents.items) |incident| count += @intFromBool(incident.occurred_at_ms >= cutoff);
    return count;
}

fn shouldCompactBeforeAppend(next_length: u64, record_count: usize, append_records: usize, index: *const Index, now_ms: i64) bool {
    const over = next_length > max_file_bytes or std.meta.isError(checkedRecordCount(record_count, append_records));
    return over and hasExpiredRecords(index, now_ms);
}

fn shouldCompactAfterAppend(next_length: u64, index: *const Index, appended_at_ms: i64, now_ms: i64) bool {
    return next_length > compaction_threshold_bytes and
        (hasAgedRecords(index, now_ms) or appended_at_ms < retentionCutoff(now_ms));
}

/// Coverage, then retained facts, unresolved pending markers, and incidents,
/// each in index order (fx's `writeRetainedRecords`).
fn writeRetained(writer: *std.Io.Writer, index: *const Index, now_ms: i64) !void {
    const cutoff = retentionCutoff(now_ms);
    if (index.coverage) |started| try record.writeRecord(writer, .{ .coverage = started });
    for (index.facts.items) |fact| {
        if (fact.created_at_ms >= cutoff) try record.writeRecord(writer, .{ .generation = fact });
    }
    for (index.pending.items) |marker| {
        if (marker.observed_at_ms >= cutoff and !index.pendingResolved(marker.id)) {
            try record.writeRecord(writer, .{ .pending = marker });
        }
    }
    for (index.incidents.items) |incident| {
        if (incident.occurred_at_ms >= cutoff) try record.writeRecord(writer, .{ .incident = incident });
    }
}

const Tail = struct { length: u64, torn: bool };

/// fx's `inspectTail`: the offset just past the last `\n`, and whether bytes
/// follow it.
fn inspectTail(io: Io, file: File) !Tail {
    const length = try file.length(io);
    if (length == 0) return .{ .length = 0, .torn = false };
    var last: [1]u8 = undefined;
    if (try file.readPositionalAll(io, &last, length - 1) == 1 and last[0] == '\n') {
        return .{ .length = length, .torn = false };
    }
    var cursor = length;
    var buffer: [8192]u8 = undefined;
    while (cursor > 0) {
        const start = cursor - @min(cursor, buffer.len);
        const len: usize = @intCast(cursor - start);
        if (try file.readPositionalAll(io, buffer[0..len], start) != len) return error.UsageWriteFailed;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..len], '\n')) |newline| {
            return .{ .length = start + newline + 1, .torn = true };
        }
        cursor = start;
    }
    return .{ .length = 0, .torn = true };
}

fn readExact(io: Io, file: File, buffer: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, buffer, offset) != buffer.len) return error.UsageReadFailed;
}

/// `readExact` in `abandon_check_bytes` pieces, stopping with
/// `error.UsageLockAbandoned` once `abandoned` is set.
fn readExactUnlessAbandoned(io: Io, file: File, buffer: []u8, offset: u64, abandoned: *const std.atomic.Value(bool)) !void {
    var done: usize = 0;
    while (done < buffer.len) {
        if (abandoned.load(.acquire)) return error.UsageLockAbandoned;
        const end = @min(buffer.len, done + abandon_check_bytes);
        try readExact(io, file, buffer[done..end], offset + done);
        done = end;
    }
}

// ---------------------------------------------------------------------------
// Read cache

/// Identifies one version of `usage.jsonl`. Appends change size and mtime; a
/// replace (repair or compaction) changes the inode.
const Key = struct {
    size: u64,
    mtime_ns: i96,
    inode: File.INode,

    fn of(stat: File.Stat) Key {
        return .{ .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .inode = stat.inode };
    }

    fn eql(a: Key, b: Key) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and a.inode == b.inode;
    }
};

const Shared = struct {
    gpa: Allocator,
    index: Index,
    key: Key,
    refs: std.atomic.Value(u32),

    fn retain(shared: *Shared) void {
        _ = shared.refs.fetchAdd(1, .monotonic);
    }

    fn release(shared: *Shared) void {
        if (shared.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = shared.gpa;
        shared.index.deinit(gpa);
        gpa.destroy(shared);
    }
};

/// One immutable parse of the ledger. Release it with `release`, from any
/// thread; the store's allocator must then be thread-safe.
pub const View = struct {
    shared: ?*Shared = null,

    pub fn ledger(view: View) Ledger {
        const shared = view.shared orelse return .{};
        return shared.index.ledger();
    }

    pub fn release(view: *View) void {
        if (view.shared) |shared| shared.release();
        view.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Store

pub const Options = struct {
    /// The directory that holds `.fx` (the user's HOME). Borrowed; open it
    /// with `.iterate = true` so creating `.fx` can fsync it on Linux.
    home: Dir,
    mode: Mode,
    lock_deadline_ms: u64 = lock_deadline_ms,
    probe: Probe = .{},
};

pub const Stats = struct {
    /// Full parses of the file, by `read` and by the writer index.
    full_parses: usize = 0,
    /// Writer index extensions that read only bytes another process appended.
    incremental_absorbs: usize = 0,
    /// `read` calls answered from the cache.
    cache_hits: usize = 0,
};

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    options: Options,
    /// `~/.fx`, opened on first use.
    profile: ?Dir = null,
    /// Resident parse kept across appends; touched only under the lock.
    index: ?Index = null,
    cache: ?*Shared = null,
    abandoned: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},

    /// Does no I/O.
    pub fn init(gpa: Allocator, io: Io, options: Options) Store {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    pub fn deinit(store: *Store) void {
        store.dropIndex();
        if (store.cache) |shared| shared.release();
        if (store.profile) |dir| dir.close(store.io);
        store.* = undefined;
    }

    /// Ends a lock wait or a parse in progress and refuses later locks, so
    /// process exit never waits on another process (fx's `abandonLock`).
    /// Unpublished usage stays with its session and recovery marker.
    pub fn abandon(store: *Store) void {
        store.abandoned.store(true, .release);
    }

    fn dropIndex(store: *Store) void {
        if (store.index) |*index| index.deinit(store.gpa);
        store.index = null;
    }

    // -- profile directory ---------------------------------------------------

    /// fx's `openExistingDurableHome` plus `validateReadable`. Never creates.
    fn existingProfile(store: *Store) !?Dir {
        if (store.profile == null) {
            store.profile = try durable.openDirNoFollow(store.io, store.options.home, profile_dir_name);
        }
        const dir = store.profile orelse return null;
        try durable.checkPrivateDir(try dir.stat(store.io));
        return dir;
    }

    /// fx's `ensureWritable`: creates `.fx` if needed and repairs it to 0700.
    fn writableProfile(store: *Store) !Dir {
        if (store.profile == null) {
            store.profile = durable.openOrCreatePrivateDir(store.io, store.options.home, profile_dir_name) catch |err| switch (err) {
                error.PrivateStatePermissionsUnsupported, error.DurablePathUnsafe => return err,
                else => return error.DurableLayoutFailed,
            };
        }
        const dir = store.profile.?;
        dir.setPermissions(store.io, File.Permissions.fromMode(durable.dir_mode)) catch return error.PrivateStatePermissionsUnsupported;
        try durable.checkPrivateDir(try dir.stat(store.io));
        return dir;
    }

    fn lockError(err: anyerror) anyerror {
        return switch (err) {
            error.LockBusy => error.UsageLockBusy,
            error.LockUnsupported => error.UsageLockUnsupported,
            error.LockAbandoned => error.UsageLockAbandoned,
            else => err,
        };
    }

    /// fx's `openUsage`: the ledger file, created (exclusive, 0600, with a
    /// directory fsync) only when `create` is set. Writable opens repair the
    /// mode; every open requires 0600.
    fn openUsage(store: *Store, dir: Dir, mode: Dir.OpenFileOptions.Mode, create: bool) !?File {
        const io = store.io;
        var created = false;
        const file = (try durable.openRegularFile(io, dir, usage_file_name, mode)) orelse created: {
            if (!create) return null;
            const new_file = dir.createFile(io, usage_file_name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = File.Permissions.fromMode(durable.file_mode),
                .resolve_beneath = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => return store.openUsage(dir, mode, false),
                else => return err,
            };
            created = true;
            break :created new_file;
        };
        errdefer file.close(io);
        if (mode != .read_only) {
            file.setPermissions(io, File.Permissions.fromMode(durable.file_mode)) catch return error.PrivateStatePermissionsUnsupported;
        }
        const stat = try file.stat(io);
        try durable.checkRegular(stat, mode);
        if (durable.modeOf(stat.permissions) != durable.file_mode) return error.PrivateStatePermissionsUnsupported;
        if (created) durable.syncDir(dir) catch return error.DurableLayoutFailed;
        return file;
    }

    // -- read ------------------------------------------------------------------

    /// The current ledger. Never creates or changes anything. Answers from
    /// the cache while the file's size, mtime, and inode are unchanged, even
    /// while another process holds the lock: an unchanged file is a
    /// committed state. Otherwise reads under fx's reader protocol.
    pub fn read(store: *Store) !View {
        const io = store.io;
        const dir = (try store.existingProfile()) orelse return .{};
        if (store.cache) |cached| {
            if (try store.currentKey(dir)) |key| {
                if (key.eql(cached.key)) {
                    cached.retain();
                    store.stats.cache_hits += 1;
                    return .{ .shared = cached };
                }
            }
        }
        while (true) {
            const held = durable.acquireLock(io, dir, lock_file_name, .{
                .deadline_ms = store.options.lock_deadline_ms,
                .abandoned = &store.abandoned,
                .create = false,
            }) catch |err| return lockError(err);
            if (held) |lock| {
                var locked = lock;
                defer locked.release(io);
                return store.readFile(dir);
            }
            var view = try store.readFile(dir);
            if (!try durable.lockFileExists(io, dir, lock_file_name)) return view;
            view.release();
        }
    }

    /// The key of the file as it is now, or null when there is no file.
    fn currentKey(store: *Store, dir: Dir) !?Key {
        const stat = dir.statFile(store.io, usage_file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        try durable.checkRegular(stat, .read_only);
        if (durable.modeOf(stat.permissions) != durable.file_mode) return error.PrivateStatePermissionsUnsupported;
        return Key.of(stat);
    }

    fn readFile(store: *Store, dir: Dir) !View {
        const io = store.io;
        const file = (try store.openUsage(dir, .read_only, false)) orelse return .{};
        defer file.close(io);
        const key = Key.of(try file.stat(io));
        if (store.cache) |cached| {
            if (key.eql(cached.key)) {
                cached.retain();
                store.stats.cache_hits += 1;
                return .{ .shared = cached };
            }
        }
        if (key.size > max_file_bytes) return error.UsageCapacityExceeded;

        const shared = try store.gpa.create(Shared);
        errdefer store.gpa.destroy(shared);
        shared.* = .{ .gpa = store.gpa, .index = .{}, .key = key, .refs = .init(1) };
        errdefer shared.index.deinit(store.gpa);
        if (key.size > 0) {
            const bytes = try store.gpa.alloc(u8, @intCast(key.size));
            defer store.gpa.free(bytes);
            try readExact(io, file, bytes, 0);
            if (bytes[bytes.len - 1] != '\n') return error.UsageStoreIncomplete;
            try shared.index.absorbBytes(store.gpa, bytes, null);
        }
        store.stats.full_parses += 1;
        if (store.cache) |old| old.release();
        shared.retain();
        store.cache = shared;
        return .{ .shared = shared };
    }

    // -- append ------------------------------------------------------------------

    /// Appends one record and answers like fx: `appended`, `duplicate` (an
    /// equal record is already durable, nothing written), or `conflict`.
    /// `now_ms` stamps the coverage line and a torn-tail incident, and sets
    /// the retention cutoff. Returns `UsageIncidentCapacity` for a new
    /// incident the full file cannot take: it is not durable.
    pub fn append(store: *Store, event: Event, now_ms: i64) !Outcome {
        if (store.options.mode == .read_only) return error.UsageStoreReadOnly;
        // Every `std.Io.Writer` here is an allocating writer, so a failed
        // write is a failed allocation.
        return store.appendLocked(event, @max(now_ms, 0)) catch |err| switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    }

    fn appendLocked(store: *Store, event: Event, now_ms: i64) !Outcome {
        const io = store.io;
        const gpa = store.gpa;
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        try record.writeRecord(&line.writer, event.asRecord());
        if (line.written().len > max_record_bytes) return error.UsageRecordTooLarge;

        const dir = try store.writableProfile();
        var lock = (durable.acquireLock(io, dir, lock_file_name, .{
            .deadline_ms = store.options.lock_deadline_ms,
            .abandoned = &store.abandoned,
            .create = true,
        }) catch |err| return lockError(err)).?;
        defer lock.release(io);
        store.options.probe.at(.lock_acquired);

        var file: ?File = (try store.openUsage(dir, .read_write, true)).?;
        defer if (file) |open| open.close(io);
        const tail = try inspectTail(io, file.?);
        var boundary = tail.length;
        const index = try store.ensureIndex(file.?, boundary);
        const decision = classify(index, event);

        var pending_bytes: std.Io.Writer.Allocating = .init(gpa);
        defer pending_bytes.deinit();
        const out = &pending_bytes.writer;
        var append_records: usize = 0;
        if (index.coverage == null) {
            try record.writeRecord(out, .{ .coverage = now_ms });
            append_records += 1;
        }
        if (tail.torn) {
            try record.writeRecord(out, .{ .incident = .{ .occurred_at_ms = now_ms, .completeness = .incomplete } });
            append_records += 1;
        }
        if (decision.write) {
            try out.writeAll(line.written());
            append_records += 1;
        }
        const bytes = pending_bytes.written();
        if (bytes.len == 0) return finish(decision);

        var next_length = std.math.add(u64, boundary, bytes.len) catch return error.UsageCapacityExceeded;
        var inode: ?File.INode = (try file.?.stat(io)).inode;
        var compacted_before = false;
        var committed = false;
        var base_records = index.record_count;
        if (shouldCompactBeforeAppend(next_length, base_records, append_records, index, now_ms)) {
            compacted_before = true;
            base_records = retainedRecordCount(index, now_ms);
            if (tail.torn) {
                var replacement: std.Io.Writer.Allocating = .init(gpa);
                defer replacement.deinit();
                try writeRetained(&replacement.writer, index, now_ms);
                try replacement.writer.writeAll(bytes);
                next_length = replacement.written().len;
                if (next_length > max_file_bytes) return error.UsageCapacityExceeded;
                _ = try checkedRecordCount(base_records, append_records);
                try store.replaceLocked(dir, replacement.written());
                file.?.close(io);
                file = null;
                committed = true;
            } else {
                file.?.close(io);
                file = null;
                try store.compactLocked(dir, now_ms);
                file = (try store.openUsage(dir, .read_write, false)) orelse return error.UsageReadFailed;
                boundary = try file.?.length(io);
                next_length = std.math.add(u64, boundary, bytes.len) catch return error.UsageCapacityExceeded;
            }
        }
        if (next_length > max_file_bytes) return error.UsageCapacityExceeded;
        _ = try checkedRecordCount(base_records, append_records);
        if (!committed) {
            if (tail.torn) {
                var replacement: std.Io.Writer.Allocating = .init(gpa);
                defer replacement.deinit();
                const prefix = try replacement.writer.writableSliceGreedy(@intCast(boundary));
                try readExact(io, file.?, prefix[0..@intCast(boundary)], 0);
                replacement.writer.advance(@intCast(boundary));
                try replacement.writer.writeAll(bytes);
                try store.replaceLocked(dir, replacement.written());
                file.?.close(io);
                file = null;
                inode = if (dir.statFile(io, usage_file_name, .{ .follow_symlinks = false })) |stat| stat.inode else |_| null;
            } else {
                try store.writeAt(file.?, bytes, boundary);
                file.?.sync(io) catch return error.UsageWriteFailed;
                store.options.probe.at(.append_synced);
            }
        }

        // Read the trigger before the index is replaced or extended.
        const compact_after = !compacted_before and store.index != null and
            shouldCompactAfterAppend(next_length, &store.index.?, event.timestamp(), now_ms);
        store.noteAppended(bytes, next_length, compacted_before, inode);
        if (compact_after and !store.abandoned.load(.acquire)) {
            if (file) |open| open.close(io);
            file = null;
            try store.compactLocked(dir, now_ms);
            store.dropIndex();
        }
        return finish(decision);
    }

    fn finish(decision: Decision) !Outcome {
        if (decision.capped) return error.UsageIncidentCapacity;
        return decision.outcome;
    }

    fn writeAt(store: *Store, file: File, bytes: []const u8, offset: u64) !void {
        const io = store.io;
        if (store.options.probe.active() and bytes.len > 1) {
            const half = bytes.len / 2;
            try file.writePositionalAll(io, bytes[0..half], offset);
            store.options.probe.at(.append_partial);
            try file.writePositionalAll(io, bytes[half..], offset + half);
        } else {
            try file.writePositionalAll(io, bytes, offset);
        }
        store.options.probe.at(.append_written);
    }

    /// fx's `ensureIndex`: reuse the resident parse when the file still ends
    /// where it did, extend it when another process only appended, and
    /// otherwise parse `[0, boundary)` again.
    fn ensureIndex(store: *Store, file: File, boundary: u64) !*Index {
        const inode = (try file.stat(store.io)).inode;
        if (store.index) |*index| {
            if (index.inode != inode) store.dropIndex();
        }
        if (store.index) |*index| {
            if (boundary == index.boundary and store.tailMatches(index, file)) return index;
            if (boundary > index.boundary and store.absorbTail(index, file, boundary)) return index;
            if (store.abandoned.load(.acquire)) return error.UsageLockAbandoned;
            store.dropIndex();
        }
        if (boundary > max_file_bytes) return error.UsageCapacityExceeded;
        // An abandoned store is exiting with its process. Freeing a large
        // ledger's buffer and partial index would take longer than the rest
        // of exit, so an abandoned read leaves both to the process exit.
        var fresh: Index = .{};
        errdefer if (!store.abandoned.load(.acquire)) fresh.deinit(store.gpa);
        if (boundary > 0) {
            const bytes = try store.gpa.alloc(u8, @intCast(boundary));
            defer if (!store.abandoned.load(.acquire)) store.gpa.free(bytes);
            try readExactUnlessAbandoned(store.io, file, bytes, 0, &store.abandoned);
            if (bytes[bytes.len - 1] != '\n') return error.UsageStoreIncomplete;
            try fresh.absorbBytes(store.gpa, bytes, &store.abandoned);
            fresh.boundary = boundary;
            fresh.captureTail(bytes);
        }
        fresh.inode = inode;
        store.stats.full_parses += 1;
        store.index = fresh;
        return &store.index.?;
    }

    fn tailMatches(store: *Store, index: *const Index, file: File) bool {
        if (index.tail_len == 0) return false;
        var buffer: [tail_sample_bytes]u8 = undefined;
        const sample = buffer[0..index.tail_len];
        readExact(store.io, file, sample, index.boundary - index.tail_len) catch return false;
        return std.mem.eql(u8, sample, index.tail[0..index.tail_len]);
    }

    fn absorbTail(store: *Store, index: *Index, file: File, boundary: u64) bool {
        if (boundary - index.boundary > max_file_bytes) return false;
        if (!store.tailMatches(index, file)) return false;
        const bytes = store.gpa.alloc(u8, @intCast(boundary - index.boundary)) catch return false;
        defer store.gpa.free(bytes);
        readExactUnlessAbandoned(store.io, file, bytes, index.boundary, &store.abandoned) catch return false;
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return false;
        index.absorbBytes(store.gpa, bytes, &store.abandoned) catch return false;
        index.boundary = boundary;
        index.captureTail(bytes);
        store.stats.incremental_absorbs += 1;
        return true;
    }

    /// After a committed append the index absorbs the lines it wrote; a
    /// compaction replaced the content, so the index is dropped instead.
    fn noteAppended(store: *Store, written: []const u8, final_length: u64, replaced: bool, inode: ?File.INode) void {
        if (replaced or inode == null) return store.dropIndex();
        const index = &(store.index orelse return);
        index.absorbBytes(store.gpa, written, null) catch return store.dropIndex();
        index.boundary = final_length;
        index.captureTail(written);
        index.inode = inode;
    }

    fn compactLocked(store: *Store, dir: Dir, now_ms: i64) !void {
        const file = (try store.openUsage(dir, .read_only, false)) orelse return;
        defer file.close(store.io);
        const index = try store.ensureIndex(file, try file.length(store.io));
        var replacement: std.Io.Writer.Allocating = .init(store.gpa);
        defer replacement.deinit();
        try writeRetained(&replacement.writer, index, now_ms);
        try store.replaceLocked(dir, replacement.written());
    }

    fn replaceLocked(store: *Store, dir: Dir, contents: []const u8) !void {
        durable.replace(store.io, dir, usage_file_name, contents, .{ .probe = store.options.probe }) catch |err| switch (err) {
            error.DurableReplacePostRenameFailed => return error.UsageCommitIndeterminate,
            error.DurableReplacePreRenameFailed => return error.UsageWriteFailed,
            else => |e| return e,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test {
    _ = durable;
    _ = markers;
}

const now_fixed: i64 = 1_800_000_000_000;

const Home = struct {
    tmp: testing.TmpDir,

    fn init() Home {
        return .{ .tmp = testing.tmpDir(.{ .iterate = true }) };
    }

    fn deinit(home: *Home) void {
        home.tmp.cleanup();
    }

    fn store(home: *Home, mode: Mode) Store {
        return Store.init(testing.allocator, testing.io, .{ .home = home.tmp.dir, .mode = mode });
    }

    fn profile(home: *Home) !Dir {
        return home.tmp.dir.openDir(testing.io, profile_dir_name, .{ .iterate = true });
    }

    fn ledgerBytes(home: *Home) ![]u8 {
        var dir = try home.profile();
        defer dir.close(testing.io);
        return dir.readFileAlloc(testing.io, usage_file_name, testing.allocator, .limited(max_file_bytes + 1));
    }

    fn appendRaw(home: *Home, bytes: []const u8) !void {
        var dir = try home.profile();
        defer dir.close(testing.io);
        var file = try dir.openFile(testing.io, usage_file_name, .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, bytes, try file.length(testing.io));
    }

    /// Writes `bytes` as a private ledger, creating a private `.fx`.
    fn seed(home: *Home, bytes: []const u8) !void {
        var dir = try durable.openOrCreatePrivateDir(testing.io, home.tmp.dir, profile_dir_name);
        defer dir.close(testing.io);
        try dir.writeFile(testing.io, .{ .sub_path = usage_file_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    }

    fn exists(home: *Home, name: []const u8) bool {
        _ = home.tmp.dir.statFile(testing.io, name, .{ .follow_symlinks = false }) catch return false;
        return true;
    }
};

fn testId(comptime n: u8) []const u8 {
    return "gen_01ARZ3NDEKTSV4RRFFQ69G5FA" ++ [_]u8{"0123456789ABCDEFGHJKMNPQRSTVWXYZ"[n]};
}

fn testFact(id: []const u8, created_at_ms: i64, input: u64) GenerationFact {
    return .{
        .id = id,
        .created_at_ms = created_at_ms,
        .model = "provider/model",
        .input_tokens = input,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .total_cost = 0.25,
    };
}

fn readLedger(store: *Store) !struct { view: View, ledger: Ledger } {
    const view = try store.read();
    return .{ .view = view, .ledger = view.ledger() };
}

fn lineFor(alloc: Allocator, rec: record.Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try record.writeRecord(&out.writer, rec);
    return out.toOwnedSlice();
}

test "contract constants are fx's" {
    try testing.expectEqual(@as(u64, 2000), lock_deadline_ms);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), max_file_bytes);
    try testing.expectEqual(@as(usize, 16 * 1024), max_record_bytes);
    try testing.expectEqual(@as(usize, 200_000), max_records);
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), compaction_threshold_bytes);
    try testing.expectEqual(@as(i64, 35 * 86_400_000), retention_ms);
    try testing.expectEqual(@as(i64, 86_400_000), compaction_slack_ms);
    try testing.expectEqual(@as(usize, 4096), max_file_incidents);
    try testing.expectEqualStrings(".fx", profile_dir_name);
    try testing.expectEqualStrings("usage.jsonl", usage_file_name);
    try testing.expectEqualStrings("usage.lock", lock_file_name);
}

test "readers never create usage.lock or usage.jsonl" {
    var home = Home.init();
    defer home.deinit();
    var dir = try durable.openOrCreatePrivateDir(testing.io, home.tmp.dir, profile_dir_name);
    defer dir.close(testing.io);
    var store = home.store(.read_write);
    defer store.deinit();
    var view = try store.read();
    view.release();
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, lock_file_name, .{}));
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, usage_file_name, .{}));
}

test "read-only store never creates ~/.fx and refuses appends" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_only);
    defer store.deinit();
    var view = try store.read();
    defer view.release();
    try testing.expectEqual(@as(?i64, null), view.ledger().coverage_started_at_ms);
    try testing.expectError(error.UsageStoreReadOnly, store.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed));
    try testing.expect(!home.exists(profile_dir_name));
}

test "first append writes coverage then the fact; equal replay is duplicate and writes nothing" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    const fact = testFact(testId(1), 1000, 10);
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = fact }, now_fixed));
    const before = try home.ledgerBytes();
    defer testing.allocator.free(before);
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .generation = fact }, now_fixed + 5));
    const after = try home.ledgerBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    const coverage = try lineFor(testing.allocator, .{ .coverage = now_fixed });
    defer testing.allocator.free(coverage);
    const generation = try lineFor(testing.allocator, .{ .generation = fact });
    defer testing.allocator.free(generation);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ coverage, generation });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, after);
}

test "new profile is created 0700 with a 0600 ledger and lock" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    _ = try store.append(.{ .incident = .{ .occurred_at_ms = 5, .completeness = .pending } }, now_fixed);
    const io = testing.io;
    try testing.expectEqual(@as(u32, 0o700), durable.modeOf((try home.tmp.dir.statFile(io, profile_dir_name, .{})).permissions));
    var dir = try home.profile();
    defer dir.close(io);
    try testing.expectEqual(@as(u32, 0o600), durable.modeOf((try dir.statFile(io, usage_file_name, .{})).permissions));
    try testing.expectEqual(@as(u32, 0o600), durable.modeOf((try dir.statFile(io, lock_file_name, .{})).permissions));
}

test "writers repair a 0755 profile and a 0644 ledger; readers reject both" {
    const io = testing.io;
    var home = Home.init();
    defer home.deinit();
    try home.seed("");
    try home.tmp.dir.setFilePermissions(io, profile_dir_name, .fromMode(0o755), .{});
    var reader = home.store(.read_only);
    defer reader.deinit();
    try testing.expectError(error.PrivateStatePermissionsUnsupported, reader.read());

    var writer = home.store(.read_write);
    defer writer.deinit();
    _ = try writer.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    try testing.expectEqual(@as(u32, 0o700), durable.modeOf((try home.tmp.dir.statFile(io, profile_dir_name, .{})).permissions));
    // A writer that already holds the directory open repairs it on every append.
    try home.tmp.dir.setFilePermissions(io, profile_dir_name, .fromMode(0o755), .{});
    _ = try writer.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    try testing.expectEqual(@as(u32, 0o700), durable.modeOf((try home.tmp.dir.statFile(io, profile_dir_name, .{})).permissions));

    var dir = try home.profile();
    defer dir.close(io);
    try dir.setFilePermissions(io, usage_file_name, .fromMode(0o644), .{});
    try testing.expectError(error.PrivateStatePermissionsUnsupported, reader.read());
    _ = try writer.append(.{ .generation = testFact(testId(2), 2, 1) }, now_fixed);
    try testing.expectEqual(@as(u32, 0o600), durable.modeOf((try dir.statFile(io, usage_file_name, .{})).permissions));
    var view = try reader.read();
    defer view.release();
    try testing.expectEqual(@as(usize, 2), view.ledger().facts.len);
}

test "symlinked profile or ledger leaf is refused" {
    const io = testing.io;
    var home = Home.init();
    defer home.deinit();
    try home.tmp.dir.createDir(io, "elsewhere", .fromMode(0o700));
    try home.tmp.dir.symLink(io, "elsewhere", profile_dir_name, .{ .is_directory = true });
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectError(error.DurablePathUnsafe, store.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed));
    try testing.expectError(error.DurablePathUnsafe, store.read());

    var other = Home.init();
    defer other.deinit();
    try other.seed("");
    var dir = try other.profile();
    defer dir.close(io);
    try dir.deleteFile(io, usage_file_name);
    try dir.writeFile(io, .{ .sub_path = "real.jsonl", .data = "", .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.symLink(io, "real.jsonl", usage_file_name, .{});
    var leaf = other.store(.read_write);
    defer leaf.deinit();
    try testing.expectError(error.DurablePathUnsafe, leaf.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed));
    try testing.expectError(error.DurablePathUnsafe, leaf.read());
}

test "conflicts: second variant written, third refused unwritten, both variants read back" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    const id = testId(3);
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = testFact(id, 1, 10) }, now_fixed));
    try testing.expectEqual(Outcome.conflict, try store.append(.{ .generation = testFact(id, 1, 11) }, now_fixed));
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .generation = testFact(id, 1, 11) }, now_fixed));
    const before = try home.ledgerBytes();
    defer testing.allocator.free(before);
    const size_before = before.len;
    try testing.expectEqual(Outcome.conflict, try store.append(.{ .generation = testFact(id, 1, 12) }, now_fixed));
    const after = try home.ledgerBytes();
    defer testing.allocator.free(after);
    try testing.expectEqual(size_before, after.len);
    var fresh = home.store(.read_only);
    defer fresh.deinit();
    var view = try fresh.read();
    defer view.release();
    try testing.expectEqual(@as(usize, 2), view.ledger().facts.len);
}

test "pending markers: two variants, and the second synthesizes an incomplete incident" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    const id = testId(4);
    try testing.expectEqual(Outcome.appended, try store.append(.{ .pending = .{ .id = id, .observed_at_ms = 7 } }, now_fixed));
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .pending = .{ .id = id, .observed_at_ms = 7 } }, now_fixed));
    try testing.expectEqual(Outcome.conflict, try store.append(.{ .pending = .{ .id = id, .observed_at_ms = 8 } }, now_fixed));
    try testing.expectEqual(Outcome.conflict, try store.append(.{ .pending = .{ .id = id, .observed_at_ms = 9 } }, now_fixed));
    var view = try store.read();
    defer view.release();
    const ledger = view.ledger();
    try testing.expectEqual(@as(usize, 2), ledger.pending.len);
    try testing.expectEqual(@as(usize, 1), ledger.incidents.len);
    try testing.expectEqual(Incident{ .occurred_at_ms = 8, .completeness = .incomplete }, ledger.incidents[0]);
    // The synthesized incident dedupes a later identical publish.
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .incident = .{ .occurred_at_ms = 8, .completeness = .incomplete } }, now_fixed));
}

test "incidents dedupe on time and completeness" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectEqual(Outcome.appended, try store.append(.{ .incident = .{ .occurred_at_ms = 5, .completeness = .pending } }, now_fixed));
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .incident = .{ .occurred_at_ms = 5, .completeness = .pending } }, now_fixed));
    try testing.expectEqual(Outcome.appended, try store.append(.{ .incident = .{ .occurred_at_ms = 5, .completeness = .incomplete } }, now_fixed));
    try testing.expectEqual(Outcome.appended, try store.append(.{ .incident = .{ .occurred_at_ms = 6, .completeness = .pending } }, now_fixed));
}

test "incident cap: a new incident at 4096 is refused, not reported as accepted" {
    var home = Home.init();
    defer home.deinit();
    var seed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer seed.deinit();
    try record.writeRecord(&seed.writer, .{ .coverage = 1 });
    for (0..max_file_incidents) |i| {
        try record.writeRecord(&seed.writer, .{ .incident = .{ .occurred_at_ms = now_fixed - @as(i64, @intCast(i)), .completeness = .pending } });
    }
    try home.seed(seed.written());
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectError(error.UsageIncidentCapacity, store.append(.{ .incident = .{ .occurred_at_ms = now_fixed + 1, .completeness = .pending } }, now_fixed));
    // An incident the file already holds is durable, so it stays a duplicate.
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .incident = .{ .occurred_at_ms = now_fixed, .completeness = .pending } }, now_fixed));
    // Facts are unaffected by the incident cap.
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = testFact(testId(1), now_fixed, 1) }, now_fixed));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const fact_line = try lineFor(testing.allocator, .{ .generation = testFact(testId(1), now_fixed, 1) });
    defer testing.allocator.free(fact_line);
    try testing.expectEqual(seed.written().len + fact_line.len, bytes.len);
}

test "torn tail: readers fail, the next writer repairs with an incident" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    _ = try store.append(.{ .generation = testFact(testId(1), 1000, 10) }, now_fixed);
    try home.appendRaw("{\"schema_version\":1");
    var reader = home.store(.read_only);
    defer reader.deinit();
    try testing.expectError(error.UsageStoreIncomplete, reader.read());

    var dir = try home.profile();
    defer dir.close(testing.io);
    const inode_before = (try dir.statFile(testing.io, usage_file_name, .{})).inode;
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = testFact(testId(2), 2000, 20) }, now_fixed + 9));
    var view = try reader.read();
    defer view.release();
    const ledger = view.ledger();
    try testing.expectEqual(@as(usize, 2), ledger.facts.len);
    try testing.expectEqual(@as(usize, 1), ledger.incidents.len);
    try testing.expectEqual(Incident{ .occurred_at_ms = now_fixed + 9, .completeness = .incomplete }, ledger.incidents[0]);
    // The repair replaced the file rather than appending in place.
    const inode_after = (try dir.statFile(testing.io, usage_file_name, .{})).inode;
    try testing.expect(inode_before != inode_after);
}

test "torn tail with a duplicate replay still repairs and records the gap" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    const fact = testFact(testId(1), 1000, 10);
    _ = try store.append(.{ .generation = fact }, now_fixed);
    try home.appendRaw("{\"kind\":");
    try testing.expectEqual(Outcome.duplicate, try store.append(.{ .generation = fact }, now_fixed));
    var view = try store.read();
    defer view.release();
    try testing.expectEqual(@as(usize, 1), view.ledger().facts.len);
    try testing.expectEqual(@as(usize, 1), view.ledger().incidents.len);
}

test "a torn file with no newline at all is replaced by coverage and an incident" {
    var home = Home.init();
    defer home.deinit();
    try home.seed("{\"schema_ver");
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectEqual(Outcome.appended, try store.append(.{ .incident = .{ .occurred_at_ms = 3, .completeness = .pending } }, 50));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":50}\n" ++
            "{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":50,\"completeness\":\"incomplete\"}\n" ++
            "{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":3,\"completeness\":\"pending\"}\n",
        bytes,
    );
}

test "corrupt middle line wedges reads and appends, and nothing is rewritten" {
    var home = Home.init();
    defer home.deinit();
    try home.seed("{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n{\"schema_version\":2}\n" ++
        "{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":3,\"completeness\":\"pending\"}\n");
    const before = try home.ledgerBytes();
    defer testing.allocator.free(before);
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectError(error.InvalidUsageStore, store.read());
    try testing.expectError(error.InvalidUsageStore, store.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed));
    const after = try home.ledgerBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "coverage rules: one value per file; records before coverage are invalid" {
    var home = Home.init();
    defer home.deinit();
    var reader = home.store(.read_only);
    defer reader.deinit();

    try home.seed("{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n");
    var same = try reader.read();
    same.release();
    try home.seed("{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":2}\n");
    try testing.expectError(error.InvalidUsageStore, reader.read());
    try home.seed("{\"schema_version\":1,\"kind\":\"pending\",\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FA1\",\"observed_at_ms\":1}\n");
    try testing.expectError(error.InvalidUsageStore, reader.read());
    const orphan = try lineFor(testing.allocator, .{ .generation = testFact(testId(1), 1, 1) });
    defer testing.allocator.free(orphan);
    try home.seed(orphan);
    try testing.expectError(error.InvalidUsageStore, reader.read());

    // An incident may precede coverage; the next writer then adds coverage after it.
    try home.seed("{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":3,\"completeness\":\"pending\"}\n");
    var writer = home.store(.read_write);
    defer writer.deinit();
    _ = try writer.append(.{ .generation = testFact(testId(1), 4, 1) }, 9);
    var view = try reader.read();
    defer view.release();
    try testing.expectEqual(@as(?i64, 9), view.ledger().coverage_started_at_ms);
}

test "blank lines are skipped and long lines exceed capacity" {
    var home = Home.init();
    defer home.deinit();
    var reader = home.store(.read_only);
    defer reader.deinit();
    try home.seed("\n{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n\n");
    var view = try reader.read();
    try testing.expectEqual(@as(usize, 1), view.ledger().record_count);
    view.release();

    const long = try testing.allocator.alloc(u8, max_record_bytes + 2);
    defer testing.allocator.free(long);
    @memset(long, ' ');
    long[long.len - 1] = '\n';
    try home.seed(long);
    try testing.expectError(error.UsageCapacityExceeded, reader.read());
}

test "invalid events are refused before any I/O; the largest valid record fits" {
    var home = Home.init();
    defer home.deinit();
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectError(error.InvalidGenerationFact, store.append(.{ .generation = testFact("gen_bad", 1, 1) }, now_fixed));
    try testing.expectError(error.InvalidPendingMarker, store.append(.{ .pending = .{ .id = testId(1), .observed_at_ms = -1 } }, now_fixed));
    try testing.expectError(error.InvalidUsageIncident, store.append(.{ .incident = .{ .occurred_at_ms = -1, .completeness = .pending } }, now_fixed));
    try testing.expect(!home.exists(profile_dir_name));

    // A 1024-byte model of quotes escapes to 2 KiB, far under the 16 KiB line cap.
    const model = try testing.allocator.alloc(u8, record.max_model_bytes);
    defer testing.allocator.free(model);
    @memset(model, '"');
    var fact = testFact(testId(1), 1, 1);
    fact.model = model;
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = fact }, now_fixed));
}

test "readers wait for a held lock and report busy after the deadline" {
    var home = Home.init();
    defer home.deinit();
    var writer = home.store(.read_write);
    defer writer.deinit();
    _ = try writer.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    var dir = try home.profile();
    defer dir.close(testing.io);
    var held = (try durable.acquireLock(testing.io, dir, lock_file_name, .{ .deadline_ms = 0, .create = false })).?;

    var reader = Store.init(testing.allocator, testing.io, .{ .home = home.tmp.dir, .mode = .read_only, .lock_deadline_ms = 40 });
    defer reader.deinit();
    try testing.expectError(error.UsageLockBusy, reader.read());
    var blocked = Store.init(testing.allocator, testing.io, .{ .home = home.tmp.dir, .mode = .read_write, .lock_deadline_ms = 40 });
    defer blocked.deinit();
    try testing.expectError(error.UsageLockBusy, blocked.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed));
    blocked.abandon();
    try testing.expectError(error.UsageLockAbandoned, blocked.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed));
    held.release(testing.io);

    var view = try reader.read();
    defer view.release();
    try testing.expectEqual(@as(usize, 1), view.ledger().facts.len);
}

test "a ledger read checks the abandon flag between pieces" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testing.allocator.alloc(u8, 2 * abandon_check_bytes + 7);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = usage_file_name, .data = bytes });
    var file = try tmp.dir.openFile(testing.io, usage_file_name, .{});
    defer file.close(testing.io);
    const read = try testing.allocator.alloc(u8, bytes.len);
    defer testing.allocator.free(read);

    var abandoned: std.atomic.Value(bool) = .init(false);
    try readExactUnlessAbandoned(testing.io, file, read, 0, &abandoned);
    try testing.expectEqualSlices(u8, bytes, read);

    abandoned.store(true, .release);
    try testing.expectError(error.UsageLockAbandoned, readExactUnlessAbandoned(testing.io, file, read, 0, &abandoned));
}

test "abandoning a first read stops it and leaves the ledger as it was" {
    const Abandoner = struct {
        fn hit(ctx: ?*anyopaque, point: Point) void {
            if (point != .lock_acquired) return;
            const store: *Store = @ptrCast(@alignCast(ctx.?));
            store.abandon();
        }
    };
    var home = Home.init();
    defer home.deinit();
    {
        var writer = home.store(.read_write);
        defer writer.deinit();
        _ = try writer.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    }
    const before = try home.ledgerBytes();
    defer testing.allocator.free(before);

    // An abandoned read leaves its buffer and partial index to the process
    // exit, so this store allocates from an arena.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var store = Store.init(arena.allocator(), testing.io, .{ .home = home.tmp.dir, .mode = .read_write });
    defer store.deinit();
    store.options.probe = .{ .ctx = &store, .hit = Abandoner.hit };
    try testing.expectError(error.UsageLockAbandoned, store.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed));

    const after = try home.ledgerBytes();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "read cache: unchanged file is not re-parsed, any change is" {
    var home = Home.init();
    defer home.deinit();
    var writer = home.store(.read_write);
    defer writer.deinit();
    _ = try writer.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    var reader = home.store(.read_only);
    defer reader.deinit();

    var first = try reader.read();
    var second = try reader.read();
    try testing.expectEqual(@as(usize, 1), reader.stats.full_parses);
    try testing.expectEqual(@as(usize, 1), reader.stats.cache_hits);
    try testing.expectEqual(first.shared, second.shared);
    second.release();

    _ = try writer.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed);
    var third = try reader.read();
    defer third.release();
    try testing.expectEqual(@as(usize, 2), reader.stats.full_parses);
    try testing.expectEqual(@as(usize, 2), third.ledger().facts.len);
    // A view taken before the change stays valid and unchanged.
    try testing.expectEqual(@as(usize, 1), first.ledger().facts.len);
    first.release();

    // A same-length replace (another process's compaction or repair) is a
    // new inode, so it is re-parsed.
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const swapped = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(swapped);
    swapped[std.mem.lastIndexOf(u8, swapped, "\"output_tokens\":2").? + "\"output_tokens\":".len] = '3';
    {
        var profile_dir = try home.profile();
        defer profile_dir.close(testing.io);
        try durable.replace(testing.io, profile_dir, usage_file_name, swapped, .{});
    }
    var replaced = try reader.read();
    try testing.expectEqual(@as(usize, 3), reader.stats.full_parses);
    try testing.expectEqual(@as(u64, 3), replaced.ledger().facts[1].output_tokens);
    replaced.release();

    // A held lock doesn't block a cache hit on an unchanged file.
    var dir = try home.profile();
    defer dir.close(testing.io);
    var held = (try durable.acquireLock(testing.io, dir, lock_file_name, .{ .deadline_ms = 0, .create = false })).?;
    defer held.release(testing.io);
    var hit = try reader.read();
    hit.release();
    try testing.expectEqual(@as(usize, 3), reader.stats.full_parses);
}

test "writer index absorbs foreign appends incrementally and re-parses after a foreign replace" {
    var home = Home.init();
    defer home.deinit();
    var mine = home.store(.read_write);
    defer mine.deinit();
    var other = home.store(.read_write);
    defer other.deinit();
    _ = try mine.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    _ = try other.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed);
    try testing.expectEqual(Outcome.duplicate, try mine.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed));
    try testing.expectEqual(@as(usize, 1), mine.stats.incremental_absorbs);
    try testing.expectEqual(@as(usize, 1), mine.stats.full_parses);

    // Same length, different bytes: the tail sample catches it.
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const swapped = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(swapped);
    const at = std.mem.lastIndexOf(u8, swapped, "\"output_tokens\":2").? + "\"output_tokens\":".len;
    swapped[at] = '3';
    var dir = try home.profile();
    defer dir.close(testing.io);
    try durable.replace(testing.io, dir, usage_file_name, swapped, .{});
    try testing.expectEqual(Outcome.conflict, try mine.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed));
    try testing.expectEqual(@as(usize, 2), mine.stats.full_parses);
}

fn seedLedger(alloc: Allocator, coverage: i64, facts: []const GenerationFact, pending: []const PendingMarker, incidents: []const Incident) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try record.writeRecord(&out.writer, .{ .coverage = coverage });
    for (facts) |fact| try record.writeRecord(&out.writer, .{ .generation = fact });
    for (pending) |marker| try record.writeRecord(&out.writer, .{ .pending = marker });
    for (incidents) |incident| try record.writeRecord(&out.writer, .{ .incident = incident });
    return out.toOwnedSlice();
}

test "retention rules: expired, resolved, aged, and retained counts" {
    var index: Index = .{};
    defer index.deinit(testing.allocator);
    const bytes = try seedLedger(testing.allocator, 1, &.{
        testFact(testId(1), now_fixed - retention_ms + 1, 1),
        testFact(testId(2), now_fixed - 2, 1),
    }, &.{
        .{ .id = testId(2), .observed_at_ms = now_fixed - 3 },
        .{ .id = testId(3), .observed_at_ms = now_fixed - 4 },
    }, &.{.{ .occurred_at_ms = now_fixed - 5, .completeness = .pending }});
    defer testing.allocator.free(bytes);
    try index.absorbBytes(testing.allocator, bytes, null);
    // A resolved pending marker counts as expired before an append...
    try testing.expect(hasExpiredRecords(&index, now_fixed));
    // ...but not as aged after one, and nothing is past the slack yet.
    try testing.expect(!hasAgedRecords(&index, now_fixed));
    try testing.expect(hasAgedRecords(&index, now_fixed + compaction_slack_ms + 2));
    // coverage + 2 facts + the unresolved marker + 1 incident
    try testing.expectEqual(@as(usize, 5), retainedRecordCount(&index, now_fixed));
    try testing.expectEqual(@as(usize, 4), retainedRecordCount(&index, now_fixed + 2));
    try testing.expect(!shouldCompactBeforeAppend(max_file_bytes, index.record_count, 1, &index, now_fixed));
    try testing.expect(shouldCompactBeforeAppend(max_file_bytes + 1, index.record_count, 1, &index, now_fixed));
    try testing.expect(shouldCompactBeforeAppend(10, max_records, 1, &index, now_fixed));
    try testing.expect(!shouldCompactAfterAppend(compaction_threshold_bytes, &index, 0, now_fixed));
    try testing.expect(shouldCompactAfterAppend(compaction_threshold_bytes + 1, &index, 0, now_fixed));
    try testing.expect(!shouldCompactAfterAppend(compaction_threshold_bytes + 1, &index, now_fixed, now_fixed));

    // Inside the day of slack: expired before an append, not aged after one.
    var slack: Index = .{};
    defer slack.deinit(testing.allocator);
    const slack_bytes = try seedLedger(testing.allocator, 1, &.{}, &.{}, &.{.{ .occurred_at_ms = now_fixed - retention_ms - 10, .completeness = .pending }});
    defer testing.allocator.free(slack_bytes);
    try slack.absorbBytes(testing.allocator, slack_bytes, null);
    try testing.expect(hasExpiredRecords(&slack, now_fixed));
    try testing.expect(!hasAgedRecords(&slack, now_fixed));
    try testing.expect(hasAgedRecords(&slack, now_fixed + compaction_slack_ms));
}

test "record capacity is checked before append and the file is left intact" {
    try testing.expectEqual(max_records, try checkedRecordCount(max_records - 1, 1));
    try testing.expectError(error.UsageCapacityExceeded, checkedRecordCount(max_records, 1));
}

test "compaction before append: over the record cap with expired records" {
    var home = Home.init();
    defer home.deinit();
    var seed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer seed.deinit();
    try record.writeRecord(&seed.writer, .{ .coverage = 1 });
    for (1..max_records) |i| {
        try record.writeRecord(&seed.writer, .{ .incident = .{ .occurred_at_ms = @intCast(i), .completeness = .pending } });
    }
    try home.seed(seed.written());
    var store = home.store(.read_write);
    defer store.deinit();
    const fact = testFact(testId(1), now_fixed, 1);
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = fact }, now_fixed));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const generation = try lineFor(testing.allocator, .{ .generation = fact });
    defer testing.allocator.free(generation);
    try testing.expectEqualStrings("{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":1}\n", bytes[0 .. bytes.len - generation.len]);
}

test "over capacity with nothing expired: append refused and the file unchanged" {
    var home = Home.init();
    defer home.deinit();
    var seed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer seed.deinit();
    for (0..max_records) |_| try record.writeRecord(&seed.writer, .{ .coverage = 1 });
    try seed.writer.writeAll("{\"schema_version\":1");
    try home.seed(seed.written());
    var store = home.store(.read_write);
    defer store.deinit();
    try testing.expectError(error.UsageCapacityExceeded, store.append(.{ .generation = testFact(testId(1), 2, 1) }, now_fixed));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    try testing.expectEqual(seed.written().len, bytes.len);
    var reader = home.store(.read_only);
    defer reader.deinit();
    try testing.expectError(error.UsageStoreIncomplete, reader.read());
}

test "compaction after append: over 8 MiB with aged records drops them, keeps coverage" {
    var home = Home.init();
    defer home.deinit();
    var seed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer seed.deinit();
    try record.writeRecord(&seed.writer, .{ .coverage = 1 });
    const aged = now_fixed - retention_ms - compaction_slack_ms - 1;
    var i: i64 = 0;
    while (seed.written().len <= compaction_threshold_bytes) : (i += 1) {
        try record.writeRecord(&seed.writer, .{ .incident = .{ .occurred_at_ms = aged - i, .completeness = .incomplete } });
    }
    try record.writeRecord(&seed.writer, .{ .incident = .{ .occurred_at_ms = now_fixed - 1, .completeness = .pending } });
    // Resolved by the fact appended below, so compaction drops it; the other
    // marker is unresolved and recent, so it stays.
    try record.writeRecord(&seed.writer, .{ .pending = .{ .id = testId(1), .observed_at_ms = now_fixed - 2 } });
    try record.writeRecord(&seed.writer, .{ .pending = .{ .id = testId(2), .observed_at_ms = now_fixed - 3 } });
    try home.seed(seed.written());
    var store = home.store(.read_write);
    defer store.deinit();
    const fact = testFact(testId(1), now_fixed, 1);
    try testing.expectEqual(Outcome.appended, try store.append(.{ .generation = fact }, now_fixed));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const expected = try seedLedger(testing.allocator, 1, &.{fact}, &.{.{ .id = testId(2), .observed_at_ms = now_fixed - 3 }}, &.{.{ .occurred_at_ms = now_fixed - 1, .completeness = .pending }});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, bytes);
}

test "probe sees every durability point of an append and a repair, in order" {
    const Recorder = struct {
        points: std.ArrayList(Point) = .empty,
        fn hit(ctx: ?*anyopaque, point: Point) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.points.append(testing.allocator, point) catch {};
        }
    };
    var recorder: Recorder = .{};
    defer recorder.points.deinit(testing.allocator);
    var home = Home.init();
    defer home.deinit();
    var store = Store.init(testing.allocator, testing.io, .{
        .home = home.tmp.dir,
        .mode = .read_write,
        .probe = .{ .ctx = &recorder, .hit = Recorder.hit },
    });
    defer store.deinit();
    _ = try store.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
    try testing.expectEqualSlices(Point, &.{ .lock_acquired, .append_partial, .append_written, .append_synced }, recorder.points.items);

    recorder.points.clearRetainingCapacity();
    try home.appendRaw("{");
    _ = try store.append(.{ .generation = testFact(testId(2), 1, 1) }, now_fixed);
    try testing.expectEqualSlices(Point, &.{
        .lock_acquired,       .replace_temp_created, .replace_temp_written,
        .replace_temp_synced, .replace_renamed,      .replace_done,
    }, recorder.points.items);
}

test "allocation failures leave no leaks and the file readable" {
    var setup = Home.init();
    defer setup.deinit();
    {
        var store = setup.store(.read_write);
        defer store.deinit();
        _ = try store.append(.{ .generation = testFact(testId(1), 1, 1) }, now_fixed);
        _ = try store.append(.{ .pending = .{ .id = testId(2), .observed_at_ms = 3 } }, now_fixed);
        _ = try store.append(.{ .pending = .{ .id = testId(2), .observed_at_ms = 4 } }, now_fixed);
        try setup.appendRaw("{\"torn");
    }
    const seeded = try setup.ledgerBytes();
    defer testing.allocator.free(seeded);

    const Run = struct {
        // Each attempt starts from the same files, so every attempt
        // allocates the same way up to the injected failure.
        fn go(alloc: Allocator, bytes: []const u8) !void {
            var home = Home.init();
            defer home.deinit();
            try home.seed(bytes);
            var store = Store.init(alloc, testing.io, .{ .home = home.tmp.dir, .mode = .read_write });
            defer store.deinit();
            if (store.read()) |torn| {
                var view = torn;
                view.release();
                return error.TestUnexpectedResult;
            } else |err| if (err != error.UsageStoreIncomplete) return err;
            _ = try store.append(.{ .generation = testFact(testId(5), 1, 1) }, now_fixed);
            _ = try store.append(.{ .generation = testFact(testId(6), 1, 1) }, now_fixed);
            var view = try store.read();
            defer view.release();
            try testing.expectEqual(@as(usize, 3), view.ledger().facts.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.go, .{seeded});
}

test "captured fx ledger reads back with fx's record counts" {
    const captured = @embedFile("../testdata/u04/usage.jsonl");
    var home = Home.init();
    defer home.deinit();
    try home.seed(captured);
    var store = home.store(.read_write);
    defer store.deinit();
    var view = try store.read();
    defer view.release();
    const ledger = view.ledger();
    try testing.expect(ledger.coverage_started_at_ms != null);
    try testing.expectEqual(@as(usize, 15), ledger.record_count);
    try testing.expectEqual(@as(usize, 5), ledger.facts.len);
    try testing.expectEqual(@as(usize, 7), ledger.pending.len);
    try testing.expectEqual(@as(usize, 2), ledger.incidents.len);
    // Replaying every captured fact answers duplicate and changes nothing.
    for (ledger.facts) |fact| try testing.expectEqual(Outcome.duplicate, try store.append(.{ .generation = fact }, now_fixed));
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(captured, bytes);
}

test "captured torn ledger is repaired by the next writer" {
    const torn = @embedFile("../testdata/u04/usage.torn-input.jsonl");
    var home = Home.init();
    defer home.deinit();
    try home.seed(torn);
    var reader = home.store(.read_only);
    defer reader.deinit();
    try testing.expectError(error.UsageStoreIncomplete, reader.read());
    var writer = home.store(.read_write);
    defer writer.deinit();
    _ = try writer.append(.{ .incident = .{ .occurred_at_ms = 1, .completeness = .pending } }, now_fixed);
    const bytes = try home.ledgerBytes();
    defer testing.allocator.free(bytes);
    const boundary = std.mem.lastIndexOfScalar(u8, torn, '\n').? + 1;
    try testing.expectEqualStrings(torn[0..boundary], bytes[0..boundary]);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":1800000000000,\"completeness\":\"incomplete\"}\n" ++
            "{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":1,\"completeness\":\"pending\"}\n",
        bytes[boundary..],
    );
}
