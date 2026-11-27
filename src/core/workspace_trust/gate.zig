//! State of the "Folder access" screen at startup: which saved answer covers
//! the start folder, whether the screen asks, the rows it lists, and what a
//! Yes does. The Gate owns its strings; the prompt borrows them. No App needed.

const std = @import("std");
const workspace_trust = @import("workspace_trust.zig");
const prompt = @import("prompt.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const trace_scope = "workspace_trust";

/// What a folder holds that can change what fx does, for the screen's list.
pub const SkillRoot = struct { path: []const u8, count: usize }; // path is static, such as ".fx/skills"

pub const Facts = struct {
    agents_md: bool = false,
    agent_profiles: bool = false,
    skill_roots: []const SkillRoot = &.{},
    mcp_servers: usize = 0,
    mcp_pending: usize = 0,
};

/// How a Yes ended.
pub const Allowed = union(enum) {
    saved,
    session_only,
    /// The folder is allowed for this session only; the answer was not saved.
    not_saved: anyerror,
};

pub const Gate = struct {
    /// Owned: the start folder as given.
    folder: []u8 = &.{},
    /// Owned: the folder whose saved answer covers `folder`.
    key: []u8 = &.{},
    places: workspace_trust.OwnedPlaces = .{},
    scope_session_only: bool = false,
    /// Borrows `folder`, `key` and `rows`. Shown only while set.
    prompt: ?prompt.Prompt = null,
    rows: std.ArrayList(prompt.Row) = .empty,
    /// Owned: each row's detail is one of these strings.
    details: std.ArrayList([]u8) = .empty,

    pub fn open(alloc: std.mem.Allocator, start: []const u8, home: ?[]const u8, skip: bool) error{OutOfMemory}!Gate {
        var gate: Gate = .{};
        errdefer gate.deinit(alloc);
        gate.folder = try alloc.dupe(u8, start);
        if (skip) {
            gate.scope_session_only = true;
            return gate;
        }
        gate.places = try workspace_trust.resolvePlaces(alloc, home);
        gate.key = try workspace_trust.resolveKey(alloc, start, gate.places.places());
        const scope = workspace_trust.scopeFor(gate.key, gate.places.places());
        gate.scope_session_only = switch (scope) {
            .session_only => true,
            .saved => false,
        };
        const trusted = switch (scope) {
            .session_only => false,
            .saved => |key| try savedTrust(alloc, home, key),
        };
        if (workspace_trust.decide(scope, trusted) == .proceed) return gate;
        gate.prompt = .{
            .folder = gate.folder,
            .cover = workspace_trust.coverFor(start, gate.key, scope, gate.places.places()),
        };
        return gate;
    }

    pub fn asking(self: *const Gate) bool {
        return self.prompt != null;
    }

    pub fn press(self: *Gate, input: prompt.Input) prompt.Outcome {
        if (self.prompt) |*shown| return shown.press(input);
        return .stay;
    }

    /// Ends the screen. A saved answer that fails is logged and the session
    /// goes on with the folder trusted.
    pub fn allow(self: *Gate, alloc: std.mem.Allocator, home: ?[]const u8) Allowed {
        self.prompt = null;
        if (self.scope_session_only) return .session_only;
        const home_path = home orelse return notSaved(self.key, error.HomeNotSet);
        var attempt = config_runtime.attemptWorkspaceTrustInHome(alloc, home_path, self.key);
        defer attempt.deinit(alloc);
        switch (attempt) {
            .outcome => return .saved,
            .failure => |failure| return notSaved(self.key, failure.err),
        }
    }

    pub fn setFacts(self: *Gate, alloc: std.mem.Allocator, facts: Facts) error{OutOfMemory}!void {
        var rows: std.ArrayList(prompt.Row) = .empty;
        var details: std.ArrayList([]u8) = .empty;
        errdefer freeRows(alloc, &rows, &details);
        try appendFactRows(alloc, &rows, &details, facts);
        freeRows(alloc, &self.rows, &self.details);
        self.rows = rows;
        self.details = details;
        if (self.prompt) |*shown| shown.rows = self.rows.items;
    }

    pub fn deinit(self: *Gate, alloc: std.mem.Allocator) void {
        freeRows(alloc, &self.rows, &self.details);
        self.places.deinit(alloc);
        alloc.free(self.key);
        alloc.free(self.folder);
        self.* = .{};
    }
};

fn savedTrust(alloc: std.mem.Allocator, home: ?[]const u8, key: []const u8) error{OutOfMemory}!bool {
    const home_path = home orelse return false;
    return config_runtime.loadWorkspaceTrustFromHome(alloc, home_path, key) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(trace_scope, "saved answer not read, the folder asks: {s}", .{@errorName(err)});
        return false;
    };
}

fn notSaved(key: []const u8, err: anyerror) Allowed {
    debug_trace.logf(trace_scope, "answer not saved for {s}, the folder asks next start: {s}", .{ key, @errorName(err) });
    return .{ .not_saved = err };
}

fn appendFactRows(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList(prompt.Row),
    details: *std.ArrayList([]u8),
    facts: Facts,
) error{OutOfMemory}!void {
    if (facts.agents_md) {
        try addRow(alloc, rows, details, "AGENTS.md", "instructions for the agent", .{});
    }
    if (facts.agent_profiles) {
        try addRow(alloc, rows, details, ".fx/agents", "agent profiles", .{});
    }
    for (facts.skill_roots) |root| {
        if (root.count == 0) continue;
        try addRow(alloc, rows, details, root.path, "{d} {s}", .{ root.count, skillNoun(root.count) });
    }
    if (facts.mcp_servers > 0) {
        try appendMcpRow(alloc, rows, details, facts.mcp_servers, facts.mcp_pending);
    }
}

fn skillNoun(count: usize) []const u8 {
    return if (count == 1) "skill" else "skills";
}

fn appendMcpRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList(prompt.Row),
    details: *std.ArrayList([]u8),
    total: usize,
    pending: usize,
) error{OutOfMemory}!void {
    const name = ".mcp.json";
    if (pending == total) {
        if (total == 1) return addRow(alloc, rows, details, name, "1 MCP server, it needs your approval", .{});
        return addRow(alloc, rows, details, name, "{d} MCP servers, each needs your approval", .{total});
    }
    if (pending == 0) {
        return addRow(alloc, rows, details, name, "{d} MCP {s}", .{ total, if (total == 1) "server" else "servers" });
    }
    if (pending == 1) return addRow(alloc, rows, details, name, "{d} MCP servers, 1 needs your approval", .{total});
    return addRow(alloc, rows, details, name, "{d} MCP servers, {d} need your approval", .{ total, pending });
}

fn addRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList(prompt.Row),
    details: *std.ArrayList([]u8),
    name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    try rows.ensureUnusedCapacity(alloc, 1);
    try details.ensureUnusedCapacity(alloc, 1);
    const detail = try alloc.print(fmt, args);
    details.appendAssumeCapacity(detail);
    rows.appendAssumeCapacity(.{ .name = name, .detail = detail });
}

fn freeRows(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList(prompt.Row),
    details: *std.ArrayList([]u8),
) void {
    for (details.items) |detail| alloc.free(detail);
    details.deinit(alloc);
    rows.deinit(alloc);
    details.* = .empty;
    rows.* = .empty;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn expectAllowed(expected: std.meta.Tag(Allowed), actual: Allowed) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}

fn expectRow(row: prompt.Row, name: []const u8, detail: []const u8) !void {
    try std.testing.expectEqualStrings(name, row.name);
    try std.testing.expectEqualStrings(detail, row.detail);
}

test "a trusted folder opens no screen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    const settings = try alloc.print("{{\"workspaces\":{{\"{s}/repo\":{{\"trusted\":true}}}}}}", .{base});
    defer alloc.free(settings);
    try writeTestFile(tmp.dir, "home/.fx/settings.json", settings);
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try std.testing.expect(!gate.asking());
}

test "an unknown folder asks and covers its repository" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const repo = try std.Io.Dir.path.join(alloc, &.{ base, "repo" });
    defer alloc.free(repo);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try std.testing.expect(gate.asking());
    const shown = gate.prompt.?;
    try std.testing.expectEqualStrings(start, shown.folder);
    switch (shown.cover) {
        .whole_repository => |path| try std.testing.expectEqualStrings(repo, path),
        else => return error.TestUnexpectedResult,
    }
}

test "a yes is saved and the next start does not ask" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var first = try Gate.open(alloc, start, home, false);
    defer first.deinit(alloc);
    try std.testing.expect(first.asking());
    try expectAllowed(.saved, first.allow(alloc, home));
    try std.testing.expect(!first.asking());

    var second = try Gate.open(alloc, start, home, false);
    defer second.deinit(alloc);
    try std.testing.expect(!second.asking());

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "home/.fx/settings.json", alloc, .limited(64 * 1024));
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes, 1, "\"trusted\":true"));
}

test "the home folder asks every time and is never saved" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);

    var gate = try Gate.open(alloc, home, home, false);
    defer gate.deinit(alloc);
    try std.testing.expect(gate.asking());
    switch (gate.prompt.?.cover) {
        .home_folder => {},
        else => return error.TestUnexpectedResult,
    }
    try expectAllowed(.session_only, gate.allow(alloc, home));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "home/.fx/settings.json", .{}));

    var again = try Gate.open(alloc, home, home, false);
    defer again.deinit(alloc);
    try std.testing.expect(again.asking());
}

test "a failed save keeps this session going and says why" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try writeTestFile(tmp.dir, "home/.fx", "not a folder");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ base, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try std.testing.expect(gate.asking());
    try expectAllowed(.not_saved, gate.allow(alloc, home));
    try std.testing.expect(!gate.asking());

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(64 * 1024));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.containsAtLeast(u8, trace, 1, "answer not saved"));
}

test "skip opens no screen and reads nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, true);
    defer gate.deinit(alloc);
    try std.testing.expect(!gate.asking());
    try std.testing.expectEqual(@as(usize, 0), gate.key.len);
}

test "a broken settings file asks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try writeTestFile(tmp.dir, "home/.fx/settings.json", "{not json");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try std.testing.expect(gate.asking());
}

test "facts become rows in a fixed order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try gate.setFacts(alloc, .{
        .agents_md = true,
        .agent_profiles = true,
        .skill_roots = &.{
            .{ .path = ".fx/skills", .count = 3 },
            .{ .path = ".agents/skills", .count = 1 },
            .{ .path = ".claude/skills", .count = 0 },
        },
        .mcp_servers = 2,
        .mcp_pending = 2,
    });
    const first = gate.prompt.?.rows;
    try std.testing.expectEqual(@as(usize, 5), first.len);
    try expectRow(first[0], "AGENTS.md", "instructions for the agent");
    try expectRow(first[1], ".fx/agents", "agent profiles");
    try expectRow(first[2], ".fx/skills", "3 skills");
    try expectRow(first[3], ".agents/skills", "1 skill");
    try expectRow(first[4], ".mcp.json", "2 MCP servers, each needs your approval");

    try gate.setFacts(alloc, .{
        .agents_md = true,
        .agent_profiles = true,
        .skill_roots = &.{
            .{ .path = ".fx/skills", .count = 3 },
            .{ .path = ".agents/skills", .count = 1 },
            .{ .path = ".claude/skills", .count = 0 },
        },
        .mcp_servers = 3,
        .mcp_pending = 1,
    });
    const second = gate.prompt.?.rows;
    try std.testing.expectEqual(@as(usize, 5), second.len);
    try expectRow(second[4], ".mcp.json", "3 MCP servers, 1 needs your approval");
}

test "escape exits and keeps the screen until fx quits" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(base);
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "home");
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "repo", "src" });
    defer alloc.free(start);

    var gate = try Gate.open(alloc, start, home, false);
    defer gate.deinit(alloc);
    try std.testing.expectEqual(prompt.Outcome.exit, gate.press(.cancel));
    try std.testing.expect(gate.asking());
}
