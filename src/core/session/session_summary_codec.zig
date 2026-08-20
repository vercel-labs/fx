const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_replay = @import("session_replay.zig");
const Allocator = std.mem.Allocator;

const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const validateSessionId = paths.validateSessionId;
const SessionSummary = types.SessionSummary;
const ResumableSessionContinuation = types.ResumableSessionContinuation;
const ResumableSessionPage = types.ResumableSessionPage;
const StateSummary = types.StateSummary;

const WorkspaceLatest = struct {
    workspace_root: []u8,
    session_id: []u8,

    fn deinit(self: *WorkspaceLatest, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const SmallCacheRead = union(enum) {
    missing,
    oversized,
    bytes: []const u8,
};

const JsonStringToken = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: JsonStringToken, alloc: Allocator) void {
        if (self.owned) |value| alloc.free(value);
    }
};

pub const session_index_file = "index.json";
const session_index_marker_file = "index.pending";
const session_index_marker_contents = "pending\n";
const relationship_migration_snapshot_file = "relationship-migration-index.json";
pub const max_session_index_bytes: usize = 16 * 1024 * 1024;
const session_index_schema_version: i64 = 3;
const deferred_cache_token_schema_version: i64 = 1;
pub const max_deferred_cache_token_bytes: usize = 4 * 1024;
const max_deferred_cache_token_count: usize = 4096;
pub const deferred_cache_dir = "deferred";
pub const relationship_migration_candidate_limit: usize = 16;
const relationship_migration_read_bytes: usize = 64 * 1024;
const relationship_migration_overlap_bytes: u64 = 512;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);

const DeferredCachePositionJson = struct {
    log_generation: []const u8,
    through_seq: u64,
    through_event_id: []const u8,
    through_event_log_bytes: u64,
};

const DeferredCacheTokenJson = struct {
    schema_version: i64,
    session_id: []const u8,
    workspace_root: []const u8,
    position: DeferredCachePositionJson,
};

pub const DeferredCacheToken = struct {
    session_id: []u8,
    workspace_root: []u8,
    position: session_replay.CommitPosition,

    pub fn deinit(self: *DeferredCacheToken, alloc: Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub fn encodeDeferredCacheToken(
    alloc: Allocator,
    session_id: []const u8,
    workspace_root: []const u8,
    position: session_replay.CommitPosition,
) ![]u8 {
    try validateSessionId(session_id);
    try paths.validateWorkspaceRoot(workspace_root);

    const generation = std.fmt.bytesToHex(position.log_generation, .lower);
    const event_id = std.fmt.bytesToHex(position.through_event_id, .lower);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"schema_version\":{d},\"session_id\":", .{deferred_cache_token_schema_version});
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(",\"position\":{\"log_generation\":");
    try std.json.Stringify.value(&generation, .{}, &out.writer);
    try out.writer.print(",\"through_seq\":{d},\"through_event_id\":", .{position.through_seq});
    try std.json.Stringify.value(&event_id, .{}, &out.writer);
    try out.writer.print(",\"through_event_log_bytes\":{d}}}}}", .{position.through_event_log_bytes});
    const encoded = try out.toOwnedSlice();
    if (encoded.len > max_deferred_cache_token_bytes) {
        alloc.free(encoded);
        return error.InvalidSessionIndex;
    }
    return encoded;
}

pub fn decodeDeferredCacheToken(
    alloc: Allocator,
    bytes: []const u8,
) !DeferredCacheToken {
    if (bytes.len == 0 or bytes.len > max_deferred_cache_token_bytes) {
        return error.InvalidSessionIndex;
    }
    var parsed = std.json.parseFromSlice(
        DeferredCacheTokenJson,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer parsed.deinit();

    if (parsed.value.schema_version != deferred_cache_token_schema_version) {
        return error.InvalidSessionIndex;
    }
    validateSessionId(parsed.value.session_id) catch
        return error.InvalidSessionIndex;
    paths.validateWorkspaceRoot(parsed.value.workspace_root) catch
        return error.InvalidSessionIndex;

    const session_id = try alloc.dupe(u8, parsed.value.session_id);
    errdefer alloc.free(session_id);
    const workspace_root = try alloc.dupe(u8, parsed.value.workspace_root);
    errdefer alloc.free(workspace_root);
    return .{
        .session_id = session_id,
        .workspace_root = workspace_root,
        .position = .{
            .log_generation = try parseDeferredTokenIdentifier(
                parsed.value.position.log_generation,
            ),
            .through_seq = parsed.value.position.through_seq,
            .through_event_id = try parseDeferredTokenIdentifier(
                parsed.value.position.through_event_id,
            ),
            .through_event_log_bytes = parsed.value.position.through_event_log_bytes,
        },
    };
}

fn parseDeferredTokenIdentifier(raw: []const u8) ![16]u8 {
    if (raw.len != 32) return error.InvalidSessionIndex;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionIndex;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionIndex;
    return result;
}

pub fn deferredCachePresent(
    sessions: *const io_mod.VerifiedDir,
) !bool {
    var deferred = (try openDeferredCacheDirectory(sessions)) orelse return false;
    defer deferred.close();
    var iter = deferred.dir.iterate();
    return (try iter.next(io_mod.getIo())) != null;
}

fn openDeferredCacheDirectory(
    sessions: *const io_mod.VerifiedDir,
) !?io_mod.VerifiedDir {
    var latest = sessions.dir.openDir(io_mod.getIo(), "latest", .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidSessionIndex,
        else => return err,
    };
    defer latest.close(io_mod.getIo());

    var deferred = latest.openDir(io_mod.getIo(), deferred_cache_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidSessionIndex,
        else => return err,
    };
    errdefer deferred.close(io_mod.getIo());
    try requirePrivateCacheDirectory(latest);
    try requirePrivateCacheDirectory(deferred);
    return .{ .dir = deferred };
}

fn requirePrivateCacheDirectory(dir: std.Io.Dir) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != private_dir_permissions.toMode())
    {
        return error.InvalidSessionIndex;
    }
}

pub fn readDeferredCacheTokens(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
) !std.ArrayList(DeferredCacheToken) {
    var tokens: std.ArrayList(DeferredCacheToken) = .empty;
    errdefer freeDeferredCacheTokens(alloc, &tokens);
    var deferred = (try openDeferredCacheDirectory(sessions)) orelse return tokens;
    defer deferred.close();

    var iter = deferred.dir.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        if (tokens.items.len >= max_deferred_cache_token_count) {
            return error.InvalidSessionIndex;
        }
        if (entry.kind != .file) return error.InvalidSessionIndex;
        try validateSessionId(entry.name);
        var token = try readDeferredCacheTokenFromDirectory(
            alloc,
            &deferred,
            entry.name,
        );
        errdefer token.deinit(alloc);
        if (!std.mem.eql(u8, entry.name, token.session_id)) {
            return error.InvalidSessionIndex;
        }
        try tokens.append(alloc, token);
    }
    return tokens;
}

pub fn readDeferredCacheToken(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !?DeferredCacheToken {
    try validateSessionId(session_id);
    var deferred = (try openDeferredCacheDirectory(sessions)) orelse return null;
    defer deferred.close();
    return readDeferredCacheTokenFromDirectory(
        alloc,
        &deferred,
        session_id,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn readDeferredCacheTokenFromDirectory(
    alloc: Allocator,
    deferred: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !DeferredCacheToken {
    var file = deferred.dir.openFile(io_mod.getIo(), session_id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop, error.IsDir => {
            return error.InvalidSessionIndex;
        },
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or
        stat.permissions.toMode() & 0o777 != private_file_permissions.toMode() or
        stat.size == 0 or stat.size > max_deferred_cache_token_bytes)
    {
        return error.InvalidSessionIndex;
    }
    const bytes = io_mod.readFileToEnd(
        alloc,
        &file,
        max_deferred_cache_token_bytes + 1,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer alloc.free(bytes);
    return decodeDeferredCacheToken(alloc, bytes);
}

pub fn freeDeferredCacheTokens(
    alloc: Allocator,
    tokens: *std.ArrayList(DeferredCacheToken),
) void {
    for (tokens.items) |*token| token.deinit(alloc);
    tokens.deinit(alloc);
}

pub const RelationshipMigrationCursor = struct {
    inode: u64 = 0,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    offset: u64 = 0,
};

pub const RelationshipMigrationCandidatePage = struct {
    cursor: RelationshipMigrationCursor,
    ids: std.ArrayList([]u8) = .empty,
    has_more: bool = false,

    pub fn deinit(self: *RelationshipMigrationCandidatePage, alloc: Allocator) void {
        for (self.ids.items) |id| alloc.free(id);
        self.ids.deinit(alloc);
        self.* = undefined;
    }
};

fn readOptionalCacheFile(alloc: Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_bytes);
}

/// Reads the aggregate summary cache at `path`, trying a stack-buffer fast
/// read then the fast parser, falling back to a heap read + scanner parse.
/// `error.SessionIndexNotFound` if absent. Caller owns the result.
pub fn readSessionStateSummary(alloc: Allocator, path: []const u8) !StateSummary {
    var prefix_buf: [4096]u8 = undefined;
    if (try readCachePrefix(path, &prefix_buf)) |prefix| {
        if (try parseSessionStateSummaryFast(alloc, prefix)) |summary| {
            return summary;
        }
    } else {
        return error.SessionIndexNotFound;
    }

    var stack_buf: [64 * 1024]u8 = undefined;
    switch (try readSmallCacheFile(path, &stack_buf)) {
        .missing => return error.SessionIndexNotFound,
        .oversized => {},
        .bytes => |bytes| {
            if (try parseSessionStateSummaryFast(alloc, bytes)) |summary| return summary;
            return parseSessionStateSummary(alloc, bytes);
        },
    }

    const bytes = try readOptionalCacheFile(alloc, path, 256 * 1024) orelse return error.SessionIndexNotFound;
    defer alloc.free(bytes);

    if (try parseSessionStateSummaryFast(alloc, bytes)) |summary| return summary;
    return parseSessionStateSummary(alloc, bytes);
}

fn readCachePrefix(path: []const u8, buffer: []u8) !?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const count = try file.readPositionalAll(io_mod.getIo(), buffer, 0);
    return buffer[0..count];
}

/// Reads the latest session id for `target_workspace` from the summary cache,
/// fast path then scanner fallback. Returns null if the workspace has no entry.
fn readLatestWorkspaceSessionId(alloc: Allocator, path: []const u8, target_workspace: []const u8) !?[]u8 {
    var stack_buf: [64 * 1024]u8 = undefined;
    switch (try readSmallCacheFile(path, &stack_buf)) {
        .missing => return error.SessionIndexNotFound,
        .oversized => {},
        .bytes => |bytes| {
            if (try parseLatestWorkspaceSessionIdFast(alloc, bytes, target_workspace)) |id| return id;
            return parseLatestWorkspaceSessionId(alloc, bytes, target_workspace);
        },
    }

    const bytes = try readOptionalCacheFile(alloc, path, 256 * 1024) orelse return error.SessionIndexNotFound;
    defer alloc.free(bytes);

    if (try parseLatestWorkspaceSessionIdFast(alloc, bytes, target_workspace)) |id| return id;
    return parseLatestWorkspaceSessionId(alloc, bytes, target_workspace);
}

fn readSmallCacheFile(path: []const u8, buf: []u8) !SmallCacheRead {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const zio = io_mod.getIo();
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(zio, &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => return .{ .bytes = buf[0..total] },
            else => return err,
        };
        if (n == 0) return .{ .bytes = buf[0..total] };
        total += n;
    }

    var extra: [1]u8 = undefined;
    const n = file.readStreaming(zio, &.{extra[0..]}) catch |err| switch (err) {
        error.EndOfStream => return .{ .bytes = buf[0..total] },
        else => return err,
    };
    return if (n == 0) .{ .bytes = buf[0..total] } else .oversized;
}

/// Best-effort byte scan for one workspace entry. Returns null to defer to the
/// scanner path; only allocation can fail.
fn parseLatestWorkspaceSessionIdFast(alloc: Allocator, bytes: []const u8, target_workspace: []const u8) Allocator.Error!?[]u8 {
    if (!isSimpleJsonStringContent(target_workspace)) return null;

    const array_key = "\"latest_by_workspace\":[";
    const array_start = std.mem.find(u8, bytes, array_key) orelse return null;
    const array_tail = bytes[array_start + array_key.len ..];
    const array_end = std.mem.findScalar(u8, array_tail, ']') orelse return null;
    const array = array_tail[0..array_end];

    var needle_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"workspace_root\":\"{s}\"", .{target_workspace}) catch return null;
    const match_start = std.mem.find(u8, array, needle) orelse return null;
    const entry_tail = array[match_start + needle.len ..];
    const entry_end = std.mem.findScalar(u8, entry_tail, '}') orelse return null;
    const entry = entry_tail[0..entry_end];

    const id_key = "\"id\":\"";
    const id_start = std.mem.find(u8, entry, id_key) orelse return null;
    const id_tail = entry[id_start + id_key.len ..];
    const id_end = std.mem.findScalar(u8, id_tail, '"') orelse return null;
    const id = id_tail[0..id_end];
    validateSessionId(id) catch return null;
    return try alloc.dupe(u8, id);
}

/// True if `text` contains no characters needing JSON escaping, so it is safe
/// to match literally in the fast scan.
fn isSimpleJsonStringContent(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == '"' or byte == '\\') return false;
    }
    return true;
}

/// Best-effort byte scan of the summary cache. Returns the parsed summary, or
/// null to signal "fall back to the scanner" (it never reports a hard parse
/// error); only allocation can fail.
fn parseSessionStateSummaryFast(alloc: Allocator, bytes: []const u8) Allocator.Error!?StateSummary {
    const schema_key = "\"schema_version\":1";
    if (std.mem.find(u8, bytes, schema_key) == null) return null;

    const count_key = "\"count\":";
    const count_start = std.mem.find(u8, bytes, count_key) orelse return null;
    const count_tail = bytes[count_start + count_key.len ..];
    const count_end = countNumberEnd(count_tail);
    if (count_end == 0) return null;
    const count = std.fmt.parseUnsigned(usize, count_tail[0..count_end], 10) catch return null;

    const latest_key = "\"latest_id\":";
    const latest_start = std.mem.find(u8, bytes, latest_key) orelse return null;
    const latest_tail = bytes[latest_start + latest_key.len ..];
    if (std.mem.startsWith(u8, latest_tail, "null")) {
        return .{ .count = count, .latest_id = null };
    }
    if (latest_tail.len == 0 or latest_tail[0] != '"') return null;
    const id_tail = latest_tail[1..];
    const id_end = std.mem.findScalar(u8, id_tail, '"') orelse return null;
    const id = id_tail[0..id_end];
    if (!isSimpleJsonStringContent(id)) return null;
    validateSessionId(id) catch return null;

    return .{
        .count = count,
        .latest_id = try alloc.dupe(u8, id),
    };
}

fn countNumberEnd(bytes: []const u8) usize {
    var end: usize = 0;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) {
        end += 1;
    }
    return end;
}

/// Authoritative `std.json.Scanner` parse of the summary cache. Strict:
/// malformed input is `error.InvalidSessionIndex`.
fn parseSessionStateSummary(alloc: Allocator, bytes: []const u8) !StateSummary {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();

    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var count: ?usize = null;
    var latest_id: ?[]u8 = null;
    errdefer if (latest_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "schema_version")) {
                    schema_ok = try readSummarySchemaVersion(&scanner);
                } else if (std.mem.eql(u8, key.text, "count")) {
                    count = try readJsonUsize(&scanner);
                } else if (std.mem.eql(u8, key.text, "latest_id")) {
                    latest_id = try readOptionalJsonStringDup(&scanner, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);

    if (!schema_ok) return error.InvalidSessionIndex;
    if (latest_id) |id| validateSessionId(id) catch return error.InvalidSessionIndex;
    return .{ .count = count orelse return error.InvalidSessionIndex, .latest_id = latest_id };
}

/// Authoritative scanner parse returning the matched workspace id, or null.
fn parseLatestWorkspaceSessionId(alloc: Allocator, bytes: []const u8, target_workspace: []const u8) !?[]u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();

    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "schema_version")) {
                    schema_ok = try readSummarySchemaVersion(&scanner);
                } else if (std.mem.eql(u8, key.text, "latest_by_workspace")) {
                    matched_id = try readLatestWorkspaceArray(&scanner, alloc, target_workspace);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);

    if (!schema_ok) return error.InvalidSessionIndex;
    return matched_id;
}

fn readLatestWorkspaceArray(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) !?[]u8 {
    try expectJsonToken(try scanner.next(), .array_begin);
    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .array_end => return matched_id,
            .object_begin => {
                const candidate = try readLatestWorkspaceEntry(scanner, alloc, target_workspace);
                if (candidate) |id| {
                    if (matched_id == null) {
                        matched_id = id;
                    } else {
                        alloc.free(id);
                    }
                }
            },
            else => return error.InvalidSessionIndex,
        }
    }
}

fn readLatestWorkspaceEntry(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) !?[]u8 {
    var workspace_matches = false;
    var id: ?[]u8 = null;
    errdefer if (id) |value| alloc.free(value);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "workspace_root")) {
                    const value = try readJsonString(scanner, alloc);
                    defer value.deinit(alloc);
                    workspace_matches = std.mem.eql(u8, value.text, target_workspace);
                } else if (std.mem.eql(u8, key.text, "id")) {
                    if (id) |old| alloc.free(old);
                    id = try readJsonStringDup(scanner, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }

    if (workspace_matches) {
        const matched_id = id orelse return error.InvalidSessionIndex;
        validateSessionId(matched_id) catch return error.InvalidSessionIndex;
        return matched_id;
    }
    if (id) |value| alloc.free(value);
    return null;
}

fn readSummarySchemaVersion(scanner: *std.json.Scanner) !bool {
    const token = try scanner.next();
    switch (token) {
        .number => |raw| return std.mem.eql(u8, raw, "1"),
        else => return error.InvalidSessionIndex,
    }
}

fn readJsonUsize(scanner: *std.json.Scanner) !usize {
    const token = try scanner.next();
    switch (token) {
        .number => |raw| return std.fmt.parseUnsigned(usize, raw, 10) catch error.InvalidSessionIndex,
        else => return error.InvalidSessionIndex,
    }
}

fn readOptionalJsonStringDup(scanner: *std.json.Scanner, alloc: Allocator) !?[]u8 {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .null => return null,
        .string, .allocated_string => {
            const value = try jsonStringFromToken(token);
            defer value.deinit(alloc);
            return try alloc.dupe(u8, value.text);
        },
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    }
}

fn readJsonStringDup(scanner: *std.json.Scanner, alloc: Allocator) ![]u8 {
    const value = try readJsonString(scanner, alloc);
    defer value.deinit(alloc);
    return try alloc.dupe(u8, value.text);
}

fn readJsonString(scanner: *std.json.Scanner, alloc: Allocator) !JsonStringToken {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .string, .allocated_string => return jsonStringFromToken(token),
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    }
}

fn jsonStringFromToken(token: std.json.Token) !JsonStringToken {
    return switch (token) {
        .string => |text| .{ .text = text },
        .allocated_string => |text| .{ .text = text, .owned = text },
        else => error.InvalidSessionIndex,
    };
}

fn freeJsonToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |text| alloc.free(text),
        .allocated_number => |text| alloc.free(text),
        else => {},
    }
}

fn expectJsonToken(token: std.json.Token, comptime expected: std.json.TokenType) !void {
    const actual: std.json.TokenType = switch (token) {
        .object_begin => .object_begin,
        .object_end => .object_end,
        .array_begin => .array_begin,
        .array_end => .array_end,
        .true => .true,
        .false => .false,
        .null => .null,
        .number, .partial_number, .allocated_number => .number,
        .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .allocated_string => .string,
        .end_of_document => .end_of_document,
    };
    if (actual != expected) return error.InvalidSessionIndex;
}

fn appendLatestWorkspaceSummary(alloc: Allocator, latest: *std.ArrayList(WorkspaceLatest), workspace_root: []const u8, session_id: []const u8) !void {
    for (latest.items) |*entry| {
        if (!std.mem.eql(u8, entry.workspace_root, workspace_root)) continue;
        if (std.mem.order(u8, session_id, entry.session_id) != .gt) return;
        const replacement_id = try alloc.dupe(u8, session_id);
        alloc.free(entry.session_id);
        entry.session_id = replacement_id;
        return;
    }

    const owned_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace_root);
    const owned_session_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_session_id);
    try latest.append(alloc, .{
        .workspace_root = owned_workspace_root,
        .session_id = owned_session_id,
    });
}

/// Parses the session index document into newest-first summaries, validating
/// the schema version and each id. Caller owns and frees the list.
fn parseSessionIndex(alloc: Allocator, json_text: []const u8) !std.ArrayList(SessionSummary) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidSessionIndex;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionIndex;

    const schema_value = parsed.value.object.get("schema_version") orelse return error.InvalidSessionIndex;
    if (schema_value != .integer or schema_value.integer != session_index_schema_version) return error.InvalidSessionIndex;

    const sessions_value = parsed.value.object.get("sessions") orelse return error.InvalidSessionIndex;
    if (sessions_value != .array) return error.InvalidSessionIndex;

    var results: std.ArrayList(SessionSummary) = .empty;
    errdefer freeSummaries(alloc, &results);
    for (sessions_value.array.items) |value| {
        var summary = try parseIndexedSummary(alloc, value);
        results.append(alloc, summary) catch |err| {
            summary.deinit(alloc);
            return err;
        };
    }
    sortSummariesNewestFirst(results.items);
    return results;
}

fn parseSessionIndexForWorkspace(
    alloc: Allocator,
    json_text: []const u8,
    workspace_root: []const u8,
) !std.ArrayList(SessionSummary) {
    if (try parseSessionIndexForWorkspaceFast(
        alloc,
        json_text,
        workspace_root,
    )) |summaries| return summaries;

    var summaries = try parseSessionIndex(alloc, json_text);
    var retained: usize = 0;
    for (summaries.items) |*summary| {
        if (summary.workspace_root != null and std.mem.eql(
            u8,
            summary.workspace_root.?,
            workspace_root,
        )) {
            summaries.items[retained] = summary.*;
            retained += 1;
        } else {
            summary.deinit(alloc);
        }
    }
    summaries.items.len = retained;
    return summaries;
}

fn parseSessionIndexForWorkspaceFast(
    alloc: Allocator,
    json_text: []const u8,
    workspace_root: []const u8,
) !?std.ArrayList(SessionSummary) {
    const prefix = "{\"schema_version\":3,\"sessions\":[";
    if (!std.mem.startsWith(u8, json_text, prefix) or
        !std.mem.endsWith(u8, json_text, "]}"))
    {
        return null;
    }

    var needle_writer: std.Io.Writer.Allocating = .init(alloc);
    defer needle_writer.deinit();
    try needle_writer.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(
        workspace_root,
        .{},
        &needle_writer.writer,
    );
    const workspace_needle = try needle_writer.toOwnedSlice();
    defer alloc.free(workspace_needle);

    var results: std.ArrayList(SessionSummary) = .empty;
    errdefer freeSummaries(alloc, &results);
    var cursor = prefix.len;
    while (cursor < json_text.len - 2) {
        if (json_text[cursor] != '{') return error.InvalidSessionIndex;
        const entry_start = cursor;
        const entry_end = findIndexedSummaryEnd(
            json_text,
            entry_start,
        ) orelse return error.InvalidSessionIndex;
        const entry = json_text[entry_start..entry_end];
        if (std.mem.find(u8, entry, workspace_needle) != null) {
            try appendWorkspaceSummaryFromSlice(
                alloc,
                &results,
                entry,
                workspace_root,
            );
        }
        cursor = entry_end;
        if (cursor == json_text.len - 2) break;
        if (json_text[cursor] != ',') return error.InvalidSessionIndex;
        cursor += 1;
    }
    if (cursor != json_text.len - 2) return error.InvalidSessionIndex;
    sortSummariesNewestFirst(results.items);
    return results;
}

fn findIndexedSummaryEnd(
    json_text: []const u8,
    entry_start: usize,
) ?usize {
    var cursor = entry_start;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    while (cursor < json_text.len) : (cursor += 1) {
        const byte = json_text[cursor];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return cursor + 1;
            },
            else => {},
        }
    }
    return null;
}

fn appendWorkspaceSummaryFromSlice(
    alloc: Allocator,
    results: *std.ArrayList(SessionSummary),
    entry: []const u8,
    workspace_root: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        entry,
        .{},
    ) catch return error.InvalidSessionIndex;
    defer parsed.deinit();
    var summary = try parseIndexedSummary(alloc, parsed.value);
    errdefer summary.deinit(alloc);
    const indexed_workspace = summary.workspace_root orelse {
        summary.deinit(alloc);
        return;
    };
    if (!std.mem.eql(u8, indexed_workspace, workspace_root)) {
        summary.deinit(alloc);
        return;
    }
    try results.append(alloc, summary);
}

fn parseIndexedSummary(alloc: Allocator, value: std.json.Value) !SessionSummary {
    if (value != .object) return error.InvalidSessionIndex;
    const root = value.object;
    const raw_id = try indexedString(root.get("id"));
    validateSessionId(raw_id) catch return error.InvalidSessionIndex;
    const id = try alloc.dupe(u8, raw_id);
    errdefer alloc.free(id);
    const workspace_root = try indexedOptionalStringDup(alloc, root.get("workspace_root"));
    errdefer if (workspace_root) |wr| alloc.free(wr);
    const origin_workspace_root = try indexedOptionalStringDup(alloc, root.get("origin_workspace_root"));
    errdefer if (origin_workspace_root) |wr| alloc.free(wr);
    const title = try indexedOptionalStringDup(alloc, root.get("title"));
    errdefer if (title) |title_text| alloc.free(title_text);
    const preview = try indexedOptionalStringDup(alloc, root.get("preview"));
    errdefer if (preview) |preview_text| alloc.free(preview_text);
    const language = session.ConversationLanguage.fromSlice(try indexedString(root.get("conversation_language"))) catch return error.InvalidSessionIndex;

    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = (try indexedOptionalBool(root.get("display_metadata_present"))) orelse false,
        .created_at_ms = try indexedI64(root.get("created_at_ms")),
        .updated_at_ms = try indexedI64(root.get("updated_at_ms")),
        .conversation_language = language,
        .history_len = try indexedUsize(root.get("history_len")),
        .has_managed_children = (try indexedOptionalBool(root.get("has_managed_children"))) orelse false,
    };
}

pub const SessionIndexPageOptions = struct {
    workspace_root: ?[]const u8 = null,
    active_id: ?[]const u8 = null,
    continuation: ?ResumableSessionContinuation = null,
    limit: usize,
    resumable_only: bool,
};

const IndexedSummaryView = struct {
    id: JsonStringToken,
    workspace_root: ?JsonStringToken = null,
    origin_workspace_root: ?JsonStringToken = null,
    title: ?JsonStringToken = null,
    preview: ?JsonStringToken = null,
    display_metadata_present: bool = false,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history_len: usize,
    has_managed_children: bool = false,

    fn deinit(self: *IndexedSummaryView, alloc: Allocator) void {
        self.id.deinit(alloc);
        if (self.workspace_root) |value| value.deinit(alloc);
        if (self.origin_workspace_root) |value| value.deinit(alloc);
        if (self.title) |value| value.deinit(alloc);
        if (self.preview) |value| value.deinit(alloc);
        self.* = undefined;
    }

    fn toOwned(self: IndexedSummaryView, alloc: Allocator) !SessionSummary {
        const id = try alloc.dupe(u8, self.id.text);
        errdefer alloc.free(id);
        const workspace_root = if (self.workspace_root) |value|
            try alloc.dupe(u8, value.text)
        else
            null;
        errdefer if (workspace_root) |value| alloc.free(value);
        const origin_workspace_root = if (self.origin_workspace_root) |value|
            try alloc.dupe(u8, value.text)
        else
            null;
        errdefer if (origin_workspace_root) |value| alloc.free(value);
        const title = if (self.title) |value| try alloc.dupe(u8, value.text) else null;
        errdefer if (title) |value| alloc.free(value);
        const preview = if (self.preview) |value| try alloc.dupe(u8, value.text) else null;
        errdefer if (preview) |value| alloc.free(value);
        return .{
            .id = id,
            .workspace_root = workspace_root,
            .origin_workspace_root = origin_workspace_root,
            .title = title,
            .preview = preview,
            .display_metadata_present = self.display_metadata_present,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .conversation_language = self.conversation_language,
            .history_len = self.history_len,
            .has_managed_children = self.has_managed_children,
        };
    }
};

fn parseSessionIndexPage(
    alloc: Allocator,
    json_text: []const u8,
    options: SessionIndexPageOptions,
) !ResumableSessionPage {
    var scanner = std.json.Scanner.initCompleteInput(alloc, json_text);
    defer scanner.deinit();

    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var sessions_seen = false;
    const retained_limit = @max(options.limit, 1) + 1;
    var retained: std.ArrayList(IndexedSummaryView) = .empty;
    defer {
        for (retained.items) |*summary| summary.deinit(alloc);
        retained.deinit(alloc);
    }

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);
                if (std.mem.eql(u8, key.text, "schema_version")) {
                    schema_ok = try readSessionIndexSchemaVersion(&scanner);
                } else if (std.mem.eql(u8, key.text, "sessions")) {
                    if (sessions_seen) return error.InvalidSessionIndex;
                    sessions_seen = true;
                    try parseSessionIndexPageRows(
                        alloc,
                        &scanner,
                        options,
                        retained_limit,
                        &retained,
                    );
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);
    if (!schema_ok or !sessions_seen) return error.InvalidSessionIndex;

    var page: ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    page.has_more = retained.items.len > options.limit;
    const result_len = @min(retained.items.len, options.limit);
    try page.summaries.ensureTotalCapacity(alloc, result_len);
    for (retained.items[0..result_len]) |summary| {
        const owned = try summary.toOwned(alloc);
        page.summaries.appendAssumeCapacity(owned);
    }
    return page;
}

fn parseSessionIndexPageRows(
    alloc: Allocator,
    scanner: *std.json.Scanner,
    options: SessionIndexPageOptions,
    retained_limit: usize,
    retained: *std.ArrayList(IndexedSummaryView),
) !void {
    try expectJsonToken(try scanner.next(), .array_begin);
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .array_end => return,
            .object_begin => {
                var summary = try readIndexedSummaryView(alloc, scanner);
                if (!indexedSummaryMatches(summary, options)) {
                    summary.deinit(alloc);
                    continue;
                }
                var insert_at: usize = 0;
                while (insert_at < retained.items.len and
                    lessIndexedSummaryNewerFirst(retained.items[insert_at], summary))
                {
                    insert_at += 1;
                }
                if (insert_at >= retained_limit) {
                    summary.deinit(alloc);
                    continue;
                }
                try retained.insert(alloc, insert_at, summary);
                if (retained.items.len > retained_limit) {
                    if (retained.pop()) |removed_value| {
                        var removed = removed_value;
                        removed.deinit(alloc);
                    }
                }
            },
            else => return error.InvalidSessionIndex,
        }
    }
}

fn readIndexedSummaryView(
    alloc: Allocator,
    scanner: *std.json.Scanner,
) !IndexedSummaryView {
    var id: ?JsonStringToken = null;
    errdefer if (id) |value| value.deinit(alloc);
    var workspace_root: ?JsonStringToken = null;
    errdefer if (workspace_root) |value| value.deinit(alloc);
    var origin_workspace_root: ?JsonStringToken = null;
    errdefer if (origin_workspace_root) |value| value.deinit(alloc);
    var title: ?JsonStringToken = null;
    errdefer if (title) |value| value.deinit(alloc);
    var preview: ?JsonStringToken = null;
    errdefer if (preview) |value| value.deinit(alloc);
    var display_metadata_present: bool = false;
    var created_at_ms: ?i64 = null;
    var updated_at_ms: ?i64 = null;
    var conversation_language: ?session.ConversationLanguage = null;
    var history_len: ?usize = null;
    var has_managed_children: bool = false;

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);
                if (std.mem.eql(u8, key.text, "id")) {
                    replaceJsonStringToken(alloc, &id, try readJsonString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "workspace_root")) {
                    replaceJsonStringToken(alloc, &workspace_root, try readOptionalJsonString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "origin_workspace_root")) {
                    replaceJsonStringToken(alloc, &origin_workspace_root, try readOptionalJsonString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "title")) {
                    replaceJsonStringToken(alloc, &title, try readOptionalJsonString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "preview")) {
                    replaceJsonStringToken(alloc, &preview, try readOptionalJsonString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "display_metadata_present")) {
                    display_metadata_present = try readJsonBool(scanner);
                } else if (std.mem.eql(u8, key.text, "created_at_ms")) {
                    created_at_ms = try readJsonI64(scanner);
                } else if (std.mem.eql(u8, key.text, "updated_at_ms")) {
                    updated_at_ms = try readJsonI64(scanner);
                } else if (std.mem.eql(u8, key.text, "conversation_language")) {
                    const language = try readJsonString(scanner, alloc);
                    defer language.deinit(alloc);
                    conversation_language = session.ConversationLanguage.fromSlice(language.text) catch
                        return error.InvalidSessionIndex;
                } else if (std.mem.eql(u8, key.text, "history_len")) {
                    history_len = try readJsonUsize(scanner);
                } else if (std.mem.eql(u8, key.text, "has_managed_children")) {
                    has_managed_children = try readJsonBool(scanner);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }

    const parsed_id = id orelse return error.InvalidSessionIndex;
    validateSessionId(parsed_id.text) catch return error.InvalidSessionIndex;
    const parsed_created_at_ms = created_at_ms orelse return error.InvalidSessionIndex;
    const parsed_updated_at_ms = updated_at_ms orelse return error.InvalidSessionIndex;
    const parsed_conversation_language = conversation_language orelse
        return error.InvalidSessionIndex;
    const parsed_history_len = history_len orelse return error.InvalidSessionIndex;
    const result: IndexedSummaryView = .{
        .id = parsed_id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = display_metadata_present,
        .created_at_ms = parsed_created_at_ms,
        .updated_at_ms = parsed_updated_at_ms,
        .conversation_language = parsed_conversation_language,
        .history_len = parsed_history_len,
        .has_managed_children = has_managed_children,
    };
    id = null;
    workspace_root = null;
    origin_workspace_root = null;
    title = null;
    preview = null;
    return result;
}

fn replaceJsonStringToken(
    alloc: Allocator,
    destination: *?JsonStringToken,
    replacement: ?JsonStringToken,
) void {
    if (destination.*) |value| value.deinit(alloc);
    destination.* = replacement;
}

fn readOptionalJsonString(
    scanner: *std.json.Scanner,
    alloc: Allocator,
) !?JsonStringToken {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    return switch (token) {
        .null => null,
        .string, .allocated_string => try jsonStringFromToken(token),
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    };
}

fn readJsonBool(scanner: *std.json.Scanner) !bool {
    return switch (try scanner.next()) {
        .true => true,
        .false => false,
        else => error.InvalidSessionIndex,
    };
}

fn readJsonI64(scanner: *std.json.Scanner) !i64 {
    return switch (try scanner.next()) {
        .number => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionIndex,
        else => error.InvalidSessionIndex,
    };
}

fn readSessionIndexSchemaVersion(scanner: *std.json.Scanner) !bool {
    return switch (try scanner.next()) {
        .number => |raw| std.mem.eql(u8, raw, "3"),
        else => error.InvalidSessionIndex,
    };
}

fn indexedSummaryMatches(
    summary: IndexedSummaryView,
    options: SessionIndexPageOptions,
) bool {
    if (options.workspace_root) |workspace_root| {
        const indexed_workspace = summary.workspace_root orelse return false;
        if (!std.mem.eql(u8, indexed_workspace.text, workspace_root)) return false;
    }
    if (options.resumable_only and
        summary.history_len == 0 and
        !summary.has_managed_children)
    {
        return false;
    }
    if (options.active_id) |active_id| {
        if (std.mem.eql(u8, summary.id.text, active_id)) return false;
    }
    if (options.continuation) |continuation| {
        if (summary.updated_at_ms > continuation.updated_at_ms) return false;
        if (summary.updated_at_ms == continuation.updated_at_ms and
            std.mem.order(u8, summary.id.text, continuation.id) != .lt)
        {
            return false;
        }
    }
    return true;
}

fn lessIndexedSummaryNewerFirst(a: IndexedSummaryView, b: IndexedSummaryView) bool {
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.order(u8, a.id.text, b.id.text) == .gt;
}

fn indexedString(maybe_value: ?std.json.Value) ![]const u8 {
    const value = maybe_value orelse return error.InvalidSessionIndex;
    if (value != .string) return error.InvalidSessionIndex;
    return value.string;
}

fn indexedOptionalStringDup(alloc: Allocator, maybe_value: ?std.json.Value) !?[]u8 {
    const value = maybe_value orelse return null;
    switch (value) {
        .null => return null,
        .string => |text| return try alloc.dupe(u8, text),
        else => return error.InvalidSessionIndex,
    }
}

fn indexedOptionalBool(maybe_value: ?std.json.Value) !?bool {
    const value = maybe_value orelse return null;
    if (value != .bool) return error.InvalidSessionIndex;
    return value.bool;
}

fn indexedI64(maybe_value: ?std.json.Value) !i64 {
    const value = maybe_value orelse return error.InvalidSessionIndex;
    if (value != .integer) return error.InvalidSessionIndex;
    return value.integer;
}

fn indexedUsize(maybe_value: ?std.json.Value) !usize {
    const value = maybe_value orelse return error.InvalidSessionIndex;
    if (value != .integer or value.integer < 0) return error.InvalidSessionIndex;
    return std.math.cast(usize, value.integer) orelse error.InvalidSessionIndex;
}

pub fn readSessionIndex(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
) !std.ArrayList(SessionSummary) {
    if (try deferredCachePresent(sessions)) return error.InvalidSessionIndex;
    return readSessionIndexForRepair(alloc, sessions);
}

pub fn readSessionIndexForRepair(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
) !std.ArrayList(SessionSummary) {
    if (try sessionIndexMarkerPresent(sessions)) return error.InvalidSessionIndex;
    var file = try openVerifiedSessionIndexFile(sessions, session_index_file);
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_session_index_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer alloc.free(bytes);
    return parseSessionIndex(alloc, bytes);
}

pub fn readSessionIndexPage(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    options: SessionIndexPageOptions,
) !ResumableSessionPage {
    if (try deferredCachePresent(sessions)) return error.InvalidSessionIndex;
    if (try sessionIndexMarkerPresent(sessions)) return error.InvalidSessionIndex;
    var file = try openVerifiedSessionIndexFile(sessions, session_index_file);
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_session_index_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer alloc.free(bytes);
    return parseSessionIndexPage(alloc, bytes, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
}

/// Reads workspace candidates from the latest complete index snapshot without
/// materializing unrelated session metadata. This intentionally ignores an
/// in-progress index marker; callers must validate the managed child payload.
pub fn readSessionIndexWorkspaceCandidates(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    workspace_root: []const u8,
) !std.ArrayList(SessionSummary) {
    if (try deferredCachePresent(sessions)) return error.InvalidSessionIndex;
    var file = try openVerifiedSessionIndexFile(sessions, session_index_file);
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(
        alloc,
        &file,
        max_session_index_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionIndex,
    };
    defer alloc.free(bytes);
    return parseSessionIndexForWorkspace(alloc, bytes, workspace_root);
}

/// Streams a fixed window of the frozen ordinary-session candidate snapshot.
/// The returned IDs are candidates only; callers must re-read canonical
/// control records before projecting any edge.
pub fn readRelationshipMigrationCandidatePage(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    continuation: RelationshipMigrationCursor,
) !RelationshipMigrationCandidatePage {
    if (try deferredCachePresent(sessions)) return error.InvalidSessionIndex;
    var file = try openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    );
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > max_session_index_bytes) return error.InvalidSessionIndex;
    const identity = RelationshipMigrationCursor{
        .inode = @intCast(stat.inode),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    };
    const same_identity = continuation.inode == identity.inode and
        continuation.size == identity.size and
        continuation.mtime_ns == identity.mtime_ns and
        continuation.offset <= identity.size;
    const start = if (same_identity) continuation.offset else 0;
    var page = RelationshipMigrationCandidatePage{
        .cursor = identity,
    };
    errdefer page.deinit(alloc);
    if (start == identity.size) {
        page.cursor.offset = start;
        return page;
    }

    var buffer: [relationship_migration_read_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io_mod.getIo(), &buffer, start);
    if (count == 0) return error.InvalidSessionIndex;
    const bytes = buffer[0..count];
    if (start == 0 and
        !hasSupportedMigrationIndexPrefix(bytes))
    {
        return error.InvalidSessionIndex;
    }

    const id_prefix = "\"id\":\"";
    var scan_offset: usize = 0;
    var consumed: usize = 0;
    while (page.ids.items.len < relationship_migration_candidate_limit) {
        const relative = std.mem.find(
            u8,
            bytes[scan_offset..],
            id_prefix,
        ) orelse break;
        const id_start = scan_offset + relative + id_prefix.len;
        const quote = std.mem.findScalar(
            u8,
            bytes[id_start..],
            '"',
        ) orelse break;
        const id_end = id_start + quote;
        const raw_id = bytes[id_start..id_end];
        validateSessionId(raw_id) catch {
            scan_offset = id_end + 1;
            continue;
        };
        try page.ids.append(alloc, try alloc.dupe(u8, raw_id));
        consumed = id_end + 1;
        scan_offset = consumed;
    }

    const read_end = start + count;
    page.cursor.offset = if (page.ids.items.len ==
        relationship_migration_candidate_limit)
        start + consumed
    else if (read_end >= identity.size)
        identity.size
    else if (read_end > relationship_migration_overlap_bytes)
        read_end - relationship_migration_overlap_bytes
    else
        read_end;
    if (page.cursor.offset <= start and read_end > start) {
        page.cursor.offset = read_end;
    }
    page.has_more = page.cursor.offset < identity.size;
    return page;
}

pub fn refreshRelationshipMigrationSnapshot(
    alloc: Allocator,
    sessions: *io_mod.VerifiedDir,
) !void {
    var source = try openVerifiedSessionIndexFile(sessions, session_index_file);
    defer source.close(io_mod.getIo());
    const source_stat = try source.stat(io_mod.getIo());
    const prefix_v2 = "{\"schema_version\":2,\"sessions\":[";
    const prefix_v3 = "{\"schema_version\":3,\"sessions\":[";
    const prefix_len = prefix_v3.len;
    if (source_stat.size > max_session_index_bytes or
        source_stat.size < prefix_len + 2)
    {
        return error.InvalidSessionIndex;
    }
    var observed_prefix: [prefix_len]u8 = undefined;
    if (try source.readPositionalAll(
        io_mod.getIo(),
        &observed_prefix,
        0,
    ) != observed_prefix.len or
        (!std.mem.eql(u8, &observed_prefix, prefix_v2) and
            !std.mem.eql(u8, &observed_prefix, prefix_v3)))
    {
        return error.InvalidSessionIndex;
    }
    var suffix: [2]u8 = undefined;
    if (try source.readPositionalAll(
        io_mod.getIo(),
        &suffix,
        source_stat.size - suffix.len,
    ) != suffix.len or !std.mem.eql(u8, &suffix, "]}")) {
        return error.InvalidSessionIndex;
    }

    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        ".{s}.tmp.{s}",
        .{ relationship_migration_snapshot_file, random_hex },
    );
    defer alloc.free(temp_name);
    var temp_exists = false;
    defer if (temp_exists) {
        sessions.dir.deleteFile(io_mod.getIo(), temp_name) catch {};
    };
    var target = sessions.dir.createFile(io_mod.getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch return error.InvalidSessionIndex;
    temp_exists = true;
    defer target.close(io_mod.getIo());
    target.setPermissions(
        io_mod.getIo(),
        private_file_permissions,
    ) catch return error.InvalidSessionIndex;
    const target_stat = target.stat(io_mod.getIo()) catch
        return error.InvalidSessionIndex;
    if (target_stat.kind != .file or
        target_stat.nlink != 1 or
        target_stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.InvalidSessionIndex;
    }

    var buffer: [relationship_migration_read_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source_stat.size) {
        const remaining = source_stat.size - offset;
        const chunk_len: usize = @intCast(@min(remaining, buffer.len));
        const count = source.readPositionalAll(
            io_mod.getIo(),
            buffer[0..chunk_len],
            offset,
        ) catch return error.InvalidSessionIndex;
        if (count != chunk_len) return error.InvalidSessionIndex;
        target.writeStreamingAll(
            io_mod.getIo(),
            buffer[0..count],
        ) catch return error.InvalidSessionIndex;
        offset += count;
    }
    target.sync(io_mod.getIo()) catch return error.InvalidSessionIndex;
    var existing = openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    ) catch |err| switch (err) {
        error.SessionIndexNotFound => null,
        else => return err,
    };
    if (existing) |*file| file.close(io_mod.getIo());
    sessions.dir.rename(
        temp_name,
        sessions.dir,
        relationship_migration_snapshot_file,
        io_mod.getIo(),
    ) catch return error.InvalidSessionIndex;
    temp_exists = false;
    var published = try openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    );
    published.close(io_mod.getIo());
    try io_mod.syncVerifiedDir(sessions.dir);
}

fn hasSupportedMigrationIndexPrefix(bytes: []const u8) bool {
    return std.mem.startsWith(
        u8,
        bytes,
        "{\"schema_version\":2,\"sessions\":[",
    ) or std.mem.startsWith(
        u8,
        bytes,
        "{\"schema_version\":3,\"sessions\":[",
    );
}

pub fn writeSessionIndex(
    alloc: Allocator,
    sessions: *io_mod.VerifiedDir,
    summaries: []const SessionSummary,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"schema_version\":{d},\"sessions\":[", .{session_index_schema_version});
    for (summaries, 0..) |summary, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeIndexedSummaryJson(&out.writer, summary);
    }
    try out.writer.writeAll("]}");
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    try io_mod.durableReplaceVerified(alloc, sessions, session_index_file, text);
}

pub fn writeSessionIndexMarker(alloc: Allocator, sessions: *io_mod.VerifiedDir) !void {
    try io_mod.durableReplaceVerified(
        alloc,
        sessions,
        session_index_marker_file,
        session_index_marker_contents,
    );
}

pub fn removeSessionIndexMarker(sessions: *io_mod.VerifiedDir) !void {
    var file = openVerifiedSessionIndexFile(sessions, session_index_marker_file) catch |err| switch (err) {
        error.SessionIndexNotFound => return,
        else => return err,
    };
    file.close(io_mod.getIo());
    sessions.dir.deleteFile(io_mod.getIo(), session_index_marker_file) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir, error.SymLinkLoop => return error.InvalidSessionIndex,
        else => return err,
    };
    try io_mod.syncVerifiedDir(sessions.dir);
}

fn openVerifiedSessionIndexFile(
    sessions: *const io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    var file = sessions.dir.openFile(io_mod.getIo(), name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SessionIndexNotFound,
        error.NotDir, error.SymLinkLoop, error.IsDir => return error.InvalidSessionIndex,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) {
        return error.InvalidSessionIndex;
    }
    return file;
}

fn sessionIndexMarkerPresent(sessions: *const io_mod.VerifiedDir) !bool {
    var file = openVerifiedSessionIndexFile(sessions, session_index_marker_file) catch |err| switch (err) {
        error.SessionIndexNotFound => return false,
        else => return err,
    };
    file.close(io_mod.getIo());
    return true;
}

fn writeIndexedSummaryJson(writer: *std.Io.Writer, summary: SessionSummary) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(summary.id, .{}, writer);
    try writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ summary.created_at_ms, summary.updated_at_ms });
    try writer.writeAll(",\"workspace_root\":");
    if (summary.workspace_root) |workspace_root| {
        try std.json.Stringify.value(workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"origin_workspace_root\":");
    if (summary.origin_workspace_root) |origin_workspace_root| {
        try std.json.Stringify.value(origin_workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"conversation_language\":");
    try std.json.Stringify.value(summary.conversation_language.view(), .{}, writer);
    try writer.print(",\"history_len\":{d},\"has_managed_children\":{s},\"display_metadata_present\":{s},\"title\":", .{
        summary.history_len,
        if (summary.has_managed_children) "true" else "false",
        if (summary.display_metadata_present) "true" else "false",
    });
    if (summary.title) |title| {
        try std.json.Stringify.value(title, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"preview\":");
    if (summary.preview) |preview| {
        try std.json.Stringify.value(preview, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

/// Frees every summary and the backing list.
pub fn freeSummaries(alloc: Allocator, sessions: *std.ArrayList(SessionSummary)) void {
    for (sessions.items) |*summary| summary.deinit(alloc);
    sessions.deinit(alloc);
}

pub fn cloneSessionSummary(alloc: Allocator, source: SessionSummary) !SessionSummary {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const workspace_root = if (source.workspace_root) |value| try alloc.dupe(u8, value) else null;
    errdefer if (workspace_root) |value| alloc.free(value);
    const origin_workspace_root = if (source.origin_workspace_root) |value| try alloc.dupe(u8, value) else null;
    errdefer if (origin_workspace_root) |value| alloc.free(value);
    const title = if (source.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const preview = if (source.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = source.display_metadata_present,
        .created_at_ms = source.created_at_ms,
        .updated_at_ms = source.updated_at_ms,
        .conversation_language = source.conversation_language,
        .history_len = source.history_len,
        .has_managed_children = source.has_managed_children,
    };
}

/// Display metadata freezes at first derivation: when the indexed row for
/// the same session already carries a title, the replacement keeps it
/// instead of a value re-derived from possibly compacted history.
pub fn preserveIndexedDisplayMetadata(
    alloc: Allocator,
    index: []const SessionSummary,
    replacement: *SessionSummary,
) !void {
    for (index) |summary| {
        if (!std.mem.eql(u8, summary.id, replacement.id)) continue;
        if (!summary.display_metadata_present) return;
        const frozen_title = summary.title orelse return;
        const title = try alloc.dupe(u8, frozen_title);
        errdefer alloc.free(title);
        const preview = if (summary.preview) |value| try alloc.dupe(u8, value) else null;
        if (replacement.title) |value| alloc.free(value);
        if (replacement.preview) |value| alloc.free(value);
        replacement.title = title;
        replacement.preview = preview;
        replacement.display_metadata_present = true;
        return;
    }
}

pub fn replaceIndexedSummary(
    alloc: Allocator,
    index: *std.ArrayList(SessionSummary),
    replacement: *SessionSummary,
) !void {
    for (index.items) |*summary| {
        if (!std.mem.eql(u8, summary.id, replacement.id)) continue;
        summary.deinit(alloc);
        summary.* = replacement.*;
        replacement.* = undefined;
        sortSummariesNewestFirst(index.items);
        return;
    }
    try index.append(alloc, replacement.*);
    replacement.* = undefined;
    sortSummariesNewestFirst(index.items);
}

pub fn resumablePageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    active_id: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (summary.history_len == 0 and !summary.has_managed_children) continue;
        if (active_id) |id| {
            if (std.mem.eql(u8, summary.id, id)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }

        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn sessionListPageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !types.SessionListPage {
    var page: types.SessionListPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len == limit) {
            page.has_more = true;
            break;
        }

        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

fn summaryFollowsContinuation(
    summary: SessionSummary,
    continuation: ResumableSessionContinuation,
) bool {
    if (summary.updated_at_ms != continuation.updated_at_ms) {
        return summary.updated_at_ms < continuation.updated_at_ms;
    }
    return std.mem.order(u8, summary.id, continuation.id) == .lt;
}

/// Sorts summaries by descending `updated_at_ms`, ties broken by descending id.
pub fn sortSummariesNewestFirst(items: []SessionSummary) void {
    sort_utils.sort(SessionSummary, items, {}, lessSummaryNewerFirst);
}

fn lessSummaryNewerFirst(_: void, a: SessionSummary, b: SessionSummary) bool {
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.order(u8, a.id, b.id) == .gt;
}

fn writeTestFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

test "session list sort is stable and O(n log n)" {
    const alloc = std.testing.allocator;
    var summaries: [500]SessionSummary = undefined;
    for (&summaries, 0..) |*summary, i| {
        summary.* = .{
            .id = try std.fmt.allocPrint(alloc, "session-{d:0>3}", .{i}),
            .created_at_ms = @intCast(i),
            .updated_at_ms = if (i % 2 == 0) 200 else 100,
            .conversation_language = session.ConversationLanguage.default(),
            .history_len = i,
        };
    }
    defer for (&summaries) |*summary| summary.deinit(alloc);

    sortSummariesNewestFirst(&summaries);

    for (summaries[1..], 1..) |summary, i| {
        try std.testing.expect(summaries[i - 1].updated_at_ms >= summary.updated_at_ms);
    }
}

test "session index rejects unsafe ids" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSessionIndex,
        parseSessionIndex(
            alloc,
            "{\"schema_version\":3,\"sessions\":[{\"id\":\"../outside\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":0}]}",
        ),
    );
}

test "session index rejects v2 so resumability metadata is rebuilt" {
    try std.testing.expectError(
        error.InvalidSessionIndex,
        parseSessionIndex(
            std.testing.allocator,
            "{\"schema_version\":2,\"sessions\":[]}",
        ),
    );
}

test "session index parses old rows as metadata missing" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndex(
        alloc,
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"old-session\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":1}]}",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expect(!summaries.items[0].display_metadata_present);
    try std.testing.expect(summaries.items[0].title == null);
    try std.testing.expect(summaries.items[0].preview == null);
    try std.testing.expect(summaries.items[0].origin_workspace_root == null);
}

test "workspace session index materializes only matching canonical rows" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndexForWorkspace(
        alloc,
        "{\"schema_version\":3,\"sessions\":[" ++
            "{\"id\":\"current\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"title\":\"brace } inside string\"}," ++
            "{\"id\":\"other\",\"created_at_ms\":1,\"updated_at_ms\":3,\"workspace_root\":\"/tmp/other\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"title\":\"\\\"workspace_root\\\":\\\"/tmp/ws\\\"\"}" ++
            "]}",
        "/tmp/ws",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings("current", summaries.items[0].id);
}

test "workspace session index preserves noncanonical cache fallback" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndexForWorkspace(
        alloc,
        "{ \"schema_version\": 3, \"sessions\": [{\"id\":\"current\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":0}] }",
        "/tmp/ws",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings("current", summaries.items[0].id);
}

test "session index parses and writes display metadata fields" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndex(
        alloc,
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"new-session\",\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":\"/tmp/origin\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":2,\"display_metadata_present\":true,\"title\":\"First prompt title\",\"preview\":\"First prompt title\\nsecond line\"}]}",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expect(summaries.items[0].display_metadata_present);
    try std.testing.expectEqualStrings("First prompt title", summaries.items[0].title.?);
    try std.testing.expectEqualStrings("First prompt title\nsecond line", summaries.items[0].preview.?);
    try std.testing.expectEqualStrings("/tmp/origin", summaries.items[0].origin_workspace_root.?);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeIndexedSummaryJson(&out.writer, summaries.items[0]);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"display_metadata_present\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"title\":\"First prompt title\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"preview\":\"First prompt title\\nsecond line\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"origin_workspace_root\":\"/tmp/origin\""));
}

test "bounded resumable index page preserves filters and newest-first order" {
    const alloc = std.testing.allocator;
    const index =
        "{\"schema_version\":3,\"sessions\":[" ++
        "{\"id\":\"older\",\"created_at_ms\":1,\"updated_at_ms\":10,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Older\",\"preview\":\"Older\"}," ++
        "{\"id\":\"other-workspace\",\"created_at_ms\":1,\"updated_at_ms\":100,\"workspace_root\":\"/tmp/other\",\"origin_workspace_root\":null,\"conversation_language\":\"ja\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Other\",\"preview\":\"Other\"}," ++
        "{\"id\":\"empty\",\"created_at_ms\":1,\"updated_at_ms\":90,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"display_metadata_present\":true,\"title\":\"Empty\",\"preview\":\"Empty\"}," ++
        "{\"id\":\"newest\",\"created_at_ms\":1,\"updated_at_ms\":40,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"fr\",\"history_len\":2,\"display_metadata_present\":true,\"title\":\"Newest 🚀\",\"preview\":\"مرحبا\"}," ++
        "{\"id\":\"active\",\"created_at_ms\":1,\"updated_at_ms\":80,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Active\",\"preview\":\"Active\"}," ++
        "{\"id\":\"middle-b\",\"created_at_ms\":1,\"updated_at_ms\":30,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Middle B\",\"preview\":\"Middle B\"}," ++
        "{\"id\":\"middle-a\",\"created_at_ms\":1,\"updated_at_ms\":30,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Middle A\",\"preview\":\"Middle A\"}" ++
        "]}";

    var first = try parseSessionIndexPage(alloc, index, .{
        .workspace_root = "/tmp/ws",
        .active_id = "active",
        .limit = 2,
        .resumable_only = true,
    });
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.summaries.items.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqualStrings("newest", first.summaries.items[0].id);
    try std.testing.expectEqualStrings("middle-b", first.summaries.items[1].id);
    try std.testing.expectEqualStrings("Newest 🚀", first.summaries.items[0].title.?);
    try std.testing.expectEqualStrings("مرحبا", first.summaries.items[0].preview.?);

    var second = try parseSessionIndexPage(alloc, index, .{
        .workspace_root = "/tmp/ws",
        .active_id = "active",
        .continuation = .{
            .updated_at_ms = first.summaries.items[1].updated_at_ms,
            .id = first.summaries.items[1].id,
        },
        .limit = 2,
        .resumable_only = true,
    });
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), second.summaries.items.len);
    try std.testing.expect(!second.has_more);
    try std.testing.expectEqualStrings("middle-a", second.summaries.items[0].id);
    try std.testing.expectEqualStrings("older", second.summaries.items[1].id);
}

test "managed child ownership keeps a zero-turn session resumable" {
    const alloc = std.testing.allocator;
    const summaries = [_]SessionSummary{
        .{
            .id = @constCast("ordinary-empty"),
            .workspace_root = @constCast("/tmp/ws"),
            .created_at_ms = 1,
            .updated_at_ms = 3,
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history_len = 0,
        },
        .{
            .id = @constCast("managed-parent"),
            .workspace_root = @constCast("/tmp/ws"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history_len = 0,
            .has_managed_children = true,
        },
    };

    var page = try resumablePageFromSummaries(
        alloc,
        &summaries,
        "/tmp/ws",
        null,
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("managed-parent", page.summaries.items[0].id);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeIndexedSummaryJson(&out.writer, summaries[1]);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        out.written(),
        1,
        "\"has_managed_children\":true",
    ));
}

test "session summary clone owns display metadata strings" {
    const alloc = std.testing.allocator;
    var source = SessionSummary{
        .id = try alloc.dupe(u8, "clone-session"),
        .workspace_root = try alloc.dupe(u8, "/tmp/ws"),
        .origin_workspace_root = try alloc.dupe(u8, "/tmp/origin"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 3,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Clone title"),
        .preview = try alloc.dupe(u8, "Clone preview"),
    };
    defer source.deinit(alloc);

    var cloned = try cloneSessionSummary(alloc, source);
    defer cloned.deinit(alloc);

    try std.testing.expect(cloned.title.?.ptr != source.title.?.ptr);
    try std.testing.expect(cloned.preview.?.ptr != source.preview.?.ptr);
    try std.testing.expectEqualStrings("Clone title", cloned.title.?);
    try std.testing.expectEqualStrings("Clone preview", cloned.preview.?);
}

test "replaced index summary keeps the frozen display metadata" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "frozen-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 3,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Frozen title"),
        .preview = try alloc.dupe(u8, "Frozen preview"),
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "frozen-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Rederived title"),
        .preview = null,
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("Frozen title", replacement.title.?);
    try std.testing.expectEqualStrings("Frozen preview", replacement.preview.?);
    try std.testing.expect(replacement.display_metadata_present);
    try std.testing.expectEqual(@as(i64, 9), replacement.updated_at_ms);
}

test "replaced index summary keeps fresh metadata over a degenerate indexed row" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "degenerate-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = null,
        .preview = try alloc.dupe(u8, "Stale preview"),
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "degenerate-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Fresh title"),
        .preview = try alloc.dupe(u8, "Fresh preview"),
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("Fresh title", replacement.title.?);
    try std.testing.expectEqualStrings("Fresh preview", replacement.preview.?);
}

test "replaced index summary keeps fresh metadata when the indexed row has none" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "bare-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 0,
        .display_metadata_present = false,
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "bare-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "First title"),
        .preview = try alloc.dupe(u8, "First preview"),
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("First title", replacement.title.?);
    try std.testing.expectEqualStrings("First preview", replacement.preview.?);
}

test "workspace summary cache returns first matching latest entry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cache_dir);
    const summary_path = try std.fs.path.join(alloc, &.{ cache_dir, "summary.json" });
    defer alloc.free(summary_path);
    try writeTestFile(
        summary_path,
        "{\"schema_version\":1,\"count\":2,\"latest_id\":\"other\",\"latest_by_workspace\":[{\"workspace_root\":\"/tmp/ws\",\"id\":\"match\"},{\"workspace_root\":\"/tmp/other\",\"id\":\"other\"}]}",
    );

    const latest = try readLatestWorkspaceSessionId(alloc, summary_path, "/tmp/ws") orelse return error.TestExpectedEqual;
    defer alloc.free(latest);
    try std.testing.expectEqualStrings("match", latest);
}

test "state summary fast parser reads generated cache shape" {
    const alloc = std.testing.allocator;
    const summary = try parseSessionStateSummaryFast(
        alloc,
        "{\"schema_version\":1,\"count\":2,\"latest_id\":\"session-2\",\"latest_by_workspace\":[]}",
    ) orelse return error.TestExpectedEqual;
    defer {
        var mutable = summary;
        mutable.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqualStrings("session-2", summary.latest_id.?);
}

test "deferred cache token round trips an exact commit position" {
    const alloc = std.testing.allocator;
    const position = session_replay.CommitPosition{
        .log_generation = [_]u8{0x12} ** 16,
        .through_seq = 42,
        .through_event_id = [_]u8{0xab} ** 16,
        .through_event_log_bytes = 4096,
    };
    const encoded = try encodeDeferredCacheToken(
        alloc,
        "deferred-token-round-trip",
        "/tmp/workspace",
        position,
    );
    defer alloc.free(encoded);

    var decoded = try decodeDeferredCacheToken(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings("deferred-token-round-trip", decoded.session_id);
    try std.testing.expectEqualStrings("/tmp/workspace", decoded.workspace_root);
    try std.testing.expectEqualDeep(position, decoded.position);
}

test "deferred cache token rejects malformed and noncanonical input" {
    const invalid = [_][]const u8{
        "",
        "{}",
        "{\"schema_version\":2,\"session_id\":\"session\",\"workspace_root\":\"/tmp/workspace\",\"position\":{\"log_generation\":\"12121212121212121212121212121212\",\"through_seq\":1,\"through_event_id\":\"abababababababababababababababab\",\"through_event_log_bytes\":1}}",
        "{\"schema_version\":1,\"session_id\":\"../session\",\"workspace_root\":\"/tmp/workspace\",\"position\":{\"log_generation\":\"12121212121212121212121212121212\",\"through_seq\":1,\"through_event_id\":\"abababababababababababababababab\",\"through_event_log_bytes\":1}}",
        "{\"schema_version\":1,\"session_id\":\"session\",\"workspace_root\":\"relative\",\"position\":{\"log_generation\":\"12121212121212121212121212121212\",\"through_seq\":1,\"through_event_id\":\"abababababababababababababababab\",\"through_event_log_bytes\":1}}",
        "{\"schema_version\":1,\"session_id\":\"session\",\"workspace_root\":\"/tmp/workspace\",\"position\":{\"log_generation\":\"1212121212121212121212121212121A\",\"through_seq\":1,\"through_event_id\":\"abababababababababababababababab\",\"through_event_log_bytes\":1}}",
    };
    for (invalid) |bytes| {
        try std.testing.expectError(
            error.InvalidSessionIndex,
            decodeDeferredCacheToken(std.testing.allocator, bytes),
        );
    }

    var oversized: [max_deferred_cache_token_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(
        error.InvalidSessionIndex,
        decodeDeferredCacheToken(std.testing.allocator, &oversized),
    );
}

test "deferred cache token reader rejects non-private files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        std.testing.io,
        "sessions",
        private_dir_permissions,
    );
    var sessions_dir = try tmp.dir.openDir(std.testing.io, "sessions", .{
        .iterate = true,
    });
    defer sessions_dir.close(std.testing.io);
    var sessions = io_mod.VerifiedDir{ .dir = sessions_dir };
    var latest = try io_mod.openOrCreateVerifiedPrivateDir(&sessions, "latest");
    defer latest.close();
    var deferred = try io_mod.openOrCreateVerifiedPrivateDir(
        &latest,
        deferred_cache_dir,
    );
    defer deferred.close();
    const encoded = try encodeDeferredCacheToken(
        alloc,
        "non-private-token",
        "/tmp/workspace",
        .{
            .log_generation = [_]u8{0x12} ** 16,
            .through_seq = 1,
            .through_event_id = [_]u8{0xab} ** 16,
            .through_event_log_bytes = 100,
        },
    );
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerified(
        alloc,
        &deferred,
        "non-private-token",
        encoded,
    );
    var file = try deferred.dir.openFile(std.testing.io, "non-private-token", .{
        .mode = .read_write,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    try file.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o644),
    );
    file.close(std.testing.io);

    try std.testing.expect(try deferredCachePresent(&sessions));
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readDeferredCacheTokens(alloc, &sessions),
    );
}

test "deferred cache token parser handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzDeferredCacheToken, .{
        .corpus = &.{
            "",
            "{}",
            "{\"schema_version\":1}",
        },
    });
}

fn fuzzDeferredCacheToken(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_deferred_cache_token_bytes + 1]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var decoded = decodeDeferredCacheToken(
        std.testing.allocator,
        buffer[0..len],
    ) catch return;
    decoded.deinit(std.testing.allocator);
}
