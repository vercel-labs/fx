//! The key that says two fx sessions launch the same stdio MCP server the
//! same way, so one owner process can run a single copy for both
//! (`tests/tla/mcp_host/SharedServers.tla`). It hashes the display name and
//! exactly the fields `mcp.engine.same()` compares: sessions that resolve the
//! same entry share it, and an entry whose name, transport, environment,
//! directory, auth, or timeouts differ in any way gets another copy.
//!
//! The name is part of the key so one entry is one key. Two entries with
//! different names are two servers even when they launch the same command,
//! which `fx doctor` relies on when it checks each entry on its own.
//!
//! Pure: no I/O, no clock, no allocation. Every field is length-prefixed, so
//! no two different configs hash the same bytes by concatenation.
const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// 32 lowercase hex digits: half of a SHA-256 digest. Long enough that two
/// different launch configs colliding is not a risk anyone can work toward.
pub const Key = [32]u8;

pub fn of(config: mcp.engine.Config) Key {
    var hasher = Sha256.init(.{});
    feedText(&hasher, config.name);
    switch (config.transport) {
        .stdio => |p| {
            feedByte(&hasher, 0);
            feedInt(&hasher, p.argv.len);
            for (p.argv) |arg| feedText(&hasher, arg);
            feedEnv(&hasher, p.environ_map);
            feedOptionalText(&hasher, p.cwd);
        },
        .http => |h| {
            feedByte(&hasher, 1);
            feedText(&hasher, h.url);
            feedInt(&hasher, h.headers.len);
            for (h.headers) |header| {
                feedText(&hasher, header.name);
                feedText(&hasher, header.value);
            }
        },
    }
    inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
        feedOptionalText(&hasher, @field(config.auth, field));
    }
    feedText(&hasher, config.auth.client_name);
    // The sign-in flow is configuration here: `same()` compares it whole.
    feedValue(&hasher, config.auth.flow);
    feedByte(&hasher, @intFromBool(config.timeouts != null));
    if (config.timeouts) |timeouts| feedValue(&hasher, timeouts);
    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

/// The environment sorted by key, so the map's order never changes the key.
/// Environments are small, so finding the next key each time costs nothing.
fn feedEnv(hasher: *Sha256, map: ?*const std.process.Environ.Map) void {
    const m = map orelse return feedInt(hasher, @as(u32, 0));
    feedInt(hasher, m.count());
    var last: ?[]const u8 = null;
    var hashed: usize = 0;
    while (hashed < m.count()) : (hashed += 1) {
        var it = m.iterator();
        var next: ?[]const u8 = null;
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (last) |previous| if (std.mem.order(u8, key, previous) != .gt) continue;
            if (next == null or std.mem.order(u8, key, next.?) == .lt) next = key;
        }
        const key = next.?;
        feedText(hasher, key);
        feedText(hasher, m.get(key).?);
        last = key;
    }
}

fn feedByte(hasher: *Sha256, byte: u8) void {
    hasher.update(&.{byte});
}

fn feedInt(hasher: *Sha256, value: anytype) void {
    const bytes = std.mem.toBytes(value);
    hasher.update(&bytes);
}

/// A 4-byte length, then the bytes.
fn feedText(hasher: *Sha256, text: []const u8) void {
    feedInt(hasher, @as(u32, @intCast(text.len)));
    hasher.update(text);
}

fn feedOptionalText(hasher: *Sha256, text: ?[]const u8) void {
    feedByte(hasher, @intFromBool(text != null));
    if (text) |value| feedText(hasher, value);
}

/// Every field of an integer, enum, bool, or nested struct, field by field,
/// so padding never enters the hash.
fn feedValue(hasher: *Sha256, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .int => feedInt(hasher, value),
        .bool => feedByte(hasher, @intFromBool(value)),
        .@"enum" => feedInt(hasher, @backingInt(value)),
        .@"struct" => {
            const info = @typeInfo(@TypeOf(value)).@"struct";
            inline for (info.field_names, info.field_types) |name, T| {
                _ = T;
                feedValue(hasher, @field(value, name));
            }
        },
        else => @compileError("an MCP server's config holds only integers, enums, bools, and structs of them"),
    }
}

const testing = std.testing;
const engine = mcp.engine;
const request = mcp.core.request;

fn envMap(a: std.mem.Allocator, pairs: []const [2][]const u8) !*const std.process.Environ.Map {
    const map = try a.create(std.process.Environ.Map);
    map.* = .init(a);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "another name gives another key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const map = try envMap(arena.allocator(), &.{.{ "A", "1" }});
    const argv = [_][]const u8{ "node", "s.js" };
    const a: engine.Config = .{ .name = "one", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = map, .cwd = "/w" } } };
    var b = a;
    b.name = "two";
    try testing.expect(!std.mem.eql(u8, &of(a), &of(b)));
}

test "the environment's order does not change the key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = [_][]const u8{"node"};
    const first = try envMap(arena.allocator(), &.{ .{ "A", "1" }, .{ "B", "2" }, .{ "C", "3" } });
    const second = try envMap(arena.allocator(), &.{ .{ "C", "3" }, .{ "A", "1" }, .{ "B", "2" } });
    const a: engine.Config = .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = first } } };
    const b: engine.Config = .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = second } } };
    try testing.expectEqual(of(a), of(b));
}

test "every compared field changes the key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a_ = arena.allocator();
    const argv = [_][]const u8{ "node", "s.js" };
    const other_argv = [_][]const u8{ "node", "other.js" };
    const base_map = try envMap(a_, &.{.{ "A", "1" }});
    const other_map = try envMap(a_, &.{ .{ "A", "1" }, .{ "B", "2" } });
    const base: engine.Config = .{
        .name = "x",
        .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } },
        .auth = .{ .client_id = "c1" },
        .timeouts = .{ .start_ms = 1_000 },
    };
    const base_key = of(base);
    const mutations = [_]engine.Config{
        // argv
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &other_argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000 } },
        // environment
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = other_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000 } },
        // another directory
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/other" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000 } },
        // no directory, where the base names one
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000 } },
        // another transport
        .{ .name = "x", .transport = .{ .http = .{ .url = "https://w.example/mcp" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000 } },
        // client id
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c2" }, .timeouts = .{ .start_ms = 1_000 } },
        // client secret
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .client_secret = "s" }, .timeouts = .{ .start_ms = 1_000 } },
        // client metadata url
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .client_metadata_url = "https://m.example/c" }, .timeouts = .{ .start_ms = 1_000 } },
        // resource
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .resource = "https://r.example/" }, .timeouts = .{ .start_ms = 1_000 } },
        // scopes
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .scopes = "a.read" }, .timeouts = .{ .start_ms = 1_000 } },
        // client name
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .client_name = "another" }, .timeouts = .{ .start_ms = 1_000 } },
        // sign-in flow
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1", .flow = .{ .max_authorizations = 4 } }, .timeouts = .{ .start_ms = 1_000 } },
        // start limit
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 2_000 } },
        // idle limit
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000, .idle_ms = 90_000 } },
        // hard limit
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000, .hard_ms = 900_000 } },
        // refresh limit
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000, .refresh_ms = 60_000 } },
        // refused-line grace
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" }, .timeouts = .{ .start_ms = 1_000, .refused_ms = 60_000 } },
        // no limits, where the base has them
        .{ .name = "x", .transport = .{ .stdio = .{ .argv = &argv, .environ_map = base_map, .cwd = "/w" } }, .auth = .{ .client_id = "c1" } },
    };
    for (mutations) |mutation| {
        try testing.expect(!std.mem.eql(u8, &base_key, &of(mutation)));
    }
    // The base hashes to itself, so a change is what moved it.
    try testing.expectEqual(base_key, of(base));
}

test "same() and the key agree on random pairs" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a_ = arena.allocator();
    const words = [_][]const u8{ "", "a", "b", "node", "s.js", "-x" };
    const cwds = [_]?[]const u8{ null, "/w", "/other" };
    for (0..500) |_| {
        var configs: [2]engine.Config = undefined;
        for (&configs) |*config| {
            config.* = .{ .name = "x", .transport = .{ .stdio = .{ .argv = &.{}, .cwd = cwds[random.uintLessThan(usize, cwds.len)] } } };
            var argv: std.ArrayList([]const u8) = .empty;
            for (0..random.uintLessThan(usize, 4)) |_| try argv.append(a_, words[random.uintLessThan(usize, words.len)]);
            config.transport.stdio.argv = argv.items;
            const pairs: []const [2][]const u8 = if (random.boolean())
                &.{}
            else if (random.boolean())
                &.{.{ "A", words[random.uintLessThan(usize, words.len)] }}
            else
                &.{ .{ "A", words[random.uintLessThan(usize, words.len)] }, .{ "B", words[random.uintLessThan(usize, words.len)] } };
            config.transport.stdio.environ_map = try envMap(a_, pairs);
            config.auth.client_id = if (random.boolean()) null else words[random.uintLessThan(usize, words.len)];
            config.auth.scopes = if (random.boolean()) null else words[random.uintLessThan(usize, words.len)];
            config.timeouts = if (random.boolean()) null else request.Timeouts{ .start_ms = random.uintAtMost(u32, 3) };
        }
        const same = engine.same(configs[0], configs[1]);
        const keys_equal = std.mem.eql(u8, &of(configs[0]), &of(configs[1]));
        try testing.expectEqual(same, keys_equal);
    }
}
