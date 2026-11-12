//! What a subagent's profile set when the subagent started. fx saves it with
//! the child, on each of its spawn lines (`src/core/subagent/child_state.zig`),
//! so a restart, a resume in another repository, or an edit of the profile
//! file cannot change what the child may do.
//!
//! Only what the profile itself set is saved: its tool list, its MCP server
//! list, and its permission mode, with where it came from. What a profile left
//! unset has no entry, and follows the agent that started the child, live. The
//! lists are saved as written, patterns included, so fx's own tools and the
//! live MCP servers still decide what they name. A profile's prompt, model,
//! effort, and description are not saved here: the prompt is read again by
//! name, and the model and effort are saved in the child's own preferences.
//!
//! The spawn line's data is kept small (4096 bytes in the session manager,
//! because every snapshot holds it for every child), so a block that would not
//! leave room for the rest of it is not saved (`max_bytes`).

const std = @import("std");
const profiles = @import("profiles.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// The key of the block in a spawn line's data.
pub const key = "started_with";

/// The most bytes of a saved block. A spawn line's data holds at most 4096, and
/// the rest of it (the name, the fingerprint, the profile's name, a purpose)
/// takes about 450 at most.
pub const max_bytes: usize = 3072;

const version: u32 = 1;

pub const StartedWith = struct {
    /// Where the profile came from. A repository's and fx's own profiles never
    /// set a mode, and fx's own set no lists.
    source: profiles.Source,
    permission_mode: ?types.PermissionMode = null,
    /// A list the profile set, as written. Null when it set none.
    tools: ?[]const []const u8 = null,
    mcp_servers: ?[]const []const u8 = null,
};

/// What `profile` set. The result borrows `profile`.
pub fn of(profile: *const profiles.Profile) StartedWith {
    return .{
        .source = profile.source,
        .permission_mode = if (profile.source == .home) profile.permission_mode else null,
        .tools = if (profile.source == .builtin) null else profile.tools,
        .mcp_servers = if (profile.source == .builtin) null else profile.mcp_servers,
    };
}

/// The profile named `name` that `started` describes, for an agent that is
/// started in it. It has no prompt and no description. The result borrows
/// `name` and `started`.
pub fn toProfile(started: StartedWith, name: []const u8) profiles.Profile {
    return .{
        .name = name,
        .description = "",
        .source = started.source,
        .permission_mode = started.permission_mode,
        .tools = started.tools,
        .mcp_servers = started.mcp_servers,
    };
}

const Wire = struct {
    v: u32 = version,
    from: []const u8,
    permission_mode: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    mcp_servers: ?[]const []const u8 = null,
};

/// The block as fx saves it: one JSON object with nothing in it for what the
/// profile left unset. The caller checks `fits`. The text belongs to `arena`.
pub fn encode(arena: Allocator, started: StartedWith) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(Wire{
        .from = @tagName(started.source),
        .permission_mode = if (started.permission_mode) |mode| @tagName(mode) else null,
        .tools = started.tools,
        .mcp_servers = started.mcp_servers,
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Whether an encoded block leaves room in a spawn line's data.
pub fn fits(encoded: []const u8) bool {
    return encoded.len <= max_bytes;
}

pub const Read = union(enum) {
    /// The data has no block: a child from before blocks, or one a profile
    /// did not start.
    none,
    /// The data has a block that fx would not have written.
    invalid,
    started: StartedWith,
};

/// The block in a spawn line's `data`, if fx wrote it. Anything else, such as a
/// version fx does not know, an unknown key, a mode on a repository's profile,
/// or text that `encode` would not give for what it says, reads as `.invalid`,
/// and the child is treated as if it had none. The result belongs to `arena`.
pub fn read(arena: Allocator, spawn_data: []const u8) Allocator.Error!Read {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, spawn_data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    if (root != .object) return .none;
    const block = root.object.get(key) orelse return .none;
    const started = (try extract(arena, block)) orelse return .invalid;
    const canonical = try encode(arena, started);
    if (!fits(canonical)) return .invalid;
    var again: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(block, .{}, &again.writer) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, again.written(), canonical)) return .invalid;
    return .{ .started = started };
}

fn extract(arena: Allocator, block: std.json.Value) Allocator.Error!?StartedWith {
    if (block != .object) return null;
    var started: StartedWith = .{ .source = .builtin };
    var has_version = false;
    var has_source = false;
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "v")) {
            if (value != .integer or value.integer != version) return null;
            has_version = true;
        } else if (std.mem.eql(u8, name, "from")) {
            if (value != .string) return null;
            started.source = std.meta.stringToEnum(profiles.Source, value.string) orelse return null;
            has_source = true;
        } else if (std.mem.eql(u8, name, "permission_mode")) {
            if (value != .string) return null;
            started.permission_mode = std.meta.stringToEnum(types.PermissionMode, value.string) orelse return null;
        } else if (std.mem.eql(u8, name, "tools")) {
            started.tools = (try names(arena, value)) orelse return null;
        } else if (std.mem.eql(u8, name, "mcp_servers")) {
            started.mcp_servers = (try names(arena, value)) orelse return null;
        } else return null;
    }
    if (!has_version or !has_source) return null;
    if (started.source != .home and started.permission_mode != null) return null;
    if (started.source == .builtin and (started.tools != null or started.mcp_servers != null)) return null;
    return started;
}

fn names(arena: Allocator, value: std.json.Value) Allocator.Error!?[]const []const u8 {
    if (value != .array) return null;
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| {
        if (item != .string or item.string.len == 0 or item.string.len > profiles.max_list_entry_bytes) return null;
        slot.* = item.string;
    }
    return out;
}

/// A copy of `started` that `alloc` owns. Free it with `free`.
pub fn dupe(alloc: Allocator, started: StartedWith) Allocator.Error!StartedWith {
    const tools = if (started.tools) |list| try dupeNames(alloc, list) else null;
    errdefer if (tools) |list| freeNames(alloc, list);
    const mcp_servers = if (started.mcp_servers) |list| try dupeNames(alloc, list) else null;
    return .{ .source = started.source, .permission_mode = started.permission_mode, .tools = tools, .mcp_servers = mcp_servers };
}

pub fn free(alloc: Allocator, started: StartedWith) void {
    if (started.tools) |list| freeNames(alloc, list);
    if (started.mcp_servers) |list| freeNames(alloc, list);
}

fn dupeNames(alloc: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, list.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |text| alloc.free(text);
        alloc.free(out);
    }
    for (list, out) |text, *slot| {
        slot.* = try alloc.dupe(u8, text);
        done += 1;
    }
    return out;
}

fn freeNames(alloc: Allocator, list: []const []const u8) void {
    for (list) |text| alloc.free(text);
    alloc.free(list);
}

pub fn eql(a: StartedWith, b: StartedWith) bool {
    return a.source == b.source and a.permission_mode == b.permission_mode and
        namesEql(a.tools, b.tools) and namesEql(a.mcp_servers, b.mcp_servers);
}

fn namesEql(a: ?[]const []const u8, b: ?[]const []const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

const testing = std.testing;
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");

test "a block holds only what the profile set, and nothing for what it left unset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: ?[]const u8 = null;

    // A profile that sets nothing: fx's own `agent`, a copy of its parent.
    const builtin = profiles.builtin(profiles.agent_name).?;
    try testing.expectEqualStrings("{\"v\":1,\"from\":\"builtin\"}", try encode(arena, of(&builtin)));

    // A realistic profile of the user's own.
    const reviewer = try profiles.parse(
        arena,
        "reviewer",
        .home,
        "{\"description\": \"Reviews changes without editing files\", \"model\": \"openai/gpt-5\", \"effort\": \"high\", " ++
            "\"permission_mode\": \"auto\", \"tools\": [\"read_file\", \"glob_files\", \"grep_files\", \"toolbox\"], " ++
            "\"mcp_servers\": [\"github\"], \"prompt\": \"replace\"}",
        "Review only.",
        &failure,
    );
    const encoded = try encode(arena, of(&reviewer));
    try testing.expectEqualStrings(
        "{\"v\":1,\"from\":\"home\",\"permission_mode\":\"auto\",\"tools\":[\"read_file\",\"glob_files\",\"grep_files\",\"toolbox\"],\"mcp_servers\":[\"github\"]}",
        encoded,
    );
    try testing.expectEqual(@as(usize, 129), encoded.len);

    // A repository's profile that sets a tool list and no servers has no
    // server entry, and one that sets none has no list, which differs from an
    // empty list.
    const project = try profiles.parse(arena, "helper", .project, "{\"description\": \"Helps\", \"permission_mode\": \"yolo\", \"tools\": []}", "", &failure);
    try testing.expectEqualStrings("{\"v\":1,\"from\":\"project\",\"tools\":[]}", try encode(arena, of(&project)));
}

test "a block read back from a spawn line is what was written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const started: StartedWith = .{
        .source = .home,
        .permission_mode = .yolo,
        .tools = &.{ "*", "!shell" },
        .mcp_servers = &.{},
    };
    const spawn = try arena.print("{{\"agent\":\"reviewer\",\"fingerprint\":\"ab\",\"profile\":\"reviewer\",\"started_with\":{s}}}", .{try encode(arena, started)});
    const got = try read(arena, spawn);
    try testing.expect(eql(started, got.started));

    const built = toProfile(got.started, "reviewer");
    try testing.expectEqual(types.PermissionMode.yolo, built.permission_mode.?);
    try testing.expect(profiles.setsTools(&built) and profiles.setsMcpServers(&built));
    try testing.expect(profiles.allowsTool(&built, "read_file", &.{}));
    try testing.expect(!profiles.allowsTool(&built, "shell", &.{}));
    try testing.expect(!profiles.allowsMcpServer(&built, "github"));

    // Data with no block, or that is not an object, has none.
    try testing.expectEqual(Read.none, try read(arena, "{\"agent\":\"reviewer\",\"fingerprint\":\"ab\"}"));
    try testing.expectEqual(Read.none, try read(arena, "[]"));
    try testing.expectEqual(Read.none, try read(arena, "not json"));
}

test "a block fx would not write reads as invalid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        // A version fx does not know, or none.
        "{\"v\":2,\"from\":\"home\"}",
        "{\"from\":\"home\"}",
        // No source, or one fx does not have.
        "{\"v\":1}",
        "{\"v\":1,\"from\":\"elsewhere\"}",
        // A key fx does not write.
        "{\"v\":1,\"from\":\"home\",\"model\":\"openai/gpt-5\"}",
        // A repository's or fx's own profile never sets a mode.
        "{\"v\":1,\"from\":\"project\",\"permission_mode\":\"yolo\"}",
        "{\"v\":1,\"from\":\"builtin\",\"permission_mode\":\"ask\"}",
        // fx's own profiles set no lists.
        "{\"v\":1,\"from\":\"builtin\",\"tools\":[]}",
        // A mode fx does not have, including a name `PermissionMode.parse` takes.
        "{\"v\":1,\"from\":\"home\",\"permission_mode\":\"full-access\"}",
        "{\"v\":1,\"from\":\"home\",\"permission_mode\":3}",
        // Lists that are not lists of names.
        "{\"v\":1,\"from\":\"home\",\"tools\":\"read_file\"}",
        "{\"v\":1,\"from\":\"home\",\"tools\":[\"\"]}",
        "{\"v\":1,\"from\":\"home\",\"tools\":[7]}",
        "{\"v\":1,\"from\":\"home\",\"mcp_servers\":[null]}",
        // The keys in the order fx writes them.
        "{\"from\":\"home\",\"v\":1}",
        // Not an object.
        "[]",
        "\"home\"",
        "null",
    };
    for (cases) |block| {
        const spawn = try arena.print("{{\"fingerprint\":\"ab\",\"started_with\":{s}}}", .{block});
        try testing.expectEqual(Read.invalid, try read(arena, spawn));
    }
    // A name longer than a profile may list.
    const long = try arena.print("{{\"started_with\":{{\"v\":1,\"from\":\"home\",\"tools\":[\"{s}\"]}}}}", .{text_utils.repeat("x", profiles.max_list_entry_bytes + 1)});
    try testing.expectEqual(Read.invalid, try read(arena, long));
}

test "a block over its budget is not saved, and one over it that is read is invalid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names_list: [40][]const u8 = undefined;
    for (&names_list, 0..) |*slot, index| slot.* = try arena.print("{s}{d}", .{ text_utils.repeat("t", 90), index });
    const started: StartedWith = .{ .source = .home, .tools = &names_list };
    const encoded = try encode(arena, started);
    try testing.expect(encoded.len > max_bytes);
    try testing.expect(!fits(encoded));
    const spawn = try arena.print("{{\"started_with\":{s}}}", .{encoded});
    try testing.expectEqual(Read.invalid, try read(arena, spawn));
}

test "a copy of a block is owned by its allocator" {
    const started: StartedWith = .{ .source = .home, .permission_mode = .auto, .tools = &.{ "read_file", "glob_files" }, .mcp_servers = &.{"github"} };
    const copy = try dupe(testing.allocator, started);
    defer free(testing.allocator, copy);
    try testing.expect(eql(started, copy));
    try testing.expect(copy.tools.?[0].ptr != started.tools.?[0].ptr);
    try testing.checkAllAllocationFailures(testing_allocator.no_resize, struct {
        fn run(alloc: Allocator, value: StartedWith) !void {
            free(alloc, try dupe(alloc, value));
        }
    }.run, .{started});
}

fn fuzzRead(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [4096]u8 = undefined;
    const spawn = buffer[0..smith.slice(&buffer)];
    switch (try read(arena, spawn)) {
        .none, .invalid => {},
        .started => |started| {
            // What is accepted is what `encode` writes: it fits, a mode only
            // comes with a profile of the user's own, and fx's own set no lists.
            const encoded = try encode(arena, started);
            try testing.expect(fits(encoded));
            if (started.source != .home) try testing.expect(started.permission_mode == null);
            if (started.source == .builtin) try testing.expect(started.tools == null and started.mcp_servers == null);
            const spawn_again = try arena.print("{{\"{s}\":{s}}}", .{ key, encoded });
            const again = try read(arena, spawn_again);
            try testing.expect(again == .started and eql(started, again.started));
            // The profile built from it allows exactly what its lists say.
            const built = toProfile(started, "fuzz");
            try testing.expectEqual(started.tools != null, profiles.setsTools(&built));
            try testing.expectEqual(started.mcp_servers != null, profiles.setsMcpServers(&built));
        },
    }
}

test "a saved profile block stays canonical for fuzzed spawn data" {
    try std.testing.fuzz({}, fuzzRead, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"agent\":\"reviewer\",\"fingerprint\":\"ab\"}",
            "{\"profile\":\"agent\",\"started_with\":{\"v\":1,\"from\":\"builtin\"}}",
            "{\"profile\":\"reviewer\",\"started_with\":{\"v\":1,\"from\":\"home\",\"permission_mode\":\"auto\",\"tools\":[\"read_file\",\"!shell\"],\"mcp_servers\":[\"github\"]}}",
            "{\"started_with\":{\"v\":1,\"from\":\"project\",\"permission_mode\":\"yolo\"}}",
            "{\"started_with\":{\"v\":2,\"from\":\"home\",\"extra\":[]}}",
            "{\"started_with\":{\"v\":1,\"from\":\"home\",\"tools\":[\"\\u0000\",\"a\\nb\",\"\"]}}",
        }) ++ @import("fuzz_corpus").subagent_started_with.*),
    });
}
