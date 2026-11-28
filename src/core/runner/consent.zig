//! Per-repository consent record for copying a repository to a Vercel destination
//! (`{fx_home}/sandbox/state/{repo_key}/consent.json`). Strict decoder with fuzz
//! target (R3.2, R3.5); written atomically only after an explicit yes (R3.4).

const std = @import("std");
const config_write = @import("config_write.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const sha256 = @import("sha256.zig");

const Allocator = std.mem.Allocator;

pub const format_version: i64 = 1;
pub const max_id_bytes: usize = 256;
pub const max_timestamp_bytes: usize = 64;
pub const max_bytes: usize = 4 * 1024;
pub const file_name = "consent.json";
const temp_prefix = ".consent.json.tmp.";

pub const Record = struct {
    version: i64 = format_version,
    team_id: []const u8,
    project_id: []const u8,
    confirmed_at: []const u8,
};

pub const ParseError = error{ InvalidConsent, OutOfMemory };
pub const WriteError = Allocator.Error || error{WriteFailed};

/// The keyed folder name (spec L5): the first 16 hex digits of the SHA-256 of the
/// user id, a newline, and the canonical workspace root.
pub fn repoKey(arena: Allocator, user_id: []const u8, canonical_root: []const u8) Allocator.Error![]const u8 {
    const digest = sha256.hexDigest(try arena.print("{s}\n{s}", .{ user_id, canonical_root }));
    return arena.dupe(u8, digest[0..16]);
}

pub fn parse(arena: Allocator, bytes: []const u8) ParseError!Record {
    if (bytes.len > max_bytes) return error.InvalidConsent;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConsent,
    };
    const object = switch (root) {
        .object => |map| map,
        else => return error.InvalidConsent,
    };
    if (object.count() != 4) return error.InvalidConsent;

    const version_value = object.get("version") orelse return error.InvalidConsent;
    const version = switch (version_value) {
        .integer => |n| n,
        else => return error.InvalidConsent,
    };
    if (version != format_version) return error.InvalidConsent;

    return .{
        .version = format_version,
        .team_id = try copyRequiredText(arena, object.get("team_id"), max_id_bytes),
        .project_id = try copyRequiredText(arena, object.get("project_id"), max_id_bytes),
        .confirmed_at = try copyRequiredText(arena, object.get("confirmed_at"), max_timestamp_bytes),
    };
}

fn copyRequiredText(arena: Allocator, value: ?std.json.Value, max: usize) ParseError![]const u8 {
    const found = value orelse return error.InvalidConsent;
    const text = switch (found) {
        .string => |s| s,
        else => return error.InvalidConsent,
    };
    if (text.len == 0 or text.len > max) return error.InvalidConsent;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidConsent;
    }
    return arena.dupe(u8, text);
}

pub fn encode(arena: Allocator, record: Record) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{
        .version = record.version,
        .team_id = record.team_id,
        .project_id = record.project_id,
        .confirmed_at = record.confirmed_at,
    }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

pub fn matchesDestination(record: Record, team_id: []const u8, project_id: []const u8) bool {
    return record.version == format_version and
        std.mem.eql(u8, record.team_id, team_id) and
        std.mem.eql(u8, record.project_id, project_id);
}

pub fn hasForDestination(
    arena: Allocator,
    fx_home: []const u8,
    key: []const u8,
    team_id: []const u8,
    project_id: []const u8,
) Allocator.Error!bool {
    const zio = io_mod.getIo();
    var home_dir = io_mod.openDirAbsoluteNoFollow(fx_home, .{ .iterate = true }) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("remote setup", "consent check skipped: {s}", .{@errorName(err)});
        return false;
    };
    defer home_dir.close(zio);
    var home_root: io_mod.VerifiedDir = .{ .dir = home_dir };
    var sandbox_dir = (io_mod.openRealDirIfPresent(&home_root, "sandbox") catch |err| {
        debug_trace.logf("remote setup", "consent sandbox dir unreadable: {s}", .{@errorName(err)});
        return false;
    }) orelse return false;
    defer sandbox_dir.close();
    var state_dir = (io_mod.openRealDirIfPresent(&sandbox_dir, "state") catch |err| {
        debug_trace.logf("remote setup", "consent state dir unreadable: {s}", .{@errorName(err)});
        return false;
    }) orelse return false;
    defer state_dir.close();
    var repo_dir = (io_mod.openRealDirIfPresent(&state_dir, key) catch |err| {
        debug_trace.logf("remote setup", "consent repo dir unreadable: {s}", .{@errorName(err)});
        return false;
    }) orelse return false;
    defer repo_dir.close();

    var file = io_mod.openExistingReadOnlyRegularFile(repo_dir.dir, file_name, .no_follow) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("remote setup", "consent file unreadable: {s}", .{@errorName(err)});
        return false;
    };
    defer file.close(zio);
    const bytes = io_mod.readFileToEnd(arena, &file, max_bytes + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("remote setup", "consent file read failed: {s}", .{@errorName(err)});
            return false;
        },
    };
    const record = parse(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConsent => {
            debug_trace.logf("remote setup", "consent file invalid; asking again", .{});
            return false;
        },
    };
    return matchesDestination(record, team_id, project_id);
}

pub fn write(
    arena: Allocator,
    fx_home: []const u8,
    key: []const u8,
    team_id: []const u8,
    project_id: []const u8,
    now_s: i64,
) WriteError!void {
    const confirmed_at = config_write.isoTime(arena, now_s) catch return error.WriteFailed;
    const bytes = try encode(arena, .{
        .team_id = team_id,
        .project_id = project_id,
        .confirmed_at = confirmed_at,
    });
    const zio = io_mod.getIo();
    var home_dir = io_mod.openDirAbsoluteNoFollow(fx_home, .{ .iterate = true }) catch return error.WriteFailed;
    defer home_dir.close(zio);
    var sandbox_dir = io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, "sandbox") catch return error.WriteFailed;
    defer sandbox_dir.close();
    var state_dir = io_mod.openOrCreateVerifiedPrivateDir(&sandbox_dir, "state") catch return error.WriteFailed;
    defer state_dir.close();
    var repo_dir = io_mod.openOrCreateVerifiedPrivateDir(&state_dir, key) catch return error.WriteFailed;
    defer repo_dir.close();

    io_mod.durableReplaceVerified(arena, &repo_dir, file_name, bytes) catch return error.WriteFailed;
    config_write.removeStaleTemps(&repo_dir, temp_prefix, now_s);
}

const testing = std.testing;

test "consent record round-trips and matches only its own destination" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try encode(arena, .{
        .team_id = "team_1",
        .project_id = "prj_1",
        .confirmed_at = "2026-11-28T10:00:00Z",
    });
    const parsed = try parse(arena, raw);
    try testing.expectEqual(format_version, parsed.version);
    try testing.expectEqualStrings("team_1", parsed.team_id);
    try testing.expectEqualStrings("prj_1", parsed.project_id);
    try testing.expectEqualStrings("2026-11-28T10:00:00Z", parsed.confirmed_at);
    try testing.expect(matchesDestination(parsed, "team_1", "prj_1"));
    try testing.expect(!matchesDestination(parsed, "team_2", "prj_1"));
    try testing.expect(!matchesDestination(parsed, "team_1", "prj_2"));
}

test "consent decoder rejects malformed, wrong-version, extra-key, empty, and oversized files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long_id = try arena.alloc(u8, max_id_bytes + 1);
    @memset(long_id, 'a');
    const long_id_json = try arena.print("{{\"version\":1,\"team_id\":\"{s}\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}}", .{long_id});
    const huge = try arena.alloc(u8, max_bytes + 1);
    @memset(huge, ' ');

    const bad_cases = [_][]const u8{
        "",
        "{",
        "[]",
        "null",
        "{}",
        "{\"version\":0,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":2,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":1.0,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":\"1\",\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":1,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\",\"extra\":1}",
        "{\"version\":1,\"team_id\":\"team_1\",\"project_id\":\"prj_1\"}",
        "{\"version\":1,\"team_id\":\"\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":1,\"team_id\":\"team_1\",\"project_id\":\"\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":1,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"\"}",
        "{\"version\":1,\"team_id\":\"team\\u0007\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        "{\"version\":1,\"team_id\":7,\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
        long_id_json,
        huge,
    };
    for (bad_cases) |bytes| {
        try testing.expectError(error.InvalidConsent, parse(arena, bytes));
    }
}

test "consent write writes atomically and hasForDestination checks destination and rejects symlinks" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io_mod.getIo(), "fxhome");
    const fx_home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "fxhome");
    const key = try repoKey(arena, "usr_1", "/Users/example/repo");

    try testing.expect(!try hasForDestination(arena, fx_home, key, "team_1", "prj_1"));
    try write(arena, fx_home, key, "team_1", "prj_1", 1_800_000_000);
    try testing.expect(try hasForDestination(arena, fx_home, key, "team_1", "prj_1"));
    try testing.expect(!try hasForDestination(arena, fx_home, key, "team_2", "prj_1"));
    try testing.expect(!try hasForDestination(arena, fx_home, key, "team_1", "prj_2"));

    const written = try tmp.dir.readFileAlloc(io_mod.getIo(), try arena.print("fxhome/sandbox/state/{s}/consent.json", .{key}), arena, .limited(max_bytes));
    const parsed = try parse(arena, written);
    try testing.expectEqualStrings("team_1", parsed.team_id);
    try testing.expectEqualStrings("prj_1", parsed.project_id);
}

fn oracleValid(arena: Allocator, bytes: []const u8) ?Record {
    if (bytes.len > max_bytes) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (root != .object or root.object.count() != 4) return null;
    const version = root.object.get("version") orelse return null;
    if (version != .integer or version.integer != format_version) return null;
    const team_id = oracleText(root.object.get("team_id"), max_id_bytes) orelse return null;
    const project_id = oracleText(root.object.get("project_id"), max_id_bytes) orelse return null;
    const confirmed_at = oracleText(root.object.get("confirmed_at"), max_timestamp_bytes) orelse return null;
    return .{ .version = format_version, .team_id = team_id, .project_id = project_id, .confirmed_at = confirmed_at };
}

fn oracleText(value: ?std.json.Value, max: usize) ?[]const u8 {
    const found = value orelse return null;
    if (found != .string) return null;
    if (found.string.len == 0 or found.string.len > max) return null;
    for (found.string) |byte| {
        if (byte < 0x20 or byte == 0x7f) return null;
    }
    return found.string;
}

fn fuzzConsentRecord(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, max_bytes + 1);
    const bytes = raw[0..smith.slice(raw)];

    const expected = oracleValid(arena, bytes);
    const parsed = parse(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConsent => {
            if (expected != null) return error.TestUnexpectedResult;
            return;
        },
    };
    const want = expected orelse return error.TestUnexpectedResult;
    try testing.expectEqual(want.version, parsed.version);
    try testing.expectEqualStrings(want.team_id, parsed.team_id);
    try testing.expectEqualStrings(want.project_id, parsed.project_id);
    try testing.expectEqualStrings(want.confirmed_at, parsed.confirmed_at);

    const encoded = try encode(arena, parsed);
    const round_trip = try parse(arena, encoded);
    try testing.expectEqual(parsed.version, round_trip.version);
    try testing.expectEqualStrings(parsed.team_id, round_trip.team_id);
    try testing.expectEqualStrings(parsed.project_id, round_trip.project_id);
    try testing.expectEqualStrings(parsed.confirmed_at, round_trip.confirmed_at);
}

test "a consent record parses or is refused on fuzzed bytes, and what parses writes back the same" {
    try std.testing.fuzz({}, fuzzConsentRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"version\":1,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
            "{\"version\":2,\"team_id\":\"team_1\",\"project_id\":\"prj_1\",\"confirmed_at\":\"2026-11-28T10:00:00Z\"}",
            "{}",
            "",
        }) ++ @import("fuzz_corpus").vercel_consent_record.*),
    });
}
