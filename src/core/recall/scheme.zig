//! The internal URL schemes read_file opens instead of a file. Kept free of
//! imports so permission checks can tell such a path from a file path.
const std = @import("std");

const schemes = [_][]const u8{ "history://", "agent://", "artifact://" };

/// Whether `path` names a node of the session tree rather than a file.
pub fn isInternalUrl(path: []const u8) bool {
    for (schemes) |scheme| if (std.mem.startsWith(u8, path, scheme)) return true;
    return false;
}

test "only the internal schemes count" {
    try std.testing.expect(isInternalUrl("history://"));
    try std.testing.expect(isInternalUrl("agent://w1"));
    try std.testing.expect(!isInternalUrl("./history://x"));
    try std.testing.expect(!isInternalUrl("history:/x"));
}
