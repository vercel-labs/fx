//! Places a shell command in a sandbox through a provider program. Outside code imports only this file.

const std = @import("std");
const policy = @import("policy.zig");
const launch = @import("launch.zig");
const runner_main = @import("runner_main.zig");
const text_utils = @import("../shared/text_utils.zig");

/// The word after the binary name that starts the built-in runner (spec L4).
pub const subcommand = runner_main.subcommand;
/// The built-in runner's process entry, called first in `main` (spec L4).
pub const runBuiltin = runner_main.runBuiltin;
/// The exit code of a run that did not start (spec L6).
pub const exit_did_not_run = runner_main.exit_did_not_run;

pub const LastRemote = policy.LastRemote;
pub const readLastRemote = policy.readLastRemote;

pub const SetupPromptContext = struct {
    fx_bin: []const u8,
    sandbox_team: ?[]const u8 = null,
    sandbox_project: ?[]const u8 = null,
    last_destination: ?LastRemote = null,
};

/// Builds the `/sandbox setup` prompt as the user's turn from the current settings,
/// the last saved destination, and the running fx binary path. Pure (no I/O).
pub fn setupPrompt(alloc: std.mem.Allocator, ctx: SetupPromptContext) std.mem.Allocator.Error![]u8 {
    const bin = try setup_host.fxCommandWord(alloc, ctx.fx_bin);
    defer alloc.free(bin);
    const team_value = text_utils.terminalSafe(ctx.sandbox_team orelse "not set");
    const project_value = text_utils.terminalSafe(ctx.sandbox_project orelse "not set");
    var last_buf: [512]u8 = undefined;
    const last_text: []const u8 = if (ctx.last_destination) |dest|
        std.mem.print(&last_buf, "{f} / {f}", .{
            text_utils.terminalSafe(dest.team_slug),
            text_utils.terminalSafe(dest.project_name),
        }) catch "none yet"
    else
        "none yet";

    return alloc.print(
        \\Help me choose where fx runs remote shell commands: the Vercel team and project of fx's remote runner.
        \\Current settings:
        \\- {s}: {f}
        \\- {s}: {f}
        \\- Last destination used: {s}
        \\When {s} is not set, fx finds the team itself (from the Vercel CLI's current team or the account's default team) and uses project fx-sandbox when {s} is not set; do not guess the CLI's current team or inspect Vercel CLI files yourself.
        \\1. Show my current choice from the facts above.
        \\2. If the Vercel CLI is installed, list my teams with `vercel teams ls`, and ask me with the ask tool which team to use, with keeping the current choice as one option.
        \\3. Then list the projects of that one team with `vercel project ls --scope <team>`, and ask me which project to use, with fx-sandbox as one option. If a Vercel command waits for a login, stop it and ask me instead.
        \\4. Save my answer with `{s} config set {s} <slug>` and `{s} config set {s} <name>`, or go back to the defaults with `{s} config unset {s}` and `{s} config unset {s}`.
        \\fx asks me again before it first copies a repository to a team or project I have not used.
    ,
        .{
            team_setting_key,
            team_value,
            project_setting_key,
            project_value,
            last_text,
            team_setting_key,
            project_setting_key,
            bin,
            team_setting_key,
            bin,
            project_setting_key,
            bin,
            team_setting_key,
            bin,
            project_setting_key,
        },
    );
}

pub const Policy = policy.Policy;
pub const PlaceError = policy.PlaceError;
pub const Refusal = policy.Refusal;
pub const Placed = policy.Placed;
pub const load = policy.load;
pub const loadForProcess = policy.loadForProcess;

pub const Launch = launch.Launch;
pub const Profile = launch.Profile;
pub const invocation = launch.invocation;
pub const duplicateLaunch = launch.duplicate;

const decide_module = @import("decide.zig");

pub const decide = decide_module.decide;
pub const Request = decide_module.Request;
pub const Decision = decide_module.Decision;
pub const Reason = decide_module.Reason;
pub const reasonLine = decide_module.reasonLine;
pub const timeoutLine = decide_module.timeoutLine;
pub const forceStopLine = decide_module.forceStopLine;

const setup_host = @import("setup_host.zig");

pub const RemoteHost = setup_host.Host;
pub const RemoteCall = setup_host.Call;
pub const RemoteResult = setup_host.Result;
pub const SetupIntent = setup_host.SetupIntent;
pub const team_setting_key = setup_host.team_setting_key;
pub const project_setting_key = setup_host.project_setting_key;
/// The refusal text for a missing login (E5): the same text remote setup gives,
/// so placement and setup say the same thing.
pub const login_missing_text = setup_host.e5_text;
pub const login_expired_text = setup_host.e6_text;
pub const no_channel_text = setup_host.e7_text;
pub const declined_text = setup_host.e8_text;
pub const sub_agent_text = setup_host.e10_text;
pub const repoKey = policy.repoKey;
pub const RemoteClock = setup_host.Clock;
pub const ensureRemoteReady = setup_host.ensureReady;
pub const remote_trace = setup_host.debug_trace_sink;
pub const remoteCall = setup_host.callFor;
pub const settingsErrorText = setup_host.settingsErrorText;
pub const runningBinaryPath = setup_host.runningBinaryPath;

const consent = @import("consent.zig");
pub const writeConsentForTest = consent.write;

test {
    _ = @import("vercel/vercel.zig");
    _ = @import("runner_main.zig");
    _ = @import("sha256.zig");
    _ = @import("setup.zig");
    _ = @import("config_write.zig");
    _ = @import("remote_slot.zig");
    _ = @import("consent.zig");
    _ = @import("setup_host.zig");
}

test "setupPrompt includes fx path, settings, last destination, and no-guess rule" {
    const alloc = std.testing.allocator;
    const defaults = try setupPrompt(alloc, .{ .fx_bin = "/opt/fx/bin/fx" });
    defer alloc.free(defaults);
    try std.testing.expect(std.mem.find(u8, defaults, "sandbox_team: not set") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "sandbox_project: not set") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "Last destination used: none yet") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "/opt/fx/bin/fx config set sandbox_team <slug>") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "/opt/fx/bin/fx config unset sandbox_team") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "do not guess") != null);
    // One team's projects only, and never a wait on a login prompt (a SAML team's
    // `vercel project ls` waits for a browser login).
    try std.testing.expect(std.mem.find(u8, defaults, "Then list the projects of that one team with `vercel project ls --scope <team>`") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "If a Vercel command waits for a login, stop it and ask me instead.") != null);
    try std.testing.expect(std.mem.find(u8, defaults, "list my choices") == null);

    const configured = try setupPrompt(alloc, .{
        .fx_bin = "/opt/fx/bin/fx",
        .sandbox_team = "acme",
        .sandbox_project = "my-proj",
        .last_destination = .{ .team_slug = "old-team", .project_name = "fx-sandbox" },
    });
    defer alloc.free(configured);
    try std.testing.expect(std.mem.find(u8, configured, "sandbox_team: acme") != null);
    try std.testing.expect(std.mem.find(u8, configured, "sandbox_project: my-proj") != null);
    try std.testing.expect(std.mem.find(u8, configured, "Last destination used: old-team / fx-sandbox") != null);
}

test "setupPrompt quotes an fx path that a shell would split" {
    const alloc = std.testing.allocator;
    const prompt = try setupPrompt(alloc, .{ .fx_bin = "/Users/example/My Tools/fx" });
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "`'/Users/example/My Tools/fx' config set sandbox_team <slug>`") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "`'/Users/example/My Tools/fx' config unset sandbox_project`") != null);
}
