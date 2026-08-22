const model_provider = @import("../config/model_provider.zig");
const std = @import("std");

pub const Id = enum {
    vercel,
    codex,
    grok,
    opencode,

    pub fn slug(self: Id) []const u8 {
        return switch (self) {
            .vercel => "vercel",
            .codex => "codex",
            .grok => "grok",
            .opencode => "opencode",
        };
    }

    pub fn provider(self: Id) model_provider.ProviderId {
        return switch (self) {
            .vercel => .gateway,
            .codex => .codex,
            .grok => .grok,
            .opencode => .opencode,
        };
    }
};

pub const Entry = struct {
    id: Id,
    name: []const u8,
    description: []const u8,
    subscription: bool,
    login_available: bool = true,
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
        .id = .opencode,
        .name = "OpenCode Go",
        .description = "OpenCode Go API key from OPENCODE_API_KEY",
        .subscription = false,
        .login_available = false,
    },
};

pub fn parse(value: []const u8) ?Id {
    if (std.ascii.eqlIgnoreCase(value, "vercel") or
        std.ascii.eqlIgnoreCase(value, "ai-gateway")) return .vercel;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "opencode")) return .opencode;
    return null;
}

pub fn find(id: Id) *const Entry {
    for (&entries) |*entry| if (entry.id == id) return entry;
    unreachable;
}

test "auth provider catalog exposes subscription providers and OpenCode" {
    try std.testing.expectEqual(Id.vercel, parse("vercel").?);
    try std.testing.expectEqual(Id.codex, parse("codex").?);
    try std.testing.expectEqual(Id.grok, parse("grok").?);
    try std.testing.expectEqual(Id.opencode, parse("OpenCode").?);
    try std.testing.expectEqual(model_provider.ProviderId.opencode, find(.opencode).id.provider());
    try std.testing.expect(!find(.opencode).subscription);
    try std.testing.expect(!find(.opencode).login_available);
    try std.testing.expect(find(.codex).subscription);
    try std.testing.expect(find(.grok).subscription);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse("unknown") == null);
}
