//! Front door of the Rex session rename: in a Rex tab, fx names the Rex
//! session after the main chat's title when Rex's rename option is on.

pub const plan = @import("plan.zig");
pub const answers = @import("answers.zig");
pub const queue = @import("queue.zig");
pub const gate = @import("gate.zig");
pub const rex_cli = @import("rex_cli.zig");
pub const renamer = @import("renamer.zig");

pub const Renamer = renamer.Renamer;
pub const Request = renamer.Request;

test {
    _ = plan;
    _ = answers;
    _ = queue;
    _ = gate;
    _ = rex_cli;
    _ = renamer;
}
