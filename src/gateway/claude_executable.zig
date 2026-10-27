//! Finds the installed `claude` executable that the `anthropic` provider's
//! Claude Code mode drives (D165). Proto embeds the SDK's executable and
//! takes `PI_CLAUDE_EXECUTABLE` as an override; proto-fx has nothing to
//! embed, so it looks in order at `PROTO_FX_CLAUDE_EXECUTABLE`, proto's
//! variable, every `PATH` entry, then the places Claude Code's installers use.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

pub const override_env = "PROTO_FX_CLAUDE_EXECUTABLE";
pub const proto_override_env = "PI_CLAUDE_EXECUTABLE";

/// Install locations under the home directory, then absolute ones.
const home_candidates = [_][]const u8{
    ".local/bin/claude",
    ".claude/local/claude",
    ".npm-global/bin/claude",
    ".bun/bin/claude",
    ".volta/bin/claude",
};
const absolute_candidates = [_][]const u8{
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "/usr/bin/claude",
};

pub const Environment = struct {
    override: ?[]const u8 = null,
    proto_override: ?[]const u8 = null,
    path: ?[]const u8 = null,
    home: ?[]const u8 = null,

    pub fn current() Environment {
        return .{
            .override = io_mod.getenv(override_env),
            .proto_override = io_mod.getenv(proto_override_env),
            .path = io_mod.getenv("PATH"),
            .home = io_mod.homeDir(),
        };
    }
};

/// The executable's absolute path, or null when none is installed. An
/// override that names no executable file is an error rather than a silent
/// fallback, so a typo cannot pick up a different install. Caller owns it.
pub fn find(alloc: Allocator, env: Environment) !?[]u8 {
    for ([_]?[]const u8{ env.override, env.proto_override }) |maybe| {
        const value = maybe orelse continue;
        if (value.len == 0) continue;
        if (!std.Io.Dir.path.isAbsolute(value) or !executable(value)) return error.ClaudeExecutableOverrideInvalid;
        return try alloc.dupe(u8, value);
    }
    if (env.path) |path| {
        var entries = std.mem.splitScalar(u8, path, ':');
        while (entries.next()) |dir| {
            if (dir.len == 0 or !std.Io.Dir.path.isAbsolute(dir)) continue;
            const candidate = try std.Io.Dir.path.join(alloc, &.{ dir, "claude" });
            if (executable(candidate)) return candidate;
            alloc.free(candidate);
        }
    }
    if (env.home) |home| for (home_candidates) |relative| {
        const candidate = try std.Io.Dir.path.join(alloc, &.{ home, relative });
        if (executable(candidate)) return candidate;
        alloc.free(candidate);
    };
    for (absolute_candidates) |candidate| if (executable(candidate)) return try alloc.dupe(u8, candidate);
    return null;
}

/// A regular file (after symlinks) with an execute bit.
fn executable(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return stat.kind == .file and stat.permissions.toMode() & 0o111 != 0;
}

test "claude executable lookup prefers overrides, then PATH, then install dirs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "home/.local/bin");
    try tmp.dir.createDirPath(io, "empty");
    for ([_][]const u8{ "bin/claude", "home/.local/bin/claude", "custom" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "#!/bin/sh\n", .flags = .{ .permissions = .fromMode(0o755) } });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "empty/claude", .data = "", .flags = .{ .permissions = .fromMode(0o644) } });
    const bin = try std.Io.Dir.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);
    const empty = try std.Io.Dir.path.join(alloc, &.{ root, "empty" });
    defer alloc.free(empty);
    const home = try std.Io.Dir.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const custom = try std.Io.Dir.path.join(alloc, &.{ root, "custom" });
    defer alloc.free(custom);
    const path = try std.mem.concat(alloc, u8, &.{ "relative:", empty, ":", bin });
    defer alloc.free(path);

    // A file without an execute bit on PATH is skipped.
    const on_path = (try find(alloc, .{ .path = path, .home = home })).?;
    defer alloc.free(on_path);
    try std.testing.expect(std.mem.endsWith(u8, on_path, "/bin/claude"));
    const in_home = (try find(alloc, .{ .path = empty, .home = home })).?;
    defer alloc.free(in_home);
    try std.testing.expect(std.mem.endsWith(u8, in_home, "home/.local/bin/claude"));
    const overridden = (try find(alloc, .{ .proto_override = custom, .path = path, .home = home })).?;
    defer alloc.free(overridden);
    try std.testing.expectEqualStrings(custom, overridden);
    try std.testing.expectError(error.ClaudeExecutableOverrideInvalid, find(alloc, .{ .override = "claude", .path = path }));
    try std.testing.expectError(error.ClaudeExecutableOverrideInvalid, find(alloc, .{ .override = home }));
}
