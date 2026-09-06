const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const session_event = @import("session_event.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const Allocator = std.mem.Allocator;

const paths = @import("session_store_paths.zig");

const validateSessionId = paths.validateSessionId;

const AuthorityClassification = enum {
    schema_v3,
    legacy,
};

const AuthoritySource = enum {
    native_create,
    legacy_migration,
};

const AuthorityMarker = struct {
    session_id: []u8,
    authority_id: session_event.Identifier,
    source: AuthoritySource,

    pub fn deinit(self: *AuthorityMarker, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

fn classifyMarker(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !?AuthorityClassification {
    try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
    const marker = try loadAuthorityMarkerOptional(alloc, session_dir);
    if (marker) |marker_value| {
        var owned = marker_value;
        defer owned.deinit(alloc);
        if (!std.mem.eql(u8, owned.session_id, session_id)) {
            return error.InvalidSessionFormat;
        }
        return .schema_v3;
    }
    return null;
}

/// Classifies a session as schema-v3 or legacy. A directory with no marker but
/// a complete prepared schema-v3 manifest is a creation orphan and reported as
/// `error.SessionNotFound` (it must not be read as legacy).
pub fn classifyAuthority(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !AuthorityClassification {
    if (try classifyMarker(alloc, session_dir, session_id)) |classification| {
        return classification;
    }
    if (try isPreparedCreationOrphan(alloc, session_dir, session_id)) {
        return error.SessionNotFound;
    }
    return .legacy;
}

/// Like `classifyAuthority` but treats a marker-less directory as legacy without
/// the creation-orphan check, so an oversized legacy snapshot can still be
/// migrated under an explicit `allow_large` request.
pub fn classifyAuthorityAllowingLargeLegacy(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !AuthorityClassification {
    if (try classifyMarker(alloc, session_dir, session_id)) |classification| {
        return classification;
    }
    return .legacy;
}

fn isPreparedCreationOrphan(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !bool {
    var file = openSessionFile(session_dir, "session.json", .read_only) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > session_projection.manifest_max_bytes) {
        return false;
    }

    const manifest_bytes = readExactLegacyFile(
        alloc,
        &file,
        stat.size,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer alloc.free(manifest_bytes);
    const schema_version = manifestSchemaVersion(alloc, manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (schema_version != 3) return false;

    var manifest = session_projection.decodeManifest(
        alloc,
        manifest_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id)) {
        return error.InvalidSessionFormat;
    }
    return true;
}

/// Reads and validates `authority.json` if present. Returns null when absent;
/// `error.InvalidSessionFormat` on a malformed or wrong-schema marker. Caller
/// owns the returned marker.
pub fn loadAuthorityMarkerOptional(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
) !?AuthorityMarker {
    const bytes = try readOptionalSessionFile(
        alloc,
        session_dir,
        "authority.json",
        16 * 1024,
    ) orelse return null;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionFormat;
    const object = parsed.value.object;
    if (try jsonU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try objectString(object, "storage_format"), "event_log_v1"))
    {
        return error.InvalidSessionFormat;
    }
    const source = std.meta.stringToEnum(
        AuthoritySource,
        try objectString(object, "source"),
    ) orelse return error.InvalidSessionFormat;
    const session_id = try alloc.dupe(u8, try objectString(object, "session_id"));
    errdefer alloc.free(session_id);
    try validateSessionId(session_id);
    return .{
        .session_id = session_id,
        .authority_id = try parseIdentifier(try objectString(object, "authority_id")),
        .source = source,
    };
}

/// Fails with `error.SessionAuthorityBoundaryUnavailable` if an in-flight
/// `authority.pending.json` transition exists for this session (the "fence"),
/// so read paths refuse a directory mid-migration.
pub fn requireAuthorityFenceAbsent(
    _: Allocator,
    session_dir: *io_mod.VerifiedDir,
    _: []const u8,
) !void {
    if (try entryExistsRelative(session_dir, "authority.pending.json")) {
        return error.SessionAuthorityBoundaryUnavailable;
    }
}

/// Reads and exact-parses `authority.pending.json` if present, returning null
/// when absent. Caller owns the returned transition.
pub fn exactJsonObject(
    value: std.json.Value,
    expected_keys: []const []const u8,
) !std.json.ObjectMap {
    if (value != .object or value.object.count() != expected_keys.len) {
        return error.InvalidSessionFormat;
    }
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        var found = false;
        for (expected_keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidSessionFormat;
    }
    return value.object;
}

pub fn readOptionalSessionFile(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
) !?[]u8 {
    var file = openSessionFile(session_dir, name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
}

/// Opens an in-session file with symlink/escape protections, rejecting
/// non-regular or hard-linked targets as `error.SessionPathUnsafe`.
pub fn openSessionFile(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: session_log.OpenMode,
) !std.Io.File {
    const file = session_dir.dir.openFile(io_mod.getIo(), name, .{
        .mode = if (mode == .writable) .read_write else .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyOpenedSessionFile(try file.stat(io_mod.getIo()), mode);
    return file;
}

fn verifyOpenedSessionFile(
    stat: std.Io.File.Stat,
    mode: session_log.OpenMode,
) !void {
    if (stat.kind != .file or stat.nlink > 1) {
        return error.SessionPathUnsafe;
    }
    // Atomic replacement can unlink the old inode after a read-only open but
    // before fstat. The descriptor remains a safe, immutable snapshot.
    if (mode == .writable and stat.nlink != 1) {
        return error.SessionPathUnsafe;
    }
}

test "read-only session files accept an atomically unlinked descriptor" {
    var stat = std.mem.zeroes(std.Io.File.Stat);
    stat.kind = .file;
    stat.nlink = 0;
    try verifyOpenedSessionFile(stat, .read_only);
    try std.testing.expectError(
        error.SessionPathUnsafe,
        verifyOpenedSessionFile(stat, .writable),
    );

    stat.nlink = 2;
    try std.testing.expectError(
        error.SessionPathUnsafe,
        verifyOpenedSessionFile(stat, .read_only),
    );
}

/// Reports whether `name` exists directly under the session dir, mapping
/// unsafe link/dir shapes to `error.SessionPathUnsafe`.
pub fn entryExistsRelative(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
) !bool {
    _ = session_dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.SymLinkLoop, error.NotDir => return error.SessionPathUnsafe,
        else => return err,
    };
    return true;
}

/// Resolves the containing device id for `name`, which the projection layer
/// folds into its stat fingerprint. The OS-specific syscall path (Linux
/// `statx`, Apple `fstatat`, 0 elsewhere) is isolated here so `eventFileStat`
/// stays platform-agnostic. Syscall failures map to `error.InvalidSessionFormat`.
fn statFileDevice(session_dir: *io_mod.VerifiedDir, name: []const u8) !u64 {
    var path_buffer: [std.c.PATH_MAX]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{name}) catch
        return error.InvalidSessionFormat;
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var statx = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    session_dir.dir.handle,
                    path_z,
                    linux.AT.SYMLINK_NOFOLLOW,
                    linux.STATX.BASIC_STATS,
                    &statx,
                ))) {
                    .SUCCESS => {
                        const major: u64 = statx.dev_major;
                        const minor: u64 = statx.dev_minor;
                        break :blk (minor & 0xff) |
                            ((major & 0xfff) << 8) |
                            ((minor & ~@as(u64, 0xff)) << 12) |
                            ((major & ~@as(u64, 0xfff)) << 32);
                    },
                    .INTR => continue,
                    else => return error.InvalidSessionFormat,
                }
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => blk: {
            var native_stat = std.mem.zeroes(std.c.Stat);
            while (true) {
                switch (std.c.errno(std.c.fstatat(
                    session_dir.dir.handle,
                    path_z,
                    &native_stat,
                    std.c.AT.SYMLINK_NOFOLLOW,
                ))) {
                    .SUCCESS => break :blk @intCast(native_stat.dev),
                    .INTR => continue,
                    else => return error.InvalidSessionFormat,
                }
            }
        },
        else => 0,
    };
}

/// Stats a session's event log into the `EventFileStat` fingerprint the
/// projection layer compares against. Rejects non-regular or hard-linked files
/// as `error.SessionPathUnsafe`; a missing log is `error.InvalidSessionFormat`.
pub fn eventFileStat(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
) !session_projection.EventFileStat {
    const stat = session_dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidSessionFormat,
        error.SymLinkLoop, error.NotDir => return error.SessionPathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    const device = try statFileDevice(session_dir, name);
    return .{
        .device = device,
        .inode = @intCast(stat.inode),
        .kind = .regular,
        .mode = stat.permissions.toMode(),
        .link_count = @intCast(stat.nlink),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

/// Parses the top-level `schema_version` from manifest/snapshot bytes.
/// Any parse problem is `error.InvalidSessionFormat`.
pub fn manifestSchemaVersion(alloc: Allocator, bytes: []const u8) !u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionFormat;
    return jsonU64(parsed.value.object, "schema_version");
}

pub fn objectString(object: std.json.ObjectMap, key: []const u8) error{InvalidSessionFormat}![]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .string) return error.InvalidSessionFormat;
    return value.string;
}

pub fn jsonU64(object: std.json.ObjectMap, key: []const u8) error{InvalidSessionFormat}!u64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    return switch (value) {
        .integer => |number| if (number >= 0)
            @intCast(number)
        else
            error.InvalidSessionFormat,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidSessionFormat,
        else => error.InvalidSessionFormat,
    };
}

/// Parses a 32-hex-char canonical identifier, rejecting non-canonical forms.
pub fn parseIdentifier(raw: []const u8) error{InvalidSessionFormat}!session_event.Identifier {
    if (raw.len != 32) return error.InvalidSessionFormat;
    var result: session_event.Identifier = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionFormat;
    return result;
}

/// Deletes one obsolete legacy-session file and syncs the directory.
pub fn deleteSessionEntry(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    try session_dir.dir.deleteFile(io_mod.getIo(), name);
    try io_mod.syncVerifiedDir(session_dir.dir);
}

/// Reads exactly `size` bytes (+1 guard) of a legacy file into an owned slice.
pub fn readExactLegacyFile(
    alloc: Allocator,
    file: *std.Io.File,
    size: u64,
) ![]u8 {
    const limit = std.math.add(u64, size, 1) catch return error.OutOfMemory;
    const max_bytes = std.math.cast(usize, limit) orelse return error.OutOfMemory;
    return io_mod.readFileToEnd(alloc, file, max_bytes);
}
