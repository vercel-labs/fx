const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const git_stdout_limit: usize = 1024 * 1024;
const git_stderr_limit: usize = 64 * 1024;

pub const Worktree = struct {
    path: []u8,
    head: []u8,
    branch: ?[]u8 = null,
    detached: bool = false,
    bare: bool = false,
    locked_reason: ?[]u8 = null,
    prunable_reason: ?[]u8 = null,
    primary: bool = false,
    current: bool = false,

    pub fn deinit(self: *Worktree, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.head);
        if (self.branch) |value| alloc.free(value);
        if (self.locked_reason) |value| alloc.free(value);
        if (self.prunable_reason) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const MutationAction = enum {
    create,
    open,
    remove,
};

pub const Mutation = struct {
    action: MutationAction,
    path: []u8,
    branch: ?[]u8 = null,
    changed: bool,
    launch_resume: ?bool = null,

    pub fn deinit(self: *Mutation, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.branch) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn initMutation(
    alloc: Allocator,
    action: MutationAction,
    path: []const u8,
    branch: ?[]const u8,
    changed: bool,
    launch_resume: ?bool,
) !Mutation {
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    const owned_branch = if (branch) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_branch) |value| alloc.free(value);
    return .{
        .action = action,
        .path = owned_path,
        .branch = owned_branch,
        .changed = changed,
        .launch_resume = launch_resume,
    };
}

pub const Snapshot = struct {
    repository_root: []u8,
    current_worktree: []u8,
    worktrees: std.ArrayList(Worktree),
    mutation: ?Mutation = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.repository_root);
        alloc.free(self.current_worktree);
        for (self.worktrees.items) |*entry| entry.deinit(alloc);
        self.worktrees.deinit(alloc);
        if (self.mutation) |*mutation| mutation.deinit(alloc);
        self.* = undefined;
    }
};

pub const Launch = struct {
    path: []u8,
    resume_session: bool,

    pub fn deinit(self: *Launch, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

pub const Ready = struct {
    snapshot: Snapshot,
    launch: ?Launch = null,

    pub fn deinit(self: *Ready, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        if (self.launch) |*launch| launch.deinit(alloc);
        self.* = undefined;
    }
};

pub const FailureCode = enum {
    git_unavailable,
    not_git_repository,
    invalid_branch,
    branch_base_conflict,
    worktree_not_found,
    worktree_ambiguous,
    primary_worktree,
    current_worktree,
    worktree_unavailable,
    git_command_failed,
};

pub const Failure = struct {
    code: FailureCode,
    message: []u8,

    pub fn deinit(self: *Failure, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    ready: Ready,
    failure: Failure,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .ready => |*ready| ready.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const CreateOptions = struct {
    branch: []const u8,
    path: []const u8,
    base: ?[]const u8 = null,
    start: bool = false,
};

pub const OpenOptions = struct {
    selector: []const u8,
    resume_session: bool = false,
};

pub const RemoveOptions = struct {
    selector: []const u8,
    confirmed: bool = false,
    force: bool = false,
};

pub const Action = union(enum) {
    list,
    create: CreateOptions,
    open: OpenOptions,
    remove: RemoveOptions,
};

pub const ParsedCommand = struct {
    action: Action,
    json: bool = false,
};

pub fn parse(args: []const [:0]const u8) !ParsedCommand {
    if (args.len == 0) return .{ .action = .list };
    if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) {
        return .{ .action = .list, .json = true };
    }

    if (std.mem.eql(u8, args[0], "list") or std.mem.eql(u8, args[0], "status")) {
        var json = false;
        for (args[1..]) |arg| {
            if (!std.mem.eql(u8, arg, "--json") or json) return error.InvalidWorktreeArgs;
            json = true;
        }
        return .{ .action = .list, .json = json };
    }

    if (std.mem.eql(u8, args[0], "create")) {
        var branch: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var base: ?[]const u8 = null;
        var start = false;
        var json = false;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--base")) {
                if (base != null or index + 1 >= args.len) return error.InvalidWorktreeArgs;
                index += 1;
                base = args[index];
            } else if (std.mem.eql(u8, arg, "--start")) {
                if (start) return error.InvalidWorktreeArgs;
                start = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                if (json) return error.InvalidWorktreeArgs;
                json = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.InvalidWorktreeArgs;
            } else if (branch == null) {
                branch = arg;
            } else if (path == null) {
                path = arg;
            } else {
                return error.InvalidWorktreeArgs;
            }
        }
        if (start and json) return error.JsonWorktreeLaunchUnsupported;
        return .{
            .action = .{ .create = .{
                .branch = branch orelse return error.InvalidWorktreeArgs,
                .path = path orelse return error.InvalidWorktreeArgs,
                .base = base,
                .start = start,
            } },
            .json = json,
        };
    }

    if (std.mem.eql(u8, args[0], "open")) {
        var selector: ?[]const u8 = null;
        var resume_session = false;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--resume")) {
                if (resume_session) return error.InvalidWorktreeArgs;
                resume_session = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.InvalidWorktreeArgs;
            } else if (selector == null) {
                selector = arg;
            } else {
                return error.InvalidWorktreeArgs;
            }
        }
        return .{ .action = .{ .open = .{
            .selector = selector orelse return error.InvalidWorktreeArgs,
            .resume_session = resume_session,
        } } };
    }

    if (std.mem.eql(u8, args[0], "remove")) {
        var selector: ?[]const u8 = null;
        var confirmed = false;
        var force = false;
        var json = false;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--confirm")) {
                if (confirmed) return error.InvalidWorktreeArgs;
                confirmed = true;
            } else if (std.mem.eql(u8, arg, "--force")) {
                if (force) return error.InvalidWorktreeArgs;
                force = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                if (json) return error.InvalidWorktreeArgs;
                json = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.InvalidWorktreeArgs;
            } else if (selector == null) {
                selector = arg;
            } else {
                return error.InvalidWorktreeArgs;
            }
        }
        const selected = selector orelse return error.InvalidWorktreeArgs;
        if (!confirmed) return error.WorktreeRemovalRequiresConfirmation;
        return .{
            .action = .{ .remove = .{
                .selector = selected,
                .confirmed = confirmed,
                .force = force,
            } },
            .json = json,
        };
    }

    return error.InvalidWorktreeArgs;
}

pub fn execute(alloc: Allocator, action: Action) !Outcome {
    return switch (action) {
        .list => loadOutcome(alloc),
        .create => |options| create(alloc, options),
        .open => |options| open(alloc, options),
        .remove => |options| remove(alloc, options),
    };
}

fn loadOutcome(alloc: Allocator) !Outcome {
    const loaded = try loadSnapshot(alloc);
    return switch (loaded) {
        .snapshot => |snapshot| .{ .ready = .{ .snapshot = snapshot } },
        .failure => |failure| .{ .failure = failure },
        .empty => unreachable,
    };
}

fn create(alloc: Allocator, options: CreateOptions) !Outcome {
    var initial = try loadSnapshot(alloc);
    defer initial.deinit(alloc);
    switch (initial) {
        .failure => return .{ .failure = initial.takeFailure() },
        .snapshot => {},
        .empty => unreachable,
    }

    var branch_check = runGit(alloc, null, &.{ "check-ref-format", "--branch", options.branch }) catch |err| {
        return failureFromRunError(alloc, err);
    };
    defer branch_check.deinit(alloc);
    if (!branch_check.succeeded()) {
        return .{ .failure = try processFailure(alloc, .invalid_branch, &branch_check, "branch name is invalid") };
    }

    const branch_ref = try std.fmt.allocPrint(alloc, "refs/heads/{s}", .{options.branch});
    defer alloc.free(branch_ref);
    var branch_lookup = runGit(alloc, null, &.{ "show-ref", "--verify", "--quiet", branch_ref }) catch |err| {
        return failureFromRunError(alloc, err);
    };
    defer branch_lookup.deinit(alloc);
    const branch_exists = switch (branch_lookup.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => return .{ .failure = try processFailure(alloc, .git_command_failed, &branch_lookup, "git could not check whether the branch exists") },
        },
        else => return .{ .failure = try processFailure(alloc, .git_command_failed, &branch_lookup, "git could not check whether the branch exists") },
    };
    if (branch_exists and options.base != null) {
        return .{ .failure = .{
            .code = .branch_base_conflict,
            .message = try alloc.dupe(u8, "--base cannot be used when the branch already exists"),
        } };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "worktree", "add" });
    if (!branch_exists) try argv.appendSlice(alloc, &.{ "-b", options.branch });
    try argv.append(alloc, options.path);
    if (branch_exists) {
        try argv.append(alloc, options.branch);
    } else if (options.base) |base| {
        try argv.append(alloc, base);
    }

    var result = runGit(alloc, null, argv.items) catch |err| {
        return failureFromRunError(alloc, err);
    };
    defer result.deinit(alloc);
    if (!result.succeeded()) {
        return .{ .failure = try processFailure(alloc, .git_command_failed, &result, "git could not create the worktree") };
    }

    var loaded = try loadSnapshot(alloc);
    defer loaded.deinit(alloc);
    switch (loaded) {
        .failure => return .{ .failure = loaded.takeFailure() },
        .snapshot => |*snapshot| {
            const created_index = findByBranch(snapshot, options.branch) orelse {
                return .{ .failure = .{
                    .code = .worktree_not_found,
                    .message = try alloc.dupe(u8, "git created the worktree but it was not present in the refreshed worktree list"),
                } };
            };
            const created = snapshot.worktrees.items[created_index];
            var launch = if (options.start)
                Launch{ .path = try alloc.dupe(u8, created.path), .resume_session = false }
            else
                null;
            errdefer if (launch) |*value| value.deinit(alloc);
            snapshot.mutation = try initMutation(
                alloc,
                .create,
                created.path,
                created.branch,
                true,
                if (options.start) false else null,
            );
            const snapshot_value = loaded.takeSnapshot();
            return .{ .ready = .{ .snapshot = snapshot_value, .launch = launch } };
        },
        .empty => unreachable,
    }
}

fn open(alloc: Allocator, options: OpenOptions) !Outcome {
    var loaded = try loadSnapshot(alloc);
    defer loaded.deinit(alloc);
    switch (loaded) {
        .failure => return .{ .failure = loaded.takeFailure() },
        .snapshot => |*snapshot| {
            const index = switch (try resolveSelector(alloc, snapshot, options.selector)) {
                .found => |value| value,
                .missing => return .{ .failure = .{
                    .code = .worktree_not_found,
                    .message = try alloc.dupe(u8, "no worktree matches that branch, path, or directory name"),
                } },
                .ambiguous => return .{ .failure = .{
                    .code = .worktree_ambiguous,
                    .message = try alloc.dupe(u8, "worktree selector is ambiguous; use an absolute path or full branch name"),
                } },
            };
            const selected = snapshot.worktrees.items[index];
            const canonical = io_mod.realpathAlloc(alloc, selected.path) catch {
                return .{ .failure = .{
                    .code = .worktree_unavailable,
                    .message = try alloc.dupe(u8, "the selected worktree directory is unavailable"),
                } };
            };
            errdefer alloc.free(canonical);
            snapshot.mutation = try initMutation(alloc, .open, canonical, selected.branch, false, options.resume_session);
            const snapshot_value = loaded.takeSnapshot();
            return .{ .ready = .{
                .snapshot = snapshot_value,
                .launch = .{ .path = canonical, .resume_session = options.resume_session },
            } };
        },
        .empty => unreachable,
    }
}

fn remove(alloc: Allocator, options: RemoveOptions) !Outcome {
    if (!options.confirmed) return error.WorktreeRemovalRequiresConfirmation;

    var initial = try loadSnapshot(alloc);
    defer initial.deinit(alloc);
    switch (initial) {
        .failure => return .{ .failure = initial.takeFailure() },
        .snapshot => |*snapshot| {
            const index = switch (try resolveSelector(alloc, snapshot, options.selector)) {
                .found => |value| value,
                .missing => return .{ .failure = .{
                    .code = .worktree_not_found,
                    .message = try alloc.dupe(u8, "no worktree matches that branch, path, or directory name"),
                } },
                .ambiguous => return .{ .failure = .{
                    .code = .worktree_ambiguous,
                    .message = try alloc.dupe(u8, "worktree selector is ambiguous; use an absolute path or full branch name"),
                } },
            };
            const selected = snapshot.worktrees.items[index];
            if (selected.primary) {
                return .{ .failure = .{
                    .code = .primary_worktree,
                    .message = try alloc.dupe(u8, "the primary worktree cannot be removed by fx"),
                } };
            }
            if (selected.current) {
                return .{ .failure = .{
                    .code = .current_worktree,
                    .message = try alloc.dupe(u8, "the current worktree cannot be removed; run this command from another worktree"),
                } };
            }

            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(alloc);
            try argv.appendSlice(alloc, &.{ "worktree", "remove" });
            if (options.force) try argv.appendSlice(alloc, &.{ "--force", "--force" });
            try argv.append(alloc, selected.path);

            var result = runGit(alloc, null, argv.items) catch |err| {
                return failureFromRunError(alloc, err);
            };
            defer result.deinit(alloc);
            if (!result.succeeded()) {
                return .{ .failure = try processFailure(alloc, .git_command_failed, &result, "git could not remove the worktree") };
            }

            var refreshed = try loadSnapshot(alloc);
            defer refreshed.deinit(alloc);
            switch (refreshed) {
                .failure => return .{ .failure = refreshed.takeFailure() },
                .snapshot => |*next| {
                    next.mutation = try initMutation(alloc, .remove, selected.path, selected.branch, true, null);
                    const snapshot_value = refreshed.takeSnapshot();
                    return .{ .ready = .{ .snapshot = snapshot_value } };
                },
                .empty => unreachable,
            }
        },
        .empty => unreachable,
    }
}

const SnapshotLoad = union(enum) {
    snapshot: Snapshot,
    failure: Failure,
    empty,

    fn deinit(self: *SnapshotLoad, alloc: Allocator) void {
        switch (self.*) {
            .snapshot => |*snapshot| snapshot.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
            .empty => {},
        }
        self.* = .empty;
    }

    fn takeSnapshot(self: *SnapshotLoad) Snapshot {
        return switch (self.*) {
            .snapshot => |snapshot| blk: {
                self.* = .empty;
                break :blk snapshot;
            },
            .failure, .empty => unreachable,
        };
    }

    fn takeFailure(self: *SnapshotLoad) Failure {
        return switch (self.*) {
            .failure => |failure| blk: {
                self.* = .empty;
                break :blk failure;
            },
            .snapshot, .empty => unreachable,
        };
    }
};

fn loadSnapshot(alloc: Allocator) !SnapshotLoad {
    var root_result = runGit(alloc, null, &.{ "rev-parse", "--show-toplevel" }) catch |err| {
        return failureLoadFromRunError(alloc, err);
    };
    defer root_result.deinit(alloc);
    if (!root_result.succeeded()) {
        return .{ .failure = try processFailure(alloc, .not_git_repository, &root_result, "current directory is not inside a Git worktree") };
    }
    const current_root_raw = std.mem.trim(u8, root_result.stdout, " \t\r\n");
    const current_root = io_mod.realpathAlloc(alloc, current_root_raw) catch {
        return .{ .failure = .{
            .code = .worktree_unavailable,
            .message = try alloc.dupe(u8, "current Git worktree is unavailable"),
        } };
    };
    defer alloc.free(current_root);

    var list_result = runGit(alloc, current_root, &.{ "worktree", "list", "--porcelain", "-z" }) catch |err| {
        return failureLoadFromRunError(alloc, err);
    };
    defer list_result.deinit(alloc);
    if (!list_result.succeeded()) {
        return .{ .failure = try processFailure(alloc, .git_command_failed, &list_result, "git could not list worktrees") };
    }

    var worktrees = try parsePorcelain(alloc, list_result.stdout, current_root);
    errdefer {
        for (worktrees.items) |*entry| entry.deinit(alloc);
        worktrees.deinit(alloc);
    }
    if (worktrees.items.len == 0) {
        worktrees.deinit(alloc);
        return .{ .failure = .{
            .code = .git_command_failed,
            .message = try alloc.dupe(u8, "git returned an empty worktree list"),
        } };
    }

    const repository_root = try alloc.dupe(u8, worktrees.items[0].path);
    errdefer alloc.free(repository_root);
    const owned_current_worktree = try alloc.dupe(u8, current_root);
    errdefer alloc.free(owned_current_worktree);

    return .{ .snapshot = .{
        .repository_root = repository_root,
        .current_worktree = owned_current_worktree,
        .worktrees = worktrees,
    } };
}

const EntryBuilder = struct {
    path: ?[]const u8 = null,
    head: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    detached: bool = false,
    bare: bool = false,
    locked_reason: ?[]const u8 = null,
    prunable_reason: ?[]const u8 = null,
};

fn parsePorcelain(alloc: Allocator, bytes: []const u8, current_root: []const u8) !std.ArrayList(Worktree) {
    var worktrees: std.ArrayList(Worktree) = .empty;
    errdefer {
        for (worktrees.items) |*entry| entry.deinit(alloc);
        worktrees.deinit(alloc);
    }

    var builder: EntryBuilder = .{};
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |field| {
        if (field.len == 0) {
            if (builder.path != null) {
                try appendEntry(alloc, &worktrees, builder, current_root);
                builder = .{};
            }
            continue;
        }
        if (std.mem.startsWith(u8, field, "worktree ")) {
            if (builder.path != null) {
                try appendEntry(alloc, &worktrees, builder, current_root);
                builder = .{};
            }
            builder.path = field["worktree ".len..];
        } else if (std.mem.startsWith(u8, field, "HEAD ")) {
            builder.head = field["HEAD ".len..];
        } else if (std.mem.startsWith(u8, field, "branch ")) {
            const value = field["branch ".len..];
            builder.branch = if (std.mem.startsWith(u8, value, "refs/heads/"))
                value["refs/heads/".len..]
            else
                value;
        } else if (std.mem.eql(u8, field, "detached")) {
            builder.detached = true;
        } else if (std.mem.eql(u8, field, "bare")) {
            builder.bare = true;
        } else if (std.mem.startsWith(u8, field, "locked")) {
            builder.locked_reason = std.mem.trimStart(u8, field["locked".len..], " ");
        } else if (std.mem.startsWith(u8, field, "prunable")) {
            builder.prunable_reason = std.mem.trimStart(u8, field["prunable".len..], " ");
        }
    }
    if (builder.path != null) try appendEntry(alloc, &worktrees, builder, current_root);
    return worktrees;
}

fn appendEntry(
    alloc: Allocator,
    worktrees: *std.ArrayList(Worktree),
    builder: EntryBuilder,
    current_root: []const u8,
) !void {
    const path_raw = builder.path orelse return error.InvalidWorktreePorcelain;
    const path = io_mod.realpathAlloc(alloc, path_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try alloc.dupe(u8, path_raw),
    };
    errdefer alloc.free(path);
    const head = try alloc.dupe(u8, builder.head orelse "");
    errdefer alloc.free(head);
    const branch = if (builder.branch) |value| try alloc.dupe(u8, value) else null;
    errdefer if (branch) |value| alloc.free(value);
    const locked_reason = if (builder.locked_reason) |value| try alloc.dupe(u8, value) else null;
    errdefer if (locked_reason) |value| alloc.free(value);
    const prunable_reason = if (builder.prunable_reason) |value| try alloc.dupe(u8, value) else null;
    errdefer if (prunable_reason) |value| alloc.free(value);

    try worktrees.append(alloc, .{
        .path = path,
        .head = head,
        .branch = branch,
        .detached = builder.detached,
        .bare = builder.bare,
        .locked_reason = locked_reason,
        .prunable_reason = prunable_reason,
        .primary = worktrees.items.len == 0,
        .current = std.mem.eql(u8, path, current_root),
    });
}

const SelectorResolution = union(enum) {
    found: usize,
    missing,
    ambiguous,
};

fn resolveSelector(alloc: Allocator, snapshot: *const Snapshot, selector: []const u8) !SelectorResolution {
    const canonical = io_mod.realpathAlloc(alloc, selector) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (canonical) |path| alloc.free(path);

    var match: ?usize = null;
    for (snapshot.worktrees.items, 0..) |entry, index| {
        const branch_match = if (entry.branch) |branch| std.mem.eql(u8, branch, selector) else false;
        const basename_match = std.mem.eql(u8, std.fs.path.basename(entry.path), selector);
        const raw_path_match = std.mem.eql(u8, entry.path, selector);
        const canonical_match = if (canonical) |path| std.mem.eql(u8, entry.path, path) else false;
        if (!branch_match and !basename_match and !raw_path_match and !canonical_match) continue;
        if (match != null and match.? != index) return .ambiguous;
        match = index;
    }
    return if (match) |index| .{ .found = index } else .missing;
}

fn findByBranch(snapshot: *const Snapshot, branch: []const u8) ?usize {
    for (snapshot.worktrees.items, 0..) |entry, index| {
        if (entry.branch) |value| {
            if (std.mem.eql(u8, value, branch)) return index;
        }
    }
    return null;
}

const GitProcess = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *GitProcess, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        self.* = undefined;
    }

    fn succeeded(self: GitProcess) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

fn runGit(alloc: Allocator, cwd: ?[]const u8, args: []const []const u8) !GitProcess {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "--no-optional-locks" });
    try argv.appendSlice(alloc, args);

    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = std.Io.Limit.limited(git_stdout_limit),
        .stderr_limit = std.Io.Limit.limited(git_stderr_limit),
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn processFailure(
    alloc: Allocator,
    code: FailureCode,
    process: *const GitProcess,
    fallback: []const u8,
) !Failure {
    const stderr = std.mem.trim(u8, process.stderr, " \t\r\n");
    const stdout = std.mem.trim(u8, process.stdout, " \t\r\n");
    const message = if (stderr.len > 0) stderr else if (stdout.len > 0) stdout else fallback;
    return .{ .code = code, .message = try alloc.dupe(u8, message) };
}

fn failureFromRunError(alloc: Allocator, err: anyerror) !Outcome {
    return .{ .failure = try failureValueFromRunError(alloc, err) };
}

fn failureLoadFromRunError(alloc: Allocator, err: anyerror) !SnapshotLoad {
    return .{ .failure = try failureValueFromRunError(alloc, err) };
}

fn failureValueFromRunError(alloc: Allocator, err: anyerror) !Failure {
    return switch (err) {
        error.FileNotFound => .{
            .code = .git_unavailable,
            .message = try alloc.dupe(u8, "git was not found in PATH"),
        },
        error.OutOfMemory => error.OutOfMemory,
        else => .{
            .code = .git_command_failed,
            .message = try std.fmt.allocPrint(alloc, "failed to run git: {s}", .{@errorName(err)}),
        },
    };
}

pub fn parseErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorktreeRemovalRequiresConfirmation => "worktree removal requires --confirm",
        error.JsonWorktreeLaunchUnsupported => "--json cannot be combined with a command that starts an interactive fx session",
        error.InvalidWorktreeArgs => "invalid worktree arguments",
        else => null,
    };
}

test "worktree parser keeps destructive removal behind explicit confirmation" {
    try std.testing.expectError(
        error.WorktreeRemovalRequiresConfirmation,
        parse(&.{ @constCast("remove"), @constCast("feature") }),
    );
    const parsed = try parse(&.{ @constCast("remove"), @constCast("feature"), @constCast("--confirm"), @constCast("--force"), @constCast("--json") });
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.action.remove.confirmed);
    try std.testing.expect(parsed.action.remove.force);
}

test "worktree parser accepts create and open launch modes" {
    const default_json = try parse(&.{@constCast("--json")});
    try std.testing.expect(default_json.action == .list);
    try std.testing.expect(default_json.json);

    const created = try parse(&.{ @constCast("create"), @constCast("feature/demo"), @constCast("../demo"), @constCast("--base"), @constCast("main"), @constCast("--start") });
    try std.testing.expectEqualStrings("feature/demo", created.action.create.branch);
    try std.testing.expectEqualStrings("../demo", created.action.create.path);
    try std.testing.expectEqualStrings("main", created.action.create.base.?);
    try std.testing.expect(created.action.create.start);

    const opened = try parse(&.{ @constCast("open"), @constCast("feature/demo"), @constCast("--resume") });
    try std.testing.expectEqualStrings("feature/demo", opened.action.open.selector);
    try std.testing.expect(opened.action.open.resume_session);

    try std.testing.expectError(
        error.JsonWorktreeLaunchUnsupported,
        parse(&.{ @constCast("create"), @constCast("feature/demo"), @constCast("../demo"), @constCast("--start"), @constCast("--json") }),
    );
}

test "porcelain parser marks primary and current linked worktrees" {
    const input =
        "worktree /repo\x00HEAD 0123456789abcdef\x00branch refs/heads/main\x00\x00" ++
        "worktree /repo-feature\x00HEAD fedcba9876543210\x00branch refs/heads/feature/demo\x00locked busy\x00\x00";
    var worktrees = try parsePorcelain(std.testing.allocator, input, "/repo-feature");
    defer {
        for (worktrees.items) |*entry| entry.deinit(std.testing.allocator);
        worktrees.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), worktrees.items.len);
    try std.testing.expect(worktrees.items[0].primary);
    try std.testing.expect(!worktrees.items[0].current);
    try std.testing.expect(!worktrees.items[1].primary);
    try std.testing.expect(worktrees.items[1].current);
    try std.testing.expectEqualStrings("feature/demo", worktrees.items[1].branch.?);
    try std.testing.expectEqualStrings("busy", worktrees.items[1].locked_reason.?);
}

test "selector resolves full branches paths and unique directory names" {
    var snapshot = Snapshot{
        .repository_root = try std.testing.allocator.dupe(u8, "/repo"),
        .current_worktree = try std.testing.allocator.dupe(u8, "/repo"),
        .worktrees = .empty,
    };
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.worktrees.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/repo"),
        .head = try std.testing.allocator.dupe(u8, "aaa"),
        .branch = try std.testing.allocator.dupe(u8, "main"),
        .primary = true,
        .current = true,
    });
    try snapshot.worktrees.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/repo-feature"),
        .head = try std.testing.allocator.dupe(u8, "bbb"),
        .branch = try std.testing.allocator.dupe(u8, "feature/demo"),
    });

    switch (try resolveSelector(std.testing.allocator, &snapshot, "feature/demo")) {
        .found => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.TestUnexpectedResult,
    }
    switch (try resolveSelector(std.testing.allocator, &snapshot, "repo-feature")) {
        .found => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.TestUnexpectedResult,
    }
}
