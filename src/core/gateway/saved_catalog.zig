//! The model catalog fx last fetched from AI Gateway for a team, saved in
//! the profile as `cache/model-catalog-v1.json`, so that a start answers from
//! it while a fresh one loads (`saved_catalog_plan.zig`). The file holds one
//! catalog. Its first line is a header that names the format, the team by
//! `token_pass.identity` (a hash that holds no secret), the catalog's URL,
//! and the wall-clock time it was saved; the rest is AI Gateway's response
//! body as it came, so it is read with the same parser as a fetched one. A
//! missing, unreadable, oversized, or broken file, or one for another team,
//! URL, or format, reads as none.
const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const json_decode = @import("../shared/json_decode.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const token_pass = @import("token_pass.zig");

const Allocator = std.mem.Allocator;

const dir_name = "cache";
const file_name = "model-catalog-v1.json";
/// A newer fx that changes the file writes another name, so this one is
/// never rewritten by an fx that cannot read it (RULES.md R3.5).
const format_version: u32 = 1;
/// About five times the size of AI Gateway's catalog today. A bigger body is
/// not saved, and a bigger file reads as none (RULES.md R3.7).
pub const max_body_bytes: usize = 2 * 1024 * 1024;
const max_header_bytes: usize = 4 * 1024;
const max_file_bytes: usize = max_header_bytes + 1 + max_body_bytes;

/// Which team's catalog, fetched from which URL.
pub const Key = struct {
    team: [token_pass.identity_len]u8,
    url: []const u8,
};

const Header = struct {
    format: u32,
    team: []const u8,
    url: []const u8,
    saved_ms: i64,
};

/// A saved catalog's body and the wall-clock time it was saved. Free it with
/// `deinit`.
pub const Saved = struct {
    file: []u8,
    body: []const u8,
    saved_ms: i64,

    pub fn deinit(self: *Saved, alloc: Allocator) void {
        alloc.free(self.file);
    }
};

/// The catalog saved for `key` in the profile at `home`, or null when there
/// is none fx can use.
pub fn load(alloc: Allocator, home: []const u8, key: Key) ?Saved {
    const path = profile_paths.rootPath(alloc, home, &.{ dir_name, file_name }) catch return null;
    defer alloc.free(path);
    const file = readFile(alloc, path) orelse return null;
    switch (parse(alloc, file, key)) {
        .found => |found| return .{ .file = file, .body = found.body, .saved_ms = found.saved_ms },
        .missed => |reason| {
            debug_trace.logf("gateway", "model catalog saved copy ignored reason={t}", .{reason});
            alloc.free(file);
            return null;
        },
    }
}

/// Saves `body`, fetched for `key` at `saved_ms` on the wall clock, in place
/// of the saved catalog. The file is replaced whole, so a crash leaves the
/// old file or the new one (RULES.md R3.4), and several fx processes that
/// save at once each write their own temporary file: the last rename wins.
pub fn save(alloc: Allocator, home: []const u8, key: Key, body: []const u8, saved_ms: i64) !void {
    if (body.len == 0 or body.len > max_body_bytes) return error.CatalogTooBig;
    const text = try encode(alloc, key, body, saved_ms);
    defer alloc.free(text);
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }),
    };
    defer home_dir.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.rootName());
    defer fx_dir.close();
    var cache_dir = try io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, dir_name);
    defer cache_dir.close();
    try io_mod.durableReplaceVerified(alloc, &cache_dir, file_name, text);
}

fn readFile(alloc: Allocator, path: []const u8) ?[]u8 {
    // A FIFO or device in its place must not stall a start, so only an
    // existing regular file opens.
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .no_follow) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("gateway", "model catalog saved copy unreadable err={s}", .{@errorName(err)});
        return null;
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| {
        debug_trace.logf("gateway", "model catalog saved copy unreadable err={s}", .{@errorName(err)});
        return null;
    };
}

/// Why a file holds no catalog fx can use, for the trace.
const Miss = enum { malformed, other_format, other_team, other_url, empty_or_too_big };

const Parsed = union(enum) {
    found: struct { body: []const u8, saved_ms: i64 },
    missed: Miss,
};

/// The body `file` holds for `key`, a slice of `file`, and when it was saved.
fn parse(alloc: Allocator, file: []const u8, key: Key) Parsed {
    const newline = std.mem.findScalar(u8, file, '\n') orelse return .{ .missed = .malformed };
    if (newline > max_header_bytes) return .{ .missed = .malformed };
    var parsed = json_decode.parseFromSlice(Header, alloc, file[0..newline], .{ .ignore_unknown_fields = true }) catch
        return .{ .missed = .malformed };
    defer parsed.deinit();
    const header = parsed.value;
    if (header.format != format_version) return .{ .missed = .other_format };
    if (!std.mem.eql(u8, header.team, &key.team)) return .{ .missed = .other_team };
    if (!std.mem.eql(u8, header.url, key.url)) return .{ .missed = .other_url };
    const body = file[newline + 1 ..];
    if (body.len == 0 or body.len > max_body_bytes) return .{ .missed = .empty_or_too_big };
    return .{ .found = .{ .body = body, .saved_ms = header.saved_ms } };
}

/// The file text for `body`. Caller owns the result.
fn encode(alloc: Allocator, key: Key, body: []const u8, saved_ms: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Header{
        .format = format_version,
        .team = &key.team,
        .url = key.url,
        .saved_ms = saved_ms,
    }, .{}, &out.writer);
    if (out.writer.buffered().len > max_header_bytes) return error.CatalogUrlTooLong;
    try out.writer.writeByte('\n');
    try out.writer.writeAll(body);
    return out.toOwnedSlice();
}

fn testHome(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn testKey(secret: []const u8, url: []const u8) Key {
    var key: Key = .{ .team = undefined, .url = url };
    _ = token_pass.identity(&key.team, .api_key, secret, null);
    return key;
}

const test_body = "{\"data\":[{\"id\":\"example/model\",\"type\":\"language\"}]}";
const test_url = "https://ai-gateway.example/v1/models";

test "saved catalog: a body saved for a team and URL loads back for them only, and the file holds no secret" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);

    const key = testKey("vck_example_saved", test_url);
    try std.testing.expect(load(alloc, home, key) == null);
    try save(alloc, home, key, test_body, 1_700_000_000_000);
    var saved = load(alloc, home, key).?;
    defer saved.deinit(alloc);
    try std.testing.expectEqualStrings(test_body, saved.body);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), saved.saved_ms);

    try std.testing.expect(load(alloc, home, testKey("vck_example_other", test_url)) == null);
    try std.testing.expect(load(alloc, home, testKey("vck_example_saved", "http://127.0.0.1:1/v1/models")) == null);

    const path = try profile_paths.rootPath(alloc, home, &.{ dir_name, file_name });
    defer alloc.free(path);
    const file = readFile(alloc, path).?;
    defer alloc.free(file);
    try std.testing.expect(std.mem.find(u8, file, "vck_example_saved") == null);
    if (comptime builtin.target.os.tag != .windows) {
        const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }

    // A later save replaces the file whole.
    try save(alloc, home, key, "{\"data\":[]}", 1_700_000_000_500);
    var later = load(alloc, home, key).?;
    defer later.deinit(alloc);
    try std.testing.expectEqualStrings("{\"data\":[]}", later.body);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_500), later.saved_ms);
}

test "saved catalog: a broken, foreign, oversized, or newer-format file reads as none and is never rewritten by a read" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);
    const key = testKey("vck_example_saved", test_url);
    try save(alloc, home, key, test_body, 1);
    const path = try profile_paths.rootPath(alloc, home, &.{ dir_name, file_name });
    defer alloc.free(path);
    const good = readFile(alloc, path).?;
    defer alloc.free(good);
    const newline = std.mem.findScalar(u8, good, '\n').?;

    const newer = try std.mem.replaceOwned(u8, alloc, good, "\"format\":1", "\"format\":2");
    defer alloc.free(newer);
    const no_body = good[0 .. newline + 1];
    const oversized = try alloc.alloc(u8, newline + 1 + max_body_bytes + 1);
    defer alloc.free(oversized);
    @memcpy(oversized[0 .. newline + 1], good[0 .. newline + 1]);
    @memset(oversized[newline + 1 ..], ' ');
    const cases = [_]struct { text: []const u8, miss: ?Miss }{
        .{ .text = "", .miss = .malformed },
        .{ .text = test_body, .miss = .malformed },
        .{ .text = "{\"format\":1}\n{}", .miss = .malformed },
        .{ .text = newer, .miss = .other_format },
        .{ .text = no_body, .miss = .empty_or_too_big },
        .{ .text = oversized, .miss = null },
        .{ .text = good[0 .. newline / 2], .miss = .malformed },
    };
    for (cases) |case| {
        try io_mod.writeFileAtomic(alloc, path, case.text);
        if (case.miss) |miss| try std.testing.expectEqual(miss, parse(alloc, case.text, key).missed);
        try std.testing.expect(load(alloc, home, key) == null);
        // Reading leaves the file as it was.
        const after = readFile(alloc, path) orelse "";
        defer if (after.len > 0) alloc.free(after);
        if (case.text.len <= max_file_bytes) try std.testing.expectEqualStrings(case.text, after);
    }
    try std.testing.expectError(error.CatalogTooBig, save(alloc, home, key, oversized[newline + 1 ..], 2));
    try std.testing.expectError(error.CatalogTooBig, save(alloc, home, key, "", 2));
}

test "saved catalog: a FIFO in place of the file reads as none" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);
    const dir = try profile_paths.rootPath(alloc, home, &.{dir_name});
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir);
    const path = try profile_paths.rootPath(alloc, home, &.{ dir_name, file_name });
    defer alloc.free(path);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = try std.mem.printSentinel(&path_buf, "{s}", .{path}, 0);
    if (mkfifo(path_z, 0o600) != 0) return error.SkipZigTest;
    try std.testing.expect(load(alloc, home, testKey("vck_example_saved", test_url)) == null);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "saved catalog: a saved catalog file reads and rewrites on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzSavedCatalog, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"format\":1,\"team\":\"0123456789abcdef0123456789abcdef\",\"url\":\"https://ai-gateway.example/v1/models\",\"saved_ms\":1}\n{\"data\":[]}",
            "{\"format\":1,\"team\":\"0123456789abcdef0123456789abcdef\",\"url\":\"https://ai-gateway.example/v1/models\",\"saved_ms\":-9223372036854775808}\n\n",
            "{\"format\":2}\n{}",
            "\n",
            "not json\n{}",
            "\xff\x00{\n",
        }) ++ @import("fuzz_corpus").saved_catalog.*),
    });
}

fn fuzzSavedCatalog(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var buffer: [8 * 1024]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const key: Key = .{ .team = "0123456789abcdef0123456789abcdef".*, .url = "https://ai-gateway.example/v1/models" };
    const before = parse(alloc, bytes, key);
    if (before == .found) {
        // The body is the file's rest, as it came.
        try std.testing.expect(before.found.body.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, bytes, before.found.body));
    }
    // What fx writes for any body it may save reads back as that body.
    const body = if (bytes.len == 0) "{}" else bytes;
    const saved_ms = smith.value(i64);
    const text = try encode(alloc, key, body, saved_ms);
    defer alloc.free(text);
    const after = parse(alloc, text, key);
    try std.testing.expectEqualStrings(body, after.found.body);
    try std.testing.expectEqual(saved_ms, after.found.saved_ms);
}
