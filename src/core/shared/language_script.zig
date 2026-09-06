const std = @import("std");

pub const Script = enum {
    latin,
    cyrillic,
    arabic,
    hebrew,
    devanagari,
    thai,
    greek,
    hangul,
    japanese,
    han,
};

pub const Profile = struct {
    script: ?Script,
    letters: usize,
    dominant_letters: usize,
};

const Counts = struct {
    latin: usize = 0,
    cyrillic: usize = 0,
    arabic: usize = 0,
    hebrew: usize = 0,
    devanagari: usize = 0,
    thai: usize = 0,
    greek: usize = 0,
    hangul: usize = 0,
    hiragana: usize = 0,
    katakana: usize = 0,
    han: usize = 0,

    fn total(self: Counts) usize {
        return self.latin + self.cyrillic + self.arabic + self.hebrew +
            self.devanagari + self.thai + self.greek + self.hangul +
            self.hiragana + self.katakana + self.han;
    }
};

pub fn profile(text: []const u8) Profile {
    return profile_with_filter(text, false, true);
}

pub fn profile_prose(text: []const u8) Profile {
    return profile_with_filter(text, true, true);
}

pub fn profile_non_latin_prose(text: []const u8) Profile {
    return profile_with_filter(text, true, false);
}

pub fn profile_prose_pair(text: []const u8) struct { all: Profile, non_latin: Profile } {
    var counts = count_text(text, true);
    const all = summarize(counts);
    counts.latin = 0;
    return .{ .all = all, .non_latin = summarize(counts) };
}

const Quote = enum {
    none,
    double,
    curly_single,
    curly_double,
};

fn profile_with_filter(text: []const u8, prose_only: bool, include_latin: bool) Profile {
    var counts = count_text(text, prose_only);
    if (!include_latin) counts.latin = 0;
    return summarize(counts);
}

fn count_text(text: []const u8, prose_only: bool) Counts {
    var counts: Counts = .{};
    var index: usize = 0;
    var in_code = false;
    var quote: Quote = .none;
    var delimiter_depth: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            index += 1;
            continue;
        };
        if (index + width > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[index .. index + width]) catch {
            index += width;
            continue;
        };
        if (prose_only) {
            if (codepoint == '`') {
                var run_end = index + width;
                while (run_end < text.len and text[run_end] == '`') : (run_end += 1) {}
                in_code = !in_code;
                index = run_end;
                continue;
            }
            if (in_code) {
                index += width;
                continue;
            }
            if (quote != .none) {
                const closes_quote = switch (quote) {
                    .none => false,
                    .double => codepoint == '"',
                    .curly_single => codepoint == 0x2019,
                    .curly_double => codepoint == 0x201D,
                };
                if (closes_quote) quote = .none;
                index += width;
                continue;
            }
            if (delimiter_depth > 0) {
                if (is_open_delimiter(codepoint)) {
                    delimiter_depth = delimiter_depth +| 1;
                } else if (is_close_delimiter(codepoint)) {
                    delimiter_depth -= 1;
                }
                index += width;
                continue;
            }
            quote = switch (codepoint) {
                '"' => .double,
                0x2018 => .curly_single,
                0x201C => .curly_double,
                else => .none,
            };
            if (quote != .none) {
                index += width;
                continue;
            }
            if (is_open_delimiter(codepoint)) {
                delimiter_depth = 1;
                index += width;
                continue;
            }
        }
        classify_codepoint(&counts, codepoint);
        index += width;
    }
    return counts;
}

fn summarize(counts: Counts) Profile {
    const letters = counts.total();
    if (counts.hiragana + counts.katakana > 0) return .{
        .script = .japanese,
        .letters = letters,
        .dominant_letters = counts.hiragana + counts.katakana + counts.han,
    };
    if (counts.hangul > 0) return .{
        .script = .hangul,
        .letters = letters,
        .dominant_letters = counts.hangul,
    };

    const candidates = [_]struct { script: Script, count: usize }{
        .{ .script = .han, .count = counts.han },
        .{ .script = .arabic, .count = counts.arabic },
        .{ .script = .hebrew, .count = counts.hebrew },
        .{ .script = .cyrillic, .count = counts.cyrillic },
        .{ .script = .greek, .count = counts.greek },
        .{ .script = .devanagari, .count = counts.devanagari },
        .{ .script = .thai, .count = counts.thai },
        .{ .script = .latin, .count = counts.latin },
    };
    var best_script: ?Script = null;
    var best_count: usize = 0;
    var tied = false;
    for (candidates) |candidate| {
        if (candidate.count == 0) continue;
        if (candidate.count > best_count) {
            best_script = candidate.script;
            best_count = candidate.count;
            tied = false;
        } else if (candidate.count == best_count) {
            tied = true;
        }
    }
    return .{
        .script = if (tied) null else best_script,
        .letters = letters,
        .dominant_letters = best_count,
    };
}

fn is_open_delimiter(codepoint: u21) bool {
    return codepoint == '(' or codepoint == '[' or codepoint == '{' or
        codepoint == 0xFF08 or codepoint == 0x3010 or codepoint == 0x300C;
}

fn is_close_delimiter(codepoint: u21) bool {
    return codepoint == ')' or codepoint == ']' or codepoint == '}' or
        codepoint == 0xFF09 or codepoint == 0x3011 or codepoint == 0x300D;
}

fn classify_codepoint(counts: *Counts, codepoint: u21) void {
    if (is_latin_codepoint(codepoint)) {
        counts.latin += 1;
    } else if (is_cyrillic_codepoint(codepoint)) {
        counts.cyrillic += 1;
    } else if (is_arabic_codepoint(codepoint)) {
        counts.arabic += 1;
    } else if (is_hebrew_codepoint(codepoint)) {
        counts.hebrew += 1;
    } else if (is_devanagari_codepoint(codepoint)) {
        counts.devanagari += 1;
    } else if (is_thai_codepoint(codepoint)) {
        counts.thai += 1;
    } else if (is_greek_codepoint(codepoint)) {
        counts.greek += 1;
    } else if (is_hangul_codepoint(codepoint)) {
        counts.hangul += 1;
    } else if (codepoint >= 0x3040 and codepoint <= 0x309F) {
        counts.hiragana += 1;
    } else if ((codepoint >= 0x30A0 and codepoint <= 0x30FF) or
        (codepoint >= 0x31F0 and codepoint <= 0x31FF) or
        (codepoint >= 0xFF66 and codepoint <= 0xFF9F))
    {
        counts.katakana += 1;
    } else if (is_han_codepoint(codepoint)) {
        counts.han += 1;
    }
}

fn is_latin_codepoint(codepoint: u21) bool {
    return (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0x00C0 and codepoint <= 0x024F) or
        (codepoint >= 0x1E00 and codepoint <= 0x1EFF);
}

fn is_cyrillic_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x0400 and codepoint <= 0x052F) or
        (codepoint >= 0x2DE0 and codepoint <= 0x2DFF) or
        (codepoint >= 0xA640 and codepoint <= 0xA69F);
}

fn is_arabic_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x0600 and codepoint <= 0x06FF) or
        (codepoint >= 0x0750 and codepoint <= 0x077F) or
        (codepoint >= 0x08A0 and codepoint <= 0x08FF) or
        (codepoint >= 0xFB50 and codepoint <= 0xFDFF) or
        (codepoint >= 0xFE70 and codepoint <= 0xFEFF);
}

fn is_hebrew_codepoint(codepoint: u21) bool {
    return codepoint >= 0x0590 and codepoint <= 0x05FF;
}

fn is_devanagari_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x0900 and codepoint <= 0x097F) or
        (codepoint >= 0xA8E0 and codepoint <= 0xA8FF);
}

fn is_thai_codepoint(codepoint: u21) bool {
    return codepoint >= 0x0E00 and codepoint <= 0x0E7F;
}

fn is_greek_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x0370 and codepoint <= 0x03FF) or
        (codepoint >= 0x1F00 and codepoint <= 0x1FFF);
}

fn is_hangul_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x11FF) or
        (codepoint >= 0x3130 and codepoint <= 0x318F) or
        (codepoint >= 0xA960 and codepoint <= 0xA97F) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or
        (codepoint >= 0xD7B0 and codepoint <= 0xD7FF);
}

fn is_han_codepoint(codepoint: u21) bool {
    return (codepoint >= 0x3400 and codepoint <= 0x4DBF) or
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        (codepoint >= 0x20000 and codepoint <= 0x2A6DF) or
        (codepoint >= 0x2A700 and codepoint <= 0x2B73F) or
        (codepoint >= 0x2B740 and codepoint <= 0x2B81F) or
        (codepoint >= 0x2B820 and codepoint <= 0x2CEAF);
}

test "paired prose profiles preserve both existing language views" {
    const samples = [_][]const u8{
        "",
        "English response with sparse 界 markers.",
        "次にロックファイルを確認します。 English identifiers.",
        "Сначала проверим файл. Then inspect it.",
        "한국어 응답 and English text.",
        "English `日本語 code` (quoted 中文) \"Русский\" prose.",
        "English “中文” {日本語 [nested]} prose.",
        "\xff invalid \xe3\x81",
    };
    for (samples) |text| {
        const pair = profile_prose_pair(text);
        try std.testing.expectEqual(profile_prose(text), pair.all);
        try std.testing.expectEqual(profile_non_latin_prose(text), pair.non_latin);
    }
    try std.testing.expectEqual(Profile{ .script = .latin, .letters = 5, .dominant_letters = 3 }, profile_prose_pair("abc中文").all);
    try std.testing.expectEqual(Profile{ .script = .han, .letters = 2, .dominant_letters = 2 }, profile_prose_pair("abc中文").non_latin);
}

test "language script profile preserves session inference semantics" {
    try std.testing.expectEqual(Script.latin, profile("a").script.?);
    try std.testing.expectEqual(Script.japanese, profile("資料を確認").script.?);
    try std.testing.expectEqual(Script.hangul, profile("파일 A").script.?);
    try std.testing.expect(profile("aя").script == null);
    try std.testing.expect(profile("1234").script == null);
}

test "language script prose profile excludes code identifiers and quoted data" {
    const chinese_with_packages =
        "接下来我将检查项目中的锁文件（如 package-lock.json、Cargo.lock、Pipfile.lock 等）及其对应的清单文件。";
    try std.testing.expectEqual(Script.han, profile_prose(chinese_with_packages).script.?);

    const english_with_quote =
        "The command failed with the quoted message ‘锁文件已损坏’, so I will inspect the lockfile.";
    try std.testing.expectEqual(Script.latin, profile_prose(english_with_quote).script.?);

    const english_after_code =
        "```zig\nconst причина = true;\n```\nI will inspect the lockfile next.";
    try std.testing.expectEqual(Script.latin, profile_prose(english_after_code).script.?);

    const chinese_with_identifiers =
        "我将检查 lockfile 和 dependency manifest，查找损坏问题。";
    const non_latin = profile_non_latin_prose(chinese_with_identifiers);
    try std.testing.expectEqual(Script.han, non_latin.script.?);
    try std.testing.expect(non_latin.dominant_letters >= 8);
}
