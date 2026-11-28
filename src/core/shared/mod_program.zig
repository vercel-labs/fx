const std = @import("std");

pub const ResolveError = std.mem.Allocator.Error || error{
    InvalidProgram,
    PathTooLong,
};

/// Resolves a mod program path against `base_dir`: bare command names stay as
/// written (except `.` and `..`, which are refused when `base_dir != null`),
/// absolute paths stay as written, and relative paths containing `/` resolve
/// inside `base_dir` while refusing any `..` segment or trailing `/`. When
/// `base_dir` is null (non-mod settings), any relative path containing `/` is
/// refused. Caller owns the returned slice.
pub fn resolve(alloc: std.mem.Allocator, program: []const u8, base_dir: ?[]const u8) ResolveError![]u8 {
    if (program.len == 0 or std.mem.findScalar(u8, program, 0) != null) return error.InvalidProgram;
    if (program[0] != '/' and std.mem.findScalar(u8, program, '/') != null) {
        const base = base_dir orelse return error.InvalidProgram;
        if (hasDotDotSegment(program) or program[program.len - 1] == '/') return error.InvalidProgram;
        const resolved = try std.Io.Dir.path.resolve(alloc, &.{ base, program });
        if (resolved.len > std.Io.Dir.max_path_bytes) {
            alloc.free(resolved);
            return error.PathTooLong;
        }
        return resolved;
    }
    if (base_dir != null and (std.mem.eql(u8, program, ".") or std.mem.eql(u8, program, ".."))) {
        return error.InvalidProgram;
    }
    return alloc.dupe(u8, program);
}

fn hasDotDotSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return true;
    }
    return false;
}

test "resolve handles relative, bare, and absolute programs across bases and refuses .. escapes" {
    const alloc = std.testing.allocator;
    const link_base = "/tmp/fx-home/mods/glm";
    const pinned_base = "/tmp/fx-home/mods/.store/glm-0123456789abcdef";

    const rel_link = try resolve(alloc, "bin/helper", link_base);
    defer alloc.free(rel_link);
    try std.testing.expectEqualStrings("/tmp/fx-home/mods/glm/bin/helper", rel_link);

    const dot_pinned = try resolve(alloc, "./bin/helper", pinned_base);
    defer alloc.free(dot_pinned);
    try std.testing.expectEqualStrings("/tmp/fx-home/mods/.store/glm-0123456789abcdef/bin/helper", dot_pinned);

    const bare = try resolve(alloc, "node", pinned_base);
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("node", bare);

    const abs = try resolve(alloc, "/usr/local/bin/node", pinned_base);
    defer alloc.free(abs);
    try std.testing.expectEqualStrings("/usr/local/bin/node", abs);

    // Without a mod base, relative paths containing '/' are refused.
    try std.testing.expectError(error.InvalidProgram, resolve(alloc, "bin/helper", null));
    const bare_no_base = try resolve(alloc, "node", null);
    defer alloc.free(bare_no_base);
    try std.testing.expectEqualStrings("node", bare_no_base);

    for ([_][]const u8{ "", "../outside", "bin/../../outside", "bin/..", "./../outside", "bin/", "..", ".", "bin\x00x" }) |bad| {
        try std.testing.expectError(error.InvalidProgram, resolve(alloc, bad, pinned_base));
    }
}
