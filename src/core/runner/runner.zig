//! Places a shell command in a sandbox through a provider program. Outside code imports only this file.

const policy = @import("policy.zig");
const launch = @import("launch.zig");
const runner_main = @import("runner_main.zig");

/// The word after the binary name that starts the built-in runner (spec L4).
pub const subcommand = runner_main.subcommand;
/// The built-in runner's process entry, called first in `main` (spec L4).
pub const runBuiltin = runner_main.runBuiltin;
/// The exit code of a run that did not start (spec L6).
pub const exit_did_not_run = runner_main.exit_did_not_run;

/// The message `/sandbox setup` sends as the user's turn. The agent runs its
/// steps, and fx sends it unchanged.
pub const setup_prompt =
    \\Help me choose where fx runs remote shell commands: the Vercel team and project of fx's remote runner.
    \\1. Show my current choice: run `fx config get sandbox_team` and `fx config get sandbox_project`. When a value is empty, fx uses the Vercel CLI's current team (or my account's default team) and the project fx-sandbox.
    \\2. If the Vercel CLI is installed, list my choices: `vercel teams ls`, then `vercel project ls --scope <team>`.
    \\3. Ask me with the ask tool which team and project to use, with keeping the defaults as one option.
    \\4. Save my answer with `fx config set sandbox_team <slug>` and `fx config set sandbox_project <name>`, or go back to the defaults with `fx config unset sandbox_team` and `fx config unset sandbox_project`.
    \\fx asks me again before it first copies a repository to a team or project I have not used.
;

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
