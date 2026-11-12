//! Rewrites text that fx already drew in one theme into another theme's
//! colors, by escape bytes. Loaded themes give each slot its own escape
//! (`theme.parse`), so each slot's color maps to its own new color.

const std = @import("std");
const shared_theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Theme = shared_theme.Theme;

pub const Token = struct {
    from: []const u8,
    to: []const u8,
};

pub const max_tokens = shared_theme.style_slot_count;

// The builtin themes share escapes between slots that change to different
// colors, so their flips keep a hand-pinned map.
const dark_to_light_builtin = [_]Token{
    .{ .from = "\x1b[1;38;5;255m", .to = "\x1b[1;38;5;235m" },
    .{ .from = "\x1b[38;5;255m", .to = "\x1b[38;5;235m" },
    .{ .from = "\x1b[1;38;5;252m", .to = "\x1b[1;38;5;238m" },
    .{ .from = "\x1b[38;5;252m", .to = "\x1b[38;5;238m" },
    .{ .from = "\x1b[38;5;250m", .to = "\x1b[38;5;241m" },
    .{ .from = "\x1b[38;5;245m", .to = "\x1b[38;5;247m" },
    .{ .from = shared_theme.fx_dark.link_style, .to = shared_theme.fx_light.link_style },
};

const light_to_dark_builtin = [_]Token{
    .{ .from = "\x1b[1;38;5;235m", .to = "\x1b[1;38;5;255m" },
    .{ .from = "\x1b[38;5;235m", .to = "\x1b[38;5;255m" },
    .{ .from = "\x1b[1;38;5;238m", .to = "\x1b[1;38;5;252m" },
    .{ .from = "\x1b[38;5;238m", .to = "\x1b[38;5;252m" },
    .{ .from = "\x1b[38;5;241m", .to = "\x1b[38;5;250m" },
    .{ .from = "\x1b[38;5;247m", .to = "\x1b[38;5;245m" },
    .{ .from = shared_theme.fx_light.link_style, .to = shared_theme.fx_dark.link_style },
};

fn isBuiltin(theme: Theme) bool {
    return std.mem.eql(u8, theme.name, shared_theme.fx_dark.name) or std.mem.eql(u8, theme.name, shared_theme.fx_light.name);
}

/// The escape rewrite map from `from` to `to`, built in `buf` or pinned for a
/// builtin-to-builtin flip. Empty when both themes have the same variant. Any
/// custom theme involved gets a map pairing each slot's old escape with its
/// new one, longest first so combined forms match before their fg-only
/// equivalents.
pub fn tokens(from: Theme, to: Theme, buf: *[max_tokens]Token) []const Token {
    if (from.light == to.light) return &.{};
    if (isBuiltin(from) and isBuiltin(to)) {
        return if (to.light) dark_to_light_builtin[0..] else light_to_dark_builtin[0..];
    }

    var n: usize = 0;
    for (0..max_tokens) |index| {
        n = appendPair(buf, n, shared_theme.styleSlot(from, index), shared_theme.styleSlot(to, index));
    }
    sortLongestFirst(buf[0..n]);
    return buf[0..n];
}

fn appendPair(buf: *[max_tokens]Token, n: usize, from: []const u8, to: []const u8) usize {
    if (from.len == 0 or std.mem.eql(u8, from, to) or n >= buf.len) return n;
    for (buf[0..n]) |existing| {
        if (std.mem.eql(u8, existing.from, from)) return n;
    }
    buf[n] = .{ .from = from, .to = to };
    return n + 1;
}

fn sortLongestFirst(map: []Token) void {
    if (map.len < 2) return;
    // The list is bounded by the theme's slots; a local insertion sort avoids
    // pulling a general block-sort implementation into this cold path.
    for (map[1..], 1..) |token, index| {
        var insert_at = index;
        while (insert_at > 0 and token.from.len > map[insert_at - 1].from.len) : (insert_at -= 1) {
            map[insert_at] = map[insert_at - 1];
        }
        map[insert_at] = token;
    }
}

/// `bytes` with each escape of `map` rewritten in one left-to-right pass, so
/// a rewritten escape is never rewritten again. Null when nothing matched.
/// Caller owns the returned slice.
pub fn rewrite(alloc: Allocator, bytes: []const u8, map: []const Token) !?[]u8 {
    if (map.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var changed = false;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == 0x1b) {
            for (map) |token| {
                if (!std.mem.startsWith(u8, bytes[index..], token.from)) continue;
                try out.writer.writeAll(token.to);
                index += token.from.len;
                changed = true;
                break;
            } else {
                try out.writer.writeByte(bytes[index]);
                index += 1;
            }
            continue;
        }
        const next = std.mem.findScalarPos(u8, bytes, index, 0x1b) orelse bytes.len;
        try out.writer.writeAll(bytes[index..next]);
        index = next;
    }

    if (!changed) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

/// The escape `escape` maps to, or null when the map does not rewrite it.
pub fn mapped(escape: []const u8, map: []const Token) ?[]const u8 {
    for (map) |token| {
        if (std.mem.eql(u8, token.from, escape)) return token.to;
    }
    return null;
}

test "custom flip maps each slot to its own color" {
    var dark = shared_theme.fx_dark;
    dark.name = "probe-dark";
    dark.inline_code_open = "\x1b[38;2;136;192;208m";
    dark.link_style = "\x1b[38;2;129;161;193m";
    var light = shared_theme.fx_light;
    light.name = "probe-light";
    light.inline_code_open = "\x1b[38;2;23;108;116m";
    light.link_style = "\x1b[38;2;0;100;176m";

    var buf: [max_tokens]Token = undefined;
    const map = tokens(dark, light, &buf);
    try std.testing.expectEqualStrings("\x1b[38;2;23;108;116m", mapped(dark.inline_code_open, map).?);
    try std.testing.expectEqualStrings("\x1b[38;2;0;100;176m", mapped(dark.link_style, map).?);

    const alloc = std.testing.allocator;
    const out = (try rewrite(alloc, "a \x1b[38;2;136;192;208mcode\x1b[39m and \x1b[38;2;129;161;193mlink\x1b[39m", map)).?;
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a \x1b[38;2;23;108;116mcode\x1b[39m and \x1b[38;2;0;100;176mlink\x1b[39m", out);
}

test "slots that share a color in one loaded theme still map to their own colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // As in many editor theme pairs: the light one shares colors the dark one keeps apart.
    const light = try shared_theme.parse(alloc,
        \\{ "type": "light", "name": "probe-light",
        \\  "colors": { "hint": "#141414", "red": "#BE1744", "diff_removed": "#BE1744" },
        \\  "syntax": { "variable": "#141414", "operator": "#141414" } }
    , .{ .truecolor = true });
    const dark = try shared_theme.parse(alloc,
        \\{ "type": "dark", "name": "probe-dark",
        \\  "colors": { "hint": "#F0F0F0", "red": "#FC6B83", "diff_removed": "#E34671" },
        \\  "syntax": { "variable": "#D6D6DD", "operator": "#D6D6DD" } }
    , .{ .truecolor = true });

    var buf: [max_tokens]Token = undefined;
    const map = tokens(light, dark, &buf);
    try std.testing.expectEqualStrings(dark.red_style, mapped(light.red_style, map).?);
    try std.testing.expectEqualStrings(dark.diff_removed_style, mapped(light.diff_removed_style, map).?);
    try std.testing.expectEqualStrings(dark.hint_style, mapped(light.hint_style, map).?);
    try std.testing.expectEqualStrings(dark.syntax.variable_style, mapped(light.syntax.variable_style, map).?);
    try std.testing.expectEqualStrings(dark.syntax.operator_style, mapped(light.syntax.operator_style, map).?);

    // And back: every slot returns to its own light color.
    const back = tokens(dark, light, &buf);
    try std.testing.expectEqualStrings(light.diff_removed_style, mapped(dark.diff_removed_style, back).?);
    try std.testing.expectEqualStrings(light.syntax.operator_style, mapped(dark.syntax.operator_style, back).?);
}

test "same variant needs no map and rewrites nothing" {
    var buf: [max_tokens]Token = undefined;
    try std.testing.expectEqual(@as(usize, 0), tokens(shared_theme.fx_dark, shared_theme.fx_dark, &buf).len);
    try std.testing.expect(try rewrite(std.testing.allocator, "\x1b[38;5;255mx", &.{}) == null);
}

test "builtin flip rewrites links both ways" {
    var buf: [max_tokens]Token = undefined;
    const to_light = tokens(shared_theme.fx_dark, shared_theme.fx_light, &buf);
    try std.testing.expectEqualStrings(shared_theme.fx_light.link_style, mapped(shared_theme.fx_dark.link_style, to_light).?);
    const to_dark = tokens(shared_theme.fx_light, shared_theme.fx_dark, &buf);
    try std.testing.expectEqualStrings(shared_theme.fx_dark.link_style, mapped(shared_theme.fx_light.link_style, to_dark).?);
}

test "a rewritten escape is not rewritten again in the same pass" {
    const map = [_]Token{
        .{ .from = "\x1b[38;5;1m", .to = "\x1b[38;5;2m" },
        .{ .from = "\x1b[38;5;2m", .to = "\x1b[38;5;3m" },
    };
    const alloc = std.testing.allocator;
    const out = (try rewrite(alloc, "\x1b[38;5;1mA\x1b[38;5;2mB", &map)).?;
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\x1b[38;5;2mA\x1b[38;5;3mB", out);
}
