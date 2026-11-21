//! Limits that keep one hook from slowing down or flooding fx.

const std = @import("std");

/// How long one hook may run when it sets no timeout of its own.
pub const default_timeout_ms: u32 = 60_000;
/// The longest timeout a hook may ask for.
pub const max_timeout_ms: u32 = 600_000;
/// The most characters in each of these, per field: added context, a reason, continue text,
/// a stop reason, and a message. A longer one is cut, and the person sees a notice.
pub const text_chars: usize = 10_000;
/// How many times Stop may keep one turn going.
pub const stop_continuations_per_turn: u8 = 3;
/// How many times SubagentStop may keep one subagent going.
pub const subagent_stop_continuations: u8 = 3;
/// The most stdout bytes fx reads from one hook.
pub const stdout_bytes: usize = 1024 * 1024;
/// The most stderr bytes fx reads from one hook.
pub const stderr_bytes: usize = 64 * 1024;
/// The most bytes in a hook id.
pub const hook_id_bytes: usize = 128;
/// The most bytes in a hook matcher.
pub const matcher_bytes: usize = 1024;
/// The most hooks fx reads from one file.
pub const hooks_per_file: usize = 256;

/// Text after a cut, and whether the cut took anything away.
const Cut = struct { text: []const u8, was_cut: bool };

/// Returns the longest prefix of `text` with at most `max_chars` characters, cut only on
/// a UTF-8 boundary. The result borrows `text`; no memory is allocated.
pub fn cutChars(text: []const u8, max_chars: usize) Cut {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (count == max_chars) return .{ .text = text[0..i], .was_cut = true };
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const len = if (i + seq_len > text.len) 1 else seq_len;
        count += 1;
        i += len;
    }
    return .{ .text = text, .was_cut = false };
}

test "cutChars keeps short text whole" {
    const wide = cutChars("hello", 10);
    try std.testing.expectEqualStrings("hello", wide.text);
    try std.testing.expect(!wide.was_cut);

    const cut = cutChars("hello", 3);
    try std.testing.expectEqualStrings("hel", cut.text);
    try std.testing.expect(cut.was_cut);

    const exact = cutChars("hello", 5);
    try std.testing.expectEqualStrings("hello", exact.text);
    try std.testing.expect(!exact.was_cut);
}

test "cutChars cuts on a UTF-8 boundary" {
    const cut = cutChars("héllo", 2);
    try std.testing.expectEqual(@as(usize, 3), cut.text.len);
    try std.testing.expectEqualStrings("hé", cut.text);
    try std.testing.expect(cut.was_cut);
}

test "cutChars counts a three-byte sequence as one character" {
    const cut = cutChars("日本語", 2);
    try std.testing.expectEqual(@as(usize, 6), cut.text.len);
    try std.testing.expectEqualStrings("日本", cut.text);
    try std.testing.expect(cut.was_cut);
}

test "cutChars with zero characters" {
    const one = cutChars("a", 0);
    try std.testing.expectEqualStrings("", one.text);
    try std.testing.expect(one.was_cut);

    const empty = cutChars("", 0);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expect(!empty.was_cut);
}

test "cutChars treats an invalid byte as one character" {
    const cut = cutChars("\xffab", 1);
    try std.testing.expectEqual(@as(usize, 1), cut.text.len);
    try std.testing.expectEqualStrings("\xff", cut.text);
    try std.testing.expect(cut.was_cut);
}

test "cutChars keeps a truncated sequence at the end" {
    const whole = cutChars("a\xe6", 5);
    try std.testing.expectEqual(@as(usize, 2), whole.text.len);
    try std.testing.expectEqualStrings("a\xe6", whole.text);
    try std.testing.expect(!whole.was_cut);
}
