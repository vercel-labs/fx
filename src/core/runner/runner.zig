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
/// The refusal text for a missing login (E5): the same text remote setup gives,
/// so placement and setup say the same thing.
pub const login_missing_text = setup_host.e5_text;
pub const RemoteClock = setup_host.Clock;
pub const ensureRemoteReady = setup_host.ensureReady;
pub const remote_trace = setup_host.debug_trace_sink;
pub const remoteCall = setup_host.callFor;

test {
    _ = @import("vercel/vercel.zig");
    _ = @import("runner_main.zig");
    _ = @import("sha256.zig");
    _ = @import("setup.zig");
    _ = @import("config_write.zig");
    _ = @import("remote_slot.zig");
    _ = @import("setup_host.zig");
}
