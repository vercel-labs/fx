const std = @import("std");

pub const Decoded = struct {
    codepoint: u21,
    len: usize,
};

/// Decodes one unit using the native tokenizer's replacement-on-invalid
/// behavior. Invalid leading bytes consume one byte; valid UTF-8 consumes the
/// complete sequence.
pub fn decode(bytes: []const u8, index: usize) Decoded {
    if (index >= bytes.len) return .{ .codepoint = std.unicode.replacement_character, .len = 0 };
    const first = bytes[index];
    const width = std.unicode.utf8ByteSequenceLength(first) catch {
        return .{ .codepoint = std.unicode.replacement_character, .len = 1 };
    };
    if (index + width > bytes.len) return .{ .codepoint = std.unicode.replacement_character, .len = 1 };
    const slice = bytes[index .. index + width];
    const cp = std.unicode.utf8Decode(slice) catch {
        return .{ .codepoint = std.unicode.replacement_character, .len = 1 };
    };
    return .{ .codepoint = cp, .len = width };
}

pub fn encode(codepoint: u21, out: []u8) usize {
    return std.unicode.utf8Encode(codepoint, out) catch {
        out[0] = 0xef;
        if (out.len > 1) out[1] = 0xbf;
        if (out.len > 2) out[2] = 0xbd;
        return @min(out.len, 3);
    };
}

pub fn codepointAt(bytes: []const u8, index: usize) u21 {
    return decode(bytes, index).codepoint;
}
