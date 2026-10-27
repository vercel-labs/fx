//! A browser run's row in the transcript reads by what its script does:
//! "Filled #email, clicked Sign in +1" (D199). The summary scans the
//! script's tab calls; it never runs or parses JavaScript fully.
const std = @import("std");

const Allocator = std.mem.Allocator;

const Verb = struct { method: []const u8, past: []const u8, takes_target: bool };

const verbs = [_]Verb{
    .{ .method = "click", .past = "clicked", .takes_target = true },
    .{ .method = "dblclick", .past = "double-clicked", .takes_target = true },
    .{ .method = "fill", .past = "filled", .takes_target = true },
    .{ .method = "type", .past = "typed into", .takes_target = true },
    .{ .method = "press", .past = "pressed", .takes_target = true },
    .{ .method = "select", .past = "selected in", .takes_target = true },
    .{ .method = "check", .past = "checked", .takes_target = true },
    .{ .method = "uncheck", .past = "unchecked", .takes_target = true },
    .{ .method = "hover", .past = "hovered", .takes_target = true },
    .{ .method = "goto", .past = "opened", .takes_target = true },
    .{ .method = "screenshot", .past = "took a screenshot", .takes_target = false },
    .{ .method = "observe", .past = "observed the page", .takes_target = false },
    .{ .method = "ariaSnapshot", .past = "read the ARIA tree", .takes_target = false },
    .{ .method = "extract", .past = "read the page", .takes_target = false },
    .{ .method = "text", .past = "read", .takes_target = true },
    .{ .method = "evaluate", .past = "ran page JavaScript", .takes_target = false },
    .{ .method = "scroll", .past = "scrolled", .takes_target = false },
    .{ .method = "reload", .past = "reloaded", .takes_target = false },
    .{ .method = "back", .past = "went back", .takes_target = false },
};

/// Phrases a person reads for the actions `code` takes, in order, the
/// first capitalized: "Clicked Sign in, filled #q +2". Null when the script
/// names no tab action. The result is owned by `arena`.
pub fn summarize(arena: Allocator, code: []const u8) !?[]const u8 {
    var phrases: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        if (code[index] != '.') continue;
        const rest = code[index + 1 ..];
        for (verbs) |verb| {
            if (!std.mem.startsWith(u8, rest, verb.method)) continue;
            const after = rest[verb.method.len..];
            if (after.len == 0 or after[0] != '(') continue;
            var phrase: []const u8 = verb.past;
            if (verb.takes_target) {
                if (firstStringArg(after[1..])) |target| {
                    phrase = try std.mem.concat(arena, u8, &.{ verb.past, " ", readable(target) });
                } else if (std.mem.eql(u8, verb.method, "goto")) {
                    continue;
                } else if (std.mem.eql(u8, verb.method, "text")) {
                    phrase = "read the page";
                }
            }
            // A repeated observe or screenshot reads once.
            for (phrases.items) |existing| {
                if (std.mem.eql(u8, existing, phrase)) break;
            } else try phrases.append(arena, phrase);
            index += verb.method.len;
            break;
        }
    }
    if (phrases.items.len == 0) return null;
    const shown = @min(phrases.items.len, 2);
    var out: std.ArrayList(u8) = .empty;
    for (phrases.items[0..shown], 0..) |phrase, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, phrase);
    }
    if (phrases.items.len > shown) try out.print(arena, " +{d}", .{phrases.items.len - shown});
    out.items[0] = std.ascii.toUpper(out.items[0]);
    return out.items;
}

/// The literal of a call's first argument when it is a quoted string.
fn firstStringArg(args: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, args, " \t\r\n");
    if (trimmed.len < 2) return null;
    const quote = trimmed[0];
    if (quote != '"' and quote != '\'' and quote != '`') return null;
    var end: usize = 1;
    while (end < trimmed.len and trimmed[end] != quote) {
        if (trimmed[end] == '\\') {
            end += 2;
            continue;
        }
        if (trimmed[end] == '\n') return null;
        end += 1;
    }
    if (end >= trimmed.len) return null;
    return trimmed[1..end];
}

/// A selector or URL as a person says it: `text/Sign in` is "Sign in",
/// `aria/Search[role=searchbox]` is "Search", a URL loses its scheme.
fn readable(target: []const u8) []const u8 {
    var value = target;
    inline for (.{ "text/", "aria/", "pierce/", "xpath/", "aria-ref=" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) value = value[prefix.len..];
    }
    if (std.mem.find(u8, value, "[role=")) |at| value = value[0..at];
    inline for (.{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, value, scheme)) value = std.mem.trimEnd(u8, value[scheme.len..], "/");
    }
    if (value.len > 40) value = value[0..40];
    return value;
}

/// A URL without its scheme or trailing slash, as an "Opened" row shows it.
pub fn shortUrl(url: []const u8) []const u8 {
    return readable(url);
}

test "browser script summaries name actions in order and fold the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Clicked Sign in", (try summarize(arena, "await tab.click('text/Sign in');")).?);
    try std.testing.expectEqualStrings(
        "Filled input[name=email], pressed Enter +2",
        (try summarize(arena, "await tab.fill(\"input[name=email]\", 'a@b.c');\nawait tab.press('Enter');\nconst o = await tab.observe();\nawait tab.screenshot();")).?,
    );
    try std.testing.expectEqualStrings("Opened example.com", (try summarize(arena, "await tab.goto(`https://example.com/`)")).?);
    try std.testing.expectEqualStrings("Observed the page", (try summarize(arena, "const a = await tab.observe(); const b = await tab.observe(); return a")).?);
    try std.testing.expectEqualStrings("Clicked", (try summarize(arena, "await (await tab.id(4)).click()")).?);
    try std.testing.expect((try summarize(arena, "return 1 + 1")) == null);
    try std.testing.expectEqualStrings("example.com/a", shortUrl("https://example.com/a/"));
}
