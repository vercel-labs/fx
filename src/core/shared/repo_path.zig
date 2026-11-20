//! Repository-relative paths that git records as given: no empty, `.` or `..`
//! components, no leading or trailing slash, no NUL, and no `.git` component
//! in any case. git applies further platform rules (HFS and NTFS variants of
//! `.git`); callers that hand paths to git still check that git kept them.
const std = @import("std");

pub fn isValid(path: []const u8) bool {
    if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
    }
    return true;
}

test "repository paths reject traversal, git metadata and malformed separators" {
    for ([_][]const u8{ "a", "a/b", "sp ace", "tab\tnew\nline", "ñandú", ".gitignore", "a/.github/x", ".git2" }) |path| {
        try std.testing.expect(isValid(path));
    }
    for ([_][]const u8{ "", "/a", "a/", "a//b", "./a", "a/./b", "../a", "a/../b", ".git", ".git/config", "a/.GIT/x", "a\x00b" }) |path| {
        try std.testing.expect(!isValid(path));
    }
}
