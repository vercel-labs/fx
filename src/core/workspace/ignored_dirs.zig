const std = @import("std");

pub const ignored_directory_names: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};

pub fn pathContainsIgnoredDirectory(path: []const u8) bool {
    var it = std.Io.Dir.path.componentIterator(path);
    while (it.next()) |component| {
        if (isIgnoredDirectoryName(component.name)) return true;
    }
    return false;
}

pub fn isIgnoredDirectoryName(name: []const u8) bool {
    for (ignored_directory_names) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

test "pathContainsIgnoredDirectory detects ignored path components" {
    try std.testing.expect(pathContainsIgnoredDirectory("node_modules/pkg/index.zig"));
    try std.testing.expect(pathContainsIgnoredDirectory("src/.git/config"));
    try std.testing.expect(pathContainsIgnoredDirectory(".zig-cache/o/file.o"));
    try std.testing.expect(pathContainsIgnoredDirectory("zig-out/bin/fx"));
    try std.testing.expect(pathContainsIgnoredDirectory(".next/server/app.js"));
    try std.testing.expect(pathContainsIgnoredDirectory("dist/app.js"));
    try std.testing.expect(pathContainsIgnoredDirectory("build/out.o"));
    try std.testing.expect(pathContainsIgnoredDirectory("coverage/lcov.info"));
}

test "pathContainsIgnoredDirectory ignores non-matching path components" {
    try std.testing.expect(!pathContainsIgnoredDirectory("src/module/index.zig"));
    try std.testing.expect(!pathContainsIgnoredDirectory("src/node_modules_backup/index.zig"));
    try std.testing.expect(!pathContainsIgnoredDirectory("src/builders/output.zig"));
}

test "isIgnoredDirectoryName detects exact ignored basenames" {
    try std.testing.expect(isIgnoredDirectoryName(".git"));
    try std.testing.expect(isIgnoredDirectoryName("node_modules"));
    try std.testing.expect(!isIgnoredDirectoryName("src/.git"));
    try std.testing.expect(!isIgnoredDirectoryName("node_modules_backup"));
}
