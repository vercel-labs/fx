//! The prompts fx sends on its own to get a turn going again: "Summarize what
//! you just did." after silent tool steps, a request to continue after a reply
//! with no text and no tool call (`src/core/agent/runtime/orchestrator.zig`
//! `appendContinuationPrompt`), and the request to go on from the last tool
//! result after a model refuses to continue an assistant message.
//!
//! A turn saves each one in its steering list at the boundary where it sent
//! it, so the next turn's request starts with every message the last request
//! carried and the provider's prompt cache still covers them. Steering
//! otherwise holds what the user typed, so a saved prompt travels inside a
//! marker here, which every reader that replays or counts steering uses to
//! tell it from the user's words, as `agent_frame.isFrame` does for a
//! subagent's report.

const std = @import("std");

const Allocator = std.mem.Allocator;

const open = "<fx_recovery_prompt>\n";
const close = "\n</fx_recovery_prompt>";

/// The steering text a turn saves for `prompt`. The caller owns the result.
pub fn saved(alloc: Allocator, prompt: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(alloc, u8, &.{ open, prompt, close });
}

/// The prompt a saved steering entry holds, or null when `text` is not one,
/// as for everything the user typed. Borrows `text`.
pub fn fromSaved(text: []const u8) ?[]const u8 {
    if (text.len < open.len + close.len) return null;
    if (!std.mem.startsWith(u8, text, open) or !std.mem.endsWith(u8, text, close)) return null;
    return text[open.len .. text.len - close.len];
}

test "a saved prompt comes back as written, and the user's words never do" {
    const alloc = std.testing.allocator;
    const text = try saved(alloc, "Summarize what you just did.");
    defer alloc.free(text);
    try std.testing.expectEqualStrings("Summarize what you just did.", fromSaved(text).?);

    try std.testing.expect(fromSaved("Summarize what you just did.") == null);
    try std.testing.expect(fromSaved("") == null);
    try std.testing.expect(fromSaved(open) == null);
    try std.testing.expect(fromSaved(open ++ "no end") == null);
    try std.testing.expect(fromSaved("no start" ++ close) == null);
}
