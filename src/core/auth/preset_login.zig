//! `fx login` for the built-in configured providers (D147): OpenRouter's
//! browser flow, or a pasted key for OpenCode, or for Anthropic a Claude
//! Code login (D184), or a subscription token or API key (D166), saved to
//! the provider key file.
const std = @import("std");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const openrouter_oauth = @import("openrouter_oauth.zig");
const cursor_oauth = @import("cursor_oauth.zig");
const provider_keys = @import("provider_keys.zig");
const provider_registry = @import("../config/provider_registry.zig");
const claude_login = @import("../../gateway/claude_login.zig");
const claude_agent = @import("../../gateway/claude_agent.zig");
const Allocator = std.mem.Allocator;

pub fn run(alloc: Allocator, id: []const u8, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    const preset = provider_registry.presetFor(id) orelse return error.ConfiguredProviderUsesEnvironmentAuth;
    switch (preset.login) {
        .browser_or_key => return openrouter_oauth.runLogin(alloc, transport, url_opener),
        .cursor => return cursor_oauth.runLogin(alloc, transport, url_opener),
        .key, .claude_or_key => {},
    }
    const stdout = std.Io.File.stdout();
    var signed_in = false;
    const prompt = if (preset.login == .claude_or_key) prompt: {
        // The installed Claude Code's own login comes first (D184).
        try stdout.writeStreamingAll(io_mod.getIo(), "Checking Claude Code\u{2026}\n");
        var status = try claude_login.check(alloc);
        defer status.deinit(alloc);
        signed_in = status == .signed_in;
        const text = try claude_login.describe(alloc, status);
        defer alloc.free(text);
        break :prompt if (signed_in)
            try alloc.print("{s}\nPress enter to use it, or paste a `claude setup-token` token or an Anthropic API key from {s} instead:\n", .{ text, preset.key_url })
        else
            try alloc.print("{s}\nOr paste a `claude setup-token` token or an Anthropic API key from {s}, and press enter:\n", .{ text, preset.key_url });
    } else try alloc.print("Paste your {s} API key from {s} and press enter:\n", .{ preset.name, preset.key_url });
    defer alloc.free(prompt);
    try stdout.writeStreamingAll(io_mod.getIo(), prompt);
    var line: openrouter_oauth.LineReader = .{};
    defer line.clear();
    while (true) {
        if (try line.poll()) |text| {
            const key = std.mem.trim(u8, text, " \t\r\n");
            if (signed_in and key.len == 0) {
                // A saved token or key would take precedence over the login.
                _ = try provider_keys.delete(alloc, preset.id);
                if (claude_agent.environmentOverride()) |name| {
                    const warning = try alloc.print("{s} is set in the environment and still takes precedence; unset it to use the Claude Code login.\n", .{name});
                    defer alloc.free(warning);
                    try stdout.writeStreamingAll(io_mod.getIo(), warning);
                }
                return;
            }
            if (!provider_keys.validKey(key)) return error.InvalidProviderKey;
            return provider_keys.save(alloc, preset.id, key);
        }
        if (line.closed) return error.InvalidProviderKey;
        try io_mod.getIo().sleep(.fromMilliseconds(50), .awake);
    }
}
