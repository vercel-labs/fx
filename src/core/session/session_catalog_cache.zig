const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_layout = @import("session_layout.zig");
const session_store = @import("session_store.zig");
const summary_codec = @import("session_summary_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
// Disposable v4 proofs bind replay and the legacy route gates to one stat window.
const magic = "fx-resume-catalog-v4\n";
const file_name = ".resume-catalog";
pub const max_bytes = 64 * 1024 * 1024;
pub const max_records = 100_000;
const Fingerprint = [Sha256.digest_length]u8;
const Generation = @import("session_event.zig").Identifier;

pub const Entry = struct {
    fingerprint: ?Fingerprint,
    value: union(enum) { visible: session_store.SessionSummary, excluded: []u8, legacy_ranking: LegacyRanking },

    /// Caller owns both strings; this is ranking evidence, never picker visibility.
    pub const LegacyRanking = struct {
        id: []u8,
        workspace_root: []u8,
        updated_at_ms: i64,
        generation: Generation,

        pub fn clone(alloc: Allocator, id_value: []const u8, workspace_root: []const u8, updated_at_ms: i64, generation: Generation) !LegacyRanking {
            const owned_id = try alloc.dupe(u8, id_value);
            errdefer alloc.free(owned_id);
            return .{ .id = owned_id, .workspace_root = try alloc.dupe(u8, workspace_root), .updated_at_ms = updated_at_ms, .generation = generation };
        }

        fn deinit(self: *LegacyRanking, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.workspace_root);
        }
    };

    fn id(self: Entry) []const u8 {
        return switch (self.value) {
            .visible => |summary| summary.id,
            .excluded => |name| name,
            .legacy_ranking => |ranking| ranking.id,
        };
    }

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.value) {
            .visible => |*summary| summary.deinit(alloc),
            .excluded => |name| alloc.free(name),
            .legacy_ranking => |*ranking| ranking.deinit(alloc),
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
    fingerprint: []const u8,
    value: union(enum) {
        visible: Summary,
        excluded: void,
        legacy_ranking: struct { workspace_root: []const u8, updated_at_ms: i64, generation: Generation },
    },
};

/// Owns parsed cache bytes. Reused entries are separately owned by the caller.
pub const Loaded = struct {
    bytes: ?[]u8 = null,
    parsed: ?std.json.Parsed([]Row) = null,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    picker_count: usize = 0,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        self.index.deinit(alloc);
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.bytes) |bytes| alloc.free(bytes);
        self.* = .{};
    }

    pub fn count(self: *const Loaded) usize {
        return self.picker_count;
    }
    pub fn rankingCount(self: *const Loaded) usize {
        return self.index.count() - self.picker_count;
    }
    pub fn present(self: *const Loaded) bool {
        return self.parsed != null;
    }
    pub fn contains(self: *const Loaded, id: []const u8) bool {
        const position = self.index.get(id) orelse return false;
        return self.parsed.?.value[position].value != .legacy_ranking;
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
        var file = try dir.openFile(io_mod.getIo(), file_name, .{ .follow_symlinks = false, .allow_directory = false, .resolve_beneath = true });
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
        if (bytes.len < magic.len + Sha256.digest_length or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidCatalogCache;
        const payload = bytes[magic.len + Sha256.digest_length ..];
        var digest: Fingerprint = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidCatalogCache;
        const parsed = try std.json.parseFromSlice([]Row, alloc, payload, .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = false, .max_value_len = max_bytes });
        errdefer parsed.deinit();
        if (parsed.value.len > max_records) return error.InvalidCatalogCache;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer index.deinit(alloc);
        try index.ensureTotalCapacity(alloc, @intCast(parsed.value.len));
        var picker_count: usize = 0;
        for (parsed.value, 0..) |row, i| {
            if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
            try session_layout.validateSessionId(row.id);
            if (row.fingerprint.len != 64) return error.InvalidCatalogCache;
            var fingerprint_bytes: Fingerprint = undefined;
            _ = std.fmt.hexToBytes(&fingerprint_bytes, row.fingerprint) catch return error.InvalidCatalogCache;
            if (row.value != .legacy_ranking) picker_count += 1;
            if (row.value == .legacy_ranking) {
                const ranking = row.value.legacy_ranking;
                try @import("session_store_paths.zig").validateWorkspaceRoot(ranking.workspace_root);
                if (ranking.updated_at_ms < 0) return error.InvalidCatalogCache;
            }
            if (row.value == .visible) {
                const summary = row.value.visible;
                if (summary.created_at_ms < 0 or summary.updated_at_ms < summary.created_at_ms) return error.InvalidCatalogCache;
                if (summary.history_len == 0 and !summary.has_checkpoint) return error.InvalidCatalogCache;
                _ = try session.ConversationLanguage.fromSlice(summary.language);
                _ = std.math.cast(usize, summary.history_len) orelse return error.InvalidCatalogCache;
                if (summary.title) |title| {
                    if (title.len > session_codec.max_session_title_bytes or !std.unicode.utf8ValidateSlice(title)) return error.InvalidCatalogCache;
                }
                for ([_]?[]const u8{ summary.workspace_root, summary.origin_workspace_root }) |root| {
                    if (root) |path| {
                        if (!std.fs.path.isAbsolute(path) or path.len > std.Io.Dir.max_path_bytes) return error.InvalidCatalogCache;
                    }
                }
            }
            const entry = index.getOrPutAssumeCapacity(row.id);
            if (entry.found_existing) return error.InvalidCatalogCache;
            entry.value_ptr.* = i;
        }
        return .{ .bytes = bytes, .parsed = parsed, .index = index, .picker_count = picker_count };
    }

    pub fn reuse(self: *const Loaded, alloc: Allocator, id: []const u8, fingerprint_value: Fingerprint) !?Entry {
        const position = self.index.get(id) orelse return null;
        const row = self.parsed.?.value[position];
        if (row.value == .legacy_ranking or !matches(row, fingerprint_value)) return null;
        return try cloneRow(alloc, row, fingerprint_value);
    }

    /// Generation from a successful replay observation, not a caller-selected source.
    pub fn rankingGeneration(self: *const Loaded, id: []const u8) ?Generation {
        const position = self.index.get(id) orelse return null;
        return switch (self.parsed.?.value[position].value) {
            .legacy_ranking => |ranking| ranking.generation,
            .visible, .excluded => null,
        };
    }

    /// Returns an independently owned ranking observation, never a picker row.
    pub fn reuseRanking(self: *const Loaded, alloc: Allocator, id: []const u8, fingerprint_value: Fingerprint) !?Entry {
        const position = self.index.get(id) orelse return null;
        const row = self.parsed.?.value[position];
        if (row.value != .legacy_ranking or !matches(row, fingerprint_value)) return null;
        return try cloneRow(alloc, row, fingerprint_value);
    }

    fn matches(row: Row, value: Fingerprint) bool {
        const hex = std.fmt.bytesToHex(value, .lower);
        return std.mem.eql(u8, row.fingerprint, &hex);
    }

    fn cloneRow(alloc: Allocator, row: Row, value: Fingerprint) !Entry {
        return .{ .fingerprint = value, .value = switch (row.value) {
            .visible => |summary| .{ .visible = try summary.clone(alloc, row.id) },
            .excluded => .{ .excluded = try alloc.dupe(u8, row.id) },
            .legacy_ranking => |ranking| .{ .legacy_ranking = try Entry.LegacyRanking.clone(alloc, row.id, ranking.workspace_root, ranking.updated_at_ms, ranking.generation) },
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

    pub fn save(self: *Writer, alloc: Allocator, entries: []const Entry, cancelled: *const std.atomic.Value(bool)) !void {
        return self.saveKind(alloc, entries, .picker, cancelled);
    }

    /// Replaces complete-scan ranking observations, preserving valid picker rows.
    pub fn saveRanking(self: *Writer, alloc: Allocator, entries: []const Entry, cancelled: *const std.atomic.Value(bool)) !void {
        return self.saveKind(alloc, entries, .ranking, cancelled);
    }

    const Purpose = enum { picker, ranking };

    fn saveKind(self: *Writer, alloc: Allocator, entries: []const Entry, purpose: Purpose, cancelled: *const std.atomic.Value(bool)) !void {
        if (cancelled.load(.acquire)) return error.Cancelled;
        if (entries.len > max_records) return error.CatalogCacheTooLarge;
        var previous = try Loaded.load(alloc, self.dir, cancelled);
        defer previous.deinit(alloc);
        var replaced: std.StringHashMapUnmanaged(void) = .empty;
        defer replaced.deinit(alloc);
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        payload.writer.writeByte('[') catch return error.OutOfMemory;
        var written: usize = 0;
        for (entries) |*entry| {
            if (cancelled.load(.acquire)) return error.Cancelled;
            const value = entry.fingerprint orelse continue;
            if ((entry.value == .legacy_ranking) != (purpose == .ranking)) return error.InvalidCatalogCache;
            try replaced.put(alloc, entry.id(), {});
            const hex = std.fmt.bytesToHex(value, .lower);
            try writeRow(&payload, &written, .{ .id = entry.id(), .fingerprint = &hex, .value = switch (entry.value) {
                .visible => |*summary| .{ .visible = Summary.from(summary) },
                .excluded => .excluded,
                .legacy_ranking => |ranking| .{ .legacy_ranking = .{ .workspace_root = ranking.workspace_root, .updated_at_ms = ranking.updated_at_ms, .generation = ranking.generation } },
            } });
        }
        if (previous.parsed) |parsed| for (parsed.value) |row| {
            if (cancelled.load(.acquire)) return error.Cancelled;
            if ((row.value == .legacy_ranking) == (purpose == .ranking) or replaced.contains(row.id)) continue;
            // Legacy picker observations have no fingerprint and must not erase ranking rows.
            const current = (if (row.value == .legacy_ranking)
                rankingFingerprint(self.dir.dir, row.id, row.value.legacy_ranking.generation)
            else
                fingerprint(self.dir.dir, row.id)) catch null;
            if (current) |stamp| if (Loaded.matches(row, stamp)) try writeRow(&payload, &written, row);
        };
        payload.writer.writeByte(']') catch return error.OutOfMemory;
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
    if (written.* != 0) payload.writer.writeByte(',') catch return error.OutOfMemory;
    // This writer is memory-only: WriteFailed means allocation exhaustion.
    std.json.Stringify.value(row, .{}, &payload.writer) catch return error.OutOfMemory;
    written.* += 1;
    if (payload.written().len > max_bytes - magic.len - Sha256.digest_length - 1) return error.CatalogCacheTooLarge;
}

/// Stats are freshness evidence only. Cache misses still use canonical discovery and admission.
pub fn fingerprint(dir: std.Io.Dir, id: []const u8) !?Fingerprint {
    try session_layout.validateSessionId(id);
    const before = (try statOptional(dir, id)) orelse return null;
    if (before.kind != .directory) return null;
    var digest = Sha256.init(.{});
    addStat(&digest, before);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "session.json", "events.jsonl" }) |name| {
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ id, name });
        const stat = (try statOptional(dir, path)) orelse return null;
        if (stat.kind != .file or stat.nlink != 1) return null;
        addStat(&digest, stat);
    }
    const child_path = try std.fmt.bufPrint(&path_buffer, "{s}/subagent", .{id});
    const child = try statOptional(dir, child_path);
    if (child) |stat| {
        if (stat.kind != .directory) return null;
        digest.update(&.{1});
        addStat(&digest, stat);
        for ([_][]const u8{ "owner.json", "control.json" }) |name| {
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/subagent/{s}", .{ id, name });
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

const watermark_name_len = "commit.".len + 32 + ".json".len;

/// Observes only the active-generation watermark used by the v3 importer, plus
/// fixed source inputs. Superseded watermarks never govern that committed prefix.
pub fn rankingFingerprint(root: std.Io.Dir, id: []const u8, generation: Generation) !?Fingerprint {
    try session_layout.validateSessionId(id);
    var dir = try root.openDir(io_mod.getIo(), id, .{ .follow_symlinks = false });
    defer dir.close(io_mod.getIo());
    return rankingFingerprintForOpenSession(root, id, dir, generation);
}

/// Binds the observation to the same directory handle used by canonical replay.
/// Replacement of that directory disables publication of the old handle's result.
pub fn rankingFingerprintForOpenSession(root: std.Io.Dir, id: []const u8, session_dir: std.Io.Dir, generation: Generation) !?Fingerprint {
    try session_layout.validateSessionId(id);
    const before = (try statOptional(root, id)) orelse return null;
    if (before.kind != .directory) return null;
    var dir = try session_dir.openDir(io_mod.getIo(), ".", .{ .follow_symlinks = false });
    defer dir.close(io_mod.getIo());
    if (!sameStat(before, try dir.stat(io_mod.getIo()))) return null;
    var hash = Sha256.init(.{});
    addStat(&hash, before);
    try addDevice(&hash, dir, ".");
    for ([_][]const u8{ "session.json", "events.jsonl", "authority.json", "authority.pending.json", "commit.pending.json", "session.legacy.json", "checkpoint.json" }) |name| {
        if (!try addRankingFile(&hash, dir, name)) return null;
    }
    var watermark_buffer: [watermark_name_len]u8 = undefined;
    const watermark = try std.fmt.bufPrint(&watermark_buffer, "commit.{s}.json", .{std.fmt.bytesToHex(generation, .lower)});
    if (!try addRankingFile(&hash, dir, watermark)) return null;
    if (try statOptional(dir, "subagent")) |child_stat| {
        if (child_stat.kind != .directory) return null;
        hash.update(&.{1});
        addStat(&hash, child_stat);
        try addDevice(&hash, dir, "subagent");
        var child = try dir.openDir(io_mod.getIo(), "subagent", .{ .follow_symlinks = false });
        defer child.close(io_mod.getIo());
        if (!sameStat(child_stat, try child.stat(io_mod.getIo()))) return null;
        for ([_][]const u8{ "owner.json", "control.json" }) |name| if (!try addRankingFile(&hash, child, name)) return null;
        if (!sameStat(child_stat, (try statOptional(dir, "subagent")) orelse return null)) return null;
    } else hash.update(&.{0});
    if (!sameStat(before, try dir.stat(io_mod.getIo())) or !sameStat(before, (try statOptional(root, id)) orelse return null)) return null;
    var result: Fingerprint = undefined;
    hash.final(&result);
    return result;
}

fn addRankingFile(hash: *Sha256, dir: std.Io.Dir, name: []const u8) !bool {
    hash.update(name);
    hash.update(&.{0});
    if (try statOptional(dir, name)) |stat| {
        if (stat.kind != .file or stat.nlink != 1) return false;
        hash.update(&.{1});
        addStat(hash, stat);
        try addDevice(hash, dir, name);
    } else hash.update(&.{0});
    return true;
}

// std.Io.File.Stat omits device identity. Match the authority reader's native
// no-follow observation; unsupported targets cannot produce ranking cache hits.
fn addDevice(hash: *Sha256, dir: std.Io.Dir, name: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
    const device: u64 = switch (@import("builtin").os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var stat: linux.Statx = std.mem.zeroes(linux.Statx);
            while (true) switch (linux.errno(linux.statx(dir.handle, path, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &stat))) {
                .SUCCESS => break :blk (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
                .INTR => continue,
                else => return error.RankingFingerprintUnavailable,
            };
        },
        .macos => blk: {
            var stat: std.c.Stat = undefined;
            while (true) switch (std.c.errno(std.c.fstatat(dir.handle, path, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
                .SUCCESS => break :blk @intCast(stat.dev),
                .INTR => continue,
                else => return error.RankingFingerprintUnavailable,
            };
        },
        else => return error.RankingFingerprintUnavailable,
    };
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, device, .little);
    hash.update(&bytes);
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
    const values = [_]u128{ stat.inode, stat.nlink, stat.size, @intFromEnum(stat.kind), stat.permissions.toMode(), @bitCast(@as(i128, stat.mtime.nanoseconds)), @bitCast(@as(i128, stat.ctime.nanoseconds)) };
    var bytes: [16]u8 = undefined;
    for (values) |value| {
        std.mem.writeInt(u128, &bytes, value, .little);
        hash.update(&bytes);
    }
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

fn rankingTestSource(dir: std.Io.Dir, id: []const u8) !void {
    try dir.createDir(io_mod.getIo(), id, .fromMode(0o700));
    var child = try dir.openDir(io_mod.getIo(), id, .{});
    defer child.close(io_mod.getIo());
    for ([_][]const u8{ "session.json", "events.jsonl", "authority.json", "commit.11111111111111111111111111111111.json" }) |name| {
        var file = try child.createFile(io_mod.getIo(), name, .{ .permissions = .fromMode(0o600) });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "{}\n");
    }
}

test "catalog ranking rows roundtrip isolate kinds and survive picker publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rankingTestSource(tmp.dir, "legacy");
    try rankingTestSource(tmp.dir, "picker");
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) } };
    defer writer.deinit();
    const stamp = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?;
    const ranking = Entry{ .fingerprint = stamp, .value = .{ .legacy_ranking = .{ .id = @constCast("legacy"), .workspace_root = @constCast("/workspace"), .updated_at_ms = 20, .generation = @splat(0x11) } } };
    const picker = Entry{ .fingerprint = try fingerprint(tmp.dir, "picker"), .value = .{ .excluded = @constCast("picker") } };
    const legacy_picker = Entry{ .fingerprint = null, .value = .{ .excluded = @constCast("legacy") } };
    var stop = std.atomic.Value(bool).init(false);
    try writer.saveRanking(alloc, &.{ranking}, &stop);
    try writer.save(alloc, &.{ picker, legacy_picker }, &stop);
    try writer.saveRanking(alloc, &.{ranking}, &stop);
    var loaded = try Loaded.load(alloc, writer.dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expectEqual(@as(usize, 1), loaded.rankingCount());
    try std.testing.expect(!loaded.contains("legacy"));
    try std.testing.expect(loaded.contains("picker"));
    try std.testing.expect((try loaded.reuse(alloc, "legacy", stamp)) == null);
    try std.testing.expect((try loaded.reuseRanking(alloc, "picker", picker.fingerprint.?)) == null);
    try std.testing.expect((try loaded.reuseRanking(alloc, "legacy", @splat(0))) == null);
    var reused = (try loaded.reuseRanking(alloc, "legacy", stamp)).?;
    defer reused.deinit(alloc);
    try std.testing.expectEqualStrings("legacy", reused.value.legacy_ranking.id);
    try std.testing.expectEqualStrings("/workspace", reused.value.legacy_ranking.workspace_root);
    try std.testing.expectEqual(@as(i64, 20), reused.value.legacy_ranking.updated_at_ms);

    // A newly migrated, cacheable picker row supersedes its old ranking row.
    const migrated = Entry{ .fingerprint = try fingerprint(tmp.dir, "legacy"), .value = .{ .excluded = @constCast("legacy") } };
    try writer.save(alloc, &.{ picker, migrated }, &stop);
    var replaced = try Loaded.load(alloc, writer.dir, null);
    defer replaced.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), replaced.count());
    try std.testing.expectEqual(@as(usize, 0), replaced.rankingCount());
}

test "catalog ranking fingerprint detects in-place authority and active watermark inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rankingTestSource(tmp.dir, "legacy");
    var dir = try tmp.dir.openDir(std.testing.io, "legacy", .{});
    defer dir.close(std.testing.io);
    for ([_][]const u8{ "authority.pending.json", "commit.pending.json", "session.legacy.json", "checkpoint.json" }) |name| {
        var file = try dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    for ([_][]const u8{ "session.json", "events.jsonl", "authority.json", "authority.pending.json", "commit.pending.json", "session.legacy.json", "checkpoint.json", "commit.11111111111111111111111111111111.json" }) |name| {
        const before = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?;
        const parent = try dir.stat(std.testing.io);
        var file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        io_mod.sleep(2 * std.time.ns_per_ms);
        try file.writePositionalAll(std.testing.io, "bad", 0);
        try std.testing.expect(sameStat(parent, try dir.stat(std.testing.io)));
        try std.testing.expect(!std.mem.eql(u8, &before, &(try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?));
    }
    const before = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?;
    try dir.deleteFile(std.testing.io, "authority.pending.json");
    try std.testing.expect(!std.mem.eql(u8, &before, &(try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?));
    var unknown = try dir.createFile(std.testing.io, "commit.unknown.json", .{});
    defer unknown.close(std.testing.io);
    const with_obsolete = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?;
    try unknown.writeStreamingAll(std.testing.io, "not an active watermark");
    try std.testing.expectEqual(with_obsolete, (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?);
}

test "catalog ranking fingerprint rejects active symlinks and replaced directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rankingTestSource(tmp.dir, "legacy");
    var original = try tmp.dir.openDir(std.testing.io, "legacy", .{});
    defer original.close(std.testing.io);
    try tmp.dir.rename("legacy", tmp.dir, "old", std.testing.io);
    try rankingTestSource(tmp.dir, "legacy");
    try std.testing.expect((try rankingFingerprintForOpenSession(tmp.dir, "legacy", original, @splat(0x11))) == null);
    var dir = try tmp.dir.openDir(std.testing.io, "legacy", .{});
    defer dir.close(std.testing.io);
    try dir.symLink(std.testing.io, "events.jsonl", "authority.pending.json", .{});
    try std.testing.expect((try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))) == null);
    try dir.deleteFile(std.testing.io, "authority.pending.json");
    try dir.deleteFile(std.testing.io, "commit.11111111111111111111111111111111.json");
    try dir.symLink(std.testing.io, "events.jsonl", "commit.11111111111111111111111111111111.json", .{});
    try std.testing.expect((try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))) == null);
}

test "catalog ranking cache tolerates thousands of obsolete watermarks and binds generation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rankingTestSource(tmp.dir, "legacy");
    var dir = try tmp.dir.openDir(std.testing.io, "legacy", .{});
    defer dir.close(std.testing.io);
    var name_buffer: [watermark_name_len]u8 = undefined;
    for (0..1536) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "commit.{x:0>32}.json", .{index});
        var file = try dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "obsolete invalid JSON");
    }
    const generation: Generation = @splat(0x11);
    const stamp = (try rankingFingerprint(tmp.dir, "legacy", generation)).?;
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) } };
    defer writer.deinit();
    const ranking = Entry{ .fingerprint = stamp, .value = .{ .legacy_ranking = .{ .id = @constCast("legacy"), .workspace_root = @constCast("/workspace"), .updated_at_ms = 20, .generation = generation } } };
    var stop = std.atomic.Value(bool).init(false);
    try writer.saveRanking(alloc, &.{ranking}, &stop);
    try writer.save(alloc, &.{}, &stop);
    var loaded = try Loaded.load(alloc, writer.dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(generation, loaded.rankingGeneration("legacy").?);
    var reused = (try loaded.reuseRanking(alloc, "legacy", (try rankingFingerprint(tmp.dir, "legacy", generation)).?)).?;
    defer reused.deinit(alloc);
    try std.testing.expectEqual(generation, reused.value.legacy_ranking.generation);
    const other = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x22))).?;
    try std.testing.expect((try loaded.reuseRanking(alloc, "legacy", other)) == null);
    var events = try dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    try events.writePositionalAll(std.testing.io, "new generation", 0);
    const changed = (try rankingFingerprint(tmp.dir, "legacy", generation)).?;
    try std.testing.expect((try loaded.reuseRanking(alloc, "legacy", changed)) == null);
}

test "catalog ranking invalid rows versions cancellation and bounds are misses" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) } };
    defer writer.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const invalid = [_]Entry{
        .{ .fingerprint = @splat(1), .value = .{ .legacy_ranking = .{ .id = @constCast("relative"), .workspace_root = @constCast("relative"), .updated_at_ms = 20, .generation = @splat(0x11) } } },
        .{ .fingerprint = @splat(1), .value = .{ .legacy_ranking = .{ .id = @constCast("negative"), .workspace_root = @constCast("/workspace"), .updated_at_ms = -1, .generation = @splat(0x11) } } },
    };
    for (invalid) |row| {
        try writer.saveRanking(alloc, &.{row}, &stop);
        var loaded = try Loaded.load(alloc, writer.dir, null);
        defer loaded.deinit(alloc);
        try std.testing.expect(!loaded.present());
    }
    const valid = Entry{ .fingerprint = @splat(1), .value = .{ .legacy_ranking = .{ .id = @constCast("valid"), .workspace_root = @constCast("/workspace"), .updated_at_ms = 20, .generation = @splat(0x11) } } };
    try writer.saveRanking(alloc, &.{ valid, valid }, &stop);
    var duplicate = try Loaded.load(alloc, writer.dir, null);
    defer duplicate.deinit(alloc);
    try std.testing.expect(!duplicate.present());
    try writer.saveRanking(alloc, &.{valid}, &stop);
    stop.store(true, .release);
    try std.testing.expectError(error.Cancelled, writer.saveRanking(alloc, &.{}, &stop));
    var retained = try Loaded.load(alloc, writer.dir, null);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), retained.rankingCount());
    var file = try writer.dir.dir.openFile(std.testing.io, file_name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    for ([_][]const u8{ "1", "2", "3" }) |version| {
        try file.writePositionalAll(std.testing.io, version, "fx-resume-catalog-v".len);
        var old_version = try Loaded.load(alloc, writer.dir, null);
        defer old_version.deinit(alloc);
        try std.testing.expect(!old_version.present());
    }
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    var written: usize = max_records;
    try std.testing.expectError(error.CatalogCacheTooLarge, writeRow(&payload, &written, .{ .id = "id", .fingerprint = "", .value = .excluded }));
}

test "catalog ranking missing or malformed generation requires rebuilding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const prefix = "[{\"id\":\"legacy\",\"fingerprint\":\"" ++ "1" ** 64 ++ "\",\"value\":{\"legacy_ranking\":{\"workspace_root\":\"/workspace\",\"updated_at_ms\":20";
    for ([_][]const u8{ prefix ++ "}}}]", prefix ++ ",\"generation\":[1]}}}]", prefix ++ ",\"generation\":null}}}]" }) |payload| {
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
}

test "catalog ranking allocation failures clean owned rows and merged publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try rankingTestSource(tmp.dir, "legacy");
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false }) } };
    defer writer.deinit();
    const stamp = (try rankingFingerprint(tmp.dir, "legacy", @splat(0x11))).?;
    const ranking = Entry{ .fingerprint = stamp, .value = .{ .legacy_ranking = .{ .id = @constCast("legacy"), .workspace_root = @constCast("/workspace"), .updated_at_ms = 20, .generation = @splat(0x11) } } };
    var stop = std.atomic.Value(bool).init(false);
    try writer.saveRanking(alloc, &.{ranking}, &stop);
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator, output: *Writer, fingerprint_value: Fingerprint) !void {
            var loaded = try Loaded.load(a, output.dir, null);
            defer loaded.deinit(a);
            var reused = (try loaded.reuseRanking(a, "legacy", fingerprint_value)).?;
            defer reused.deinit(a);
            var cancelled = std.atomic.Value(bool).init(false);
            try output.saveRanking(a, &.{reused}, &cancelled);
            try output.save(a, &.{}, &cancelled);
        }
    }.check, .{ &writer, stamp });
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
