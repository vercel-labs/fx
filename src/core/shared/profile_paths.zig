const std = @import("std");

const Allocator = std.mem.Allocator;

pub const root_dir_name = ".fx";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
pub const prompt_history_file_name = "history.jsonl";
pub const usage_file_name = "usage.jsonl";
pub const usage_recovery_dir_name = "usage-recovery";
pub const backups_dir_name = "backups";
pub const mcp_credentials_dir_name = "mcp-credentials";
pub const mcp_credentials_file_name = "credentials.json";
pub const settings_file_name = "settings.json";
pub const mcp_config_file_name = "mcp.json";
pub const managed_skills_dir_name = "skills";
pub const memories_file_name = "memories.json";
pub const logs_dir_name = "logs";
pub const trace_log_file_name = "trace.log";
pub const recordings_dir_name = "recordings";
pub const global_instructions_file_name = "AGENTS.md";

/// A root that is not absolute cannot produce a usable profile path, so every helper reports
/// it instead of silently building a path relative to the working directory.
pub const PathError = Allocator.Error || error{ProfileRootNotAbsolute};

/// Every helper below takes the resolved root the entry belongs to, never `$HOME`, so one
/// change of root moves every path consistently. A root must be absolute: joining a relative
/// one would silently produce a path relative to the working directory.
fn joinRoot(alloc: Allocator, root: []const u8, segments: []const []const u8) PathError![]u8 {
    if (!std.fs.path.isAbsolute(root)) return error.ProfileRootNotAbsolute;

    var parts: [3][]const u8 = undefined;
    parts[0] = root;
    for (segments, 1..) |segment, index| parts[index] = segment;
    return std.fs.path.join(alloc, parts[0 .. segments.len + 1]);
}

pub fn settingsPath(alloc: Allocator, config_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, config_root, &.{settings_file_name});
}

pub fn mcpConfigPath(alloc: Allocator, config_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, config_root, &.{mcp_config_file_name});
}

pub fn backupsDir(alloc: Allocator, config_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, config_root, &.{backups_dir_name});
}

pub fn mcpCredentialsDir(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{mcp_credentials_dir_name});
}

pub fn mcpCredentialsPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{ mcp_credentials_dir_name, mcp_credentials_file_name });
}

pub fn authPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{auth_file_name});
}

pub fn chatgptAuthPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{chatgpt_auth_file_name});
}

pub fn grokAuthPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{grok_auth_file_name});
}

pub fn apiKeyPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{api_key_file_name});
}

pub fn sessionsDir(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{sessions_dir_name});
}

pub fn promptHistoryPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{prompt_history_file_name});
}

pub fn logsDir(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{logs_dir_name});
}

pub fn traceLogPath(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{ logs_dir_name, trace_log_file_name });
}

pub fn recordingsDir(alloc: Allocator, state_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, state_root, &.{recordings_dir_name});
}

pub fn managedSkillsDir(alloc: Allocator, data_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, data_root, &.{managed_skills_dir_name});
}

pub fn memoriesPath(alloc: Allocator, data_root: []const u8) PathError![]u8 {
    return joinRoot(alloc, data_root, &.{memories_file_name});
}

const profile_roots = @import("profile_roots.zig");

test "profile path helpers keep every entry under a legacy root" {
    const alloc = std.testing.allocator;

    var roots = try profile_roots.resolve(alloc, .{ .home = "/tmp/fake-home" }, .{
        .os_tag = .linux,
        .has_legacy_profile = true,
    });
    defer roots.deinit(alloc);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx", roots.config);
    try std.testing.expectEqual(profile_roots.Layout.legacy, roots.layout);

    const settings = try settingsPath(alloc, roots.config);
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/settings.json", settings);

    const mcp = try mcpConfigPath(alloc, roots.config);
    defer alloc.free(mcp);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/mcp.json", mcp);

    const backups = try backupsDir(alloc, roots.config);
    defer alloc.free(backups);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/backups", backups);

    const mcp_credentials_dir = try mcpCredentialsDir(alloc, roots.state);
    defer alloc.free(mcp_credentials_dir);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials",
        mcp_credentials_dir,
    );

    const mcp_credentials = try mcpCredentialsPath(alloc, roots.state);
    defer alloc.free(mcp_credentials);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials/credentials.json",
        mcp_credentials,
    );

    const auth = try authPath(alloc, roots.state);
    defer alloc.free(auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/auth.json", auth);

    const chatgpt_auth = try chatgptAuthPath(alloc, roots.state);
    defer alloc.free(chatgpt_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/chatgpt-auth.json", chatgpt_auth);

    const grok_auth = try grokAuthPath(alloc, roots.state);
    defer alloc.free(grok_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/grok-auth.json", grok_auth);

    const api_key = try apiKeyPath(alloc, roots.state);
    defer alloc.free(api_key);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/api-key", api_key);

    const sessions = try sessionsDir(alloc, roots.state);
    defer alloc.free(sessions);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/sessions", sessions);

    const history = try promptHistoryPath(alloc, roots.state);
    defer alloc.free(history);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/history.jsonl", history);

    const logs = try logsDir(alloc, roots.state);
    defer alloc.free(logs);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs", logs);

    const trace = try traceLogPath(alloc, roots.state);
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs/trace.log", trace);

    const recordings = try recordingsDir(alloc, roots.state);
    defer alloc.free(recordings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/recordings", recordings);

    const skills = try managedSkillsDir(alloc, roots.data);
    defer alloc.free(skills);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/skills", skills);

    const memories = try memoriesPath(alloc, roots.data);
    defer alloc.free(memories);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/memories.json", memories);
}

test "profile path helpers freeze the XDG layout too" {
    const alloc = std.testing.allocator;

    var roots = try profile_roots.resolve(alloc, .{
        .home = "/home/tester",
        .config_home = "/x/cfg",
        .state_home = "/x/st",
        .data_home = "/x/dat",
    }, .{ .os_tag = .linux, .allow_xdg_layout = true });
    defer roots.deinit(alloc);

    const cases = [_]struct {
        path: []u8,
        expected: []const u8,
    }{
        .{ .path = try settingsPath(alloc, roots.config), .expected = "/x/cfg/fx/settings.json" },
        .{ .path = try mcpConfigPath(alloc, roots.config), .expected = "/x/cfg/fx/mcp.json" },
        .{ .path = try backupsDir(alloc, roots.config), .expected = "/x/cfg/fx/backups" },
        .{ .path = try authPath(alloc, roots.state), .expected = "/x/st/fx/auth.json" },
        .{
            .path = try chatgptAuthPath(alloc, roots.state),
            .expected = "/x/st/fx/chatgpt-auth.json",
        },
        .{ .path = try grokAuthPath(alloc, roots.state), .expected = "/x/st/fx/grok-auth.json" },
        .{ .path = try apiKeyPath(alloc, roots.state), .expected = "/x/st/fx/api-key" },
        .{ .path = try mcpCredentialsDir(alloc, roots.state), .expected = "/x/st/fx/mcp-credentials" },
        .{
            .path = try mcpCredentialsPath(alloc, roots.state),
            .expected = "/x/st/fx/mcp-credentials/credentials.json",
        },
        .{ .path = try sessionsDir(alloc, roots.state), .expected = "/x/st/fx/sessions" },
        .{ .path = try promptHistoryPath(alloc, roots.state), .expected = "/x/st/fx/history.jsonl" },
        .{ .path = try logsDir(alloc, roots.state), .expected = "/x/st/fx/logs" },
        .{ .path = try traceLogPath(alloc, roots.state), .expected = "/x/st/fx/logs/trace.log" },
        .{ .path = try recordingsDir(alloc, roots.state), .expected = "/x/st/fx/recordings" },
        .{ .path = try managedSkillsDir(alloc, roots.data), .expected = "/x/dat/fx/skills" },
        .{ .path = try memoriesPath(alloc, roots.data), .expected = "/x/dat/fx/memories.json" },
    };
    defer for (cases) |case| alloc.free(case.path);

    for (cases) |case| try std.testing.expectEqualStrings(case.expected, case.path);
}

test "profile path helpers reject a root that is not absolute" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.ProfileRootNotAbsolute, settingsPath(alloc, "fx"));
    try std.testing.expectError(error.ProfileRootNotAbsolute, sessionsDir(alloc, "./fx"));
    try std.testing.expectError(error.ProfileRootNotAbsolute, memoriesPath(alloc, ""));
    try std.testing.expectError(error.ProfileRootNotAbsolute, traceLogPath(alloc, "../fx"));
}
