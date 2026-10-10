//! The session manager: one append-only log per session, one owner for
//! session storage and the live-session lifecycle.
//!
//! This file (L4) is the only public root; fx imports it and nothing else.
//! A process creates one `Manager` with `init`, which does no disk I/O.
//! Thirteen operations cover every host (docs/session-manager/system-design.md
//! "API"), plus `verify` and `rebuild` for doctor:
//!
//!   openNew  openResume  openFork  openImport        -> Session
//!   Session.append  Session.putBlob  Session.state  Session.read  Session.close
//!   read  getBlob  list  delete                       (by id, no lock)
//!
//! Every input is checked here; the levels below trust it. A Session is
//! safe to use from any thread, and each call on it is atomic relative to
//! the others. Index (catalog) failures never fail a session change: the
//! session data is already durable, and the failure is reported through
//! the diagnostics callback (`index_stale`).

const std = @import("std");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const fold = @import("fold.zig");
const log_mod = @import("log.zig");
const session_mod = @import("session.zig");
const catalog_mod = @import("catalog.zig");
const diag = @import("diag.zig");

pub const Role = schema.Role;
pub const Host = schema.Host;
pub const Reason = schema.Reason;
pub const Outcome = schema.Outcome;
pub const SetKey = schema.SetKey;
pub const Kind = schema.Kind;
pub const Body = schema.Body;
pub const Event = fold.Event;
pub const Piece = fold.Piece;
pub const State = fold.State;
pub const Child = fold.Child;
pub const Diagnostic = diag.Event;
pub const DiagnosticKind = diag.Kind;
pub const Diagnostics = diag.Sink;
pub const Page = session_mod.Page;
pub const Entry = session_mod.Entry;
pub const Cursor = session_mod.Cursor;
pub const From = session_mod.From;
pub const Direction = session_mod.Direction;
pub const ForkPoint = session_mod.ForkPoint;
pub const Verified = session_mod.Verified;
pub const Summary = catalog_mod.Summary;
pub const ListPage = catalog_mod.Page;
pub const ListCursor = catalog_mod.Cursor;
pub const Filter = catalog_mod.Filter;
pub const Rebuilt = catalog_mod.Rebuilt;
pub const BlobHash = [schema.blob_hash_len]u8;
pub const max_blob_bytes = session_mod.max_blob_bytes;
/// Largest `data` or `value` accepted in one event; the adapter moves
/// bodies above its own, smaller threshold into blobs.
pub const max_value_bytes: usize = log_mod.max_line_bytes - 64 * 1024;
const max_text_bytes = 4096;

/// An I/O failure with its OS cause when known, `Io` otherwise (D29).
pub const IoFault = storage.IoFault;
pub const OpenError = error{ InvalidArgument, NotFound, Busy, ChildSession, Corrupt, UnsupportedVersion, InvalidForkPoint, Exists, OutOfMemory } || storage.IoFault;
pub const AppendError = error{ InvalidArgument, InvalidTransition, SessionClosed, TooLarge, OutOfMemory } || storage.IoFault;
pub const CloseError = error{OutOfMemory} || storage.IoFault;
pub const ReadError = error{ InvalidArgument, NotFound, OutOfMemory } || storage.IoFault;
pub const SessionReadError = error{ InvalidArgument, SessionClosed, OutOfMemory } || storage.IoFault;
pub const BlobError = error{ InvalidArgument, NotFound, Corrupt, OutOfMemory } || storage.IoFault;
pub const ListError = error{ Busy, OutOfMemory } || storage.IoFault;
pub const DeleteError = error{ InvalidArgument, NotFound, Busy, OutOfMemory } || storage.IoFault;
pub const VerifyError = error{ InvalidArgument, NotFound, OutOfMemory } || storage.IoFault;
pub const RebuildError = error{ Busy, OutOfMemory } || storage.IoFault;

pub const Backend = enum { posix };

pub const InitOptions = struct {
    /// The sessions root, `~/.fx/sessions/v2` in fx (D19); created on first
    /// use, with any missing parent folders, all `0700`.
    root: []const u8,
    backend: Backend = .posix,
    /// Called once for every repair or drop (D14).
    diagnostics: ?Diagnostics = null,
    /// How long an open waits for a session or index lock before Busy.
    lock_wait_ms: u64 = 2000,
    /// Snapshot distance (D7).
    snapshot_every_bytes: u64 = session_mod.default_snapshot_every_bytes,
    /// Index size that triggers a rewrite with one line per id.
    index_compact_bytes: u64 = 1 << 20,
};

pub const NewOptions = struct {
    workspace: []const u8,
    host: Host,
    role: Role = .root,
    /// Required for a child session.
    parent: ?[]const u8 = null,
    /// A child's id, already named in its parent's `child_spawned` (D34); a
    /// root always gets a fresh one. A taken id fails the first turn's
    /// append and leaves the existing session as it was.
    id: ?[]const u8 = null,
};

pub const ResumeTarget = union(enum) {
    id: []const u8,
    /// The newest updated root session in the workspace (`--resume last`).
    last,
    /// The root session this host opened last in the workspace (`-c` is
    /// `.last_opened = .app`).
    last_opened: Host,
};

pub const ResumeOptions = struct {
    target: ResumeTarget,
    workspace: []const u8,
    host: Host,
    parent: ?[]const u8 = null,
    /// How long this open waits for the session's writer lock before Busy;
    /// null uses the manager's `lock_wait_ms`. A picker passes 0 so a
    /// session open elsewhere shows as busy at once (D38).
    lock_wait_ms: ?u64 = null,
};

pub const ForkOptions = struct {
    source: []const u8,
    at: ForkPoint,
    workspace: []const u8,
    host: Host,
};

pub const ImportOptions = struct {
    /// The v1 id, kept (D8).
    id: []const u8,
    workspace: []const u8,
    host: Host,
    role: Role = .root,
    parent: ?[]const u8 = null,
    created_ms: u64,
};

/// A saved session as `peek` reads it. Owns everything; free with `deinit`.
pub const Peeked = struct {
    role: Role,
    /// A child's parent; null for a root.
    parent: ?[]u8 = null,
    workspace: []u8,
    /// With `created_ms` and `updated_ms` set, as `Session.state` sets them.
    state: State,

    pub fn deinit(p: *Peeked, gpa: std.mem.Allocator) void {
        if (p.parent) |value| gpa.free(value);
        gpa.free(p.workspace);
        p.state.deinit(gpa);
        p.* = undefined;
    }
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    root_path: []u8,
    env: session_mod.Env,
    root_mutex: std.Io.Mutex = .init,
    root_open: bool = false,
    index_lock: catalog_mod.IndexLock = .{},

    /// No disk I/O happens here; the root opens on first use. `gpa` must be
    /// thread-safe when Sessions are used from several threads. The Manager
    /// must outlive every Session.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: InitOptions) error{ InvalidArgument, OutOfMemory }!*Manager {
        if (options.root.len == 0 or !std.unicode.utf8ValidateSlice(options.root)) return error.InvalidArgument;
        const m = try gpa.create(Manager);
        errdefer gpa.destroy(m);
        m.* = .{
            .gpa = gpa,
            .root_path = try gpa.dupe(u8, options.root),
            .env = .{
                .gpa = gpa,
                .s = .{ .io = io },
                .root = undefined,
                .options = .{
                    .lock_wait_ms = options.lock_wait_ms,
                    .snapshot_every_bytes = options.snapshot_every_bytes,
                    .index_compact_bytes = options.index_compact_bytes,
                },
                .diagnostics = options.diagnostics,
            },
        };
        return m;
    }

    /// Every Session must be closed and released first.
    pub fn deinit(m: *Manager) void {
        m.index_lock.close(m.env.s);
        if (m.root_open) m.env.s.closeDir(m.env.root);
        m.gpa.free(m.root_path);
        m.gpa.destroy(m);
    }

    /// Test and driver builds only: report internal steps to a tracer, and
    /// optionally plant a known bug the trace check must reject.
    pub fn setTracing(
        m: *Manager,
        observer: if (storage.hooks) session_mod.Observer else void,
        planted: if (storage.hooks) hooks.trace.Planted else void,
    ) void {
        if (storage.hooks) {
            m.env.observer = observer;
            m.env.planted = planted;
        }
    }

    /// Test and driver builds only: route storage through a fault injector.
    pub fn setFault(m: *Manager, fault: if (storage.hooks) *storage.Fault else void) void {
        if (storage.hooks) m.env.s.fault = fault;
    }

    fn ready(m: *Manager) storage.IoFault!void {
        const io = m.env.s.io;
        m.root_mutex.lockUncancelable(io);
        defer m.root_mutex.unlock(io);
        if (m.root_open) return;
        m.env.root = m.env.s.openRoot(m.root_path) catch |io_err| return storage.ioFault(io_err);
        m.root_open = true;
    }

    /// `ready` for calls that only find or read: a missing root is not
    /// created, so reading on a machine that never saved a session writes
    /// nothing. False means there is nothing to find.
    fn readyToRead(m: *Manager) storage.IoFault!bool {
        {
            const io = m.env.s.io;
            m.root_mutex.lockUncancelable(io);
            defer m.root_mutex.unlock(io);
            if (m.root_open) return true;
        }
        const present = m.env.s.rootExists(m.root_path) catch |io_err| return storage.ioFault(io_err);
        if (!present) return false;
        try ready(m);
        return true;
    }

    fn catalog(m: *Manager) catalog_mod.Catalog {
        return .{ .env = &m.env, .lock = &m.index_lock };
    }

    fn nowMs(m: *Manager) u64 {
        return std.math.cast(u64, std.Io.Timestamp.now(m.env.s.io, .real).toMilliseconds()) orelse 0;
    }

    /// Records an index failure that did not fail the session change.
    fn indexStale(m: *Manager, id: []const u8) void {
        diag.report(m.env.diagnostics, .{ .kind = .index_stale, .session_id = id });
    }

    // -- open -----------------------------------------------------------------

    /// A new session in memory. Nothing touches the disk until its first
    /// turn (D2).
    pub fn openNew(m: *Manager, options: NewOptions) OpenError!Session {
        try checkText(options.workspace);
        try checkRoleParent(options.role, options.parent);
        if (options.id) |id| {
            if (options.role != .child) return error.InvalidArgument;
            try checkId(id);
        }
        const inner = try session_mod.openNew(&m.env, .{
            .workspace = options.workspace,
            .host = options.host,
            .role = options.role,
            .parent = options.parent,
            .id = options.id,
        });
        return .{ .manager = m, .inner = inner };
    }

    /// Opens a saved session for writing: Busy if another process has it.
    pub fn openResume(m: *Manager, options: ResumeOptions) OpenError!Session {
        try checkText(options.workspace);
        if (options.parent) |p| try checkId(p);
        // Arguments are checked before the disk is asked anything.
        switch (options.target) {
            .id => |id| try checkId(id),
            .last, .last_opened => {},
        }
        if (!try readyToRead(m)) return error.NotFound;
        // An id resolved from the index is owned here.
        var resolved: ?[]u8 = null;
        defer if (resolved) |r| m.gpa.free(r);
        const id: []const u8 = switch (options.target) {
            .id => |id| id,
            .last, .last_opened => blk: {
                const target: catalog_mod.Target = switch (options.target) {
                    .last => .last,
                    .last_opened => |host| .{ .last_opened = host },
                    .id => unreachable,
                };
                resolved = (try m.resolve(options.workspace, target)) orelse return error.NotFound;
                break :blk resolved.?;
            },
        };
        const inner = session_mod.openResume(&m.env, .{
            .id = id,
            .workspace = options.workspace,
            .host = options.host,
            .parent = options.parent,
            .lock_wait_ms = options.lock_wait_ms,
        }) catch |err| return switch (err) {
            error.NotFound, error.Busy, error.ChildSession, error.Corrupt, error.UnsupportedVersion, error.OutOfMemory => |e| e,
            else => |io_err| storage.ioFault(io_err),
        };
        const session: Session = .{ .manager = m, .inner = inner };
        // The repair may have moved the workspace or interrupted a turn, so
        // the whole entry is written, not only the open time (D42).
        session.updateIndexAs(.{ .resumed = options.host });
        return session;
    }

    fn resolve(m: *Manager, workspace: []const u8, target: catalog_mod.Target) OpenError!?[]u8 {
        return m.catalog().resolve(m.gpa, workspace, target) catch |err| switch (err) {
            error.Busy => error.Busy,
            error.OutOfMemory => error.OutOfMemory,
            else => |io_err| storage.ioFault(io_err),
        };
    }

    /// A new root session that starts as a copy of `source` up to a turn
    /// boundary (D5). The source is never changed, and may be damaged
    /// (`.last_good`, D15).
    pub fn openFork(m: *Manager, options: ForkOptions) OpenError!Session {
        try checkId(options.source);
        try checkText(options.workspace);
        try ready(m);
        const inner = session_mod.openFork(&m.env, .{
            .source = options.source,
            .at = options.at,
            .workspace = options.workspace,
            .host = options.host,
        }) catch |err| return switch (err) {
            error.NotFound, error.Busy, error.ChildSession, error.Corrupt, error.UnsupportedVersion, error.InvalidForkPoint, error.OutOfMemory => |e| e,
            else => |io_err| storage.ioFault(io_err),
        };
        const session: Session = .{ .manager = m, .inner = inner };
        session.updateIndexAs(.published);
        return session;
    }

    /// The v1 conversion only (D8): a new session under an existing id,
    /// whose batches keep their original times (`Session.appendAt`). Exists
    /// if the id is taken now or was ever deleted.
    pub fn openImport(m: *Manager, options: ImportOptions) OpenError!Session {
        try checkId(options.id);
        try checkText(options.workspace);
        try checkRoleParent(options.role, options.parent);
        try ready(m);
        if (m.env.s.stat(m.env.root, options.id)) |_| return error.Exists else |err| switch (err) {
            error.NotFound => {},
            else => |io_err| return storage.ioFault(io_err),
        }
        const deleted = m.catalog().isDeleted(m.gpa, options.id) catch |err| return switch (err) {
            error.Busy => error.Busy,
            error.OutOfMemory => error.OutOfMemory,
            else => |io_err| storage.ioFault(io_err),
        };
        if (deleted) return error.Exists;
        const inner = try session_mod.openNew(&m.env, .{
            .workspace = options.workspace,
            .host = options.host,
            .role = options.role,
            .parent = options.parent,
            .id = options.id,
            .created_ms = options.created_ms,
        });
        return .{ .manager = m, .inner = inner, .import = true };
    }

    // -- by id, without a lock ------------------------------------------------

    /// A page of lines: forward from `.start` or a cursor, or backward from
    /// `.end` or a cursor. The caller frees the page.
    pub fn read(m: *Manager, gpa: std.mem.Allocator, id: []const u8, from: From, direction: Direction, limit: usize) ReadError!Page {
        try checkId(id);
        if (limit == 0) return error.InvalidArgument;
        if (!try readyToRead(m)) return error.NotFound;
        return session_mod.readPage(&m.env, gpa, id, from, direction, limit);
    }

    /// A blob's bytes, checked against its hash. The caller frees them.
    /// A saved session's state, folded without its lock as the catalog
    /// reads it: line 1, the newest snapshot, then the tail (D37). A torn
    /// tail is left as it is, and a child needs no parent to be read.
    pub fn peek(m: *Manager, gpa: std.mem.Allocator, id: []const u8) OpenError!Peeked {
        try checkId(id);
        if (!try readyToRead(m)) return error.NotFound;
        var summary = try session_mod.readSummary(&m.env, id);
        defer summary.deinit(m.gpa);
        var state = try summary.state.clone(gpa);
        errdefer state.deinit(gpa);
        state.created_ms = summary.created_ms;
        state.updated_ms = summary.updated_ms;
        const workspace = try gpa.dupe(u8, summary.identity.workspace);
        errdefer gpa.free(workspace);
        return .{
            .role = summary.identity.role,
            .parent = if (summary.identity.parent) |parent| try gpa.dupe(u8, parent) else null,
            .workspace = workspace,
            .state = state,
        };
    }

    pub fn getBlob(m: *Manager, gpa: std.mem.Allocator, id: []const u8, hash: []const u8) BlobError![]u8 {
        try checkId(id);
        if (!schema.validBlobHash(hash)) return error.InvalidArgument;
        if (!try readyToRead(m)) return error.NotFound;
        return session_mod.readBlob(&m.env, gpa, id, hash);
    }

    /// The path of a durable blob of session `id`, for a tool that opens
    /// files by path, such as a web-fetch download (D49). The file is
    /// read-only; only `getBlob` checks its bytes. The caller frees it.
    pub fn blobPath(m: *Manager, gpa: std.mem.Allocator, id: []const u8, hash: []const u8) BlobError![]u8 {
        try checkId(id);
        if (!schema.validBlobHash(hash)) return error.InvalidArgument;
        if (!try readyToRead(m)) return error.NotFound;
        try session_mod.blobExists(&m.env, id, hash);
        return std.Io.Dir.path.join(gpa, &.{ m.root_path, id, "blobs", hash });
    }

    /// Root sessions, newest first, from the index alone.
    pub fn list(m: *Manager, gpa: std.mem.Allocator, filter: Filter, cursor: ?ListCursor, limit: usize) ListError!ListPage {
        if (!try readyToRead(m)) return .{ .arena = .init(gpa), .items = &.{}, .next = null };
        return m.catalog().list(gpa, filter, cursor, @max(limit, 1));
    }

    /// Deletes a session and the children it owns. Busy if any is open.
    /// Order per session (`tla/Catalog.tla`): children first, then the
    /// rename to `.trash`, the index tombstone, and the purge. fx removes
    /// the matching terminal folders (D13).
    pub fn delete(m: *Manager, id: []const u8) DeleteError!void {
        try checkId(id);
        if (!try readyToRead(m)) return error.NotFound;
        return m.deleteDepth(id, 0);
    }

    fn deleteDepth(m: *Manager, id: []const u8, depth: usize) DeleteError!void {
        const children = try session_mod.childrenOf(&m.env, id);
        defer {
            for (children) |c| m.gpa.free(c);
            m.gpa.free(children);
        }
        if (depth < 8) for (children) |child| {
            m.deleteDepth(child, depth + 1) catch |err| switch (err) {
                error.NotFound => {},
                else => return err,
            };
        };
        try session_mod.trashSession(&m.env, id);
        m.catalog().del(id, m.nowMs()) catch m.indexStale(id);
        try session_mod.purgeTrashed(&m.env, id);
    }

    /// Doctor: checks every line and snapshot of one session.
    pub fn verify(m: *Manager, id: []const u8) VerifyError!Verified {
        try checkId(id);
        if (!try readyToRead(m)) return error.NotFound;
        return session_mod.verifySession(&m.env, id) catch |err| switch (err) {
            error.NotFound, error.OutOfMemory => |e| e,
            error.Busy, error.ChildSession, error.Corrupt, error.UnsupportedVersion => error.Io,
            else => |io_err| storage.ioFault(io_err),
        };
    }

    /// Doctor: re-derives the index and sweeps leftovers.
    pub fn rebuild(m: *Manager) RebuildError!Rebuilt {
        try ready(m);
        return m.catalog().rebuild(m.gpa);
    }
};

pub const Session = struct {
    manager: *Manager,
    inner: *session_mod.Session,
    import: bool = false,

    pub fn id(s: Session) []const u8 {
        return s.inner.id();
    }

    /// Appends a batch and returns the seq of its last line. Returns after
    /// the fsync when the batch holds a durable-class event (D3).
    pub fn append(s: Session, events: []const Event) AppendError!u64 {
        if (s.import) return error.InvalidArgument;
        return s.appendChecked(events, null);
    }

    /// Import only: appends a batch stamped with its original time.
    pub fn appendAt(s: Session, events: []const Event, ts_ms: u64) AppendError!u64 {
        if (!s.import) return error.InvalidArgument;
        return s.appendChecked(events, ts_ms);
    }

    fn appendChecked(s: Session, events: []const Event, ts_ms: ?u64) AppendError!u64 {
        try checkEvents(s.manager.gpa, events, s.import);
        // The root opens on the first publish at the latest, and an append
        // that stays held in memory does no disk I/O at all (D2).
        if (!s.inner.staysHeld(events)) try s.manager.ready();
        const result = try s.inner.appendReport(events, ts_ms);
        if (result.published) s.updateIndexAs(.published) else if (result.listing_changed) s.updateIndex();
        return result.last_seq;
    }

    /// Stores a large body and returns its hash, once it is durable (D6).
    pub fn putBlob(s: Session, bytes: []const u8) AppendError!BlobHash {
        return s.inner.putBlob(bytes);
    }

    /// As `putBlob`, for the first `len` bytes of an open file outside the
    /// session, copied in chunks (D44). A file shorter than `len` is `Io`.
    pub fn putBlobFile(s: Session, file: std.Io.File, len: u64) AppendError!BlobHash {
        return s.inner.putBlobFile(file, len);
    }

    /// A page of this session's lines through its own open log: the current
    /// session's scrollback, with no open per page. `Manager.read` is for a
    /// session that is not open here. The caller frees the page.
    pub fn read(s: Session, gpa: std.mem.Allocator, from: From, direction: Direction, limit: usize) SessionReadError!Page {
        if (limit == 0) return error.InvalidArgument;
        return s.inner.readPage(gpa, from, direction, limit);
    }

    /// An owned copy of the folded state; free with `State.deinit`.
    pub fn state(s: Session, gpa: std.mem.Allocator) error{OutOfMemory}!State {
        return s.inner.stateCopy(gpa);
    }

    /// Interrupts an open turn, appends `closed`, syncs, updates the index
    /// and releases the lock. Later calls get SessionClosed.
    pub fn close(s: Session) CloseError!void {
        const was_live = s.inner.closeReport() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => |io_err| storage.ioFault(io_err),
        };
        if (was_live) s.updateIndex();
    }

    /// Frees the handle, closing it first if needed. No other thread may
    /// still use it.
    pub fn release(s: Session) void {
        s.close() catch {};
        s.inner.destroy();
    }

    fn updateIndex(s: Session) void {
        s.updateIndexAs(.changed);
    }

    /// A new session counts as opened by the host that created it, and a
    /// resumed one by the host that resumed it, so `-c` finds it; other
    /// updates leave the open times alone.
    fn updateIndexAs(s: Session, why: union(enum) { published, changed, resumed: Host }) void {
        const m = s.manager;
        var arena = std.heap.ArenaAllocator.init(m.gpa);
        defer arena.deinit();
        var summary = s.indexSummary(arena.allocator()) catch return m.indexStale(s.id());
        switch (why) {
            .published => summary.opened_ms[@backingInt(summary.host)] = summary.updated_ms,
            .resumed => |host| summary.opened_ms[@backingInt(host)] = m.nowMs(),
            .changed => {},
        }
        m.catalog().put(summary) catch m.indexStale(s.id());
    }

    fn indexSummary(s: Session, arena: std.mem.Allocator) error{OutOfMemory}!Summary {
        const st = try s.inner.stateCopy(arena);
        const identity = &s.inner.identity;
        const workspace = try session_mod.currentWorkspace(s.inner, arena);
        return .{
            .id = identity.id,
            .role = identity.role,
            .host = identity.host,
            .workspace = workspace,
            .title = st.title,
            .language = st.language,
            .parent = identity.parent,
            // The newest line's time, as a rebuild computes it (D20).
            .created_ms = if (st.created_ms != 0) st.created_ms else s.manager.nowMs(),
            .updated_ms = if (st.updated_ms != 0) st.updated_ms else s.manager.nowMs(),
            .turns = st.committed + st.interrupted,
        };
    }
};

/// Test and driver builds only (`-Dhooks=true`): fault injection, the trace
/// writer and the internals a tracer reads. Empty in the build fx uses.
pub const hooks = if (storage.hooks) struct {
    pub const Fault = storage.Fault;
    pub const flipBit = @import("storage_fault.zig").flipBit;
    pub const Dir = storage.Dir;
    pub const Recorder = diag.Recorder;
    pub const trace = @import("trace.zig");
    pub const session = session_mod;
    pub const log = log_mod;
    pub const schema = @import("schema.zig");
} else struct {};

// ---------------------------------------------------------------------------
// Input checks (pure)

fn checkText(text: []const u8) error{InvalidArgument}!void {
    if (text.len == 0 or text.len > max_text_bytes) return error.InvalidArgument;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidArgument;
}

fn checkId(id: []const u8) error{InvalidArgument}!void {
    if (!schema.validId(id)) return error.InvalidArgument;
}

fn checkRoleParent(role: Role, parent: ?[]const u8) error{InvalidArgument}!void {
    switch (role) {
        .root => if (parent != null) return error.InvalidArgument,
        .child => try checkId(parent orelse return error.InvalidArgument),
    }
}

/// Valid JSON with no surrounding whitespace: a reader gets exactly these
/// bytes back, and a resumed state equals the live one.
fn checkJson(gpa: std.mem.Allocator, raw: []const u8) AppendError!void {
    if (raw.len > max_value_bytes) return error.TooLarge;
    if (raw.len == 0 or isJsonSpace(raw[0]) or isJsonSpace(raw[raw.len - 1])) return error.InvalidArgument;
    if (!(std.json.validate(gpa, raw) catch return error.OutOfMemory)) return error.InvalidArgument;
}

fn isJsonSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn checkJsonString(gpa: std.mem.Allocator, raw: []const u8) AppendError!void {
    try checkJson(gpa, raw);
    if (raw.len < 2 or raw[0] != '"') return error.InvalidArgument;
}

/// A JSON string of 1 to 24 bytes, as v1 stores a conversation language
/// (D18); any bytes, so every v1 value converts.
fn checkLanguage(gpa: std.mem.Allocator, raw: []const u8) AppendError!void {
    try checkJsonString(gpa, raw);
    const parsed = std.json.parseFromSlice([]const u8, gpa, raw, .{}) catch return error.InvalidArgument;
    defer parsed.deinit();
    if (parsed.value.len == 0 or parsed.value.len > max_language_bytes) return error.InvalidArgument;
}

const max_language_bytes = 24;

/// What a host may send: valid JSON for fx's content, and only the kinds
/// and reasons that belong to hosts. The manager writes the rest itself.
fn checkEvents(gpa: std.mem.Allocator, events: []const Event, import: bool) AppendError!void {
    if (events.len == 0) return error.InvalidArgument;
    for (events) |event| switch (event) {
        .turn_started, .turn_committed => {},
        .item => |piece| {
            if (!schema.validItemType(piece.type)) return error.InvalidArgument;
            try checkJson(gpa, piece.data);
            for (piece.blobs) |hash| if (!schema.validBlobHash(hash)) return error.InvalidArgument;
        },
        .compacted => |data| try checkJson(gpa, data),
        // Crash and close interruptions are the manager's; an import
        // replays whatever v1 recorded.
        .turn_interrupted => |reason| switch (reason) {
            .cancel, .failed => {},
            .closed, .crash => if (!import) return error.InvalidArgument,
        },
        .set => |s| {
            switch (s.key) {
                .title, .workspace, .client_prompt => try checkJsonString(gpa, s.value),
                .language => try checkLanguage(gpa, s.value),
                .prefs, .permissions, .usage, .tool_identities, .moved_files, .compaction_records => try checkJson(gpa, s.value),
            }
            for (s.blobs) |hash| if (!schema.validBlobHash(hash)) return error.InvalidArgument;
        },
        .child_spawned => |c| {
            try checkId(c.child);
            try checkWorkId(c.work_id);
            if (c.data) |data| try checkChildData(gpa, data);
        },
        .child_finished => |c| {
            try checkId(c.child);
            try checkWorkId(c.work_id);
            if (c.outcome == .lost and !import) return error.InvalidArgument;
            if (c.data) |data| try checkChildData(gpa, data);
        },
    };
}

/// Folded into every snapshot for each child, so kept small (D22).
fn checkChildData(gpa: std.mem.Allocator, raw: []const u8) AppendError!void {
    if (raw.len > max_child_data_bytes) return error.TooLarge;
    try checkJson(gpa, raw);
}

pub const max_child_data_bytes = 4096;

fn checkWorkId(work_id: []const u8) error{InvalidArgument}!void {
    if (work_id.len == 0 or work_id.len > 255) return error.InvalidArgument;
    if (!std.unicode.utf8ValidateSlice(work_id)) return error.InvalidArgument;
}

test {
    _ = @import("storage.zig");
    _ = @import("schema.zig");
    _ = @import("log.zig");
    _ = @import("fold.zig");
    _ = @import("session.zig");
    _ = @import("catalog.zig");
    // Fault injection and traces exist only with -Dhooks=true.
    if (storage.hooks) {
        _ = @import("storage_fault.zig");
        _ = @import("trace.zig");
    }
}

const boundary_tests = struct {
    //! The module boundary, checked on every test run: files under `src/` import
    //! only the standard library, the build options, or a sibling in `src/`.
    //! Nothing from fx reaches in, and nothing here reaches out.

    const build_options = @import("build_options");

    const Violation = struct {
        import: []const u8,
    };

    /// Pure: returns the first import in `source` that crosses the boundary.
    fn firstViolation(source: []const u8) ?Violation {
        const marker = "@import(\"";
        var at: usize = 0;
        while (std.mem.findPos(u8, source, at, marker)) |start| {
            const name_start = start + marker.len;
            const name_end = std.mem.findScalarPos(u8, source, name_start, '"') orelse
                return .{ .import = source[name_start..] };
            const name = source[name_start..name_end];
            if (!allowed(name)) return .{ .import = name };
            at = name_end;
        }
        return null;
    }

    fn allowed(name: []const u8) bool {
        const packages = [_][]const u8{ "std", "builtin", "build_options" };
        for (packages) |package| {
            if (std.mem.eql(u8, name, package)) return true;
        }
        // A sibling file: `x.zig` with no path separator and no parent reference.
        return std.mem.endsWith(u8, name, ".zig") and
            std.mem.findScalar(u8, name, '/') == null and
            std.mem.findScalar(u8, name, '\\') == null;
    }

    test "boundary scanner accepts std and siblings" {
        try std.testing.expectEqual(@as(?Violation, null), firstViolation(
            \\const std = @import("std");
            \\const log = @import("log.zig");
            \\const options = @import("build_options");
        ));
    }

    test "boundary scanner rejects parent paths and foreign packages" {
        const up = firstViolation("const x = @import(\"../fx/src/main.zig\");").?;
        try std.testing.expectEqualStrings("../fx/src/main.zig", up.import);
        const foreign = firstViolation("const z = @import(\"zero\");").?;
        try std.testing.expectEqualStrings("zero", foreign.import);
        const unterminated = firstViolation("@import(\"std").?;
        try std.testing.expectEqualStrings("std", unterminated.import);
    }

    test "every file under src stays inside the boundary" {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        var dir = try std.Io.Dir.cwd().openDir(io, build_options.src_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var files: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(4 << 20));
            defer gpa.free(source);
            if (firstViolation(source)) |violation| {
                std.debug.print("{s} imports \"{s}\"\n", .{ entry.name, violation.import });
                return error.BoundaryViolation;
            }
            files += 1;
        }
        try std.testing.expect(files >= 2);
    }
};

test {
    _ = boundary_tests;
}

const api_tests = struct {
    //! The API as fx will use it: this file imports only `api.zig`.

    const api = @import("api.zig");

    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    const Recorder = struct {
        kinds: std.ArrayList(api.DiagnosticKind) = .empty,
        mutex: std.Io.Mutex = .init,

        fn sink(r: *Recorder) api.Diagnostics {
            return .{ .context = r, .emit = emit };
        }

        fn emit(context: ?*anyopaque, event: api.Diagnostic) void {
            const r: *Recorder = @ptrCast(@alignCast(context.?));
            r.mutex.lockUncancelable(io);
            defer r.mutex.unlock(io);
            r.kinds.append(gpa, event.kind) catch {};
        }

        fn count(r: *Recorder, kind: api.DiagnosticKind) usize {
            var n: usize = 0;
            for (r.kinds.items) |k| {
                if (k == kind) n += 1;
            }
            return n;
        }
    };

    const Fixture = struct {
        tmp: testing.TmpDir,
        root: []u8,
        recorder: Recorder = .{},
        manager: *api.Manager,

        fn init(f: *Fixture) !void {
            return f.initWith(1 << 20);
        }

        fn initWith(f: *Fixture, index_compact_bytes: u64) !void {
            f.tmp = testing.tmpDir(.{ .iterate = true });
            const base = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
            defer gpa.free(base);
            f.root = try std.Io.Dir.path.join(gpa, &.{ base, "sessions", "v2" });
            f.recorder = .{};
            f.manager = try api.Manager.init(gpa, io, .{
                .root = f.root,
                .diagnostics = f.recorder.sink(),
                .lock_wait_ms = 50,
                .index_compact_bytes = index_compact_bytes,
            });
        }

        fn deinit(f: *Fixture) void {
            f.manager.deinit();
            f.recorder.kinds.deinit(gpa);
            gpa.free(f.root);
            f.tmp.cleanup();
        }

        fn dir(f: *Fixture) !std.Io.Dir {
            return std.Io.Dir.cwd().openDir(io, f.root, .{});
        }
    };

    const piece: api.Event = .{ .item = .{ .type = "assistant", .data = "{\"text\":\"hi\"}" } };

    /// Returns once the wall clock shows a later millisecond than when called.
    fn nextMillisecond() !void {
        const start = std.Io.Timestamp.now(io, .real).toMilliseconds();
        while (std.Io.Timestamp.now(io, .real).toMilliseconds() == start) try io.sleep(.fromMilliseconds(1), .awake);
    }

    fn listIds(m: *api.Manager, filter: api.Filter) ![][]const u8 {
        var page = try m.list(gpa, filter, null, 100);
        defer page.deinit();
        const ids = try gpa.alloc([]const u8, page.items.len);
        for (page.items, ids) |item, *id| id.* = try gpa.dupe(u8, item.id);
        return ids;
    }

    fn freeIds(ids: [][]const u8) void {
        for (ids) |id| gpa.free(id);
        gpa.free(ids);
    }

    test "init touches nothing on disk" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try testing.expectError(error.FileNotFound, f.dir());
        // Held settings and a close before any turn: still nothing, not even the
        // root folder, so fx starting up does no session I/O (D2).
        const s = try f.manager.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{.{ .set = .{ .key = .title, .value = "\"draft\"" } }});
        s.release();
        try testing.expectError(error.FileNotFound, f.dir());
        // The first turn creates the root and publishes the session.
        const t = try f.manager.openNew(.{ .workspace = "/w", .host = .app });
        defer t.release();
        _ = try t.append(&.{ .turn_started, piece, .turn_committed });
        var root = try f.dir();
        root.close(io);
    }

    test "reads before any session create nothing on disk" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        // An editor listing sessions on a machine that never saved one.
        var page = try f.manager.list(gpa, .all, null, 10);
        try testing.expectEqual(@as(usize, 0), page.items.len);
        page.deinit();
        try testing.expectError(error.NotFound, f.manager.read(gpa, "AAAAAAAAAAAA", .start, .forward, 10));
        try testing.expectError(error.NotFound, f.manager.getBlob(gpa, "AAAAAAAAAAAA", &@as([64]u8, @splat('0'))));
        try testing.expectError(error.NotFound, f.manager.openResume(.{ .target = .last, .workspace = "/w", .host = .acp }));
        try testing.expectError(error.NotFound, f.manager.verify("AAAAAAAAAAAA"));
        try testing.expectError(error.NotFound, f.manager.delete("AAAAAAAAAAAA"));
        try testing.expectError(error.FileNotFound, f.dir());
        // Once a session is saved, the same calls find it.
        const s = try f.manager.openNew(.{ .workspace = "/w", .host = .acp });
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        s.release();
        var listed = try f.manager.list(gpa, .all, null, 10);
        defer listed.deinit();
        try testing.expectEqual(@as(usize, 1), listed.items.len);
    }

    test "a read-only session folder fails with AccessDenied, not Io (D29)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const s = try f.manager.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();
        var root = try f.dir();
        defer root.close(io);
        var folder = try root.openDir(io, id, .{});
        defer folder.close(io);
        try folder.setFilePermissions(io, "log.jsonl", .fromMode(0o400), .{});
        defer folder.setFilePermissions(io, "log.jsonl", .fromMode(0o600), .{}) catch {};
        try testing.expectError(error.AccessDenied, f.manager.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app }));
    }

    test "a session's whole life through the API" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{.{ .set = .{ .key = .title, .value = "\"first\"" } }});
        _ = try s.append(&.{ .turn_started, piece });
        const hash = try s.putBlob("big tool output");
        const refs = [_][]const u8{&hash};
        _ = try s.append(&.{ .{ .item = .{ .type = "tool_result", .data = "{\"tool\":1}", .blobs = &refs } }, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);

        // Listed from the first turn on, with its title.
        {
            var page = try m.list(gpa, .{ .workspace = "/w" }, null, 10);
            defer page.deinit();
            try testing.expectEqual(@as(usize, 1), page.items.len);
            try testing.expectEqualStrings("\"first\"", page.items[0].title.?);
        }
        s.release();
        {
            var page = try m.list(gpa, .all, null, 10);
            defer page.deinit();
            try testing.expectEqual(@as(u64, 1), page.items[0].turns);
        }

        // Scrollback: newest first.
        var back = try m.read(gpa, id, .end, .backward, 2);
        defer back.deinit();
        try testing.expectEqual(api.Kind.closed, back.entries[0].kind.?);
        try testing.expectEqual(api.Kind.turn_committed, back.entries[1].kind.?);
        const bytes = try m.getBlob(gpa, id, &hash);
        defer gpa.free(bytes);
        try testing.expectEqualStrings("big tool output", bytes);

        // Resume, state, and verify.
        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .ask });
        var state = try r.state(gpa);
        defer state.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), state.committed);
        try testing.expect(state.clean_exit);
        r.release();
        const verified = try m.verify(id);
        try testing.expectEqual(@as(?u64, null), verified.damaged_at);
        try testing.expectEqual(@as(u64, 0), verified.bad_snapshots);
    }

    test "sessions tied on their update time resolve as the list sorts them (D11)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        // Written in the same millisecond, as a fast machine does.
        for ([_][]const u8{ "1786460757753-tie-f", "1786460757753-tie-c", "1786460757753-tie-e", "1786460757753-tie-a", "1786460757753-tie-d", "1786460757753-tie-b" }) |id| {
            const s = try m.openImport(.{ .id = id, .workspace = "/w", .host = .app, .created_ms = 1000 });
            _ = try s.appendAt(&.{ .turn_started, .turn_committed }, 2000);
            s.release();
        }
        const ids = try listIds(m, .all);
        defer freeIds(ids);
        try testing.expectEqualStrings("1786460757753-tie-a", ids[0]);
        const last = try m.openResume(.{ .target = .last, .workspace = "/w", .host = .ask });
        defer last.release();
        try testing.expectEqualStrings(ids[0], last.id());
    }

    test "-c and --resume last stay distinct (D11)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const a = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try a.append(&.{ .turn_started, .turn_committed });
        const a_id = try gpa.dupe(u8, a.id());
        defer gpa.free(a_id);
        a.release();
        const b = try m.openNew(.{ .workspace = "/w", .host = .ask });
        _ = try b.append(&.{ .turn_started, .turn_committed });
        const b_id = try gpa.dupe(u8, b.id());
        defer gpa.free(b_id);
        b.release();
        const other = try m.openNew(.{ .workspace = "/elsewhere", .host = .app });
        _ = try other.append(&.{ .turn_started, .turn_committed });
        other.release();

        // The app opens a; then ask and acp open b, a millisecond later at
        // least, so b is the newer one however fast this runs.
        (try m.openResume(.{ .target = .{ .id = a_id }, .workspace = "/w", .host = .app })).release();
        try nextMillisecond();
        (try m.openResume(.{ .target = .{ .id = b_id }, .workspace = "/w", .host = .ask })).release();
        (try m.openResume(.{ .target = .{ .id = b_id }, .workspace = "/w", .host = .acp })).release();

        // b was updated last (closed by acp); the app last opened a. Resuming
        // is itself an open, so this check runs as `fx ask --resume last`.
        const last = try m.openResume(.{ .target = .last, .workspace = "/w", .host = .ask });
        try testing.expectEqualStrings(b_id, last.id());
        last.release();
        const c = try m.openResume(.{ .target = .{ .last_opened = .app }, .workspace = "/w", .host = .app });
        try testing.expectEqualStrings(a_id, c.id());
        c.release();
        try testing.expectError(error.NotFound, m.openResume(.{ .target = .{ .last_opened = .sdk }, .workspace = "/w", .host = .sdk }));
        try testing.expectError(error.NotFound, m.openResume(.{ .target = .last, .workspace = "/nowhere", .host = .app }));
    }

    test "a resume from another workspace lists the session there at once, and keeps -c (D42)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .acp });
        _ = try s.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        // Still open: the index names the new workspace before any close.
        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/x", .host = .app });
        try expectListedIn(m, "/x", id);
        try expectListedIn(m, "/w", null);
        r.release();
        try expectListedIn(m, "/x", id);
        // The resume counts as the app's open, so `-c` in /x finds it.
        const c = try m.openResume(.{ .target = .{ .last_opened = .app }, .workspace = "/x", .host = .app });
        try testing.expectEqualStrings(id, c.id());
        c.release();
    }

    fn expectListedIn(m: *api.Manager, workspace: []const u8, want: ?[]const u8) !void {
        var page = try m.list(gpa, .{ .workspace = workspace }, null, 10);
        defer page.deinit();
        if (want) |expected| {
            try testing.expectEqual(@as(usize, 1), page.items.len);
            try testing.expectEqualStrings(expected, page.items[0].id);
        } else {
            try testing.expectEqual(@as(usize, 0), page.items.len);
        }
    }

    test "fork, children, delete: listing and ids" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const p = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try p.append(&.{ .turn_started, piece, .turn_committed });
        const p_id = try gpa.dupe(u8, p.id());
        defer gpa.free(p_id);
        const c = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p_id });
        _ = try p.append(&.{ .turn_started, .{ .child_spawned = .{ .child = c.id(), .work_id = "w" } } });
        _ = try c.append(&.{ .turn_started, .turn_committed });
        _ = try p.append(&.{ .{ .child_finished = .{ .child = c.id(), .work_id = "w", .outcome = .ok } }, .turn_committed });
        const c_id = try gpa.dupe(u8, c.id());
        defer gpa.free(c_id);
        c.release();

        const fork = try m.openFork(.{ .source = p_id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, fork.id());
        defer gpa.free(fork_id);
        fork.release();

        // Children are never listed.
        const ids = try listIds(m, .all);
        defer freeIds(ids);
        try testing.expectEqual(@as(usize, 2), ids.len);
        for (ids) |id| try testing.expect(!std.mem.eql(u8, id, c_id));

        try testing.expectError(error.Busy, m.delete(p_id));
        p.release();
        try m.delete(p_id);
        try testing.expectError(error.NotFound, m.read(gpa, c_id, .start, .forward, 1));
        const after = try listIds(m, .all);
        defer freeIds(after);
        try testing.expectEqual(@as(usize, 1), after.len);
        try testing.expectEqualStrings(fork_id, after[0]);
        // A deleted id never comes back, not even through an import.
        try testing.expectError(error.Exists, m.openImport(.{ .id = p_id, .workspace = "/w", .host = .app, .created_ms = 1 }));
        try testing.expectError(error.NotFound, m.delete(p_id));
    }

    test "a child opens under the id its parent recorded, until its first turn creates the log (D34)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const p = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer p.release();
        const child_id = "1786460757753-child";
        _ = try p.append(&.{ .turn_started, .{ .child_spawned = .{ .child = child_id, .work_id = "w1" } } });

        // The first attempt never starts a turn, as when a crash loses the work:
        // nothing reaches the disk, and the id stays free for the next attempt.
        const lost = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id(), .id = child_id });
        try testing.expectEqualStrings(child_id, lost.id());
        lost.release();
        try testing.expectError(error.NotFound, m.read(gpa, child_id, .start, .forward, 1));

        const c = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id(), .id = child_id });
        _ = try c.append(&.{ .turn_started, piece, .turn_committed });
        c.release();
        var page = try m.read(gpa, child_id, .start, .forward, 1);
        defer page.deinit();
        try testing.expectEqual(api.Kind.session_created, page.entries[0].kind.?);
        // Resuming it needs its parent, as for any child.
        try testing.expectError(error.ChildSession, m.openResume(.{ .target = .{ .id = child_id }, .workspace = "/w", .host = .child }));
        const again = try m.openResume(.{ .target = .{ .id = child_id }, .workspace = "/w", .host = .child, .parent = p.id() });
        again.release();
    }

    test "only a child takes an id, it must be valid, and a taken id never replaces a session (D34)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        try testing.expectError(error.InvalidArgument, m.openNew(.{ .workspace = "/w", .host = .app, .id = "1786460757753-root" }));
        const p = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer p.release();
        _ = try p.append(&.{ .turn_started, piece, .turn_committed });
        try testing.expectError(error.InvalidArgument, m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id(), .id = "../escape" }));

        const first = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id(), .id = "1786460757753-taken" });
        _ = try first.append(&.{ .turn_started, piece, .turn_committed });
        first.release();
        var before = try m.read(gpa, "1786460757753-taken", .start, .forward, 100);
        defer before.deinit();

        const second = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id(), .id = "1786460757753-taken" });
        defer second.release();
        try testing.expectError(error.Io, second.append(&.{ .turn_started, piece, .turn_committed }));
        var after = try m.read(gpa, "1786460757753-taken", .start, .forward, 100);
        defer after.deinit();
        try testing.expectEqual(before.entries.len, after.entries.len);
        for (before.entries, after.entries) |b, a| {
            try testing.expectEqual(b.seq, a.seq);
            try testing.expectEqual(b.kind, a.kind);
            try testing.expectEqual(b.ts_ms, a.ts_ms);
        }
    }

    test "peek reads a session without its lock and repairs nothing (D37)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        // Nothing saved yet: NotFound, and the root is not created.
        try testing.expectError(error.NotFound, m.peek(gpa, "1786460757753-none"));
        try testing.expectError(error.InvalidArgument, m.peek(gpa, "../escape"));

        const p = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try p.append(&.{ .turn_started, piece, .turn_committed, .{ .set = .{ .key = .title, .value = "\"T\"" } } });
        const p_id = try gpa.dupe(u8, p.id());
        defer gpa.free(p_id);
        // Open for writing elsewhere: peek still reads it.
        {
            var peeked = try m.peek(gpa, p_id);
            defer peeked.deinit(gpa);
            try testing.expectEqual(api.Role.root, peeked.role);
            try testing.expectEqualStrings("/w", peeked.workspace);
            try testing.expectEqual(@as(u64, 1), peeked.state.last_turn);
            try testing.expectEqualStrings("\"T\"", peeked.state.title.?);
            try testing.expect(peeked.state.created_ms > 0);
        }
        const c = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p_id, .id = "1786460757753-peek-kid" });
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c.id(), .work_id = "w" } }});
        _ = try c.append(&.{ .turn_started, .turn_committed });
        c.release();
        p.release();

        // A child reads without its parent.
        {
            var peeked = try m.peek(gpa, "1786460757753-peek-kid");
            defer peeked.deinit(gpa);
            try testing.expectEqual(api.Role.child, peeked.role);
            try testing.expectEqualStrings(p_id, peeked.parent.?);
        }

        // A torn tail is read around and left in place.
        var root = try f.dir();
        defer root.close(io);
        const log_path = try std.Io.Dir.path.join(gpa, &.{ p_id, "log.jsonl" });
        defer gpa.free(log_path);
        var torn_len: u64 = 0;
        {
            var log = try root.openFile(io, log_path, .{ .mode = .read_write });
            defer log.close(io);
            try log.writePositionalAll(io, "{\"v\":1,\"seq", try log.length(io));
            torn_len = try log.length(io);
        }
        var peeked = try m.peek(gpa, p_id);
        defer peeked.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), peeked.state.last_turn);
        const after = try root.statFile(io, log_path, .{});
        try testing.expectEqual(torn_len, after.size);
    }

    test "import keeps the v1 id and the original times" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openImport(.{ .id = "1786460757753-v1", .workspace = "/w", .host = .app, .created_ms = 1000 });
        try testing.expectError(error.InvalidArgument, s.append(&.{.turn_started}));
        _ = try s.appendAt(&.{ .turn_started, piece, .turn_committed }, 2000);
        _ = try s.appendAt(&.{ .turn_started, .{ .turn_interrupted = .crash } }, 3000);
        s.release();
        var page = try m.read(gpa, "1786460757753-v1", .start, .forward, 10);
        defer page.deinit();
        try testing.expectEqual(@as(u64, 1000), page.entries[0].ts_ms);
        try testing.expectEqual(@as(u64, 2000), page.entries[1].ts_ms);
        try testing.expectEqual(@as(u64, 3000), page.entries[5].ts_ms);
        try testing.expectError(error.Exists, m.openImport(.{ .id = "1786460757753-v1", .workspace = "/w", .host = .app, .created_ms = 1 }));
        // The list shows the original times, not the time of the conversion (D20).
        var listed = try m.list(gpa, .all, null, 10);
        defer listed.deinit();
        try testing.expectEqual(@as(u64, 1000), listed.items[0].created_ms);
        try testing.expectEqual(@as(u64, 3000), listed.items[0].updated_ms);
    }

    /// `ts` of the newest line in a session's log.
    fn newestTs(m: *api.Manager, id: []const u8) !u64 {
        var page = try m.read(gpa, id, .end, .backward, 1);
        defer page.deinit();
        return page.entries[0].ts_ms;
    }

    test "state carries the created and updated times, and the list agrees (D20)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        {
            var st = try s.state(gpa);
            defer st.deinit(gpa);
            try testing.expectEqual(@as(u64, 0), st.created_ms);
            try testing.expectEqual(@as(u64, 0), st.updated_ms);
        }
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        var first = try s.state(gpa);
        defer first.deinit(gpa);
        try testing.expect(first.created_ms > 0);
        try testing.expectEqual(try newestTs(m, id), first.updated_ms);
        s.release();

        // Resume reads both back from the log; the list shows the same times.
        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app });
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqual(first.created_ms, st.created_ms);
        try testing.expectEqual(try newestTs(m, id), st.updated_ms);
        r.release();
        var listed = try m.list(gpa, .all, null, 10);
        defer listed.deinit();
        try testing.expectEqual(first.created_ms, listed.items[0].created_ms);
        try testing.expectEqual(try newestTs(m, id), listed.items[0].updated_ms);

        // A fork is created now; its copied lines keep older times.
        const fk = try m.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        defer fk.release();
        var forked = try fk.state(gpa);
        defer forked.deinit(gpa);
        try testing.expect(forked.created_ms >= st.updated_ms);
        try testing.expectEqual(forked.created_ms, forked.updated_ms);
    }

    test "hosts end turns as cancel or failed; closed and crash stay the manager's (D21)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const s = try f.manager.openNew(.{ .workspace = "/w", .host = .app });
        defer s.release();
        _ = try s.append(&.{.turn_started});
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .turn_interrupted = .closed }}));
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .turn_interrupted = .crash }}));
        _ = try s.append(&.{.{ .turn_interrupted = .failed }});
        var st = try s.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqual(api.Reason.failed, st.last_interrupted.?.reason);
    }

    test "child data is small, exact, and never lost; outcomes include cancelled (D22)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const p = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer p.release();
        _ = try p.append(&.{.turn_started});
        const c = try m.openNew(.{ .workspace = "/w", .host = .child, .role = .child, .parent = p.id() });
        defer c.release();

        const big = try gpa.alloc(u8, api.max_child_data_bytes + 1);
        defer gpa.free(big);
        @memset(big, 'a');
        big[0] = '"';
        big[big.len - 1] = '"';
        try testing.expectError(error.TooLarge, p.append(&.{.{ .child_spawned = .{ .child = c.id(), .work_id = "w1", .data = big } }}));
        try testing.expectError(error.InvalidArgument, p.append(&.{.{ .child_spawned = .{ .child = c.id(), .work_id = "w1", .data = " {}" } }}));
        const data = "{\"name\": \"reviewer\", \"agent\": \"general\"}";
        _ = try p.append(&.{.{ .child_spawned = .{ .child = c.id(), .work_id = "w1", .data = data } }});
        try testing.expectError(error.InvalidArgument, p.append(&.{.{ .child_finished = .{ .child = c.id(), .work_id = "w1", .outcome = .lost } }}));
        try testing.expectError(error.InvalidTransition, p.append(&.{.{ .child_spawned = .{ .child = c.id(), .work_id = "w2" } }}));
        _ = try p.append(&.{.{ .child_finished = .{ .child = c.id(), .work_id = "w1", .outcome = .cancelled } }});

        var st = try p.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), st.children.items.len);
        const child: api.Child = st.children.items[0];
        try testing.expectEqualStrings(c.id(), child.id);
        try testing.expectEqualStrings(data, child.spawn_data.?);
        try testing.expectEqual(@as(?api.Outcome, .cancelled), child.outcome);
        try testing.expect(!child.open);
    }

    test "raw values with surrounding whitespace are refused, so readers get the exact bytes" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const s = try f.manager.openNew(.{ .workspace = "/w", .host = .app });
        defer s.release();
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .prefs, .value = "{} " } }}));
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .title, .value = " \"t\"" } }}));
        _ = try s.append(&.{ .turn_started, .{ .set = .{ .key = .usage, .value = "null" } } });
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .item = .{ .type = "user", .data = "\n{}" } }}));
    }

    test "a state too large for one snapshot is skipped and reported; the append and resume stand" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        // Two settings of 3 MiB each fit one line apiece, but not one snapshot.
        const big = try gpa.alloc(u8, 3 << 20);
        defer gpa.free(big);
        @memset(big, 'a');
        big[0] = '"';
        big[big.len - 1] = '"';
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, .{ .set = .{ .key = .prefs, .value = big } } });
        _ = try s.append(&.{.{ .set = .{ .key = .usage, .value = big } }});
        _ = try s.append(&.{ .{ .compacted = "{}" }, .turn_committed });
        try testing.expect(f.recorder.count(.snapshot_skipped) >= 1);
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app });
        defer r.release();
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), st.committed);
        try testing.expectEqualStrings(big, st.prefs.?);
        try testing.expectEqualStrings(big, st.usage.?);
        const verified = try m.verify(id);
        try testing.expectEqual(@as(?u64, null), verified.damaged_at);
        try testing.expectEqual(@as(u64, 0), verified.bad_snapshots);
    }

    test "list self-heals a missing folder and rebuild restores the index, each reported once" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        var ids: [3][]u8 = undefined;
        for (&ids) |*id| {
            const s = try m.openNew(.{ .workspace = "/w", .host = .app });
            _ = try s.append(&.{ .turn_started, .turn_committed });
            id.* = try gpa.dupe(u8, s.id());
            s.release();
        }
        defer for (ids) |id| gpa.free(id);
        var root = try f.dir();
        defer root.close(io);

        // A folder vanishes behind the manager's back.
        try root.deleteTree(io, ids[0]);
        const healed = try listIds(m, .all);
        defer freeIds(healed);
        try testing.expectEqual(@as(usize, 2), healed.len);
        try testing.expectEqual(@as(usize, 1), f.recorder.count(.index_healed));
        const again = try listIds(m, .all);
        defer freeIds(again);
        try testing.expectEqual(@as(usize, 1), f.recorder.count(.index_healed));

        // The index is lost, and a leftover sits in .trash.
        try root.deleteFile(io, "index.jsonl");
        try root.createDirPath(io, ".trash/leftover");
        const empty = try listIds(m, .all);
        defer freeIds(empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
        const rebuilt = try m.rebuild();
        try testing.expectEqual(@as(u64, 2), rebuilt.sessions);
        try testing.expectEqual(@as(u64, 1), rebuilt.swept);
        try testing.expectEqual(@as(usize, 1), f.recorder.count(.rebuild_swept));
        const restored = try listIds(m, .all);
        defer freeIds(restored);
        try testing.expectEqual(@as(usize, 2), restored.len);
    }

    test "a torn index tail is cut before the next record, and a big index compacts" {
        var f: Fixture = undefined;
        try f.initWith(4096);
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();
        var root = try f.dir();
        defer root.close(io);
        {
            var index = try root.openFile(io, "index.jsonl", .{ .mode = .read_write });
            defer index.close(io);
            const len = try index.length(io);
            try index.writePositionalAll(io, "{\"op\":\"put\",\"id\":\"tor", len);
        }
        for (0..40) |_| (try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app })).release();
        const ids = try listIds(m, .all);
        defer freeIds(ids);
        try testing.expectEqual(@as(usize, 1), ids.len);
        try testing.expectEqual(@as(usize, 0), f.recorder.count(.index_healed));
        const st = try root.statFile(io, "index.jsonl", .{});
        try testing.expect(st.size < 4096);
    }

    test "inputs are checked at the boundary" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        try testing.expectError(error.InvalidArgument, m.openNew(.{ .workspace = "", .host = .app }));
        try testing.expectError(error.InvalidArgument, m.openNew(.{ .workspace = "/w", .host = .child, .role = .child }));
        try testing.expectError(error.InvalidArgument, m.openResume(.{ .target = .{ .id = "../etc" }, .workspace = "/w", .host = .app }));
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer s.release();
        _ = try s.append(&.{.turn_started});
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .item = .{ .type = "assistant", .data = "{not json" } }}));
        for ([_][]const u8{ "", "Steering", "tool-call", &@as([33]u8, @splat('x')) }) |bad_type| {
            try testing.expectError(error.InvalidArgument, s.append(&.{.{ .item = .{ .type = bad_type, .data = "{}" } }}));
        }
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .title, .value = "42" } }}));
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .turn_interrupted = .crash }}));
        try testing.expectError(error.InvalidArgument, s.append(&.{}));
        try testing.expectError(error.InvalidArgument, m.getBlob(gpa, s.id(), "nothex"));
        // Nothing was written by any refused call.
        var page = try m.read(gpa, s.id(), .start, .forward, 10);
        defer page.deinit();
        try testing.expectEqual(@as(usize, 2), page.entries.len);
    }

    test "item types: stored on the line, returned by read, never interpreted" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        const types = [_][]const u8{ "user", "assistant", "tool_call", "tool_result", "steering", "a_name_fx_adds_later" };
        _ = try s.append(&.{.turn_started});
        for (types) |t| _ = try s.append(&.{.{ .item = .{ .type = t, .data = "{}" } }});
        _ = try s.append(&.{.turn_committed});
        s.release();

        // `read` gives every type back, in order.
        var page = try m.read(gpa, id, .start, .forward, 100);
        defer page.deinit();
        var seen: usize = 0;
        for (page.entries) |entry| {
            const body = entry.body orelse continue;
            if (body != .item) continue;
            try testing.expectEqualStrings(types[seen], body.item.type);
            seen += 1;
        }
        try testing.expectEqual(types.len, seen);

        // On disk the type is a plain field, so `grep` and `jq` find a steer.
        var dir = try f.dir();
        defer dir.close(io);
        var path: [300]u8 = undefined;
        const bytes = try dir.readFileAlloc(io, try std.mem.print(&path, "{s}/log.jsonl", .{id}), gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"kind\":\"item\",\"turn\":1,\"type\":\"steering\""));
    }

    test "the conversation language is listed, follows changes, survives rebuild and resume" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        // Held before the first turn, like any setting (D2).
        _ = try s.append(&.{.{ .set = .{ .key = .language, .value = "\"es\"" } }});
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        try expectListedLanguage(m, "\"es\"");

        _ = try s.append(&.{.{ .set = .{ .key = .language, .value = "\"und-Latn\"" } }});
        try expectListedLanguage(m, "\"und-Latn\"");

        // Refused: not a string, empty, longer than 24 bytes. Nothing changes.
        for ([_][]const u8{ "42", "\"\"", "\"" ++ &@as([25]u8, @splat('x')) ++ "\"" }) |bad| {
            try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .language, .value = bad } }}));
        }
        s.release();
        try expectListedLanguage(m, "\"und-Latn\"");

        // The index is derived: a rebuild finds the language in the log.
        _ = try m.rebuild();
        try expectListedLanguage(m, "\"und-Latn\"");

        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app });
        defer r.release();
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqualStrings("\"und-Latn\"", st.language.?);
    }

    fn expectListedLanguage(m: *api.Manager, want: []const u8) !void {
        var page = try m.list(gpa, .all, null, 10);
        defer page.deinit();
        try testing.expectEqual(@as(usize, 1), page.items.len);
        try testing.expectEqualStrings(want, page.items[0].language.?);
    }

    test "Session.read pages the open session exactly like read by id" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer s.release();
        // Nothing on disk before the first turn: an empty page, not an error.
        var empty = try s.read(gpa, .end, .backward, 10);
        try testing.expectEqual(@as(usize, 0), empty.entries.len);
        empty.deinit();
        try testing.expectError(error.InvalidArgument, s.read(gpa, .end, .backward, 0));

        for (0..12) |_| _ = try s.append(&.{ .turn_started, piece, piece, .turn_committed });
        for ([_]api.Direction{ .backward, .forward }) |direction| {
            var from_open: api.From = if (direction == .backward) .end else .start;
            var from_id = from_open;
            var pages: usize = 0;
            while (true) : (pages += 1) {
                var a = try s.read(gpa, from_open, direction, 7);
                defer a.deinit();
                var b = try m.read(gpa, s.id(), from_id, direction, 7);
                defer b.deinit();
                try testing.expectEqual(b.entries.len, a.entries.len);
                for (a.entries, b.entries) |x, y| {
                    try testing.expectEqual(y.seq, x.seq);
                    try testing.expectEqual(y.offset, x.offset);
                }
                try testing.expectEqual(b.next == null, a.next == null);
                from_open = .{ .at = a.next orelse break };
                from_id = .{ .at = b.next.? };
            }
            try testing.expect(pages > 1);
        }
    }

    test "Session.read while another thread appends, and after close" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        const Writer = struct {
            fn run(session: api.Session) void {
                for (0..200) |_| _ = session.append(&.{ .turn_started, piece, .turn_committed }) catch return;
            }
        };
        const writer = try std.Thread.spawn(.{}, Writer.run, .{s});
        for (0..200) |_| {
            var page = try s.read(gpa, .end, .backward, 20);
            defer page.deinit();
            // Newest first, one line after another, never a torn line.
            for (page.entries[1..], page.entries[0 .. page.entries.len - 1]) |older, newer| {
                try testing.expectEqual(newer.seq - 1, older.seq);
            }
        }
        writer.join();
        try s.close();
        try testing.expectError(error.SessionClosed, s.read(gpa, .end, .backward, 10));
        s.release();
    }

    test "a resume sets its own wait for a held session, and none is Busy at once (D38)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const held = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try held.append(&.{ .turn_started, piece, .turn_committed });
        const id = try gpa.dupe(u8, held.id());
        defer gpa.free(id);
        var released = false;
        defer if (!released) held.release();

        const Timed = struct {
            fn busyAfterMs(manager: *api.Manager, session_id: []const u8, wait: ?u64) !i64 {
                const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
                try testing.expectError(error.Busy, manager.openResume(.{ .target = .{ .id = session_id }, .workspace = "/w", .host = .app, .lock_wait_ms = wait }));
                return std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;
            }
        };
        // The fixture's manager waits 50 ms; each open's own wait wins.
        try testing.expect(try Timed.busyAfterMs(m, id, 400) >= 400);
        try testing.expect(try Timed.busyAfterMs(m, id, 0) < 400);
        try testing.expect(try Timed.busyAfterMs(m, id, null) < 400);

        held.release();
        released = true;
        const reopened = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app, .lock_wait_ms = 0 });
        reopened.release();
    }

    test "a lost or damaged blob damages its session: verify counts it and a recover fork stops before it (D39)" {
        for ([_]bool{ false, true }) |overwrite| {
            var f: Fixture = undefined;
            try f.init();
            defer f.deinit();
            const m = f.manager;
            const s = try m.openNew(.{ .workspace = "/w", .host = .app });
            // Turn 1 names no blob, turn 2 names one, turn 3 names none.
            _ = try s.append(&.{ .turn_started, piece, .turn_committed });
            _ = try s.append(&.{.turn_started});
            const hash = try s.putBlob("the body of a long answer");
            const refs = [_][]const u8{&hash};
            _ = try s.append(&.{ .{ .item = .{ .type = "assistant", .data = "{}", .blobs = &refs } }, .turn_committed });
            _ = try s.append(&.{ .turn_started, piece, .turn_committed });
            const id = try gpa.dupe(u8, s.id());
            defer gpa.free(id);
            s.release();
            try testing.expectEqual(@as(u64, 0), (try m.verify(id)).bad_blobs);

            var root = try f.dir();
            defer root.close(io);
            const path = try gpa.print("{s}/blobs/{s}", .{ id, &hash });
            defer gpa.free(path);
            if (overwrite) {
                // A blob is read-only (D49), so damage replaces the file, as
                // an editor that renames over it would.
                try testing.expectError(error.AccessDenied, root.writeFile(io, .{ .sub_path = path, .data = "x" }));
                try root.deleteFile(io, path);
                try root.writeFile(io, .{ .sub_path = path, .data = "the body of a long ANSWER" });
            } else {
                try root.deleteFile(io, path);
            }

            // The log is intact; the blob it names is not.
            const verified = try m.verify(id);
            try testing.expectEqual(@as(u64, 1), verified.bad_blobs);
            try testing.expectEqual(@as(?u64, null), verified.damaged_at);
            try testing.expectError(if (overwrite) error.Corrupt else error.NotFound, m.getBlob(gpa, id, &hash));

            // Recover copies turn 1 only; a fork past turn 1 is refused.
            const copy = try m.openFork(.{ .source = id, .at = .last_good, .workspace = "/w", .host = .app });
            var st = try copy.state(gpa);
            defer st.deinit(gpa);
            try testing.expectEqual(@as(u64, 1), st.last_turn);
            copy.release();
            try testing.expectError(error.InvalidForkPoint, m.openFork(.{ .source = id, .at = .{ .turn = 3 }, .workspace = "/w", .host = .app }));
            const early = try m.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
            early.release();
        }
    }

    test "a setting lists blobs outside a turn under the item's rule, and fork, verify and recover follow it (D47)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        // Held before the first turn: nothing is on disk, so no blob exists.
        const absent = [_][]const u8{&@as([64]u8, @splat('a'))};
        try testing.expectError(error.InvalidTransition, s.append(&.{.{ .set = .{ .key = .moved_files, .value = "{}", .blobs = &absent } }}));
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        // A malformed hash is refused at the boundary, a missing one by the rule.
        const malformed = [_][]const u8{"../x"};
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .moved_files, .value = "{}", .blobs = &malformed } }}));
        try testing.expectError(error.InvalidTransition, s.append(&.{.{ .set = .{ .key = .moved_files, .value = "{}", .blobs = &absent } }}));
        const hash = try s.putBlob("a body from the side folder");
        const refs = [_][]const u8{&hash};
        const value = try gpa.print("{{\"map\":\"{s}\"}}", .{&hash});
        defer gpa.free(value);
        _ = try s.append(&.{.{ .set = .{ .key = .moved_files, .value = value, .blobs = &refs } }});
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app });
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqualStrings(value, st.moved_files.?);
        r.release();
        try testing.expectEqual(@as(u64, 0), (try m.verify(id)).bad_blobs);
        const fork = try m.openFork(.{ .source = id, .at = .{ .turn = 2 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, fork.id());
        defer gpa.free(fork_id);
        fork.release();
        const body = try m.getBlob(gpa, fork_id, &hash);
        defer gpa.free(body);
        try testing.expectEqualStrings("a body from the side folder", body);

        // A lost blob that only the setting names damages the session there.
        var root = try f.dir();
        defer root.close(io);
        const path = try gpa.print("{s}/blobs/{s}", .{ id, &hash });
        defer gpa.free(path);
        try root.deleteFile(io, path);
        try testing.expectEqual(@as(u64, 1), (try m.verify(id)).bad_blobs);
        const copy = try m.openFork(.{ .source = id, .at = .last_good, .workspace = "/w", .host = .app });
        var copied = try copy.state(gpa);
        defer copied.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), copied.last_turn);
        try testing.expectEqual(@as(?[]u8, null), copied.moved_files);
        copy.release();
    }

    test "compactor records are a setting that lists blobs inside a turn, and the newest wins on resume and in a fork (D50)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{ .turn_started, piece });
        // Mid-turn, as auto compaction runs: the records and their map.
        const record = try s.putBlob("T1 shell: ls\nResult:\nfirst\n");
        const first_map = try s.putBlob("{\"compacted-T1.txt\":\"r\"}");
        const first = try gpa.print("{{\"map\":\"{s}\"}}", .{&first_map});
        defer gpa.free(first);
        _ = try s.append(&.{.{ .set = .{ .key = .compaction_records, .value = first, .blobs = &.{ &record, &first_map } } }});
        _ = try s.append(&.{ piece, .turn_committed });
        // A later compaction rewrites the map; the newest value wins.
        _ = try s.append(&.{.turn_started});
        const second_map = try s.putBlob("{\"compacted-T1.txt\":\"r\",\"compacted-M1.txt\":\"m\"}");
        const second = try gpa.print("{{\"map\":\"{s}\"}}", .{&second_map});
        defer gpa.free(second);
        _ = try s.append(&.{.{ .set = .{ .key = .compaction_records, .value = second, .blobs = &.{&second_map} } }});
        _ = try s.append(&.{ piece, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .app });
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqualStrings(second, st.compaction_records.?);
        r.release();
        try testing.expectEqual(@as(u64, 0), (try m.verify(id)).bad_blobs);

        // A fork at turn 1 keeps the first map and links its records.
        const fork = try m.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, fork.id());
        defer gpa.free(fork_id);
        var forked = try fork.state(gpa);
        defer forked.deinit(gpa);
        try testing.expectEqualStrings(first, forked.compaction_records.?);
        fork.release();
        const body = try m.getBlob(gpa, fork_id, &record);
        defer gpa.free(body);
        try testing.expectEqualStrings("T1 shell: ls\nResult:\nfirst\n", body);
    }

    test "a blob is read-only and its path opens to its bytes, in the session and in a fork (D49)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        _ = try s.append(&.{.turn_started});
        const hash = try s.putBlob("%PDF-1.7 a download");
        const refs = [_][]const u8{&hash};
        _ = try s.append(&.{ .{ .item = .{ .type = "tool", .data = "{}", .blobs = &refs } }, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        const path = try m.blobPath(gpa, id, &hash);
        defer gpa.free(path);
        try testing.expect(std.mem.endsWith(u8, path, &hash));
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        var buffer: [64]u8 = undefined;
        const len = try file.readPositional(io, &.{&buffer}, 0);
        const st = try file.stat(io);
        file.close(io);
        try testing.expectEqualStrings("%PDF-1.7 a download", buffer[0..len]);
        try testing.expectEqual(@as(std.posix.mode_t, storage.blob_mode), st.permissions.toMode() & 0o777);
        try testing.expectError(error.AccessDenied, std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }));

        // A fork's hard link is the same read-only file under the fork's folder.
        const fork = try m.openFork(.{ .source = id, .at = .{ .turn = 1 }, .workspace = "/w", .host = .app });
        const fork_id = try gpa.dupe(u8, fork.id());
        defer gpa.free(fork_id);
        fork.release();
        const fork_path = try m.blobPath(gpa, fork_id, &hash);
        defer gpa.free(fork_path);
        try testing.expect(std.mem.find(u8, fork_path, fork_id) != null);
        const fork_st = try std.Io.Dir.cwd().statFile(io, fork_path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, storage.blob_mode), fork_st.permissions.toMode() & 0o777);

        // Only a well-formed hash this session holds has a path.
        try testing.expectError(error.NotFound, m.blobPath(gpa, id, &@as([64]u8, @splat('b'))));
        try testing.expectError(error.InvalidArgument, m.blobPath(gpa, id, "../x"));
        try testing.expectError(error.NotFound, m.blobPath(gpa, "nosuchsession", &hash));
    }

    test "a file's bytes become the same blob as the bytes themselves, copied in chunks (D44)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .app });
        defer s.release();
        var spool_dir = testing.tmpDir(.{});
        defer spool_dir.cleanup();
        // Larger than one copy chunk, and not a multiple of it.
        const body = try gpa.alloc(u8, 600 * 1024 + 7);
        defer gpa.free(body);
        for (body, 0..) |*byte, i| byte.* = @truncate(i *% 31);
        try spool_dir.dir.writeFile(io, .{ .sub_path = "spool", .data = body });
        var spool = try spool_dir.dir.openFile(io, "spool", .{});
        defer spool.close(io);

        // A held session has no folder for a blob.
        try testing.expectError(error.InvalidTransition, s.putBlobFile(spool, body.len));
        _ = try s.append(&.{.turn_started});
        const from_file = try s.putBlobFile(spool, body.len);
        try testing.expectEqualStrings(&schema.blobHash(body), &from_file);
        try testing.expectEqualStrings(&from_file, &(try s.putBlob(body)));
        const prefix = try s.putBlobFile(spool, 10);
        try testing.expectEqualStrings(&schema.blobHash(body[0..10]), &prefix);
        // A file shorter than claimed stores nothing.
        try testing.expectError(error.Io, s.putBlobFile(spool, body.len + 1));
        try testing.expectError(error.TooLarge, s.putBlobFile(spool, max_blob_bytes + 1));

        const refs = [_][]const u8{ &from_file, &prefix };
        _ = try s.append(&.{ .{ .item = .{ .type = "tool", .data = "{}", .blobs = &refs } }, .turn_committed });
        const stored = try m.getBlob(gpa, s.id(), &from_file);
        defer gpa.free(stored);
        try testing.expectEqualSlices(u8, body, stored);
        var root = try f.dir();
        defer root.close(io);
        const blobs_path = try gpa.print("{s}/blobs", .{s.id()});
        defer gpa.free(blobs_path);
        var blobs = try root.openDir(io, blobs_path, .{ .iterate = true });
        defer blobs.close(io);
        var names = blobs.iterate();
        var count: usize = 0;
        while (try names.next(io)) |entry| {
            try testing.expect(schema.validBlobHash(entry.name));
            const st = try blobs.statFile(io, entry.name, .{});
            try testing.expectEqual(@as(std.posix.mode_t, storage.blob_mode), st.permissions.toMode() & 0o777);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    test "an ACP client's prompt and tool identities are settings that resume keeps (D46)" {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const m = f.manager;
        const s = try m.openNew(.{ .workspace = "/w", .host = .acp });
        // The prompt is a JSON string; anything else is refused.
        try testing.expectError(error.InvalidArgument, s.append(&.{.{ .set = .{ .key = .client_prompt, .value = "{\"text\":1}" } }}));
        _ = try s.append(&.{
            .{ .set = .{ .key = .client_prompt, .value = "\"You run inside Mini.\"" } },
            .{ .set = .{ .key = .tool_identities, .value = "{\"mcp_mini_read\":{\"server\":\"mini\",\"tool\":\"read\"}}" } },
        });
        _ = try s.append(&.{ .turn_started, piece, .turn_committed });
        const id = try gpa.dupe(u8, s.id());
        defer gpa.free(id);
        s.release();

        const r = try m.openResume(.{ .target = .{ .id = id }, .workspace = "/w", .host = .acp });
        defer r.release();
        var st = try r.state(gpa);
        defer st.deinit(gpa);
        try testing.expectEqualStrings("\"You run inside Mini.\"", st.client_prompt.?);
        try testing.expectEqualStrings("{\"mcp_mini_read\":{\"server\":\"mini\",\"tool\":\"read\"}}", st.tool_identities.?);
    }
};

test {
    _ = api_tests;
}
