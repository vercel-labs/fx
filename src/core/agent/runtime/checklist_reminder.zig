//! The reminder a turn gets when the model stops with checklist tasks
//! still open (D232), as proto's checklist tracker sends it: the reply
//! stays in the turn, a hidden reminder that is never saved lists the open
//! tasks, and the turn goes on. A turn gets at most `reminder_cap`
//! reminders, and none again until the model has run a tool since the last
//! one. A reply that asks the person something, and blocked tasks, never
//! bring one.
const std = @import("std");
const types = @import("../../shared/types.zig");
const runtime_deps = @import("deps.zig");
const checklist = @import("../../checklist/checklist.zig");
const summary = @import("../../checklist/summary.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const reminder_cap = summary.reminder_cap;

/// One turn's reminders so far.
pub const State = struct {
    sent: usize = 0,
    /// The turn's message count when the last reminder went out.
    sent_at: ?usize = null,
};

/// Returns whether the turn goes on.
pub fn remind(
    deps: *const runtime_deps.AgentRuntimeDeps,
    arena: Allocator,
    messages: *std.ArrayList(ChatMessage),
    state: *State,
    reply: []const u8,
    replay: ?types.ProviderReplay,
) !bool {
    const store = deps.checklist orelse return false;
    if (state.sent >= reminder_cap) return false;
    if (state.sent_at) |at| if (!ranToolSince(messages.items, at)) return false;
    if (asksThePerson(reply)) return false;
    var list = (try store.snapshot(arena)) orelse return false;
    defer list.deinit();
    if (list.countWhere(checklist.isOpen) == 0) return false;
    state.sent += 1;
    try messages.append(arena, .{ .role = .assistant, .content = reply, .provider_replay = replay, .standalone_response = true });
    try messages.append(arena, .{ .role = .user, .content = try summary.reminder(arena, &list, state.sent) });
    state.sent_at = messages.items.len;
    try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });
    publishNotice(deps, try summary.reminderNotice(arena, &list, state.sent));
    return true;
}

/// A notice row under the `checklist` topic, as stream rules show theirs.
fn publishNotice(deps: *const runtime_deps.AgentRuntimeDeps, body: []const u8) void {
    // Event payloads travel through the worker queue, which frees them with
    // the process allocator.
    const owned = types.dupeSemanticNotice(std.heap.c_allocator, .{ .topic = "checklist", .tone = .warning, .body = body }) catch return;
    deps.push_event(deps.ctx, .{ .semantic_notice = owned }) catch {
        types.freeSemanticNotice(std.heap.c_allocator, owned);
    };
}

fn ranToolSince(messages: []const ChatMessage, at: usize) bool {
    if (at > messages.len) return false;
    for (messages[at..]) |message| if (message.role == .tool) return true;
    return false;
}

/// Whether the reply ends by asking the person something, so the turn
/// waits on them, not on the checklist.
pub fn asksThePerson(reply: []const u8) bool {
    const text = std.mem.trimEnd(u8, reply, " \t\r\n");
    const start = if (std.mem.findScalarLast(u8, text, '\n')) |index| index + 1 else 0;
    const last = std.mem.trim(u8, text[start..], " \t*_>`");
    if (last.len == 0) return false;
    if (std.mem.endsWith(u8, last, "?") or std.mem.endsWith(u8, last, "？")) return true;
    const cues = [_][]const u8{ "please confirm", "confirm", "let me know", "tell me", "reply", "choose", "pick", "decide" };
    var lower_buf: [64]u8 = undefined;
    const head = std.ascii.lowerString(&lower_buf, last[0..@min(last.len, lower_buf.len)]);
    for (cues) |cue| if (std.mem.startsWith(u8, head, cue)) return true;
    return false;
}

test "a reply that asks the person brings no reminder" {
    try std.testing.expect(asksThePerson("Done with step one.\nShould I also update the docs?"));
    try std.testing.expect(asksThePerson("Let me know which option you prefer."));
    try std.testing.expect(!asksThePerson("All done. Tests pass."));
    try std.testing.expect(!asksThePerson(""));
}
