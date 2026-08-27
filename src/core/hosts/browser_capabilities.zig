const std = @import("std");

pub const model_context =
    "Runtime capabilities: this is the embedded browser version of fx, not locally installed fx. " ++
    "Public web fetch, web search, and general outbound network access are unavailable. " ++
    "Do not attempt curl, wget, package managers, raw sockets, or equivalent network workarounds through terminal commands. " ++
    "If the user asks for external web content, explain this limitation immediately and say that locally installed fx provides the full tool suite. " ++
    "When a browser workspace terminal is advertised, use it only for the files and commands that workspace exposes.";

test "browser model context refuses unavailable network workarounds" {
    try std.testing.expect(std.mem.find(u8, model_context, "Public web fetch, web search, and general outbound network access are unavailable") != null);
    try std.testing.expect(std.mem.find(u8, model_context, "Do not attempt curl, wget") != null);
    try std.testing.expect(std.mem.find(u8, model_context, "locally installed fx provides the full tool suite") != null);
}
