const std = @import("std");

const Allocator = std.mem.Allocator;

pub const root_dir_name = ".fx";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
/// Side folders older v2 sessions kept (D27): v1's per-session layout, one
/// folder per session id. A session moves out on its first open (D47).
pub const session_files_dir_name = "session-files";
/// Hosted terminal state of v2 sessions, one folder per session id (D45).
pub const terminal_dir_name = "terminal";
pub const prompt_history_file_name = "history.jsonl";
pub const usage_file_name = "usage.jsonl";
pub const usage_recovery_dir_name = "usage-recovery";
pub const backups_dir_name = "backups";
pub const mcp_credentials_dir_name = "mcp-credentials";
pub const mcp_credentials_file_name = "credentials.json";

const settings_file_name = "settings.json";
const mcp_config_file_name = "mcp.json";
const managed_skills_dir_name = "skills";
const logs_dir_name = "logs";
const trace_log_file_name = "trace.log";
const recordings_dir_name = "recordings";

/// The folder `FX_HOME` names, set once at startup by `useFxHome` before any
/// other thread runs. Null means fx keeps its files in `~/.fx`.
var fx_home: ?[]const u8 = null;

pub const FxHomeError = error{ FxHomeNotAbsolute, FxHomeIsRoot, FxHomeIsHome };

/// Points every profile path at `value`, which must be an absolute path
/// other than `/` and other than `home`: fx keeps its folder private, which
/// would close the home folder to everyone else. Trailing slashes are
/// ignored, and an empty value leaves the default. `value` must outlive the
/// process, as an environment string does.
pub fn useFxHome(value: []const u8, home: ?[]const u8) FxHomeError!void {
    const trimmed = std.mem.trimEnd(u8, value, "/");
    if (value.len == 0) return;
    if (!std.Io.Dir.path.isAbsolute(value)) return error.FxHomeNotAbsolute;
    if (trimmed.len == 0) return error.FxHomeIsRoot;
    if (home) |path| if (std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, path, "/"))) return error.FxHomeIsHome;
    fx_home = trimmed;
}

/// The folder that holds `$FX_HOME`, or null when it isn't set. fx uses it
/// as the home folder when `HOME` is unset, since profile paths then come
/// from `FX_HOME` alone.
pub fn fxHomeParent() ?[]const u8 {
    const root = fx_home orelse return null;
    return std.Io.Dir.path.dirname(root) orelse "/";
}

/// Whether `FX_HOME` moved fx's folder for this process.
pub fn fxHomeActive() bool {
    return fx_home != null;
}

const display_default = "~/" ++ root_dir_name;
const display_moved = "$FX_HOME";

/// How messages name fx's folder: `~/.fx`, or `$FX_HOME` when it is set.
pub fn displayRoot() []const u8 {
    return if (fx_home != null) display_moved else display_default;
}

/// `text` as written, with each `~/.fx` read as `$FX_HOME` when it is set.
/// Both versions are built at compile time.
pub fn displayText(comptime text: []const u8) []const u8 {
    const moved = comptime movedText(text);
    return if (fx_home != null) moved else text;
}

fn movedText(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var out: []const u8 = "";
        var rest: []const u8 = text;
        while (std.mem.find(u8, rest, display_default)) |at| {
            out = out ++ rest[0..at] ++ display_moved;
            rest = rest[at + display_default.len ..];
        }
        return out ++ rest;
    }
}

/// Writes runtime `text` the way `displayText` reads it.
pub fn writeDisplayText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (fx_home == null) return writer.writeAll(text);
    var rest = text;
    while (std.mem.find(u8, rest, display_default)) |at| {
        try writer.writeAll(rest[0..at]);
        try writer.writeAll(display_moved);
        rest = rest[at + display_default.len ..];
    }
    try writer.writeAll(rest);
}

/// The folder that holds fx's folder: `home`, or the parent of `$FX_HOME`.
/// Code that opens fx's folder without following symlinks opens this, then
/// `rootName()` inside it.
pub fn rootParent(home: []const u8) []const u8 {
    const root = fx_home orelse return home;
    return std.Io.Dir.path.dirname(root) orelse "/";
}

/// The name of fx's folder inside `rootParent`: `.fx`, or the last part of
/// `$FX_HOME`.
pub fn rootName() []const u8 {
    const root = fx_home orelse return root_dir_name;
    return std.Io.Dir.path.basename(root);
}

/// Joins `parts` under fx's folder. The caller owns the result.
pub fn rootPath(alloc: Allocator, home: []const u8, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(alloc);
    try all.appendSlice(alloc, &.{ rootParent(home), rootName() });
    try all.appendSlice(alloc, parts);
    return std.Io.Dir.path.join(alloc, all.items);
}

pub fn rootDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{});
}

/// fx's folder as `fx status` shows it, or null when neither `FX_HOME` nor
/// `home` names one. The caller owns the result.
pub fn activeRoot(alloc: Allocator, home: ?[]const u8) !?[]u8 {
    if (fx_home == null and home == null) return null;
    return try rootDir(alloc, home orelse "");
}

pub fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{settings_file_name});
}

pub fn mcpConfigPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{mcp_config_file_name});
}

pub fn mcpCredentialsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{mcp_credentials_dir_name});
}

pub fn mcpCredentialsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ mcp_credentials_dir_name, mcp_credentials_file_name });
}

pub fn managedSkillsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{managed_skills_dir_name});
}

pub fn authPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{auth_file_name});
}

pub fn chatgptAuthPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{chatgpt_auth_file_name});
}

pub fn apiKeyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{api_key_file_name});
}

pub fn sessionsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{sessions_dir_name});
}

pub fn promptHistoryPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{prompt_history_file_name});
}

pub fn backupsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{backups_dir_name});
}

pub fn logsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{logs_dir_name});
}

pub fn traceLogPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ logs_dir_name, trace_log_file_name });
}

pub const diagnostics_dir_name = "diagnostics";
pub const last_shutdown_report_file_name = "last-shutdown.json";

pub fn lastShutdownReportPath(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{ diagnostics_dir_name, last_shutdown_report_file_name });
}

pub fn recordingsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return rootPath(alloc, home, &.{recordings_dir_name});
}

test "profile path helpers preserve current default locations" {
    const alloc = std.testing.allocator;

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx", root);

    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/settings.json", settings);

    const mcp = try mcpConfigPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/mcp.json", mcp);

    const mcp_credentials_dir = try mcpCredentialsDir(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials_dir);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials",
        mcp_credentials_dir,
    );

    const mcp_credentials = try mcpCredentialsPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials/credentials.json",
        mcp_credentials,
    );

    const skills = try managedSkillsDir(alloc, "/tmp/fake-home");
    defer alloc.free(skills);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/skills", skills);

    const auth = try authPath(alloc, "/tmp/fake-home");
    defer alloc.free(auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/auth.json", auth);

    const chatgpt_auth = try chatgptAuthPath(alloc, "/tmp/fake-home");
    defer alloc.free(chatgpt_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/chatgpt-auth.json", chatgpt_auth);

    const api_key = try apiKeyPath(alloc, "/tmp/fake-home");
    defer alloc.free(api_key);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/api-key", api_key);

    const sessions = try sessionsDir(alloc, "/tmp/fake-home");
    defer alloc.free(sessions);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/sessions", sessions);

    const history = try promptHistoryPath(alloc, "/tmp/fake-home");
    defer alloc.free(history);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/history.jsonl", history);

    const backups = try backupsDir(alloc, "/tmp/fake-home");
    defer alloc.free(backups);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/backups", backups);

    const logs = try logsDir(alloc, "/tmp/fake-home");
    defer alloc.free(logs);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs", logs);

    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs/trace.log", trace);

    const recordings = try recordingsDir(alloc, "/tmp/fake-home");
    defer alloc.free(recordings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/recordings", recordings);
}

test "FX_HOME moves every profile path and how messages name it" {
    const alloc = std.testing.allocator;
    defer fx_home = null;

    try std.testing.expectEqualStrings("~/.fx", displayRoot());
    try std.testing.expectEqualStrings("/tmp/fake-home", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings(".fx", rootName());
    try std.testing.expectEqualStrings("back up ~/.fx/sessions", displayText("back up ~/.fx/sessions"));
    try useFxHome("", null);
    try std.testing.expect(!fxHomeActive());
    try std.testing.expectError(error.FxHomeNotAbsolute, useFxHome("profiles/work", null));
    try std.testing.expectError(error.FxHomeIsRoot, useFxHome("///", null));
    try std.testing.expectError(error.FxHomeIsHome, useFxHome("/Users/me/", "/Users/me"));
    try std.testing.expect(!fxHomeActive());

    try useFxHome("/tmp/fx-profile/", "/Users/me");
    try std.testing.expectEqualStrings("/tmp", fxHomeParent().?);
    try std.testing.expect(fxHomeActive());
    try std.testing.expectEqualStrings("$FX_HOME", displayRoot());
    try std.testing.expectEqualStrings(
        "back up $FX_HOME/sessions, or $FX_HOME/backups",
        displayText("back up ~/.fx/sessions, or ~/.fx/backups"),
    );
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeDisplayText(&writer, "edit ~/.fx/settings.json");
    try std.testing.expectEqualStrings("edit $FX_HOME/settings.json", writer.buffered());
    try std.testing.expectEqualStrings("/tmp", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings("fx-profile", rootName());

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fx-profile", root);
    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fx-profile/settings.json", settings);
    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fx-profile/logs/trace.log", trace);

    try useFxHome("/fx", null);
    try std.testing.expectEqualStrings("/", rootParent("/tmp/fake-home"));
    try std.testing.expectEqualStrings("fx", rootName());
}
