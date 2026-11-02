//! Unicode 17.0 emphasis flanking classes.
//!
//! Generated from:
//! https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
//! Source SHA-256: 2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c
//!
//! Selected properties: general categories P* and S* (punctuation and
//! symbols) and Zs (space separators), which CommonMark uses to decide
//! whether a delimiter run is left or right flanking. Code points below
//! U+0080 are classified directly. To regenerate, parse the general
//! category field of UnicodeData.txt, expanding First/Last range pairs,
//! and emit maximal runs of matching code points at or above U+0080.
//!
//! Unicode data is used under https://www.unicode.org/license.txt.

const std = @import("std");

const SourceRange = struct { first: u21, last: u21 };
const PackedRange = packed struct(u32) {
    first: u21,
    span: u11,
};

/// CommonMark punctuation: any code point in general category P* or S*.
pub fn isPunctuationOrSymbol(cp: u21) bool {
    if (cp < 0x80) return cp > 0x20 and cp < 0x7f and !std.ascii.isAlphanumeric(@intCast(cp));
    return containsCodepoint(&punctuation_ranges, cp);
}

/// CommonMark whitespace: general category Zs plus tab, line feed, form
/// feed, and carriage return.
pub fn isWhitespace(cp: u21) bool {
    if (cp < 0x80) return cp == ' ' or cp == '\t' or cp == '\n' or cp == 0x0c or cp == '\r';
    return containsCodepoint(&space_ranges, cp);
}

fn containsCodepoint(ranges: []const PackedRange, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (cp < range.first) {
            hi = mid;
        } else if (cp > range.first + range.span) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn packRanges(comptime source: []const SourceRange) [source.len]PackedRange {
    var encoded: [source.len]PackedRange = undefined;
    for (source, 0..) |range, index| {
        encoded[index] = .{
            .first = range.first,
            .span = @intCast(range.last - range.first),
        };
    }
    return encoded;
}

const source_space_ranges = [_]SourceRange{
    .{ .first = 0x00A0, .last = 0x00A0 },
    .{ .first = 0x1680, .last = 0x1680 },
    .{ .first = 0x2000, .last = 0x200A },
    .{ .first = 0x202F, .last = 0x202F },
    .{ .first = 0x205F, .last = 0x205F },
    .{ .first = 0x3000, .last = 0x3000 },
};

const space_ranges = packRanges(&source_space_ranges);

const source_punctuation_ranges = [_]SourceRange{
    .{ .first = 0x00A1, .last = 0x00A9 },
    .{ .first = 0x00AB, .last = 0x00AC },
    .{ .first = 0x00AE, .last = 0x00B1 },
    .{ .first = 0x00B4, .last = 0x00B4 },
    .{ .first = 0x00B6, .last = 0x00B8 },
    .{ .first = 0x00BB, .last = 0x00BB },
    .{ .first = 0x00BF, .last = 0x00BF },
    .{ .first = 0x00D7, .last = 0x00D7 },
    .{ .first = 0x00F7, .last = 0x00F7 },
    .{ .first = 0x02C2, .last = 0x02C5 },
    .{ .first = 0x02D2, .last = 0x02DF },
    .{ .first = 0x02E5, .last = 0x02EB },
    .{ .first = 0x02ED, .last = 0x02ED },
    .{ .first = 0x02EF, .last = 0x02FF },
    .{ .first = 0x0375, .last = 0x0375 },
    .{ .first = 0x037E, .last = 0x037E },
    .{ .first = 0x0384, .last = 0x0385 },
    .{ .first = 0x0387, .last = 0x0387 },
    .{ .first = 0x03F6, .last = 0x03F6 },
    .{ .first = 0x0482, .last = 0x0482 },
    .{ .first = 0x055A, .last = 0x055F },
    .{ .first = 0x0589, .last = 0x058A },
    .{ .first = 0x058D, .last = 0x058F },
    .{ .first = 0x05BE, .last = 0x05BE },
    .{ .first = 0x05C0, .last = 0x05C0 },
    .{ .first = 0x05C3, .last = 0x05C3 },
    .{ .first = 0x05C6, .last = 0x05C6 },
    .{ .first = 0x05F3, .last = 0x05F4 },
    .{ .first = 0x0606, .last = 0x060F },
    .{ .first = 0x061B, .last = 0x061B },
    .{ .first = 0x061D, .last = 0x061F },
    .{ .first = 0x066A, .last = 0x066D },
    .{ .first = 0x06D4, .last = 0x06D4 },
    .{ .first = 0x06DE, .last = 0x06DE },
    .{ .first = 0x06E9, .last = 0x06E9 },
    .{ .first = 0x06FD, .last = 0x06FE },
    .{ .first = 0x0700, .last = 0x070D },
    .{ .first = 0x07F6, .last = 0x07F9 },
    .{ .first = 0x07FE, .last = 0x07FF },
    .{ .first = 0x0830, .last = 0x083E },
    .{ .first = 0x085E, .last = 0x085E },
    .{ .first = 0x0888, .last = 0x0888 },
    .{ .first = 0x0964, .last = 0x0965 },
    .{ .first = 0x0970, .last = 0x0970 },
    .{ .first = 0x09F2, .last = 0x09F3 },
    .{ .first = 0x09FA, .last = 0x09FB },
    .{ .first = 0x09FD, .last = 0x09FD },
    .{ .first = 0x0A76, .last = 0x0A76 },
    .{ .first = 0x0AF0, .last = 0x0AF1 },
    .{ .first = 0x0B70, .last = 0x0B70 },
    .{ .first = 0x0BF3, .last = 0x0BFA },
    .{ .first = 0x0C77, .last = 0x0C77 },
    .{ .first = 0x0C7F, .last = 0x0C7F },
    .{ .first = 0x0C84, .last = 0x0C84 },
    .{ .first = 0x0D4F, .last = 0x0D4F },
    .{ .first = 0x0D79, .last = 0x0D79 },
    .{ .first = 0x0DF4, .last = 0x0DF4 },
    .{ .first = 0x0E3F, .last = 0x0E3F },
    .{ .first = 0x0E4F, .last = 0x0E4F },
    .{ .first = 0x0E5A, .last = 0x0E5B },
    .{ .first = 0x0F01, .last = 0x0F17 },
    .{ .first = 0x0F1A, .last = 0x0F1F },
    .{ .first = 0x0F34, .last = 0x0F34 },
    .{ .first = 0x0F36, .last = 0x0F36 },
    .{ .first = 0x0F38, .last = 0x0F38 },
    .{ .first = 0x0F3A, .last = 0x0F3D },
    .{ .first = 0x0F85, .last = 0x0F85 },
    .{ .first = 0x0FBE, .last = 0x0FC5 },
    .{ .first = 0x0FC7, .last = 0x0FCC },
    .{ .first = 0x0FCE, .last = 0x0FDA },
    .{ .first = 0x104A, .last = 0x104F },
    .{ .first = 0x109E, .last = 0x109F },
    .{ .first = 0x10FB, .last = 0x10FB },
    .{ .first = 0x1360, .last = 0x1368 },
    .{ .first = 0x1390, .last = 0x1399 },
    .{ .first = 0x1400, .last = 0x1400 },
    .{ .first = 0x166D, .last = 0x166E },
    .{ .first = 0x169B, .last = 0x169C },
    .{ .first = 0x16EB, .last = 0x16ED },
    .{ .first = 0x1735, .last = 0x1736 },
    .{ .first = 0x17D4, .last = 0x17D6 },
    .{ .first = 0x17D8, .last = 0x17DB },
    .{ .first = 0x1800, .last = 0x180A },
    .{ .first = 0x1940, .last = 0x1940 },
    .{ .first = 0x1944, .last = 0x1945 },
    .{ .first = 0x19DE, .last = 0x19FF },
    .{ .first = 0x1A1E, .last = 0x1A1F },
    .{ .first = 0x1AA0, .last = 0x1AA6 },
    .{ .first = 0x1AA8, .last = 0x1AAD },
    .{ .first = 0x1B4E, .last = 0x1B4F },
    .{ .first = 0x1B5A, .last = 0x1B6A },
    .{ .first = 0x1B74, .last = 0x1B7F },
    .{ .first = 0x1BFC, .last = 0x1BFF },
    .{ .first = 0x1C3B, .last = 0x1C3F },
    .{ .first = 0x1C7E, .last = 0x1C7F },
    .{ .first = 0x1CC0, .last = 0x1CC7 },
    .{ .first = 0x1CD3, .last = 0x1CD3 },
    .{ .first = 0x1FBD, .last = 0x1FBD },
    .{ .first = 0x1FBF, .last = 0x1FC1 },
    .{ .first = 0x1FCD, .last = 0x1FCF },
    .{ .first = 0x1FDD, .last = 0x1FDF },
    .{ .first = 0x1FED, .last = 0x1FEF },
    .{ .first = 0x1FFD, .last = 0x1FFE },
    .{ .first = 0x2010, .last = 0x2027 },
    .{ .first = 0x2030, .last = 0x205E },
    .{ .first = 0x207A, .last = 0x207E },
    .{ .first = 0x208A, .last = 0x208E },
    .{ .first = 0x20A0, .last = 0x20C1 },
    .{ .first = 0x2100, .last = 0x2101 },
    .{ .first = 0x2103, .last = 0x2106 },
    .{ .first = 0x2108, .last = 0x2109 },
    .{ .first = 0x2114, .last = 0x2114 },
    .{ .first = 0x2116, .last = 0x2118 },
    .{ .first = 0x211E, .last = 0x2123 },
    .{ .first = 0x2125, .last = 0x2125 },
    .{ .first = 0x2127, .last = 0x2127 },
    .{ .first = 0x2129, .last = 0x2129 },
    .{ .first = 0x212E, .last = 0x212E },
    .{ .first = 0x213A, .last = 0x213B },
    .{ .first = 0x2140, .last = 0x2144 },
    .{ .first = 0x214A, .last = 0x214D },
    .{ .first = 0x214F, .last = 0x214F },
    .{ .first = 0x218A, .last = 0x218B },
    .{ .first = 0x2190, .last = 0x2429 },
    .{ .first = 0x2440, .last = 0x244A },
    .{ .first = 0x249C, .last = 0x24E9 },
    .{ .first = 0x2500, .last = 0x2775 },
    .{ .first = 0x2794, .last = 0x2B73 },
    .{ .first = 0x2B76, .last = 0x2BFF },
    .{ .first = 0x2CE5, .last = 0x2CEA },
    .{ .first = 0x2CF9, .last = 0x2CFC },
    .{ .first = 0x2CFE, .last = 0x2CFF },
    .{ .first = 0x2D70, .last = 0x2D70 },
    .{ .first = 0x2E00, .last = 0x2E2E },
    .{ .first = 0x2E30, .last = 0x2E5D },
    .{ .first = 0x2E80, .last = 0x2E99 },
    .{ .first = 0x2E9B, .last = 0x2EF3 },
    .{ .first = 0x2F00, .last = 0x2FD5 },
    .{ .first = 0x2FF0, .last = 0x2FFF },
    .{ .first = 0x3001, .last = 0x3004 },
    .{ .first = 0x3008, .last = 0x3020 },
    .{ .first = 0x3030, .last = 0x3030 },
    .{ .first = 0x3036, .last = 0x3037 },
    .{ .first = 0x303D, .last = 0x303F },
    .{ .first = 0x309B, .last = 0x309C },
    .{ .first = 0x30A0, .last = 0x30A0 },
    .{ .first = 0x30FB, .last = 0x30FB },
    .{ .first = 0x3190, .last = 0x3191 },
    .{ .first = 0x3196, .last = 0x319F },
    .{ .first = 0x31C0, .last = 0x31E5 },
    .{ .first = 0x31EF, .last = 0x31EF },
    .{ .first = 0x3200, .last = 0x321E },
    .{ .first = 0x322A, .last = 0x3247 },
    .{ .first = 0x3250, .last = 0x3250 },
    .{ .first = 0x3260, .last = 0x327F },
    .{ .first = 0x328A, .last = 0x32B0 },
    .{ .first = 0x32C0, .last = 0x33FF },
    .{ .first = 0x4DC0, .last = 0x4DFF },
    .{ .first = 0xA490, .last = 0xA4C6 },
    .{ .first = 0xA4FE, .last = 0xA4FF },
    .{ .first = 0xA60D, .last = 0xA60F },
    .{ .first = 0xA673, .last = 0xA673 },
    .{ .first = 0xA67E, .last = 0xA67E },
    .{ .first = 0xA6F2, .last = 0xA6F7 },
    .{ .first = 0xA700, .last = 0xA716 },
    .{ .first = 0xA720, .last = 0xA721 },
    .{ .first = 0xA789, .last = 0xA78A },
    .{ .first = 0xA828, .last = 0xA82B },
    .{ .first = 0xA836, .last = 0xA839 },
    .{ .first = 0xA874, .last = 0xA877 },
    .{ .first = 0xA8CE, .last = 0xA8CF },
    .{ .first = 0xA8F8, .last = 0xA8FA },
    .{ .first = 0xA8FC, .last = 0xA8FC },
    .{ .first = 0xA92E, .last = 0xA92F },
    .{ .first = 0xA95F, .last = 0xA95F },
    .{ .first = 0xA9C1, .last = 0xA9CD },
    .{ .first = 0xA9DE, .last = 0xA9DF },
    .{ .first = 0xAA5C, .last = 0xAA5F },
    .{ .first = 0xAA77, .last = 0xAA79 },
    .{ .first = 0xAADE, .last = 0xAADF },
    .{ .first = 0xAAF0, .last = 0xAAF1 },
    .{ .first = 0xAB5B, .last = 0xAB5B },
    .{ .first = 0xAB6A, .last = 0xAB6B },
    .{ .first = 0xABEB, .last = 0xABEB },
    .{ .first = 0xFB29, .last = 0xFB29 },
    .{ .first = 0xFBB2, .last = 0xFBD2 },
    .{ .first = 0xFD3E, .last = 0xFD4F },
    .{ .first = 0xFD90, .last = 0xFD91 },
    .{ .first = 0xFDC8, .last = 0xFDCF },
    .{ .first = 0xFDFC, .last = 0xFDFF },
    .{ .first = 0xFE10, .last = 0xFE19 },
    .{ .first = 0xFE30, .last = 0xFE52 },
    .{ .first = 0xFE54, .last = 0xFE66 },
    .{ .first = 0xFE68, .last = 0xFE6B },
    .{ .first = 0xFF01, .last = 0xFF0F },
    .{ .first = 0xFF1A, .last = 0xFF20 },
    .{ .first = 0xFF3B, .last = 0xFF40 },
    .{ .first = 0xFF5B, .last = 0xFF65 },
    .{ .first = 0xFFE0, .last = 0xFFE6 },
    .{ .first = 0xFFE8, .last = 0xFFEE },
    .{ .first = 0xFFFC, .last = 0xFFFD },
    .{ .first = 0x10100, .last = 0x10102 },
    .{ .first = 0x10137, .last = 0x1013F },
    .{ .first = 0x10179, .last = 0x10189 },
    .{ .first = 0x1018C, .last = 0x1018E },
    .{ .first = 0x10190, .last = 0x1019C },
    .{ .first = 0x101A0, .last = 0x101A0 },
    .{ .first = 0x101D0, .last = 0x101FC },
    .{ .first = 0x1039F, .last = 0x1039F },
    .{ .first = 0x103D0, .last = 0x103D0 },
    .{ .first = 0x1056F, .last = 0x1056F },
    .{ .first = 0x10857, .last = 0x10857 },
    .{ .first = 0x10877, .last = 0x10878 },
    .{ .first = 0x1091F, .last = 0x1091F },
    .{ .first = 0x1093F, .last = 0x1093F },
    .{ .first = 0x10A50, .last = 0x10A58 },
    .{ .first = 0x10A7F, .last = 0x10A7F },
    .{ .first = 0x10AC8, .last = 0x10AC8 },
    .{ .first = 0x10AF0, .last = 0x10AF6 },
    .{ .first = 0x10B39, .last = 0x10B3F },
    .{ .first = 0x10B99, .last = 0x10B9C },
    .{ .first = 0x10D6E, .last = 0x10D6E },
    .{ .first = 0x10D8E, .last = 0x10D8F },
    .{ .first = 0x10EAD, .last = 0x10EAD },
    .{ .first = 0x10ED0, .last = 0x10ED8 },
    .{ .first = 0x10F55, .last = 0x10F59 },
    .{ .first = 0x10F86, .last = 0x10F89 },
    .{ .first = 0x11047, .last = 0x1104D },
    .{ .first = 0x110BB, .last = 0x110BC },
    .{ .first = 0x110BE, .last = 0x110C1 },
    .{ .first = 0x11140, .last = 0x11143 },
    .{ .first = 0x11174, .last = 0x11175 },
    .{ .first = 0x111C5, .last = 0x111C8 },
    .{ .first = 0x111CD, .last = 0x111CD },
    .{ .first = 0x111DB, .last = 0x111DB },
    .{ .first = 0x111DD, .last = 0x111DF },
    .{ .first = 0x11238, .last = 0x1123D },
    .{ .first = 0x112A9, .last = 0x112A9 },
    .{ .first = 0x113D4, .last = 0x113D5 },
    .{ .first = 0x113D7, .last = 0x113D8 },
    .{ .first = 0x1144B, .last = 0x1144F },
    .{ .first = 0x1145A, .last = 0x1145B },
    .{ .first = 0x1145D, .last = 0x1145D },
    .{ .first = 0x114C6, .last = 0x114C6 },
    .{ .first = 0x115C1, .last = 0x115D7 },
    .{ .first = 0x11641, .last = 0x11643 },
    .{ .first = 0x11660, .last = 0x1166C },
    .{ .first = 0x116B9, .last = 0x116B9 },
    .{ .first = 0x1173C, .last = 0x1173F },
    .{ .first = 0x1183B, .last = 0x1183B },
    .{ .first = 0x11944, .last = 0x11946 },
    .{ .first = 0x119E2, .last = 0x119E2 },
    .{ .first = 0x11A3F, .last = 0x11A46 },
    .{ .first = 0x11A9A, .last = 0x11A9C },
    .{ .first = 0x11A9E, .last = 0x11AA2 },
    .{ .first = 0x11B00, .last = 0x11B09 },
    .{ .first = 0x11BE1, .last = 0x11BE1 },
    .{ .first = 0x11C41, .last = 0x11C45 },
    .{ .first = 0x11C70, .last = 0x11C71 },
    .{ .first = 0x11EF7, .last = 0x11EF8 },
    .{ .first = 0x11F43, .last = 0x11F4F },
    .{ .first = 0x11FD5, .last = 0x11FF1 },
    .{ .first = 0x11FFF, .last = 0x11FFF },
    .{ .first = 0x12470, .last = 0x12474 },
    .{ .first = 0x12FF1, .last = 0x12FF2 },
    .{ .first = 0x16A6E, .last = 0x16A6F },
    .{ .first = 0x16AF5, .last = 0x16AF5 },
    .{ .first = 0x16B37, .last = 0x16B3F },
    .{ .first = 0x16B44, .last = 0x16B45 },
    .{ .first = 0x16D6D, .last = 0x16D6F },
    .{ .first = 0x16E97, .last = 0x16E9A },
    .{ .first = 0x16FE2, .last = 0x16FE2 },
    .{ .first = 0x1BC9C, .last = 0x1BC9C },
    .{ .first = 0x1BC9F, .last = 0x1BC9F },
    .{ .first = 0x1CC00, .last = 0x1CCEF },
    .{ .first = 0x1CCFA, .last = 0x1CCFC },
    .{ .first = 0x1CD00, .last = 0x1CEB3 },
    .{ .first = 0x1CEBA, .last = 0x1CED0 },
    .{ .first = 0x1CEE0, .last = 0x1CEF0 },
    .{ .first = 0x1CF50, .last = 0x1CFC3 },
    .{ .first = 0x1D000, .last = 0x1D0F5 },
    .{ .first = 0x1D100, .last = 0x1D126 },
    .{ .first = 0x1D129, .last = 0x1D164 },
    .{ .first = 0x1D16A, .last = 0x1D16C },
    .{ .first = 0x1D183, .last = 0x1D184 },
    .{ .first = 0x1D18C, .last = 0x1D1A9 },
    .{ .first = 0x1D1AE, .last = 0x1D1EA },
    .{ .first = 0x1D200, .last = 0x1D241 },
    .{ .first = 0x1D245, .last = 0x1D245 },
    .{ .first = 0x1D300, .last = 0x1D356 },
    .{ .first = 0x1D6C1, .last = 0x1D6C1 },
    .{ .first = 0x1D6DB, .last = 0x1D6DB },
    .{ .first = 0x1D6FB, .last = 0x1D6FB },
    .{ .first = 0x1D715, .last = 0x1D715 },
    .{ .first = 0x1D735, .last = 0x1D735 },
    .{ .first = 0x1D74F, .last = 0x1D74F },
    .{ .first = 0x1D76F, .last = 0x1D76F },
    .{ .first = 0x1D789, .last = 0x1D789 },
    .{ .first = 0x1D7A9, .last = 0x1D7A9 },
    .{ .first = 0x1D7C3, .last = 0x1D7C3 },
    .{ .first = 0x1D800, .last = 0x1D9FF },
    .{ .first = 0x1DA37, .last = 0x1DA3A },
    .{ .first = 0x1DA6D, .last = 0x1DA74 },
    .{ .first = 0x1DA76, .last = 0x1DA83 },
    .{ .first = 0x1DA85, .last = 0x1DA8B },
    .{ .first = 0x1E14F, .last = 0x1E14F },
    .{ .first = 0x1E2FF, .last = 0x1E2FF },
    .{ .first = 0x1E5FF, .last = 0x1E5FF },
    .{ .first = 0x1E95E, .last = 0x1E95F },
    .{ .first = 0x1ECAC, .last = 0x1ECAC },
    .{ .first = 0x1ECB0, .last = 0x1ECB0 },
    .{ .first = 0x1ED2E, .last = 0x1ED2E },
    .{ .first = 0x1EEF0, .last = 0x1EEF1 },
    .{ .first = 0x1F000, .last = 0x1F02B },
    .{ .first = 0x1F030, .last = 0x1F093 },
    .{ .first = 0x1F0A0, .last = 0x1F0AE },
    .{ .first = 0x1F0B1, .last = 0x1F0BF },
    .{ .first = 0x1F0C1, .last = 0x1F0CF },
    .{ .first = 0x1F0D1, .last = 0x1F0F5 },
    .{ .first = 0x1F10D, .last = 0x1F1AD },
    .{ .first = 0x1F1E6, .last = 0x1F202 },
    .{ .first = 0x1F210, .last = 0x1F23B },
    .{ .first = 0x1F240, .last = 0x1F248 },
    .{ .first = 0x1F250, .last = 0x1F251 },
    .{ .first = 0x1F260, .last = 0x1F265 },
    .{ .first = 0x1F300, .last = 0x1F6D8 },
    .{ .first = 0x1F6DC, .last = 0x1F6EC },
    .{ .first = 0x1F6F0, .last = 0x1F6FC },
    .{ .first = 0x1F700, .last = 0x1F7D9 },
    .{ .first = 0x1F7E0, .last = 0x1F7EB },
    .{ .first = 0x1F7F0, .last = 0x1F7F0 },
    .{ .first = 0x1F800, .last = 0x1F80B },
    .{ .first = 0x1F810, .last = 0x1F847 },
    .{ .first = 0x1F850, .last = 0x1F859 },
    .{ .first = 0x1F860, .last = 0x1F887 },
    .{ .first = 0x1F890, .last = 0x1F8AD },
    .{ .first = 0x1F8B0, .last = 0x1F8BB },
    .{ .first = 0x1F8C0, .last = 0x1F8C1 },
    .{ .first = 0x1F8D0, .last = 0x1F8D8 },
    .{ .first = 0x1F900, .last = 0x1FA57 },
    .{ .first = 0x1FA60, .last = 0x1FA6D },
    .{ .first = 0x1FA70, .last = 0x1FA7C },
    .{ .first = 0x1FA80, .last = 0x1FA8A },
    .{ .first = 0x1FA8E, .last = 0x1FAC6 },
    .{ .first = 0x1FAC8, .last = 0x1FAC8 },
    .{ .first = 0x1FACD, .last = 0x1FADC },
    .{ .first = 0x1FADF, .last = 0x1FAEA },
    .{ .first = 0x1FAEF, .last = 0x1FAF8 },
    .{ .first = 0x1FB00, .last = 0x1FB92 },
    .{ .first = 0x1FB94, .last = 0x1FBEF },
    .{ .first = 0x1FBFA, .last = 0x1FBFA },
};

const punctuation_ranges = packRanges(&source_punctuation_ranges);

test "flanking classes follow Unicode general categories" {
    try std.testing.expect(isPunctuationOrSymbol(0x2014)); // em dash, Pd
    try std.testing.expect(isPunctuationOrSymbol(0x201C)); // left double quote, Pi
    try std.testing.expect(isPunctuationOrSymbol(0x00D7)); // multiplication sign, Sm
    try std.testing.expect(isPunctuationOrSymbol(0xFF0C)); // fullwidth comma, Po
    try std.testing.expect(isPunctuationOrSymbol(0x1F600)); // grinning face, So
    try std.testing.expect(isPunctuationOrSymbol(0x1F979)); // face holding back tears, So, Unicode 14
    try std.testing.expect(!isPunctuationOrSymbol(0x00B5)); // micro sign, Ll
    try std.testing.expect(!isPunctuationOrSymbol(0x00AA)); // feminine ordinal, Lo
    try std.testing.expect(!isPunctuationOrSymbol(0x3031)); // vertical kana repeat mark, Lm
    try std.testing.expect(!isPunctuationOrSymbol(0x4E2D)); // CJK ideograph, Lo
    try std.testing.expect(!isPunctuationOrSymbol(0x2460)); // circled digit one, No
    try std.testing.expect(isPunctuationOrSymbol('*') and !isPunctuationOrSymbol('a'));
    try std.testing.expect(isWhitespace(0x00A0) and isWhitespace(0x3000) and isWhitespace(0x2003));
    try std.testing.expect(isWhitespace(' ') and isWhitespace('\t') and !isWhitespace(0x200B));
}

test "packed flanking ranges preserve generated endpoints" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PackedRange));
    for (source_space_ranges, space_ranges) |source, encoded| {
        try std.testing.expectEqual(source.first, encoded.first);
        try std.testing.expectEqual(source.last, @as(u21, encoded.first) + encoded.span);
    }
    for (source_punctuation_ranges, punctuation_ranges) |source, encoded| {
        try std.testing.expectEqual(source.first, encoded.first);
        try std.testing.expectEqual(source.last, @as(u21, encoded.first) + encoded.span);
    }
}
