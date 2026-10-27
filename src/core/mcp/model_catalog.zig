const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const max_prompt_bytes: usize = 4 * 1024;
const header =
    "Configured MCP servers visible to this model turn are listed below.\n" ++
    "A listed server is not a reason to use MCP. Use capability_search only when the task clearly needs a capability not already available locally. Pass the task and an optional exact server name. Call tools advertised after search directly. Use mcp_select_tool when a relevant result is not yet callable. Use returned identities and refine the query when needed.\n" ++
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
    /// The server's tools are advertised every turn without a search.
    always_loaded: bool = false,
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

/// One server's availability as the session's instructions show it.
pub const BaselineEntry = struct {
    name: []u8,
    availability: Availability,
};

const max_change_notice_transitions: usize = 8;

/// Renders a model-visible note describing how current availability differs
/// from the baseline the instructions show. Returns null when nothing
/// differs. Tool-count-only changes and moves between `ready`,
/// `available_on_demand` and `discovering` do not render: each means the
/// server can be searched, and the model learns its tools from the search.
/// The caller owns the returned slice.
pub fn renderChangeNotice(
    alloc: Allocator,
    baseline: []const BaselineEntry,
    current: []const ServerSummary,
) Allocator.Error!?[]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var transitions: usize = 0;
    var omitted: usize = 0;

    for (current) |server| {
        const entry = findBaselineEntry(baseline, server.name) orelse {
            try renderAdditionLine(&body.writer, &transitions, &omitted, server.name, server.availability);
            continue;
        };
        if (usable(entry.availability) and usable(server.availability)) continue;
        if (entry.availability == server.availability) continue;
        try renderTransitionLine(&body.writer, &transitions, &omitted, server.name, entry.availability, server.availability, server.tool_count);
    }
    for (baseline) |entry| {
        if (findCurrentEntry(current, entry.name) != null) continue;
        try renderRemovalLine(&body.writer, &transitions, &omitted, entry.name);
    }
    if (transitions == 0) return null;
    if (omitted > 0) {
        body.writer.print("  and {d} more change{s}\n", .{ omitted, if (omitted == 1) "" else "s" }) catch return error.OutOfMemory;
    }
    const change_header = "MCP server availability now differs from the <mcp_servers> list in the instructions:\n";
    const change_footer = "These states replace the ones that list shows. Treat earlier claims in this conversation that a listed server required authentication or was unavailable as outdated; re-run capability_search before concluding a server cannot be used.\n";
    return std.mem.concat(alloc, u8, &.{ change_header, body.written(), change_footer }) catch return error.OutOfMemory;
}

fn usable(availability: Availability) bool {
    return switch (availability) {
        .ready, .available_on_demand, .discovering => true,
        else => false,
    };
}

fn renderAdditionLine(
    writer: *std.Io.Writer,
    transitions: *usize,
    omitted: *usize,
    name: []const u8,
    availability: Availability,
) Allocator.Error!void {
    if (transitions.* == max_change_notice_transitions) {
        omitted.* += 1;
        return;
    }
    writer.writeAll("  ") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(writer, name) catch return error.OutOfMemory;
    writer.print(": added ({s})\n", .{@tagName(availability)}) catch return error.OutOfMemory;
    transitions.* += 1;
}

fn renderTransitionLine(
    writer: *std.Io.Writer,
    transitions: *usize,
    omitted: *usize,
    name: []const u8,
    before: Availability,
    after: Availability,
    tool_count: ?usize,
) Allocator.Error!void {
    if (transitions.* == max_change_notice_transitions) {
        omitted.* += 1;
        return;
    }
    writer.writeAll("  ") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(writer, name) catch return error.OutOfMemory;
    writer.print(": {s} -> {s}", .{ @tagName(before), @tagName(after) }) catch return error.OutOfMemory;
    if (tool_count) |count| {
        writer.print(" ({d} tools)\n", .{count}) catch return error.OutOfMemory;
    } else {
        writer.writeByte('\n') catch return error.OutOfMemory;
    }
    transitions.* += 1;
}

fn renderRemovalLine(
    writer: *std.Io.Writer,
    transitions: *usize,
    omitted: *usize,
    name: []const u8,
) Allocator.Error!void {
    if (transitions.* == max_change_notice_transitions) {
        omitted.* += 1;
        return;
    }
    writer.writeAll("  ") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(writer, name) catch return error.OutOfMemory;
    writer.writeAll(": removed\n") catch return error.OutOfMemory;
    transitions.* += 1;
}

fn findBaselineEntry(baseline: []const BaselineEntry, name: []const u8) ?BaselineEntry {
    for (baseline) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn findCurrentEntry(current: []const ServerSummary, name: []const u8) ?ServerSummary {
    for (current) |server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

/// The MCP catalog a session's instructions carry (D260). The first render
/// in a session is kept and repeated byte for byte on every later turn, so
/// a server that connects, signs in or fails never rewrites the cached head
/// of the request. How availability differs from it rides in the turn
/// context instead (`changeNotice`). `reset` starts over for a new session.
pub const SessionHead = struct {
    lock: std.Io.Mutex = .init,
    /// The section text, owned by the allocator passed to `instructions`.
    text: ?[]u8 = null,
    baseline: []BaselineEntry = &.{},

    /// Returns the session's catalog section, rendering and keeping
    /// `snapshot` on the first call. The result is owned by `arena`; `gpa`
    /// owns what the head keeps and must be the one passed to `reset`.
    pub fn instructions(self: *SessionHead, gpa: Allocator, arena: Allocator, snapshot: Snapshot) Allocator.Error!PromptSection {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.text) |text| return .{ .text = try arena.dupe(u8, text) };
        const section = try render(arena, snapshot);
        const text = try gpa.dupe(u8, section.text);
        errdefer gpa.free(text);
        const baseline = try gpa.alloc(BaselineEntry, snapshot.servers.len);
        var initialized: usize = 0;
        errdefer {
            for (baseline[0..initialized]) |entry| gpa.free(entry.name);
            gpa.free(baseline);
        }
        for (snapshot.servers, baseline) |server, *entry| {
            entry.* = .{ .name = try gpa.dupe(u8, server.name), .availability = server.availability };
            initialized += 1;
        }
        self.text = text;
        self.baseline = baseline;
        return section;
    }

    /// Returns a note on how `current` differs from the catalog the
    /// instructions show, owned by `arena`, or null when nothing differs or
    /// no turn has rendered the instructions yet. It is the same text for
    /// as long as the difference lasts, so the turn context that carries it
    /// repeats only when it changes (D130).
    pub fn changeNotice(self: *SessionHead, arena: Allocator, current: []const ServerSummary) Allocator.Error!?[]u8 {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.text == null) return null;
        return renderChangeNotice(arena, self.baseline, current);
    }

    pub fn reset(self: *SessionHead, gpa: Allocator) void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.text) |text| gpa.free(text);
        for (self.baseline) |entry| gpa.free(entry.name);
        gpa.free(self.baseline);
        self.text = null;
        self.baseline = &.{};
    }
};

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
        .notice = try alloc.print(
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
        if (server.always_loaded and server.availability == .ready and count > 0) {
            out.writer.writeAll(" loaded=\"true\"") catch return error.OutOfMemory;
        }
    }
    out.writer.writeAll(" />\n") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn truncationMarker(alloc: Allocator, omitted_count: usize) ![]u8 {
    return alloc.print(
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
        always_loaded: bool = false,
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
            .always_loaded = input.always_loaded,
        };
        initialized += 1;
    }
    return .{ .servers = servers };
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
            "A listed server is not a reason to use MCP. Use capability_search only when the task clearly needs a capability not already available locally. Pass the task and an optional exact server name. Call tools advertised after search directly. Use mcp_select_tool when a relevant result is not yet callable. Use returned identities and refine the query when needed.\n" ++
            "<mcp_servers>\n" ++
            "  <server name=\"alpha\" state=\"ready\" tools=\"2\" />\n" ++
            "  <server name=\"zeta\" state=\"authentication_required\" />\n" ++
            "</mcp_servers>\n",
        section.text,
    );
    try std.testing.expectEqual(@as(?[]u8, null), section.notice);
}

test "render marks ready always-loaded servers with visible tools" {
    const alloc = std.testing.allocator;
    var snapshot = try ownedSnapshot(alloc, &.{
        .{ .name = "browser", .availability = .ready, .tool_count = 3, .always_loaded = true },
        .{ .name = "empty", .availability = .ready, .tool_count = 0, .always_loaded = true },
        .{ .name = "lazy", .availability = .ready, .tool_count = 1 },
    });
    defer snapshot.deinit(alloc);

    var section = try render(alloc, snapshot);
    defer section.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, section.text, "<server name=\"browser\" state=\"ready\" tools=\"3\" loaded=\"true\" />") != null);
    try std.testing.expect(std.mem.find(u8, section.text, "<server name=\"empty\" state=\"ready\" tools=\"0\" />") != null);
    try std.testing.expect(std.mem.find(u8, section.text, "<server name=\"lazy\" state=\"ready\" tools=\"1\" />") != null);
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
        testing_allocator.no_resize,
        checkRenderAllocationFailures,
        .{},
    );
}

test "renderChangeNotice stays silent when availability is unchanged" {
    const alloc = std.testing.allocator;
    const baseline = [_]BaselineEntry{
        .{ .name = @constCast("linear"), .availability = .ready },
    };
    const current = [_]ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 12 },
    };

    const notice = try renderChangeNotice(alloc, &baseline, &current);

    try std.testing.expectEqual(@as(?[]u8, null), notice);
}

test "renderChangeNotice reports authentication recovery with tool count" {
    const alloc = std.testing.allocator;
    const baseline = [_]BaselineEntry{
        .{ .name = @constCast("linear"), .availability = .authentication_required },
    };
    const current = [_]ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };

    const notice = try renderChangeNotice(alloc, &baseline, &current);
    defer alloc.free(notice.?);

    try std.testing.expect(std.mem.find(u8, notice.?, "linear: authentication_required -> ready (74 tools)") != null);
    try std.testing.expect(std.mem.find(u8, notice.?, "Treat earlier claims") != null);
}

test "renderChangeNotice reports added and removed servers" {
    const alloc = std.testing.allocator;
    const baseline = [_]BaselineEntry{
        .{ .name = @constCast("slack"), .availability = .ready },
    };
    const current = [_]ServerSummary{
        .{ .name = @constCast("notion"), .availability = .failed },
    };

    const notice = try renderChangeNotice(alloc, &baseline, &current);
    defer alloc.free(notice.?);

    try std.testing.expect(std.mem.find(u8, notice.?, "notion: added (failed)") != null);
    try std.testing.expect(std.mem.find(u8, notice.?, "slack: removed") != null);
}

test "renderChangeNotice bounds the transition list and encodes names" {
    const alloc = std.testing.allocator;
    var baseline: [10]BaselineEntry = undefined;
    var current: [10]ServerSummary = undefined;
    var names: [10][]u8 = undefined;
    for (0..10) |index| {
        names[index] = try alloc.print("server<{d}>", .{index});
    }
    defer for (names) |name| alloc.free(name);
    for (0..10) |index| {
        baseline[index] = .{ .name = names[index], .availability = .failed };
        current[index] = .{ .name = names[index], .availability = .ready };
    }

    const notice = try renderChangeNotice(alloc, &baseline, &current);
    defer alloc.free(notice.?);

    try std.testing.expect(std.mem.find(u8, notice.?, "server&lt;0&gt;: failed -> ready") != null);
    try std.testing.expect(std.mem.find(u8, notice.?, "server&lt;7&gt;: failed -> ready") != null);
    try std.testing.expect(std.mem.find(u8, notice.?, "server&lt;8&gt;") == null);
    try std.testing.expect(std.mem.find(u8, notice.?, "and 2 more changes") != null);
}

test "renderChangeNotice ignores moves between searchable states" {
    const alloc = std.testing.allocator;
    const baseline = [_]BaselineEntry{
        .{ .name = @constCast("fixture"), .availability = .available_on_demand },
        .{ .name = @constCast("linear"), .availability = .discovering },
    };
    const current = [_]ServerSummary{
        .{ .name = @constCast("fixture"), .availability = .ready, .tool_count = 1 },
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };

    try std.testing.expectEqual(@as(?[]u8, null), try renderChangeNotice(alloc, &baseline, &current));
}

test "a session head repeats its first catalog and reports differences apart" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var head: SessionHead = .{};
    defer head.reset(alloc);

    try std.testing.expectEqual(@as(?[]u8, null), try head.changeNotice(arena, &.{}));
    var first = try ownedSnapshot(alloc, &.{
        .{ .name = "fixture", .availability = .available_on_demand },
        .{ .name = "linear", .availability = .authentication_required },
    });
    defer first.deinit(alloc);
    const start = try head.instructions(alloc, arena, first);

    var later = try ownedSnapshot(alloc, &.{
        .{ .name = "fixture", .availability = .ready, .tool_count = 1 },
        .{ .name = "linear", .availability = .authentication_required },
    });
    defer later.deinit(alloc);
    const again = try head.instructions(alloc, arena, later);
    try std.testing.expectEqualStrings(start.text, again.text);
    try std.testing.expect(std.mem.find(u8, again.text, "state=\"available_on_demand\"") != null);
    try std.testing.expectEqual(@as(?[]u8, null), try head.changeNotice(arena, later.servers));

    var signed_in = try ownedSnapshot(alloc, &.{
        .{ .name = "fixture", .availability = .ready, .tool_count = 1 },
        .{ .name = "linear", .availability = .ready, .tool_count = 74 },
    });
    defer signed_in.deinit(alloc);
    const notice = (try head.changeNotice(arena, signed_in.servers)).?;
    try std.testing.expect(std.mem.find(u8, notice, "linear: authentication_required -> ready (74 tools)") != null);
    try std.testing.expect(std.mem.find(u8, notice, "fixture") == null);
    // The same difference renders the same bytes on every turn.
    try std.testing.expectEqualStrings(notice, (try head.changeNotice(arena, signed_in.servers)).?);

    head.reset(alloc);
    const fresh = try head.instructions(alloc, arena, signed_in);
    try std.testing.expect(std.mem.find(u8, fresh.text, "<server name=\"linear\" state=\"ready\" tools=\"74\" />") != null);
}

fn checkSessionHeadAllocationFailures(alloc: Allocator) !void {
    var servers = [_]ServerSummary{
        .{ .name = @constCast("alpha"), .availability = .ready, .tool_count = 2 },
        .{ .name = @constCast("beta"), .availability = .failed },
    };
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    var head: SessionHead = .{};
    defer head.reset(alloc);
    _ = try head.instructions(alloc, arena_state.allocator(), .{ .servers = &servers });
}

test "a session head cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkSessionHeadAllocationFailures,
        .{},
    );
}
