//! The isolated run's own rules (spec I1 to I2): the host key and the sandbox names, the profile's
//! network arguments, the sweep of this host's leftovers, and the `runs/` retention. The create,
//! push, exec and bring-back are in `sandbox.zig`, `sync.zig`, `exec.zig` and `bring_back.zig`, and
//! `runner_main.zig` runs them in order. Outside code imports `vercel.zig`, not this file.

const std = @import("std");
const cli_flags = @import("../../cli/cli_flags.zig");
const flags = @import("../flags.zig");
const OptionDoc = @import("../../slash_commands/command_specs.zig").OptionDoc;
const io_mod = @import("../../shared/io.zig");
const reply = @import("reply.zig");
const sandbox = @import("sandbox.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const sync = @import("sync.zig");
const transport = @import("transport.zig");
const credentials = @import("credentials.zig");
const test_server = @import("test_server.zig");

const Allocator = std.mem.Allocator;

/// The leading hex digits of the host key (I1).
pub const host_key_bytes: usize = 8;
/// The random bytes that end a sandbox name, as twelve hex digits (I2).
const name_random_bytes: usize = 6;
/// A leftover sandbox older than this is deleted by the sweep (I1).
pub const sweep_age_ms: i64 = 60 * 60 * 1000;
/// The most sandbox names the sweep reads in one run (I1).
pub const sweep_list_limit: usize = 200;
/// The newest `runs/` folders kept (I1).
pub const kept_runs: usize = 20;
/// The folder under the state folder that holds each isolated run's files (I3).
pub const runs_dir = "runs";
const max_name_bytes: usize = 256;

/// The network policy of an isolated sandbox (I2).
pub const Network = union(enum) {
    deny_all,
    allow_all,
    custom: []const []const u8,
};

pub const Parsed = union(enum) {
    policy: Network,
    /// The first word fx does not understand, as the user wrote it (N27).
    unknown_argument: []const u8,
};

/// The options of a profile's network arguments (I2), read through `cli_flags`.
const network_options = [_]OptionDoc{
    .{ .flag = "--network <mode>", .description = "deny-all, the default, or allow-all" },
    .{ .flag = "--allow-domain <domain>", .description = "a domain the sandbox may reach; repeat for each" },
};

const NetworkFlag = enum { network, allow_domain };

const network_ids = cli_flags.idTable(NetworkFlag, &network_options);

/// I2: the network arguments of a profile. Nothing given means deny-all. `--allow-domain` may repeat,
/// and it does not mix with `--network`. A word that is not one of these is the unknown argument
/// (N27), reported as the user wrote it.
pub fn parseNetwork(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    const words = try flags.sentinelWords(arena, args);
    var parser = cli_flags.Parser.init(&network_options, words);
    var mode: ?Network = null;
    var domains: std.ArrayList([]const u8) = .empty;
    while (true) {
        const before = parser.index;
        const item = parser.next() catch return .{ .unknown_argument = args[parser.index - 1] };
        const found = item orelse break;
        switch (found) {
            .positional => |word| {
                if (parser.options_ended) return .{ .unknown_argument = "--" };
                return .{ .unknown_argument = word };
            },
            .option => |match| {
                const flag = network_ids[match.index].?;
                const name = cli_flags.flagName(network_options[match.index]);
                // `--flag=value` is not the form the profile takes, so the whole word is unknown.
                if (parser.index - before == 1) return .{ .unknown_argument = args[before] };
                const text = match.value.?;
                switch (flag) {
                    .network => {
                        if (mode != null or domains.items.len > 0) return .{ .unknown_argument = name };
                        mode = if (std.mem.eql(u8, text, "deny-all"))
                            Network.deny_all
                        else if (std.mem.eql(u8, text, "allow-all"))
                            Network.allow_all
                        else
                            return .{ .unknown_argument = text };
                    },
                    .allow_domain => {
                        if (mode != null or text.len == 0) return .{ .unknown_argument = name };
                        try domains.append(arena, text);
                    },
                }
            },
        }
    }
    if (parser.options_ended) return .{ .unknown_argument = "--" };
    if (domains.items.len > 0) return .{ .policy = .{ .custom = domains.items } };
    return .{ .policy = mode orelse .deny_all };
}

/// The `networkPolicy` body of the create call (I2).
pub fn body(network: Network) sandbox.NetworkBody {
    return switch (network) {
        .deny_all => .{ .mode = "deny-all" },
        .allow_all => .{ .mode = "allow-all" },
        .custom => |domains| .{ .mode = "custom", .allowedDomains = domains },
    };
}

/// I1: the host key, the first eight hex digits of SHA-256 over `{user_id}\n{hostname}`.
pub fn hostKey(arena: Allocator, user_id: []const u8, hostname: []const u8) Allocator.Error![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(user_id);
    hasher.update("\n");
    hasher.update(hostname);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, hex[0..host_key_bytes]);
}

/// The prefix every isolated sandbox of this host shares, `fx-iso-{host_key}-` (I1).
pub fn namePrefix(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    return arena.print("fx-iso-{s}-", .{key});
}

/// A new isolated sandbox name, `fx-iso-{host_key}-{12 hex}` (I2).
pub fn newSandboxName(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var bytes: [name_random_bytes]u8 = undefined;
    io_mod.getIo().random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return arena.print("fx-iso-{s}-{s}", .{ key, hex[0..] });
}

pub const Listed = struct {
    name: []const u8,
    /// When the sandbox was created, in milliseconds since the epoch.
    created_ms: i64,
    /// The sandbox's status (`running` while it is live), or null when the reply omits it.
    status: ?[]const u8,
};

pub const ListPage = struct {
    items: []const Listed,
    /// The `pagination.next` cursor of the page, or null on the last page.
    next: ?[]const u8,
};

/// I1: one list reply, its sandboxes with their names and creation times, and the next cursor.
pub fn parseListPage(arena: Allocator, bytes: []const u8) reply.ParseError!ListPage {
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    const array = switch (object.get("sandboxes") orelse return error.BadReply) {
        .array => |items| items,
        else => return error.BadReply,
    };
    var items: std.ArrayList(Listed) = .empty;
    for (array.items) |value| {
        const entry = try reply.objectOf(value);
        const name = try reply.requiredText(arena, entry.get("name"), max_name_bytes);
        const created_ms = switch (entry.get("createdAt") orelse return error.BadReply) {
            .integer => |ms| ms,
            else => return error.BadReply,
        };
        const status: ?[]const u8 = switch (entry.get("status") orelse .null) {
            .null => null,
            else => try reply.requiredText(arena, entry.get("status"), max_name_bytes),
        };
        try items.append(arena, .{ .name = name, .created_ms = created_ms, .status = status });
    }
    return .{ .items = items.items, .next = try cursorOf(arena, object.get("pagination")) };
}

/// The `next` cursor of a page. An empty string is no cursor: a page that names no next page ends the list.
fn cursorOf(arena: Allocator, pagination: ?std.json.Value) reply.ParseError!?[]const u8 {
    const object = try reply.objectOf(pagination orelse return null);
    return switch (object.get("next") orelse return null) {
        .null => null,
        .integer => |number| try arena.print("{d}", .{number}),
        .string => |text| if (text.len == 0) null else try arena.dupe(u8, text),
        else => return error.BadReply,
    };
}

/// I1: a leftover is swept only when its name has this host's prefix, its status is known and is not
/// `running`, and it was created more than an hour before `now_ms`. A sandbox that is still live is
/// never swept, even when it is old: a run whose runner died stops at its own timeout.
pub fn shouldDelete(item: Listed, prefix: []const u8, now_ms: i64) bool {
    const status = item.status orelse return false;
    return std.mem.startsWith(u8, item.name, prefix) and
        !std.mem.eql(u8, status, "running") and
        now_ms - item.created_ms > sweep_age_ms;
}

/// I1: deletes this host's leftover isolated sandboxes, reading at most `sweep_list_limit` entries. A
/// failed list or delete is not an error, and the run goes on.
pub fn sweep(arena: Allocator, ctx: *sandbox.Context, prefix: []const u8, now_ms: i64) void {
    var cursor: ?[]const u8 = null;
    var seen: usize = 0;
    while (seen < sweep_list_limit) {
        const response = sandbox.listIsolatedPage(ctx, prefix, cursor) catch |err| {
            debug_trace.logf("remote run", "event=sweep_skipped what=isolated reason=list_failed err={s}", .{@errorName(err)});
            return;
        };
        if (response.status != 200) {
            debug_trace.logf("remote run", "event=sweep_skipped what=isolated reason=list_refused status={d}", .{response.status});
            return;
        }
        const page = parseListPage(arena, response.body) catch |err| {
            debug_trace.logf("remote run", "event=sweep_skipped what=isolated reason=list_unreadable err={s}", .{@errorName(err)});
            return;
        };
        if (page.items.len == 0) return;
        for (page.items) |item| {
            if (seen >= sweep_list_limit) return;
            seen += 1;
            if (shouldDelete(item, prefix, now_ms)) sandbox.deleteSandboxNamed(ctx, item.name) catch |err| debug_trace.logf("remote run", "event=sweep_failed what=isolated_sandbox reason={s}", .{@errorName(err)});
        }
        cursor = page.next orelse return;
    }
}

test "a sweep that cannot list the sandboxes says so in the trace, and deletes nothing (I1)" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "sweep.log" });
    defer alloc.free(trace_path);
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .status = "500 Internal Server Error", .body = "{}" }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const origin = try std.mem.print(&buffer, "http://127.0.0.1:{d}", .{server.port()});
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(origin),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-test",
        .repo_root = "/w/repo",
        .state_dir = &state_dir,
    };

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "remote run");
    sweep(arena, &ctx, "fx-", 0);

    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &file, 8192);
    defer alloc.free(text);
    try testing.expect(std.mem.find(u8, text, "event=sweep_skipped what=isolated reason=list_refused status=500") != null);
}

pub const RunEntry = struct {
    name: []const u8,
    /// The folder's modification time, in milliseconds since the epoch.
    mtime_ms: i64,
};

/// I1: the `runs/` folders beyond the newest `kept_runs`, by folder mtime. It reorders `runs`, newest
/// first, and returns the old tail.
pub fn runsToDelete(runs: []RunEntry) []RunEntry {
    if (runs.len <= kept_runs) return runs[0..0];
    var index: usize = 1;
    while (index < runs.len) : (index += 1) {
        var at = index;
        while (at > 0 and runs[at - 1].mtime_ms < runs[at].mtime_ms) : (at -= 1) {
            std.mem.swap(RunEntry, &runs[at - 1], &runs[at]);
        }
    }
    return runs[kept_runs..];
}

/// I1: deletes the `runs/` folders beyond the newest `kept_runs`. A failure is not an error.
pub fn pruneRuns(arena: Allocator, state_dir: *io_mod.VerifiedDir) void {
    const io = io_mod.getIo();
    var runs = state_dir.dir.openDir(io, runs_dir, .{ .iterate = true }) catch return;
    defer runs.close(io);
    var found: std.ArrayList(RunEntry) = .empty;
    var entries = runs.iterate();
    while (entries.next(io) catch return) |entry| {
        if (entry.kind != .directory) continue;
        const stat = runs.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        const name = arena.dupe(u8, entry.name) catch return;
        const mtime_ms = @divFloor(sync.mtimeNs(stat), 1_000_000);
        found.append(arena, .{ .name = name, .mtime_ms = mtime_ms }) catch return;
    }
    // I1: a failed delete is not an error. The next run's sweep lists the folder again.
    for (runsToDelete(found.items)) |old| runs.deleteTree(io, old.name) catch {};
}

/// I3: `runs/{run_id}`, created when it is missing. An isolated run's bring-back writes there.
pub fn openRunFolder(arena: Allocator, state_dir: *io_mod.VerifiedDir, run_id: []const u8) !std.Io.Dir {
    const io = io_mod.getIo();
    const path = try arena.print("{s}/{s}", .{ runs_dir, run_id });
    try state_dir.dir.createDirPath(io, path);
    return state_dir.dir.openDir(io, path, .{ .iterate = true });
}

const testing = std.testing;

/// The list reply of the sweep (I1): one page, read as a JSON reply.
fn fuzzListPage(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, transport.max_response_bytes);
    const len = smith.slice(raw);
    const page = parseListPage(arena, raw[0..len]) catch |err| return switch (err) {
        error.BadReply => {},
        error.OutOfMemory => error.OutOfMemory,
    };
    for (page.items) |item| {
        try testing.expect(item.name.len > 0 and item.name.len <= max_name_bytes);
        if (item.status) |status| try testing.expect(status.len > 0 and status.len <= max_name_bytes);
    }
    if (page.next) |next| try testing.expect(next.len > 0);
}

test "a sandbox list page parses or is refused, and a parsed page has bounded names and a non-empty cursor, on fuzzed bytes" {
    try testing.fuzz({}, fuzzListPage, .{
        .corpus = &@import("fuzz_corpus").vercel_list_page.*,
    });
}

test "the profile's network arguments name one policy, and the first unknown word is named (I2)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none: []const []const u8 = &.{};
    try testing.expectEqual(Network.deny_all, (try parseNetwork(arena, none)).policy);
    try testing.expectEqual(Network.deny_all, (try parseNetwork(arena, &.{ "--network", "deny-all" })).policy);
    try testing.expectEqual(Network.allow_all, (try parseNetwork(arena, &.{ "--network", "allow-all" })).policy);
    const custom = (try parseNetwork(arena, &.{ "--allow-domain", "a.example", "--allow-domain", "b.example" })).policy;
    try testing.expectEqual(@as(usize, 2), custom.custom.len);
    try testing.expectEqualStrings("b.example", custom.custom[1]);
    try testing.expectEqualStrings("--network", (try parseNetwork(arena, &.{"--network"})).unknown_argument);
    try testing.expectEqualStrings("open", (try parseNetwork(arena, &.{ "--network", "open" })).unknown_argument);
    try testing.expectEqualStrings("--allow-domain", (try parseNetwork(arena, &.{ "--network", "allow-all", "--allow-domain", "x" })).unknown_argument);
    try testing.expectEqualStrings("--bogus", (try parseNetwork(arena, &.{"--bogus"})).unknown_argument);
}

test "the network body names the mode and the domains (I2)" {
    try testing.expectEqualStrings("deny-all", body(.deny_all).mode);
    const domains = [_][]const u8{"a.example"};
    const custom = body(.{ .custom = &domains });
    try testing.expectEqualStrings("custom", custom.mode);
    try testing.expectEqualStrings("a.example", custom.allowedDomains.?[0]);
}

test "the host key is the first eight hex digits of SHA-256 over the user id, a newline and the host name (I1)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("bd06835f", try hostKey(arena, "usr_fake", "example-host"));
    try testing.expectEqualStrings("fx-iso-bd06835f-", try namePrefix(arena, "bd06835f"));
    const name = try newSandboxName(arena, "bd06835f");
    try testing.expectEqual(@as(usize, "fx-iso-bd06835f-".len + 12), name.len);
    try testing.expect(std.mem.startsWith(u8, name, "fx-iso-bd06835f-"));
}

test "a list page reads its sandboxes, statuses and next cursor, and only this host's stopped sandboxes older than an hour go (I1)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = try parseListPage(arena, "{\"pagination\":{\"count\":4,\"next\":5},\"sandboxes\":[" ++
        "{\"name\":\"fx-iso-bd06835f-old\",\"createdAt\":1000,\"status\":\"stopped\"}," ++
        "{\"name\":\"fx-iso-bd06835f-live\",\"createdAt\":1000,\"status\":\"running\"}," ++
        "{\"name\":\"fx-iso-bd06835f-new\",\"createdAt\":9000,\"status\":\"stopped\"}," ++
        "{\"name\":\"fx-iso-bd06835f-nostatus\",\"createdAt\":1000}]}");
    try testing.expectEqual(@as(usize, 4), page.items.len);
    try testing.expectEqualStrings("5", page.next.?);
    try testing.expect(page.items[3].status == null);
    const now: i64 = 1000 + sweep_age_ms + 1;
    const prefix = "fx-iso-bd06835f-";
    try testing.expect(shouldDelete(page.items[0], prefix, now));
    try testing.expect(!shouldDelete(page.items[1], prefix, now));
    try testing.expect(!shouldDelete(page.items[2], prefix, now));
    try testing.expect(!shouldDelete(page.items[3], prefix, now));
    try testing.expect(!shouldDelete(.{ .name = "fx-iso-other-x", .created_ms = 1000, .status = "stopped" }, prefix, now));
    try testing.expect(!shouldDelete(.{ .name = "fx-iso-bd06835f-edge", .created_ms = now - sweep_age_ms, .status = "stopped" }, prefix, now));
    const last = try parseListPage(arena, "{\"sandboxes\":[]}");
    try testing.expectEqual(@as(?[]const u8, null), last.next);
}

test "the newest twenty runs are kept, and the older ones are returned for deletion (I1)" {
    var runs: [22]RunEntry = undefined;
    for (&runs, 0..) |*run, index| run.* = .{ .name = "run", .mtime_ms = @intCast(index) };
    const old = runsToDelete(&runs);
    try testing.expectEqual(@as(usize, 2), old.len);
    try testing.expectEqual(@as(i64, 1), old[0].mtime_ms);
    try testing.expectEqual(@as(i64, 0), old[1].mtime_ms);
    var few: [3]RunEntry = .{ .{ .name = "a", .mtime_ms = 1 }, .{ .name = "b", .mtime_ms = 2 }, .{ .name = "c", .mtime_ms = 3 } };
    try testing.expectEqual(@as(usize, 0), runsToDelete(&few).len);
}
