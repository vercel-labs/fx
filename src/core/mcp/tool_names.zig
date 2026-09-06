const std = @import("std");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const Allocator = std.mem.Allocator;
const collections = @import("../shared/collections.zig");
const max_mcp_tool_tags: usize = 16;

/// One alias authority for a session. Retired names remain reserved so a later
/// catalog cannot silently assign an advertised name to a different tool.
pub const Registry = struct {
    const max_aliases: usize = 64 * 1024;
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    by_identity: std.StringHashMapUnmanaged([]u8) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        var entries = self.by_identity.iterator();
        while (entries.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.by_identity.deinit(self.alloc);
        self.aliases.deinit(self.alloc);
    }

    /// Borrows the server identity until the registry is destroyed.
    pub fn serverName(self: *Registry, alias: []const u8) ?[]const u8 {
        const io = @import("../shared/io.zig").getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.aliases.get(alias);
    }

    /// Returns an owned alias. Concurrent startup, refresh, and recovery share
    /// this assignment; published catalogs never own the reservation storage.
    pub fn name(self: *Registry, alloc: Allocator, builtins: tool_dispatch.Registry, server: []const u8, tool: []const u8) (Allocator.Error || error{McpToolNameLimitExceeded})![]u8 {
        const io = @import("../shared/io.zig").getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const identity = try std.fmt.allocPrint(self.alloc, "{d}:{s}{s}", .{ server.len, server, tool });
        defer self.alloc.free(identity);
        if (self.by_identity.get(identity)) |existing| return alloc.dupe(u8, existing);
        if (self.by_identity.count() >= max_aliases) return error.McpToolNameLimitExceeded;
        const base = buildBaseToolName(self.alloc, server, tool) catch return error.OutOfMemory;
        defer self.alloc.free(base);
        var suffix: ?usize = null;
        while (true) {
            const candidate = try candidateWithSuffix(self.alloc, base, suffix);
            if (builtins.lookup(candidate) != null or self.aliases.contains(candidate)) {
                self.alloc.free(candidate);
                suffix = if (suffix) |value| value + 1 else 2;
                continue;
            }
            errdefer self.alloc.free(candidate);
            const owned_key = try self.alloc.dupe(u8, identity);
            errdefer self.alloc.free(owned_key);
            const result = try alloc.dupe(u8, candidate);
            errdefer alloc.free(result);
            try self.by_identity.ensureUnusedCapacity(self.alloc, 1);
            try self.aliases.ensureUnusedCapacity(self.alloc, 1);
            self.by_identity.putAssumeCapacityNoClobber(owned_key, candidate);
            const server_end = owned_key.len - tool.len;
            self.aliases.putAssumeCapacityNoClobber(candidate, owned_key[server_end - server.len .. server_end]);
            return result;
        }
    }
};

/// Match the configured namespace without allocating or interpreting tool arguments.
pub fn matchesServer(name: []const u8, server_name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "mcp_")) return false;
    const source = if (server_name.len == 0) "server" else server_name;
    const segment = name[4..];
    for (source, 0..) |byte, index| {
        if (index >= segment.len) return false;
        const normalized = if (isIdentifierByte(byte)) byte else '_';
        if (segment[index] != normalized) return false;
    }
    return segment.len > source.len and segment[source.len] == '_';
}

fn buildBaseToolName(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("mcp_");
    if (server_name.len == 0) {
        try out.writer.writeAll("server");
    } else {
        try writeSanitizedSegment(&out.writer, server_name);
    }
    try out.writer.writeByte('_');
    if (tool_name.len == 0) {
        try out.writer.writeAll("tool");
    } else {
        try writeSanitizedSegment(&out.writer, tool_name);
    }

    return try out.toOwnedSlice();
}

fn writeSanitizedSegment(writer: *std.Io.Writer, segment: []const u8) !void {
    for (segment) |byte| {
        if (isIdentifierByte(byte)) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('_');
        }
    }
}

fn candidateWithSuffix(alloc: Allocator, base: []const u8, suffix_index: ?usize) ![]u8 {
    const max_name_len = 64;
    if (suffix_index) |index| {
        const suffix = try std.fmt.allocPrint(alloc, "_{d}", .{index});
        defer alloc.free(suffix);

        const prefix_len = @min(base.len, max_name_len - suffix.len);
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ base[0..prefix_len], suffix });
    }

    return alloc.dupe(u8, base[0..@min(base.len, max_name_len)]);
}

test "session tool aliases survive replacement and cannot retarget a collision" {
    const alloc = std.testing.allocator;
    var registry = Registry.init(alloc);
    defer registry.deinit();
    const first = try registry.name(alloc, .{}, "a/b", "c");
    defer alloc.free(first);
    const collision = try registry.name(alloc, .{}, "a_b", "c");
    defer alloc.free(collision);
    try std.testing.expect(!std.mem.eql(u8, first, collision));
    const refreshed = try registry.name(alloc, .{}, "a/b", "c");
    defer alloc.free(refreshed);
    try std.testing.expectEqualStrings(first, refreshed);
    const recovered = try registry.name(alloc, .{}, "a_b", "c");
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(collision, recovered);
}

pub fn tagsFor(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]const []u8 {
    var tags: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &tags);

    try appendTag(alloc, &tags, "mcp");
    try appendTagTokens(alloc, &tags, server_name);
    try appendTagTokens(alloc, &tags, tool_name);

    return try tags.toOwnedSlice(alloc);
}

fn appendTagTokens(alloc: Allocator, tags: *std.ArrayList([]u8), text: []const u8) !void {
    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (isIdentifierByte(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |s| {
            try appendTag(alloc, tags, text[s..index]);
            start = null;
        }
    }
    if (start) |s| try appendTag(alloc, tags, text[s..]);
}

fn appendTag(alloc: Allocator, tags: *std.ArrayList([]u8), raw: []const u8) !void {
    if (raw.len == 0 or tags.items.len >= max_mcp_tool_tags) return;

    const normalized = try std.ascii.allocLowerString(alloc, raw);
    errdefer alloc.free(normalized);
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, normalized)) {
            alloc.free(normalized);
            return;
        }
    }
    try tags.append(alloc, normalized);
}

pub fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}
