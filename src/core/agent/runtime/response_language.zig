const std = @import("std");
const display_width = @import("../../shared/display_width.zig");
const language_script = @import("../../shared/language_script.zig");
const text_utils = @import("../../shared/text_utils.zig");

const minimum_letters: usize = 5;
const minimum_unexpected_prose_letters: usize = 8;

pub const Script = language_script.Script;
pub const Evidence = language_script.Profile;

pub const Decision = enum {
    accept,
    accept_without_prose,
    retry_once,
    fail_without_commit,
    undecidable,
};

pub const DecisionInput = struct {
    expected: ?Script,
    candidate: Evidence,
    correction_attempted: bool = false,
    has_tool_calls: bool = false,
    cancelled: bool = false,
};

pub fn evidence(text: []const u8) Evidence {
    const profiles = language_script.profile_prose_pair(text);
    const observed = profiles.all;
    const non_latin = profiles.non_latin;
    const minimum_unexpected_share = observed.letters / 5 +
        @as(usize, @intFromBool(observed.letters % 5 != 0));
    if (non_latin.script != null and
        non_latin.dominant_letters >= minimum_unexpected_prose_letters and
        non_latin.dominant_letters >= minimum_unexpected_share)
    {
        return clear_evidence(
            non_latin.script.?,
            non_latin.letters,
            non_latin.dominant_letters,
        );
    }
    if (observed.letters < minimum_letters or observed.script == null) return .{
        .script = null,
        .letters = observed.letters,
        .dominant_letters = observed.dominant_letters,
    };
    return clear_evidence(
        observed.script.?,
        observed.letters,
        observed.dominant_letters,
    );
}

// noinline: these prompt scans touch every prompt byte once per signal and
// are the turn loop's hottest code. Keeping them in their own function keeps
// their profile out of the turn loop, which can then compile for size.
pub noinline fn infer_expectation(prompt: []const u8) ?Script {
    if (may_request_language_switch(prompt)) return null;
    const script = evidence(prompt).script orelse return null;
    if (script != .latin or !has_english_authority_signal(prompt)) return null;
    // A request written in another Latin-script language can quote English
    // and still ask for a reply in any script, so expect Latin only when the
    // whole prompt reads as English (`tests/tla/agent_runtime/ResponseLanguage.tla`
    // RequestedLanguageAccepted).
    if (has_non_ascii_latin_letter(prompt) or has_clause_without_english(prompt)) return null;
    return script;
}

pub fn decide(input: DecisionInput) Decision {
    if (input.cancelled) return .undecidable;
    const expected = input.expected orelse return .undecidable;
    const actual = input.candidate.script orelse return .undecidable;
    if (actual == expected) return .accept;
    if (input.has_tool_calls) return .accept_without_prose;
    return if (input.correction_attempted) .fail_without_commit else .retry_once;
}

fn clear_evidence(script: Script, letters: usize, dominant_letters: usize) Evidence {
    const whole_fifths = letters / 5;
    const remainder = letters % 5;
    const required = whole_fifths * 3 + (remainder * 3 + 4) / 5;
    return .{
        .script = if (dominant_letters >= required) script else null,
        .letters = letters,
        .dominant_letters = dominant_letters,
    };
}

fn may_request_language_switch(prompt: []const u8) bool {
    const signals = [_][]const u8{
        "answer in ",
        "respond in ",
        "reply in ",
        "write in ",
        "speak in ",
        "translate",
        " language",
        "chinese",
        "mandarin",
        "cantonese",
        "japanese",
        "korean",
        "russian",
        "ukrainian",
        "bulgarian",
        "arabic",
        "persian",
        "farsi",
        "urdu",
        "hebrew",
        "greek",
        "hindi",
        "marathi",
        "nepali",
        "thai",
    };
    for (signals) |signal| {
        if (contains_ignore_case(prompt, signal)) return true;
    }
    return false;
}

fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

/// Whether the text has a Latin letter outside ASCII, such as "ị" or "é",
/// which English prose does not use. Malformed bytes are skipped one at a
/// time, so a cut-short sequence cannot hide the letter after it.
fn has_non_ascii_latin_letter(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] < 0x80) {
            index += 1;
            continue;
        }
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            index += 1;
            continue;
        };
        if (index + width > text.len) return false;
        const codepoint = display_width.decodeUtf8Sequence(text[index .. index + width]) catch {
            index += 1;
            continue;
        };
        // U+00D7 and U+00F7 are the signs × and ÷, not letters.
        if ((codepoint >= 0x00C0 and codepoint <= 0x024F and codepoint != 0x00D7 and codepoint != 0x00F7) or
            (codepoint >= 0x1E00 and codepoint <= 0x1EFF)) return true;
        index += width;
    }
    return false;
}

/// Whether some clause of three or more words, outside code spans, has no
/// English function word: words of another language, even when the rest of
/// the prompt is English. A clause ends at a line break or at a word that ends
/// in . ! ? : or ;. A word is a whitespace-separated token with an ASCII letter.
fn has_clause_without_english(text: []const u8) bool {
    var words: usize = 0;
    var has_function_word = false;
    var in_code = false;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '`') {
            while (index < text.len and text[index] == '`') : (index += 1) {}
            in_code = !in_code;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            index += 1;
            if (byte != '\n' or in_code) continue;
            if (words >= 3 and !has_function_word) return true;
            words = 0;
            has_function_word = false;
            continue;
        }
        const start = index;
        while (index < text.len and text[index] != '`' and !std.ascii.isWhitespace(text[index])) : (index += 1) {}
        if (in_code) continue;
        const token = text[start..index];
        if (has_ascii_letter(token)) {
            words += 1;
            if (is_english_function_word(token)) has_function_word = true;
        }
        if (std.mem.findScalar(u8, ".!?:;", token[token.len - 1]) != null) {
            if (words >= 3 and !has_function_word) return true;
            words = 0;
            has_function_word = false;
        }
    }
    return words >= 3 and !has_function_word;
}

fn has_ascii_letter(token: []const u8) bool {
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) return true;
    }
    return false;
}

/// Short words that other Latin-script languages also use, such as "a",
/// "in", "is", and "do", are left out, so they cannot pass a clause in
/// another language as English. "I" counts only as a capital.
const english_function_words = [_][]const u8{
    "the",    "this",   "that",    "these",   "those",   "you",   "your",
    "please", "what",   "why",     "how",     "should",  "would", "could",
    "will",   "and",    "or",      "of",      "to",      "are",   "were",
    "be",     "been",   "being",   "it",      "its",     "with",  "for",
    "from",   "by",     "if",      "then",    "than",    "not",   "does",
    "did",    "can",    "have",    "has",     "had",     "haven", "hasn",
    "don",    "doesn",  "didn",    "isn",     "aren",    "wasn",  "weren",
    "won",    "wouldn", "couldn",  "shouldn", "let",     "we",    "my",
    "our",    "us",     "they",    "them",    "their",   "there", "here",
    "which",  "who",    "whose",   "when",    "where",   "about", "into",
    "after",  "before", "but",     "all",     "any",     "some",  "each",
    "every",  "only",   "more",    "very",    "also",    "just",  "same",
    "such",   "other",  "without", "through", "because", "while", "until",
    "since",  "over",   "under",   "yes",     "she",     "his",   "her",
    "him",    "out",    "up",
};

/// Whether a token is an English function word, allowing punctuation around
/// it and a contraction such as "don't" or "it’s" after it.
fn is_english_function_word(token: []const u8) bool {
    var start: usize = 0;
    while (start < token.len and !std.ascii.isAlphabetic(token[start])) : (start += 1) {}
    var end = start;
    while (end < token.len and std.ascii.isAlphabetic(token[end])) : (end += 1) {}
    if (start == end) return false;
    const rest = token[end..];
    if (rest.len > 0 and rest[0] != '\'' and !std.mem.startsWith(u8, rest, "\u{2019}")) {
        for (rest) |byte| {
            if (std.ascii.isAlphanumeric(byte)) return false;
        }
    }
    const word = token[start..end];
    if (std.mem.eql(u8, word, "I")) return true;
    for (english_function_words) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

fn has_english_authority_signal(text: []const u8) bool {
    const words = [_][]const u8{
        "the",
        "this",
        "that",
        "these",
        "those",
        "you",
        "your",
        "please",
        "what",
        "why",
        "how",
        "should",
        "would",
        "could",
        "will",
    };
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and !std.ascii.isAlphabetic(text[start])) : (start += 1) {}
        const word_start = start;
        while (start < text.len and std.ascii.isAlphabetic(text[start])) : (start += 1) {}
        if (word_start == start) continue;
        const word = text[word_start..start];
        for (words) |candidate| {
            if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
        }
    }
    return false;
}

test "response language evidence distinguishes clear scripts" {
    try std.testing.expectEqual(Script.latin, evidence("I will inspect the lockfile next.").script.?);
    try std.testing.expectEqual(Script.han, evidence("我会先检查锁文件和依赖清单。").script.?);
    try std.testing.expectEqual(Script.cyrillic, evidence("Сначала я проверю файл блокировки.").script.?);
    try std.testing.expectEqual(Script.japanese, evidence("次にロックファイルを確認します。").script.?);
    try std.testing.expectEqual(
        Script.han,
        evidence("接下来我将检查项目中的锁文件（如 package-lock.json、Cargo.lock、Pipfile.lock 等）及其对应的清单文件。").script.?,
    );
    try std.testing.expectEqual(
        Script.han,
        evidence("我将检查 lockfile 和 dependency manifest，查找损坏问题。").script.?,
    );
    try std.testing.expectEqual(
        Script.latin,
        evidence(text_utils.repeat("English transcript payload with sparse 界 markers. ", 16)).script.?,
    );
}

test "response language expectation follows the current human unless a switch may be explicit" {
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again.").?);
    try std.testing.expect(infer_expectation("请再次检查锁文件。") == null);
    try std.testing.expect(infer_expectation("Answer in Japanese and keep it short.") == null);
    try std.testing.expect(infer_expectation("Translate the error into Russian.") == null);
    try std.testing.expect(infer_expectation("Why did you answer in Chinese? Reply in English.") == null);
    try std.testing.expect(infer_expectation("Rispondi in giapponese.") == null);
    try std.testing.expect(infer_expectation("Antworte auf Japanisch.") == null);
    try std.testing.expect(infer_expectation("fix lockfile") == null);
}

test "response language expectation abstains for non-English requests that quote English" {
    const requests = [_][]const u8{
        // Vietnamese asks for a Korean translation (#809).
        "Dịch nội dung sau sang tiếng Hàn. The lockfile is broken again.",
        // Latin-script languages written in ASCII only.
        "Terjemahkan ke bahasa Korea. The lockfile is broken again.",
        "Tolong terjemahkan teks berikut ke bahasa Korea: The lockfile is broken again and the build " ++
            "fails when you run it, so please check what changed in the last commit and tell me why it broke.",
        "Terjemahkan ke bahasa Korea\n\nThe lockfile is broken again.",
        "The lockfile is broken again. Terjemahkan ke bahasa Korea.",
        "Isalin mo ito sa Hapon. The lockfile is broken again.",
        "Tafsiri maandishi haya kwa Kikorea. The lockfile is broken again.",
        "Dich noi dung sau sang tieng Han. The lockfile is broken again.",
        "Traduce esto al coreano. The lockfile is broken again.",
        "Traduci questo testo in coreano. The lockfile is broken again.",
        "Vertaal dit naar het Koreaans. The lockfile is broken again.",
        // "i" is a word in Italian; only the capital "I" counts as English.
        "Traduci i file in coreano. The lockfile is broken again.",
        // Any Latin letter outside ASCII abstains, even in English.
        "Ask José to review the lockfile.",
    };
    for (requests) |prompt| {
        errdefer std.debug.print("expected no expectation for: {s}\n", .{prompt});
        try std.testing.expect(infer_expectation(prompt) == null);
    }
}

test "response language expectation keeps plain English" {
    const requests = [_][]const u8{
        "The lockfile is broken again.",
        "The lockfile is broken again. Say what you will inspect next.",
        "The lockfile’s broken — please fix it.",
        "Please read notes.txt and explain the result.",
        "Fix the flaky TUI resize test.",
        "Why is 3 × 4 ÷ 2 wrong in the parser?",
        "Why does `zig build test` fail on this branch?",
        "Why does this fail?\n```\nzig build test --summary none\nerror: FileNotFound\n```\nI think the parser broke.",
        "Nothing ran. Answer that message now.",
        "I couldn't open it. What should I check?",
        "I tried zig build. Why does the lockfile break?",
        "Don't touch lockfile parsing. Why does it break?",
        "Don’t touch lockfile parsing. Why does it break?",
    };
    for (requests) |prompt| {
        errdefer std.debug.print("expected a Latin expectation for: {s}\n", .{prompt});
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
}

test "response language expectation judges clauses of three or more words" {
    // Two words are too few to say a clause is not English.
    try std.testing.expectEqual(Script.latin, infer_expectation("Tolong terjemahkan. The lockfile is broken again.").?);
    try std.testing.expect(infer_expectation("Tolong terjemahkan ini. The lockfile is broken again.") == null);
}

test "response language expectation tolerates malformed UTF-8" {
    try std.testing.expectEqual(Script.latin, infer_expectation("\xff\xfe The lockfile is broken again.").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("\x80 The lockfile is broken again.").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again. \xc3").?);
    // A sequence cut short does not hide the accented letter after it.
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xe1 é") == null);
    try std.testing.expect(infer_expectation("") == null);
    try std.testing.expect(infer_expectation("?! ... ;") == null);
}

const fuzz_prompt_capacity = 512;

fn fuzzInferExpectation(_: void, smith: *std.testing.Smith) anyerror!void {
    const accented = " \u{1ECB}";
    const bare_clause = "Tolong terjemahkan ini.\n";
    var buffer: [bare_clause.len + fuzz_prompt_capacity + accented.len]u8 = undefined;
    @memcpy(buffer[0..bare_clause.len], bare_clause);
    const len: usize = @intCast(smith.slice(buffer[bare_clause.len..][0..fuzz_prompt_capacity]));
    const prompt = buffer[bare_clause.len..][0..len];
    // fx only ever expects a Latin reply.
    if (infer_expectation(prompt)) |script| try std.testing.expectEqual(Script.latin, script);
    // A clause of three words with no English function word, or a Latin
    // letter outside ASCII, means the prompt may not be English.
    try std.testing.expect(infer_expectation(buffer[0 .. bare_clause.len + len]) == null);
    @memcpy(buffer[bare_clause.len + len ..][0..accented.len], accented);
    try std.testing.expect(infer_expectation(buffer[bare_clause.len..][0 .. len + accented.len]) == null);
}

test "response language expectation stays conservative on fuzzed prompts" {
    try std.testing.fuzz({}, fuzzInferExpectation, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "The lockfile is broken again.",
            "Dịch nội dung sau sang tiếng Hàn. The lockfile is broken again.",
            "Terjemahkan ke bahasa Korea. The lockfile is broken again.",
            "Why does `zig build test` fail?\n```\nconst x = 1;\n```\nPlease check.",
            "The lockfile is broken \xf0\x9f",
            "\xff\xfe\xe1",
            "",
        }) ++ @import("fuzz_corpus").response_language_expectation.*),
    });
}

test "response language decision is pure conservative and bounded" {
    const expected = infer_expectation("The lockfile is broken again.");
    const matching = evidence("I will inspect the lockfile next.");
    const mismatching = evidence("我会先检查锁文件和依赖清单。");
    const mixed = evidence("abcd锁文件坏");

    try std.testing.expectEqual(Decision.accept, decide(.{
        .expected = expected,
        .candidate = matching,
    }));
    try std.testing.expectEqual(Decision.retry_once, decide(.{
        .expected = expected,
        .candidate = mismatching,
    }));
    try std.testing.expectEqual(Decision.fail_without_commit, decide(.{
        .expected = expected,
        .candidate = mismatching,
        .correction_attempted = true,
    }));
    try std.testing.expectEqual(Decision.accept_without_prose, decide(.{
        .expected = expected,
        .candidate = mismatching,
        .has_tool_calls = true,
    }));
    try std.testing.expectEqual(Decision.undecidable, decide(.{
        .expected = expected,
        .candidate = mismatching,
        .cancelled = true,
    }));
    try std.testing.expectEqual(Decision.undecidable, decide(.{
        .expected = expected,
        .candidate = mixed,
    }));
    try std.testing.expectEqual(Decision.undecidable, decide(.{
        .expected = null,
        .candidate = matching,
    }));
}

test "response language evidence tolerates malformed UTF-8 and insufficient text" {
    try std.testing.expect(evidence("ok").script == null);
    try std.testing.expectEqual(Script.latin, evidence("\xff\xfe broken").script.?);
}
