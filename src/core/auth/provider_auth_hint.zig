//! What to do when a configured provider refuses its credential (D205). A
//! built-in preset signs in again through login; a provider the user
//! defined in models.json reads the key its definition names.
const std = @import("std");
const provider_registry = @import("../config/provider_registry.zig");

/// Where the fix is typed: the terminal UI's `/login`, or the CLI.
pub const Surface = enum { terminal, cli };

/// Writes the fix for `provider` (a configured provider's id).
pub fn write(writer: *std.Io.Writer, provider: []const u8, surface: Surface) !void {
    const preset = provider_registry.presetFor(provider) orelse {
        try writer.print("Check the API key the {s} definition in models.json names.", .{provider});
        return;
    };
    switch (surface) {
        .terminal => try writer.print("Run /login {s}", .{preset.id}),
        .cli => try writer.print("Run `proto-fx login {s}`", .{preset.id}),
    }
    switch (preset.login) {
        .claude_or_key => try writer.writeAll(" to use your Claude Code login (sign it in again with `claude auth login`), or a new token or API key."),
        .browser_or_key, .key, .cursor => try writer.writeAll(" to sign in again or save a new key."),
    }
}

test "presets point at login and user providers at their definition" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, "anthropic", .terminal);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "Run /login anthropic to use your Claude Code login"));
    out.clearRetainingCapacity();
    try write(&out.writer, "openrouter", .cli);
    try std.testing.expectEqualStrings("Run `proto-fx login openrouter` to sign in again or save a new key.", out.written());
    out.clearRetainingCapacity();
    try write(&out.writer, "local", .terminal);
    try std.testing.expectEqualStrings("Check the API key the local definition in models.json names.", out.written());
}
