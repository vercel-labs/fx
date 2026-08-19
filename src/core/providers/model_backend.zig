const std = @import("std");

/// First-class model transport. Distinct from `CredentialSource`, which is only
/// how fx authenticates to Vercel AI Gateway.
pub const ModelBackend = enum {
    vercel_gateway,
    chatgpt,
    grok,
    cursor,
    openai_compatible,

    pub fn label(self: ModelBackend) []const u8 {
        return switch (self) {
            .vercel_gateway => "Vercel AI Gateway",
            .chatgpt => "ChatGPT",
            .grok => "Grok",
            .cursor => "Cursor",
            .openai_compatible => "OpenAI-compatible",
        };
    }

    pub fn persistedName(self: ModelBackend) []const u8 {
        return @tagName(self);
    }

    pub fn isImplemented(self: ModelBackend) bool {
        return switch (self) {
            .vercel_gateway, .openai_compatible, .chatgpt, .grok, .cursor => true,
        };
    }

    pub fn usesGatewayBalance(self: ModelBackend) bool {
        return self == .vercel_gateway;
    }
};

pub const provider_env = "FX_PROVIDER";

pub fn parse(text: []const u8) ?ModelBackend {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.meta.stringToEnum(ModelBackend, trimmed);
}

pub fn parseStrict(text: []const u8) ?ModelBackend {
    return std.meta.stringToEnum(ModelBackend, text);
}

test "model backend round trips through its persisted name" {
    for (std.meta.tags(ModelBackend)) |backend| {
        try std.testing.expectEqual(backend, parse(@tagName(backend)).?);
        try std.testing.expectEqual(backend, parseStrict(@tagName(backend)).?);
        try std.testing.expectEqualStrings(@tagName(backend), backend.persistedName());
    }
    try std.testing.expect(parse("openai") == null);
    try std.testing.expect(parse(" vercel_gateway ") == .vercel_gateway);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parseStrict(" vercel_gateway ") == null);
}

test "model backend implementation and billing flags stay conservative" {
    try std.testing.expect(ModelBackend.vercel_gateway.isImplemented());
    try std.testing.expect(ModelBackend.openai_compatible.isImplemented());
    try std.testing.expect(ModelBackend.chatgpt.isImplemented());
    try std.testing.expect(ModelBackend.grok.isImplemented());
    try std.testing.expect(ModelBackend.cursor.isImplemented());
    try std.testing.expect(ModelBackend.vercel_gateway.usesGatewayBalance());
    try std.testing.expect(!ModelBackend.openai_compatible.usesGatewayBalance());
    try std.testing.expect(!ModelBackend.chatgpt.usesGatewayBalance());
    try std.testing.expect(!ModelBackend.grok.usesGatewayBalance());
    try std.testing.expectEqualStrings("OpenAI-compatible", ModelBackend.openai_compatible.label());
    try std.testing.expectEqualStrings("ChatGPT", ModelBackend.chatgpt.label());
    try std.testing.expectEqualStrings("Grok", ModelBackend.grok.label());
}

pub const LoginTarget = enum {
    vercel,
    chatgpt,
    grok,
    cursor,

    pub fn backend(self: LoginTarget) ?ModelBackend {
        return switch (self) {
            .vercel => .vercel_gateway,
            .chatgpt => .chatgpt,
            .grok => .grok,
            .cursor => .cursor,
        };
    }
};

pub fn parseLoginTarget(text: []const u8) ?LoginTarget {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .vercel;
    if (std.mem.eql(u8, trimmed, "vercel")) return .vercel;
    if (std.mem.eql(u8, trimmed, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, trimmed, "grok")) return .grok;
    if (std.mem.eql(u8, trimmed, "cursor")) return .cursor;
    return null;
}

test "login target parses vercel as the default and named subscription backends" {
    try std.testing.expectEqual(LoginTarget.vercel, parseLoginTarget(""));
    try std.testing.expectEqual(LoginTarget.vercel, parseLoginTarget(" vercel "));
    try std.testing.expectEqual(LoginTarget.chatgpt, parseLoginTarget("chatgpt"));
    try std.testing.expectEqual(LoginTarget.grok, parseLoginTarget(" grok "));
    try std.testing.expectEqual(LoginTarget.cursor, parseLoginTarget("cursor"));
    try std.testing.expect(parseLoginTarget("openai") == null);
    try std.testing.expectEqual(ModelBackend.chatgpt, LoginTarget.chatgpt.backend().?);
    try std.testing.expectEqual(ModelBackend.grok, LoginTarget.grok.backend().?);
    try std.testing.expectEqual(ModelBackend.vercel_gateway, LoginTarget.vercel.backend().?);
}
