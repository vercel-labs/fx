const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// One curated ACP agent from the official ACP registry
/// (https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json).
/// `path_candidates` are executable names probed against PATH in priority
/// order; `npx_package` is the registry distribution when the agent is not
/// installed locally. All strings are static; the struct is copyable.
pub const AgentCatalogEntry = struct {
    id: []const u8,
    display_name: []const u8,
    description: []const u8,
    path_candidates: []const []const u8 = &.{},
    npx_package: ?[]const u8 = null,
    launch_args: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
};

pub const catalog = [_]AgentCatalogEntry{
    .{
        .id = "claude-acp",
        .display_name = "Claude Agent",
        .description = "ACP wrapper for Anthropic's Claude",
        .path_candidates = &.{"claude-agent-acp"},
        .npx_package = "@agentclientprotocol/claude-agent-acp",
        .launch_args = &.{},
    },
    .{
        .id = "codex-acp",
        .display_name = "Codex",
        .description = "ACP adapter for OpenAI's coding assistant",
        .path_candidates = &.{"codex-acp"},
        .npx_package = "@agentclientprotocol/codex-acp",
        .launch_args = &.{},
    },
    .{
        .id = "gemini",
        .display_name = "Gemini CLI",
        .description = "Google's official CLI for Gemini",
        .path_candidates = &.{"gemini"},
        .npx_package = "@google/gemini-cli",
        .launch_args = &.{"--acp"},
    },
    .{
        .id = "grok-build",
        .display_name = "Grok Build",
        .description = "xAI's coding agent and CLI",
        .path_candidates = &.{"grok"},
        .npx_package = "@xai-official/grok",
        .launch_args = &.{ "agent", "stdio" },
    },
    .{
        .id = "qwen-code",
        .display_name = "Qwen Code",
        .description = "Alibaba's Qwen coding assistant",
        .path_candidates = &.{"qwen"},
        .npx_package = "@qwen-code/qwen-code",
        .launch_args = &.{ "--acp", "--experimental-skills" },
    },
    .{
        .id = "opencode",
        .display_name = "OpenCode",
        .description = "The open source coding agent",
        .path_candidates = &.{"opencode"},
        .npx_package = null,
        .launch_args = &.{"acp"},
    },
    .{
        .id = "goose",
        .display_name = "goose",
        .description = "A local, extensible, open source AI agent",
        .path_candidates = &.{"goose"},
        .npx_package = null,
        .launch_args = &.{"acp"},
    },
    .{
        .id = "cursor",
        .display_name = "Cursor Agent",
        .description = "Cursor's coding agent",
        .path_candidates = &.{"cursor-agent"},
        .npx_package = null,
        .launch_args = &.{"acp"},
    },
    .{
        .id = "kimi",
        .display_name = "Kimi CLI",
        .description = "Moonshot AI's coding agent",
        .path_candidates = &.{"kimi"},
        .npx_package = null,
        .launch_args = &.{"acp"},
    },
    .{
        .id = "cline",
        .display_name = "Cline",
        .description = "Autonomous coding agent CLI",
        .path_candidates = &.{"cline"},
        .npx_package = "cline",
        .launch_args = &.{"--acp"},
    },
    .{
        .id = "amp-acp",
        .display_name = "Amp",
        .description = "ACP wrapper for Amp, the frontier coding agent",
        .path_candidates = &.{"amp-acp"},
        .npx_package = null,
        .launch_args = &.{},
    },
    .{
        .id = "auggie",
        .display_name = "Auggie CLI",
        .description = "Augment Code's software agent",
        .path_candidates = &.{"auggie"},
        .npx_package = "@augmentcode/auggie",
        .launch_args = &.{"--acp"},
        .env = &.{"AUGMENT_DISABLE_AUTO_UPDATE=1"},
    },
};

pub const DetectionStatus = enum {
    /// An executable from path_candidates exists on PATH.
    installed_local,
    /// No local executable, but the registry publishes an npx distribution.
    installable_via_npx,
    /// No local executable and no npx distribution.
    unavailable,
};

/// Owned detection result. `entry` is a static catalog entry (borrowed);
/// `resolved_command` is owned by the caller's allocator when non-null.
pub const Detection = struct {
    entry: *const AgentCatalogEntry,
    resolved_command: ?[]u8 = null,
    status: DetectionStatus,

    pub fn deinit(self: *Detection, alloc: Allocator) void {
        if (self.resolved_command) |command| alloc.free(command);
        self.* = undefined;
    }
};

/// Returns the static catalog entries in registry order. Borrowed, not owned.
pub fn entries() []const AgentCatalogEntry {
    return &catalog;
}

pub fn findByCatalogId(id: []const u8) ?*const AgentCatalogEntry {
    for (&catalog) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn isExecutableFile(permissions_mode: std.Io.File.Permissions) bool {
    const mode = permissions_mode.toMode();
    return mode & 0o111 != 0;
}

/// Probes PATH for the entry's candidates. Returns an owned Detection.
pub fn detect(alloc: Allocator, entry: *const AgentCatalogEntry) !Detection {
    if (builtin.os.tag == .windows) {
        // Windows PATH resolution requires PATHEXT handling; treat any npx
        // distribution as installable and otherwise report unavailable.
        if (entry.npx_package) |_| {
            return .{ .entry = entry, .status = .installable_via_npx };
        }
        return .{ .entry = entry, .status = .unavailable };
    }

    const path_value = io_mod.getenv("PATH") orelse {
        if (entry.npx_package) |_| {
            return .{ .entry = entry, .status = .installable_via_npx };
        }
        return .{ .entry = entry, .status = .unavailable };
    };

    return detectInPathValue(alloc, entry, path_value);
}

/// PATH entries may be relative or contain an unexpanded `~`; open them
/// relative to cwd (execvp semantics) rather than asserting absoluteness.
fn detectInPathValue(
    alloc: Allocator,
    entry: *const AgentCatalogEntry,
    path_value: []const u8,
) !Detection {
    const zio = io_mod.getIo();
    var path_dirs = std.mem.tokenizeScalar(u8, path_value, ':');
    while (path_dirs.next()) |dir| {
        if (dir.len == 0) continue;
        for (entry.path_candidates) |candidate| {
            const full = std.fs.path.join(alloc, &.{ dir, candidate }) catch
                return error.OutOfMemory;
            defer alloc.free(full);

            var file = std.Io.Dir.cwd().openFile(zio, full, .{}) catch continue;
            defer file.close(zio);
            const stat = file.stat(zio) catch continue;
            if (stat.kind != .file) continue;
            if (!isExecutableFile(stat.permissions)) continue;

            return .{
                .entry = entry,
                .resolved_command = try alloc.dupe(u8, full),
                .status = .installed_local,
            };
        }
    }

    if (entry.npx_package) |_| {
        return .{ .entry = entry, .status = .installable_via_npx };
    }
    return .{ .entry = entry, .status = .unavailable };
}

/// Detects every catalog entry. Caller owns the slice and each Detection.
pub fn detectAll(alloc: Allocator) ![]Detection {
    var results: std.ArrayList(Detection) = .empty;
    errdefer {
        for (results.items) |*detection| detection.deinit(alloc);
        results.deinit(alloc);
    }
    for (&catalog) |*entry| {
        try results.append(alloc, try detect(alloc, entry));
    }
    return results.toOwnedSlice(alloc);
}

/// Launch args for an npx-distributed agent: ["-y", package] ++ launch_args.
/// The returned slices borrow from the static catalog entry; only the outer
/// slice is owned by the caller's allocator.
pub fn npxLaunchArgs(alloc: Allocator, entry: *const AgentCatalogEntry) ![][]const u8 {
    const package = entry.npx_package orelse return error.AcpAgentNotNpxInstallable;
    const total = 2 + entry.launch_args.len;
    const args = try alloc.alloc([]const u8, total);
    args[0] = "-y";
    args[1] = package;
    for (entry.launch_args, 0..) |arg, i| args[2 + i] = arg;
    return args;
}

test "catalog keeps registry order and stable ids" {
    try std.testing.expectEqualStrings("claude-acp", catalog[0].id);
    try std.testing.expectEqualStrings("auggie", catalog[catalog.len - 1].id);
    try std.testing.expectEqual(@as(usize, 12), catalog.len);
    for (&catalog) |*entry| {
        try std.testing.expect(entry.id.len > 0);
        try std.testing.expect(entry.display_name.len > 0);
    }
}

test "findByCatalogId matches ids and rejects unknown ids" {
    try std.testing.expectEqualStrings(
        "Gemini CLI",
        findByCatalogId("gemini").?.display_name,
    );
    try std.testing.expect(findByCatalogId("no-such-agent") == null);
}

test "detect reports unavailable or npx fallback for absent binaries" {
    const alloc = std.testing.allocator;
    const absent = AgentCatalogEntry{
        .id = "absent-agent",
        .display_name = "Absent",
        .description = "",
        .path_candidates = &.{"fx-definitely-absent-binary-xyz"},
        .npx_package = null,
    };
    var detection = try detect(alloc, &absent);
    defer detection.deinit(alloc);
    try std.testing.expectEqual(DetectionStatus.unavailable, detection.status);
    try std.testing.expect(detection.resolved_command == null);

    const absent_with_npx = AgentCatalogEntry{
        .id = "absent-npx-agent",
        .display_name = "Absent Npx",
        .description = "",
        .path_candidates = &.{"fx-definitely-absent-binary-xyz"},
        .npx_package = "example-pkg",
    };
    var npx_detection = try detect(alloc, &absent_with_npx);
    defer npx_detection.deinit(alloc);
    try std.testing.expectEqual(DetectionStatus.installable_via_npx, npx_detection.status);
}

test "detect tolerates relative and unexpanded-tilde PATH entries" {
    const alloc = std.testing.allocator;
    const entry = AgentCatalogEntry{
        .id = "absent-agent",
        .display_name = "Absent",
        .description = "",
        .path_candidates = &.{"fx-definitely-absent-binary-xyz"},
        .npx_package = null,
    };
    var detection = try detectInPathValue(alloc, &entry, "~/.dotnet/tools:relative/bin::/usr/bin");
    defer detection.deinit(alloc);
    try std.testing.expectEqual(DetectionStatus.unavailable, detection.status);
}

test "detectAll covers the whole catalog and frees cleanly" {
    const alloc = std.testing.allocator;
    const detections = try detectAll(alloc);
    defer {
        for (detections) |*detection| detection.deinit(alloc);
        alloc.free(detections);
    }
    try std.testing.expectEqual(catalog.len, detections.len);
}

test "npxLaunchArgs composes package and launch args" {
    const alloc = std.testing.allocator;
    const entry = findByCatalogId("gemini").?;
    const args = try npxLaunchArgs(alloc, entry);
    defer alloc.free(args);
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("-y", args[0]);
    try std.testing.expectEqualStrings("@google/gemini-cli", args[1]);
    try std.testing.expectEqualStrings("--acp", args[2]);

    const not_npx = findByCatalogId("opencode").?;
    try std.testing.expectError(error.AcpAgentNotNpxInstallable, npxLaunchArgs(alloc, not_npx));
}
