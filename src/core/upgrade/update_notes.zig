const std = @import("std");
const update_target = @import("update_target.zig");

pub const Kind = enum {
    notes,
    changes,
};

pub const Destination = struct {
    kind: Kind,
    channel: update_target.Channel,
    version: []const u8,
    previous_revision: ?[]const u8 = null,
    revision: ?[]const u8 = null,

    pub fn writeUrl(self: Destination, writer: *std.Io.Writer) !void {
        switch (self.channel) {
            .stable => try writer.print(
                "https://fx.sh/changelog#v{s}",
                .{update_target.normalizeVersion(self.version)},
            ),
            .dev => {
                const revision = self.revision orelse return error.InvalidRevision;
                if (!update_target.isValidRevision(revision)) return error.InvalidRevision;
                if (self.previous_revision) |previous| {
                    if (!update_target.isValidRevision(previous)) return error.InvalidRevision;
                    if (!update_target.revisionsEqual(previous, revision)) {
                        try writer.print(
                            "https://github.com/vercel-labs/fx/compare/{s}...{s}",
                            .{ previous, revision },
                        );
                        return;
                    }
                }
                try writer.print(
                    "https://github.com/vercel-labs/fx/commit/{s}",
                    .{revision},
                );
            },
        }
    }

    pub fn writeHyperlinkLabel(self: Destination, writer: *std.Io.Writer) !void {
        try writer.writeByte('(');
        try writer.writeAll("\x1b]8;;");
        try self.writeUrl(writer);
        try writer.writeAll("\x1b\\\x1b[4m");
        try writeLabel(self.kind, writer);
        try writer.writeAll("\x1b[24m\x1b]8;;\x1b\\)");
    }
};

pub fn destination(
    channel: update_target.Channel,
    version: []const u8,
    previous_revision: []const u8,
    revision: []const u8,
) ?Destination {
    return switch (channel) {
        .stable => if (update_target.isValidVersion(update_target.normalizeVersion(version))) .{
            .kind = .notes,
            .channel = .stable,
            .version = version,
        } else null,
        .dev => if (update_target.isValidRevision(revision)) .{
            .kind = .changes,
            .channel = .dev,
            .version = version,
            .previous_revision = if (update_target.isValidRevision(previous_revision)) previous_revision else null,
            .revision = revision,
        } else null,
    };
}

pub fn writeLabel(kind: Kind, writer: *std.Io.Writer) !void {
    try writer.writeAll(switch (kind) {
        .notes => "notes",
        .changes => "changes",
    });
}

test "stable destination uses normalized changelog anchor" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = destination(.stable, "v0.0.8", "", "") orelse
        return error.TestExpectedDestination;
    try std.testing.expectEqual(Kind.notes, value.kind);
    try value.writeUrl(&out.writer);
    try std.testing.expectEqualStrings(
        "https://fx.sh/changelog#v0.0.8",
        out.writer.buffered(),
    );
}

test "dev destination uses compare range when both revisions are valid" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = destination(
        .dev,
        "0.0.8",
        "1111111111111111111111111111111111111111",
        "abcdef0123456789abcdef0123456789abcdef01",
    ) orelse return error.TestExpectedDestination;
    try std.testing.expectEqual(Kind.changes, value.kind);
    try value.writeUrl(&out.writer);
    try std.testing.expectEqualStrings(
        "https://github.com/vercel-labs/fx/compare/1111111111111111111111111111111111111111...abcdef0123456789abcdef0123456789abcdef01",
        out.writer.buffered(),
    );
}

test "dev destination falls back to the installed commit" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = destination(
        .dev,
        "0.0.8",
        "unknown",
        "abcdef0123456789abcdef0123456789abcdef01",
    ) orelse return error.TestExpectedDestination;
    try value.writeUrl(&out.writer);
    try std.testing.expectEqualStrings(
        "https://github.com/vercel-labs/fx/commit/abcdef0123456789abcdef0123456789abcdef01",
        out.writer.buffered(),
    );
}

test "dev destination treats a short previous revision as the same commit" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = destination(
        .dev,
        "0.0.8",
        "abcdef012345",
        "abcdef0123456789abcdef0123456789abcdef01",
    ) orelse return error.TestExpectedDestination;
    try value.writeUrl(&out.writer);
    try std.testing.expectEqualStrings(
        "https://github.com/vercel-labs/fx/commit/abcdef0123456789abcdef0123456789abcdef01",
        out.writer.buffered(),
    );
}

test "destination links only the label, not its parentheses" {
    const stable = destination(.stable, "0.0.8", "", "") orelse
        return error.TestExpectedDestination;
    const dev = destination(
        .dev,
        "0.0.8",
        "1111111111111111111111111111111111111111",
        "abcdef0123456789abcdef0123456789abcdef01",
    ) orelse return error.TestExpectedDestination;

    const cases = [_]struct {
        value: Destination,
        expected: []const u8,
    }{
        .{
            .value = stable,
            .expected = "(\x1b]8;;https://fx.sh/changelog#v0.0.8\x1b\\" ++
                "\x1b[4mnotes\x1b[24m\x1b]8;;\x1b\\)",
        },
        .{
            .value = dev,
            .expected = "(\x1b]8;;https://github.com/vercel-labs/fx/compare/1111111111111111111111111111111111111111...abcdef0123456789abcdef0123456789abcdef01\x1b\\" ++
                "\x1b[4mchanges\x1b[24m\x1b]8;;\x1b\\)",
        },
    };

    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try case.value.writeHyperlinkLabel(&out.writer);
        try std.testing.expectEqualStrings(case.expected, out.writer.buffered());
    }
}

test "invalid build identity has no destination" {
    try std.testing.expect(destination(.stable, "dev", "", "") == null);
    try std.testing.expect(destination(.dev, "0.0.8", "", "not-a-revision") == null);
}
