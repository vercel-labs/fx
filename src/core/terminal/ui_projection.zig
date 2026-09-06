const std = @import("std");
const contracts = @import("contracts.zig");

const Allocator = std.mem.Allocator;

pub const Row = struct {
    session_id: []u8,
    label: []u8,
    lifecycle: contracts.Lifecycle,
    attention: contracts.AttentionState,
    backend: contracts.Backend,
    attachable: bool = true,

    fn deinit(self: *Row, alloc: Allocator) void {
        alloc.free(self.label);
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    alloc: Allocator,
    rows: []Row,

    pub fn deinit(self: *Snapshot) void {
        for (self.rows) |*row| row.deinit(self.alloc);
        self.alloc.free(self.rows);
        self.* = undefined;
    }
};

pub const BackgroundStatus = struct {
    count: usize = 0,
    running: bool = false,
};

pub fn backgroundStatus(rows: []const Row) BackgroundStatus {
    var result: BackgroundStatus = .{};
    for (rows) |row| {
        if (row.lifecycle != .running or row.attention.attention != .background) {
            continue;
        }
        result.count += 1;
        result.running = true;
    }
    return result;
}

pub const Store = struct {
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
        self.* = .{};
    }

    pub fn observe(
        self: *Store,
        alloc: Allocator,
        request: contracts.ActionRequest,
        result: contracts.Result,
    ) !void {
        const success = switch (result) {
            .success => |value| value,
            .failure => return,
        };
        switch (success) {
            .list => |value| switch (request) {
                .list => |filters| if (filters.task_id == null and
                    filters.workspace_root == null and filters.lifecycle == null and
                    filters.backend == null)
                {
                    try self.replaceAll(alloc, value.sessions);
                } else for (value.sessions) |facts| {
                    try self.upsert(alloc, facts, null);
                },
                else => unreachable,
            },
            .inspect => |value| try self.upsert(
                alloc,
                value.session,
                value.command orelse value.shell,
            ),
            .start => |value| try self.upsert(alloc, value.session, labelFromRequest(request)),
            .read => |value| try self.upsert(alloc, value.session, null),
            .screen => |value| try self.upsert(alloc, value.session, null),
            .write => |value| try self.upsert(alloc, value.session, null),
            .wait => |value| try self.upsert(alloc, value.session, null),
            .resize => |value| try self.upsert(alloc, value.session, null),
            .signal => |value| try self.upsert(alloc, value.session, null),
            .close => |value| try self.upsert(alloc, value.session, null),
        }
    }

    pub fn snapshot(self: *const Store, alloc: Allocator) !Snapshot {
        const rows = try alloc.alloc(Row, self.rows.items.len);
        var initialized: usize = 0;
        errdefer {
            for (rows[0..initialized]) |*row| row.deinit(alloc);
            alloc.free(rows);
        }
        for (self.rows.items, rows) |source, *target| {
            const session_id = try alloc.dupe(u8, source.session_id);
            errdefer alloc.free(session_id);
            target.* = .{
                .session_id = session_id,
                .label = try alloc.dupe(u8, source.label),
                .lifecycle = source.lifecycle,
                .attention = source.attention,
                .backend = source.backend,
            };
            initialized += 1;
        }
        return .{ .alloc = alloc, .rows = rows };
    }

    pub fn clear(self: *Store, alloc: Allocator) bool {
        if (self.rows.items.len == 0) return false;
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.clearRetainingCapacity();
        return true;
    }

    fn replaceAll(
        self: *Store,
        alloc: Allocator,
        sessions: []const contracts.SessionFacts,
    ) !void {
        var replacement: Store = .{};
        errdefer replacement.deinit(alloc);
        for (sessions) |facts| {
            var label: ?[]const u8 = null;
            for (self.rows.items) |row| {
                if (std.mem.eql(u8, row.session_id, facts.session_id)) {
                    label = row.label;
                    break;
                }
            }
            try replacement.upsert(alloc, facts, label);
        }
        var previous = self.*;
        self.* = replacement;
        previous.deinit(alloc);
    }

    fn upsert(
        self: *Store,
        alloc: Allocator,
        facts: contracts.SessionFacts,
        label: ?[]const u8,
    ) !void {
        for (self.rows.items) |*row| {
            if (!std.mem.eql(u8, row.session_id, facts.session_id)) continue;
            if (label) |value| {
                const replacement = try alloc.dupe(u8, value);
                alloc.free(row.label);
                row.label = replacement;
            }
            row.lifecycle = facts.lifecycle;
            row.attention = facts.attention;
            row.backend = facts.backend;
            return;
        }
        const session_id = try alloc.dupe(u8, facts.session_id);
        errdefer alloc.free(session_id);
        const display = label orelse facts.session_id;
        const display_copy = try alloc.dupe(u8, display);
        errdefer alloc.free(display_copy);
        try self.rows.append(alloc, .{
            .session_id = session_id,
            .label = display_copy,
            .lifecycle = facts.lifecycle,
            .attention = facts.attention,
            .backend = facts.backend,
        });
    }
};

fn labelFromRequest(request: contracts.ActionRequest) ?[]const u8 {
    return switch (request) {
        .start => |value| value.command orelse switch (value.shell) {
            .user_login => "interactive shell",
            .executable => |shell| shell.path,
        },
        else => null,
    };
}

test "background status counts only running background terminal sessions" {
    const rows = [_]Row{
        .{ .session_id = @constCast("a"), .label = @constCast("a"), .lifecycle = .running, .attention = .{}, .backend = .native },
        .{ .session_id = @constCast("b"), .label = @constCast("b"), .lifecycle = .running, .attention = .{ .attention = .agent_wait, .write_lease = .agent }, .backend = .native },
        .{ .session_id = @constCast("c"), .label = @constCast("c"), .lifecycle = .exited, .attention = .{}, .backend = .tmux },
        .{ .session_id = @constCast("d"), .label = @constCast("d"), .lifecycle = .running, .attention = .{ .attention = .user_takeover, .write_lease = .human }, .backend = .native },
        .{ .session_id = @constCast("e"), .label = @constCast("e"), .lifecycle = .starting, .attention = .{}, .backend = .native },
        .{ .session_id = @constCast("f"), .label = @constCast("f"), .lifecycle = .closed, .attention = .{}, .backend = .tmux },
    };
    const status = backgroundStatus(&rows);
    try std.testing.expectEqual(@as(usize, 1), status.count);
    try std.testing.expect(status.running);
}

test "filtered catalog observations update rows without replacing the full projection" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const full = [_]contracts.SessionFacts{
        testFacts("terminal-a", .running),
        testFacts("terminal-b", .starting),
    };
    try store.observe(
        alloc,
        .{ .list = .{} },
        .{ .success = .{ .list = .{ .sessions = &full } } },
    );

    const partial = [_]contracts.SessionFacts{
        testFacts("terminal-b", .running),
    };
    try store.observe(
        alloc,
        .{ .list = .{ .lifecycle = .running } },
        .{ .success = .{ .list = .{ .sessions = &partial } } },
    );
    var snapshot = try store.snapshot(alloc);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.rows.len);
    try std.testing.expectEqual(contracts.Lifecycle.running, snapshot.rows[1].lifecycle);
}

fn checkUpsertAllocationFailures(alloc: Allocator) !void {
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.upsert(
        alloc,
        testFacts("terminal-a", .running),
        "display label",
    );
}

test "upsert releases owned row fields on every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkUpsertAllocationFailures,
        .{},
    );
}

fn testFacts(
    session_id: []const u8,
    lifecycle: contracts.Lifecycle,
) contracts.SessionFacts {
    return .{
        .session_id = session_id,
        .lifecycle = lifecycle,
        .attention = .{},
        .backend = .native,
        .output_cursor = .{ .segment = 1, .offset = 0 },
        .screen_recovery = .{ .unavailable = .missing },
    };
}
