//! Where a shell command runs: on this machine or in a sandbox. Settings
//! decide it, never the model. The decision is pure: no I/O, no allocation,
//! and no clock.
const std = @import("std");
const command_environment = @import("command_environment.zig");
const wildcard = @import("../shared/wildcard.zig");

pub const Placement = command_environment.Placement;

/// A placement plus, for `.isolated`, the name of the isolated profile to
/// use. A null profile means the profile named `default`.
pub const Decision = struct {
    placement: Placement = .local,
    profile: ?[]const u8 = null,
};

pub const Rule = struct {
    /// A command pattern, matched like a permission rule: `*` matches any run
    /// of characters and `?` matches one character.
    pattern: []const u8,
    decision: Decision,
};

pub const Policy = struct {
    /// The decision when no rule matches. An untrusted workspace sets it to
    /// `.isolated`.
    default: Decision = .{},
    /// Checked in order; the first rule that matches wins.
    rules: []const Rule = &.{},
};

/// The decision for `command` under `policy`. Leading and trailing
/// whitespace in the command does not count.
pub fn decide(policy: Policy, command: []const u8) Decision {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    for (policy.rules) |rule| {
        if (wildcard.match(rule.pattern, trimmed)) return rule.decision;
    }
    return policy.default;
}

test "placement is local with no policy" {
    try std.testing.expectEqual(Placement.local, decide(.{}, "zig build test").placement);
    try std.testing.expectEqual(Placement.local, decide(.{}, "").placement);
}

test "placement follows the first matching rule" {
    const rules = [_]Rule{
        .{ .pattern = "zig build*", .decision = .{ .placement = .workspace } },
        .{ .pattern = "zig*", .decision = .{ .placement = .isolated } },
    };
    const policy: Policy = .{ .rules = &rules };

    try std.testing.expectEqual(Placement.workspace, decide(policy, "zig build test").placement);
    try std.testing.expectEqual(Placement.workspace, decide(policy, "  zig build\n").placement);
    try std.testing.expectEqual(Placement.isolated, decide(policy, "zig fmt src").placement);
    try std.testing.expectEqual(Placement.local, decide(policy, "git status").placement);
}

test "an untrusted workspace runs isolated unless a rule says otherwise" {
    const rules = [_]Rule{
        .{ .pattern = "git status", .decision = .{ .placement = .local } },
    };
    const policy: Policy = .{ .default = .{ .placement = .isolated }, .rules = &rules };

    try std.testing.expectEqual(Placement.isolated, decide(policy, "npm install").placement);
    try std.testing.expectEqual(Placement.local, decide(policy, "git status").placement);
    try std.testing.expectEqual(Placement.isolated, decide(policy, "git status -s").placement);
}

test "a rule can name an isolated profile" {
    const rules = [_]Rule{
        .{ .pattern = "convert *", .decision = .{ .placement = .isolated, .profile = "media" } },
    };
    const policy: Policy = .{ .rules = &rules };
    const media = decide(policy, "convert in.png out.jpg");
    try std.testing.expectEqual(Placement.isolated, media.placement);
    try std.testing.expectEqualStrings("media", media.profile.?);
    try std.testing.expectEqual(@as(?[]const u8, null), decide(policy, "ls").profile);
}
