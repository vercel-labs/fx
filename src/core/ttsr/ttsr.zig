//! Time-traveling stream rules (TTSR): rules that watch the model's output
//! as it streams and step in the moment it breaks one, ported from proto.
//!
//! This is the module's front door. `discovery.zig` finds the rules,
//! `coordinator.zig` enforces them for one turn, and `cli_ttsr.zig` in
//! `core/cli` lists, tests and scans them.
pub const rule = @import("rule.zig");
pub const settings = @import("settings.zig");
pub const discovery = @import("discovery.zig");
pub const matcher = @import("matcher.zig");
pub const evaluate = @import("evaluate.zig");
pub const manager = @import("manager.zig");
pub const coordinator = @import("coordinator.zig");
pub const envelope = @import("envelope.zig");
pub const judge = @import("judge.zig");
pub const paths = @import("paths.zig");

pub const Coordinator = coordinator.Coordinator;
pub const Injection = coordinator.Injection;
pub const Settings = settings.Settings;

test {
    _ = @import("regex.zig");
    _ = @import("yaml.zig");
    _ = @import("regions.zig");
    _ = @import("paths.zig");
    _ = @import("ast.zig");
    _ = @import("shell_code.zig");
    _ = @import("rule.zig");
    _ = @import("settings.zig");
    _ = @import("discovery.zig");
    _ = @import("matcher_tests.zig");
    _ = @import("envelope.zig");
    _ = @import("ledger.zig");
    _ = @import("manager.zig");
    _ = @import("judge.zig");
    _ = @import("coordinator_tests.zig");
}
