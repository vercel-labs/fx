const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
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

const OpenedSessionFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

const LegacyFingerprint = struct {
    schema: session_json.LegacySchemaVersion,
    primary_bytes: u64,
    primary_sha256: session_projection.Digest,
};

const AuthorityTransitionKind = enum {
    session_create,
    legacy_to_v3,
};

pub const AuthorityTransition = struct {
    session_id: []u8,
    kind: AuthorityTransitionKind,
    authority_id: session_event.Identifier,
    prior: ?LegacyFingerprint,
    proposed: session_log.CommitPosition,

    pub fn deinit(self: *AuthorityTransition, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

/// Shared front half of the two `classifyAuthority*` entry points: rejects a
/// pending authority fence, then returns `.schema_v3` when a valid marker is
/// present, or `null` when none is (caller decides legacy vs. orphan).
/// Returns `error.InvalidSessionFormat` if the marker names a different session.
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
    var opened = openSessionFileWithStat(session_dir, "session.json", .read_only) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer opened.file.close(io_mod.getIo());
    if (opened.stat.size > session_projection.manifest_max_bytes) {
        return false;
    }

    const manifest_bytes = readExactLegacyFile(
        alloc,
        &opened.file,
        opened.stat.size,
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
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    const transition = try loadAuthorityTransitionOptional(
        alloc,
        session_dir,
    ) orelse return;
    var owned = transition;
    defer owned.deinit(alloc);
    if (!std.mem.eql(u8, owned.session_id, session_id)) {
        return error.InvalidSessionFormat;
    }
    return error.SessionAuthorityBoundaryUnavailable;
}

/// Reads and exact-parses `authority.pending.json` if present, returning null
/// when absent. Caller owns the returned transition.
pub fn loadAuthorityTransitionOptional(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
) !?AuthorityTransition {
    const bytes = try readOptionalSessionFile(
        alloc,
        session_dir,
        "authority.pending.json",
        32 * 1024,
    ) orelse return null;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const expected_keys = [_][]const u8{
        "schema_version",
        "session_id",
        "operation_id",
        "kind",
        "authority_id",
        "prior",
        "proposed",
    };
    const object = try exactJsonObject(parsed.value, &expected_keys);
    if (try jsonU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(u8, try objectString(object, "session_id"));
    errdefer alloc.free(session_id);
    try validateSessionId(session_id);
    _ = try parseIdentifier(try objectString(object, "operation_id"));
    const kind = std.meta.stringToEnum(
        AuthorityTransitionKind,
        try objectString(object, "kind"),
    ) orelse return error.InvalidSessionFormat;
    const authority_id = try parseIdentifier(
        try objectString(object, "authority_id"),
    );
    const prior_value = object.get("prior") orelse
        return error.InvalidSessionFormat;
    const prior: ?LegacyFingerprint = switch (kind) {
        .session_create => blk: {
            if (prior_value != .null) return error.InvalidSessionFormat;
            break :blk null;
        },
        .legacy_to_v3 => try parseLegacyFingerprint(prior_value),
    };
    return .{
        .session_id = session_id,
        .kind = kind,
        .authority_id = authority_id,
        .prior = prior,
        .proposed = try parseProposedPosition(
            object.get("proposed") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn parseLegacyFingerprint(value: std.json.Value) error{InvalidSessionFormat}!LegacyFingerprint {
    const expected_keys = [_][]const u8{
        "storage_format",
        "primary_bytes",
        "primary_sha256",
    };
    const object = try exactJsonObject(value, &expected_keys);
    const storage = try objectString(object, "storage_format");
    const schema: session_json.LegacySchemaVersion =
        if (std.mem.eql(u8, storage, "legacy_snapshot_v1"))
            .v1
        else if (std.mem.eql(u8, storage, "legacy_snapshot_v2"))
            .v2
        else
            return error.InvalidSessionFormat;
    return .{
        .schema = schema,
        .primary_bytes = try jsonU64(object, "primary_bytes"),
        .primary_sha256 = try parseDigest(
            try objectString(object, "primary_sha256"),
        ),
    };
}

fn parseProposedPosition(value: std.json.Value) error{InvalidSessionFormat}!session_log.CommitPosition {
    const expected_keys = [_][]const u8{
        "storage_format",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    };
    const object = try exactJsonObject(value, &expected_keys);
    if (!std.mem.eql(
        u8,
        try objectString(object, "storage_format"),
        "event_log_v1",
    )) {
        return error.InvalidSessionFormat;
    }
    return .{
        .log_generation = try parseIdentifier(
            try objectString(object, "log_generation"),
        ),
        .through_seq = try jsonU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(
            try objectString(object, "through_event_id"),
        ),
        .through_event_log_bytes = try jsonU64(
            object,
            "through_event_log_bytes",
        ),
    };
}

/// Returns the object only if it has exactly `expected_keys` and no others,
/// rejecting unknown/missing keys with `error.InvalidSessionFormat`.
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

fn parseDigest(raw: []const u8) error{InvalidSessionFormat}!session_projection.Digest {
    if (raw.len != @sizeOf(session_projection.Digest) * 2) {
        return error.InvalidSessionFormat;
    }
    var result: session_projection.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch
        return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) {
        return error.InvalidSessionFormat;
    }
    return result;
}

fn legacyFingerprintMatches(
    alloc: Allocator,
    bytes: []const u8,
    expected: LegacyFingerprint,
) !bool {
    if (bytes.len != expected.primary_bytes) return false;
    const schema = session_json.parseLegacySchemaVersion(
        alloc,
        bytes,
    ) catch return false;
    if (schema != expected.schema) return false;
    const digest = session_projection.sha256(bytes);
    return std.mem.eql(u8, &digest, &expected.primary_sha256);
}

/// Asserts a parsed transition names `session_id`; otherwise `error.InvalidSessionFormat`.
pub fn requireAuthorityTransitionSession(
    transition: AuthorityTransition,
    session_id: []const u8,
) !void {
    if (!std.mem.eql(u8, transition.session_id, session_id)) {
        return error.InvalidSessionFormat;
    }
}

fn legacyPrimaryBytes(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
    expected: LegacyFingerprint,
) !?[]u8 {
    const max_bytes = std.math.cast(
        usize,
        std.math.add(u64, expected.primary_bytes, 1) catch
            return error.LegacySessionMigrationResourceExhausted,
    ) orelse return error.LegacySessionMigrationResourceExhausted;
    const bytes = try readOptionalSessionFile(
        alloc,
        session_dir,
        name,
        max_bytes,
    ) orelse return null;
    errdefer alloc.free(bytes);
    if (!try legacyFingerprintMatches(alloc, bytes, expected)) {
        alloc.free(bytes);
        return null;
    }
    return bytes;
}

fn removeSessionEntryIfPresent(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    session_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

/// Rolls an interrupted migration back to its legacy snapshot: restores the
/// fingerprint-matched primary from the stable copy, removes the v3 marker, and
/// clears the intent. Inconsistent on-disk state yields
/// `error.LegacySessionMigrationIndeterminate`.
pub fn restoreLegacyAuthority(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    transition: AuthorityTransition,
) !void {
    const prior = transition.prior orelse return error.InvalidSessionFormat;
    const current = try legacyPrimaryBytes(
        alloc,
        &writable.dir,
        "session.json",
        prior,
    );
    if (current) |bytes| {
        alloc.free(bytes);
    } else {
        const stable = try legacyPrimaryBytes(
            alloc,
            &writable.dir,
            "session.legacy.json",
            prior,
        ) orelse return error.LegacySessionMigrationIndeterminate;
        defer alloc.free(stable);
        io_mod.durableReplaceVerified(
            alloc,
            &writable.dir,
            "session.json",
            stable,
        ) catch return error.LegacySessionMigrationIndeterminate;
    }
    removeSessionEntryIfPresent(&writable.dir, "authority.json") catch
        return error.LegacySessionMigrationIndeterminate;
    io_mod.syncVerifiedDir(writable.dir.dir) catch
        return error.LegacySessionMigrationIndeterminate;
    const confirmed = try legacyPrimaryBytes(
        alloc,
        &writable.dir,
        "session.json",
        prior,
    ) orelse return error.LegacySessionMigrationIndeterminate;
    alloc.free(confirmed);
    if (try entryExistsRelative(&writable.dir, "authority.json")) {
        return error.LegacySessionMigrationIndeterminate;
    }
    deleteSessionEntry(&writable.dir, "authority.pending.json") catch
        return error.SessionAuthorityIntentCleanupPending;
}

/// Reads an in-session file fully, capped at `max_bytes`. Returns null if the
/// file is absent; read/parse failures collapse to `error.InvalidSessionFormat`
/// (except `OutOfMemory`). Caller owns the returned bytes.
pub fn readOptionalSessionFile(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
) !?[]u8 {
    var opened = openSessionFileWithStat(session_dir, name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer opened.file.close(io_mod.getIo());
    return io_mod.readFileToEndSized(alloc, &opened.file, opened.stat.size, max_bytes) catch |err| switch (err) {
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
    const opened = try openSessionFileWithStat(session_dir, name, mode);
    return opened.file;
}

fn openSessionFileWithStat(
    session_dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: session_log.OpenMode,
) !OpenedSessionFile {
    const file = session_dir.dir.openFile(io_mod.getIo(), name, .{
        .mode = if (mode == .writable) .read_write else .read_only,
        // The stat below rejects directories and other non-files.
        .allow_directory = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    try verifyOpenedSessionFile(stat, mode);
    return .{ .file = file, .stat = stat };
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

/// Structural equality of two commit positions.
pub fn positionsEqual(
    left: session_log.CommitPosition,
    right: session_log.CommitPosition,
) bool {
    return std.mem.eql(u8, &left.log_generation, &right.log_generation) and
        left.through_seq == right.through_seq and
        std.mem.eql(u8, &left.through_event_id, &right.through_event_id) and
        left.through_event_log_bytes == right.through_event_log_bytes;
}

/// Structural equality of two parsed transitions, including the optional prior
/// legacy fingerprint.
pub fn authorityTransitionsEqual(
    left: AuthorityTransition,
    right: AuthorityTransition,
) bool {
    if (!std.mem.eql(u8, left.session_id, right.session_id) or
        left.kind != right.kind or
        !std.mem.eql(u8, &left.authority_id, &right.authority_id) or
        !positionsEqual(left.proposed, right.proposed) or
        (left.prior == null) != (right.prior == null))
    {
        return false;
    }
    if (left.prior) |left_prior| {
        const right_prior = right.prior.?;
        return left_prior.schema == right_prior.schema and
            left_prior.primary_bytes == right_prior.primary_bytes and
            std.mem.eql(
                u8,
                &left_prior.primary_sha256,
                &right_prior.primary_sha256,
            );
    }
    return true;
}

/// Deletes an in-session file and fsyncs the directory so the removal is durable.
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
    return io_mod.readFileToEndSized(alloc, file, size, max_bytes);
}

/// Normalizes a canonical-replay `OutOfMemory` into
/// `error.SessionReplayResourceExhausted`; passes every other error through.
pub fn mapReplayError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.SessionReplayResourceExhausted,
        else => err,
    };
}
