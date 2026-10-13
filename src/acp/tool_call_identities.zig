//! Remembers the MCP identity each exposed tool name had when an ACP session
//! called it, so `session/load` replays those calls with their server,
//! original tool, and title. Replay otherwise resolves identity from the live
//! catalog, which stays empty for servers served over the ACP connection
//! until the next turn connects them. The record is display metadata stored
//! beside the client system prompt; an unreadable record is dropped.

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const session_child_store = @import("../core/session/session_child_store.zig");
const session_adapter = @import("../core/session/session_adapter.zig");

const Allocator = std.mem.Allocator;
const Identity = mcp_runtime.McpRuntime.ToolIdentity;

/// The side file a v1 session keeps its record in.
pub const file_name = "mcp-tool-identities.json";
const max_bytes: usize = 256 * 1024;
/// Names past this bound replay without MCP identity.
const max_entries: usize = 1024;

/// Where a session keeps its record: a v1 session's side file, or a v2
/// session's `tool_identities` setting (D46).
pub const Target = union(enum) {
    none,
    capability: *session_child_store.SessionChildCapability,
    v2: *session_adapter.Session,
};

pub const Record = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.array_hash_map.String(Identity) = .empty,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        for (self.entries.keys(), self.entries.values()) |name, identity| {
            alloc.free(name);
            identity.deinit(alloc);
        }
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Returns a copy of the identity recorded for `name` in `arena`.
    pub fn lookup(self: *Record, arena: Allocator, name: []const u8) !?Identity {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const identity = self.entries.get(name) orelse return null;
        return try dupeIdentity(arena, identity);
    }

    /// Records `identity` for `name` and rewrites the stored record when it
    /// changed. A full record keeps its existing names.
    pub fn remember(
        self: *Record,
        alloc: Allocator,
        target: Target,
        name: []const u8,
        identity: Identity,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.entries.get(name)) |current| {
            if (identityEql(current, identity)) return;
        } else if (self.entries.count() >= max_entries) return;
        const bytes = try self.serialize(alloc, name, identity);
        defer alloc.free(bytes);
        // The stored record stays within what `load` accepts.
        if (bytes.len > max_bytes) return error.ToolIdentityRecordFull;
        switch (target) {
            .none => {},
            .capability => |capability| {
                var entry = try capability.atomicReplace(alloc, .client_context, file_name, bytes);
                entry.deinit(alloc);
            },
            .v2 => |session| try session.setToolIdentities(bytes),
        }
        // Memory follows the stored copy, so a failed write changes neither.
        try self.put(alloc, name, identity);
    }

    fn put(self: *Record, alloc: Allocator, name: []const u8, identity: Identity) !void {
        const owned = try dupeIdentity(alloc, identity);
        errdefer owned.deinit(alloc);
        if (self.entries.getPtr(name)) |existing| {
            existing.deinit(alloc);
            existing.* = owned;
            return;
        }
        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);
        try self.entries.put(alloc, key, owned);
    }

    /// Serializes the record as it would be with `name` set to `identity`.
    fn serialize(self: *const Record, alloc: Allocator, name: []const u8, identity: Identity) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeByte('{') catch return error.OutOfMemory;
        var replaced = false;
        for (self.entries.keys(), self.entries.values(), 0..) |key, value, index| {
            if (index > 0) w.writeByte(',') catch return error.OutOfMemory;
            const current = std.mem.eql(u8, key, name);
            replaced = replaced or current;
            try writeEntry(w, key, if (current) identity else value);
        }
        if (!replaced) {
            if (self.entries.count() > 0) w.writeByte(',') catch return error.OutOfMemory;
            try writeEntry(w, name, identity);
        }
        w.writeByte('}') catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    fn writeEntry(w: *std.Io.Writer, name: []const u8, identity: Identity) error{OutOfMemory}!void {
        std.json.Stringify.value(name, .{}, w) catch return error.OutOfMemory;
        w.writeByte(':') catch return error.OutOfMemory;
        std.json.Stringify.value(.{
            .server = identity.server,
            .tool = identity.tool,
            .title = identity.title,
        }, .{}, w) catch return error.OutOfMemory;
    }
};

/// Loads the session's record; a session without one gets an empty record.
pub fn load(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !Record {
    var file = capability.openFileReadOnly(alloc, .client_context, file_name) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.deinit();
    // The reader rejects a file that reaches its limit, so allow one byte
    // more to accept a record of exactly `max_bytes`.
    const bytes = try file.readToEnd(alloc, max_bytes + 1);
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

/// A record from its stored JSON; `load` reads a v1 side file through it, and
/// a v2 session hands it its setting.
pub fn parse(alloc: Allocator, bytes: []const u8) !Record {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolIdentityRecord;
    var record: Record = .{};
    errdefer record.deinit(alloc);
    var it = parsed.value.object.iterator();
    while (it.next()) |field| {
        if (record.entries.count() >= max_entries) break;
        if (field.value_ptr.* != .object) return error.InvalidToolIdentityRecord;
        const object = field.value_ptr.object;
        const server = stringField(object, "server") orelse return error.InvalidToolIdentityRecord;
        const tool = stringField(object, "tool") orelse return error.InvalidToolIdentityRecord;
        const title: ?[]u8 = switch (object.get("title") orelse .null) {
            .null => null,
            .string => |text| if (mcp_runtime.usableDisplayTitle(text)) |usable| @constCast(usable) else null,
            else => return error.InvalidToolIdentityRecord,
        };
        try record.put(alloc, field.key_ptr.*, .{ .server = server, .tool = tool, .title = title });
    }
    return record;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return @constCast(value.string);
}

fn identityEql(a: Identity, b: Identity) bool {
    if (!std.mem.eql(u8, a.server, b.server) or !std.mem.eql(u8, a.tool, b.tool)) return false;
    const a_title = a.title orelse return b.title == null;
    const b_title = b.title orelse return false;
    return std.mem.eql(u8, a_title, b_title);
}

fn dupeIdentity(alloc: Allocator, identity: Identity) !Identity {
    const server = try alloc.dupe(u8, identity.server);
    errdefer alloc.free(server);
    const tool = try alloc.dupe(u8, identity.tool);
    errdefer alloc.free(tool);
    return .{
        .server = server,
        .tool = tool,
        .title = if (identity.title) |title| try alloc.dupe(u8, title) else null,
    };
}

test "tool identity record round-trips and skips unchanged names" {
    const alloc = std.testing.allocator;
    var record: Record = .{};
    defer record.deinit(alloc);
    try record.remember(alloc, .none, "mcp_mini_browser_navigate", .{
        .server = @constCast("mini"),
        .tool = @constCast("browser_navigate"),
        .title = @constCast("Navigate"),
    });
    try record.remember(alloc, .none, "mcp_mini_browser_read", .{
        .server = @constCast("mini"),
        .tool = @constCast("browser_read"),
    });
    try record.remember(alloc, .none, "mcp_mini_browser_read", .{
        .server = @constCast("mini"),
        .tool = @constCast("browser_read"),
    });
    try std.testing.expectEqual(@as(usize, 2), record.entries.count());

    const bytes = try record.serialize(alloc, "mcp_mini_browser_read", record.entries.get("mcp_mini_browser_read").?);
    defer alloc.free(bytes);
    var restored = try parse(alloc, bytes);
    defer restored.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const navigate = (try restored.lookup(arena_state.allocator(), "mcp_mini_browser_navigate")).?;
    try std.testing.expectEqualStrings("mini", navigate.server);
    try std.testing.expectEqualStrings("browser_navigate", navigate.tool);
    try std.testing.expectEqualStrings("Navigate", navigate.title.?);
    const read = (try restored.lookup(arena_state.allocator(), "mcp_mini_browser_read")).?;
    try std.testing.expectEqual(@as(?[]u8, null), read.title);
    try std.testing.expectEqual(@as(?Identity, null), try restored.lookup(arena_state.allocator(), "read_file"));
}

test "tool identity record rejects malformed entries and control-character titles" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidToolIdentityRecord, parse(alloc, "[]"));
    try std.testing.expectError(error.InvalidToolIdentityRecord, parse(alloc, "{\"mcp_a_b\":{\"server\":\"a\"}}"));

    var record = try parse(alloc, "{\"mcp_a_b\":{\"server\":\"a\",\"tool\":\"b\",\"title\":\"bad\\u001btitle\"}}");
    defer record.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const identity = (try record.lookup(arena_state.allocator(), "mcp_a_b")).?;
    try std.testing.expectEqual(@as(?[]u8, null), identity.title);
}

test "tool identity record refuses names that would outgrow the stored record" {
    const alloc = std.testing.allocator;
    var record: Record = .{};
    defer record.deinit(alloc);
    const server_name = try alloc.alloc(u8, 4096);
    defer alloc.free(server_name);
    @memset(server_name, 's');

    var name_buf: [32]u8 = undefined;
    var accepted: usize = 0;
    const full = for (0..max_entries) |index| {
        const name = try std.mem.print(&name_buf, "mcp_s_tool_{d}", .{index});
        record.remember(alloc, .none, name, .{ .server = server_name, .tool = @constCast("tool") }) catch |err| {
            try std.testing.expectEqual(error.ToolIdentityRecordFull, err);
            break name;
        };
        accepted += 1;
    } else return error.TestExpectedFullRecord;

    // The refused name is not kept in memory either.
    try std.testing.expectEqual(accepted, record.entries.count());
    try std.testing.expect(!record.entries.contains(full));
    const bytes = try record.serialize(alloc, "mcp_s_tool_0", record.entries.get("mcp_s_tool_0").?);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_bytes);
}
