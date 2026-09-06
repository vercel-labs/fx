const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const host_target = @import("../hosts/target.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;
const cache_dir_name = "provider-versions";
const max_cache_bytes = 256;

pub const refresh_interval_ms: i64 = 60_000;
pub const Provider = enum { codex, grok };
pub const Error = Allocator.Error || error{ Cancelled, ProviderVersionUnavailable };

pub const Version = struct {
    bytes: [update_target.max_version_bytes]u8,
    len: u8,

    pub fn parse(raw: []const u8) ?Version {
        const value = update_target.normalizeVersion(std.mem.trim(u8, raw, " \r\n\t"));
        if (!update_target.isValidVersion(value)) return null;
        var version: Version = .{ .bytes = [_]u8{0} ** update_target.max_version_bytes, .len = @intCast(value.len) };
        @memcpy(version.bytes[0..value.len], value);
        return version;
    }

    pub fn slice(self: *const Version) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Lookup = struct {
    context: ?*anyopaque,
    fetch: *const fn (?*anyopaque, Allocator, Provider) Error!Version,
};

const Cached = struct {
    version: Version,
    checked_at_ms: i64,

    fn fresh(self: Cached, now_ms: i64) bool {
        const age = std.math.sub(i64, now_ms, self.checked_at_ms) catch return false;
        return age >= 0 and age < refresh_interval_ms;
    }
};

const Cache = struct {
    context: ?*anyopaque = null,
    load: *const fn (?*anyopaque, Allocator, Provider) anyerror!?Cached = loadCache,
    save: *const fn (?*anyopaque, Allocator, Provider, Cached) anyerror!void = saveCache,
};

pub fn resolve(alloc: Allocator, provider: Provider, lookup: Lookup) Error!Version {
    return resolveWithCache(alloc, provider, lookup, .{}, io_mod.milliTimestamp());
}

fn resolveWithCache(alloc: Allocator, provider: Provider, lookup: Lookup, cache: Cache, now_ms: i64) Error!Version {
    const cached = cache.load(cache.context, alloc, provider) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("models", "provider version cache unreadable provider={t} err={s}", .{ provider, @errorName(err) });
        break :blk null;
    };
    if (cached) |entry| if (entry.fresh(now_ms)) return entry.version;

    const version = lookup.fetch(lookup.context, alloc, provider) catch |err| blk: {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        const previous = cached orelse return err;
        debug_trace.logf("models", "provider version lookup unavailable provider={t}; using cached version={s}", .{ provider, previous.version.slice() });
        break :blk previous.version;
    };
    // The timestamp also bounds retries when the release service is unavailable.
    cache.save(cache.context, alloc, provider, .{ .version = version, .checked_at_ms = now_ms }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("models", "provider version cache write failed provider={t} err={s}", .{ provider, @errorName(err) });
    };
    return version;
}

fn cacheFile(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "codex.json",
        .grok => "grok.json",
    };
}

fn loadCache(_: ?*anyopaque, alloc: Allocator, provider: Provider) !?Cached {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer profile_dir.close(io_mod.getIo());
    var cache_dir = profile_dir.openDir(io_mod.getIo(), cache_dir_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer cache_dir.close(io_mod.getIo());
    return readCached(alloc, cache_dir, provider);
}

fn readCached(alloc: Allocator, dir: std.Io.Dir, provider: Provider) !?Cached {
    var file = io_mod.openExistingRegularFile(dir, cacheFile(provider), .read_only) catch |err| {
        if (err == error.FileNotFound) return null;
        if (err == error.DurablePathUnsafe) return error.InvalidProviderVersionCache;
        return err;
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidProviderVersionCache;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_cache_bytes);
    defer alloc.free(bytes);
    const Record = struct { version: []const u8, checked_at_ms: i64 };
    const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{});
    defer parsed.deinit();
    return .{
        .version = Version.parse(parsed.value.version) orelse return error.InvalidProviderVersionCache,
        .checked_at_ms = parsed.value.checked_at_ms,
    };
}

fn saveCache(_: ?*anyopaque, alloc: Allocator, provider: Provider, cached: Cached) !void {
    if (comptime host_target.is_wasm) return;
    const home = io_mod.getenv("HOME") orelse return;
    try saveCacheAtHome(alloc, provider, cached, home);
}

fn saveCacheAtHome(alloc: Allocator, provider: Provider, cached: Cached, home: []const u8) !void {
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true });
    defer home_dir.close(io_mod.getIo());
    var profile_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.root_dir_name);
    defer profile_dir.close();
    var cache_dir = try io_mod.openOrCreateVerifiedPrivateDir(&profile_dir, cache_dir_name);
    defer cache_dir.close();
    try writeCached(alloc, &cache_dir, provider, cached);
}

fn writeCached(alloc: Allocator, dir: *io_mod.VerifiedDir, provider: Provider, cached: Cached) !void {
    var bytes: [max_cache_bytes]u8 = undefined;
    const text = try std.fmt.bufPrint(&bytes, "{{\"version\":\"{s}\",\"checked_at_ms\":{d}}}\n", .{ cached.version.slice(), cached.checked_at_ms });
    try io_mod.durableReplaceVerified(alloc, dir, cacheFile(provider), text);
}

test "provider versions accept bounded stable releases and reject header or URL data" {
    const version = Version.parse(" v0.153.1\n").?;
    try std.testing.expectEqualStrings("0.153.1", version.slice());
    for ([_][]const u8{ "", "latest", "1.2", "1.2.3.4", "1.2.3?x=y", "1.2.3\r\nHeader: value", "4294967296.1.2" }) |raw| {
        try std.testing.expect(Version.parse(raw) == null);
    }
}

test "provider version cache round trips and rejects damaged data" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "versions");
    defer dir.close();
    try std.testing.expect((try readCached(alloc, dir.dir, .codex)) == null);
    try writeCached(alloc, &dir, .codex, .{ .version = Version.parse("0.153.1").?, .checked_at_ms = 500 });
    const cached = (try readCached(alloc, dir.dir, .codex)).?;
    try std.testing.expectEqualStrings("0.153.1", cached.version.slice());
    try std.testing.expect(cached.fresh(500));
    try std.testing.expect(!cached.fresh(499));
    try std.testing.expect(!cached.fresh(500 + refresh_interval_ms));
    try io_mod.durableReplaceVerified(alloc, &dir, cacheFile(.codex), "{\"version\":\"bad\",\"checked_at_ms\":0}");
    try std.testing.expectError(error.InvalidProviderVersionCache, readCached(alloc, dir.dir, .codex));
}

test "provider version cache creates its profile from a fresh home" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try saveCacheAtHome(alloc, .grok, .{ .version = Version.parse("1.0.13").?, .checked_at_ms = 500 }, home);
    var dir = try tmp.dir.openDir(std.testing.io, ".fx/provider-versions", .{});
    defer dir.close(std.testing.io);
    const cached = (try readCached(alloc, dir, .grok)).?;
    try std.testing.expectEqualStrings("1.0.13", cached.version.slice());
}

test "provider version cache rejects directories symlinks and hardlinks" {
    if (comptime @import("builtin").os.tag == .windows or host_target.is_wasm) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const Kind = enum { directory, symlink, hardlink };
    for ([_]Provider{ .codex, .grok }) |provider| {
        for ([_]Kind{ .directory, .symlink, .hardlink }) |kind| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const name = cacheFile(provider);
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "target",
                .data = "{\"version\":\"1.2.3\",\"checked_at_ms\":500}",
            });
            switch (kind) {
                .directory => try tmp.dir.createDir(std.testing.io, name, .fromMode(0o700)),
                .symlink => try tmp.dir.symLink(std.testing.io, "target", name, .{}),
                .hardlink => {
                    const name_z = try alloc.dupeZ(u8, name);
                    defer alloc.free(name_z);
                    try std.testing.expectEqual(@as(c_int, 0), std.c.linkat(tmp.dir.handle, "target", tmp.dir.handle, name_z, 0));
                },
            }
            try std.testing.expectError(error.InvalidProviderVersionCache, readCached(alloc, tmp.dir, provider));
        }
    }
}

const TestState = struct {
    cached: ?Cached = null,
    current: Version = Version.parse("0.153.1").?,
    failure: ?Error = null,
    write_failed: bool = false,
    fetch_count: usize = 0,

    fn fetch(ctx: ?*anyopaque, _: Allocator, _: Provider) Error!Version {
        const self: *TestState = @ptrCast(@alignCast(ctx.?));
        self.fetch_count += 1;
        if (self.failure) |err| return err;
        return self.current;
    }

    fn load(ctx: ?*anyopaque, _: Allocator, _: Provider) !?Cached {
        const self: *TestState = @ptrCast(@alignCast(ctx.?));
        return self.cached;
    }

    fn save(ctx: ?*anyopaque, _: Allocator, _: Provider, cached: Cached) !void {
        const self: *TestState = @ptrCast(@alignCast(ctx.?));
        if (self.write_failed) return error.TestCacheWriteFailed;
        self.cached = cached;
    }

    fn resolveAt(self: *TestState, now_ms: i64) Error!Version {
        return resolveWithCache(std.testing.allocator, .codex, .{ .context = self, .fetch = fetch }, .{ .context = self, .load = load, .save = save }, now_ms);
    }
};

test "provider versions refresh automatically and preserve the last valid cache on lookup failure" {
    var state: TestState = .{};
    _ = try state.resolveAt(0);
    state.current = Version.parse("0.154.0").?;
    var version = try state.resolveAt(refresh_interval_ms - 1);
    try std.testing.expectEqualStrings("0.153.1", version.slice());
    try std.testing.expectEqual(@as(usize, 1), state.fetch_count);
    version = try state.resolveAt(refresh_interval_ms);
    try std.testing.expectEqualStrings("0.154.0", version.slice());
    state.failure = error.ProviderVersionUnavailable;
    version = try state.resolveAt(2 * refresh_interval_ms);
    try std.testing.expectEqualStrings("0.154.0", version.slice());
    _ = try state.resolveAt(2 * refresh_interval_ms + 1);
    try std.testing.expectEqual(@as(usize, 3), state.fetch_count);
}

test "provider version failures do not fabricate a version or suppress cancellation" {
    var state: TestState = .{ .failure = error.ProviderVersionUnavailable };
    try std.testing.expectError(error.ProviderVersionUnavailable, state.resolveAt(0));
    state.failure = null;
    state.write_failed = true;
    const version = try state.resolveAt(0);
    try std.testing.expectEqualStrings("0.153.1", version.slice());
    try std.testing.expect(state.cached == null);
    state.cached = .{ .version = version, .checked_at_ms = 0 };
    state.failure = error.Cancelled;
    try std.testing.expectError(error.Cancelled, state.resolveAt(refresh_interval_ms));
}
