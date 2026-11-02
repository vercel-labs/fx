const std = @import("std");
const user_message_card = @import("../assistant/user_message_card.zig");

pub const Rgb = user_message_card.Rgb;

pub const Background = struct {
    light: bool,
    rgb: Rgb,
};

pub const ResponseStatus = enum { invalid, pending, complete };

const primary_device_attributes_prefix = "\x1b[?";

/// Classifies a primary device attributes reply (`ESC [ ? Ps ; ... c`). Every
/// terminal answers that query, so fx sends it as a fence after a query the
/// terminal may ignore.
pub fn classifyPrimaryDeviceAttributes(bytes: []const u8) ResponseStatus {
    if (std.mem.startsWith(u8, primary_device_attributes_prefix, bytes)) return .pending;
    if (!std.mem.startsWith(u8, bytes, primary_device_attributes_prefix)) return .invalid;

    const parameters = bytes[primary_device_attributes_prefix.len..];
    var expect_digit = true;
    for (parameters, 0..) |byte, index| {
        if (std.ascii.isDigit(byte)) {
            expect_digit = false;
            continue;
        }
        if (byte == ';' and !expect_digit) {
            expect_digit = true;
            continue;
        }
        if (byte == 'c') {
            return if (!expect_digit and index + 1 == parameters.len)
                .complete
            else
                .invalid;
        }
        return .invalid;
    }
    return .pending;
}

/// Returns where a complete primary device attributes reply starts when
/// `bytes` ends with one.
pub fn trailingPrimaryDeviceAttributes(bytes: []const u8) ?usize {
    const start = std.mem.findLast(u8, bytes, primary_device_attributes_prefix) orelse return null;
    return if (classifyPrimaryDeviceAttributes(bytes[start..]) == .complete) start else null;
}

pub fn parseOsc11Response(bytes: []const u8) ?Background {
    const prefix = "\x1b]11;rgb:";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;

    const rgb_end = if (std.mem.endsWith(u8, bytes, "\x1b\\"))
        bytes.len - 2
    else if (std.mem.endsWith(u8, bytes, "\x07"))
        bytes.len - 1
    else
        return null;
    if (rgb_end <= prefix.len) return null;

    var components: [3]u32 = undefined;
    var it = std.mem.splitScalar(u8, bytes[prefix.len..rgb_end], '/');
    for (&components) |*component| {
        const part = it.next() orelse return null;
        component.* = normalizeOsc11Component(part) orelse return null;
    }
    if (it.next() != null) return null;

    const luminance = (components[0] * 299 + components[1] * 587 + components[2] * 114) / 1000;
    return .{
        .light = luminance > 32768,
        .rgb = .{
            .r = @intCast(components[0] >> 8),
            .g = @intCast(components[1] >> 8),
            .b = @intCast(components[2] >> 8),
        },
    };
}

// Terminal.app is the one mainstream terminal that quantizes 38;2 colors
// itself; every other target either sets COLORTERM or renders RGB exactly.
pub fn truecolorSupportedForValues(colorterm: ?[]const u8, term_program: ?[]const u8) bool {
    if (colorterm) |value| {
        if (std.mem.find(u8, value, "truecolor") != null) return true;
        if (std.mem.find(u8, value, "24bit") != null) return true;
    }
    if (term_program) |value| {
        if (std.mem.eql(u8, value, "Apple_Terminal")) return false;
    }
    return true;
}

test "truecolorSupportedForValues honors COLORTERM over program name" {
    try std.testing.expect(truecolorSupportedForValues("truecolor", "Apple_Terminal"));
}

test "truecolorSupportedForValues degrades Apple Terminal without COLORTERM" {
    try std.testing.expect(!truecolorSupportedForValues(null, "Apple_Terminal"));
}

test "truecolorSupportedForValues defaults to truecolor for unknown terminals" {
    try std.testing.expect(truecolorSupportedForValues(null, null));
    try std.testing.expect(truecolorSupportedForValues(null, "ghostty"));
}

pub fn parseColorFgBgLight(colorfgbg: []const u8) bool {
    var last_semi: ?usize = null;
    for (colorfgbg, 0..) |byte, i| {
        if (byte == ';') last_semi = i;
    }
    const bg_str = if (last_semi) |pos| colorfgbg[pos + 1 ..] else return false;
    const bg = std.fmt.parseUnsigned(u8, bg_str, 10) catch return false;
    return bg >= 8;
}

fn normalizeOsc11Component(part: []const u8) ?u32 {
    if (part.len == 0 or part.len > 4) return null;
    const value = std.fmt.parseUnsigned(u32, part, 16) catch return null;
    const bits: u5 = @intCast(part.len * 4);
    const maximum = (@as(u32, 1) << bits) - 1;
    return @divTrunc(value * 0xffff, maximum);
}

test "COLORFGBG parser detects light terminal" {
    try std.testing.expect(parseColorFgBgLight("0;15"));
    try std.testing.expect(parseColorFgBgLight("0;8"));
    try std.testing.expect(parseColorFgBgLight("1;3;15"));
    try std.testing.expect(!parseColorFgBgLight("15;0"));
    try std.testing.expect(!parseColorFgBgLight("0;7"));
    try std.testing.expect(!parseColorFgBgLight(""));
    try std.testing.expect(!parseColorFgBgLight("garbage"));
}

test "OSC 11 parser detects light background and extracts RGB" {
    const white = parseOsc11Response("\x1b]11;rgb:ffff/ffff/ffff\x1b\\").?;
    try std.testing.expect(white.light);
    try std.testing.expectEqual(@as(u8, 0xff), white.rgb.r);

    const near_white = parseOsc11Response("\x1b]11;rgb:f0f0/f0f0/f0f0\x07").?;
    try std.testing.expect(near_white.light);

    const black = parseOsc11Response("\x1b]11;rgb:0000/0000/0000\x1b\\").?;
    try std.testing.expect(!black.light);
    try std.testing.expectEqual(@as(u8, 0x00), black.rgb.r);

    const dark = parseOsc11Response("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\").?;
    try std.testing.expect(!dark.light);
    try std.testing.expectEqual(@as(u8, 0x1c), dark.rgb.r);

    try std.testing.expect(parseOsc11Response("garbage") == null);
}

test "OSC 11 parser normalizes one-digit RGB channels" {
    const white = parseOsc11Response("\x1b]11;rgb:f/f/f\x07").?;

    try std.testing.expect(white.light);
    try std.testing.expectEqual(@as(u8, 0xff), white.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), white.rgb.g);
    try std.testing.expectEqual(@as(u8, 0xff), white.rgb.b);
}

test "OSC 11 parser supports every RGB component width" {
    const white_samples = [_][]const u8{
        "\x1b]11;rgb:f/f/f\x07",
        "\x1b]11;rgb:ff/ff/ff\x07",
        "\x1b]11;rgb:fff/fff/fff\x07",
        "\x1b]11;rgb:ffff/ffff/ffff\x07",
    };
    const dark_samples = [_][]const u8{
        "\x1b]11;rgb:4/4/4\x07",
        "\x1b]11;rgb:44/44/44\x07",
        "\x1b]11;rgb:444/444/444\x07",
        "\x1b]11;rgb:4444/4444/4444\x07",
    };

    for (white_samples) |sample| {
        const parsed = parseOsc11Response(sample).?;
        try std.testing.expect(parsed.light);
        try std.testing.expectEqual(@as(u8, 0xff), parsed.rgb.r);
    }
    for (dark_samples) |sample| {
        const parsed = parseOsc11Response(sample).?;
        try std.testing.expect(!parsed.light);
        try std.testing.expectEqual(@as(u8, 0x44), parsed.rgb.r);
    }
}

test "OSC 11 parser rejects non-OSC-11 envelopes" {
    const invalid = [_][]const u8{
        "rgb:ffff/ffff/ffff",
        "\x1b]10;rgb:ffff/ffff/ffff\x07",
        "\x1b]11;rgb:ffff/ffff/ffff",
        "\x1b]11;rgb:ffff/ffff/ffff/ffff\x07",
        "\x1b]11;rgb:ffff/ffff\x07",
        "\x1b]11;rgb:ffff/ffff/zzzz\x07",
        "\x1b]11;rgb:fffff/ffff/ffff\x07",
        "\x1b]11;rgb:ffff/ffff/ffff\x07tail",
    };

    for (invalid) |sample| {
        try std.testing.expect(parseOsc11Response(sample) == null);
    }
}
