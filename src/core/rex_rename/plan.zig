//! Decides the Rex session label for a chat title, and whether fx may set it.
//! No I/O, no clock, no allocation: the caller reads Rex and carries out the
//! decision.

const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const text_utils = @import("../shared/text_utils.zig");

/// Rex refuses a longer label: `rex session rename` fails with exit 2.
pub const max_label_chars = 128;
/// Room for `max_label_chars` characters of 4 bytes each.
pub const max_label_bytes = max_label_chars * 4;

pub const Decision = enum {
    /// The label is Rex's own or the one fx asked for last, and differs.
    rename,
    /// The session already has the label.
    already_named,
    /// A person or another program named the session. fx leaves it alone.
    named_by_someone_else,
};

/// True for the label Rex gives a session that nobody named, such as
/// `morning-atoll`: two runs of lowercase ASCII letters joined by one hyphen.
pub fn isRexMadeUpLabel(label: []const u8) bool {
    const hyphen = std.mem.findScalar(u8, label, '-') orelse return false;
    return isLowercaseWord(label[0..hyphen]) and isLowercaseWord(label[hyphen + 1 ..]);
}

fn isLowercaseWord(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte < 'a' or byte > 'z') return false;
    }
    return true;
}

/// The label fx asks Rex for: `title` without control characters or broken
/// UTF-8, trimmed of spaces at both ends, and cut at a whole character after
/// `max_label_chars` characters. Null when nothing is left. The result points
/// into `out`.
pub fn labelFromTitle(title: []const u8, out: *[max_label_bytes]u8) ?[]const u8 {
    var written: usize = 0;
    var chars: usize = 0;
    var index: usize = 0;
    while (index < title.len and chars < max_label_chars) {
        const sequence = nextSequence(title, index) orelse {
            index += 1;
            continue;
        };
        index += sequence.len;
        const kept: []const u8 = switch (classify(sequence)) {
            .text => sequence,
            .space => " ",
            .dropped => continue,
        };
        @memcpy(out[written .. written + kept.len], kept);
        written += kept.len;
        chars += 1;
    }
    const label = std.mem.trim(u8, out[0..written], " ");
    return if (label.len == 0) null else label;
}

const Kind = enum { text, space, dropped };

/// The whole UTF-8 sequence that starts at `index`, or null for a byte that
/// does not start one.
fn nextSequence(title: []const u8, index: usize) ?[]const u8 {
    const len = std.unicode.utf8ByteSequenceLength(title[index]) catch return null;
    if (len > title.len - index) return null;
    const sequence = title[index .. index + len];
    _ = display_width.decodeUtf8Sequence(sequence) catch return null;
    return sequence;
}

/// Line breaks and tabs become spaces, so words stay apart. Every other C0
/// control, DEL, and C1 control is dropped: Rex refuses a label with one.
fn classify(sequence: []const u8) Kind {
    const codepoint = display_width.decodeUtf8Sequence(sequence) catch return .dropped;
    if (codepoint == '\n' or codepoint == '\r' or codepoint == '\t') return .space;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return .dropped;
    return .text;
}

/// Whether fx renames a session that has `current` to `wanted`. fx renames
/// only a session that still has Rex's made-up label, or the label fx itself
/// asked for last (`last_wanted`), so a name that a person gave stays.
pub fn decide(current: []const u8, wanted: []const u8, last_wanted: ?[]const u8) Decision {
    if (std.mem.eql(u8, current, wanted)) return .already_named;
    if (isRexMadeUpLabel(current)) return .rename;
    if (last_wanted) |label| {
        if (std.mem.eql(u8, current, label)) return .rename;
    }
    return .named_by_someone_else;
}

test "Rex's made-up labels are two lowercase words joined by one hyphen" {
    for ([_][]const u8{ "morning-atoll", "quiet-meadow", "a-b" }) |label| {
        try std.testing.expect(isRexMadeUpLabel(label));
    }
    for ([_][]const u8{
        "",
        "-",
        "morning",
        "morning-",
        "-atoll",
        "morning--atoll",
        "morning-atoll-sea",
        "Morning-atoll",
        "morning-at0ll",
        "morning atoll",
        "Fix login redirect",
        "caf\u{e9}-bar",
    }) |label| {
        try std.testing.expect(!isRexMadeUpLabel(label));
    }
}

test "a title becomes a label without control characters or outer spaces" {
    var out: [max_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Fix login redirect", labelFromTitle("  Fix login redirect \t", &out).?);
    try std.testing.expectEqualStrings("ab]2;xc", labelFromTitle("a\x07b\x1b]2;x\x7fc", &out).?);
    try std.testing.expectEqualStrings("ab", labelFromTitle("a\u{9b}b", &out).?);
    try std.testing.expectEqualStrings("caf\u{e9} ok", labelFromTitle("caf\u{e9}\xff ok", &out).?);
    try std.testing.expectEqualStrings("one two", labelFromTitle("one\ntwo", &out).?);
    try std.testing.expect(labelFromTitle("", &out) == null);
    try std.testing.expect(labelFromTitle(" \x1b\x07 ", &out) == null);
}

test "a long title is cut at a whole character after the label limit" {
    var out: [max_label_bytes]u8 = undefined;
    const ascii = labelFromTitle(text_utils.repeat("x", max_label_chars + 12), &out).?;
    try std.testing.expectEqual(@as(usize, max_label_chars), ascii.len);

    const wide = labelFromTitle(text_utils.repeat("\u{1f600}", max_label_chars + 1), &out).?;
    try std.testing.expectEqual(@as(usize, max_label_chars * 4), wide.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide));

    // A space at the cut is trimmed like any other trailing space.
    const spaced = labelFromTitle(text_utils.repeat("y", max_label_chars - 1) ++ " tail", &out).?;
    try std.testing.expectEqualStrings(text_utils.repeat("y", max_label_chars - 1), spaced);
}

test "fx renames only Rex's own label or the label it asked for last" {
    try std.testing.expectEqual(Decision.rename, decide("morning-atoll", "Fix login", null));
    try std.testing.expectEqual(Decision.rename, decide("Fix login", "Fix logout", "Fix login"));
    try std.testing.expectEqual(Decision.already_named, decide("Fix login", "Fix login", null));
    try std.testing.expectEqual(Decision.already_named, decide("Fix login", "Fix login", "Old"));
    try std.testing.expectEqual(Decision.named_by_someone_else, decide("my project", "Fix login", null));
    try std.testing.expectEqual(Decision.named_by_someone_else, decide("my project", "Fix login", "Old title"));
    // Another fx in the same session named it: its title is not this fx's.
    try std.testing.expectEqual(Decision.named_by_someone_else, decide("Other chat", "Fix login", null));
}
