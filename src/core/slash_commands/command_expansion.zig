const std = @import("std");

const paste_framing = @import("../input/paste_framing.zig");

const Allocator = std.mem.Allocator;

/// A custom command expands into the composer, so it inherits the composer
/// ceiling rather than defining a second limit that could drift from it.
const max_expanded_bytes: usize = paste_framing.default_input_limits.composer_bytes;

/// Shown when a body plus its arguments would outgrow the composer.
pub const too_large_notice = "expanded command exceeds the input limit";

const Error = Allocator.Error || error{ExpandedCommandTooLarge};

const arguments_token = "$ARGUMENTS";

/// Expands `body` against the raw `args` text of one invocation.
///
/// Expansion is strictly single-pass: every substitution is appended to the
/// output and the cursor jumps past the placeholder, so text coming from the
/// user is never rescanned for placeholders. It touches no file, no process,
/// and no socket: the whole pass is a scan over two slices.
pub fn expand(alloc: Allocator, body: []const u8, args: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, cursor, '$')) |at| {
        try appendBounded(alloc, &out, body[cursor..at]);
        const placeholder = placeholderAt(body[at..], args);
        try appendBounded(alloc, &out, placeholder.text);
        cursor = at + placeholder.consumed;
    }
    try appendBounded(alloc, &out, body[cursor..]);

    return out.toOwnedSlice(alloc);
}

const Placeholder = struct {
    /// Borrowed from `body` or from `args`; the caller copies it immediately.
    text: []const u8,
    consumed: usize,
};

/// A `$` that starts no placeholder is emitted alone, so the bytes behind it
/// are re-entered as ordinary text and stay verbatim.
const literal_dollar: Placeholder = .{ .text = "$", .consumed = 1 };

fn placeholderAt(rest: []const u8, args: []const u8) Placeholder {
    std.debug.assert(rest.len > 0 and rest[0] == '$');

    if (rest.len >= 2 and rest[1] == '$') return .{ .text = "$", .consumed = 2 };
    if (std.mem.startsWith(u8, rest, arguments_token)) {
        return .{ .text = args, .consumed = arguments_token.len };
    }
    if (rest.len >= 2 and isPositional(rest[1])) {
        // `$10` is not `$1` followed by a zero: a second digit means the run
        // was never a placeholder, so it is left verbatim.
        if (rest.len >= 3 and std.ascii.isDigit(rest[2])) return literal_dollar;
        return .{ .text = positional(args, rest[1]), .consumed = 2 };
    }
    if (fallbackAt(rest, args)) |placeholder| return placeholder;
    return literal_dollar;
}

/// Matches `${N:-default}` for N in 1-9. Every other shape, including an
/// unterminated one, returns null so the text survives verbatim.
fn fallbackAt(rest: []const u8, args: []const u8) ?Placeholder {
    if (rest.len < 3 or rest[1] != '{') return null;
    if (!isPositional(rest[2])) return null;
    if (!std.mem.startsWith(u8, rest[3..], ":-")) return null;

    const default_start = "${N:-".len;
    const close = std.mem.indexOfScalarPos(u8, rest, default_start, '}') orelse return null;
    const value = positional(args, rest[2]);
    return .{
        // The default is emitted as written: expanding it would make the pass
        // recursive, and a default containing `$1` is a literal `$1`.
        .text = if (value.len > 0) value else rest[default_start..close],
        .consumed = close + 1,
    };
}

fn isPositional(byte: u8) bool {
    return byte >= '1' and byte <= '9';
}

/// Returns the `digit`-th whitespace-separated argument, or the empty string
/// when the invocation supplied fewer.
fn positional(args: []const u8, digit: u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t\r\n");
    var seen: u8 = 0;
    while (it.next()) |token| {
        seen += 1;
        if (seen == digit - '0') return token;
    }
    return "";
}

/// Checks the ceiling before every append, so an oversized expansion fails
/// with a diagnostic instead of growing the buffer toward it.
fn appendBounded(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    if (text.len > max_expanded_bytes - out.items.len) return error.ExpandedCommandTooLarge;
    try out.appendSlice(alloc, text);
}

const testing = std.testing;

fn expectExpands(body: []const u8, args: []const u8, expected: []const u8) !void {
    const expanded = try expand(testing.allocator, body, args);
    defer testing.allocator.free(expanded);
    try testing.expectEqualStrings(expected, expanded);
}

test "the epic definition of done expands in one pass" {
    try expectExpands(
        "Hello $1, full input was $ARGUMENTS",
        "Ada Lovelace",
        "Hello Ada, full input was Ada Lovelace",
    );
}

test "$ARGUMENTS keeps the original internal spacing" {
    try expectExpands("[$ARGUMENTS]", "a  b\tc", "[a  b\tc]");
}

test "positional placeholders past the supplied arguments become empty" {
    try expectExpands(
        "1=$1 2=$2 3=$3 9=$9",
        "a b",
        "1=a 2=b 3= 9=",
    );
}

test "a doubled dollar becomes one literal dollar and shields the next byte" {
    try expectExpands("$$", "a b", "$");
    try expectExpands("$$1", "a b", "$1");
    try expectExpands("$$ARGUMENTS", "a b", "$ARGUMENTS");
    try expectExpands("$$$1", "a b", "$a");
}

test "$0, $10, and $FOO are left verbatim" {
    try expectExpands("$0", "a b", "$0");
    try expectExpands("$10", "a b", "$10");
    try expectExpands("$FOO", "a b", "$FOO");
    try expectExpands("cost is 10$ today", "a b", "cost is 10$ today");
    try expectExpands("trailing $", "a b", "trailing $");
}

test "substituted argument text is never rescanned" {
    try expectExpands("$1", "$ARGUMENTS", "$ARGUMENTS");
    try expectExpands("$ARGUMENTS", "$1 $ARGUMENTS", "$1 $ARGUMENTS");
    try expectExpands("$1|$2", "$2 $1", "$2|$1");
}

test "an invocation with no arguments empties every placeholder and succeeds" {
    try expectExpands("[$ARGUMENTS][$1][$9]", "", "[][][]");
}

test "${N:-default} uses the argument when one was supplied" {
    try expectExpands("${1:-main}", "feature", "feature");
    try expectExpands("checkout ${2:-main}", "origin feature", "checkout feature");
}

test "${N:-default} falls back when the argument is missing" {
    try expectExpands("${1:-main}", "", "main");
    try expectExpands("${2:-main}", "only", "main");
    try expectExpands("${1:-}", "", "");
}

test "a default containing a placeholder is emitted verbatim" {
    try expectExpands("${1:-$1}", "", "$1");
    try expectExpands("${1:-$ARGUMENTS}", "", "$ARGUMENTS");
    try expectExpands("${1:-$2}", "", "$2");
}

test "malformed fallback forms are emitted verbatim without failing" {
    try expectExpands("${1:-", "a", "${1:-");
    try expectExpands("${0:-x}", "a", "${0:-x}");
    try expectExpands("${99:-x}", "a", "${99:-x}");
    try expectExpands("${1}", "a", "${1}");
    try expectExpands("${1:x}", "a", "${1:x}");
    try expectExpands("${", "a", "${");
    try expectExpands("$", "a", "$");
}

test "expansion fails with a diagnostic instead of outgrowing the composer" {
    const alloc = testing.allocator;
    const args = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(args);
    @memset(args, 'x');

    // Nine copies of a one-megabyte argument overshoot the eight-megabyte
    // composer ceiling, and the failure lands before the buffer reaches it.
    try testing.expectError(
        error.ExpandedCommandTooLarge,
        expand(alloc, "$1$1$1$1$1$1$1$1$1", args),
    );

    const under = try expand(alloc, "$1$1", args);
    defer alloc.free(under);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), under.len);
}

test "the expansion ceiling tracks the composer limit" {
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), max_expanded_bytes);
    try testing.expectEqual(
        paste_framing.default_input_limits.forOwner(.composer),
        max_expanded_bytes,
    );
}
