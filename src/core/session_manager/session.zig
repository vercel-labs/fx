//! L2: one session and its lifecycle.
//!
//! - `openNew` touches nothing on disk. `set` lines are held in memory until
//!   the first `turn_started`, which publishes the session (D2).
//! - `append` assigns seq and ts under the Session mutex, checks the batch
//!   with the pure rules in fold.zig, writes it with one call, and syncs
//!   after the unlock when the batch holds a durable-class event (D3).
//! - `openResume` takes the flock, cuts a torn tail, folds from the newest
//!   snapshot, and repairs what a crash left open (D1).
//! - `close` interrupts an open turn, appends `closed`, syncs, unlocks.
//! - `readPage` reads any session without a lock.
//!
//! Locks, always in this order: the flock on `{id}/lock` (one writing
//! process), then `Session.mutex` (one call at a time), then
//! `Session.sync_mutex` (one fsync at a time). Hosts never lock anything.

const std = @import("std");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const diag = @import("diag.zig");
const trace = if (storage.hooks) @import("trace.zig") else struct {};

const hooks = storage.hooks;
const Log = log_mod.Log;

/// D7, tuned by `zig build bench`: at 10K turns resume takes 1.2 ms at
/// 256 KB and 0.4 ms at 64 KB. Smaller distances gain little and cost more
/// log bytes when the folded state (settings, children) is large.
pub const default_snapshot_every_bytes: u64 = 64 << 10;

pub const Options = struct {
    /// How long `openResume` retries a held flock before Busy.
    lock_wait_ms: u64 = 2000,
    /// A snapshot follows once this many bytes were appended since the last
    /// one (D7). A `compacted` line always gets one.
    snapshot_every_bytes: u64 = default_snapshot_every_bytes,
    /// The index is rewritten with one line per id past this size.
    index_compact_bytes: u64 = 1 << 20,
};

/// What every Session of one manager shares. Owned by L4; outlives them.
pub const Env = struct {
    /// Thread-safe when Sessions are used from several threads.
    gpa: std.mem.Allocator,
    s: storage.Storage,
    root: storage.Dir,
    options: Options = .{},
    diagnostics: ?diag.Sink = null,
    observer: if (hooks) ?Observer else void = if (hooks) null else {},
    catalog_observer: if (hooks) ?CatalogObserver else void = if (hooks) null else {},
    planted: if (hooks) trace.Planted else void = if (hooks) .none else {},

    /// Hooks only: reports a catalog-level step (`tla/Catalog.tla`).
    pub fn observeCatalog(env: *const Env, id: []const u8, what: CatalogStep) void {
        if (hooks) {
            const observer = env.catalog_observer orelse return;
            observer.notify(observer.context, id, what);
        }
    }

    fn nowMs(env: *const Env) u64 {
        return std.math.cast(u64, std.Io.Timestamp.now(env.s.io, .real).toMilliseconds()) orelse 0;
    }

    pub fn isPlanted(env: *const Env, bug: anytype) bool {
        return if (hooks) env.planted == bug else false;
    }
};

/// Hooks only: what the Session just did, for the spec tracers in tests.
pub const Observed = union(enum) {
    opened_new,
    made_tmp,
    /// One line reached the file (observed mode writes line by line).
    wrote_line: struct { seq: u64, kind: schema.Kind, cause: Cause },
    publish_synced,
    renamed,
    published,
    /// Resume took the lock and repaired an open turn (if any).
    reopened,
    closed,
    /// `append` holds the mutex / is about to release it after writing.
    mutex_acquired,
    mutex_releasing,
    /// The flock was released by `close`.
    unlocked,
};

/// Hooks only: catalog-level steps, for the Catalog tracer in tests.
pub const CatalogStep = enum { index_put, index_del, trashed, purged, healed, rebuilt };

pub const CatalogObserver = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, id: []const u8, what: CatalogStep) void,
};

pub const Cause = enum { header, host, snapshot, close, interrupt_repair, child_repair, workspace_repair };

pub const Observer = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, session: *Session, what: Observed) void,
};

pub const AppendError = error{ InvalidTransition, SessionClosed, TooLarge, OutOfMemory } || storage.IoFault;
pub const OpenError = error{ NotFound, Busy, ChildSession, Corrupt, UnsupportedVersion, OutOfMemory } || storage.IoFault;

pub const Identity = struct {
    id: []u8,
    workspace: []u8,
    role: schema.Role,
    host: schema.Host,
    parent: ?[]u8 = null,
    forked_from: ?Origin = null,

    pub const Origin = struct { id: []u8, seq: u64 };

    fn fromCreated(gpa: std.mem.Allocator, c: schema.Body.Created) error{OutOfMemory}!Identity {
        var identity: Identity = .{
            .id = try gpa.dupe(u8, c.id),
            .workspace = &.{},
            .role = c.role,
            .host = c.host,
        };
        errdefer identity.deinit(gpa);
        identity.workspace = try gpa.dupe(u8, c.workspace);
        if (c.parent) |parent| identity.parent = try gpa.dupe(u8, parent);
        if (c.forked_from) |origin| identity.forked_from = .{ .id = try gpa.dupe(u8, origin.id), .seq = origin.seq };
        return identity;
    }

    fn created(identity: *const Identity) schema.Body.Created {
        return .{
            .id = identity.id,
            .workspace = identity.workspace,
            .role = identity.role,
            .host = identity.host,
            .parent = identity.parent,
            .forked_from = if (identity.forked_from) |o| .{ .id = o.id, .seq = o.seq } else null,
        };
    }

    /// Child lines at or before this seq belong to a fork's source.
    fn forkSeq(identity: *const Identity) u64 {
        return if (identity.forked_from) |o| o.seq else 0;
    }

    fn deinit(identity: *Identity, gpa: std.mem.Allocator) void {
        gpa.free(identity.id);
        gpa.free(identity.workspace);
        if (identity.parent) |parent| gpa.free(parent);
        if (identity.forked_from) |origin| gpa.free(origin.id);
    }
};

const Live = struct {
    dir: storage.Dir,
    log: Log,
    lock: storage.File,
};

const Phase = union(enum) {
    /// Before the first turn: nothing on disk.
    held,
    live: Live,
    /// A write or sync failed; durability is unknown until a reopen.
    failed: ?Live,
    closed,
};

/// The last written seq, which `syncThrough` reads without `mutex` so that
/// appends go on during an fsync. A 64-bit atomic where the target has one;
/// on 32-bit targets such as fx's wasm build, a value behind its own brief
/// lock (never held across an fsync).
const SeqCell = if (@bitSizeOf(usize) >= 64) struct {
    value: std.atomic.Value(u64) = .init(0),

    fn store(cell: *@This(), _: std.Io, seq: u64) void {
        cell.value.store(seq, .release);
    }

    fn load(cell: *@This(), _: std.Io) u64 {
        return cell.value.load(.acquire);
    }
} else struct {
    mutex: std.Io.Mutex = .init,
    value: u64 = 0,

    fn store(cell: *@This(), io: std.Io, seq: u64) void {
        cell.mutex.lockUncancelable(io);
        defer cell.mutex.unlock(io);
        cell.value = seq;
    }

    fn load(cell: *@This(), io: std.Io) u64 {
        cell.mutex.lockUncancelable(io);
        defer cell.mutex.unlock(io);
        return cell.value;
    }
};

pub const Session = struct {
    env: *const Env,
    mutex: std.Io.Mutex = .init,
    sync_mutex: std.Io.Mutex = .init,

    identity: Identity,
    /// Under `mutex`.
    state: fold.State = .{},
    phase: Phase,
    /// Import only (D8): keep the original timestamp of each event.
    import_ts: ?u64 = null,
    /// `ts` of line 1: set by an import, else by the first publish or fork,
    /// or read back on resume.
    created_ms: ?u64 = null,
    /// `ts` of the newest line, never before `created_ms`; 0 until the
    /// first write (D20). Under `mutex`.
    updated_ms: u64 = 0,

    // Scratch and held lines, under `mutex`.
    held: std.ArrayList(u8) = .empty,
    held_lines: u64 = 0,
    batch: std.ArrayList(u8) = .empty,
    bounds: std.ArrayList(usize) = .empty,
    bodies: std.ArrayList(schema.Body) = .empty,
    /// Log offset just past the newest snapshot, or 0.
    snapshot_base: u64 = 0,

    // Durability, under `sync_mutex`.
    sync_file: ?storage.File = null,
    synced_seq: u64 = 0,
    /// Written under `mutex`, read under `sync_mutex`.
    written_seq: SeqCell = .{},
    /// A sync that failed outside `mutex`, as a `FaultCode`; `none` until then.
    sync_fault: std.atomic.Value(u8) = .init(@backingInt(FaultCode.none)),
    /// Under `mutex`: the cause of the write or sync that failed the
    /// session. Every later call reports it (D40).
    fault: ?storage.IoFault = null,

    pub fn id(session: *const Session) []const u8 {
        return session.identity.id;
    }

    /// Whether appending `events` leaves this session held in memory, so it
    /// needs no disk, not even the root folder (D2). A publishing thread
    /// always opens the root first, so a stale answer is harmless.
    pub fn staysHeld(session: *Session, events: []const fold.Event) bool {
        const io = session.env.s.io;
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);
        if (session.phase != .held) return false;
        for (events) |event| {
            if (event == .turn_started) return false;
        }
        return true;
    }

    /// A page of this session's own lines through its open log: no open and
    /// no scan for the end, so paging the current session's transcript
    /// costs only the reads. Holds `mutex` while it reads one page, so a
    /// concurrent `close` cannot take the file away. Before the first turn
    /// nothing is on disk: an empty page.
    pub fn readPage(
        session: *Session,
        gpa: std.mem.Allocator,
        from: From,
        direction: Direction,
        limit: usize,
    ) (error{ SessionClosed, OutOfMemory } || storage.IoFault)!Page {
        const io = session.env.s.io;
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);
        const log: *const Log = switch (session.phase) {
            .held => return .{ .arena = .init(gpa), .entries = &.{}, .next = null, .damaged = false },
            .live => |*live| &live.log,
            // After a failed write, the lines up to the tracked end are whole.
            .failed => |*maybe| if (maybe.*) |*live| &live.log else return error.SessionClosed,
            .closed => return error.SessionClosed,
        };
        return readLines(session.env.s, gpa, log.file, log.end, from, direction, limit);
    }

    /// An owned copy of the folded state, taken under the mutex.
    pub fn stateCopy(session: *Session, gpa: std.mem.Allocator) error{OutOfMemory}!fold.State {
        const io = session.env.s.io;
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);
        var copy = try session.state.clone(gpa);
        copy.created_ms = session.created_ms orelse 0;
        copy.updated_ms = session.updated_ms;
        return copy;
    }

    /// Lines stamped `ts` reached the log.
    fn wrote(session: *Session, ts: u64) void {
        session.updated_ms = @max(ts, session.created_ms orelse 0);
    }

    /// Appends a batch and returns the seq of its last line. The batch is
    /// written with one call; it is checked as a whole, so a refused batch
    /// writes nothing. Returns after the fsync if the batch holds a
    /// durable-class event.
    pub fn append(session: *Session, events: []const fold.Event) AppendError!u64 {
        return (try session.appendReport(events, null)).last_seq;
    }

    pub const Appended = struct {
        last_seq: u64,
        /// This call published the session (its first turn).
        published: bool,
        /// The batch set the title or the workspace.
        listing_changed: bool,
    };

    /// `append`, plus what the catalog needs to know. `ts_ms` stamps the
    /// batch with an original time (import only).
    pub fn appendReport(session: *Session, events: []const fold.Event, ts_ms: ?u64) AppendError!Appended {
        const io = session.env.s.io;
        var sync_through: ?u64 = null;
        const result = blk: {
            session.mutex.lockUncancelable(io);
            defer session.mutex.unlock(io);
            session.observe(.mutex_acquired);
            const was_held = session.phase == .held;
            if (ts_ms) |ts| session.import_ts = ts;
            const last = try session.appendLocked(events, &sync_through);
            session.observe(.mutex_releasing);
            break :blk Appended{
                .last_seq = last,
                .published = was_held and session.phase == .live,
                // Only a published session is in the index.
                .listing_changed = session.phase == .live and changesListing(events),
            };
        };
        if (sync_through) |seq| try session.syncThrough(seq);
        return result;
    }

    fn appendLocked(session: *Session, events: []const fold.Event, sync_through: *?u64) AppendError!u64 {
        switch (session.phase) {
            .closed => return error.SessionClosed,
            .failed => return session.fault orelse error.Io,
            .held, .live => {},
        }
        if (faultFromCode(session.sync_fault.load(.acquire))) |cause| {
            session.markFailed(cause);
            return cause;
        }
        if (events.len == 0) return session.state.last_seq;
        const gpa = session.env.gpa;
        try session.bodies.resize(gpa, events.len);
        const bodies = session.bodies.items;
        fold.plan(&session.state, events, bodies) catch |err| {
            if (!session.plantedItemOutsideTurn(events, bodies)) return err;
        };
        const ts = session.timestamp();
        switch (session.phase) {
            .held => {
                // Nothing exists on disk yet, so no blob can be referenced.
                if (hasBlobRefs(bodies)) return error.InvalidTransition;
                if (!hasTurnStart(bodies)) {
                    try session.hold(bodies, ts);
                } else {
                    // The publish syncs every line it writes.
                    try session.publish(bodies, ts);
                    try session.maybeSnapshot(&session.phase.live, bodies, ts);
                }
            },
            .live => |*live| {
                try session.checkBlobRefs(live, bodies);
                try session.writeBodies(live, bodies, ts, .host);
                try session.maybeSnapshot(live, bodies, ts);
                if (needsSync(bodies)) sync_through.* = session.state.last_seq;
            },
            .failed, .closed => unreachable,
        }
        return session.state.last_seq;
    }

    /// Hooks only: the planted TurnLifecycle bug writes an item anyway.
    fn plantedItemOutsideTurn(session: *Session, events: []const fold.Event, bodies: []schema.Body) bool {
        if (!session.env.isPlanted(.accept_item_outside_turn)) return false;
        if (events.len != 1 or events[0] != .item or session.phase != .live) return false;
        bodies[0] = .{ .item = .{ .turn = session.state.last_turn, .type = events[0].item.type, .data = events[0].item.data } };
        return true;
    }

    /// Before the first turn, a batch without `turn_started` may only hold
    /// settings; they wait in memory, already framed (seq 2 onward).
    fn hold(session: *Session, bodies: []const schema.Body, ts: u64) AppendError!void {
        for (bodies) |body| if (body != .set) return error.InvalidTransition;
        const gpa = session.env.gpa;
        const start = session.held.items.len;
        errdefer session.held.shrinkRetainingCapacity(start);
        for (bodies, 0..) |body, i| {
            try session.frame(&session.held, 2 + session.held_lines + i, ts, body);
        }
        for (bodies, 0..) |body, i| {
            try fold.apply(gpa, &session.state, 0, .{ .seq = 2 + session.held_lines + i, .offset = 0, .body = body });
        }
        session.held_lines += bodies.len;
    }

    /// The first turn: stage the session in `.tmp/{id}`, make line 1
    /// durable, then rename it into place and sync the root, so a visible
    /// session always has a durable first line (`tla/Lifecycle.tla`).
    fn publish(session: *Session, bodies: []const schema.Body, ts: u64) AppendError!void {
        session.writeFirstTurn(bodies, ts) catch |err| {
            // Nothing is visible; later calls name the cause (D40).
            session.phase = .{ .failed = null };
            if (session.fault == null) session.fault = asIoFault(err);
            return err;
        };
    }

    fn writeFirstTurn(session: *Session, bodies: []const schema.Body, ts: u64) AppendError!void {
        const gpa = session.env.gpa;

        // Frame everything first: line 1, the held lines, then the batch.
        session.batch.clearRetainingCapacity();
        session.bounds.clearRetainingCapacity();
        const created = session.created_ms orelse ts;
        try session.frameMarked(1, created, .{ .session_created = session.identity.created() });
        session.created_ms = created;
        var at: usize = 0;
        while (at < session.held.items.len) {
            const nl = std.mem.findScalarPos(u8, session.held.items, at, '\n').?;
            try session.batch.appendSlice(gpa, session.held.items[at .. nl + 1]);
            try session.bounds.append(gpa, session.batch.items.len);
            at = nl + 1;
        }
        const first_batch_seq = 2 + session.held_lines;
        for (bodies, 0..) |body, i| try session.frameMarked(first_batch_seq + i, ts, body);

        const live = try session.stage(null);

        // Fold the batch; line 1 has no state and the held lines are folded.
        for (bodies, 0..) |body, i| {
            const line_index: usize = @intCast(1 + session.held_lines + i);
            try fold.apply(gpa, &session.state, 0, .{
                .seq = first_batch_seq + i,
                .offset = session.bounds.items[line_index - 1],
                .body = body,
            });
        }
        session.phase = .{ .live = live };
        session.wrote(ts);
        session.held.clearAndFree(gpa);
        session.held_lines = 0;
        session.written_seq.store(session.env.s.io, session.state.last_seq);
        session.setSyncFile(live.log.file, session.state.last_seq);
    }

    /// The staged publish shared by the first turn and fork: `.tmp/{id}`,
    /// the lines framed in `session.batch`, blobs linked from a fork's
    /// source, a synced log, the lock, a synced folder, the rename into
    /// place, and a synced root. Only then is the session visible, always
    /// with a durable first line (`tla/Lifecycle.tla`).
    fn stage(session: *Session, source_blobs: ?storage.Dir) AppendError!Live {
        const env = session.env;
        const s = env.s;
        const id_ = session.identity.id;
        const tmp = s.ensureDir(env.root, ".tmp") catch |io_err| return storage.ioFault(io_err);
        defer s.closeDir(tmp);
        s.makeDir(tmp, id_) catch |err| switch (err) {
            // A leftover from a crashed attempt with the same id (an import).
            error.AlreadyExists => {
                s.deleteTree(tmp, id_) catch |io_err| return storage.ioFault(io_err);
                s.makeDir(tmp, id_) catch |io_err| return storage.ioFault(io_err);
            },
            else => |io_err| return storage.ioFault(io_err),
        };
        session.observe(.made_tmp);
        const dir = s.openDir(tmp, id_) catch |io_err| return storage.ioFault(io_err);
        errdefer s.closeDir(dir);
        {
            const blobs = s.ensureDir(dir, "blobs") catch |io_err| return storage.ioFault(io_err);
            defer s.closeDir(blobs);
            if (source_blobs) |source| {
                try session.linkBlobs(source, blobs);
                s.syncDir(blobs) catch |io_err| return storage.ioFault(io_err);
            }
        }
        var log = Log.create(s, dir, "log.jsonl", .{}) catch |io_err| return storage.ioFault(io_err);
        errdefer log.close();
        session.writeFramed(&log, 1, .header) catch |io_err| return storage.ioFault(io_err);

        const rename_first = env.isPlanted(.rename_before_fsync);
        if (rename_first) try session.publishRename(tmp);
        s.sync(log.file) catch |io_err| return storage.ioFault(io_err);
        session.observe(.publish_synced);
        const lock = s.createFile(dir, "lock") catch |io_err| return storage.ioFault(io_err);
        errdefer s.closeFile(lock);
        if (!(s.tryLock(lock) catch |io_err| return storage.ioFault(io_err))) return error.Io;
        s.syncDir(dir) catch |io_err| return storage.ioFault(io_err);
        if (!rename_first) try session.publishRename(tmp);
        s.syncDir(env.root) catch |io_err| return storage.ioFault(io_err);
        session.observe(.published);
        return .{ .dir = dir, .log = log, .lock = lock };
    }

    /// Hard-links every blob of a fork's source (D6), copying when a link
    /// is refused, for example across file systems.
    fn linkBlobs(session: *Session, source: storage.Dir, target: storage.Dir) AppendError!void {
        const s = session.env.s;
        var skipped_one = false;
        var listing = s.list(source);
        while (listing.next() catch |io_err| return storage.ioFault(io_err)) |entry| {
            if (entry.kind != .file or !schema.validBlobHash(entry.name)) continue;
            if (session.env.isPlanted(.fork_skips_blob_link) and !skipped_one) {
                skipped_one = true;
                continue;
            }
            s.link(source, entry.name, target, entry.name) catch |err| switch (err) {
                error.AlreadyExists => {},
                error.NoSpace => return error.NoSpaceLeft,
                else => try copyBlob(session.env, source, target, entry.name),
            };
        }
    }

    /// Stores `bytes` as a blob of this session and returns its name, the
    /// SHA-256 hash (D6). Returns only once the blob and its name are
    /// durable: a line referring to it may become durable through any later
    /// fsync, including one another thread starts. Storing the same bytes
    /// again costs one stat.
    pub fn putBlob(session: *Session, bytes: []const u8) AppendError![schema.blob_hash_len]u8 {
        if (bytes.len > max_blob_bytes) return error.TooLarge;
        return session.storeBlob(.{ .bytes = bytes });
    }

    /// As `putBlob`, for the first `len` bytes of `file`, an open file
    /// outside the session such as a command's output spool. They are
    /// copied in chunks, so the body is never whole in memory (D44).
    pub fn putBlobFile(session: *Session, file: std.Io.File, len: u64) AppendError![schema.blob_hash_len]u8 {
        if (len > max_blob_bytes) return error.TooLarge;
        return session.storeBlob(.{ .file = .{ .file = file, .len = len } });
    }

    const BlobSource = union(enum) {
        bytes: []const u8,
        file: struct { file: std.Io.File, len: u64 },
    };

    const blob_copy_chunk_bytes = 256 * 1024;

    fn storeBlob(session: *Session, source: BlobSource) AppendError![schema.blob_hash_len]u8 {
        const env = session.env;
        const s = env.s;
        const io = s.io;
        // Hold the mutex only to check the phase and borrow the folder.
        const dir = blk: {
            session.mutex.lockUncancelable(io);
            defer session.mutex.unlock(io);
            switch (session.phase) {
                .live => |live| break :blk s.openDir(live.dir, "blobs") catch |io_err| return storage.ioFault(io_err),
                .held => return error.InvalidTransition,
                .failed => return session.fault orelse error.Io,
                .closed => return error.SessionClosed,
            }
        };
        defer s.closeDir(dir);
        // Bytes in hand name themselves before any write; a file is named
        // once copied.
        const known: ?[schema.blob_hash_len]u8 = switch (source) {
            .bytes => |bytes| schema.blobHash(bytes),
            .file => null,
        };
        if (known) |hash| if (s.stat(dir, &hash)) |_| return hash else |_| {};
        var tmp_name: [1 + 7 + 1 + 16 + 4]u8 = undefined;
        var suffix: [8]u8 = undefined;
        io.random(&suffix);
        const name = std.mem.print(&tmp_name, ".pending.{x}.tmp", .{&suffix}) catch unreachable;
        const file = s.createReadOnlyFile(dir, name) catch |io_err| return storage.ioFault(io_err);
        var file_open = true;
        defer if (file_open) s.closeFile(file);
        var renamed = false;
        defer if (!renamed) s.deleteFile(dir, name) catch {};
        const hash = switch (source) {
            .bytes => |bytes| blk: {
                s.writeAt(file, bytes, 0) catch |io_err| return storage.ioFault(io_err);
                break :blk known.?;
            },
            .file => |from| try copyBlobFrom(env, file, from.file, from.len),
        };
        s.sync(file) catch |io_err| return storage.ioFault(io_err);
        s.closeFile(file);
        file_open = false;
        if (known == null) if (s.stat(dir, &hash)) |_| return hash else |_| {};
        s.rename(dir, name, dir, &hash) catch |io_err| return storage.ioFault(io_err);
        renamed = true;
        s.syncDir(dir) catch |io_err| return storage.ioFault(io_err);
        return hash;
    }

    /// Every blob an item or a setting refers to must already exist in this
    /// session (`tla/Fork.tla` `RefsExist`).
    fn checkBlobRefs(session: *Session, live: *Live, bodies: []const schema.Body) AppendError!void {
        if (!hasBlobRefs(bodies)) return;
        const s = session.env.s;
        const dir = s.openDir(live.dir, "blobs") catch |io_err| return storage.ioFault(io_err);
        defer s.closeDir(dir);
        for (bodies) |body| for (body.blobRefs()) |hash| {
            if (!schema.validBlobHash(hash)) return error.InvalidTransition;
            _ = s.stat(dir, hash) catch return error.InvalidTransition;
        };
    }

    fn publishRename(session: *Session, tmp: storage.Dir) AppendError!void {
        session.env.s.rename(tmp, session.identity.id, session.env.root, session.identity.id) catch |io_err| return storage.ioFault(io_err);
        session.observe(.renamed);
    }

    /// Frames `bodies` at the end of the live log, writes them, and folds them.
    fn writeBodies(session: *Session, live: *Live, bodies: []const schema.Body, ts: u64, cause: Cause) AppendError!void {
        const gpa = session.env.gpa;
        const first_seq = live.log.next_seq;
        const base = live.log.end;
        session.batch.clearRetainingCapacity();
        session.bounds.clearRetainingCapacity();
        for (bodies, 0..) |body, i| try session.frameMarked(first_seq + i, ts, body);
        session.writeFramed(&live.log, first_seq, cause) catch |err| {
            const fault = storage.ioFault(err);
            session.markFailed(fault);
            return fault;
        };
        const fork_seq = session.identity.forkSeq();
        for (bodies, 0..) |body, i| {
            const offset = base + if (i == 0) 0 else session.bounds.items[i - 1];
            try fold.apply(gpa, &session.state, fork_seq, .{ .seq = first_seq + i, .offset = offset, .body = body });
        }
        session.wrote(ts);
        session.written_seq.store(session.env.s.io, session.state.last_seq);
    }

    /// Writes `session.batch` (lines ending at `session.bounds`) in one
    /// append, observed or not, so traced runs and crash matrices see the
    /// write pattern production has. An observer then sees each line; a
    /// tracer reading the disk bounds its view by the line's seq.
    fn writeFramed(session: *Session, log: *Log, first_seq: u64, cause: Cause) log_mod.AppendError!void {
        try log.append(session.batch.items, session.bounds.items.len);
        if (!session.observing()) return;
        var start: usize = 0;
        for (session.bounds.items, 0..) |end, i| {
            const line = session.batch.items[start..end];
            const header = log_mod.checkLine(line) catch unreachable;
            // In a publish only line 1 is the header; the held and batch
            // lines after it come from the host.
            const line_cause: Cause = if (cause != .header) cause else if (i == 0) .header else .host;
            session.observe(.{ .wrote_line = .{ .seq = first_seq + i, .kind = header.kind.?, .cause = line_cause } });
            start = end;
        }
    }

    fn maybeSnapshot(session: *Session, live: *Live, bodies: []const schema.Body, ts: u64) AppendError!void {
        var compacted = false;
        for (bodies) |body| {
            if (body == .compacted) compacted = true;
        }
        if (!compacted and live.log.end - session.snapshot_base < session.env.options.snapshot_every_bytes) return;
        try session.writeSnapshot(live, ts);
    }

    /// A snapshot is a cache: one that does not fit in a line is skipped and
    /// reported, never failing the append whose batch is already written.
    fn writeSnapshot(session: *Session, live: *Live, ts: u64) AppendError!void {
        const gpa = session.env.gpa;
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        const body = try session.snapshotBody(&encoded);
        session.writeBodies(live, &.{body}, ts, .snapshot) catch |err| switch (err) {
            error.TooLarge => diag.report(session.env.diagnostics, .{
                .kind = .snapshot_skipped,
                .session_id = session.identity.id,
                .count = encoded.items.len,
            }),
            else => return err,
        };
        session.snapshot_base = live.log.end;
    }

    /// A snapshot of the state folded so far. The body borrows `encoded`.
    fn snapshotBody(session: *Session, encoded: *std.ArrayList(u8)) error{OutOfMemory}!schema.Body {
        const gpa = session.env.gpa;
        if (session.env.isPlanted(.snapshot_drops_field)) {
            var copy = try session.state.clone(gpa);
            defer copy.deinit(gpa);
            if (copy.prefs) |p| gpa.free(p);
            copy.prefs = null;
            try fold.encodeState(gpa, encoded, &copy);
        } else {
            try fold.encodeState(gpa, encoded, &session.state);
        }
        return .{ .snapshot = .{
            .covers_seq = session.state.last_seq,
            .state = encoded.items,
            .compaction_offset = session.state.compaction_offset,
        } };
    }

    fn frame(session: *Session, out: *std.ArrayList(u8), seq: u64, ts: u64, body: schema.Body) AppendError!void {
        const gpa = session.env.gpa;
        var fields: std.ArrayList(u8) = .empty;
        defer fields.deinit(gpa);
        try schema.appendBody(gpa, &fields, body);
        log_mod.appendLine(gpa, out, seq, ts, std.meta.activeTag(body), fields.items) catch |err| switch (err) {
            error.TooLarge => return error.TooLarge,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn frameMarked(session: *Session, seq: u64, ts: u64, body: schema.Body) AppendError!void {
        try session.frame(&session.batch, seq, ts, body);
        try session.bounds.append(session.env.gpa, session.batch.items.len);
    }

    /// Returns once every line through `seq` is synced. Runs outside
    /// `mutex`, so appends from other threads continue during the fsync;
    /// one fsync covers every line written before it started.
    fn syncThrough(session: *Session, seq: u64) AppendError!void {
        const io = session.env.s.io;
        session.sync_mutex.lockUncancelable(io);
        defer session.sync_mutex.unlock(io);
        if (session.synced_seq >= seq) return;
        const file = session.sync_file orelse return error.SessionClosed;
        const target = session.written_seq.load(io);
        std.debug.assert(target >= seq);
        session.env.s.sync(file) catch |err| {
            const fault = storage.ioFault(err);
            // Only the first cause is kept; a later failure changes nothing.
            _ = session.sync_fault.cmpxchgStrong(@backingInt(FaultCode.none), @backingInt(faultCode(fault)), .release, .monotonic);
            return fault;
        };
        session.synced_seq = target;
    }

    fn setSyncFile(session: *Session, file: ?storage.File, synced: u64) void {
        const io = session.env.s.io;
        session.sync_mutex.lockUncancelable(io);
        defer session.sync_mutex.unlock(io);
        session.sync_file = file;
        session.synced_seq = synced;
    }

    /// Fails a live session with `cause`; the first cause is the one kept.
    fn markFailed(session: *Session, cause: storage.IoFault) void {
        switch (session.phase) {
            .live => |live| session.phase = .{ .failed = live },
            else => {},
        }
        if (session.fault == null) session.fault = cause;
    }

    fn timestamp(session: *const Session) u64 {
        return session.import_ts orelse session.env.nowMs();
    }

    fn observing(session: *const Session) bool {
        return if (hooks) session.env.observer != null else false;
    }

    fn observe(session: *Session, what: Observed) void {
        if (hooks) {
            const observer = session.env.observer orelse return;
            observer.notify(observer.context, session, what);
        }
    }

    /// Ends the session: an open turn is interrupted, `closed` is appended
    /// and synced, and the flock is released. Later calls get SessionClosed.
    /// Calling it again does nothing. The handle stays valid until `destroy`.
    pub fn close(session: *Session) AppendError!void {
        _ = try session.closeReport();
    }

    /// `close`, returning whether the session exists on disk (it was
    /// published) and this call closed it.
    pub fn closeReport(session: *Session) AppendError!bool {
        const io = session.env.s.io;
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);
        const was_live = session.phase == .live;
        try session.closeLocked();
        return was_live;
    }

    fn closeLocked(session: *Session) AppendError!void {
        switch (session.phase) {
            .closed => return,
            .held => {
                if (session.held_lines > 0) diag.report(session.env.diagnostics, .{
                    .kind = .held_lines_dropped,
                    .session_id = session.identity.id,
                    .count = session.held_lines,
                });
                session.held.clearAndFree(session.env.gpa);
                session.held_lines = 0;
                session.phase = .closed;
            },
            .failed => |maybe_live| {
                if (maybe_live) |live| session.release(live);
                session.phase = .closed;
            },
            .live => |*live| {
                var result: AppendError!void = {};
                var bodies_buffer: [2]schema.Body = undefined;
                var n: usize = 0;
                if (session.state.open_turn) |turn| {
                    bodies_buffer[n] = .{ .turn_interrupted = .{ .turn = turn, .reason = .closed } };
                    n += 1;
                }
                bodies_buffer[n] = .closed;
                n += 1;
                if (session.writeBodies(live, bodies_buffer[0..n], session.timestamp(), .close)) {
                    session.observe(.closed);
                    result = session.syncThrough(session.state.last_seq);
                } else |err| result = err;
                const resources = switch (session.phase) {
                    .live => |l| l,
                    .failed => |l| l.?,
                    else => unreachable,
                };
                session.release(resources);
                session.phase = .closed;
                return result;
            },
        }
    }

    fn release(session: *Session, live: Live) void {
        const s = session.env.s;
        session.setSyncFile(null, session.synced_seq);
        var log = live.log;
        s.unlock(live.lock);
        session.observe(.unlocked);
        s.closeFile(live.lock);
        log.close();
        s.closeDir(live.dir);
    }

    /// Releases the lock and files without writing anything, as a process
    /// crash would, then frees the handle. Used when `openResume` fails
    /// midway, and by tests to simulate a crash.
    pub fn abandon(session: *Session) void {
        switch (session.phase) {
            .live => |live| session.release(live),
            .failed => |maybe_live| if (maybe_live) |live| session.release(live),
            .held, .closed => {},
        }
        session.phase = .closed;
        session.destroy();
    }

    /// Frees the handle. The session must be closed, and no other thread
    /// may still be using it.
    pub fn destroy(session: *Session) void {
        std.debug.assert(session.phase == .closed);
        const gpa = session.env.gpa;
        session.identity.deinit(gpa);
        session.state.deinit(gpa);
        session.held.deinit(gpa);
        session.batch.deinit(gpa);
        session.bounds.deinit(gpa);
        session.bodies.deinit(gpa);
        gpa.destroy(session);
    }
};

/// Blobs above this size are refused; the adapter keeps fx's own, smaller limits.
pub const max_blob_bytes: usize = 512 << 20;

/// An I/O fault as one byte, so a sync on another thread can hand its cause
/// to the next append through an atomic.
const FaultCode = enum(u8) { none, io, no_space, access_denied, read_only, too_big };

fn faultCode(fault: storage.IoFault) FaultCode {
    return switch (fault) {
        error.Io => .io,
        error.NoSpaceLeft => .no_space,
        error.AccessDenied => .access_denied,
        error.ReadOnlyFileSystem => .read_only,
        error.FileTooBig => .too_big,
    };
}

/// The I/O fault an append failed with, if it was one.
fn asIoFault(err: AppendError) ?storage.IoFault {
    return switch (err) {
        error.Io => error.Io,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.AccessDenied => error.AccessDenied,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.FileTooBig => error.FileTooBig,
        else => null,
    };
}

fn faultFromCode(code: u8) ?storage.IoFault {
    return switch (std.enums.fromInt(FaultCode, code) orelse .io) {
        .none => null,
        .io => error.Io,
        .no_space => error.NoSpaceLeft,
        .access_denied => error.AccessDenied,
        .read_only => error.ReadOnlyFileSystem,
        .too_big => error.FileTooBig,
    };
}

test "a fault code round trips every I/O fault, and none is no fault" {
    const faults = [_]storage.IoFault{ error.Io, error.NoSpaceLeft, error.AccessDenied, error.ReadOnlyFileSystem, error.FileTooBig };
    for (faults) |fault| try std.testing.expectEqual(fault, faultFromCode(@backingInt(faultCode(fault))).?);
    try std.testing.expectEqual(@as(?storage.IoFault, null), faultFromCode(@backingInt(FaultCode.none)));
}

fn hasBlobRefs(bodies: []const schema.Body) bool {
    for (bodies) |body| {
        if (body.blobRefs().len > 0) return true;
    }
    return false;
}

/// Copies the first `len` bytes of `from` into `to` in chunks and returns
/// their blob name. A source shorter than `len` is an I/O failure.
fn copyBlobFrom(env: *const Env, to: storage.File, from: std.Io.File, len: u64) AppendError![schema.blob_hash_len]u8 {
    const s = env.s;
    const buffer = try env.gpa.alloc(u8, @intCast(@min(len, Session.blob_copy_chunk_bytes)));
    defer env.gpa.free(buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (offset < len) {
        const want: usize = @intCast(@min(len - offset, buffer.len));
        const got = from.readPositional(s.io, &.{buffer[0..want]}, offset) catch return error.Io;
        if (got == 0) return error.Io;
        hasher.update(buffer[0..got]);
        s.writeAt(to, buffer[0..got], offset) catch |io_err| return storage.ioFault(io_err);
        offset += got;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// The copy fallback when a hard link is refused: the copy is synced
/// before the folder is.
fn copyBlob(env: *const Env, source: storage.Dir, target: storage.Dir, name: []const u8) AppendError!void {
    const s = env.s;
    const gpa = env.gpa;
    const from = s.openFile(source, name, .read_only) catch |io_err| return storage.ioFault(io_err);
    defer s.closeFile(from);
    const len = s.length(from) catch |io_err| return storage.ioFault(io_err);
    if (len > max_blob_bytes) return error.Io;
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    if ((s.readAt(from, bytes, 0) catch |io_err| return storage.ioFault(io_err)) != bytes.len) return error.Io;
    const to = s.createReadOnlyFile(target, name) catch |io_err| return storage.ioFault(io_err);
    defer s.closeFile(to);
    s.writeAt(to, bytes, 0) catch |io_err| return storage.ioFault(io_err);
    s.sync(to) catch |io_err| return storage.ioFault(io_err);
}

fn changesListing(events: []const fold.Event) bool {
    for (events) |event| switch (event) {
        .set => |s| if (s.key == .title or s.key == .workspace or s.key == .language) return true,
        else => {},
    };
    return false;
}

fn hasTurnStart(bodies: []const schema.Body) bool {
    for (bodies) |body| {
        if (body == .turn_started) return true;
    }
    return false;
}

/// Durability points (system-design.md "Durable State And Schema").
fn needsSync(bodies: []const schema.Body) bool {
    for (bodies) |body| switch (body) {
        .turn_committed, .turn_interrupted, .child_spawned, .child_finished => return true,
        // Usage is durable before fx clears its usage-recovery marker
        // (`tla/Wiring.tla` UsageNeverSilent).
        // fx removes the side folder only once the move is durable (D47).
        // Compactor records need no sync of their own: the compaction line
        // that cites them comes later in the log, which keeps a prefix (D50).
        .set => |s| switch (s.key) {
            .permissions, .usage, .moved_files => return true,
            .prefs, .title, .workspace, .language, .client_prompt, .tool_identities, .compaction_records => {},
        },
        else => {},
    };
    return false;
}

// ---------------------------------------------------------------------------
// Opening

pub const NewOptions = struct {
    workspace: []const u8,
    role: schema.Role = .root,
    host: schema.Host,
    parent: ?[]const u8 = null,
    forked_from: ?schema.ForkOrigin = null,
    /// Import (D8) keeps a v1 id; otherwise a fresh id is drawn.
    id: ?[]const u8 = null,
    /// Import only: the original creation time, stamped on line 1.
    created_ms: ?u64 = null,
};

/// A new session in memory. Nothing touches the disk until the first turn.
pub fn openNew(env: *const Env, options: NewOptions) error{OutOfMemory}!*Session {
    const gpa = env.gpa;
    var fresh_id: [schema.new_id_len]u8 = undefined;
    const id_ = options.id orelse blk: {
        schema.newId(env.s.io, &fresh_id);
        break :blk &fresh_id;
    };
    var identity = try Identity.fromCreated(gpa, .{
        .id = id_,
        .workspace = options.workspace,
        .role = options.role,
        .host = options.host,
        .parent = options.parent,
        .forked_from = options.forked_from,
    });
    errdefer identity.deinit(gpa);
    const session = try gpa.create(Session);
    session.* = .{ .env = env, .identity = identity, .phase = .held, .created_ms = options.created_ms };
    session.observe(.opened_new);
    return session;
}

pub const ResumeOptions = struct {
    id: []const u8,
    workspace: []const u8,
    host: schema.Host,
    /// Required to resume a child session.
    parent: ?[]const u8 = null,
    /// How long to wait for the flock before Busy; null uses the
    /// environment's `lock_wait_ms` (D38).
    lock_wait_ms: ?u64 = null,
};

/// Opens a published session for writing: the flock (else Busy after the
/// retry window), the tail cut, line 1, the newest snapshot and the tail
/// after it, then the crash repair and one sync. Cost does not grow with
/// the session's age.
pub fn openResume(env: *const Env, options: ResumeOptions) OpenError!*Session {
    var parts = try openParts(env, options);
    const session = env.gpa.create(Session) catch {
        parts.deinit(env);
        return error.OutOfMemory;
    };
    // Ownership of every part moves into the Session here.
    session.* = .{
        .env = env,
        .identity = parts.loaded.identity,
        .state = parts.loaded.state,
        .phase = .{ .live = .{ .dir = parts.dir, .log = parts.log, .lock = parts.lock } },
        .snapshot_base = parts.loaded.snapshot_end,
        .created_ms = parts.loaded.created_ms,
        .updated_ms = parts.loaded.updated_ms,
    };
    session.written_seq.store(session.env.s.io, session.state.last_seq);
    session.setSyncFile(parts.log.file, session.state.last_seq);
    repair(session, options.workspace) catch |err| {
        session.abandon();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => |io_err| storage.ioFault(io_err),
        };
    };
    return session;
}

const Parts = struct {
    dir: storage.Dir,
    lock: storage.File,
    log: Log,
    loaded: Loaded,

    fn deinit(p: *Parts, env: *const Env) void {
        p.loaded.deinit(env.gpa);
        p.log.close();
        env.s.closeFile(p.lock);
        env.s.closeDir(p.dir);
    }
};

/// Everything `openResume` needs before the Session exists; on error,
/// everything acquired so far is released here.
fn openParts(env: *const Env, options: ResumeOptions) OpenError!Parts {
    const s = env.s;
    const gpa = env.gpa;
    if (!schema.validId(options.id)) return error.NotFound;
    const dir = s.openDir(env.root, options.id) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        else => |io_err| storage.ioFault(io_err),
    };
    errdefer s.closeDir(dir);
    const lock = s.openFile(dir, "lock", .read_write) catch |err| return switch (err) {
        error.NotFound => error.Corrupt,
        else => |io_err| storage.ioFault(io_err),
    };
    errdefer s.closeFile(lock);
    if (!env.isPlanted(.skip_flock)) try acquireLock(env, lock, options.lock_wait_ms orelse env.options.lock_wait_ms);

    var opened = Log.open(gpa, s, dir, "log.jsonl", .read_write, .{}) catch |err| return switch (err) {
        error.NotFound => error.Corrupt,
        error.OutOfMemory => error.OutOfMemory,
        else => |io_err| storage.ioFault(io_err),
    };
    errdefer opened.log.close();
    if (opened.cut_bytes > 0) diag.report(env.diagnostics, .{
        .kind = .torn_tail_cut,
        .session_id = options.id,
        .count = opened.cut_bytes,
        .offset = opened.log.end,
    });
    switch (opened.verdict) {
        .clean, .torn => {},
        .corrupt => |c| {
            diag.report(env.diagnostics, .{ .kind = .opened_read_only, .session_id = options.id, .offset = c.at });
            return error.Corrupt;
        },
        .newer_version => |n| {
            diag.report(env.diagnostics, .{ .kind = .opened_read_only, .session_id = options.id, .offset = n.at });
            return error.UnsupportedVersion;
        },
    }
    if (opened.log.lineCount() == 0) return error.Corrupt;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var damaged_at: u64 = 0;
    var loaded = loadFolded(env, &arena_state, opened.log.file, opened.log.end, &damaged_at) catch |err| {
        // Damage behind the tail, found while folding: reported once here.
        if (err == error.Corrupt) diag.report(env.diagnostics, .{
            .kind = .opened_read_only,
            .session_id = options.id,
            .offset = damaged_at,
        });
        return err;
    };
    errdefer loaded.deinit(gpa);
    if (!std.mem.eql(u8, loaded.identity.id, options.id)) return error.Corrupt;
    if (loaded.identity.role == .child) {
        const parent = options.parent orelse return error.ChildSession;
        const own = loaded.identity.parent orelse return error.ChildSession;
        if (!std.mem.eql(u8, parent, own)) return error.ChildSession;
    }
    return .{ .dir = dir, .lock = lock, .log = opened.log, .loaded = loaded };
}

fn acquireLock(env: *const Env, lock: storage.File, wait_ms: u64) OpenError!void {
    const io = env.s.io;
    const step_ms: u64 = 10;
    var waited: u64 = 0;
    while (true) {
        if (env.s.tryLock(lock) catch |io_err| return storage.ioFault(io_err)) return;
        if (waited >= wait_ms) return error.Busy;
        io.sleep(.fromMilliseconds(@intCast(step_ms)), .awake) catch return error.Busy;
        waited += step_ms;
    }
}

const Loaded = struct {
    identity: Identity,
    state: fold.State,
    /// Log offset just past the newest snapshot, or 0.
    snapshot_end: u64,
    /// `ts` of line 1 and of the last line.
    created_ms: u64,
    updated_ms: u64,

    fn deinit(l: *Loaded, gpa: std.mem.Allocator) void {
        l.identity.deinit(gpa);
        l.state.deinit(gpa);
    }
};

/// Line 1, then the newest snapshot found scanning backward, then the tail
/// after it. Without a snapshot, the whole log is folded.
fn loadFolded(env: *const Env, arena_state: *std.heap.ArenaAllocator, file: storage.File, end: u64, damaged_at: *u64) OpenError!Loaded {
    const gpa = env.gpa;
    const arena = arena_state.allocator();
    var first = log_mod.ForwardReader.init(gpa, env.s, file, 0, end, 1);
    defer first.deinit();
    const line1 = (first.next() catch |err| {
        damaged_at.* = first.damaged_at orelse 0;
        return mapRead(err);
    }) orelse return error.Corrupt;
    if (line1.header.kind != .session_created) return error.Corrupt;
    const created = schema.parseBody(arena, .session_created, line1.body()) catch return error.Corrupt;
    var identity = try Identity.fromCreated(gpa, created.session_created);
    errdefer identity.deinit(gpa);
    const line1_end = line1.offset + line1.bytes.len;

    // The newest snapshot, scanning back from the end.
    var snapshot: ?struct { seq: u64, end: u64, state: []const u8, ts_ms: u64 } = null;
    {
        var back = log_mod.BackwardReader.init(gpa, env.s, file, end);
        defer back.deinit();
        while (back.next() catch |err| {
            damaged_at.* = back.damaged_at orelse 0;
            return mapRead(err);
        }) |line| {
            if (line.offset < line1_end) break;
            if (line.header.kind != .snapshot) continue;
            const body = schema.parseBody(arena, .snapshot, line.body()) catch return error.Corrupt;
            snapshot = .{ .seq = line.header.seq, .end = line.offset + line.bytes.len, .state = body.snapshot.state, .ts_ms = line.header.ts_ms };
            break;
        }
    }

    var state: fold.State = .{};
    errdefer state.deinit(gpa);
    const fork_seq = identity.forkSeq();
    var from = line1_end;
    var expected: u64 = 2;
    state.last_seq = 1;
    if (snapshot) |snap| {
        state = fold.decodeState(gpa, arena, snap.state) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadBody => error.Corrupt,
        };
        // A snapshot copied from a fork's source carries the source's children.
        if (snap.seq <= fork_seq) state.clearChildren(gpa);
        state.last_seq = snap.seq;
        from = snap.end;
        expected = snap.seq + 1;
    }
    var updated_ms = if (snapshot) |snap| snap.ts_ms else line1.header.ts_ms;
    const created_ms = line1.header.ts_ms;
    var tail = log_mod.ForwardReader.init(gpa, env.s, file, from, end, expected);
    defer tail.deinit();
    var line_arena = std.heap.ArenaAllocator.init(gpa);
    defer line_arena.deinit();
    while (tail.next() catch |err| {
        damaged_at.* = tail.damaged_at orelse 0;
        return mapRead(err);
    }) |line| {
        _ = line_arena.reset(.retain_capacity);
        updated_ms = line.header.ts_ms;
        const kind = line.header.kind orelse {
            state.last_seq = line.header.seq; // unknown kinds are skipped
            state.clean_exit = false;
            continue;
        };
        const body = schema.parseBody(line_arena.allocator(), kind, line.body()) catch return error.Corrupt;
        try fold.apply(gpa, &state, fork_seq, .{ .seq = line.header.seq, .offset = line.offset, .body = body });
    }
    return .{
        .identity = identity,
        .state = state,
        .snapshot_end = if (snapshot) |snap| snap.end else 0,
        .created_ms = created_ms,
        // A fork's copied lines keep the source's older times (D20).
        .updated_ms = @max(updated_ms, created_ms),
    };
}

fn mapRead(err: log_mod.ReadError) OpenError {
    return switch (err) {
        error.Corrupt => error.Corrupt,
        error.OutOfMemory => error.OutOfMemory,
        else => |io_err| storage.ioFault(io_err),
    };
}

/// Crash repair at the end of `openResume` (D1, `tla/Subagents.tla`).
fn repair(session: *Session, workspace: []const u8) AppendError!void {
    const gpa = session.env.gpa;
    const live = &session.phase.live;
    const ts = session.timestamp();
    // An open turn from the previous owner is interrupted (D1).
    if (session.state.open_turn) |turn| {
        try session.writeBodies(live, &.{.{ .turn_interrupted = .{ .turn = turn, .reason = .crash } }}, ts, .interrupt_repair);
    }
    session.observe(.reopened);
    // Every unfinished work item gets a known outcome (tla/Subagents.tla).
    var finished: std.ArrayList(schema.Body) = .empty;
    defer finished.deinit(gpa);
    for (session.state.children.items) |child| {
        if (!child.open) continue;
        const has_log = childHasLog(session.env, child.id);
        try finished.append(gpa, .{ .child_finished = .{
            .child = child.id,
            .work_id = child.work_id,
            .outcome = if (has_log) .interrupted else .lost,
        } });
    }
    if (finished.items.len > 0) {
        // `writeBodies` folds the lines, which updates the children the
        // bodies borrow from; frame from copies.
        var copies = std.heap.ArenaAllocator.init(gpa);
        defer copies.deinit();
        for (finished.items) |*body| {
            body.child_finished.child = try copies.allocator().dupe(u8, body.child_finished.child);
            body.child_finished.work_id = try copies.allocator().dupe(u8, body.child_finished.work_id);
        }
        if (session.env.isPlanted(.repair_marks_child_twice)) {
            // Copied first: appending may move the list it came from.
            const twice = finished.items[0];
            try finished.append(gpa, twice);
        }
        try session.writeBodies(live, finished.items, ts, .child_repair);
    }
    // Resumed from another workspace: record it.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    if (!std.mem.eql(u8, try currentWorkspace(session, scratch.allocator()), workspace)) {
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(gpa);
        try schema.appendJsonString(gpa, &value, workspace);
        try session.writeBodies(live, &.{.{ .set = .{ .key = .workspace, .value = value.items } }}, ts, .workspace_repair);
    }
    try session.syncThrough(session.state.last_seq);
}

/// The workspace in effect: the newest `set workspace`, else line 1's.
/// The result may point into `arena` or into the session.
pub fn currentWorkspace(session: *const Session, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const raw = session.state.workspace orelse return session.identity.workspace;
    return std.json.parseFromSliceLeaky([]const u8, arena, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not a JSON string: compare the raw bytes, which never match a path.
        else => raw,
    };
}

fn childHasLog(env: *const Env, child: []const u8) bool {
    if (!schema.validId(child)) return false;
    const dir = env.s.openDir(env.root, child) catch return false;
    defer env.s.closeDir(dir);
    _ = env.s.stat(dir, "log.jsonl") catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Reading (lock-free)

/// A position between two lines.
pub const Cursor = struct {
    /// A line boundary in the log.
    offset: u64,
    /// Seq of the line that starts at `offset`.
    seq: u64,
};

pub const From = union(enum) { start, end, at: Cursor };
pub const Direction = enum { forward, backward };

pub const Entry = struct {
    seq: u64,
    /// Byte offset of the line: a `Cursor` for reading from it.
    offset: u64,
    ts_ms: u64,
    kind: ?schema.Kind,
    kind_name: []const u8,
    /// Parsed fields; null for a kind this version does not know.
    body: ?schema.Body,
};

/// One page of lines. Owns everything it points to; free with `deinit`.
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    /// In reading order: oldest first forward, newest first backward.
    entries: []Entry,
    /// Where the next page in the same direction starts; null at the end.
    next: ?Cursor,
    /// Reading stopped at a damaged line: nothing past it can be trusted.
    damaged: bool,

    pub fn deinit(page: *Page) void {
        page.arena.deinit();
    }
};

pub const ReadError = error{ NotFound, OutOfMemory } || storage.IoFault;

/// Reads up to `limit` lines of any session without taking its lock. Only
/// complete, valid lines are returned; written lines never change, so a
/// concurrent writer cannot disturb a reader.
pub fn readPage(
    env: *const Env,
    gpa: std.mem.Allocator,
    id_: []const u8,
    from: From,
    direction: Direction,
    limit: usize,
) ReadError!Page {
    const s = env.s;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        else => |io_err| storage.ioFault(io_err),
    };
    defer s.closeDir(dir);
    const file = s.openFile(dir, "log.jsonl", .read_only) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        else => |io_err| storage.ioFault(io_err),
    };
    defer s.closeFile(file);
    const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
    const end = log_mod.lastLineEnd(s, file, len) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |io_err| storage.ioFault(io_err),
    };
    return readLines(s, gpa, file, end, from, direction, limit);
}

/// A page of the lines before `end` in an open log, shared by the read by
/// id and `Session.readPage`. The caller keeps `file` open throughout.
/// Entries of a page allocated up front, without the safety fill.
const max_raw_page_entries = 1024;

fn readLines(
    s: storage.Storage,
    gpa: std.mem.Allocator,
    file: storage.File,
    end: u64,
    from: From,
    direction: Direction,
    limit: usize,
) (error{OutOfMemory} || storage.IoFault)!Page {
    var page: Page = .{ .arena = .init(gpa), .entries = &.{}, .next = null, .damaged = false };
    errdefer page.arena.deinit();
    const arena = page.arena.allocator();
    // Raw, as `log.ReadBuffer` explains: every entry is written in full
    // before it is read. A longer page grows the list as usual.
    const first_capacity: usize = @min(limit, max_raw_page_entries);
    const first_memory = arena.rawAlloc(first_capacity * @sizeOf(Entry), .of(Entry), @returnAddress()) orelse return error.OutOfMemory;
    const first_entries: [*]Entry = @ptrCast(@alignCast(first_memory));
    var entries: std.ArrayList(Entry) = .initBuffer(first_entries[0..first_capacity]);
    switch (direction) {
        .forward => {
            const at: Cursor = switch (from) {
                .start => .{ .offset = 0, .seq = 1 },
                .end => return page,
                .at => |c| c,
            };
            var reader = log_mod.ForwardReader.init(gpa, s, file, at.offset, end, at.seq);
            defer reader.deinit();
            var last: ?Cursor = null;
            while (entries.items.len < limit) {
                const line = reader.next() catch |err| switch (err) {
                    error.Corrupt => {
                        page.damaged = true;
                        break;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |io_err| return storage.ioFault(io_err),
                } orelse break;
                try entries.append(arena, try copyEntry(arena, line));
                last = .{ .offset = line.offset + line.bytes.len, .seq = line.header.seq + 1 };
            }
            if (!page.damaged and entries.items.len == limit) {
                if (last) |c| if (c.offset < end) {
                    page.next = c;
                };
            }
        },
        .backward => {
            var reader = switch (from) {
                .start => return page,
                .end => log_mod.BackwardReader.init(gpa, s, file, end),
                .at => |c| blk: {
                    var r = log_mod.BackwardReader.init(gpa, s, file, c.offset);
                    r.expected_seq = if (c.seq > 1) c.seq - 1 else null;
                    break :blk r;
                },
            };
            defer reader.deinit();
            var oldest: ?Cursor = null;
            while (entries.items.len < limit) {
                const line = reader.next() catch |err| switch (err) {
                    error.Corrupt => {
                        page.damaged = true;
                        break;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |io_err| return storage.ioFault(io_err),
                } orelse break;
                try entries.append(arena, try copyEntry(arena, line));
                oldest = .{ .offset = line.offset, .seq = line.header.seq };
            }
            if (!page.damaged and entries.items.len == limit) {
                if (oldest) |c| if (c.offset > 0) {
                    page.next = c;
                };
            }
        },
    }
    page.entries = entries.items;
    return page;
}

fn copyEntry(arena: std.mem.Allocator, line: log_mod.Line) error{OutOfMemory}!Entry {
    // The reader's buffer is reused on the next line: copy before parsing.
    // Raw, as `log.ReadBuffer` explains: the copy writes every byte.
    const bytes = (arena.rawAlloc(line.bytes.len, .@"1", @returnAddress()) orelse return error.OutOfMemory)[0..line.bytes.len];
    @memcpy(bytes, line.bytes);
    // The reader checked the line; only the header's name moves.
    var header = line.header;
    header.kind_name = bytes[@intFromPtr(header.kind_name.ptr) - @intFromPtr(line.bytes.ptr) ..][0..header.kind_name.len];
    const kind = header.kind;
    const body: ?schema.Body = if (kind) |k|
        schema.parseLineBody(arena, k, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadBody => null,
        }
    else
        null;
    return .{ .seq = header.seq, .offset = line.offset, .ts_ms = header.ts_ms, .kind = kind, .kind_name = header.kind_name, .body = body };
}

// ---------------------------------------------------------------------------
// Blobs, fork and delete

pub const BlobError = error{ NotFound, Corrupt, OutOfMemory } || storage.IoFault;

/// Reads a blob of any session without a lock. The bytes are checked
/// against their name, so a damaged blob is reported, never returned.
/// The caller owns the result.
pub fn readBlob(env: *const Env, gpa: std.mem.Allocator, id_: []const u8, hash: []const u8) BlobError![]u8 {
    const s = env.s;
    if (!schema.validId(id_) or !schema.validBlobHash(hash)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    const blobs = s.openDir(dir, "blobs") catch |err| return notFoundOr(err);
    defer s.closeDir(blobs);
    const file = s.openFile(blobs, hash, .read_only) catch |err| return notFoundOr(err);
    defer s.closeFile(file);
    const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
    if (len > max_blob_bytes) return error.Corrupt;
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    if ((s.readAt(file, bytes, 0) catch |io_err| return storage.ioFault(io_err)) != bytes.len) return error.Io;
    const actual = schema.blobHash(bytes);
    if (!std.mem.eql(u8, &actual, hash)) return error.Corrupt;
    return bytes;
}

/// Whether session `id_` holds a regular blob file named `hash`; its bytes
/// are not read (D49).
pub fn blobExists(env: *const Env, id_: []const u8, hash: []const u8) (error{NotFound} || storage.IoFault)!void {
    const s = env.s;
    if (!schema.validId(id_) or !schema.validBlobHash(hash)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    const blobs = s.openDir(dir, "blobs") catch |err| return notFoundOr(err);
    defer s.closeDir(blobs);
    const st = s.stat(blobs, hash) catch |err| return notFoundOr(err);
    if (st.kind != .file) return error.NotFound;
}

fn notFoundOr(err: storage.Error) (error{NotFound} || storage.IoFault) {
    return if (err == error.NotFound) error.NotFound else error.Io;
}

/// Whether a blob of session `id_` is present and matches its name. A
/// missing or damaged one damages its session like a bad line (D39).
fn blobIsWhole(env: *const Env, id_: []const u8, hash: []const u8) (error{OutOfMemory} || storage.IoFault)!bool {
    const bytes = readBlob(env, env.gpa, id_, hash) catch |err| switch (err) {
        error.NotFound, error.Corrupt => return false,
        else => |e| return e,
    };
    env.gpa.free(bytes);
    return true;
}

pub const ForkPoint = union(enum) {
    /// The end of this turn; 0 means before the first turn.
    turn: u64,
    /// The last turn that ended before any damage (`fx session recover`, D15).
    last_good,
};

pub const ForkOptions = struct {
    source: []const u8,
    at: ForkPoint,
    workspace: []const u8,
    host: schema.Host,
};

pub const ForkError = OpenError || error{InvalidForkPoint};

/// A new root session whose lines 2..S are the source's, unchanged, where
/// S ends a turn (D5). The source is read without its lock and never
/// changed; a damaged source forks up to its last good turn. Every source
/// blob is hard-linked (D6), so the fork stays whole if the source goes.
pub fn openFork(env: *const Env, options: ForkOptions) ForkError!*Session {
    const s = env.s;
    const gpa = env.gpa;
    if (!schema.validId(options.source)) return error.NotFound;
    const src_dir = s.openDir(env.root, options.source) catch |err| return notFoundOr(err);
    defer s.closeDir(src_dir);
    const src = s.openFile(src_dir, "log.jsonl", .read_only) catch |err| return switch (err) {
        error.NotFound => error.Corrupt,
        else => |io_err| storage.ioFault(io_err),
    };
    defer s.closeFile(src);
    const len = s.length(src) catch |io_err| return storage.ioFault(io_err);
    const end = log_mod.lastLineEnd(s, src, len) catch return error.Corrupt;
    const point = try findForkPoint(env, options.source, src, end, options.at);

    const session = try openNew(env, .{
        .workspace = options.workspace,
        .host = options.host,
        .forked_from = .{ .id = options.source, .seq = point.seq },
    });
    errdefer {
        session.phase = .closed;
        session.destroy();
    }
    // Line 1 is new; lines 2..S are copied (see `copyFolded`).
    session.batch.clearRetainingCapacity();
    session.bounds.clearRetainingCapacity();
    const created = env.nowMs();
    session.frameMarked(1, created, .{ .session_created = session.identity.created() }) catch |err| return forkError(err);
    session.created_ms = created;
    const copied = try gpa.alloc(u8, @intCast(point.end - point.line1_end));
    defer gpa.free(copied);
    if ((s.readAt(src, copied, point.line1_end) catch |io_err| return storage.ioFault(io_err)) != copied.len) return error.Io;
    copyFolded(session, copied, point.seq) catch |err| return forkError(err);
    const blobs = s.openDir(src_dir, "blobs") catch |err| switch (err) {
        error.NotFound => null,
        else => |io_err| return storage.ioFault(io_err),
    };
    defer if (blobs) |b| s.closeDir(b);
    const live = session.stage(blobs) catch |err| return forkError(err);
    session.phase = .{ .live = live };
    session.wrote(created);
    session.written_seq.store(session.env.s.io, point.seq);
    session.setSyncFile(live.log.file, point.seq);
    return session;
}

fn forkError(err: AppendError) ForkError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Copied lines were checked on read; anything else is an I/O failure.
        error.InvalidTransition, error.SessionClosed, error.TooLarge => error.Io,
        else => |io_err| storage.ioFault(io_err),
    };
}

const ForkPointFound = struct {
    seq: u64,
    /// Offset just past line S in the source.
    end: u64,
    /// Offset just past line 1 in the source.
    line1_end: u64,
};

/// Pass 1 of a fork: where S is. Reading stops at the first damage: a bad
/// line, or a line naming a missing or damaged blob (D39).
fn findForkPoint(env: *const Env, source: []const u8, src: storage.File, end: u64, at: ForkPoint) ForkError!ForkPointFound {
    const gpa = env.gpa;
    var reader = log_mod.ForwardReader.init(gpa, env.s, src, 0, end, 1);
    defer reader.deinit();
    const line1 = (reader.next() catch |err| return mapRead(err)) orelse return error.Corrupt;
    if (line1.header.kind != .session_created) return error.Corrupt;
    const line1_end = line1.offset + line1.bytes.len;
    var before_first_turn: ForkPointFound = .{ .seq = 1, .end = line1_end, .line1_end = line1_end };
    var turn_seen = false;
    var last_end: ?ForkPointFound = null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (true) {
        const line = (reader.next() catch |err| switch (err) {
            error.Corrupt => break, // the good part ends here (D15)
            error.OutOfMemory => return error.OutOfMemory,
            else => |io_err| return storage.ioFault(io_err),
        }) orelse break;
        const here: ForkPointFound = .{ .seq = line.header.seq, .end = line.offset + line.bytes.len, .line1_end = line1_end };
        const kind = line.header.kind orelse continue;
        switch (kind) {
            .turn_started => turn_seen = true,
            .item, .set => {
                _ = arena.reset(.retain_capacity);
                const body = schema.parseBody(arena.allocator(), kind, line.body()) catch return error.Corrupt;
                var whole = true;
                for (body.blobRefs()) |hash| {
                    if (!try blobIsWhole(env, source, hash)) whole = false;
                }
                if (!whole) break;
            },
            .turn_committed, .turn_interrupted => {
                _ = arena.reset(.retain_capacity);
                const body = schema.parseBody(arena.allocator(), kind, line.body()) catch return error.Corrupt;
                const turn = switch (body) {
                    .turn_committed => |t| t.turn,
                    .turn_interrupted => |t| t.turn,
                    else => unreachable,
                };
                last_end = here;
                if (at == .turn and at.turn == turn) return here;
            },
            else => {},
        }
        if (!turn_seen) before_first_turn = here;
    }
    return switch (at) {
        .turn => |turn| if (turn == 0) before_first_turn else error.InvalidForkPoint,
        .last_good => last_end orelse error.InvalidForkPoint,
    };
}

/// Pass 2 of a fork: appends the source's lines 2..S to the batch and folds
/// each at its offset in the fork. Lines are copied byte for byte, so their
/// crc holds, except snapshots: a snapshot records byte offsets, and the
/// fork's line 1 has a different length, so each snapshot is encoded again
/// from the fork's own fold at that point, with the same seq and time.
fn copyFolded(session: *Session, copied: []const u8, fork_seq: u64) AppendError!void {
    const gpa = session.env.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    var at: usize = 0;
    while (std.mem.findScalarPos(u8, copied, at, '\n')) |nl| : (at = nl + 1) {
        _ = arena.reset(.retain_capacity);
        const source_line = copied[at .. nl + 1];
        const source_header = log_mod.checkLine(source_line) catch |io_err| return storage.ioFault(io_err);
        const start = session.batch.items.len;
        if (source_header.kind == .snapshot) {
            encoded.clearRetainingCapacity();
            try session.frameMarked(source_header.seq, source_header.ts_ms, try session.snapshotBody(&encoded));
        } else {
            try session.batch.appendSlice(gpa, source_line);
            try session.bounds.append(gpa, session.batch.items.len);
        }
        const line = session.batch.items[start..];
        const header = log_mod.checkLine(line) catch unreachable;
        if (header.kind) |kind| {
            const body = schema.parseBody(arena.allocator(), kind, log_mod.lineBody(line, header)) catch |io_err| return storage.ioFault(io_err);
            try fold.apply(gpa, &session.state, fork_seq, .{ .seq = header.seq, .offset = start, .body = body });
            if (kind == .snapshot) session.snapshot_base = session.batch.items.len;
        } else {
            session.state.last_seq = header.seq;
        }
    }
    // The fork owns no children spawned before its fork point.
    std.debug.assert(session.state.children.items.len == 0);
}

pub const DeleteError = error{ NotFound, Busy, OutOfMemory } || storage.IoFault;

/// The child ids a session owns, from its `child_spawned` lines. The
/// caller frees each id and the list.
pub fn childrenOf(env: *const Env, id_: []const u8) DeleteError![][]u8 {
    const s = env.s;
    const gpa = env.gpa;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    var children: std.ArrayList([]u8) = .empty;
    errdefer {
        for (children.items) |c| gpa.free(c);
        children.deinit(gpa);
    }
    try collectChildren(env, dir, &children);
    return children.toOwnedSlice(gpa);
}

/// Step 1 of a delete (`tla/Catalog.tla` `Trash`): Busy if the session is
/// open anywhere, else it is renamed to `.trash/{id}`, which makes it gone
/// for everyone at once. The caller then appends the index tombstone and
/// calls `purgeTrashed`; owned children are deleted first (`childrenOf`),
/// so a Busy child never leaves an orphan.
pub fn trashSession(env: *const Env, id_: []const u8) DeleteError!void {
    const s = env.s;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    var dir_open = true;
    defer if (dir_open) s.closeDir(dir);
    const lock = s.openFile(dir, "lock", .read_write) catch |err| switch (err) {
        error.NotFound => null,
        else => |io_err| return storage.ioFault(io_err),
    };
    defer if (lock) |l| s.closeFile(l);
    if (lock) |l| if (!(s.tryLock(l) catch |io_err| return storage.ioFault(io_err))) return error.Busy;
    const trash = s.ensureDir(env.root, ".trash") catch |io_err| return storage.ioFault(io_err);
    defer s.closeDir(trash);
    s.deleteTree(trash, id_) catch |io_err| return storage.ioFault(io_err);
    s.closeDir(dir);
    dir_open = false;
    s.rename(env.root, id_, trash, id_) catch |err| return notFoundOr(err);
    s.syncDir(env.root) catch |io_err| return storage.ioFault(io_err);
    env.observeCatalog(id_, .trashed);
}

/// Step 3 of a delete (`Purge`): removes `.trash/{id}` and everything in it.
pub fn purgeTrashed(env: *const Env, id_: []const u8) DeleteError!void {
    const s = env.s;
    const trash = s.openDir(env.root, ".trash") catch |err| return notFoundOr(err);
    defer s.closeDir(trash);
    s.deleteTree(trash, id_) catch |io_err| return storage.ioFault(io_err);
    env.observeCatalog(id_, .purged);
}

/// Whether a session with this id is open for writing anywhere.
pub fn isBusy(env: *const Env, id_: []const u8) DeleteError!bool {
    const s = env.s;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    const lock = s.openFile(dir, "lock", .read_write) catch |err| return switch (err) {
        error.NotFound => false,
        else => |io_err| storage.ioFault(io_err),
    };
    defer s.closeFile(lock);
    if (!(s.tryLock(lock) catch |io_err| return storage.ioFault(io_err))) return true;
    s.unlock(lock);
    return false;
}

/// The distinct child ids named by `child_spawned` lines.
fn collectChildren(env: *const Env, dir: storage.Dir, out: *std.ArrayList([]u8)) DeleteError!void {
    const s = env.s;
    const gpa = env.gpa;
    const file = s.openFile(dir, "log.jsonl", .read_only) catch |err| return switch (err) {
        error.NotFound => {},
        else => |io_err| storage.ioFault(io_err),
    };
    defer s.closeFile(file);
    const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
    var reader = log_mod.ForwardReader.init(gpa, s, file, 0, len, 1);
    defer reader.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    while (true) {
        const line = (reader.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break, // a damaged log still deletes; its later children are not found
        }) orelse break;
        if (line.header.kind != .child_spawned) continue;
        _ = arena.reset(.retain_capacity);
        const body = schema.parseBody(arena.allocator(), .child_spawned, line.body()) catch continue;
        const child = body.child_spawned.child;
        for (out.items) |known| {
            if (std.mem.eql(u8, known, child)) break;
        } else try out.append(gpa, try gpa.dupe(u8, child));
    }
}

// ---------------------------------------------------------------------------
// Doctor

pub const Verified = struct {
    lines: u64,
    /// Offset of the first damaged line, if any; lines past it were not checked.
    damaged_at: ?u64,
    /// Snapshots whose state differs from the fold at their position.
    bad_snapshots: u64,
    /// Blobs a line names that are missing or fail their hash (D39).
    bad_blobs: u64 = 0,
};

/// Reads a whole log without its lock: every line's frame, checksum and
/// seq, and every snapshot against the fold at its position (a snapshot is
/// a cache that must equal what it replaces).
pub fn verifySession(env: *const Env, id_: []const u8) OpenError!Verified {
    const s = env.s;
    const gpa = env.gpa;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    const file = s.openFile(dir, "log.jsonl", .read_only) catch |err| return notFoundOr(err);
    defer s.closeFile(file);
    const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
    const end = log_mod.lastLineEnd(s, file, len) catch return error.Corrupt;
    var reader = log_mod.ForwardReader.init(gpa, s, file, 0, end, 1);
    defer reader.deinit();
    var state: fold.State = .{};
    defer state.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var result: Verified = .{ .lines = 0, .damaged_at = null, .bad_snapshots = 0 };
    var fork_seq: u64 = 0;
    while (true) {
        const line = (reader.next() catch |err| switch (err) {
            error.Corrupt => {
                result.damaged_at = reader.damaged_at;
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => |io_err| return storage.ioFault(io_err),
        }) orelse break;
        result.lines += 1;
        _ = arena.reset(.retain_capacity);
        const kind = line.header.kind orelse continue;
        const body = schema.parseBody(arena.allocator(), kind, line.body()) catch {
            result.damaged_at = line.offset;
            break;
        };
        for (body.blobRefs()) |hash| {
            if (!try blobIsWhole(env, id_, hash)) result.bad_blobs += 1;
        }
        switch (body) {
            .session_created => |c| fork_seq = if (c.forked_from) |o| o.seq else 0,
            .snapshot => |snap| {
                var decoded = fold.decodeState(gpa, arena.allocator(), snap.state) catch {
                    result.bad_snapshots += 1;
                    continue;
                };
                defer decoded.deinit(gpa);
                decoded.last_seq = state.last_seq;
                decoded.clean_exit = state.clean_exit;
                // A snapshot copied from a fork's source carries its children.
                if (line.header.seq <= fork_seq) decoded.clearChildren(gpa);
                if (!decoded.eql(&state)) result.bad_snapshots += 1;
            },
            else => {},
        }
        try fold.apply(gpa, &state, fork_seq, .{ .seq = line.header.seq, .offset = line.offset, .body = body });
    }
    return result;
}

/// What the catalog records about one session, read without its lock.
pub const Summary = struct {
    identity: Identity,
    state: fold.State,
    created_ms: u64,
    updated_ms: u64,

    pub fn deinit(summary: *Summary, gpa: std.mem.Allocator) void {
        summary.identity.deinit(gpa);
        summary.state.deinit(gpa);
    }
};

/// Line 1, the newest snapshot and the tail of a session, read-only.
pub fn readSummary(env: *const Env, id_: []const u8) OpenError!Summary {
    const s = env.s;
    const gpa = env.gpa;
    if (!schema.validId(id_)) return error.NotFound;
    const dir = s.openDir(env.root, id_) catch |err| return notFoundOr(err);
    defer s.closeDir(dir);
    const file = s.openFile(dir, "log.jsonl", .read_only) catch |err| return notFoundOr(err);
    defer s.closeFile(file);
    const len = s.length(file) catch |io_err| return storage.ioFault(io_err);
    const end = log_mod.lastLineEnd(s, file, len) catch return error.Corrupt;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var damaged_at: u64 = 0;
    const loaded = try loadFolded(env, &arena_state, file, end, &damaged_at);
    return .{ .identity = loaded.identity, .state = loaded.state, .created_ms = loaded.created_ms, .updated_ms = loaded.updated_ms };
}

const session_tests = struct {
    //! L2 behavior, through the Session only: data-flow.md scenarios 1 to 3 and
    //! 5 to 11. Runs with and without hooks; fault-only cases skip without.

    const session_mod = @import("session.zig");

    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const Fault = storage.Fault;

    pub const TestEnv = struct {
        tmp: testing.TmpDir,
        fault: if (hooks) Fault else void,
        recorder: diag.Recorder,
        env: session_mod.Env,
        /// Set by `crash`: a crash closes written files unsynced by definition.
        crashed: bool = false,

        /// In place: `env` points into `t`, so `t` must not move afterwards.
        pub fn init(t: *TestEnv, options: session_mod.Options) void {
            t.crashed = false;
            t.tmp = testing.tmpDir(.{ .iterate = true });
            t.recorder = .{ .gpa = gpa, .io = io };
            if (hooks) t.fault = .init(gpa, io, 1);
            t.env = .{
                .gpa = gpa,
                .s = if (hooks) .{ .io = io, .fault = &t.fault } else .{ .io = io },
                .root = .{ .handle = t.tmp.dir },
                .options = options,
                .diagnostics = t.recorder.sink(),
            };
        }

        pub fn deinit(t: *TestEnv) void {
            if (hooks) {
                // Every written file was closed only after a sync.
                if (!t.crashed) testing.expectEqual(@as(usize, 0), t.fault.closed_unsynced) catch @panic("a written file was closed unsynced");
                t.fault.deinit();
            }
            t.recorder.deinit();
            t.tmp.cleanup();
        }

        pub fn kinds(t: *TestEnv, id: []const u8) ![]schema.Kind {
            var page = try session_mod.readPage(&t.env, gpa, id, .start, .forward, 1 << 20);
            defer page.deinit();
            const out = try gpa.alloc(schema.Kind, page.entries.len);
            for (page.entries, 0..) |entry, i| {
                try testing.expectEqual(@as(u64, i + 1), entry.seq);
                out[i] = entry.kind.?;
            }
            return out;
        }
    };

    /// fx dies: nothing more is written, and the kernel drops the flock.
    fn crash(t: *TestEnv, s: *Session) void {
        t.crashed = true;
        s.abandon();
    }

    fn expectKinds(t: *TestEnv, id: []const u8, expected: []const schema.Kind) !void {
        const got = try t.kinds(id);
        defer gpa.free(got);
        try testing.expectEqualSlices(schema.Kind, expected, got);
    }

    fn newRoot(t: *TestEnv) !*Session {
        return session_mod.openNew(&t.env, .{ .workspace = "/w", .host = .app });
    }

    fn resumeRoot(t: *TestEnv, id: []const u8) !*Session {
        return session_mod.openResume(&t.env, .{ .id = id, .workspace = "/w", .host = .app });
    }

    fn closeAndDestroy(s: *Session) !void {
        try s.close();
        s.destroy();
    }

    /// Delete as L3 composes it, minus the index: children first, then trash
    /// and purge.
    pub fn deleteWithoutIndex(env: *const session_mod.Env, id: []const u8) session_mod.DeleteError!void {
        const children = try session_mod.childrenOf(env, id);
        defer {
            for (children) |c| env.gpa.free(c);
            env.gpa.free(children);
        }
        for (children) |child| deleteWithoutIndex(env, child) catch |err| switch (err) {
            error.NotFound => {},
            else => return err,
        };
        try session_mod.trashSession(env, id);
        try session_mod.purgeTrashed(env, id);
    }

    const item: fold.Event = .{ .item = .{ .type = "assistant", .data = "{\"text\":\"piece\"}" } };

    test "a session that never starts a turn leaves nothing on disk" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{.{ .set = .{ .key = .title, .value = "\"draft\"" } }});
        try testing.expectError(error.InvalidTransition, s.append(&.{item}));
        try closeAndDestroy(s);
        var listing = t.env.s.list(t.env.root);
        try testing.expectEqual(@as(?storage.Entry, null), try listing.next());
        try testing.expectEqual(@as(usize, 1), t.recorder.count(.held_lines_dropped));
    }

    test "the first turn publishes line 1, the held settings and the batch" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{.{ .set = .{ .key = .title, .value = "\"hello\"" } }});
        try testing.expectEqual(@as(u64, 4), try s.append(&.{ .turn_started, item }));
        const dir = try t.env.s.openDir(t.env.root, s.id());
        defer t.env.s.closeDir(dir);
        try testing.expectEqual(storage.Kind.file, (try t.env.s.stat(dir, "lock")).kind);
        try testing.expectEqual(storage.Kind.directory, (try t.env.s.stat(dir, "blobs")).kind);
        // The staging folder is empty again.
        const tmp = try t.env.s.openDir(t.env.root, ".tmp");
        defer t.env.s.closeDir(tmp);
        var listing = t.env.s.list(tmp);
        try testing.expectEqual(@as(?storage.Entry, null), try listing.next());

        try expectKinds(&t, s.id(), &.{ .session_created, .set, .turn_started, .item });
        _ = try s.append(&.{.turn_committed});
        var state = try s.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqualStrings("\"hello\"", state.title.?);
        try testing.expectEqual(@as(u64, 1), state.committed);
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        try closeAndDestroy(s);
        try expectKinds(&t, id, &.{ .session_created, .set, .turn_started, .item, .turn_committed, .closed });
    }

    test "a refused batch writes nothing" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        defer closeAndDestroy(s) catch {};
        _ = try s.append(&.{.turn_started});
        try testing.expectError(error.InvalidTransition, s.append(&.{ item, .turn_started }));
        try testing.expectError(error.InvalidTransition, s.append(&.{ .turn_committed, .turn_committed }));
        try expectKinds(&t, s.id(), &.{ .session_created, .turn_started });
    }

    test "a crash leaves an open turn, and resume interrupts it" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{ .turn_started, item });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        crash(&t, s);

        const r = try resumeRoot(&t, id);
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(?u64, null), state.open_turn);
        try testing.expectEqual(schema.Reason.crash, state.last_interrupted.?.reason);
        try testing.expect(!state.clean_exit);
        // The next turn is turn 2.
        _ = try r.append(&.{ .turn_started, item, .turn_committed });
        var after = try r.stateCopy(gpa);
        defer after.deinit(gpa);
        try testing.expectEqual(@as(u64, 2), after.last_turn);
        try closeAndDestroy(r);
        try expectKinds(&t, id, &.{ .session_created, .turn_started, .item, .turn_interrupted, .turn_started, .item, .turn_committed, .closed });
    }

    test "a second writer gets Busy while the first holds the session" {
        var t: TestEnv = undefined;
        t.init(.{ .lock_wait_ms = 30 });
        defer t.deinit();
        const s = try newRoot(&t);
        defer closeAndDestroy(s) catch {};
        _ = try s.append(&.{ .turn_started, .turn_committed });
        try testing.expectError(error.Busy, resumeRoot(&t, s.id()));
        try testing.expectError(error.NotFound, resumeRoot(&t, "missing"));
    }

    test "close interrupts an open turn, and later calls get SessionClosed" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{ .turn_started, item });
        try s.close();
        try testing.expectError(error.SessionClosed, s.append(&.{item}));
        try s.close();
        try expectKinds(&t, s.id(), &.{ .session_created, .turn_started, .item, .turn_interrupted, .closed });
        const r = try resumeRoot(&t, s.id());
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(schema.Reason.closed, state.last_interrupted.?.reason);
        try testing.expect(state.clean_exit);
        try closeAndDestroy(r);
        s.destroy();
    }

    test "resuming from another workspace records it once" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        try closeAndDestroy(s);
        const moved = try session_mod.openResume(&t.env, .{ .id = id, .workspace = "/other \"place\"", .host = .app });
        try closeAndDestroy(moved);
        const again = try session_mod.openResume(&t.env, .{ .id = id, .workspace = "/other \"place\"", .host = .ask });
        var state = try again.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqualStrings("\"/other \\\"place\\\"\"", state.workspace.?);
        try closeAndDestroy(again);
        try expectKinds(&t, id, &.{ .session_created, .turn_started, .turn_committed, .closed, .set, .closed, .closed });
    }

    test "a child session resumes only with its parent" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const c = try session_mod.openNew(&t.env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = "p1" });
        _ = try c.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, c.id());
        defer gpa.free(id);
        try closeAndDestroy(c);
        try testing.expectError(error.ChildSession, resumeRoot(&t, id));
        try testing.expectError(error.ChildSession, session_mod.openResume(&t.env, .{ .id = id, .workspace = "/w", .host = .child, .parent = "p2" }));
        const ok = try session_mod.openResume(&t.env, .{ .id = id, .workspace = "/w", .host = .child, .parent = "p1" });
        try closeAndDestroy(ok);
    }

    /// A full fold of every line, ignoring snapshots: the reference state.
    fn fullFold(t: *TestEnv, id: []const u8) !fold.State {
        var page = try session_mod.readPage(&t.env, gpa, id, .start, .forward, 1 << 20);
        defer page.deinit();
        var state: fold.State = .{};
        errdefer state.deinit(gpa);
        for (page.entries) |entry| {
            const body = entry.body.?;
            if (body == .snapshot) {
                state.last_seq = entry.seq;
                state.clean_exit = false;
                continue;
            }
            try fold.apply(gpa, &state, 0, .{ .seq = entry.seq, .offset = entry.offset, .body = body });
        }
        return state;
    }

    test "resume from snapshots equals a full fold" {
        var t: TestEnv = undefined;
        t.init(.{ .snapshot_every_bytes = 1024 });
        defer t.deinit();
        const s = try newRoot(&t);
        var prng = std.Random.DefaultPrng.init(3);
        const random = prng.random();
        var value_buffer: [32]u8 = undefined;
        for (0..60) |turn| {
            _ = try s.append(&.{ .turn_started, item, item });
            const value = try std.mem.print(&value_buffer, "{{\"model\":\"m{d}\"}}", .{turn});
            _ = try s.append(&.{.{ .set = .{ .key = .prefs, .value = value } }});
            if (random.boolean()) {
                _ = try s.append(&.{.turn_committed});
            } else {
                _ = try s.append(&.{.{ .turn_interrupted = .cancel }});
            }
            if (turn % 17 == 0) _ = try s.append(&.{.{ .compacted = "{\"summary\":\"...\"}" }});
        }
        _ = try s.append(&.{ .turn_started, item });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        crash(&t, s);

        const r = try resumeRoot(&t, id);
        var resumed = try r.stateCopy(gpa);
        defer resumed.deinit(gpa);
        try closeAndDestroy(r);
        // Compare against a full fold of the log as it stood before the close.
        var reference = try fullFold(&t, id);
        defer reference.deinit(gpa);
        // The close added turn_interrupted? No: resume already interrupted the
        // open turn, then close appended `closed`. Undo only the close line.
        try testing.expect(reference.clean_exit);
        reference.clean_exit = false;
        reference.last_seq -= 1;
        try testing.expect(resumed.eql(&reference));
        try testing.expectEqualStrings("{\"model\":\"m59\"}", resumed.prefs.?);

        const all = try t.kinds(id);
        defer gpa.free(all);
        var snapshots: usize = 0;
        for (all) |k| {
            if (k == .snapshot) snapshots += 1;
        }
        try testing.expect(snapshots >= 5);
    }

    test "a compaction is followed by a snapshot" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        defer closeAndDestroy(s) catch {};
        _ = try s.append(&.{ .turn_started, .{ .compacted = "{}" } });
        try expectKinds(&t, s.id(), &.{ .session_created, .turn_started, .compacted, .snapshot });
        var state = try s.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(?u64, 3), state.last_compaction_seq);
    }

    const Worker = struct {
        session: *Session,
        count: usize,
        durable: bool,
        failed: bool = false,

        fn run(w: *Worker) void {
            for (0..w.count) |_| {
                if (w.durable) {
                    const seq = w.session.append(&.{.{ .set = .{ .key = .permissions, .value = "{\"allow\":[]}" } }}) catch {
                        w.failed = true;
                        return;
                    };
                    // A durable-class call returns only after its own sync.
                    w.session.sync_mutex.lockUncancelable(io);
                    const synced = w.session.synced_seq;
                    w.session.sync_mutex.unlock(io);
                    if (synced < seq) w.failed = true;
                } else {
                    _ = w.session.append(&.{item}) catch {
                        w.failed = true;
                        return;
                    };
                }
            }
        }
    };

    test "set usage returns after its own sync; set prefs does not sync" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{.turn_started});
        const usage_seq = try s.append(&.{.{ .set = .{ .key = .usage, .value = "{\"n\":1}" } }});
        const prefs_seq = try s.append(&.{.{ .set = .{ .key = .prefs, .value = "{}" } }});
        s.sync_mutex.lockUncancelable(io);
        const synced = s.synced_seq;
        s.sync_mutex.unlock(io);
        try testing.expect(synced >= usage_seq);
        try testing.expect(synced < prefs_seq);
        try closeAndDestroy(s);
    }

    test "threads appending at once get contiguous seqs in file order" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{.turn_started});
        var workers: [8]Worker = undefined;
        var threads: [8]std.Thread = undefined;
        for (&workers, &threads, 0..) |*w, *thread, i| {
            w.* = .{ .session = s, .count = 50, .durable = i % 2 == 0 };
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{w});
        }
        for (threads) |thread| thread.join();
        for (workers) |w| try testing.expect(!w.failed);
        _ = try s.append(&.{.turn_committed});
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        try closeAndDestroy(s);
        // readPage checks crc and that seq is contiguous from 1.
        const all = try t.kinds(id);
        defer gpa.free(all);
        var items: usize = 0;
        var sets: usize = 0;
        for (all) |k| switch (k) {
            .item => items += 1,
            .set => sets += 1,
            else => {},
        };
        try testing.expectEqual(@as(usize, 200), items);
        try testing.expectEqual(@as(usize, 200), sets);
    }

    test "paging backward and forward returns every line once, stable across appends" {
        var t: TestEnv = undefined;
        t.init(.{ .snapshot_every_bytes = 1 << 30 });
        defer t.deinit();
        const s = try newRoot(&t);
        defer closeAndDestroy(s) catch {};
        _ = try s.append(&.{.turn_started});
        for (0..20) |_| _ = try s.append(&.{item});
        // 22 lines. Page backward by 5 from the end.
        var seen: std.ArrayList(u64) = .empty;
        defer seen.deinit(gpa);
        var from: session_mod.From = .end;
        var first = true;
        while (true) {
            var page = try session_mod.readPage(&t.env, gpa, s.id(), from, .backward, 5);
            defer page.deinit();
            for (page.entries) |e| try seen.append(gpa, e.seq);
            if (first) {
                // Appends after the first page do not disturb older pages.
                _ = try s.append(&.{ item, item });
                first = false;
            }
            from = .{ .at = page.next orelse break };
        }
        try testing.expectEqual(@as(usize, 22), seen.items.len);
        for (seen.items, 0..) |seq, i| try testing.expectEqual(@as(u64, 22 - i), seq);

        var forward: std.ArrayList(u64) = .empty;
        defer forward.deinit(gpa);
        var at: session_mod.From = .start;
        while (true) {
            var page = try session_mod.readPage(&t.env, gpa, s.id(), at, .forward, 7);
            defer page.deinit();
            for (page.entries) |e| try forward.append(gpa, e.seq);
            at = .{ .at = page.next orelse break };
        }
        try testing.expectEqual(@as(usize, 24), forward.items.len);
        for (forward.items, 0..) |seq, i| try testing.expectEqual(@as(u64, i + 1), seq);
    }

    test "a torn tail is cut once and a damaged middle refuses to resume, each reported once" {
        if (!hooks) return error.SkipZigTest;
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        _ = try s.append(&.{ .turn_started, item, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        // Die in the middle of the next line.
        _ = try s.append(&.{.turn_started});
        t.fault.next_write = .{ .keep = 20, .then = .die };
        try testing.expectError(error.Io, s.append(&.{item}));
        crash(&t, s);
        t.fault.restart();
        const r = try resumeRoot(&t, id);
        try closeAndDestroy(r);
        try testing.expectEqual(@as(usize, 1), t.recorder.count(.torn_tail_cut));

        // Now damage line 2 of the log.
        const dir = try t.env.s.openDir(t.env.root, id);
        defer t.env.s.closeDir(dir);
        var path_buffer: [300]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "{s}/log.jsonl", .{id});
        const bytes = try t.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const line2 = std.mem.findScalar(u8, bytes, '\n').? + 1;
        try @import("storage_fault.zig").flipBit(io, dir, "log.jsonl", line2 + 4, 1);
        try testing.expectError(error.Corrupt, resumeRoot(&t, id));
        try testing.expectEqual(@as(usize, 1), t.recorder.count(.opened_read_only));
        // Reading still works up to the damage.
        var page = try session_mod.readPage(&t.env, gpa, id, .start, .forward, 100);
        defer page.deinit();
        try testing.expect(page.damaged);
        try testing.expectEqual(@as(usize, 1), page.entries.len);
    }

    test "a failed write or sync reports its OS cause, and every later call reports it too (D40)" {
        if (!hooks) return error.SkipZigTest;
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();

        // A full disk on a log write (D29).
        const s = try newRoot(&t);
        _ = try s.append(&.{ .turn_started, item, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        t.fault.fail_error = error.NoSpace;
        t.fault.next_write = .{ .keep = 0, .then = .fail };
        try testing.expectError(error.NoSpaceLeft, s.append(&.{.turn_started}));
        // Durability is unknown after a failed write, so nothing more is
        // written; later calls still name the cause (D40).
        try testing.expectError(error.NoSpaceLeft, s.append(&.{.turn_started}));
        try testing.expectError(error.NoSpaceLeft, s.putBlob("after the full disk"));
        try closeAndDestroy(s);
        try expectKinds(&t, id, &.{ .session_created, .turn_started, .item, .turn_committed });

        // A read-only file system on the sync that ends a turn.
        const r = try resumeRoot(&t, id);
        _ = try r.append(&.{ .turn_started, item });
        t.fault.fail_error = error.ReadOnly;
        t.fault.fail_next_sync = true;
        try testing.expectError(error.ReadOnlyFileSystem, r.append(&.{.turn_committed}));
        try testing.expectError(error.ReadOnlyFileSystem, r.append(&.{.turn_started}));
        try closeAndDestroy(r);
        // The close does not sync again: the failed sync's bytes stay unknown.
        try testing.expectEqual(@as(usize, 1), t.fault.closed_unsynced);
        t.fault.closed_unsynced = 0;

        // A permission denial on the first turn, before the session exists.
        const n = try newRoot(&t);
        t.fault.fail_error = error.Refused;
        t.fault.next_write = .{ .keep = 0, .then = .fail };
        try testing.expectError(error.AccessDenied, n.append(&.{ .turn_started, item }));
        try testing.expectError(error.AccessDenied, n.append(&.{.turn_started}));
        try closeAndDestroy(n);
    }

    // ---------------------------------------------------------------------------
    // Blobs, fork, children, delete (plan checkpoint 4)

    /// `refs` must outlive the event: the caller owns the array.
    fn itemWith(refs: []const []const u8) fold.Event {
        return .{ .item = .{ .type = "tool_result", .data = "{\"tool\":\"read\"}", .blobs = refs } };
    }

    test "blobs: stored once, checked on read, required before a line refers to them" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const s = try newRoot(&t);
        defer closeAndDestroy(s) catch {};
        try testing.expectError(error.InvalidTransition, s.putBlob("too early"));
        _ = try s.append(&.{.turn_started});
        const hash = try s.putBlob("tool output");
        try testing.expectEqualSlices(u8, &hash, &(try s.putBlob("tool output")));
        const refs = [_][]const u8{&hash};
        _ = try s.append(&.{itemWith(&refs)});
        const missing = schema.blobHash("never stored");
        const missing_refs = [_][]const u8{&missing};
        try testing.expectError(error.InvalidTransition, s.append(&.{itemWith(&missing_refs)}));
        const bad_refs = [_][]const u8{"../../etc/passwd"};
        try testing.expectError(error.InvalidTransition, s.append(&.{itemWith(&bad_refs)}));

        const bytes = try session_mod.readBlob(&t.env, gpa, s.id(), &hash);
        defer gpa.free(bytes);
        try testing.expectEqualStrings("tool output", bytes);
        try testing.expectError(error.NotFound, session_mod.readBlob(&t.env, gpa, s.id(), &missing));

        if (hooks) {
            const dir = try t.env.s.openDir(t.env.root, s.id());
            defer t.env.s.closeDir(dir);
            const blobs = try t.env.s.openDir(dir, "blobs");
            defer t.env.s.closeDir(blobs);
            try @import("storage_fault.zig").flipBit(io, blobs, &hash, 3, 0);
            try testing.expectError(error.Corrupt, session_mod.readBlob(&t.env, gpa, s.id(), &hash));
        }
    }

    /// A source session with three committed turns, a blob in turn 2, and an
    /// open fourth turn.
    fn forkSource(t: *TestEnv) !struct { id: []u8, hash: [64]u8 } {
        const s = try newRoot(t);
        _ = try s.append(&.{ .turn_started, item, .turn_committed });
        _ = try s.append(&.{.turn_started});
        const hash = try s.putBlob("shared body");
        const refs = [_][]const u8{&hash};
        _ = try s.append(&.{ itemWith(&refs), .turn_committed });
        _ = try s.append(&.{ .turn_started, item, .turn_committed });
        _ = try s.append(&.{ .turn_started, item });
        const id = try gpa.dupe(u8, s.id());
        try closeAndDestroy(s);
        return .{ .id = id, .hash = hash };
    }

    test "fork at a turn boundary copies the prefix and survives its source" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const source = try forkSource(&t);
        defer gpa.free(source.id);
        const before = try t.kinds(source.id);
        defer gpa.free(before);

        const f = try session_mod.openFork(&t.env, .{ .source = source.id, .at = .{ .turn = 2 }, .workspace = "/w", .host = .app });
        var state = try f.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(u64, 2), state.committed);
        try testing.expectEqual(@as(?u64, null), state.open_turn);
        try testing.expectEqualStrings(source.id, f.identity.forked_from.?.id);
        // The fork continues with turn 3 of its own.
        _ = try f.append(&.{ .turn_started, item, .turn_committed });
        const fork_id = try gpa.dupe(u8, f.id());
        defer gpa.free(fork_id);
        try closeAndDestroy(f);

        // Lines 2..S match the source's, and the source is unchanged.
        const fork_kinds = try t.kinds(fork_id);
        defer gpa.free(fork_kinds);
        try testing.expectEqualSlices(schema.Kind, before[1..7], fork_kinds[1..7]);
        const after = try t.kinds(source.id);
        defer gpa.free(after);
        try testing.expectEqualSlices(schema.Kind, before, after);

        // Delete the source: the fork still reads fully, blob included.
        try deleteWithoutIndex(&t.env, source.id);
        try testing.expectError(error.NotFound, session_mod.readPage(&t.env, gpa, source.id, .start, .forward, 10));
        const bytes = try session_mod.readBlob(&t.env, gpa, fork_id, &source.hash);
        defer gpa.free(bytes);
        try testing.expectEqualStrings("shared body", bytes);
        const r = try resumeRoot(&t, fork_id);
        try closeAndDestroy(r);
    }

    test "a fork after a compaction and snapshots verifies clean and resumes at its own offsets" {
        var t: TestEnv = undefined;
        t.init(.{ .snapshot_every_bytes = 256 });
        defer t.deinit();
        const s = try newRoot(&t);
        const big: fold.Event = .{ .item = .{ .type = "assistant", .data = "{\"text\":\"" ++ &@as([200]u8, @splat('x')) ++ "\"}" } };
        _ = try s.append(&.{ .turn_started, big, .turn_committed });
        _ = try s.append(&.{ .turn_started, .{ .compacted = "{}" }, big, .turn_committed });
        _ = try s.append(&.{ .turn_started, big, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        try closeAndDestroy(s);

        // The fork's line 1 is longer than the source's, so every copied line
        // moves; the copied snapshots must be encoded again with its offsets.
        const f = try session_mod.openFork(&t.env, .{ .source = id, .at = .{ .turn = 3 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, f.id());
        defer gpa.free(fork_id);
        try closeAndDestroy(f);
        const verified = try session_mod.verifySession(&t.env, fork_id);
        try testing.expectEqual(@as(?u64, null), verified.damaged_at);
        try testing.expectEqual(@as(u64, 0), verified.bad_snapshots);

        var page = try session_mod.readPage(&t.env, gpa, fork_id, .start, .forward, 100);
        defer page.deinit();
        var compacted_at: ?u64 = null;
        var snapshots: usize = 0;
        for (page.entries) |entry| {
            if (entry.kind == .compacted) compacted_at = entry.offset;
            if (entry.kind == .snapshot) snapshots += 1;
        }
        try testing.expect(snapshots >= 2);
        // Resume starts from the newest snapshot; the model's context must
        // start at the fork's own compacted line.
        const r = try resumeRoot(&t, fork_id);
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(compacted_at, state.compaction_offset);
        try closeAndDestroy(r);
    }

    test "fork points: turn 0, and never inside a turn" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const source = try forkSource(&t);
        defer gpa.free(source.id);
        try testing.expectError(error.InvalidForkPoint, session_mod.openFork(&t.env, .{ .source = source.id, .at = .{ .turn = 5 }, .workspace = "/w", .host = .app }));
        // Turn 4 was left open by the close: its end line is an interrupt, a boundary.
        const four = try session_mod.openFork(&t.env, .{ .source = source.id, .at = .{ .turn = 4 }, .workspace = "/w", .host = .app });
        try closeAndDestroy(four);
        const zero = try session_mod.openFork(&t.env, .{ .source = source.id, .at = .{ .turn = 0 }, .workspace = "/w", .host = .app });
        const zero_id = try gpa.dupe(u8, zero.id());
        defer gpa.free(zero_id);
        try closeAndDestroy(zero);
        try expectKinds(&t, zero_id, &.{ .session_created, .closed });
        try testing.expectError(error.NotFound, session_mod.openFork(&t.env, .{ .source = "missing", .at = .last_good, .workspace = "/w", .host = .app }));
    }

    test "recover: a damaged source forks up to its last good turn, untouched" {
        if (!hooks) return error.SkipZigTest;
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const source = try forkSource(&t);
        defer gpa.free(source.id);
        // Damage the item of turn 3 (line 9).
        var path_buffer: [300]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "{s}/log.jsonl", .{source.id});
        const bytes = try t.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        var line_start: usize = 0;
        for (0..8) |_| line_start = std.mem.findScalarPos(u8, bytes, line_start, '\n').? + 1;
        const dir = try t.env.s.openDir(t.env.root, source.id);
        defer t.env.s.closeDir(dir);
        try @import("storage_fault.zig").flipBit(io, dir, "log.jsonl", line_start + 10, 2);
        const damaged = try t.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(damaged);

        try testing.expectError(error.Corrupt, resumeRoot(&t, source.id));
        const f = try session_mod.openFork(&t.env, .{ .source = source.id, .at = .last_good, .workspace = "/w", .host = .app });
        var state = try f.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(u64, 2), state.committed);
        try closeAndDestroy(f);
        const unchanged = try t.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(unchanged);
        try testing.expectEqualSlices(u8, damaged, unchanged);
    }

    fn childOf(t: *TestEnv, parent: []const u8) !*Session {
        return session_mod.openNew(&t.env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = parent });
    }

    test "children: finished through the parent, and repaired as lost or interrupted" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const p = try newRoot(&t);
        _ = try p.append(&.{.turn_started});
        const parent_id = try gpa.dupe(u8, p.id());
        defer gpa.free(parent_id);

        // c1 runs to completion.
        const c1 = try childOf(&t, parent_id);
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c1.id(), .work_id = "w1" } }});
        _ = try c1.append(&.{ .turn_started, item, .turn_committed });
        _ = try p.append(&.{.{ .child_finished = .{ .child = c1.id(), .work_id = "w1", .outcome = .ok } }});
        try closeAndDestroy(c1);
        // c2 publishes a log, c3 dies before its first turn; then the parent crashes.
        const c2 = try childOf(&t, parent_id);
        const c3 = try childOf(&t, parent_id);
        _ = try p.append(&.{ .{ .child_spawned = .{ .child = c2.id(), .work_id = "w1" } }, .{ .child_spawned = .{ .child = c3.id(), .work_id = "w1" } } });
        _ = try c2.append(&.{.turn_started});
        const c2_id = try gpa.dupe(u8, c2.id());
        defer gpa.free(c2_id);
        crash(&t, c2);
        try c3.close();
        c3.destroy();
        crash(&t, p);

        const r = try resumeRoot(&t, parent_id);
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        // Every child stays listed with how its work ended; none is open.
        try testing.expectEqual(@as(usize, 3), state.children.items.len);
        const want = [_]schema.Outcome{ .ok, .interrupted, .lost };
        for (state.children.items, want) |child, outcome| {
            try testing.expect(!child.open);
            try testing.expectEqual(@as(?schema.Outcome, outcome), child.outcome);
        }
        try closeAndDestroy(r);
        var page = try session_mod.readPage(&t.env, gpa, parent_id, .start, .forward, 100);
        defer page.deinit();
        var outcomes: std.ArrayList(schema.Outcome) = .empty;
        defer outcomes.deinit(gpa);
        for (page.entries) |e| if (e.body) |body| switch (body) {
            .child_finished => |f| try outcomes.append(gpa, f.outcome),
            else => {},
        };
        try testing.expectEqualSlices(schema.Outcome, &.{ .ok, .interrupted, .lost }, outcomes.items);

        // A child resumes only through its parent; deleting the parent removes it.
        const again = try session_mod.openResume(&t.env, .{ .id = c2_id, .workspace = "/w", .host = .child, .parent = parent_id });
        try testing.expectError(error.Busy, deleteWithoutIndex(&t.env, parent_id));
        try closeAndDestroy(again);
        try deleteWithoutIndex(&t.env, parent_id);
        try testing.expectError(error.NotFound, session_mod.readPage(&t.env, gpa, c2_id, .start, .forward, 1));
        try testing.expectError(error.NotFound, deleteWithoutIndex(&t.env, parent_id));
        const trash = try t.env.s.openDir(t.env.root, ".trash");
        defer t.env.s.closeDir(trash);
        var listing = t.env.s.list(trash);
        try testing.expectEqual(@as(?storage.Entry, null), try listing.next());
    }

    test "a fork owns none of its source's children" {
        var t: TestEnv = undefined;
        t.init(.{});
        defer t.deinit();
        const p = try newRoot(&t);
        _ = try p.append(&.{ .turn_started, .{ .child_spawned = .{ .child = "kid", .work_id = "w" } }, .turn_committed });
        const id = try gpa.dupe(u8, p.id());
        defer gpa.free(id);
        try closeAndDestroy(p);
        const f = try session_mod.openFork(&t.env, .{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, f.id());
        defer gpa.free(fork_id);
        crash(&t, f);
        // Its reopen repairs nothing that belongs to the source.
        const r = try resumeRoot(&t, fork_id);
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), state.children.items.len);
        try closeAndDestroy(r);
        const kinds = try t.kinds(fork_id);
        defer gpa.free(kinds);
        for (kinds) |k| try testing.expect(k != .child_finished);
    }
};

test {
    _ = session_tests;
}

const session_model_tests = struct {
    //! L2 against its four specs: every scenario here writes a trace that
    //! `zig build traces` checks with TLC, and every spec also gets one planted
    //! bug whose trace must be rejected.
    //!
    //! Each tracer is an Observer: the Session notifies what it just did, and
    //! the tracer names the spec action, reads the disk fields straight from the
    //! files (never through the session), and writes one trace line.

    const session_mod = @import("session.zig");
    const Fault = @import("storage_fault.zig").Fault;

    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const Io = std.Io;

    // ---------------------------------------------------------------------------
    // Disk helpers (direct reads, no fault layer, no session)

    fn readLog(root: Io.Dir, id: []const u8) !?[]u8 {
        var path: [300]u8 = undefined;
        const visible = try std.mem.print(&path, "{s}/log.jsonl", .{id});
        if (root.readFileAlloc(io, visible, gpa, .limited(8 << 20))) |bytes| return bytes else |_| {}
        const staged = try std.mem.print(&path, ".tmp/{s}/log.jsonl", .{id});
        if (root.readFileAlloc(io, staged, gpa, .limited(8 << 20))) |bytes| return bytes else |_| {}
        return null;
    }

    /// Every complete line's header and body, parsed from the file bytes.
    const DiskLine = struct { seq: u64, kind: ?schema.Kind, body: ?schema.Body };

    fn diskLines(arena: std.mem.Allocator, bytes: []const u8) ![]DiskLine {
        var out: std.ArrayList(DiskLine) = .empty;
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, bytes, at, '\n')) |nl| : (at = nl + 1) {
            const line = bytes[at .. nl + 1];
            const header = log_mod.checkLine(line) catch {
                try out.append(arena, .{ .seq = 0, .kind = null, .body = null });
                continue;
            };
            const body: ?schema.Body = if (header.kind) |k|
                schema.parseBody(arena, k, log_mod.lineBody(line, header)) catch null
            else
                null;
            try out.append(arena, .{ .seq = header.seq, .kind = header.kind, .body = body });
        }
        return out.items;
    }

    fn exists(root: Io.Dir, path: []const u8) bool {
        _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn testEnv(tmp: *testing.TmpDir, fault: *Fault, options: session_mod.Options) session_mod.Env {
        return .{
            .gpa = gpa,
            .s = .{ .io = io, .fault = fault },
            .root = .{ .handle = tmp.dir },
            .options = options,
        };
    }

    // ---------------------------------------------------------------------------
    // TurnLifecycle

    fn runTurnTrace(case: []const u8, planted: trace.Planted) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        var tracer: trace.TurnTraces = .{ .gpa = gpa, .io = io, .root = tmp.dir, .dir = trace.default_dir, .case = case };
        defer tracer.deinit();
        var env = testEnv(&tmp, &fault, .{});
        env.observer = tracer.observer();
        env.planted = planted;
        const item: fold.Event = .{ .item = .{ .type = "assistant", .data = "{}" } };

        const s = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{.{ .set = .{ .key = .title, .value = "\"t\"" } }});
        _ = try s.append(&.{ .turn_started, item, item });
        try testing.expectError(error.InvalidTransition, s.append(&.{.turn_started}));
        _ = try s.append(&.{ .{ .compacted = "{}" }, .turn_committed });
        if (planted == .accept_item_outside_turn) _ = try s.append(&.{item});
        _ = try s.append(&.{ .turn_started, item });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.abandon();
        tracer.crash(id);

        const r = try session_mod.openResume(&env, .{ .id = id, .workspace = "/moved", .host = .app });
        _ = try r.append(&.{ .turn_started, item });
        try r.close();
        r.destroy();

        const again = try session_mod.openResume(&env, .{ .id = id, .workspace = "/moved", .host = .ask });
        _ = try again.append(&.{ .{ .set = .{ .key = .prefs, .value = "{}" } }, .turn_started, .{ .turn_interrupted = .cancel } });
        try again.close();
        again.destroy();
        try testing.expectEqual(@as(usize, 1), tracer.traced().len);
        try tracer.finish();
    }

    test "TurnLifecycle trace: turns, a refusal, a crash, reopen, close" {
        try runTurnTrace("turns-crash-reopen-close", .none);
    }

    test "TurnLifecycle trace: planted bug, an item outside a turn" {
        try runTurnTrace("planted-accept_item_outside_turn", .accept_item_outside_turn);
    }

    // ---------------------------------------------------------------------------
    // Lifecycle

    const LifecycleTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,
        fault: *Fault,
        ids: [2]?[]u8 = .{ null, null },
        step: [2][]const u8 = .{ "idle", "idle" },
        acked: [2]bool = .{ false, false },

        const labels = [2][]const u8{ "s1", "s2" };

        fn observer(t: *LifecycleTracer) session_mod.Observer {
            return .{ .context = t, .notify = notify };
        }

        fn deinit(t: *LifecycleTracer) void {
            for (t.ids) |maybe| if (maybe) |id| gpa.free(id);
        }

        fn slot(t: *LifecycleTracer, id: []const u8) usize {
            for (t.ids, 0..) |maybe, i| {
                if (maybe) |known| if (std.mem.eql(u8, known, id)) return i;
            }
            for (&t.ids, 0..) |*maybe, i| if (maybe.* == null) {
                maybe.* = gpa.dupe(u8, id) catch @panic("oom");
                return i;
            };
            @panic("more than two traced sessions");
        }

        fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
            const t: *LifecycleTracer = @ptrCast(@alignCast(context));
            const i = t.slot(session.id());
            const move: ?struct { []const u8, []const u8 } = switch (what) {
                .opened_new => .{ "mem", "OpenNew" },
                .made_tmp => .{ "tmpdir", "MkTmp" },
                .wrote_line => |w| if (w.seq == 1) .{ "written", "WriteLine1" } else null,
                .publish_synced => .{ "synced", "FsyncLog" },
                .renamed => .{ "renamed", "Rename" },
                .published => .{ "done", "FsyncDirAndAck" },
                else => null,
            };
            const m = move orelse return;
            t.step[i] = m[0];
            if (std.mem.eql(u8, m[0], "done")) t.acked[i] = true;
            t.emit(m[1], labels[i]);
        }

        /// fx dies: every unfinished publish stops for good.
        fn crashed(t: *LifecycleTracer, event: []const u8) void {
            for (&t.step) |*step| {
                if (!std.mem.eql(u8, step.*, "idle") and !std.mem.eql(u8, step.*, "done")) step.* = "dead";
            }
            t.emit(event, null);
        }

        fn sweep(t: *LifecycleTracer, s: storage.Storage, i: usize) !void {
            const tmp = try s.openDir(.{ .handle = t.root }, ".tmp");
            defer s.closeDir(tmp);
            try s.deleteTree(tmp, t.ids[i].?);
            t.emit("Sweep", labels[i]);
        }

        fn where(t: *LifecycleTracer, i: usize) []const u8 {
            const id = t.ids[i] orelse return "none";
            var path: [300]u8 = undefined;
            if (exists(t.root, id)) return "visible";
            if (exists(t.root, std.mem.print(&path, ".tmp/{s}", .{id}) catch return "none")) return "tmp";
            return "none";
        }

        fn line1(t: *LifecycleTracer, i: usize) []const u8 {
            const id = t.ids[i] orelse return "none";
            const folder = t.where(i);
            if (std.mem.eql(u8, folder, "none")) return "none";
            var path: [300]u8 = undefined;
            const dir_path = if (std.mem.eql(u8, folder, "visible")) id else std.mem.print(&path, ".tmp/{s}", .{id}) catch return "none";
            var dir = t.root.openDir(io, dir_path, .{}) catch return "none";
            defer dir.close(io);
            const bytes = dir.readFileAlloc(io, "log.jsonl", gpa, .limited(1 << 20)) catch return "none";
            defer gpa.free(bytes);
            const nl = std.mem.findScalar(u8, bytes, '\n') orelse return "none";
            return if (t.fault.isDurable(.{ .handle = dir }, "log.jsonl", nl + 1)) "durable" else "cached";
        }

        fn emit(t: *LifecycleTracer, event: []const u8, s: ?[]const u8) void {
            const Per = struct { s1: []const u8, s2: []const u8 };
            const PerBool = struct { s1: bool, s2: bool };
            const step: Per = .{ .s1 = t.step[0], .s2 = t.step[1] };
            const where_: Per = .{ .s1 = t.where(0), .s2 = t.where(1) };
            const line1_: Per = .{ .s1 = t.line1(0), .s2 = t.line1(1) };
            const acked: PerBool = .{ .s1 = t.acked[0], .s2 = t.acked[1] };
            if (s) |label| {
                t.trace.write(.{ .event = event, .s = label, .step = step, .where = where_, .line1 = line1_, .acked = acked });
            } else {
                t.trace.write(.{ .event = event, .step = step, .where = where_, .line1 = line1_, .acked = acked });
            }
        }
    };

    /// Kills the process when the Session reaches `at`.
    const KillAt = struct {
        inner: session_mod.Observer,
        fault: *Fault,
        at: std.meta.Tag(session_mod.Observed),
        fired: bool = false,

        fn observer(k: *KillAt) session_mod.Observer {
            return .{ .context = k, .notify = notify };
        }

        fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
            const k: *KillAt = @ptrCast(@alignCast(context));
            k.inner.notify(k.inner.context, session, what);
            if (!k.fired and what == k.at) {
                k.fired = true;
                k.fault.kill();
            }
        }
    };

    fn runLifecycleTrace(case: []const u8, planted: trace.Planted, power_loss: bool) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 5);
        defer fault.deinit();
        var tracer: LifecycleTracer = .{ .trace = try trace.Trace.create(gpa, io, "Lifecycle", case), .root = tmp.dir, .fault = &fault };
        defer tracer.deinit();
        var killer: KillAt = .{ .inner = tracer.observer(), .fault = &fault, .at = .renamed };
        var env = testEnv(&tmp, &fault, .{});
        env.observer = killer.observer();
        env.planted = planted;

        // s1: dies right after its rename, before the root folder is synced.
        const s1 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try s1.append(&.{.{ .set = .{ .key = .title, .value = "\"one\"" } }});
        try testing.expectError(error.Io, s1.append(&.{.turn_started}));
        s1.abandon();
        if (power_loss) {
            _ = fault.powerLoss();
            tracer.crashed("PowerLoss");
            fault.reboot();
        } else {
            tracer.crashed("ProcessCrash");
            fault.restart();
        }
        if (std.mem.eql(u8, tracer.where(0), "tmp")) try tracer.sweep(env.s, 0);

        // s2: a complete first turn after the restart.
        killer.fired = true;
        const s2 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try s2.append(&.{ .turn_started, .turn_committed });
        try s2.close();
        s2.destroy();
        try tracer.trace.finish();
    }

    test "Lifecycle trace: a crash mid-publish, a sweep, then a full publish" {
        try runLifecycleTrace("crash-after-rename", .none, false);
    }

    test "Lifecycle trace: a power loss mid-publish" {
        try runLifecycleTrace("power-loss-after-rename", .none, true);
    }

    test "Lifecycle trace: planted bug, rename before the log sync" {
        try runLifecycleTrace("planted-rename_before_fsync", .rename_before_fsync, false);
    }

    // ---------------------------------------------------------------------------
    // ResumeSnapshot

    const SnapTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,

        fn observer(t: *SnapTracer) session_mod.Observer {
            return .{ .context = t, .notify = notify };
        }

        fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
            const t: *SnapTracer = @ptrCast(@alignCast(context));
            const w = switch (what) {
                .wrote_line => |w| w,
                else => return,
            };
            const event: []const u8 = switch (w.kind) {
                .set => "Set",
                .turn_started => "Start",
                .turn_committed => "Commit",
                .snapshot => "Snapshot",
                else => return,
            };
            t.emit(session.id(), event, w.seq);
        }

        const St = struct { pref: []const u8, turns: u64, open: bool };
        const TestEntry = struct { k: []const u8, v: []const u8, st: St };
        const empty: St = .{ .pref = "none", .turns = 0, .open = false };

        /// The disk view holds the lines up to `upto_seq` (one batch, one write).
        fn emit(t: *SnapTracer, id: []const u8, event: []const u8, upto_seq: u64) void {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const bytes = (readLog(t.root, id) catch null) orelse return;
            defer gpa.free(bytes);
            const lines = diskLines(arena, bytes) catch return;
            var entries: std.ArrayList(TestEntry) = .empty;
            for (lines) |line| {
                if (line.seq > upto_seq) break;
                const body = line.body orelse continue;
                const entry: TestEntry = switch (body) {
                    .set => |s| .{ .k = "set", .v = unquote(s.value), .st = empty },
                    .turn_started => .{ .k = "start", .v = "none", .st = empty },
                    .turn_committed => .{ .k = "commit", .v = "none", .st = empty },
                    .snapshot => |snap| blk: {
                        var state = fold.decodeState(gpa, arena, snap.state) catch return;
                        defer state.deinit(gpa);
                        const pref = if (state.prefs) |p| arena.dupe(u8, unquote(p)) catch return else "none";
                        break :blk .{ .k = "snap", .v = "none", .st = .{ .pref = pref, .turns = state.committed, .open = state.open_turn != null } };
                    },
                    else => continue,
                };
                entries.append(arena, entry) catch return;
            }
            const last = entries.items[entries.items.len - 1];
            if (std.mem.eql(u8, event, "Set")) {
                t.trace.write(.{ .event = event, .v = last.v, .log = entries.items });
            } else {
                t.trace.write(.{ .event = event, .log = entries.items });
            }
        }

        fn unquote(raw: []const u8) []const u8 {
            return if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
        }
    };

    fn runSnapshotTrace(case: []const u8, planted: trace.Planted) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        var tracer: SnapTracer = .{ .trace = try trace.Trace.create(gpa, io, "ResumeSnapshot", case), .root = tmp.dir };
        // A snapshot after every batch.
        var env = testEnv(&tmp, &fault, .{ .snapshot_every_bytes = 1 });
        env.observer = tracer.observer();
        env.planted = planted;
        const v1: fold.Event = .{ .set = .{ .key = .prefs, .value = "\"v1\"" } };
        const v2: fold.Event = .{ .set = .{ .key = .prefs, .value = "\"v2\"" } };

        const s = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ v1, .turn_started });
        _ = try s.append(&.{v2});
        _ = try s.append(&.{.turn_committed});
        _ = try s.append(&.{ .turn_started, v1 });
        _ = try s.append(&.{ .turn_committed, .turn_started });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.abandon();
        // Resume must see exactly the state the log implies.
        env.observer = null;
        const r = try session_mod.openResume(&env, .{ .id = id, .workspace = "/w", .host = .app });
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        try r.close();
        r.destroy();
        if (planted == .none) {
            try testing.expectEqualStrings("\"v1\"", state.prefs.?);
            try testing.expectEqual(@as(u64, 2), state.committed);
        }
        try tracer.trace.finish();
    }

    test "ResumeSnapshot trace: a snapshot after every batch" {
        try runSnapshotTrace("snapshot-every-batch", .none);
    }

    test "ResumeSnapshot trace: planted bug, snapshots drop prefs" {
        try runSnapshotTrace("planted-snapshot_drops_field", .snapshot_drops_field);
    }

    // ---------------------------------------------------------------------------
    // WriterLock

    threadlocal var thread_label: []const u8 = "t1";

    const LockTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,
        id: []const u8,
        /// Lines on disk before the trace began.
        base: u64,
        mutex: Io.Mutex = .init,
        holder: []const u8 = "none",
        alive: [2]bool = .{ true, true },
        opened: [2]bool = .{ false, false },
        next_seq: [2]u64 = .{ 1, 1 },
        inside: [2][]const u8 = .{ "none", "none" },

        const labels = [2][]const u8{ "p1", "p2" };

        const Proc = struct {
            tracer: *LockTracer,
            p: usize,

            fn observer(proc: *Proc) session_mod.Observer {
                return .{ .context = proc, .notify = notify };
            }

            fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
                const proc: *Proc = @ptrCast(@alignCast(context));
                const t = proc.tracer;
                t.mutex.lockUncancelable(io);
                defer t.mutex.unlock(io);
                switch (what) {
                    .mutex_acquired => {
                        t.inside[proc.p] = thread_label;
                        t.emitLocked("Acquire", proc.p, thread_label);
                    },
                    .mutex_releasing => {
                        t.inside[proc.p] = "none";
                        t.next_seq[proc.p] = t.relative(session.state.last_seq + 1);
                        t.emitLocked("WriteAndRelease", proc.p, thread_label);
                    },
                    else => {},
                }
            }
        };

        /// Seq relative to the trace start, with `closed` lines left out.
        fn relative(t: *LockTracer, seq: u64) u64 {
            const bytes = (readLog(t.root, t.id) catch null) orelse return 0;
            defer gpa.free(bytes);
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const lines = diskLines(arena_state.allocator(), bytes) catch return 0;
            var skipped: u64 = 0;
            for (lines) |line| {
                if (line.seq > t.base and line.seq < seq and line.kind == .closed) skipped += 1;
            }
            return seq - t.base - skipped;
        }

        fn event(t: *LockTracer, name: []const u8, p: usize, session: ?*Session) void {
            t.mutex.lockUncancelable(io);
            defer t.mutex.unlock(io);
            if (std.mem.eql(u8, name, "Open")) {
                t.holder = labels[p];
                t.opened[p] = true;
                t.next_seq[p] = t.relative(session.?.state.last_seq + 1);
            } else if (std.mem.eql(u8, name, "Close")) {
                t.holder = "none";
                t.opened[p] = false;
            } else if (std.mem.eql(u8, name, "Crash")) {
                t.alive[p] = false;
                t.opened[p] = false;
                t.inside[p] = "none";
                if (std.mem.eql(u8, t.holder, labels[p])) t.holder = "none";
            } else if (std.mem.eql(u8, name, "Restart")) {
                t.alive[p] = true;
            }
            t.emitLocked(name, p, null);
        }

        fn emitLocked(t: *LockTracer, name: []const u8, p: usize, thread: ?[]const u8) void {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const Line = struct { seq: u64, by: []const u8 };
            var file: std.ArrayList(Line) = .empty;
            if (readLog(t.root, t.id) catch null) |bytes| {
                defer gpa.free(bytes);
                const lines = diskLines(arena, bytes) catch return;
                var skipped: u64 = 0;
                for (lines) |line| {
                    if (line.seq <= t.base) continue;
                    if (line.kind == .closed) {
                        skipped += 1;
                        continue;
                    }
                    const by: []const u8 = if (line.body) |body| switch (body) {
                        .set => |s| byOf(arena, s.value),
                        else => "?",
                    } else "?";
                    file.append(arena, .{ .seq = line.seq - t.base - skipped, .by = by }) catch return;
                }
            }
            const Bools = struct { p1: bool, p2: bool };
            const Nums = struct { p1: u64, p2: u64 };
            const Names = struct { p1: []const u8, p2: []const u8 };
            const state = .{
                .holder = t.holder,
                .alive = Bools{ .p1 = t.alive[0], .p2 = t.alive[1] },
                .opened = Bools{ .p1 = t.opened[0], .p2 = t.opened[1] },
                .nextSeq = Nums{ .p1 = t.next_seq[0], .p2 = t.next_seq[1] },
                .mutex = Names{ .p1 = t.inside[0], .p2 = t.inside[1] },
            };
            if (thread) |label| {
                t.trace.write(.{ .event = name, .p = labels[p], .t = label, .holder = state.holder, .alive = state.alive, .opened = state.opened, .nextSeq = state.nextSeq, .mutex = state.mutex, .file = file.items });
            } else {
                t.trace.write(.{ .event = name, .p = labels[p], .holder = state.holder, .alive = state.alive, .opened = state.opened, .nextSeq = state.nextSeq, .mutex = state.mutex, .file = file.items });
            }
        }

        fn byOf(arena: std.mem.Allocator, value: []const u8) []const u8 {
            const Parsed = struct { by: []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, arena, value, .{}) catch return "?";
            return parsed.by;
        }
    };

    const LockWorker = struct {
        session: *Session,
        label: []const u8,
        value: []const u8,
        count: usize,
        failed: bool = false,

        fn run(w: *LockWorker) void {
            thread_label = w.label;
            for (0..w.count) |_| {
                _ = w.session.append(&.{.{ .set = .{ .key = .prefs, .value = w.value } }}) catch {
                    w.failed = true;
                    return;
                };
            }
        }
    };

    fn writeFromTwoThreads(s: *Session, value: []const u8) !void {
        var workers = [_]LockWorker{
            .{ .session = s, .label = "t1", .value = value, .count = 3 },
            .{ .session = s, .label = "t2", .value = value, .count = 3 },
        };
        var threads: [2]std.Thread = undefined;
        for (&workers, &threads) |*w, *thread| thread.* = try std.Thread.spawn(.{}, LockWorker.run, .{w});
        for (threads) |thread| thread.join();
        for (workers) |w| try testing.expect(!w.failed);
    }

    fn runLockTrace(case: []const u8, planted: trace.Planted) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault1 = Fault.init(gpa, io, 1);
        defer fault1.deinit();
        var fault2 = Fault.init(gpa, io, 2);
        defer fault2.deinit();
        // Two processes: two managers over the same root, each with its own flock.
        var env1 = testEnv(&tmp, &fault1, .{ .lock_wait_ms = 20 });
        var env2 = testEnv(&tmp, &fault2, .{ .lock_wait_ms = 20 });
        env2.planted = planted;

        // The session exists before the trace begins.
        const setup = try session_mod.openNew(&env1, .{ .workspace = "/w", .host = .app });
        _ = try setup.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, setup.id());
        defer gpa.free(id);
        try setup.close();
        const base = setup.state.last_seq;
        setup.destroy();

        var tracer: LockTracer = .{ .trace = try trace.Trace.create(gpa, io, "WriterLock", case), .root = tmp.dir, .id = id, .base = base };
        var proc1: LockTracer.Proc = .{ .tracer = &tracer, .p = 0 };
        var proc2: LockTracer.Proc = .{ .tracer = &tracer, .p = 1 };
        env1.observer = proc1.observer();
        env2.observer = proc2.observer();
        const options: session_mod.ResumeOptions = .{ .id = id, .workspace = "/w", .host = .app };

        // p1 opens and writes from two threads; p2 is refused meanwhile.
        const a = try session_mod.openResume(&env1, options);
        tracer.event("Open", 0, a);
        if (planted == .skip_flock) {
            const b = try session_mod.openResume(&env2, options);
            tracer.event("Open", 1, b);
            b.abandon();
        } else {
            try testing.expectError(error.Busy, session_mod.openResume(&env2, options));
        }
        try writeFromTwoThreads(a, "{\"by\":\"p1\"}");
        // p1 crashes; the kernel frees the flock.
        a.abandon();
        tracer.event("Crash", 0, null);

        // p2 takes over, writes, and closes cleanly.
        const b = try session_mod.openResume(&env2, options);
        tracer.event("Open", 1, b);
        try writeFromTwoThreads(b, "{\"by\":\"p2\"}");
        try b.close();
        tracer.event("Close", 1, null);
        b.destroy();

        // p1 restarts and continues where the log ends.
        tracer.event("Restart", 0, null);
        const c = try session_mod.openResume(&env1, options);
        tracer.event("Open", 0, c);
        try writeFromTwoThreads(c, "{\"by\":\"p1\"}");
        try c.close();
        tracer.event("Close", 0, null);
        c.destroy();
        try tracer.trace.finish();
    }

    test "WriterLock trace: two processes, two threads each, a crash and a takeover" {
        try runLockTrace("two-processes-two-threads", .none);
    }

    test "WriterLock trace: planted bug, resume skips the flock" {
        try runLockTrace("planted-skip_flock", .skip_flock);
    }

    // ---------------------------------------------------------------------------
    // Fork

    const ForkTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,
        ids: [3]?[]u8 = .{ null, null, null },
        st: [3][]const u8 = .{ "none", "none", "none" },
        /// A fork's staging writes are part of its Fork action; its writes
        /// after the publish are ordinary host writes.
        published: [3]bool = .{ false, false, false },
        /// Ghost: the prefix each fork copied, as the code copied it.
        base: [3][]const Lg = .{ &.{}, &.{}, &.{} },
        base_arena: std.heap.ArenaAllocator,
        blob_hashes: [2][64]u8,
        /// During a line's notify: that session's disk view ends at the line
        /// (a batch is one write, observed line by line after it).
        horizon: ?struct { id: []const u8, seq: u64 } = null,

        const labels = [3][]const u8{ "s1", "s2", "s3" };
        const blob_labels = [2][]const u8{ "b1", "b2" };
        const Lg = struct { k: []const u8, b: []const u8 };

        fn init(t: *ForkTracer, case: []const u8, root: Io.Dir) !void {
            t.* = .{
                .trace = try trace.Trace.create(gpa, io, "Fork", case),
                .root = root,
                .base_arena = .init(gpa),
                .blob_hashes = .{ schema.blobHash("b1"), schema.blobHash("b2") },
            };
        }

        fn deinit(t: *ForkTracer) void {
            for (t.ids) |maybe| if (maybe) |id| gpa.free(id);
            t.base_arena.deinit();
        }

        fn observer(t: *ForkTracer) session_mod.Observer {
            return .{ .context = t, .notify = notify };
        }

        fn slot(t: *ForkTracer, id: []const u8) usize {
            for (t.ids, 0..) |maybe, i| {
                if (maybe) |known| if (std.mem.eql(u8, known, id)) return i;
            }
            for (&t.ids, 0..) |*maybe, i| if (maybe.* == null) {
                maybe.* = gpa.dupe(u8, id) catch @panic("oom");
                return i;
            };
            @panic("more than three traced sessions");
        }

        fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
            const t: *ForkTracer = @ptrCast(@alignCast(context));
            const i = t.slot(session.id());
            if (session.identity.forked_from != null and !t.published[i]) {
                const origin = session.identity.forked_from.?;
                // A fork is one action: its staging writes are not host writes.
                if (what != .published) return;
                t.published[i] = true;
                const src = t.slot(origin.id);
                var arena_state = std.heap.ArenaAllocator.init(gpa);
                defer arena_state.deinit();
                const source_lg = t.lgOf(arena_state.allocator(), src) catch return;
                const copied = source_lg[1..@intCast(origin.seq)];
                const kept = t.base_arena.allocator().alloc(Lg, copied.len) catch return;
                for (copied, kept) |from, *to| to.* = .{
                    .k = t.base_arena.allocator().dupe(u8, from.k) catch return,
                    .b = t.base_arena.allocator().dupe(u8, from.b) catch return,
                };
                t.base[i] = kept;
                t.st[i] = "live";
                t.emit("Fork", .{ .src = labels[src], .f = labels[i], .at = origin.seq });
                return;
            }
            const w = switch (what) {
                .wrote_line => |w| w,
                else => return,
            };
            t.horizon = .{ .id = session.id(), .seq = w.seq };
            defer t.horizon = null;
            switch (w.kind) {
                .session_created => {
                    t.st[i] = "live";
                    t.emit("Create", .{ .s = labels[i] });
                },
                .turn_started => t.emit("Start", .{ .s = labels[i] }),
                .turn_committed => t.emit("Commit", .{ .s = labels[i] }),
                .item => {
                    var arena_state = std.heap.ArenaAllocator.init(gpa);
                    defer arena_state.deinit();
                    const lg = t.lgOf(arena_state.allocator(), i) catch return;
                    t.emit("Item", .{ .s = labels[i], .b = lg[lg.len - 1].b });
                },
                else => {},
            }
        }

        fn putBlob(t: *ForkTracer, s: *Session, content: []const u8) ![64]u8 {
            const hash = try s.putBlob(content);
            t.emit("PutBlob", .{ .s = labels[t.slot(s.id())], .b = t.blobLabel(&hash) });
            return hash;
        }

        fn deleted(t: *ForkTracer, id: []const u8) void {
            const i = t.slot(id);
            t.st[i] = "deleted";
            t.emit("Delete", .{ .s = labels[i] });
        }

        fn blobLabel(t: *ForkTracer, hash: []const u8) []const u8 {
            for (t.blob_hashes, blob_labels) |known, label| {
                if (std.mem.eql(u8, &known, hash)) return label;
            }
            return "?";
        }

        fn folder(t: *ForkTracer, buffer: []u8, i: usize) ?[]const u8 {
            const id = t.ids[i] orelse return null;
            if (exists(t.root, id)) return id;
            const staged = std.mem.print(buffer, ".tmp/{s}", .{id}) catch return null;
            return if (exists(t.root, staged)) staged else null;
        }

        fn lgOf(t: *ForkTracer, arena: std.mem.Allocator, i: usize) ![]Lg {
            var out: std.ArrayList(Lg) = .empty;
            const id = t.ids[i] orelse return out.items;
            const bytes = (try readLog(t.root, id)) orelse return out.items;
            defer gpa.free(bytes);
            for (try diskLines(arena, bytes)) |line| {
                if (t.horizon) |h| if (std.mem.eql(u8, h.id, id) and line.seq > h.seq) break;
                const body = line.body orelse continue;
                const entry: Lg = switch (body) {
                    .session_created => .{ .k = "created", .b = "none" },
                    .turn_started => .{ .k = "start", .b = "none" },
                    .turn_committed => .{ .k = "commit", .b = "none" },
                    .item => |piece| .{ .k = "item", .b = if (piece.blobs.len > 0) t.blobLabel(piece.blobs[0]) else "none" },
                    else => continue,
                };
                try out.append(arena, entry);
            }
            return out.items;
        }

        fn linksOf(t: *ForkTracer, arena: std.mem.Allocator, i: usize) ![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var buffer: [300]u8 = undefined;
            const path = t.folder(&buffer, i) orelse return out.items;
            var dir = t.root.openDir(io, path, .{}) catch return out.items;
            defer dir.close(io);
            var blobs = dir.openDir(io, "blobs", .{ .iterate = true }) catch return out.items;
            defer blobs.close(io);
            var it = blobs.iterate();
            while (try it.next(io)) |entry| {
                if (!schema.validBlobHash(entry.name)) continue;
                try out.append(arena, t.blobLabel(entry.name));
            }
            std.mem.sort([]const u8, out.items, {}, lessString);
            return out.items;
        }

        fn lessString(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }

        fn emit(t: *ForkTracer, event: []const u8, args: anytype) void {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const Set = struct { @"$set": []const []const u8 };
            const PerLg = struct { s1: []const Lg, s2: []const Lg, s3: []const Lg };
            const PerSet = struct { s1: Set, s2: Set, s3: Set };
            const PerSt = struct { s1: []const u8, s2: []const u8, s3: []const u8 };
            var lg: [3][]const Lg = undefined;
            var links: [3]Set = undefined;
            for (0..3) |i| {
                lg[i] = t.lgOf(arena, i) catch return;
                links[i] = .{ .@"$set" = t.linksOf(arena, i) catch return };
            }
            const state = .{
                .st = PerSt{ .s1 = t.st[0], .s2 = t.st[1], .s3 = t.st[2] },
                .lg = PerLg{ .s1 = lg[0], .s2 = lg[1], .s3 = lg[2] },
                .links = PerSet{ .s1 = links[0], .s2 = links[1], .s3 = links[2] },
                .base = PerLg{ .s1 = t.base[0], .s2 = t.base[1], .s3 = t.base[2] },
            };
            const Args = @TypeOf(args);
            if (@hasField(Args, "src")) {
                t.trace.write(.{ .event = event, .src = args.src, .f = args.f, .at = args.at, .st = state.st, .lg = state.lg, .links = state.links, .base = state.base });
            } else if (@hasField(Args, "b")) {
                t.trace.write(.{ .event = event, .s = args.s, .b = args.b, .st = state.st, .lg = state.lg, .links = state.links, .base = state.base });
            } else {
                t.trace.write(.{ .event = event, .s = args.s, .st = state.st, .lg = state.lg, .links = state.links, .base = state.base });
            }
        }
    };

    fn runForkTrace(case: []const u8, planted: trace.Planted) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        var tracer: ForkTracer = undefined;
        try tracer.init(case, tmp.dir);
        defer tracer.deinit();
        var env = testEnv(&tmp, &fault, .{});
        env.observer = tracer.observer();
        env.planted = planted;

        const s1 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try s1.append(&.{.turn_started});
        const b1 = try tracer.putBlob(s1, "b1");
        const r1 = [_][]const u8{&b1};
        _ = try s1.append(&.{ .{ .item = .{ .type = "tool_result", .data = "{}", .blobs = &r1 } }, .turn_committed });
        _ = try s1.append(&.{.turn_started});
        const b2 = try tracer.putBlob(s1, "b2");
        const r2 = [_][]const u8{&b2};
        _ = try s1.append(&.{ .{ .item = .{ .type = "tool_result", .data = "{}", .blobs = &r2 } }, .turn_committed });

        // Fork s1 at the end of turn 1, while s1 is still open elsewhere.
        const s2 = try session_mod.openFork(&env, .{ .source = s1.id(), .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        if (planted == .fork_skips_blob_link) {
            // The code notices too: one source blob is missing from the fork.
            var missing: usize = 0;
            for ([_][]const u8{ &b1, &b2 }) |hash| {
                if (session_mod.readBlob(&env, gpa, s2.id(), hash)) |bytes| gpa.free(bytes) else |err| {
                    try testing.expectEqual(error.NotFound, err);
                    missing += 1;
                }
            }
            try testing.expectEqual(@as(usize, 1), missing);
            s1.abandon();
            s2.abandon();
            return tracer.trace.finish();
        }
        _ = try s2.append(&.{.turn_started});
        _ = try s2.append(&.{ .{ .item = .{ .type = "tool_result", .data = "{}", .blobs = &r2 } }, .turn_committed });

        // The source goes away; the fork keeps its prefix and its blobs.
        const s1_id = try gpa.dupe(u8, s1.id());
        defer gpa.free(s1_id);
        s1.abandon();
        try session_tests.deleteWithoutIndex(&env, s1_id);
        tracer.deleted(s1_id);
        _ = try s2.append(&.{ .turn_started, .{ .item = .{ .type = "tool_result", .data = "{}", .blobs = &r1 } }, .turn_committed });

        // A fork of the fork.
        const s3 = try session_mod.openFork(&env, .{ .source = s2.id(), .at = .{ .turn = 2 }, .workspace = "/w", .host = .app });
        _ = try s3.append(&.{ .turn_started, .turn_committed });
        s2.abandon();
        s3.abandon();
        try tracer.trace.finish();
    }

    test "Fork trace: fork, delete the source, fork the fork" {
        try runForkTrace("fork-delete-source-fork-again", .none);
    }

    test "Fork trace: planted bug, a fork skips a blob link" {
        try runForkTrace("planted-fork_skips_blob_link", .fork_skips_blob_link);
    }

    // ---------------------------------------------------------------------------
    // Subagents

    const SubTracer = struct {
        trace: trace.Trace,
        root: Io.Dir,
        parent: ?[]u8 = null,
        children: [2]?[]u8 = .{ null, null },
        /// The child's log has been published.
        published: [2]bool = .{ false, false },
        thread: [2][]const u8 = .{ "none", "none" },
        up: bool = true,
        repairing: bool = false,
        /// During a parent line's notify: the parent's disk view ends at it.
        horizon: ?u64 = null,

        const labels = [2][]const u8{ "c1", "c2" };
        const Plog = struct { k: []const u8, c: []const u8, w: u64, o: []const u8 };

        fn deinit(t: *SubTracer) void {
            if (t.parent) |p| gpa.free(p);
            for (t.children) |maybe| if (maybe) |c| gpa.free(c);
        }

        fn observer(t: *SubTracer) session_mod.Observer {
            return .{ .context = t, .notify = notify };
        }

        fn slot(t: *SubTracer, child: []const u8) usize {
            for (t.children, 0..) |maybe, i| {
                if (maybe) |known| if (std.mem.eql(u8, known, child)) return i;
            }
            for (&t.children, 0..) |*maybe, i| if (maybe.* == null) {
                maybe.* = gpa.dupe(u8, child) catch @panic("oom");
                return i;
            };
            @panic("more than two traced children");
        }

        fn notify(context: *anyopaque, session: *Session, what: session_mod.Observed) void {
            const t: *SubTracer = @ptrCast(@alignCast(context));
            if (session.identity.role == .child) {
                const i = t.slot(session.id());
                switch (what) {
                    // The first work's turn publishes the child's log.
                    .published => {
                        t.published[i] = true;
                        t.thread[i] = "running";
                        t.emit("ChildStart", labels[i]);
                    },
                    // Later work runs in the published log.
                    .wrote_line => |w| if (w.kind == .turn_started and t.published[i] and
                        std.mem.eql(u8, t.thread[i], "starting"))
                    {
                        t.thread[i] = "running";
                        t.emit("ChildStart", labels[i]);
                    },
                    else => {},
                }
                return;
            }
            if (t.parent == null) t.parent = gpa.dupe(u8, session.id()) catch @panic("oom");
            switch (what) {
                .reopened => {
                    t.up = true;
                    t.repairing = true;
                    t.emit("Reopen", null);
                },
                .wrote_line => |w| {
                    if (w.kind != .child_spawned and w.kind != .child_finished) return;
                    t.horizon = w.seq;
                    defer t.horizon = null;
                    var arena_state = std.heap.ArenaAllocator.init(gpa);
                    defer arena_state.deinit();
                    const plog = t.plogOf(arena_state.allocator()) catch return;
                    const last = plog[plog.len - 1];
                    const i = t.slot(t.children[labelIndex(last.c)].?);
                    switch (w.kind) {
                        .child_spawned => {
                            t.thread[i] = "starting";
                            t.emit("Spawn", labels[i]);
                        },
                        else => if (w.cause == .child_repair) {
                            t.emit("RepairChild", labels[i]);
                        } else {
                            t.thread[i] = "none";
                            t.emit(if (std.mem.eql(u8, last.o, "cancelled")) "Cancel" else "ChildFinish", labels[i]);
                        },
                    }
                },
                else => {},
            }
        }

        fn labelIndex(label: []const u8) usize {
            return if (std.mem.eql(u8, label, "c1")) 0 else 1;
        }

        fn spawnable(t: *SubTracer, child: []const u8) void {
            _ = t.slot(child);
        }

        fn crash(t: *SubTracer) void {
            t.up = false;
            t.repairing = false;
            t.thread = .{ "none", "none" };
            t.emit("Crash", null);
        }

        fn repairDone(t: *SubTracer) void {
            t.repairing = false;
            t.emit("RepairDone", null);
        }

        fn plogOf(t: *SubTracer, arena: std.mem.Allocator) ![]Plog {
            var out: std.ArrayList(Plog) = .empty;
            const parent = t.parent orelse return out.items;
            const bytes = (try readLog(t.root, parent)) orelse return out.items;
            defer gpa.free(bytes);
            // A child's work number counts its spawn lines (`tla/Subagents.tla`).
            var works: [2]u64 = .{ 0, 0 };
            for (try diskLines(arena, bytes)) |line| {
                if (t.horizon) |h| if (line.seq > h) break;
                const body = line.body orelse continue;
                switch (body) {
                    .child_spawned => |c| {
                        const i = t.slot(c.child);
                        works[i] += 1;
                        try out.append(arena, .{ .k = "spawned", .c = labels[i], .w = works[i], .o = "none" });
                    },
                    .child_finished => |c| {
                        const i = t.slot(c.child);
                        try out.append(arena, .{ .k = "finished", .c = labels[i], .w = works[i], .o = @tagName(c.outcome) });
                    },
                    else => {},
                }
            }
            return out.items;
        }

        fn emit(t: *SubTracer, event: []const u8, c: ?[]const u8) void {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const plog = t.plogOf(arena_state.allocator()) catch return;
            var path: [300]u8 = undefined;
            var has_log: [2]bool = .{ false, false };
            for (t.children, 0..) |maybe, i| if (maybe) |child| {
                has_log[i] = exists(t.root, std.mem.print(&path, "{s}/log.jsonl", .{child}) catch continue);
            };
            const Bools = struct { c1: bool, c2: bool };
            const Names = struct { c1: []const u8, c2: []const u8 };
            const child_log: Bools = .{ .c1 = has_log[0], .c2 = has_log[1] };
            const thread: Names = .{ .c1 = t.thread[0], .c2 = t.thread[1] };
            if (c) |label| {
                t.trace.write(.{ .event = event, .c = label, .plog = plog, .childLog = child_log, .thread = thread, .up = t.up, .repairing = t.repairing });
            } else {
                t.trace.write(.{ .event = event, .plog = plog, .childLog = child_log, .thread = thread, .up = t.up, .repairing = t.repairing });
            }
        }
    };

    fn runSubagentsTrace(case: []const u8, planted: trace.Planted, finish_first: bool) !void {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        var tracer: SubTracer = .{ .trace = try trace.Trace.create(gpa, io, "Subagents", case), .root = tmp.dir };
        defer tracer.deinit();
        var env = testEnv(&tmp, &fault, .{});
        env.observer = tracer.observer();
        env.planted = planted;

        const p = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try p.append(&.{.turn_started});
        const parent_id = try gpa.dupe(u8, p.id());
        defer gpa.free(parent_id);

        const c1 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = parent_id });
        tracer.spawnable(c1.id());
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c1.id(), .work_id = "w1" } }});
        _ = try c1.append(&.{ .turn_started, .turn_committed });
        if (finish_first) {
            _ = try p.append(&.{.{ .child_finished = .{ .child = c1.id(), .work_id = "w1", .outcome = .ok } }});
        }
        const c2 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = parent_id });
        tracer.spawnable(c2.id());
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c2.id(), .work_id = "w1" } }});

        // The process dies with c2 never started (and c1 still running unless finished).
        c1.abandon();
        c2.abandon();
        p.abandon();
        tracer.crash();

        const r = try session_mod.openResume(&env, .{ .id = parent_id, .workspace = "/w", .host = .app });
        tracer.repairDone();
        r.abandon();
        try tracer.trace.finish();
    }

    test "Subagents trace: one child finishes, one is lost in a crash" {
        try runSubagentsTrace("finish-then-lost", .none, true);
    }

    test "Subagents trace: a crash leaves one child interrupted and one lost" {
        try runSubagentsTrace("interrupted-and-lost", .none, false);
    }

    test "Subagents trace: planted bug, repair finishes a child twice" {
        try runSubagentsTrace("planted-repair_marks_child_twice", .repair_marks_child_twice, false);
    }

    test "Subagents trace: a named child fails, works again, is cancelled; a crash interrupts another" {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(gpa, io, 1);
        defer fault.deinit();
        var tracer: SubTracer = .{ .trace = try trace.Trace.create(gpa, io, "Subagents", "second-work-cancel-interrupt"), .root = tmp.dir };
        defer tracer.deinit();
        var env = testEnv(&tmp, &fault, .{});
        env.observer = tracer.observer();

        const p = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .app });
        _ = try p.append(&.{.turn_started});
        const parent_id = try gpa.dupe(u8, p.id());
        defer gpa.free(parent_id);

        // c1's first work fails; its second runs in the same log and is cancelled.
        const c1 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = parent_id });
        tracer.spawnable(c1.id());
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c1.id(), .work_id = "w1", .data = "{\"name\":\"reviewer\"}" } }});
        _ = try c1.append(&.{ .turn_started, .turn_committed });
        _ = try p.append(&.{.{ .child_finished = .{ .child = c1.id(), .work_id = "w1", .outcome = .failed, .data = "{\"error\":\"e\"}" } }});
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c1.id(), .work_id = "w2" } }});
        _ = try c1.append(&.{.turn_started});
        _ = try p.append(&.{.{ .child_finished = .{ .child = c1.id(), .work_id = "w2", .outcome = .cancelled } }});
        _ = try c1.append(&.{.{ .turn_interrupted = .cancel }});

        // c2 is running when the process dies.
        const c2 = try session_mod.openNew(&env, .{ .workspace = "/w", .host = .child, .role = .child, .parent = parent_id });
        tracer.spawnable(c2.id());
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c2.id(), .work_id = "w1" } }});
        _ = try c2.append(&.{.turn_started});
        c1.abandon();
        c2.abandon();
        p.abandon();
        tracer.crash();

        const r = try session_mod.openResume(&env, .{ .id = parent_id, .workspace = "/w", .host = .app });
        tracer.repairDone();
        var state = try r.stateCopy(gpa);
        defer state.deinit(gpa);
        r.abandon();
        try tracer.trace.finish();

        try testing.expectEqual(@as(usize, 2), state.children.items.len);
        const named = state.children.items[0];
        try testing.expectEqualStrings("w2", named.work_id);
        try testing.expectEqual(@as(?schema.Outcome, .cancelled), named.outcome);
        try testing.expectEqual(@as(?[]u8, null), named.spawn_data);
        try testing.expectEqual(@as(?[]u8, null), named.finish_data);
        try testing.expectEqual(@as(?schema.Outcome, .interrupted), state.children.items[1].outcome);
        try testing.expect(!state.children.items[1].open);
    }
};

test {
    if (@import("storage.zig").hooks) _ = session_model_tests;
}
