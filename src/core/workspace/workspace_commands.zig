const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const workspace_access = @import("workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Action = union(enum) {
    add: []const u8,
    remove: []const u8,
    clear,

    fn label(self: Action) []const u8 {
        return switch (self) {
            .add => "add",
            .remove => "remove",
            .clear => "clear",
        };
    }

    fn path(self: Action) ?[]const u8 {
        return switch (self) {
            .add, .remove => |value| value,
            .clear => null,
        };
    }
};

pub const Mutation = struct {
    action: []const u8,
    path: ?[]const u8 = null,
    saved_changed: bool,
    runtime_changed: bool,
    launch_flag_can_restore: bool = false,
};

pub const FailurePhase = enum {
    stage,
    commit,
    reconcile,
};

pub const Reconciliation = union(enum) {
    intended: workspace_access.WorkspaceAccess,
    previous: workspace_access.WorkspaceAccess,
    unconfirmed,

    pub fn deinit(self: *Reconciliation, alloc: Allocator) void {
        switch (self.*) {
            .intended => |*access| access.deinit(alloc),
            .previous => |*access| access.deinit(alloc),
            .unconfirmed => {},
        }
        self.* = .unconfirmed;
    }
};

pub const Updated = struct {
    access: workspace_access.WorkspaceAccess,
    mutation: Mutation,

    fn deinit(self: *Updated, alloc: Allocator) void {
        self.access.deinit(alloc);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    updated: Updated,
    indeterminate: Reconciliation,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .updated => |*updated| updated.deinit(alloc),
            .indeterminate => |*reconciliation| reconciliation.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn execute(
    alloc: Allocator,
    primary_directory: []const u8,
    current: *const workspace_access.WorkspaceAccess,
    action: Action,
    failure_phase: *FailurePhase,
) !Result {
    failure_phase.* = .stage;
    var add_identity: ?[]u8 = null;
    defer if (add_identity) |identity| alloc.free(identity);
    var staged: ?workspace_access.WorkspaceAccess = switch (action) {
        .add => |path| blk: {
            add_identity = try workspace_access.addDirectoryIdentityAlloc(
                alloc,
                primary_directory,
                path,
            );
            break :blk current.stageAddSaved(
                alloc,
                primary_directory,
                add_identity.?,
            ) catch |err| switch (err) {
                error.TooManyDirectories => null,
                else => return err,
            };
        },
        .remove => |path| try current.stageRemove(alloc, primary_directory, path),
        .clear => current.stageClear(),
    };
    defer if (staged) |*access| access.deinit(alloc);

    const runtime_sources = if (staged) |*access| access else current;
    var command_line: ?[][]u8 = null;
    defer if (command_line) |paths| freeStringSlice(alloc, paths);
    switch (action) {
        .add => command_line = try runtime_sources.commandLineDirectoriesAlloc(alloc),
        .remove, .clear => {},
    }

    const durable_patch: config_runtime.WorkspaceDirectoryMutation = .{
        .workspace_root = primary_directory,
        .observed_sources = current.saved_sources,
        .patch = switch (action) {
            .add => .{ .add = add_identity.? },
            .remove => .{ .remove = removedPath(current, &staged.?) orelse return error.UnknownAdditionalDirectory },
            .clear => .clear,
        },
        .command_line_directories = command_line orelse &.{},
    };

    failure_phase.* = .commit;
    var outcome = config_runtime.mutateWorkspaceDirectory(
        alloc,
        durable_patch,
    ) catch |err| {
        if (err != error.SettingsCommitIndeterminate) return err;
        failure_phase.* = .reconcile;
        const intended = if (staged) |*access| access else return .{ .indeterminate = .unconfirmed };
        return .{ .indeterminate = try reconcileWorkspaceAccess(
            alloc,
            primary_directory,
            current,
            intended,
        ) };
    };
    defer outcome.deinit(alloc);

    failure_phase.* = .reconcile;
    var committed = try loadCommittedWorkspaceAccess(
        alloc,
        primary_directory,
        runtime_sources,
    );
    errdefer committed.deinit(alloc);

    const updated = Updated{
        .access = committed,
        .mutation = .{
            .action = action.label(),
            .path = action.path(),
            .saved_changed = switch (outcome) {
                .committed => true,
                .unchanged => false,
            },
            .runtime_changed = !current.eql(&committed),
            .launch_flag_can_restore = current.commandLineSourceRemoved(&committed),
        },
    };
    committed = .{};
    return .{ .updated = updated };
}

fn removedPath(
    current: *const workspace_access.WorkspaceAccess,
    staged: *const workspace_access.WorkspaceAccess,
) ?[]const u8 {
    for (current.entries) |entry| {
        var retained = false;
        for (staged.entries) |candidate| {
            if (std.mem.eql(u8, entry.path, candidate.path)) {
                retained = true;
                break;
            }
        }
        if (!retained) return entry.path;
    }
    return null;
}

fn loadCommittedWorkspaceAccess(
    alloc: Allocator,
    primary_directory: []const u8,
    staged: *const workspace_access.WorkspaceAccess,
) !workspace_access.WorkspaceAccess {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary_directory);
    defer detailed.deinit(alloc);
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.cause == .invalid_additional_directories) return error.InvalidSettingsFormat;
    }

    const command_line = try staged.commandLineDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, command_line);
    return workspace_access.WorkspaceAccess.init(
        alloc,
        primary_directory,
        detailed.additional_directory_sources orelse &.{},
        command_line,
        staged.saved_suppressed,
    );
}

/// Reloads durable roots after an indeterminate settings commit and accepts
/// only the intended or previous saved state.
fn reconcileWorkspaceAccess(
    alloc: Allocator,
    primary_directory: []const u8,
    current: *const workspace_access.WorkspaceAccess,
    intended: *const workspace_access.WorkspaceAccess,
) !Reconciliation {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary_directory);
    defer detailed.deinit(alloc);

    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.cause == .invalid_additional_directories) return .unconfirmed;
    }
    return classifyDurableState(
        alloc,
        current,
        intended,
        detailed.additional_directories orelse &.{},
    );
}

fn classifyDurableState(
    alloc: Allocator,
    current: *const workspace_access.WorkspaceAccess,
    intended: *const workspace_access.WorkspaceAccess,
    durable: []const []const u8,
) !Reconciliation {
    const current_saved = try current.savedDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, current_saved);
    const intended_saved = try intended.savedDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, intended_saved);

    if (stringSlicesEqual(durable, intended_saved)) {
        return .{ .intended = try intended.clone(alloc) };
    }
    if (stringSlicesEqual(durable, current_saved)) {
        return .{ .previous = try current.clone(alloc) };
    }
    return .unconfirmed;
}

fn stringSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn freeStringSlice(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

test "shared workspace mutation owns staging persistence metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);

    var environ = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer environ.deinit();

    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{},
        &.{},
        false,
    );
    defer current.deinit(alloc);

    var failure_phase: FailurePhase = .stage;
    var result = try execute(alloc, primary, &current, .{ .add = shared }, &failure_phase);
    defer result.deinit(alloc);
    switch (result) {
        .updated => |updated| {
            try std.testing.expectEqualStrings("add", updated.mutation.action);
            try std.testing.expectEqualStrings(shared, updated.mutation.path.?);
            try std.testing.expect(updated.mutation.saved_changed);
            try std.testing.expect(updated.mutation.runtime_changed);
            try std.testing.expectEqual(@as(usize, 1), updated.access.entries.len);
        },
        .indeterminate => return error.TestExpectedEqual,
    }
}

test "shared workspace mutations apply stale actions to the latest durable roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "added", .default_dir);
    try tmp.dir.createDir(std.testing.io, "launch", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);
    const launch = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "launch");
    defer alloc.free(launch);

    var saved: [workspace_access.max_additional_directories - 1][]u8 = undefined;
    var initialized: usize = 0;
    defer for (saved[0..initialized]) |path| alloc.free(path);
    for (&saved, 0..) |*path, index| {
        const name = try alloc.print("saved-{d}", .{index});
        defer alloc.free(name);
        try tmp.dir.createDir(std.testing.io, name, .default_dir);
        path.* = try io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
        initialized += 1;
    }

    var environ = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer environ.deinit();

    var first = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &saved,
        &.{launch},
        false,
    );
    defer first.deinit(alloc);
    var stale_second = try first.clone(alloc);
    defer stale_second.deinit(alloc);

    try writeWorkspaceDirectoriesFixture(
        alloc,
        tmp.dir,
        "home/.fx/settings.json",
        primary,
        &saved,
    );

    var failure_phase: FailurePhase = .stage;
    var remove_result = try execute(
        alloc,
        primary,
        &first,
        .{ .remove = saved[0] },
        &failure_phase,
    );
    defer remove_result.deinit(alloc);
    var add_result = try execute(
        alloc,
        primary,
        &stale_second,
        .{ .add = added },
        &failure_phase,
    );
    defer add_result.deinit(alloc);
    switch (add_result) {
        .updated => |updated| {
            try std.testing.expectEqual(workspace_access.max_additional_directories, updated.access.entries.len);
            try std.testing.expect(updated.access.entries[workspace_access.max_additional_directories - 1].command_line);
            try std.testing.expectEqualStrings(
                launch,
                updated.access.entries[workspace_access.max_additional_directories - 1].path,
            );
        },
        .indeterminate => return error.TestExpectedEqual,
    }

    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary);
    defer detailed.deinit(alloc);
    try std.testing.expectEqual(workspace_access.max_additional_directories - 1, detailed.additional_directories.?.len);
    try std.testing.expectEqualStrings(saved[1], detailed.additional_directories.?[0]);
    try std.testing.expectEqualStrings(added, detailed.additional_directories.?[workspace_access.max_additional_directories - 2]);
}

test "workspace add rejects effective capacity before changing settings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "added", .default_dir);
    try tmp.dir.createDir(std.testing.io, "launch", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);
    const launch = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "launch");
    defer alloc.free(launch);

    var saved: [workspace_access.max_additional_directories - 1][]u8 = undefined;
    var initialized: usize = 0;
    defer for (saved[0..initialized]) |path| alloc.free(path);
    for (&saved, 0..) |*path, index| {
        const name = try alloc.print("saved-{d}", .{index});
        defer alloc.free(name);
        try tmp.dir.createDir(std.testing.io, name, .default_dir);
        path.* = try io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
        initialized += 1;
    }

    var environ = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer environ.deinit();

    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &saved,
        &.{launch},
        false,
    );
    defer current.deinit(alloc);
    try writeWorkspaceDirectoriesFixture(
        alloc,
        tmp.dir,
        "home/.fx/settings.json",
        primary,
        &saved,
    );
    const before = try readFixtureFile(alloc, tmp.dir, "home/.fx/settings.json");
    defer alloc.free(before);

    var failure_phase: FailurePhase = .stage;
    try std.testing.expectError(
        error.TooManyDirectories,
        execute(alloc, primary, &current, .{ .add = added }, &failure_phase),
    );

    const after = try readFixtureFile(alloc, tmp.dir, "home/.fx/settings.json");
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(FailurePhase.commit, failure_phase);
    try std.testing.expectEqual(workspace_access.max_additional_directories, current.entries.len);
    for (current.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.path, added));
    }
}

test "shared workspace mutation removes command line only access without a durable write" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "launch", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const launch = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "launch");
    defer alloc.free(launch);

    var environ = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer environ.deinit();

    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{},
        &.{launch},
        false,
    );
    defer current.deinit(alloc);

    var failure_phase: FailurePhase = .stage;
    var result = try execute(
        alloc,
        primary,
        &current,
        .{ .remove = launch },
        &failure_phase,
    );
    defer result.deinit(alloc);
    switch (result) {
        .updated => |updated| {
            try std.testing.expect(!updated.mutation.saved_changed);
            try std.testing.expect(updated.mutation.runtime_changed);
            try std.testing.expect(updated.mutation.launch_flag_can_restore);
            try std.testing.expectEqual(@as(usize, 0), updated.access.entries.len);
        },
        .indeterminate => return error.TestExpectedEqual,
    }

    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary);
    defer detailed.deinit(alloc);
    try std.testing.expect(detailed.additional_directories == null);
}

test "shared workspace mutation classifies indeterminate durable state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "previous", .default_dir);
    try tmp.dir.createDir(std.testing.io, "intended", .default_dir);

    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const previous = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "previous");
    defer alloc.free(previous);
    const intended_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "intended");
    defer alloc.free(intended_path);

    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{previous},
        &.{},
        false,
    );
    defer current.deinit(alloc);
    var intended = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{intended_path},
        &.{},
        false,
    );
    defer intended.deinit(alloc);

    var reconciliation = try classifyDurableState(
        alloc,
        &current,
        &intended,
        &.{intended_path},
    );
    defer reconciliation.deinit(alloc);
    switch (reconciliation) {
        .intended => |access| try std.testing.expectEqualStrings(intended_path, access.entries[0].path),
        .previous, .unconfirmed => return error.TestExpectedEqual,
    }
}

test "workspace access reconciliation accepts only intended or previous saved state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "previous", .default_dir);
    try tmp.dir.createDir(std.testing.io, "launch", .default_dir);
    try tmp.dir.createDir(std.testing.io, "third", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const previous = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "previous");
    defer alloc.free(previous);
    const launch = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "launch");
    defer alloc.free(launch);
    const third = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "third");
    defer alloc.free(third);

    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{previous},
        &.{launch},
        false,
    );
    defer current.deinit(alloc);
    var intended = current.stageClear();
    defer intended.deinit(alloc);
    var env = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer env.deinit();

    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", "{}\n");
    var intended_result = try reconcileWorkspaceAccess(alloc, primary, &current, &intended);
    defer intended_result.deinit(alloc);
    switch (intended_result) {
        .intended => |access| try std.testing.expectEqual(@as(usize, 0), access.entries.len),
        else => return error.TestExpectedEqual,
    }

    const previous_fixture = try alloc.print(
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\"]}}}}}}\n",
        .{ primary, previous },
    );
    defer alloc.free(previous_fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", previous_fixture);
    var previous_result = try reconcileWorkspaceAccess(alloc, primary, &current, &intended);
    defer previous_result.deinit(alloc);
    switch (previous_result) {
        .previous => |access| {
            try std.testing.expectEqual(@as(usize, 2), access.entries.len);
            try std.testing.expect(access.entries[1].command_line);
        },
        else => return error.TestExpectedEqual,
    }

    const third_fixture = try alloc.print(
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\"]}}}}}}\n",
        .{ primary, third },
    );
    defer alloc.free(third_fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", third_fixture);
    var third_result = try reconcileWorkspaceAccess(alloc, primary, &current, &intended);
    defer third_result.deinit(alloc);
    try std.testing.expect(third_result == .unconfirmed);

    const invalid_fixture = try alloc.print(
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\",\"{s}\"]}}}}}}\n",
        .{ primary, previous, previous },
    );
    defer alloc.free(invalid_fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", invalid_fixture);
    var invalid_result = try reconcileWorkspaceAccess(alloc, primary, &current, &intended);
    defer invalid_result.deinit(alloc);
    try std.testing.expect(invalid_result == .unconfirmed);
}

test "workspace access reconciliation rejects a retargeted durable source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    tmp.dir.symLink(std.testing.io, "first", "saved-link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const source = try std.Io.Dir.path.resolveAlloc(alloc, &.{ primary, "../saved-link" });
    defer alloc.free(source);
    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{source},
        &.{},
        false,
    );
    defer current.deinit(alloc);
    var intended = current.stageClear();
    defer intended.deinit(alloc);
    var env = try TestEnv.install(alloc, &.{.{ .key = "HOME", .value = home }});
    defer env.deinit();

    const fixture = try alloc.print(
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\"]}}}}}}\n",
        .{ primary, source },
    );
    defer alloc.free(fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", fixture);
    try tmp.dir.deleteFile(std.testing.io, "saved-link");
    try tmp.dir.symLink(std.testing.io, "second", "saved-link", .{ .is_directory = true });

    var result = try reconcileWorkspaceAccess(alloc, primary, &current, &intended);
    defer result.deinit(alloc);
    try std.testing.expect(result == .unconfirmed);
}

test "shared workspace mutation reports the failing transaction phase" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);

    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    var current = try workspace_access.WorkspaceAccess.init(
        alloc,
        primary,
        &.{},
        &.{},
        false,
    );
    defer current.deinit(alloc);

    var phase: FailurePhase = .commit;
    try std.testing.expectError(
        error.PrimaryDirectory,
        execute(alloc, primary, &current, .{ .add = primary }, &phase),
    );
    try std.testing.expectEqual(FailurePhase.stage, phase);

    var environ = try TestEnv.install(alloc, &.{});
    defer environ.deinit();
    try std.testing.expectError(
        error.HomeNotSet,
        execute(alloc, primary, &current, .{ .add = shared }, &phase),
    );
    try std.testing.expectEqual(FailurePhase.commit, phase);
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn readFixtureFile(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024);
}

fn writeWorkspaceDirectoriesFixture(
    alloc: Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    workspace_root: []const u8,
    directories: []const []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"workspaces\":{");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(":{\"additional_directories\":[");
    for (directories, 0..) |directory, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(directory, .{}, &out.writer);
    }
    try out.writer.writeAll("]}}}\n");
    try writeFixtureFile(dir, sub_path, out.written());
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const EnvEntry) !*TestEnv {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        for (entries) |entry| try self.map.put(entry.key, entry.value);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        if (stable_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};
