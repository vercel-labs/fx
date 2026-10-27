//! `fx login` for the built-in configured providers (D147): OpenRouter's
//! browser flow, or a pasted key for OpenCode, or for Anthropic a Claude
//! subscription token or API key (D166), saved to the provider key file.
const std = @import("std");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const openrouter_oauth = @import("openrouter_oauth.zig");
const provider_keys = @import("provider_keys.zig");
const provider_registry = @import("../config/provider_registry.zig");
const Allocator = std.mem.Allocator;

pub fn run(alloc: Allocator, id: []const u8, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    const preset = provider_registry.presetFor(id) orelse return error.ConfiguredProviderUsesEnvironmentAuth;
    switch (preset.login) {
        .browser_or_key => return openrouter_oauth.runLogin(alloc, transport, url_opener),
        .key, .claude_or_key => {},
    }
    const prompt = if (preset.login == .claude_or_key)
        try alloc.print("Paste a Claude subscription token from `claude setup-token` to use Claude Code, or an Anthropic API key from {s}, and press enter:\n", .{preset.key_url})
    else
        try alloc.print("Paste your {s} API key from {s} and press enter:\n", .{ preset.name, preset.key_url });
    defer alloc.free(prompt);
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), prompt);
    var line: openrouter_oauth.LineReader = .{};
    defer line.clear();
    while (true) {
        if (try line.poll()) |text| {
            const key = std.mem.trim(u8, text, " \t\r\n");
            if (!provider_keys.validKey(key)) return error.InvalidProviderKey;
            return provider_keys.save(alloc, preset.id, key);
        }
        if (line.closed) return error.InvalidProviderKey;
        try io_mod.getIo().sleep(.fromMilliseconds(50), .awake);
    }
}
