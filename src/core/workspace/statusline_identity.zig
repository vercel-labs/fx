const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const max_git_metadata_bytes: usize = 4096;
const max_encoded_workspace_bytes: usize = std.fs.max_path_bytes * 4;
const max_encoded_branch_bytes: usize = 512;

pub const Snapshot = struct {
    workspace_label: []const u8 = "",
    git_branch: ?[]const u8 = null,
};

const HeadSignature = struct {
    inode: u64,
    mtime_ns: i128,
    size: u64,

    fn eql(a: HeadSignature, b: HeadSignature) bool {
        return a.inode == b.inode and
            a.mtime_ns == b.mtime_ns and
            a.size == b.size;
    }
};

const ParsedHead = union(enum) {
    branch: []const u8,
    detached: []const u8,
};

const HeadPathResolution = union(enum) {
    missing,
    invalid,
    found: []u8,
};

/// Owns the filesystem-derived state used by the footer. The UI only receives
/// terminal-safe strings, and repeated renders stat HEAD without rereading it
/// unless its metadata changes.
pub const Runtime = struct {
    enabled: bool = false,
    workspace_root: []u8 = &.{},
    workspace_label: []u8 = &.{},
    head_path: []u8 = &.{},
    branch_label: []u8 = &.{},
    head_signature: ?HeadSignature = null,

    pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
        freeOwned(alloc, &self.workspace_root);
        freeOwned(alloc, &self.workspace_label);
        freeOwned(alloc, &self.head_path);
        freeOwned(alloc, &self.branch_label);
        self.* = .{};
    }

    pub fn snapshot(self: *const Runtime) Snapshot {
        return .{
            .workspace_label = self.workspace_label,
            .git_branch = if (self.branch_label.len > 0) self.branch_label else null,
        };
    }

    pub fn refresh(
        self: *Runtime,
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
    ) !Snapshot {
        if (!self.enabled) return .{};
        if (!std.mem.eql(u8, self.workspace_root, workspace_root)) {
            try self.rebuildWorkspace(alloc, workspace_root);
        }
        try self.refreshBranch(alloc);
        return self.snapshot();
    }

    fn rebuildWorkspace(
        self: *Runtime,
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
    ) !void {
        if (workspace_root.len == 0) {
            self.deinit(alloc);
            return;
        }

        const next_root = try alloc.dupe(u8, workspace_root);
        errdefer alloc.free(next_root);

        const encoded_path = try encodeWorkspacePath(alloc, workspace_root);
        errdefer alloc.free(encoded_path);

        const next_head_path = try resolveHeadPath(alloc, workspace_root);
        errdefer if (next_head_path) |path| alloc.free(path);

        freeOwned(alloc, &self.workspace_root);
        freeOwned(alloc, &self.workspace_label);
        freeOwned(alloc, &self.head_path);
        freeOwned(alloc, &self.branch_label);

        self.workspace_root = next_root;
        self.workspace_label = encoded_path;
        self.head_path = next_head_path orelse &.{};
        self.head_signature = null;
    }

    fn refreshBranch(self: *Runtime, alloc: std.mem.Allocator) !void {
        if (self.head_path.len == 0) return;

        const stat = std.Io.Dir.cwd().statFile(
            io_mod.getIo(),
            self.head_path,
            .{ .follow_symlinks = false },
        ) catch {
            freeOwned(alloc, &self.branch_label);
            self.head_signature = null;
            return;
        };
        if (stat.kind != .file) {
            freeOwned(alloc, &self.branch_label);
            self.head_signature = null;
            return;
        }

        const signature = HeadSignature{
            .inode = @intCast(stat.inode),
            .mtime_ns = stat.mtime.nanoseconds,
            .size = stat.size,
        };
        if (self.head_signature) |previous| {
            if (previous.eql(signature)) return;
        }

        const head = readSmallFile(alloc, self.head_path, max_git_metadata_bytes) catch {
            freeOwned(alloc, &self.branch_label);
            self.head_signature = signature;
            return;
        };
        defer alloc.free(head);

        const parsed = parseHead(head);
        if (parsed) |value| {
            var detached_buf: [32]u8 = undefined;
            const raw = switch (value) {
                .branch => |branch| branch,
                .detached => |sha| std.fmt.bufPrint(
                    &detached_buf,
                    "detached:{s}",
                    .{sha},
                ) catch sha,
            };
            var encoded = try text_utils.encodeTerminalSafe(
                alloc,
                raw,
                max_encoded_branch_bytes,
            );
            freeOwned(alloc, &self.branch_label);
            self.branch_label = encoded.bytes;
            encoded.bytes = &.{};
        } else {
            freeOwned(alloc, &self.branch_label);
        }
        self.head_signature = signature;
    }
};

fn freeOwned(alloc: std.mem.Allocator, bytes: *[]u8) void {
    if (bytes.*.len > 0) alloc.free(bytes.*);
    bytes.* = &.{};
}

fn encodeWorkspacePath(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
) ![]u8 {
    const encoded = text_utils.encodeTerminalSafePathTail(
        alloc,
        workspace_root,
        max_encoded_workspace_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PathBasenameTooLong => {
            const fallback = try text_utils.encodeTerminalSafe(
                alloc,
                workspace_root,
                max_encoded_workspace_bytes,
            );
            return fallback.bytes;
        },
    };
    return encoded.bytes;
}

fn resolveHeadPath(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
) !?[]u8 {
    var candidate = workspace_root;
    while (true) {
        switch (try resolveHeadPathAt(alloc, candidate)) {
            .found => |head_path| return head_path,
            .invalid => return null,
            .missing => {},
        }
        const parent = std.fs.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

fn resolveHeadPathAt(
    alloc: std.mem.Allocator,
    candidate_root: []const u8,
) !HeadPathResolution {
    const dot_git = try std.fs.path.join(alloc, &.{ candidate_root, ".git" });
    defer alloc.free(dot_git);

    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        dot_git,
        .{ .follow_symlinks = false },
    ) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .invalid,
    };

    if (stat.kind == .directory) {
        return .{ .found = try std.fs.path.join(alloc, &.{ dot_git, "HEAD" }) };
    }
    if (stat.kind != .file) return .invalid;

    const content = readSmallFile(alloc, dot_git, max_git_metadata_bytes) catch return .invalid;
    defer alloc.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .invalid;

    const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (raw.len == 0) return .invalid;
    const git_dir = if (std.fs.path.isAbsolute(raw))
        try alloc.dupe(u8, raw)
    else
        try std.fs.path.resolve(alloc, &.{ candidate_root, raw });
    defer alloc.free(git_dir);
    return .{ .found = try std.fs.path.join(alloc, &.{ git_dir, "HEAD" }) };
}

fn readSmallFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn parseHead(head: []const u8) ?ParsedHead {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (trimmed.len == 0) return null;

    const ref_prefix = "ref:";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const ref = std.mem.trim(u8, trimmed[ref_prefix.len..], " \t\r\n");
        if (ref.len == 0) return null;
        const heads_prefix = "refs/heads/";
        const branch = if (std.mem.startsWith(u8, ref, heads_prefix))
            ref[heads_prefix.len..]
        else
            ref;
        if (branch.len == 0) return null;
        return .{ .branch = branch };
    }

    if (trimmed.len < 7) return null;
    for (trimmed) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return .{ .detached = trimmed[0..@min(trimmed.len, 12)] };
}

fn writeTestFile(
    dir: std.Io.Dir,
    path: []const u8,
    content: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test "workspace statusline identity refreshes branch and detached HEAD" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "ref: refs/heads/main\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    var snapshot = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings(root, snapshot.workspace_label);
    try std.testing.expectEqualStrings("main", snapshot.git_branch.?);

    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "ref: refs/heads/refreshed-branch\n");
    snapshot = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("refreshed-branch", snapshot.git_branch.?);

    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "0123456789abcdef0123456789abcdef01234567\n");
    snapshot = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("detached:0123456789ab", snapshot.git_branch.?);
}

test "workspace statusline identity resolves worktree gitdir files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(
        tmp.dir,
        "workspace/.git",
        "gitdir: ../git-data/worktrees/active\n",
    );
    try writeTestFile(
        tmp.dir,
        "git-data/worktrees/active/HEAD",
        "ref: refs/heads/worktree-branch\n",
    );

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const snapshot = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("worktree-branch", snapshot.git_branch.?);
}

test "workspace statusline identity finds a repository above the working directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "ref: refs/heads/parent-repo\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/packages/app");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo/packages/app");
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const snapshot = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings(root, snapshot.workspace_label);
    try std.testing.expectEqualStrings("parent-repo", snapshot.git_branch.?);
}

test "workspace statusline identity handles non-git and hostile paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "unsafe-\x1b[31m-workspace");
    try writeTestFile(
        tmp.dir,
        "unsafe-\x1b[31m-workspace/.git",
        "not a Git directory\n",
    );

    const root = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "unsafe-\x1b[31m-workspace",
    );
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const snapshot = try runtime.refresh(alloc, root);
    try std.testing.expect(snapshot.git_branch == null);
    try std.testing.expect(std.mem.findScalar(u8, snapshot.workspace_label, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, snapshot.workspace_label, "\\x1b") != null);
}

test "workspace statusline identity rejects malformed detached HEAD" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "not-a-commit\x1b[31m\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const snapshot = try runtime.refresh(alloc, root);
    try std.testing.expect(snapshot.git_branch == null);
}

test "workspace statusline identity represents the filesystem root" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const snapshot = try runtime.refresh(alloc, std.fs.path.sep_str);
    try std.testing.expectEqualStrings(std.fs.path.sep_str, snapshot.workspace_label);
}

test "workspace statusline disabled refresh preserves cached identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "ref: refs/heads/main\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var runtime: Runtime = .{ .enabled = true };
    defer runtime.deinit(alloc);

    const initial = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("main", initial.git_branch.?);

    runtime.enabled = false;
    try writeTestFile(tmp.dir, "workspace/.git/HEAD", "ref: refs/heads/changed-while-disabled\n");
    const disabled = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("", disabled.workspace_label);
    try std.testing.expect(disabled.git_branch == null);
    try std.testing.expectEqualStrings(root, runtime.workspace_root);
    try std.testing.expectEqualStrings("main", runtime.branch_label);

    runtime.enabled = true;
    const reenabled = try runtime.refresh(alloc, root);
    try std.testing.expectEqualStrings("changed-while-disabled", reenabled.git_branch.?);
}
