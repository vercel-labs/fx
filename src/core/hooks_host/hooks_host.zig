//! fx's side of the hooks engine: the host it runs on, and later the loaded
//! hook files and the calls from each fx event. Outside code imports only this file.

pub const trust = @import("trust.zig");
pub const loader = @import("loader.zig");
pub const Runtime = @import("runtime.zig").Runtime;
pub const logPath = @import("runtime.zig").logPath;
pub const oldLogPath = @import("runtime.zig").oldLogPath;
/// Stops every hook process group still live. A signal handler may call it (R3.9).
pub const killLiveGroups = @import("live_groups.zig").killAll;
/// Stops the hook groups when a CLI surface ends by a signal, and gives the signal dispositions back after.
pub const installExitSignals = @import("exit_signals.zig").installExitSignals;
pub const restoreExitSignals = @import("exit_signals.zig").restoreExitSignals;
pub const surface_exit_signals = @import("exit_signals.zig").surface_signals;
pub const hangup_exit_signals = @import("exit_signals.zig").hangup_signals;

test {
    _ = @import("exit_signals.zig");
    _ = @import("live_groups.zig");
    _ = @import("process.zig");
    _ = @import("native.zig");
    _ = @import("trust.zig");
    _ = @import("loader.zig");
    _ = @import("runtime.zig");
}
