const std = @import("std");

pub const Id = enum {
    vercel,
    codex,
    grok,
    claude,

    pub fn slug(self: Id) []const u8 {
        return switch (self) {
            .vercel => "vercel",
            .codex => "codex",
            .grok => "grok",
            .claude => "claude",
        };
    }
};

pub const Entry = struct {
    id: Id,
    name: []const u8,
    description: []const u8,
    subscription: bool,
};

pub const entries = [_]Entry{
    .{
        .id = .vercel,
        .name = "Vercel AI Gateway",
        .description = "Vercel account or AI Gateway billing",
        .subscription = false,
    },
    .{
        .id = .codex,
        .name = "Codex",
        .description = "ChatGPT Plus, Pro, Business, Enterprise, or Edu subscription",
        .subscription = true,
    },
    .{
        .id = .grok,
        .name = "Grok",
        .description = "SuperGrok or X Premium subscription",
        .subscription = true,
    },
    .{
        .id = .claude,
        .name = "Claude",
        .description = "Claude Pro, Max, Team, or Enterprise subscription",
        .subscription = true,
    },
};

pub fn parse(value: []const u8) ?Id {
    if (std.ascii.eqlIgnoreCase(value, "vercel") or
        std.ascii.eqlIgnoreCase(value, "ai-gateway")) return .vercel;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "claude")) return .claude;
    return null;
}

pub fn find(id: Id) *const Entry {
    for (&entries) |*entry| if (entry.id == id) return entry;
    unreachable;
}

test "auth provider catalog exposes subscription providers without aliases" {
    try std.testing.expectEqual(Id.vercel, parse("vercel").?);
    try std.testing.expectEqual(Id.codex, parse("codex").?);
    try std.testing.expectEqual(Id.grok, parse("grok").?);
    try std.testing.expectEqual(Id.claude, parse("claude").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expect(find(.codex).subscription);
    try std.testing.expect(find(.grok).subscription);
    try std.testing.expect(find(.claude).subscription);
}
