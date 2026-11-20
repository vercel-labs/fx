//! Reads every hook file for one workspace into a snapshot, and tells whether
//! any file it read has changed since.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const hooks = @import("../../hooks/hooks.zig");
const trust = @import("trust.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const max_file_bytes = 1024 * 1024;

/// Where to look. Borrowed for one call.
pub const Paths = struct {
    /// The user's home, or null when fx has none; then only the project file loads and nothing is trusted.
    home: ?[]const u8,
    workspace_root: []const u8,
};

/// What fx saw of one file, so a later check can tell whether it changed.
pub const Stamp = union(enum) {
    missing,
    present: struct { size: u64, mtime: i96, ctime: i96, inode: u64 },
};

/// One file the snapshot depends on. Owns `path`.
const Watched = struct { path: []u8, stamp: Stamp };

/// One problem fx found while loading. Owns its strings.
pub const Problem = struct { path: []u8, where: []u8, message: []u8 };

/// Everything fx read for one workspace. Owns its memory; free it with deinit.
pub const Snapshot = struct {
    /// The parsed files, in run order.
    files: []hooks.config.File = &.{},
    /// Every hook that may run, in run order, pointing into `files`.
    hooks: []*const hooks.config.Hook = &.{},
    /// Parallel to `hooks`: whether a person trusted the hook.
    trusted: []bool = &.{},
    /// Parallel to `hooks`: whether the person disabled the hook for this workspace. A disabled hook never runs.
    disabled: []bool = &.{},
    /// Parallel to `hooks`: each hook's trust digest.
    digests: [][Sha256.digest_length]u8 = &.{},
    /// Parallel to `hooks`: the path of the file each hook came from (borrowed from `watched`).
    sources: [][]const u8 = &.{},
    problems: []Problem = &.{},
    watched: []Watched = &.{},
    claude_settings: bool = false,
    /// Set when the trust file was refused. No hook runs then, whatever the trust rule or the disabled list.
    trust_refused: bool = false,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(alloc);
        if (self.files.len > 0) alloc.free(self.files);
        if (self.hooks.len > 0) alloc.free(self.hooks);
        if (self.trusted.len > 0) alloc.free(self.trusted);
        if (self.disabled.len > 0) alloc.free(self.disabled);
        if (self.digests.len > 0) alloc.free(self.digests);
        if (self.sources.len > 0) alloc.free(self.sources);
        for (self.problems) |problem| {
            alloc.free(problem.path);
            alloc.free(problem.where);
            alloc.free(problem.message);
        }
        if (self.problems.len > 0) alloc.free(self.problems);
        for (self.watched) |entry| alloc.free(entry.path);
        if (self.watched.len > 0) alloc.free(self.watched);
        self.* = undefined;
    }

    /// The hooks to run. With `trust_required`, only trusted ones; otherwise all.
    /// The caller frees the returned slice (not the hooks).
    pub fn runnable(self: *const Snapshot, alloc: std.mem.Allocator, trust_required: bool) std.mem.Allocator.Error![]*const hooks.config.Hook {
        var list: std.ArrayList(*const hooks.config.Hook) = .empty;
        errdefer list.deinit(alloc);
        for (self.hooks, 0..) |hook, index| {
            if (self.trust_refused or self.disabled[index]) continue;
            if (trust_required and !self.trusted[index]) continue;
            try list.append(alloc, hook);
        }
        return list.toOwnedSlice(alloc);
    }

    /// How many hooks wait for trust. A disabled hook never runs, so it does not wait.
    pub fn pending(self: *const Snapshot) usize {
        if (self.trust_refused) return 0;
        var count: usize = 0;
        for (self.trusted, 0..) |is_trusted, index| {
            if (!is_trusted and !self.disabled[index]) count += 1;
        }
        return count;
    }

    /// How many hooks the person disabled for this workspace.
    pub fn disabledCount(self: *const Snapshot) usize {
        var count: usize = 0;
        for (self.disabled) |is_disabled| {
            if (is_disabled) count += 1;
        }
        return count;
    }
};

/// Reads every hook file for `paths`. Only running out of memory is an error;
/// every other problem is a `Problem` in the snapshot.
pub fn load(alloc: std.mem.Allocator, paths: Paths) std.mem.Allocator.Error!Snapshot {
    var builder: Builder = .{ .alloc = alloc, .paths = paths };
    errdefer builder.deinit();

    const profile_path: ?[]u8 = if (paths.home) |home|
        try profile_paths.rootPath(alloc, home, &.{"hooks.json"})
    else
        null;
    defer if (profile_path) |text| alloc.free(text);

    const project_path = try std.Io.Dir.path.join(alloc, &.{ paths.workspace_root, ".fx/hooks.json" });
    defer alloc.free(project_path);

    var profile_parsed = false;
    if (profile_path) |text| {
        profile_parsed = try builder.readCandidate(text, .{
            .layer = .profile,
            .workspace_root = paths.workspace_root,
        }, true);
    }
    const same_as_profile = if (profile_path) |text| std.mem.eql(u8, text, project_path) else false;
    if (!same_as_profile) {
        _ = try builder.readCandidate(project_path, .{ .layer = .project }, false);
    }

    if (profile_parsed and builder.claude_settings) {
        if (paths.home) |home| {
            const user_settings = try std.Io.Dir.path.join(alloc, &.{ home, ".claude/settings.json" });
            defer alloc.free(user_settings);
            _ = try builder.readCandidate(user_settings, .{ .layer = .claude_user, .report_unknown_keys = false }, false);

            const project_settings = try std.Io.Dir.path.join(alloc, &.{ paths.workspace_root, ".claude/settings.json" });
            defer alloc.free(project_settings);
            _ = try builder.readCandidate(project_settings, .{ .layer = .claude_project, .report_unknown_keys = false }, false);

            const local_settings = try std.Io.Dir.path.join(alloc, &.{ paths.workspace_root, ".claude/settings.local.json" });
            defer alloc.free(local_settings);
            _ = try builder.readCandidate(local_settings, .{ .layer = .claude_project, .report_unknown_keys = false }, false);
        }
    }

    var store: trust.Store = .{};
    defer store.deinit(alloc);
    // A refused trust file stops every hook: its disabled list is unknown, and it may have been tampered with.
    var trust_refused = false;
    if (paths.home) |home| {
        const trust_file = try trust.path(alloc, home);
        defer alloc.free(trust_file);
        _ = try builder.watch(trust_file, statStamp(trust_file) orelse .missing);

        if (trust.load(alloc, trust_file)) |loaded| {
            store = loaded;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TrustFileUnsafe => {
                trust_refused = true;
                try builder.problem(
                    trust_file,
                    "",
                    "other users can write this file; fx runs no hook until you run chmod go-w on it",
                );
            },
            error.TrustFileInvalid => {
                trust_refused = true;
                try builder.problem(
                    trust_file,
                    "",
                    "is not a trust file fx wrote; fx runs no hook until you fix or remove it",
                );
            },
            error.TrustFileUnreadable => {
                trust_refused = true;
                try builder.problem(trust_file, "", "could not read this file; fx runs no hook until it can");
            },
        }
    }

    try builder.collectHooks();
    try builder.markTrusted(&store);
    try builder.markDisabled(&store);
    builder.trust_refused = trust_refused;
    if (trust_refused) debug_trace.logf("hooks", "the trust file is refused, so no hook runs for {s}", .{paths.workspace_root});

    var trusted_count: usize = 0;
    for (builder.trusted.items) |is_trusted| {
        if (is_trusted) trusted_count += 1;
    }
    debug_trace.logf("hooks", "loaded {d} hooks for {s}: {d} trusted, {d} problems", .{
        builder.hooks.items.len,
        paths.workspace_root,
        trusted_count,
        builder.problems.items.len,
    });

    return builder.finish();
}

/// Whether any watched file changed since `snapshot` was read. It only stats files.
pub fn changed(snapshot: *const Snapshot) bool {
    for (snapshot.watched) |entry| {
        const now = statStamp(entry.path) orelse return true;
        switch (entry.stamp) {
            .missing => if (now != .missing) return true,
            .present => |before| {
                const after = switch (now) {
                    .missing => return true,
                    .present => |value| value,
                };
                if (after.size != before.size or
                    after.mtime != before.mtime or
                    after.ctime != before.ctime or
                    after.inode != before.inode) return true;
            },
        }
    }
    return false;
}

/// One hook id and the file that claimed it.
const SeenId = struct { id: []const u8, path: []const u8 };

/// Collects the snapshot while the files are read, and owns it until finish.
const Builder = struct {
    alloc: std.mem.Allocator,
    paths: Paths,
    files: std.ArrayList(hooks.config.File) = .empty,
    /// Parallel to `files`: the watched path each file came from.
    file_paths: std.ArrayList([]const u8) = .empty,
    hooks: std.ArrayList(*const hooks.config.Hook) = .empty,
    trusted: std.ArrayList(bool) = .empty,
    /// Parallel to `hooks`: whether the person disabled each hook for this workspace.
    disabled: std.ArrayList(bool) = .empty,
    digests: std.ArrayList([Sha256.digest_length]u8) = .empty,
    sources: std.ArrayList([]const u8) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    watched: std.ArrayList(Watched) = .empty,
    claude_settings: bool = false,
    trust_refused: bool = false,

    fn deinit(self: *Builder) void {
        const alloc = self.alloc;
        for (self.files.items) |*file| file.deinit(alloc);
        self.files.deinit(alloc);
        self.file_paths.deinit(alloc);
        self.hooks.deinit(alloc);
        self.trusted.deinit(alloc);
        self.disabled.deinit(alloc);
        self.digests.deinit(alloc);
        self.sources.deinit(alloc);
        for (self.problems.items) |entry| {
            alloc.free(entry.path);
            alloc.free(entry.where);
            alloc.free(entry.message);
        }
        self.problems.deinit(alloc);
        for (self.watched.items) |entry| alloc.free(entry.path);
        self.watched.deinit(alloc);
    }

    fn finish(self: *Builder) std.mem.Allocator.Error!Snapshot {
        var snapshot = Snapshot{ .claude_settings = self.claude_settings, .trust_refused = self.trust_refused };
        errdefer snapshot.deinit(self.alloc);
        snapshot.files = try self.files.toOwnedSlice(self.alloc);
        snapshot.hooks = try self.hooks.toOwnedSlice(self.alloc);
        snapshot.trusted = try self.trusted.toOwnedSlice(self.alloc);
        snapshot.disabled = try self.disabled.toOwnedSlice(self.alloc);
        snapshot.digests = try self.digests.toOwnedSlice(self.alloc);
        snapshot.sources = try self.sources.toOwnedSlice(self.alloc);
        snapshot.problems = try self.problems.toOwnedSlice(self.alloc);
        snapshot.watched = try self.watched.toOwnedSlice(self.alloc);
        // Borrowed paths only; the buffer has no owner after the file list is gone.
        self.file_paths.deinit(self.alloc);
        return snapshot;
    }

    /// Records one candidate, and returns whether it parsed into a kept file.
    fn readCandidate(
        self: *Builder,
        file_path: []const u8,
        options: hooks.config.ParseOptions,
        check_mode: bool,
    ) std.mem.Allocator.Error!bool {
        const io = io_mod.getIo();
        const stat = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = try self.watch(file_path, .missing);
                return false;
            },
            else => {
                _ = try self.watch(file_path, .missing);
                try self.problemFormat(file_path, "", "could not read this file: {s}", .{@errorName(err)});
                return false;
            },
        };

        const watched_path = try self.watch(file_path, stampOf(stat));
        if (stat.kind != .file) {
            try self.problem(file_path, "", "is not a regular file");
            return false;
        }
        if (stat.size > max_file_bytes) {
            try self.problem(file_path, "", "is larger than 1 MiB; fx ignores it");
            return false;
        }
        if (check_mode and stat.permissions.toMode() & trust.group_or_other_write != 0) {
            try self.problem(file_path, "", "other users can write this file; fx ignores it until you run chmod go-w on it");
            return false;
        }

        var file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
            try self.problemFormat(file_path, "", "could not read this file: {s}", .{@errorName(err)});
            return false;
        };
        defer file.close(io);

        const bytes = io_mod.readFileToEnd(self.alloc, &file, max_file_bytes + 1) catch |err| {
            try self.problemFormat(file_path, "", "could not read this file: {s}", .{@errorName(err)});
            return false;
        };
        defer self.alloc.free(bytes);

        var parsed = try hooks.config.parse(self.alloc, bytes, options);
        var kept = false;
        defer if (!kept) parsed.deinit(self.alloc);
        for (parsed.diagnostics) |diagnostic| {
            try self.problem(file_path, diagnostic.where, diagnostic.message);
        }
        // The problems hold their own copies now; drop the file's.
        for (parsed.diagnostics) |diagnostic| {
            self.alloc.free(diagnostic.where);
            self.alloc.free(diagnostic.message);
        }
        if (parsed.diagnostics.len > 0) self.alloc.free(parsed.diagnostics);
        parsed.diagnostics = &.{};
        if (parsed.claude_settings) self.claude_settings = true;
        try self.files.append(self.alloc, parsed);
        kept = true;
        try self.file_paths.append(self.alloc, watched_path);
        return true;
    }

    /// Hooks whose id another file already used are skipped with a problem.
    fn collectHooks(self: *Builder) std.mem.Allocator.Error!void {
        var seen: std.ArrayList(SeenId) = .empty;
        defer seen.deinit(self.alloc);

        for (self.files.items, 0..) |*file, file_index| {
            const file_path = self.file_paths.items[file_index];
            for (file.hooks) |*hook| {
                if (claimId(&seen, hook.id)) |earlier| {
                    try self.problemFormat(file_path, hook.where, "id \"{s}\" is also used in {s}; this hook is skipped", .{
                        hook.id,
                        earlier,
                    });
                    continue;
                }
                seen.append(self.alloc, .{ .id = hook.id, .path = file_path }) catch |err| {
                    return err;
                };
                try self.hooks.append(self.alloc, hook);
                try self.sources.append(self.alloc, file_path);
            }
        }
    }

    /// Records every hook's digest, whether it is trusted, and the files it names.
    fn markTrusted(self: *Builder, store: *const trust.Store) std.mem.Allocator.Error!void {
        for (self.hooks.items, 0..) |hook, index| {
            var named = try trust.namedFiles(self.alloc, hook.command, self.paths.workspace_root, self.paths.home);
            defer named.deinit(self.alloc);

            if (named.dropped > 0) {
                try self.problemFormat(self.sources.items[index], hook.where, "this hook names more than {d} files; trust covers only the first {d}", .{
                    trust.max_named_files,
                    trust.max_named_files,
                });
            }

            // Stamp each named file before its digest reads it. A write after the stamp
            // then shows as a change at the next refresh. A stamp taken after the read
            // could hide a write made in between.
            for (named.files) |file_path| {
                _ = try self.watch(file_path, statStamp(file_path) orelse .missing);
            }

            const value = try trust.digest(self.alloc, hook, self.paths.workspace_root, named.files);
            try self.digests.append(self.alloc, value);
            try self.trusted.append(self.alloc, store.contains(value));
        }
    }

    /// Records whether the person disabled each hook for this workspace. It runs after markTrusted,
    /// so `disabled` lines up with `hooks`. With no trust file read, nothing is disabled.
    fn markDisabled(self: *Builder, store: *const trust.Store) std.mem.Allocator.Error!void {
        for (self.hooks.items) |hook| {
            try self.disabled.append(self.alloc, store.isDisabled(self.paths.workspace_root, hook.id));
        }
    }

    /// Records one watched path once, and returns the stored copy of it.
    fn watch(self: *Builder, file_path: []const u8, stamp: Stamp) std.mem.Allocator.Error![]const u8 {
        for (self.watched.items) |entry| {
            if (std.mem.eql(u8, entry.path, file_path)) return entry.path;
        }
        const copy = try self.alloc.dupe(u8, file_path);
        errdefer self.alloc.free(copy);
        try self.watched.append(self.alloc, .{ .path = copy, .stamp = stamp });
        return copy;
    }

    fn problem(self: *Builder, file_path: []const u8, where: []const u8, message: []const u8) std.mem.Allocator.Error!void {
        const owned_path = try self.alloc.dupe(u8, file_path);
        errdefer self.alloc.free(owned_path);
        const owned_where = try self.alloc.dupe(u8, where);
        errdefer self.alloc.free(owned_where);
        const owned_message = try self.alloc.dupe(u8, message);
        errdefer self.alloc.free(owned_message);
        try self.problems.append(self.alloc, .{ .path = owned_path, .where = owned_where, .message = owned_message });
    }

    fn problemFormat(self: *Builder, file_path: []const u8, where: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const message = try self.alloc.print(fmt, args);
        defer self.alloc.free(message);
        try self.problem(file_path, where, message);
    }
};

/// Claims `id` for a file, or returns the first file that already claimed it.
fn claimId(seen: *std.ArrayList(SeenId), id: []const u8) ?[]const u8 {
    for (seen.items) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry.path;
    }
    return null;
}

fn stampOf(stat: std.Io.File.Stat) Stamp {
    return .{ .present = .{
        .size = stat.size,
        .mtime = stat.mtime.nanoseconds,
        .ctime = stat.ctime.nanoseconds,
        .inode = @intCast(stat.inode),
    } };
}

/// The stamp of `file_path` now, or null when it cannot be read for a reason
/// other than being missing.
fn statStamp(file_path: []const u8) ?Stamp {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return null,
    };
    return stampOf(stat);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        return .{ .tmp = tmp, .home = home, .workspace = workspace };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn writeFixture(alloc: std.mem.Allocator, file_path: []const u8, text: []const u8) !void {
    try io_mod.writeFileAtomic(alloc, file_path, text);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
}

fn writeProfile(alloc: std.mem.Allocator, fixture: *const Fixture, text: []const u8) !void {
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const file_path = try profile_paths.rootPath(alloc, fixture.home, &.{"hooks.json"});
    defer alloc.free(file_path);
    try writeFixture(alloc, file_path, text);
}

fn writeProject(alloc: std.mem.Allocator, fixture: *const Fixture, text: []const u8) !void {
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    const file_path = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, ".fx/hooks.json" });
    defer alloc.free(file_path);
    try writeFixture(alloc, file_path, text);
}

fn findProblem(snapshot: *const Snapshot, needle: []const u8) bool {
    for (snapshot.problems) |problem| {
        if (std.mem.find(u8, problem.message, needle) != null) return true;
    }
    return false;
}

test "nothing exists yet" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), snapshot.hooks.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.problems.len);
    try std.testing.expectEqual(@as(usize, 3), snapshot.watched.len);
    for (snapshot.watched) |entry| {
        try std.testing.expect(entry.stamp == .missing);
    }
    try std.testing.expect(!changed(&snapshot));
}

test "a profile and a project file both load, in run order" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\"}]}]}}");
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\"}]}]}}");

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.hooks.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.problems.len);
    try std.testing.expectEqual(hooks.EventName.pre_tool_use, snapshot.hooks[0].event);
    try std.testing.expectEqual(hooks.EventName.stop, snapshot.hooks[1].event);
    try std.testing.expect(!snapshot.trusted[0]);
    try std.testing.expect(!snapshot.trusted[1]);
    try std.testing.expectEqual(@as(usize, 2), snapshot.pending());

    const all = try snapshot.runnable(alloc, false);
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const trusted_only = try snapshot.runnable(alloc, true);
    defer alloc.free(trusted_only);
    try std.testing.expectEqual(@as(usize, 0), trusted_only.len);
}

test "a trusted digest runs, an untrusted one waits" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const profile_text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\"}]}]}}";
    try writeProfile(alloc, &fixture, profile_text);
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\"}]}]}}");

    var parsed = try hooks.config.parse(alloc, profile_text, .{ .layer = .profile, .workspace_root = fixture.workspace });
    defer parsed.deinit(alloc);
    var named = try trust.namedFiles(alloc, parsed.hooks[0].command, fixture.workspace, fixture.home);
    defer named.deinit(alloc);
    const value = try trust.digest(alloc, &parsed.hooks[0], fixture.workspace, named.files);

    var store = trust.Store{};
    defer store.deinit(alloc);
    try store.add(alloc, value, "profile hook");
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try trust.save(alloc, trust_file, &store);

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.hooks.len);
    try std.testing.expect(snapshot.trusted[0]);
    try std.testing.expect(!snapshot.trusted[1]);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending());

    const trusted_only = try snapshot.runnable(alloc, true);
    defer alloc.free(trusted_only);
    try std.testing.expectEqual(@as(usize, 1), trusted_only.len);
    try std.testing.expectEqual(snapshot.hooks[0], trusted_only[0]);
}

test "a profile file others can write is ignored" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\"}]}]}}");
    const profile_file = try profile_paths.rootPath(alloc, fixture.home, &.{"hooks.json"});
    defer alloc.free(profile_file);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), profile_file, std.Io.File.Permissions.fromMode(0o664), .{});

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), snapshot.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.problems.len);
    try std.testing.expect(std.mem.find(u8, snapshot.problems[0].message, "other users can write this file") != null);
}

test "Claude settings load only when the profile asks" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "home/.claude");
    try fixture.tmp.dir.createDirPath(io_mod.getIo(), "workspace/.claude");

    const user_settings = try std.Io.Dir.path.join(alloc, &.{ fixture.home, ".claude/settings.json" });
    defer alloc.free(user_settings);
    try writeFixture(alloc, user_settings, "{\"hooks\":{\"PostToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"fmt\"}]}]}}");
    const project_settings = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, ".claude/settings.json" });
    defer alloc.free(project_settings);
    try writeFixture(alloc, project_settings, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bye\"}]}]}}");

    try writeProfile(alloc, &fixture, "{\"claude_settings\":true}");
    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.claude_settings);
    try std.testing.expectEqual(@as(usize, 2), snapshot.hooks.len);
    try std.testing.expectEqual(hooks.config.Layer.claude_user, snapshot.hooks[0].layer);
    try std.testing.expectEqual(hooks.config.Layer.claude_project, snapshot.hooks[1].layer);

    try writeProfile(alloc, &fixture, "{}");
    var quiet = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer quiet.deinit(alloc);
    try std.testing.expect(!quiet.claude_settings);
    try std.testing.expectEqual(@as(usize, 0), quiet.hooks.len);
    for (quiet.watched) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.path, ".claude/settings.json") == null);
    }
}

test "an id another file used is skipped" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\",\"id\":\"same\"}]}]}}");
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\",\"id\":\"same\"}]}]}}");

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), snapshot.hooks.len);
    try std.testing.expectEqual(hooks.EventName.pre_tool_use, snapshot.hooks[0].event);
    try std.testing.expectEqual(@as(usize, 1), snapshot.problems.len);
    try std.testing.expect(std.mem.find(u8, snapshot.problems[0].message, "is also used in") != null);
}

test "a hook's script is watched and its digest follows the content" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProject(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./guard.sh\"}]}]}}");
    const guard = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "guard.sh" });
    defer alloc.free(guard);
    try writeFixture(alloc, guard, "echo 1");

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.hooks.len);
    var saw_guard = false;
    for (snapshot.watched) |entry| {
        if (std.mem.eql(u8, entry.path, guard)) saw_guard = true;
    }
    try std.testing.expect(saw_guard);
    try std.testing.expect(!changed(&snapshot));
    const first_digest = snapshot.digests[0];

    try writeFixture(alloc, guard, "echo 1 && echo a longer line");
    try std.testing.expect(changed(&snapshot));

    var second = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer second.deinit(alloc);
    try std.testing.expect(!std.mem.eql(u8, &first_digest, &second.digests[0]));
}

test "a named file rewritten after the snapshot is read reads as changed, and its hook loses trust" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    const profile_text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./guard.sh\"}]}]}}";
    try writeProfile(alloc, &fixture, profile_text);
    const guard = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "guard.sh" });
    defer alloc.free(guard);
    try writeFixture(alloc, guard, "echo 1");

    var parsed = try hooks.config.parse(alloc, profile_text, .{ .layer = .profile, .workspace_root = fixture.workspace });
    defer parsed.deinit(alloc);
    var named = try trust.namedFiles(alloc, parsed.hooks[0].command, fixture.workspace, fixture.home);
    defer named.deinit(alloc);
    const value = try trust.digest(alloc, &parsed.hooks[0], fixture.workspace, named.files);

    var store = trust.Store{};
    defer store.deinit(alloc);
    try store.add(alloc, value, "profile hook");
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try trust.save(alloc, trust_file, &store);

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.trusted[0]);
    var stamped = false;
    for (snapshot.watched) |entry| {
        if (!std.mem.eql(u8, entry.path, guard)) continue;
        stamped = true;
        // The stamp taken at load is the file as it was at load.
        try std.testing.expect(std.meta.eql(entry.stamp, statStamp(guard).?));
    }
    try std.testing.expect(stamped);
    try std.testing.expect(!changed(&snapshot));

    try writeFixture(alloc, guard, "echo 1 && echo a longer line");
    try std.testing.expect(changed(&snapshot));

    var after = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer after.deinit(alloc);
    try std.testing.expect(!after.trusted[0]);
}

test "creating or deleting a watched file counts as a change" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);

    var missing = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer missing.deinit(alloc);
    try std.testing.expect(!changed(&missing));

    try writeProfile(alloc, &fixture, "{}");
    try std.testing.expect(changed(&missing));

    var present = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer present.deinit(alloc);
    try std.testing.expect(!changed(&present));

    const profile_file = try profile_paths.rootPath(alloc, fixture.home, &.{"hooks.json"});
    defer alloc.free(profile_file);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), profile_file);
    try std.testing.expect(changed(&present));
}

test "a trust file others can write trusts nothing" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\"}]}]}}");
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try writeFixture(alloc, trust_file, "{\"version\":1,\"trusted\":[]}");
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), trust_file, std.Io.File.Permissions.fromMode(0o664), .{});

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), snapshot.hooks.len);
    try std.testing.expect(!snapshot.trusted[0]);
    try std.testing.expect(findProblem(&snapshot, "fx runs no hook"));
}

test "a refused trust file stops every hook, whatever the trust rule" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\"}]}]}}");
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try writeFixture(alloc, trust_file, "{\"version\":1,\"trusted\":[]}");
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), trust_file, std.Io.File.Permissions.fromMode(0o664), .{});

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.problems.len);
    try std.testing.expectEqualStrings(
        "other users can write this file; fx runs no hook until you run chmod go-w on it",
        snapshot.problems[0].message,
    );

    const open = try snapshot.runnable(alloc, false);
    defer alloc.free(open);
    try std.testing.expectEqual(@as(usize, 0), open.len);
    const trusted_only = try snapshot.runnable(alloc, true);
    defer alloc.free(trusted_only);
    try std.testing.expectEqual(@as(usize, 0), trusted_only.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending());
    // A refused file is its own state: the person disabled nothing, and the snapshot says so.
    try std.testing.expect(snapshot.trust_refused);
    try std.testing.expectEqual(@as(usize, 0), snapshot.disabledCount());
}

test "a hook disabled for this workspace never runs and does not wait for trust" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProfile(alloc, &fixture, "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./p.sh\",\"id\":\"lint\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"./s.sh\",\"id\":\"notes\"}]}]}}");

    var store = trust.Store{};
    defer store.deinit(alloc);
    try store.setDisabled(alloc, fixture.workspace, "lint", true);
    const trust_file = try trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try trust.save(alloc, trust_file, &store);

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    // Both hooks are listed, and only the one the person disabled is marked.
    try std.testing.expectEqual(@as(usize, 2), snapshot.hooks.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.disabledCount());
    for (snapshot.hooks, snapshot.disabled) |hook, is_disabled| {
        try std.testing.expectEqual(std.mem.eql(u8, hook.id, "lint"), is_disabled);
    }

    // The disabled hook runs under neither trust rule. The other hook is untrusted, so it waits.
    const open = try snapshot.runnable(alloc, false);
    defer alloc.free(open);
    try std.testing.expectEqual(@as(usize, 1), open.len);
    try std.testing.expectEqualStrings("notes", open[0].id);
    const trusted_only = try snapshot.runnable(alloc, true);
    defer alloc.free(trusted_only);
    try std.testing.expectEqual(@as(usize, 0), trusted_only.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending());
}

test "problems from the hook files pass through" {
    const alloc = std.testing.allocator;
    var fixture = try Fixture.init(alloc);
    defer fixture.deinit(alloc);
    try writeProject(alloc, &fixture, "{\"hooks\":{\"Nope\":[]}}");
    const project_file = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, ".fx/hooks.json" });
    defer alloc.free(project_file);

    var snapshot = try load(alloc, .{ .home = fixture.home, .workspace_root = fixture.workspace });
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), snapshot.problems.len);
    try std.testing.expectEqualStrings(project_file, snapshot.problems[0].path);
    try std.testing.expectEqualStrings("unknown event \"Nope\"", snapshot.problems[0].message);
}
