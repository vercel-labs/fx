//! fx's notices as transcript rows (D111, D187): a turn or a steer whose
//! text is fx's own notice, settled jobs or messages from other agents,
//! shows as status rows, never as the person's prompt. Several notices
//! that reached one turn together arrive joined; each gets its rows. The
//! live transcript and every history replay read them the same way.
const std = @import("std");
const agent_message = @import("../subagent/agent_message.zig");
const job_notice = @import("../jobs/notice.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

const close_tag = "</system-notice>";

/// The rows for `text`, or null when it is not only fx's notices. Owned by
/// `arena`.
pub fn rows(arena: Allocator, text: []const u8) !?[]const types.SemanticNotice {
    var rest = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, rest, "<system-notice")) return null;
    var out: std.ArrayList(types.SemanticNotice) = .empty;
    while (rest.len > 0) {
        if (!std.mem.startsWith(u8, rest, "<system-notice")) return null;
        const end = (std.mem.find(u8, rest, close_tag) orelse return null) + close_tag.len;
        const part = rest[0..end];
        if (job_notice.parse(arena, part)) |jobs| {
            for (jobs) |row| {
                var buf: [512]u8 = undefined;
                const safe = try text_utils.encodeTerminalSafeInline(arena, job_notice.rowText(&buf, row), 480);
                const tone: types.NoticeTone = if (job_notice.rowFailed(row)) .@"error" else if (std.mem.eql(u8, row.state, "cancelled")) .cancelled else .success;
                try out.append(arena, .{ .topic = "", .tone = tone, .body = safe.bytes });
            }
        } else if (agent_message.parse(arena, part)) |parsed| {
            for (parsed.messages) |row| {
                const safe = try text_utils.encodeTerminalSafeInline(arena, try agent_message.rowText(arena, row, ""), 480);
                try out.append(arena, .{ .topic = "", .tone = .information, .body = safe.bytes });
            }
        } else return null;
        rest = std.mem.trimStart(u8, rest[end..], " \t\r\n");
    }
    return out.items;
}

test "joined job and agent notices become rows; anything else stays a prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const job = job_notice.open_tag ++ "{\"jobs\":[{\"id\":\"bg_1\",\"kind\":\"shell\",\"label\":\"npm test\",\"state\":\"completed\",\"duration_ms\":62000}]}\nBackground job bg_1 has completed." ++ job_notice.close_tag;
    const mails = [_]@import("../session/session_adapter.zig").Mail{.{ .id = @constCast("m1"), .seq = 1, .from = @constCast("A"), .label = @constCast("alpha"), .body = @constCast("status?") }};
    const mail = (try agent_message.build(arena, "root", &mails)).?.text;
    const both = try std.mem.concat(arena, u8, &.{ job, "\n\n", mail });
    const shown = (try rows(arena, both)).?;
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqualStrings("alpha → you · status?", shown[1].body);
    try std.testing.expect((try rows(arena, "fix the bug")) == null);
    try std.testing.expect((try rows(arena, try std.mem.concat(arena, u8, &.{ mail, " and also this" }))) == null);
}
