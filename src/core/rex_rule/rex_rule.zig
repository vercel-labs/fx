//! Front door of the Rex resume rule.

pub const plan = @import("plan.zig");
pub const records = @import("records.zig");
pub const apply = @import("apply.zig");
pub const gate = @import("gate.zig");
pub const rex_cli = @import("rex_cli.zig");
pub const installer = @import("installer.zig");

pub const Installer = installer.Installer;
pub const Outcome = apply.Outcome;

test {
    _ = plan;
    _ = records;
    _ = apply;
    _ = gate;
    _ = rex_cli;
    _ = installer;
}
