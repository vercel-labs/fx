//! The words for an MCP host's sign-in notices. A server's name, its sign-in
//! address, and a failure's reason come from configuration or the network, so
//! each is bounded and made terminal safe before it reaches a transcript. The
//! terminal app and the ACP host both show these notices.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

pub const Text = struct {
    /// Owned by the allocator passed to `format`.
    text: []u8,
    warning: bool,
};

const server_bytes = 160;
const url_bytes = 16 * 1024;
const reason_bytes = 240;

/// The notice's text, or null for a notice that has none: a needed login is
/// shown by status, not as a message.
pub fn format(alloc: Allocator, notice: runtime.Notice) !?Text {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (notice) {
        .authorize => |n| .{
            .text = try alloc.print("Sign in to {s} in your browser. If it didn't open, go to:\n  {s}", .{
                try safe(arena, n.server, server_bytes),
                try safe(arena, n.url, url_bytes),
            }),
            .warning = false,
        },
        .signed_in => |server| .{
            .text = try alloc.print("Signed in to {s}.", .{try safe(arena, server, server_bytes)}),
            .warning = false,
        },
        .sign_in_failed => |n| .{
            .text = try alloc.print("Couldn't sign in to {s}: {s}.", .{
                try safe(arena, n.server, server_bytes),
                try safe(arena, n.reason, reason_bytes),
            }),
            .warning = true,
        },
        .needs_login => null,
        .not_saved => |n| blk: {
            const server = try safe(arena, n.server, server_bytes);
            break :blk .{
                .text = try alloc.print("Couldn't save {s}'s new login: {s}. It keeps working here, but after a restart {s} needs a login again.", .{
                    server,
                    try safe(arena, n.reason, reason_bytes),
                    server,
                }),
                .warning = true,
            };
        },
    };
}

fn safe(arena: Allocator, raw: []const u8, max: usize) ![]const u8 {
    return (try text_utils.encodeTerminalSafeInline(arena, raw, max)).bytes;
}

test "format makes a server's name and reason terminal safe" {
    const alloc = std.testing.allocator;
    const failed = (try format(alloc, .{ .sign_in_failed = .{ .server = "evil\x1b[2J", .reason = "bad\nreason" } })).?;
    defer alloc.free(failed.text);
    try std.testing.expect(failed.warning);
    try std.testing.expect(std.mem.findScalar(u8, failed.text, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, failed.text, '\n') == null);

    const signed_in = (try format(alloc, .{ .signed_in = "linear" })).?;
    defer alloc.free(signed_in.text);
    try std.testing.expectEqualStrings("Signed in to linear.", signed_in.text);
    try std.testing.expect(!signed_in.warning);

    try std.testing.expect(try format(alloc, .{ .needs_login = "linear" }) == null);
}
