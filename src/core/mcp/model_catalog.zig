const std = @import("std");
const health = @import("health.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

const max_prompt_bytes: usize = 4 * 1024;
const header =
    "Configured MCP servers visible to this model turn are listed below.\n" ++
    "Use capability_search with the requested use case. Then use mcp_select_tool with one exact MCP result. Do not guess tool names.\n" ++
    "<mcp_servers>\n";
const footer = "</mcp_servers>\n";
const empty_entry = "  <none />\n";

pub const Availability = enum {
    ready,
    discovering,
    available_on_demand,
    authentication_required,
    disabled,
    failed,
    unavailable,
};

pub const ServerSummary = struct {
    name: []u8,
    availability: Availability,
    tool_count: ?usize = null,
};

pub const Snapshot = struct {
    servers: []ServerSummary,

    /// Returns an owned empty snapshot. The caller releases it with `deinit`.
    pub fn empty(alloc: Allocator) !Snapshot {
        return .{ .servers = try alloc.alloc(ServerSummary, 0) };
    }

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.servers) |server| alloc.free(server.name);
        alloc.free(self.servers);
        self.* = undefined;
    }
};

pub const PromptSection = struct {
    text: []u8,
    notice: ?[]u8 = null,

    pub fn deinit(self: *PromptSection, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.notice) |notice| alloc.free(notice);
        self.* = undefined;
    }
};

pub fn classifyAvailability(
    connection: health.ConnectionState,
    authentication: health.AuthenticationState,
    deferred_for_ask: bool,
) Availability {
    if (authentication == .required) return .authentication_required;
    return switch (connection) {
        .disabled => .disabled,
        .connecting => .discovering,
        .ready => .ready,
        .failed => .failed,
        .disconnected => if (deferred_for_ask) .available_on_demand else .unavailable,
    };
}

/// Returns an owned prompt section. The caller releases it with `deinit` unless
/// both values are intentionally retained by the supplied request arena.
pub fn render(alloc: Allocator, snapshot: Snapshot) Allocator.Error!PromptSection {
    return renderWithLimit(alloc, snapshot, max_prompt_bytes);
}

fn renderWithLimit(alloc: Allocator, snapshot: Snapshot, limit: usize) Allocator.Error!PromptSection {
    if (snapshot.servers.len == 0) {
        if (!partsFit(limit, &.{ header, empty_entry, footer })) {
            return .{ .text = try alloc.dupe(u8, "") };
        }
        return .{ .text = try std.mem.concat(alloc, u8, &.{ header, empty_entry, footer }) };
    }

    const sorted = try alloc.alloc(*const ServerSummary, snapshot.servers.len);
    defer alloc.free(sorted);
    for (snapshot.servers, 0..) |*server, index| sorted[index] = server;
    sort_utils.sort(*const ServerSummary, sorted, {}, lessServerSummary);

    const entries = try alloc.alloc([]u8, sorted.len);
    var initialized: usize = 0;
    defer {
        for (entries[0..initialized]) |entry| alloc.free(entry);
        alloc.free(entries);
    }
    for (sorted, 0..) |server, index| {
        entries[index] = try renderEntry(alloc, server.*);
        initialized += 1;
    }

    if (entriesFit(limit, entries, null)) {
        return .{ .text = try joinEntries(alloc, entries, null) };
    }

    var retained_count: usize = 0;
    for (0..entries.len + 1) |candidate_count| {
        const marker = try truncationMarker(alloc, entries.len - candidate_count);
        defer alloc.free(marker);
        if (!entriesFit(limit, entries[0..candidate_count], marker)) break;
        retained_count = candidate_count;
    }
    const omitted_count = entries.len - retained_count;
    const marker = try truncationMarker(alloc, omitted_count);
    defer alloc.free(marker);
    const text = if (entriesFit(limit, entries[0..retained_count], marker))
        try joinEntries(alloc, entries[0..retained_count], marker)
    else
        try alloc.dupe(u8, "");
    errdefer alloc.free(text);
    return .{
        .text = text,
        .notice = try std.fmt.allocPrint(
            alloc,
            "[context] omitted {d} MCP server{s} from the model catalog because the fixed {d}-byte budget was reached",
            .{ omitted_count, if (omitted_count == 1) "" else "s", limit },
        ),
    };
}

fn lessServerSummary(_: void, lhs: *const ServerSummary, rhs: *const ServerSummary) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn renderEntry(alloc: Allocator, server: ServerSummary) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("  <server name=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, server.name) catch return error.OutOfMemory;
    out.writer.print("\" state=\"{s}\"", .{@tagName(server.availability)}) catch return error.OutOfMemory;
    if (server.tool_count) |count| {
        out.writer.print(" tools=\"{d}\"", .{count}) catch return error.OutOfMemory;
    }
    out.writer.writeAll(" />\n") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn truncationMarker(alloc: Allocator, omitted_count: usize) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "  <catalog_truncated omitted_count=\"{d}\" />\n",
        .{omitted_count},
    );
}

fn entriesFit(limit: usize, entries: []const []const u8, marker: ?[]const u8) bool {
    var remaining = limit;
    if (!consume(&remaining, header.len)) return false;
    for (entries) |entry| {
        if (!consume(&remaining, entry.len)) return false;
    }
    if (marker) |value| {
        if (!consume(&remaining, value.len)) return false;
    }
    return consume(&remaining, footer.len);
}

fn partsFit(limit: usize, parts: []const []const u8) bool {
    var remaining = limit;
    for (parts) |part| {
        if (!consume(&remaining, part.len)) return false;
    }
    return true;
}

fn consume(remaining: *usize, bytes: usize) bool {
    if (bytes > remaining.*) return false;
    remaining.* -= bytes;
    return true;
}

fn joinEntries(alloc: Allocator, entries: []const []const u8, marker: ?[]const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(header) catch return error.OutOfMemory;
    for (entries) |entry| out.writer.writeAll(entry) catch return error.OutOfMemory;
    if (marker) |value| out.writer.writeAll(value) catch return error.OutOfMemory;
    out.writer.writeAll(footer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn ownedSnapshot(
    alloc: Allocator,
    inputs: []const struct {
        name: []const u8,
        availability: Availability,
        tool_count: ?usize = null,
    },
) !Snapshot {
    const servers = try alloc.alloc(ServerSummary, inputs.len);
    var initialized: usize = 0;
    errdefer {
        for (servers[0..initialized]) |server| alloc.free(server.name);
        alloc.free(servers);
    }
    for (inputs, 0..) |input, index| {
        servers[index] = .{
            .name = try alloc.dupe(u8, input.name),
            .availability = input.availability,
            .tool_count = input.tool_count,
        };
        initialized += 1;
    }
    return .{ .servers = servers };
}

test "availability follows canonical connection authentication and deferred state" {
    const Case = struct {
        connection: health.ConnectionState,
        authentication: health.AuthenticationState = .none,
        deferred_for_ask: bool = false,
        expected: Availability,
    };
    const cases = [_]Case{
        .{ .connection = .ready, .expected = .ready },
        .{ .connection = .connecting, .expected = .discovering },
        .{ .connection = .disconnected, .deferred_for_ask = true, .expected = .available_on_demand },
        .{ .connection = .failed, .authentication = .required, .expected = .authentication_required },
        .{ .connection = .disabled, .expected = .disabled },
        .{ .connection = .failed, .expected = .failed },
        .{ .connection = .disconnected, .expected = .unavailable },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            classifyAvailability(case.connection, case.authentication, case.deferred_for_ask),
        );
    }
}

test "render exposes sorted server summaries without tool metadata" {
    const alloc = std.testing.allocator;
    var snapshot = try ownedSnapshot(alloc, &.{
        .{ .name = "zeta", .availability = .authentication_required },
        .{ .name = "alpha", .availability = .ready, .tool_count = 2 },
    });
    defer snapshot.deinit(alloc);

    var section = try render(alloc, snapshot);
    defer section.deinit(alloc);

    try std.testing.expectEqualStrings(
        "Configured MCP servers visible to this model turn are listed below.\n" ++
            "Use capability_search with the requested use case. Then use mcp_select_tool with one exact MCP result. Do not guess tool names.\n" ++
            "<mcp_servers>\n" ++
            "  <server name=\"alpha\" state=\"ready\" tools=\"2\" />\n" ++
            "  <server name=\"zeta\" state=\"authentication_required\" />\n" ++
            "</mcp_servers>\n",
        section.text,
    );
    try std.testing.expectEqual(@as(?[]u8, null), section.notice);
}

test "render encodes names and bounds omissions without revealing omitted aliases" {
    const alloc = std.testing.allocator;
    var snapshot = try ownedSnapshot(alloc, &.{
        .{ .name = "alpha", .availability = .ready, .tool_count = 1 },
        .{ .name = "bravo", .availability = .ready, .tool_count = 2 },
        .{ .name = "hidden<&\"", .availability = .failed },
    });
    defer snapshot.deinit(alloc);

    var section = try renderWithLimit(alloc, snapshot, 280);
    defer section.deinit(alloc);

    try std.testing.expect(section.text.len <= 280);
    try std.testing.expect(section.notice != null);
    try std.testing.expect(std.mem.find(u8, section.notice.?, "omitted 3 MCP servers") != null);
    try std.testing.expect(std.mem.find(u8, section.notice.?, "hidden") == null);
    try std.testing.expect(std.mem.find(u8, section.text, "hidden<&\"") == null);
}

test "render explicitly reports an empty catalog" {
    const alloc = std.testing.allocator;
    var snapshot = try ownedSnapshot(alloc, &.{});
    defer snapshot.deinit(alloc);

    var section = try render(alloc, snapshot);
    defer section.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, section.text, "<none />") != null);
    try std.testing.expectEqual(@as(?[]u8, null), section.notice);
}

fn checkRenderAllocationFailures(alloc: Allocator) !void {
    var servers = [_]ServerSummary{
        .{ .name = @constCast("alpha"), .availability = .ready, .tool_count = 2 },
        .{ .name = @constCast("beta"), .availability = .failed },
    };
    var section = try render(alloc, .{ .servers = &servers });
    section.deinit(alloc);
}

test "render cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRenderAllocationFailures,
        .{},
    );
}
