//! The session index: the single derived owner of "which saved sessions exist
//! and how they summarize". Every listing surface (the resume picker,
//! `fx sessions`, `fx session last`, ACP listing, and latest-session resume)
//! reads it through `listActionableCatalog`, so no listing surface scans
//! session directories on its own.
//!
//! Rows are bound to stat fingerprints of each session's classification
//! inputs. A matching fingerprint reuses the row without opening the session;
//! a mismatch reclassifies that one directory through canonical discovery.
//! The file is disposable: a missing, corrupt, or older-version index is
//! rebuilt from the session directories, which remain the only authority.
const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const child_state = @import("../subagent/child_state.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_discovery = @import("session_discovery.zig");
const session_layout = @import("session_layout.zig");
const session_store = @import("session_store.zig");
const summary_codec = @import("session_summary_codec.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
// v6 stores the disposable row payload in a bounded binary encoding. Every
// older format remains a cache miss and is rebuilt from canonical sessions.
const magic = "fx-resume-catalog-v6\n";
const file_name = ".resume-catalog";
const max_bytes = 64 * 1024 * 1024;
const max_records = 100_000;
const Fingerprint = [Sha256.digest_length]u8;

const Entry = struct {
    fingerprint: ?Fingerprint,
    value: union(enum) { visible: session_store.SessionSummary, excluded: []u8 },
    /// A stale schema-v3 projection whose committed log failed to replay in
    /// this listing: listed from its manifest. The failure may be transient,
    /// so the row is never cached and every listing checks it again.
    unreplayable: bool = false,

    fn id(self: Entry) []const u8 {
        return switch (self.value) {
            .visible => |summary| summary.id,
            .excluded => |name| name,
        };
    }

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.value) {
            .visible => |*summary| summary.deinit(alloc),
            .excluded => |name| alloc.free(name),
        }
        self.* = undefined;
    }
};

const Summary = struct {
    workspace_root: ?[]const u8,
    origin_workspace_root: ?[]const u8,
    title: ?[]const u8,
    preview: ?[]const u8,
    display_metadata_present: bool,
    created_at_ms: i64,
    updated_at_ms: i64,
    history_len: u64,
    language: []const u8,
    has_checkpoint: bool,
    has_managed_children: bool,

    fn from(source: *const session_store.SessionSummary) Summary {
        return .{
            .workspace_root = source.workspace_root,
            .origin_workspace_root = source.origin_workspace_root,
            .title = source.title,
            .preview = source.preview,
            .display_metadata_present = source.display_metadata_present,
            .created_at_ms = source.created_at_ms,
            .updated_at_ms = source.updated_at_ms,
            .history_len = source.history_len,
            .language = source.conversation_language.view(),
            .has_checkpoint = source.has_checkpoint,
            .has_managed_children = source.has_managed_children,
        };
    }

    /// The row contract `load` enforces. Discovery can report a summary
    /// outside it, such as a legacy session whose clock stepped back, and one
    /// such row would make `load` reject the whole file, so the catalog lists
    /// that session without caching it.
    fn persistable(self: Summary) bool {
        if (self.created_at_ms < 0 or self.updated_at_ms < self.created_at_ms) return false;
        if (!std.unicode.utf8ValidateSlice(self.language)) return false;
        _ = session.ConversationLanguage.fromSlice(self.language) catch return false;
        if (std.math.cast(usize, self.history_len) == null) return false;
        for ([_]?[]const u8{ self.workspace_root, self.origin_workspace_root, self.title, self.preview }) |optional| {
            if (optional) |value| if (!std.unicode.utf8ValidateSlice(value)) return false;
        }
        if (self.title) |title| {
            if (title.len > session_codec.max_session_title_bytes) return false;
        }
        for ([_]?[]const u8{ self.workspace_root, self.origin_workspace_root }) |root| {
            const path = root orelse continue;
            if (!std.Io.Dir.path.isAbsolute(path) or path.len > std.Io.Dir.max_path_bytes) return false;
        }
        return true;
    }

    fn clone(self: Summary, alloc: Allocator, id: []const u8) !session_store.SessionSummary {
        return summary_codec.cloneSessionSummary(alloc, .{
            .id = @constCast(id),
            .workspace_root = if (self.workspace_root) |value| @constCast(value) else null,
            .origin_workspace_root = if (self.origin_workspace_root) |value| @constCast(value) else null,
            .title = if (self.title) |value| @constCast(value) else null,
            .preview = if (self.preview) |value| @constCast(value) else null,
            .display_metadata_present = self.display_metadata_present,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .history_len = std.math.cast(usize, self.history_len) orelse return error.InvalidCatalogCache,
            .conversation_language = try session.ConversationLanguage.fromSlice(self.language),
            .has_checkpoint = self.has_checkpoint,
            .has_managed_children = self.has_managed_children,
        });
    }
};

const Row = struct {
    id: []const u8,
    fingerprint: Fingerprint,
    value: union(enum) {
        visible: Summary,
        excluded: void,
    },
};

/// Owns parsed cache bytes. Reused entries are separately owned by the caller.
pub const Loaded = struct {
    bytes: ?[]u8 = null,
    parsed: ?[]Row = null,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        self.index.deinit(alloc);
        if (self.parsed) |rows| alloc.free(rows);
        if (self.bytes) |bytes| alloc.free(bytes);
        self.* = .{};
    }

    fn count(self: *const Loaded) usize {
        return self.index.count();
    }
    fn present(self: *const Loaded) bool {
        return self.parsed != null;
    }
    pub fn contains(self: *const Loaded, id: []const u8) bool {
        return self.index.contains(id);
    }

    pub fn load(alloc: Allocator, dir: ?io_mod.VerifiedDir, cancelled: ?*const std.atomic.Value(bool)) !Loaded {
        const root = dir orelse return .{};
        return loadChecked(alloc, root.dir, cancelled) catch |err| switch (err) {
            error.OutOfMemory, error.Cancelled => return err,
            error.FileNotFound => .{},
            else => blk: {
                debug_trace.logf("core", "session catalog cache ignored err={s}", .{@errorName(err)});
                break :blk .{};
            },
        };
    }

    fn loadChecked(alloc: Allocator, dir: std.Io.Dir, cancelled: ?*const std.atomic.Value(bool)) !Loaded {
        // Opening a FIFO or device for reading can block, so the helper checks
        // the entry and opens it without blocking before any read.
        var file = try io_mod.openExistingRegularFile(dir, file_name, .read_only);
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink > 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidCatalogCache;
        const bytes = try alloc.alloc(u8, @intCast(stat.size));
        errdefer alloc.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
            const end = @min(bytes.len, offset + 64 * 1024);
            const read = try file.readPositionalAll(io_mod.getIo(), bytes[offset..end], offset);
            if (read != end - offset) return error.InvalidCatalogCache;
            offset = end;
        }
        if (bytes.len < magic.len + Sha256.digest_length + @sizeOf(u32) or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidCatalogCache;
        const payload = bytes[magic.len + Sha256.digest_length ..];
        var digest: Fingerprint = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidCatalogCache;
        const rows = try decodeRows(alloc, payload, cancelled);
        errdefer alloc.free(rows);
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer index.deinit(alloc);
        try index.ensureTotalCapacity(alloc, @intCast(rows.len));
        for (rows, 0..) |row, i| {
            if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
            const entry = index.getOrPutAssumeCapacity(row.id);
            if (entry.found_existing) return error.InvalidCatalogCache;
            entry.value_ptr.* = i;
        }
        return .{ .bytes = bytes, .parsed = rows, .index = index };
    }

    fn reuse(self: *const Loaded, alloc: Allocator, id: []const u8, fingerprint_value: Fingerprint) !?Entry {
        const position = self.index.get(id) orelse return null;
        const row = self.parsed.?[position];
        if (!matches(row, fingerprint_value)) return null;
        return try cloneRow(alloc, row, fingerprint_value);
    }

    /// Clones every visible row into picker summaries, excluding `active_id`.
    /// Rows are NOT revalidated against current on-disk state; the result is
    /// stale evidence for instant paint only, and canonical admission still
    /// re-checks any selection. Caller owns the list and each summary.
    pub fn cloneVisibleSummaries(self: *const Loaded, alloc: Allocator, active_id: ?[]const u8) !std.ArrayList(session_store.SessionSummary) {
        var summaries: std.ArrayList(session_store.SessionSummary) = .empty;
        errdefer {
            for (summaries.items) |*summary| summary.deinit(alloc);
            summaries.deinit(alloc);
        }
        const rows = self.parsed orelse return summaries;
        for (rows) |row| {
            const summary = switch (row.value) {
                .visible => |*value| value,
                .excluded => continue,
            };
            if (active_id) |active| if (std.mem.eql(u8, active, row.id)) continue;
            var cloned = try summary.clone(alloc, row.id);
            errdefer cloned.deinit(alloc);
            try summaries.append(alloc, cloned);
        }
        return summaries;
    }

    fn matches(row: Row, value: Fingerprint) bool {
        return std.mem.eql(u8, &row.fingerprint, &value);
    }

    fn cloneRow(alloc: Allocator, row: Row, value: Fingerprint) !Entry {
        return .{ .fingerprint = value, .value = switch (row.value) {
            .visible => |summary| .{ .visible = try summary.clone(alloc, row.id) },
            .excluded => .{ .excluded = try alloc.dupe(u8, row.id) },
        } };
    }
};

/// A narrow cache-writing handle obtained only from a writable app store.
pub const Writer = struct {
    dir: io_mod.VerifiedDir,

    pub fn init(store: session_store.Store) !?Writer {
        if (store.canonical_root.mode != .writable) return null;
        const root = store.canonical_root.sessions orelse return null;
        return .{ .dir = .{ .dir = try root.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) } };
    }
    pub fn deinit(self: *Writer) void {
        self.dir.close();
    }

    /// Publishes every fingerprinted entry, then keeps any earlier row this
    /// scan did not observe only while its session still matches that row.
    fn save(self: *Writer, alloc: Allocator, entries: []const Entry, cancelled: *const std.atomic.Value(bool)) !void {
        if (cancelled.load(.acquire)) return error.Cancelled;
        if (entries.len > max_records) return error.CatalogCacheTooLarge;
        var previous = try Loaded.load(alloc, self.dir, cancelled);
        defer previous.deinit(alloc);
        var replaced: std.StringHashMapUnmanaged(void) = .empty;
        defer replaced.deinit(alloc);
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        writeInt(&payload.writer, u32, 0) catch return error.OutOfMemory;
        var written: usize = 0;
        for (entries) |*entry| {
            if (cancelled.load(.acquire)) return error.Cancelled;
            const value = entry.fingerprint orelse continue;
            try replaced.put(alloc, entry.id(), {});
            try writeRow(&payload, &written, .{ .id = entry.id(), .fingerprint = value, .value = switch (entry.value) {
                .visible => |*summary| .{ .visible = Summary.from(summary) },
                .excluded => .excluded,
            } });
        }
        if (previous.parsed) |rows| for (rows) |row| {
            if (cancelled.load(.acquire)) return error.Cancelled;
            if (replaced.contains(row.id)) continue;
            const current = fingerprint(self.dir.dir, row.id) catch null;
            if (current) |stamp| if (Loaded.matches(row, stamp)) try writeRow(&payload, &written, row);
        };
        std.mem.writeInt(u32, payload.written()[0..@sizeOf(u32)], @intCast(written), .little);
        if (cancelled.load(.acquire)) return error.Cancelled;
        var digest: Fingerprint = undefined;
        Sha256.hash(payload.written(), &digest, .{});
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        out.writer.writeAll(magic) catch return error.OutOfMemory;
        out.writer.writeAll(&digest) catch return error.OutOfMemory;
        out.writer.writeAll(payload.written()) catch return error.OutOfMemory;
        try io_mod.durableReplaceVerified(alloc, &self.dir, file_name, out.written());
    }
};

fn writeRow(payload: *std.Io.Writer.Allocating, written: *usize, row: Row) !void {
    if (written.* == max_records) return error.CatalogCacheTooLarge;
    writeString(&payload.writer, row.id) catch return error.OutOfMemory;
    payload.writer.writeAll(&row.fingerprint) catch return error.OutOfMemory;
    switch (row.value) {
        .excluded => payload.writer.writeByte(0) catch return error.OutOfMemory,
        .visible => |summary| {
            payload.writer.writeByte(1) catch return error.OutOfMemory;
            var flags: u8 = 0;
            if (summary.display_metadata_present) flags |= 1 << 0;
            if (summary.has_checkpoint) flags |= 1 << 1;
            if (summary.has_managed_children) flags |= 1 << 2;
            payload.writer.writeByte(flags) catch return error.OutOfMemory;
            writeInt(&payload.writer, i64, summary.created_at_ms) catch return error.OutOfMemory;
            writeInt(&payload.writer, i64, summary.updated_at_ms) catch return error.OutOfMemory;
            writeInt(&payload.writer, u64, summary.history_len) catch return error.OutOfMemory;
            writeOptionalString(&payload.writer, summary.workspace_root) catch return error.OutOfMemory;
            writeOptionalString(&payload.writer, summary.origin_workspace_root) catch return error.OutOfMemory;
            writeOptionalString(&payload.writer, summary.title) catch return error.OutOfMemory;
            writeOptionalString(&payload.writer, summary.preview) catch return error.OutOfMemory;
            writeString(&payload.writer, summary.language) catch return error.OutOfMemory;
        },
    }
    written.* += 1;
    if (payload.written().len > max_bytes - magic.len - Sha256.digest_length) return error.CatalogCacheTooLarge;
}

fn decodeRows(
    alloc: Allocator,
    payload: []const u8,
    cancelled: ?*const std.atomic.Value(bool),
) ![]Row {
    var cursor = ByteCursor{ .bytes = payload };
    const count = try cursor.readInt(u32);
    if (count > max_records) return error.InvalidCatalogCache;
    const rows = try alloc.alloc(Row, count);
    errdefer alloc.free(rows);
    for (rows) |*row| {
        if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
        const id = try cursor.readString();
        session_layout.validateSessionId(id) catch return error.InvalidCatalogCache;
        const raw_fingerprint = try cursor.take(@sizeOf(Fingerprint));
        const fingerprint_value: Fingerprint = raw_fingerprint[0..@sizeOf(Fingerprint)].*;
        const value: @FieldType(Row, "value") = switch (try cursor.readByte()) {
            0 => .excluded,
            1 => visible: {
                const flags = try cursor.readByte();
                if (flags & ~@as(u8, 0b111) != 0) return error.InvalidCatalogCache;
                const summary = Summary{
                    .display_metadata_present = flags & (1 << 0) != 0,
                    .has_checkpoint = flags & (1 << 1) != 0,
                    .has_managed_children = flags & (1 << 2) != 0,
                    .created_at_ms = try cursor.readInt(i64),
                    .updated_at_ms = try cursor.readInt(i64),
                    .history_len = try cursor.readInt(u64),
                    .workspace_root = try cursor.readOptionalString(),
                    .origin_workspace_root = try cursor.readOptionalString(),
                    .title = try cursor.readOptionalString(),
                    .preview = try cursor.readOptionalString(),
                    .language = try cursor.readString(),
                };
                if (!summary.persistable()) return error.InvalidCatalogCache;
                break :visible .{ .visible = summary };
            },
            else => return error.InvalidCatalogCache,
        };
        row.* = .{ .id = id, .fingerprint = fingerprint_value, .value = value };
    }
    if (!cursor.done()) return error.InvalidCatalogCache;
    return rows;
}

const ByteCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *ByteCursor, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.offset, len) catch
            return error.InvalidCatalogCache;
        if (end > self.bytes.len) return error.InvalidCatalogCache;
        const result = self.bytes[self.offset..end];
        self.offset = end;
        return result;
    }

    fn readByte(self: *ByteCursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readInt(self: *ByteCursor, comptime T: type) !T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn readString(self: *ByteCursor) ![]const u8 {
        return self.take(try self.readInt(u32));
    }

    fn readOptionalString(self: *ByteCursor) !?[]const u8 {
        const len = try self.readInt(u32);
        if (len == std.math.maxInt(u32)) return null;
        return @as(?[]const u8, try self.take(len));
    }

    fn done(self: ByteCursor) bool {
        return self.offset == self.bytes.len;
    }
};

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    const len = std.math.cast(u32, value.len) orelse return error.CatalogCacheTooLarge;
    try writeInt(writer, u32, len);
    try writer.writeAll(value);
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |bytes| {
        try writeString(writer, bytes);
    } else {
        try writeInt(writer, u32, std.math.maxInt(u32));
    }
}

/// Reports whether a persisted catalog exists, without parsing it. Callers use
/// this to decide whether warming the catalog is worth any work at all.
pub fn catalogFileExists(sessions: ?io_mod.VerifiedDir) bool {
    const root = sessions orelse return false;
    const stat = root.dir.statFile(io_mod.getIo(), file_name, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}

/// Stats are freshness evidence only. Cache misses still use canonical discovery and admission.
fn fingerprint(dir: std.Io.Dir, id: []const u8) !?Fingerprint {
    try session_layout.validateSessionId(id);
    const before = (try statOptional(dir, id)) orelse return null;
    if (before.kind != .directory) return null;
    var digest = Sha256.init(.{});
    addStat(&digest, before);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Classification observes each of these files, and its result depends on
    // whether each is present: a legacy session carries no event log, and a
    // schema_v3 session whose manifest is lost is listed from its log. Their
    // presence, absence, or replacement must invalidate a cached row, so bind
    // them into the digest.
    for ([_][]const u8{ "session.json", "events.jsonl", "authority.json", "authority.pending.json", "display.json" }) |name| {
        const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ id, name });
        if (try statOptional(dir, path)) |stat| {
            if (stat.kind != .file or stat.nlink != 1) return null;
            digest.update(&.{1});
            addStat(&digest, stat);
        } else digest.update(&.{0});
    }
    const child_path = try std.mem.print(&path_buffer, "{s}/subagent", .{id});
    const child = try statOptional(dir, child_path);
    if (child) |stat| {
        if (stat.kind != .directory) return null;
        digest.update(&.{1});
        addStat(&digest, stat);
        for ([_][]const u8{ "owner.json", "control.json" }) |name| {
            const path = try std.mem.print(&path_buffer, "{s}/subagent/{s}", .{ id, name });
            if (try statOptional(dir, path)) |marker| {
                if (marker.kind != .file or marker.nlink != 1) return null;
                digest.update(&.{1});
                addStat(&digest, marker);
            } else digest.update(&.{0});
        }
    } else digest.update(&.{0});
    const after = (try statOptional(dir, id)) orelse return null;
    if (!sameStat(before, after)) return null;
    var value: Fingerprint = undefined;
    digest.final(&value);
    return value;
}

fn statOptional(dir: std.Io.Dir, path: []const u8) !?std.Io.File.Stat {
    return dir.statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => err,
    };
}

fn sameStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.nlink == b.nlink and a.kind == b.kind and a.size == b.size and
        a.permissions.toMode() == b.permissions.toMode() and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn addStat(hash: *Sha256, stat: std.Io.File.Stat) void {
    const values = [_]u128{ stat.inode, stat.nlink, stat.size, @backingInt(stat.kind), stat.permissions.toMode(), @bitCast(@as(i128, stat.mtime.nanoseconds)), @bitCast(@as(i128, stat.ctime.nanoseconds)) };
    var bytes: [16]u8 = undefined;
    for (values) |value| {
        std.mem.writeInt(u128, &bytes, value, .little);
        hash.update(&bytes);
    }
}

/// Every listable session in newest-first order, plus the number of session
/// directories that could not be classified during this refresh.
pub const ActionableSessionCatalog = struct {
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    skipped_invalid: usize = 0,
    /// Owned ids of listed sessions whose stale schema-v3 log failed to replay
    /// in this listing. Such rows are never cached, so every listing observes
    /// them afresh.
    unreplayable_ids: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ActionableSessionCatalog, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        for (self.unreplayable_ids.items) |id| alloc.free(id);
        self.unreplayable_ids.deinit(alloc);
        self.* = undefined;
    }

    pub fn isUnreplayable(self: *const ActionableSessionCatalog, id: []const u8) bool {
        for (self.unreplayable_ids.items) |value| {
            if (std.mem.eql(u8, value, id)) return true;
        }
        return false;
    }
};

const CatalogRead = struct {
    store: session_store.Store,
    candidates: session_store.CandidateIterator,
    iterator_mutex: std.Io.Mutex = .init,
    active_id: ?[]const u8,
    cancelled: *std.atomic.Value(bool),
    cache: *const Loaded,
    changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reused: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    skipped_invalid: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn nextId(self: *CatalogRead, alloc: Allocator) !?[]u8 {
        self.iterator_mutex.lockUncancelable(io_mod.getIo());
        defer self.iterator_mutex.unlock(io_mod.getIo());
        return self.candidates.nextId(alloc, self.cancelled);
    }
};

const CatalogWorker = struct {
    read: *CatalogRead,
    alloc: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    failure: ?anyerror = null,

    fn run(self: *CatalogWorker) void {
        self.readAll() catch |err| {
            self.failure = err;
            self.read.cancelled.store(true, .release);
        };
    }

    fn readAll(self: *CatalogWorker) !void {
        const dir = self.read.store.canonical_root.sessions orelse return;
        while (try self.read.nextId(self.alloc)) |id| {
            defer self.alloc.free(id);
            const before = fingerprint(dir.dir, id) catch null;
            if (before) |stamp| {
                if (try self.read.cache.reuse(self.alloc, id, stamp)) |value| {
                    var entry = value;
                    errdefer entry.deinit(self.alloc);
                    try self.entries.append(self.alloc, entry);
                    _ = self.read.reused.fetchAdd(1, .monotonic);
                    continue;
                }
            }
            var fenced = false;
            var candidate = self.read.store.readOnlyCandidate(self.alloc, id, self.read.cancelled) catch |err| switch (err) {
                error.OutOfMemory, error.Cancelled => return err,
                else => fallback: {
                    // A legacy upgrade interrupted mid-rename stays listed from
                    // its stable snapshot, so resuming it can run recovery.
                    if (self.read.store.readOnlyFencedLegacyCandidate(self.alloc, id, self.read.cancelled)) |value| {
                        fenced = true;
                        break :fallback value;
                    } else |fallback_err| switch (fallback_err) {
                        error.OutOfMemory, error.Cancelled => return fallback_err,
                        else => {},
                    }
                    session_discovery.logDiscoveryError(.read_only_list, id, null, null, err);
                    _ = self.read.skipped_invalid.fetchAdd(1, .monotonic);
                    continue;
                },
            };
            var owned = true;
            defer if (owned) candidate.deinit(self.alloc);
            const is_active = if (self.read.active_id) |active| std.mem.eql(u8, id, active) else false;
            if (is_active and !candidate.summary.hasResumableContent()) continue;
            if (self.read.cancelled.load(.acquire)) return error.Cancelled;
            // The fingerprint binds every classification input, so each settled
            // row is cacheable, a replayed schema_v3 projection included: the
            // commit watermark and checkpoint the replay also reads are
            // replaced by rename, which changes the session directory stat the
            // fingerprint binds. A row read around an interrupted upgrade
            // describes a transition, and a failed replay can be transient,
            // so neither is ever reused. Empty sessions stay listed; the
            // picker alone hides rows without resumable content.
            var cacheable = !fenced and candidate.projection_state != .stale;
            const managed = child_state.isDiscoveredManagedChildSession(self.read.store, self.alloc, candidate.summary.id, candidate.subagent_child) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // An unverifiable marker or first event stays listed, as
                // `fx sessions` always did; exact resume still refuses a real
                // child. The row is not cached, so the check runs again.
                else => blk: {
                    cacheable = false;
                    break :blk false;
                },
            };
            if (!managed and !Summary.from(&candidate.summary).persistable()) {
                debug_trace.logf("core", "session catalog cache left id={s} uncached: summary outside the row contract", .{id});
                cacheable = false;
            }
            const after = if (cacheable) fingerprint(dir.dir, id) catch null else null;
            const stable = if (before) |a| if (after) |z| std.mem.eql(u8, &a, &z) else false else false;
            var entry = Entry{
                .fingerprint = if (stable) after else null,
                .value = if (managed) .{ .excluded = try self.alloc.dupe(u8, id) } else .{ .visible = candidate.summary },
                .unreplayable = !fenced and candidate.storage == .schema_v3 and candidate.projection_state == .stale,
            };
            if (!managed) owned = false;
            errdefer entry.deinit(self.alloc);
            try self.entries.append(self.alloc, entry);
            if (stable or self.read.cache.contains(id)) self.read.changed.store(true, .release);
        }
    }
};

/// Refreshes the session index and returns every listable session, newest
/// first. `active_id` is omitted from the result. Rows whose fingerprints still
/// match are reused without opening their sessions; the rest are reclassified
/// by canonical discovery. When `cache_writer` is set, a changed index is
/// persisted for the next caller. Caller owns the returned catalog.
pub fn listActionableCatalog(
    store: session_store.Store,
    alloc: Allocator,
    active_id: ?[]const u8,
    cancelled: ?*std.atomic.Value(bool),
    cache_writer: ?*Writer,
) !ActionableSessionCatalog {
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    var local_stop = std.atomic.Value(bool).init(false);
    const stop_requested = cancelled orelse &local_stop;
    var cached = try Loaded.load(std.heap.c_allocator, store.canonical_root.sessions, stop_requested);
    defer cached.deinit(std.heap.c_allocator);
    var read = CatalogRead{ .store = store, .candidates = store.readOnlyCandidates(), .active_id = active_id, .cancelled = stop_requested, .cache = &cached };
    read.changed.store(!cached.present(), .monotonic);
    // Worker storage is independent of the caller's allocator and ends after the merge.
    const worker_alloc = std.heap.c_allocator;
    var workers: [4]CatalogWorker = undefined;
    for (&workers) |*worker| worker.* = .{ .read = &read, .alloc = worker_alloc };
    defer for (&workers) |*worker| {
        for (worker.entries.items) |*entry| entry.deinit(worker_alloc);
        worker.entries.deinit(worker_alloc);
    };
    var threads: [workers.len - 1]?std.Thread = @splat(null);
    errdefer {
        stop_requested.store(true, .release);
        for (&threads) |*handle| {
            if (handle.*) |thread| thread.join();
            handle.* = null;
        }
    }
    for (&threads, workers[1..]) |*handle, *worker| {
        handle.* = try std.Thread.spawn(.{}, CatalogWorker.run, .{worker});
    }
    workers[0].run();
    for (&threads) |*handle| {
        handle.*.?.join();
        handle.* = null;
    }
    for (workers) |worker| {
        if (worker.failure) |err| {
            if (err != error.Cancelled) return err;
        }
    }
    if (stop_requested.load(.acquire)) return error.Cancelled;
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(worker_alloc);
        entries.deinit(worker_alloc);
    }
    for (&workers) |*worker| {
        try entries.appendSlice(worker_alloc, worker.entries.items);
        worker.entries.items.len = 0;
    }
    var catalog: ActionableSessionCatalog = .{ .skipped_invalid = read.skipped_invalid.load(.monotonic) };
    errdefer catalog.deinit(alloc);
    var cacheable: usize = 0;
    for (entries.items) |entry| {
        if (stop_requested.load(.acquire)) return error.Cancelled;
        if (entry.fingerprint != null) cacheable += 1;
        switch (entry.value) {
            .visible => |summary| {
                if (active_id) |active| if (std.mem.eql(u8, active, summary.id)) continue;
                if (entry.unreplayable) {
                    const unreplayable_id = try alloc.dupe(u8, summary.id);
                    errdefer alloc.free(unreplayable_id);
                    try catalog.unreplayable_ids.append(alloc, unreplayable_id);
                }
                var copy = try summary_codec.cloneSessionSummary(alloc, summary);
                errdefer copy.deinit(alloc);
                try catalog.summaries.append(alloc, copy);
            },
            .excluded => {},
        }
    }
    if (cache_writer) |writer| {
        if (read.changed.load(.acquire) or cacheable != cached.count()) {
            writer.save(alloc, entries.items, stop_requested) catch |err| {
                if (stop_requested.load(.acquire)) return error.Cancelled;
                debug_trace.logf("core", "session catalog cache not saved err={s}", .{@errorName(err)});
            };
        }
    }
    debug_trace.logf("core", "session catalog cache reused={d} records={d} skipped_invalid={d}", .{ read.reused.load(.monotonic), cacheable, catalog.skipped_invalid });
    summary_codec.sortSummariesNewestFirst(catalog.summaries.items);
    return catalog;
}

test "actionable catalog preserves discovery and child visibility" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("saved request") },
        .assistant = @constCast("saved response"),
    } }};
    for ([_][]const u8{ "public", "private-bit", "private-marker", "empty" }, 0..) |id, index| {
        const durable = session_codec.DurableSessionState{
            .id = @constCast(id),
            .origin_workspace_root = workspace,
            .workspace_root = workspace,
            .created_at_ms = 1,
            .updated_at_ms = @intCast(index + 1),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history = if (std.mem.eql(u8, id, "empty")) &.{} else @constCast(&history),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
            .subagent_child = std.mem.eql(u8, id, "private-bit"),
        };
        var writable = try store.startWritableSession(alloc, durable);
        writable.deinit(alloc);
    }
    const children = child_state.Store{ .backend = .{ .v1 = &store }, .parent_id = "public" };
    try children.markChildSession(alloc, "private-marker");
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, null);
    defer catalog.deinit(alloc);
    // Children stay private; an empty session is listed, and only the picker
    // hides rows without resumable content.
    try std.testing.expectEqual(@as(usize, 2), catalog.summaries.items.len);
    for (catalog.summaries.items) |summary| {
        try std.testing.expect(std.mem.eql(u8, summary.id, "public") or std.mem.eql(u8, summary.id, "empty"));
    }
    var reference = try store.list(alloc);
    defer summary_codec.freeSummaries(alloc, &reference);
    var visible: usize = 0;
    for (reference.items) |summary| {
        if (std.mem.eql(u8, summary.id, "private-bit") or std.mem.eql(u8, summary.id, "private-marker")) continue;
        try std.testing.expectEqualStrings(summary.id, catalog.summaries.items[visible].id);
        try std.testing.expectEqual(summary.history_len, catalog.summaries.items[visible].history_len);
        try std.testing.expectEqual(summary.updated_at_ms, catalog.summaries.items[visible].updated_at_ms);
        visible += 1;
    }
    try std.testing.expectEqual(catalog.summaries.items.len, visible);
    stopped.store(true, .release);
    try std.testing.expectError(error.Cancelled, listActionableCatalog(store, alloc, null, &stopped, null));
    const AllocationCheck = struct {
        fn run(failing_alloc: Allocator, source: session_store.Store) !void {
            var result = try listActionableCatalog(source, failing_alloc, null, null, null);
            defer result.deinit(failing_alloc);
            try std.testing.expectEqual(@as(usize, 2), result.summaries.items.len);
        }

        fn candidate(failing_alloc: Allocator, source: session_store.Store) !void {
            var result = try source.readOnlyCandidate(failing_alloc, "public", null);
            defer result.deinit(failing_alloc);
            try std.testing.expectEqualStrings("public", result.summary.id);
            try std.testing.expectEqual(@as(?bool, false), result.subagent_child);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, AllocationCheck.run, .{store});
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, AllocationCheck.candidate, .{store});

    stopped.store(false, .release);
    var empty_cache: Loaded = .{};
    var failed_read = CatalogRead{ .store = store, .candidates = store.readOnlyCandidates(), .active_id = null, .cancelled = &stopped, .cache = &empty_cache };
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var failed_worker = CatalogWorker{ .read = &failed_read, .alloc = failing.allocator() };
    defer failed_worker.entries.deinit(failing.allocator());
    failed_worker.run();
    try std.testing.expectEqual(error.OutOfMemory, failed_worker.failure.?);
    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expectError(error.Cancelled, store.readOnlyCandidate(alloc, "public", &stopped));

    stopped.store(false, .release);
    var writer = (try Writer.init(store)).?;
    defer writer.deinit();
    var built = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer built.deinit(alloc);
    var reused = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer reused.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), reused.summaries.items.len);
    try std.testing.expectEqualStrings(built.summaries.items[0].id, reused.summaries.items[0].id);
    {
        var changed = try store.resumeForWrite(alloc, "public");
        defer changed.deinit(alloc);
        _ = try changed.renameConversation(alloc, "Changed title");
    }
    var renamed = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer renamed.deinit(alloc);
    try std.testing.expectEqualStrings("Changed title", renamed.summaries.items[0].title.?);
    try io_mod.durableReplaceVerified(alloc, &writer.dir, ".resume-catalog", "truncated cache");
    var repaired = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), repaired.summaries.items.len);
    try std.testing.expectEqualStrings("Changed title", repaired.summaries.items[0].title.?);
    const new_owner = child_state.Store{ .backend = .{ .v1 = &store }, .parent_id = "parent" };
    try new_owner.markChildSession(alloc, "public");
    var hidden = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer hidden.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), hidden.summaries.items.len);
    try std.testing.expectEqualStrings("empty", hidden.summaries.items[0].id);
    var removed = try store.resumeForWrite(alloc, "empty");
    try std.testing.expectEqual(.discarded, store.deleteCommittedSession(alloc, &removed));
    var reconciled = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer reconciled.deinit(alloc);
    var saved = try Loaded.load(alloc, writer.dir, null);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.present());
    try std.testing.expect(!saved.contains("empty"));
    try std.testing.expectEqual(@as(usize, 0), reconciled.summaries.items.len);
    var read_only = try session_store.Store.initReadOnlyFromHome(alloc, home, workspace);
    defer read_only.deinit(alloc);
    try std.testing.expect((try Writer.init(read_only)) == null);
}

test "actionable catalog lists and caches legacy sessions without event logs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx/sessions/legacy-old");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    // Oldest persisted format: a schema v2 snapshot with no event log.
    const manifest = try alloc.print("{{\"schema_version\":2,\"id\":\"legacy-old\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"{s}\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[{{\"role\":\"user\",\"content\":\"saved\"}}],\"total_input_tokens\":0,\"total_output_tokens\":0}}\n", .{workspace});
    defer alloc.free(manifest);
    var file = try tmp.dir.createFile(std.testing.io, "home/.fx/sessions/legacy-old/session.json", .{});
    try file.writeStreamingAll(std.testing.io, manifest);
    file.close(std.testing.io);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var writer = (try Writer.init(store)).?;
    defer writer.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer catalog.deinit(alloc);
    // Legacy sessions stay resumable, so every listing shows them, and the row
    // lands in the cache so later scans reuse it instead of reparsing.
    try std.testing.expectEqual(@as(usize, 1), catalog.summaries.items.len);
    try std.testing.expectEqualStrings("legacy-old", catalog.summaries.items[0].id);
    var saved = try Loaded.load(alloc, writer.dir, null);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.present());
    try std.testing.expect(saved.contains("legacy-old"));
    var again = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer again.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), again.summaries.items.len);
}

test "a summary outside the row contract stays listed without disabling the index" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    // A legacy snapshot whose clock stepped back records an update before its
    // creation, which the index row contract rejects.
    const Snapshot = struct { id: []const u8, created_at_ms: i64, updated_at_ms: i64 };
    for ([_]Snapshot{
        .{ .id = "legacy-ok", .created_at_ms = 1, .updated_at_ms = 2 },
        .{ .id = "clock-skewed", .created_at_ms = 2000, .updated_at_ms = 1000 },
    }) |snapshot| {
        const dir_path = try alloc.print("home/.fx/sessions/{s}", .{snapshot.id});
        defer alloc.free(dir_path);
        try tmp.dir.createDirPath(std.testing.io, dir_path);
        const path = try alloc.print("{s}/session.json", .{dir_path});
        defer alloc.free(path);
        const manifest = try alloc.print("{{\"schema_version\":2,\"id\":\"{s}\",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"workspace_root\":\"{s}\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[{{\"role\":\"user\",\"content\":\"saved\"}}],\"total_input_tokens\":0,\"total_output_tokens\":0}}\n", .{ snapshot.id, snapshot.created_at_ms, snapshot.updated_at_ms, workspace });
        defer alloc.free(manifest);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = manifest });
    }
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var writer = (try Writer.init(store)).?;
    defer writer.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer catalog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), catalog.summaries.items.len);
    {
        var saved = try Loaded.load(alloc, writer.dir, null);
        defer saved.deinit(alloc);
        try std.testing.expect(saved.present());
        try std.testing.expect(saved.contains("legacy-ok"));
        try std.testing.expect(!saved.contains("clock-skewed"));
    }
    // The next listing reuses the saved row and leaves the index untouched.
    const index_path = "home/.fx/sessions/.resume-catalog";
    const before = try tmp.dir.statFile(std.testing.io, index_path, .{});
    var again = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer again.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), again.summaries.items.len);
    const after = try tmp.dir.statFile(std.testing.io, index_path, .{});
    try std.testing.expectEqual(before.inode, after.inode);
}

test "actionable catalog lists an interrupted legacy upgrade without caching it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx/sessions/fenced");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const snapshot = try alloc.print("{{\"schema_version\":2,\"id\":\"fenced\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"{s}\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[{{\"role\":\"user\",\"content\":\"saved\"}}],\"total_input_tokens\":0,\"total_output_tokens\":0}}\n", .{workspace});
    defer alloc.free(snapshot);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.fx/sessions/fenced/session.legacy.json", .data = snapshot });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.fx/sessions/fenced/authority.pending.json", .data = "pending" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.fx/sessions/fenced/session.json", .data = "interrupted replacement" });

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var writer = (try Writer.init(store)).?;
    defer writer.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer catalog.deinit(alloc);
    // The stable snapshot keeps the session listed so resuming it can finish
    // the upgrade, but the row describes a transition and is never reused.
    try std.testing.expectEqual(@as(usize, 1), catalog.summaries.items.len);
    try std.testing.expectEqualStrings("fenced", catalog.summaries.items[0].id);
    var saved = try Loaded.load(alloc, writer.dir, null);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.present());
    try std.testing.expect(!saved.contains("fenced"));
}

test "actionable catalog lists an unverifiable child marker without caching it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var writable = try store.startWritableSession(alloc, .{
        .id = @constCast("unverified"),
        .origin_workspace_root = workspace,
        .workspace_root = workspace,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
    });
    writable.deinit(alloc);
    try tmp.dir.createDir(std.testing.io, "home/.fx/sessions/unverified/subagent", .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.fx/sessions/unverified/subagent/control.json", .data = "not a control record", .flags = .{ .permissions = .fromMode(0o600) } });

    var writer = (try Writer.init(store)).?;
    defer writer.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    var catalog = try listActionableCatalog(store, alloc, null, &stopped, &writer);
    defer catalog.deinit(alloc);
    // A damaged marker cannot prove the session is a child, so it stays
    // listed; the row is not cached so the next listing checks it again.
    try std.testing.expectEqual(@as(usize, 1), catalog.summaries.items.len);
    try std.testing.expectEqualStrings("unverified", catalog.summaries.items[0].id);
    var saved = try Loaded.load(alloc, writer.dir, null);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.present());
    try std.testing.expect(!saved.contains("unverified"));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "catalog cache ignores a FIFO without blocking" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ root, file_name }, 0);
    if (mkfifo(path, 0o600) != 0) return error.SkipZigTest;
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    // Reading a FIFO waits for a writer that never comes; the index is ignored.
    var loaded = try Loaded.load(alloc, dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expect(!loaded.present());
}

test "catalog cache round trips owned rows and ignores incomplete observations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) } };
    defer writer.deinit();
    var entries = [_]Entry{
        .{ .fingerprint = @splat(1), .value = .{ .visible = try summary_codec.cloneSessionSummary(alloc, .{
            .id = @constCast("visible"),
            .workspace_root = @constCast("/workspace"),
            .origin_workspace_root = @constCast("/origin"),
            .title = @constCast("Saved title"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .history_len = 3,
            .conversation_language = .literal("en"),
        }) } },
        .{ .fingerprint = @splat(2), .value = .{ .excluded = try alloc.dupe(u8, "private") } },
        .{ .fingerprint = null, .value = .{ .excluded = try alloc.dupe(u8, "temporary-failure") } },
    };
    defer for (&entries) |*entry| entry.deinit(alloc);
    var stopped = std.atomic.Value(bool).init(false);
    try writer.save(alloc, &entries, &stopped);
    var loaded = try Loaded.load(alloc, writer.dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.present());
    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    try std.testing.expect(!loaded.contains("temporary-failure"));
    var visible = (try loaded.reuse(alloc, "visible", @splat(1))).?;
    defer visible.deinit(alloc);
    try std.testing.expectEqualStrings("Saved title", visible.value.visible.title.?);
    try std.testing.expectEqual(@as(usize, 3), visible.value.visible.history_len);
    try std.testing.expect((try loaded.reuse(alloc, "visible", @splat(3))) == null);
    var excluded = (try loaded.reuse(alloc, "private", @splat(2))).?;
    defer excluded.deinit(alloc);
    try std.testing.expectEqualStrings("private", excluded.value.excluded);
    stopped.store(true, .release);
    try std.testing.expectError(error.Cancelled, writer.save(alloc, &.{}, &stopped));
    var retained = try Loaded.load(alloc, writer.dir, null);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), retained.count());
}

test "catalog cache corruption and duplicate identifiers require rebuilding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) } };
    defer writer.deinit();
    const duplicate = Entry{ .fingerprint = @splat(4), .value = .{ .excluded = @constCast("duplicate") } };
    var stopped = std.atomic.Value(bool).init(false);
    try writer.save(alloc, &.{ duplicate, duplicate }, &stopped);
    var invalid = try Loaded.load(alloc, writer.dir, null);
    defer invalid.deinit(alloc);
    try std.testing.expect(!invalid.present());
    try io_mod.durableReplaceVerified(alloc, &writer.dir, file_name, "corrupt cache");
    var corrupt = try Loaded.load(alloc, writer.dir, null);
    defer corrupt.deinit(alloc);
    try std.testing.expect(!corrupt.present());
}

test "catalog older versions cancellation and bounds are misses" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) } };
    defer writer.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const valid = Entry{ .fingerprint = @splat(1), .value = .{ .excluded = @constCast("valid") } };
    try writer.save(alloc, &.{valid}, &stop);
    stop.store(true, .release);
    try std.testing.expectError(error.Cancelled, writer.save(alloc, &.{}, &stop));
    var retained = try Loaded.load(alloc, writer.dir, null);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), retained.count());
    var file = try writer.dir.dir.openFile(std.testing.io, file_name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    // Every earlier format, including v4 files that still carry legacy
    // ranking rows, is ignored and rebuilt rather than partially trusted.
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |version| {
        try file.writePositionalAll(std.testing.io, version, "fx-resume-catalog-v".len);
        var old_version = try Loaded.load(alloc, writer.dir, null);
        defer old_version.deinit(alloc);
        try std.testing.expect(!old_version.present());
    }
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    var written: usize = max_records;
    try std.testing.expectError(error.CatalogCacheTooLarge, writeRow(&payload, &written, .{ .id = "id", .fingerprint = @splat(0), .value = .excluded }));
}

test "catalog rows reject a v5 JSON payload relabelled v6" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const payload = "[{\"id\":\"legacy\",\"fingerprint\":\"" ++ text_utils.repeat("1", 64) ++ "\",\"value\":{\"legacy_ranking\":{\"workspace_root\":\"/workspace\",\"updated_at_ms\":20}}}]";
    var digest: Fingerprint = undefined;
    Sha256.hash(payload, &digest, .{});
    var bytes: std.Io.Writer.Allocating = .init(alloc);
    defer bytes.deinit();
    try bytes.writer.writeAll(magic);
    try bytes.writer.writeAll(&digest);
    try bytes.writer.writeAll(payload);
    try io_mod.durableReplaceVerified(alloc, &dir, file_name, bytes.written());
    var loaded = try Loaded.load(alloc, dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expect(!loaded.present());
}

test "catalog fingerprint binds authority fence display sidecar and missing event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session");
    {
        var file = try tmp.dir.createFile(std.testing.io, "session/session.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    // Legacy sessions carry no event log; the fingerprint must still exist.
    const legacy = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expectEqual(legacy, (try fingerprint(tmp.dir, "session")).?);
    // A later appearance of events.jsonl invalidates the legacy observation.
    {
        var file = try tmp.dir.createFile(std.testing.io, "session/events.jsonl", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const with_events = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &legacy, &with_events));
    // Adding or removing the authority marker, fence, or display sidecar must
    // invalidate the observation even when session.json and events.jsonl are
    // untouched.
    for ([_][]const u8{ "authority.json", "authority.pending.json", "display.json" }) |name| {
        const path = try std.testing.allocator.print("session/{s}", .{name});
        defer std.testing.allocator.free(path);
        const absent = (try fingerprint(tmp.dir, "session")).?;
        var file = try tmp.dir.createFile(std.testing.io, path, .{});
        try file.writeStreamingAll(std.testing.io, "{}\n");
        file.close(std.testing.io);
        const present = (try fingerprint(tmp.dir, "session")).?;
        try std.testing.expect(!std.mem.eql(u8, &absent, &present));
        try tmp.dir.deleteFile(std.testing.io, path);
    }
}

test "catalog fingerprint detects event appends and child directory permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session/subagent");
    for ([_][]const u8{ "session/session.json", "session/events.jsonl" }) |path| {
        var file = try tmp.dir.createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const first = (try fingerprint(tmp.dir, "session")).?;
    var events = try tmp.dir.openFile(std.testing.io, "session/events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    try events.writePositionalAll(std.testing.io, "more\n", 3);
    const appended = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &first, &appended));
    var child = try tmp.dir.openDir(std.testing.io, "session/subagent", .{ .iterate = true });
    defer child.close(std.testing.io);
    try child.setPermissions(std.testing.io, .fromMode(0o700));
    const private = (try fingerprint(tmp.dir, "session")).?;
    try child.setPermissions(std.testing.io, .fromMode(0o755));
    const changed = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &private, &changed));
}
