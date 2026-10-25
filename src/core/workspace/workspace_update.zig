//! Applies one `/workspace` change to a live session and says what happened.
//! The terminal app and the ACP host both run `/workspace`, so the outcome and
//! its words live here once.
const std = @import("std");
const types = @import("../shared/types.zig");
const output_contracts = @import("../output/output_contracts.zig");
const workspace_access = @import("workspace_access.zig");
const workspace_commands = @import("workspace_commands.zig");

const Allocator = std.mem.Allocator;

/// What a workspace change did, as the notice a user reads.
pub const Report = struct {
    /// Neutral for the new workspace listing, a warning when the saved
    /// settings may not match, an error when nothing changed.
    tone: types.NoticeTone,
    /// Owned by the allocator passed to `apply`.
    text: []u8,
};

/// Runs `action` against `host`'s live access and installs the access that
/// results. `host` provides `workspaceAccess() *const WorkspaceAccess` and
/// `installWorkspaceAccess(*WorkspaceAccess)`, which takes what it installs
/// and leaves the argument empty.
pub fn apply(
    alloc: Allocator,
    primary_directory: []const u8,
    host: anytype,
    action: workspace_commands.Action,
) !Report {
    var phase: workspace_commands.FailurePhase = .stage;
    var result = workspace_commands.execute(alloc, primary_directory, host.workspaceAccess(), action, &phase) catch |err| {
        const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace update failed";
        const prefix: []const u8 = switch (phase) {
            .stage => "Workspace update rejected",
            .commit => "Workspace settings were not changed",
            .reconcile => "Workspace settings are uncertain and could not be reloaded",
        };
        return .{ .tone = .@"error", .text = try alloc.print("{s}: {s}", .{ prefix, reason }) };
    };
    defer result.deinit(alloc);

    switch (result) {
        .updated => |*updated| {
            _ = host.installWorkspaceAccess(&updated.access);
            return .{
                .tone = .neutral,
                .text = try snapshotText(alloc, primary_directory, host.workspaceAccess(), updated.mutation),
            };
        },
        .indeterminate => |*reconciliation| {
            const text: []const u8 = switch (reconciliation.*) {
                .intended => |*reconciled| blk: {
                    _ = host.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the requested update.";
                },
                .previous => |*reconciled| blk: {
                    _ = host.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the previous state, so the update is not active.";
                },
                .unconfirmed => "Workspace settings durability is uncertain; reloaded settings match neither the requested nor previous state, so runtime access is unchanged.",
            };
            return .{ .tone = .warning, .text = try alloc.dupe(u8, text) };
        },
    }
}

/// The workspace listing `/workspace` prints, with the change that led to it
/// when there was one. Caller owns the text.
pub fn snapshotText(
    alloc: Allocator,
    primary_directory: []const u8,
    access: *const workspace_access.WorkspaceAccess,
    mutation: ?workspace_commands.Mutation,
) ![]u8 {
    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(primary_directory, access);
    snapshot.mutation = mutation;
    return snapshot.renderInteractiveBody(alloc);
}

test "apply reports a rejected change as an error and installs nothing" {
    const alloc = std.testing.allocator;
    const Host = struct {
        access: workspace_access.WorkspaceAccess = .{},
        installs: usize = 0,

        pub fn workspaceAccess(self: *@This()) *const workspace_access.WorkspaceAccess {
            return &self.access;
        }

        pub fn installWorkspaceAccess(self: *@This(), access: *workspace_access.WorkspaceAccess) void {
            self.installs += 1;
            self.access.deinit(alloc);
            self.access = access.*;
            access.* = .{};
        }
    };
    var host: Host = .{};
    defer host.access.deinit(alloc);

    // Removing a directory the session never added changes nothing.
    const report = try apply(alloc, "/tmp/primary", &host, .{ .remove = "/tmp/never-added" });
    defer alloc.free(report.text);
    try std.testing.expectEqual(types.NoticeTone.@"error", report.tone);
    try std.testing.expect(std.mem.startsWith(u8, report.text, "Workspace update rejected: "));
    try std.testing.expectEqual(@as(usize, 0), host.installs);
}
