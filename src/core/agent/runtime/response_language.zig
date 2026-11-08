const std = @import("std");
const ascii_case = @import("../../shared/ascii_case.zig");
const display_width = @import("../../shared/display_width.zig");
const language_script = @import("../../shared/language_script.zig");
const text_utils = @import("../../shared/text_utils.zig");
const unicode_classes = @import("../presentation/unicode_classes.zig");

const minimum_letters: usize = 5;
const minimum_unexpected_prose_letters: usize = 8;
/// A clause shorter than this is too short to say it is not English.
const minimum_clause_words: usize = 3;
/// The combining accents that follow a base letter, such as U+0323 after "i".
const combining_accents_first: u21 = 0x0300;
const combining_accents_last: u21 = 0x036F;

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
        if (ascii_case.containsIgnoreCase(prompt, signal)) return true;
    }
    return false;
}

/// Whether the text has a Latin letter outside ASCII, such as "ị" or "é",
/// which English prose does not use. The same letter stored as a base letter
/// and a combining accent, "i" and U+0323, counts too. Malformed bytes are
/// skipped one at a time, so a cut-short sequence cannot hide the letter
/// after it.
fn has_non_ascii_latin_letter(text: []const u8) bool {
    var index: usize = 0;
    var after_latin_letter = false;
    while (index < text.len) {
        const rune = display_width.decodeNextRune(text, index);
        index += rune.len;
        if (is_latin_letter_outside_ascii(rune.codepoint)) return true;
        if (after_latin_letter and
            rune.codepoint >= combining_accents_first and rune.codepoint <= combining_accents_last) return true;
        after_latin_letter = rune.codepoint < 0x80 and std.ascii.isAlphabetic(@intCast(rune.codepoint));
    }
    return false;
}

fn is_latin_letter_outside_ascii(codepoint: u21) bool {
    // U+00D7 and U+00F7 are the signs × and ÷, not letters.
    return codepoint >= 0x80 and language_script.is_latin_codepoint(codepoint) and
        codepoint != 0x00D7 and codepoint != 0x00F7;
}

/// What separates words at one place in a prompt.
const Separator = struct {
    /// Its length in bytes, or 0 when no separator starts there.
    len: usize,
    /// Whether it is a line break, which also ends a clause.
    line_break: bool,
};

/// The separator that starts at `index`: ASCII white space, a Unicode space
/// separator of `unicode_classes.isWhitespace`, or a line break. The line
/// breaks are LF, VT, FF, and CR, the next line (U+0085), the line separator
/// (U+2028), and the paragraph separator (U+2029).
fn separator_at(text: []const u8, index: usize) Separator {
    const byte = text[index];
    if (byte < 0x80) return .{
        .len = @intFromBool(std.ascii.isWhitespace(byte)),
        .line_break = byte >= '\n' and byte <= '\r',
    };
    const rune = display_width.decodeNextRune(text, index);
    const line_break = rune.codepoint == 0x0085 or rune.codepoint == 0x2028 or rune.codepoint == 0x2029;
    return .{
        .len = if (line_break or unicode_classes.isWhitespace(rune.codepoint)) rune.len else 0,
        .line_break = line_break,
    };
}

/// Whether some clause of `minimum_clause_words` or more words, outside code
/// spans, has no English function word: words of another language, even when
/// the rest of the prompt is English. A clause ends at a line break or at a
/// word that ends in . ! ? : or ;. A word is a token with an ASCII letter
/// between the separators of `separator_at`.
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
        const separator = separator_at(text, index);
        if (separator.len > 0) {
            index += separator.len;
            if (!separator.line_break or in_code) continue;
            if (words >= minimum_clause_words and !has_function_word) return true;
            words = 0;
            has_function_word = false;
            continue;
        }
        const start = index;
        while (index < text.len and text[index] != '`' and separator_at(text, index).len == 0) : (index += 1) {}
        if (in_code) continue;
        const token = text[start..index];
        if (has_ascii_letter(token)) {
            words += 1;
            if (is_english_function_word(token)) has_function_word = true;
        }
        if (std.mem.findScalar(u8, ".!?:;", token[token.len - 1]) != null) {
            if (words >= minimum_clause_words and !has_function_word) return true;
            words = 0;
            has_function_word = false;
        }
    }
    return words >= minimum_clause_words and !has_function_word;
}

fn has_ascii_letter(token: []const u8) bool {
    for (token) |byte| {
        if (std.ascii.isAlphabetic(byte)) return true;
    }
    return false;
}

/// English words that other Latin-script languages do not use as ordinary
/// words. One of them in a prompt marks it as possibly English
/// (`has_english_authority_signal`), and in a clause it marks the clause as
/// English.
const english_authority_words = [_][]const u8{
    "the",    "this", "that", "these", "those",  "you",   "your",
    "please", "what", "why",  "how",   "should", "would", "could",
};

/// More English function words, with the same rule. Words that another
/// Latin-script language also uses as ordinary words are left out, so they
/// cannot pass a clause in that language as English: "a", "in", "is", and
/// "do", and thirty more such as "to" (Polish, Czech), "we" and "of" (Dutch),
/// "by" and "my" (Czech, Polish), "her" (Turkish), "can" (Vietnamese), "for"
/// (Danish), and "will" (German). "I" counts only as a capital.
const english_function_words = english_authority_words ++ [_][]const u8{
    "and",   "were",  "being",   "its",     "with",    "from",  "if",
    "then",  "does",  "did",     "they",    "their",   "there", "here",
    "our",   "which", "who",     "whose",   "when",    "where", "about",
    "into",  "after", "before",  "some",    "each",    "every", "only",
    "very",  "other", "without", "through", "because", "while", "until",
    "since", "yes",   "she",     "him",     "out",     "up",
};

/// The start of a contraction: "don" in "don't", "it" in "it's". These count
/// as English only before an apostrophe and an English ending, because "don",
/// "won", "haven", "can", "let", "it", and "we" are words of Spanish, Dutch,
/// Turkish, Vietnamese, and other languages, and Turkish gives a name its own
/// ending after an apostrophe, as in "Can'a".
const english_contraction_stems = [_][]const u8{
    "don",   "doesn", "didn",   "isn",    "aren",    "wasn",
    "weren", "won",   "wouldn", "couldn", "shouldn", "haven",
    "hasn",  "can",   "let",    "it",     "we",
};

/// What English adds after the apostrophe of a contraction: "t" in "don't", "s"
/// in "it's", "re" in "we're", "ll", "ve", "d", and "m".
const english_contraction_endings = [_][]const u8{ "t", "s", "re", "ll", "ve", "d", "m" };

/// Whether the letters at the start of `after_apostrophe` are exactly one of
/// the `english_contraction_endings`, in either case.
fn starts_with_english_contraction_ending(after_apostrophe: []const u8) bool {
    var len: usize = 0;
    while (len < after_apostrophe.len and std.ascii.isAlphabetic(after_apostrophe[len])) : (len += 1) {}
    for (english_contraction_endings) |ending| {
        if (std.ascii.eqlIgnoreCase(after_apostrophe[0..len], ending)) return true;
    }
    return false;
}

/// Whether a token is an English function word, allowing punctuation around
/// it and a contraction such as "don't" or "it’s" after it.
fn is_english_function_word(token: []const u8) bool {
    var start: usize = 0;
    while (start < token.len and !std.ascii.isAlphabetic(token[start])) : (start += 1) {}
    var end = start;
    while (end < token.len and std.ascii.isAlphabetic(token[end])) : (end += 1) {}
    if (start == end) return false;
    const rest = token[end..];
    const apostrophe_len: usize = if (rest.len > 0 and rest[0] == '\'')
        1
    else if (std.mem.startsWith(u8, rest, "\u{2019}"))
        "\u{2019}".len
    else
        0;
    const contracted = apostrophe_len > 0;
    if (rest.len > 0 and !contracted) {
        for (rest) |byte| {
            if (std.ascii.isAlphanumeric(byte)) return false;
        }
    }
    const word = token[start..end];
    if (std.mem.eql(u8, word, "I")) return true;
    for (english_function_words) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    if (contracted and starts_with_english_contraction_ending(rest[apostrophe_len..])) {
        for (english_contraction_stems) |stem| {
            if (std.ascii.eqlIgnoreCase(word, stem)) return true;
        }
    }
    return false;
}

fn has_english_authority_signal(text: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and !std.ascii.isAlphabetic(text[start])) : (start += 1) {}
        const word_start = start;
        while (start < text.len and std.ascii.isAlphabetic(text[start])) : (start += 1) {}
        if (word_start == start) continue;
        const word = text[word_start..start];
        for (english_authority_words) |candidate| {
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
    // "it" and "to" are words of Vietnamese and Polish, so a clause whose only
    // English words are such words is not judged English either.
    try std.testing.expect(infer_expectation("Make it work now. Please check the result.") == null);
    try std.testing.expectEqual(Script.latin, infer_expectation("Make the parser work now. Please check the result.").?);
}

test "response language expectation tolerates malformed UTF-8" {
    try std.testing.expectEqual(Script.latin, infer_expectation("\xff\xfe The lockfile is broken again.").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("\x80 The lockfile is broken again.").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again. \xc3").?);
    // A sequence cut short does not hide the accented letter after it.
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xe1 é") == null);
    // A 2-, 3-, or 4-byte lead that claims more bytes than remain skips one
    // byte, whether or not an accented letter follows it.
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xc3\xc3\xa9") == null);
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xe1\xc3\xa9") == null);
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xf0\xc3\xa9") == null);
    try std.testing.expect(infer_expectation("The lockfile is broken again. \xf0\xe1\xbb\x8b") == null);
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again. \xf0").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again. \xe1\xbb").?);
    try std.testing.expectEqual(Script.latin, infer_expectation("The lockfile is broken again. \xf0\x9f\x98").?);
    try std.testing.expect(infer_expectation("") == null);
    try std.testing.expect(infer_expectation("?! ... ;") == null);
}

test "response language expectation counts decomposed accents like precomposed letters" {
    // Each pair is the same request: letters with accents, then base letters
    // followed by combining marks (U+0300 to U+036F).
    const pairs = [_][2][]const u8{
        .{
            "Dịch giúp tôi. The lockfile is broken again.",
            "Di\u{323}ch giu\u{301}p to\u{302}i. The lockfile is broken again.",
        },
        .{
            "Réponds vite, s'il te plaît. The lockfile is broken again.",
            "Re\u{301}ponds vite, s'il te plai\u{302}t. The lockfile is broken again.",
        },
        .{
            "Zrób to dla mnie. The lockfile is broken again.",
            "Zro\u{301}b to dla mnie. The lockfile is broken again.",
        },
        .{
            "Ask José to review the lockfile.",
            "Ask Jose\u{301} to review the lockfile.",
        },
    };
    for (pairs) |pair| {
        try std.testing.expect(infer_expectation(pair[0]) == null);
        try std.testing.expect(infer_expectation(pair[1]) == null);
    }
    // A combining mark counts only straight after a Latin letter.
    const stray_marks = [_][]const u8{
        "\u{301}The lockfile is broken again.",
        "The lockfile is broken again. \u{301}",
        "Why is 3\u{301} wrong in the lockfile parser?",
        "Why is the lockfile \u{301}broken again?",
        // Straight after a character that is not a letter of ASCII.
        "The lockfile is broken again \u{2014}\u{301}",
        "The lockfile is broken again. \u{754C}\u{301}",
    };
    for (stray_marks) |prompt| {
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
}

/// The prompts for which `infer_expectation` does not give `expected`, one per
/// line, for a test to compare with an empty string.
fn unexpected_expectations(prompts: []const []const u8, expected: ?Script) ![]u8 {
    var misses: std.ArrayList(u8) = .empty;
    errdefer misses.deinit(std.testing.allocator);
    for (prompts) |prompt| {
        if (infer_expectation(prompt) == expected) continue;
        try misses.appendSlice(std.testing.allocator, prompt);
        try misses.append(std.testing.allocator, '\n');
    }
    return misses.toOwnedSlice(std.testing.allocator);
}

test "response language expectation ignores English words that another language uses" {
    // One request for each word that the English list leaves out because a
    // Latin-script language uses it as an ordinary word, written without
    // accents and followed by quoted English.
    const requests = [_][]const u8{
        "Sprawdz to w pliku konfiguracyjnym. The lockfile is broken again.", // to: Polish
        "Kunnen we dit vandaag nog oplossen? The lockfile is broken again.", // we: Dutch
        "Is dit een bug of een feature? The lockfile is broken again.", // of: Dutch
        "Mohl by to nekdo zkontrolovat? The lockfile is broken again.", // by: Czech
        "Her gun yeni bir hata cikiyor. The lockfile is broken again.", // her: Turkish
        "Praat even over de nieuwe build. The lockfile is broken again.", // over: Dutch
        "Let goed op de volgorde van de tests. The lockfile is broken again.", // let: Dutch
        "My musimy to jeszcze sprawdzic. The lockfile is broken again.", // my: Polish
        "Hij had de test nooit gedraaid. The lockfile is broken again.", // had: Dutch
        "Det er for langsomt i dag. The lockfile is broken again.", // for: Danish
        "Ich will das Problem verstehen. The lockfile is broken again.", // will: German
        "Also gut, dann pruefen wir das. The lockfile is broken again.", // also: German
        "All diese Tests laufen zu langsam. The lockfile is broken again.", // all: German
        "Tu has cambiado el archivo de configuracion. The lockfile is broken again.", // has: Spanish
        "Vi skal have den nye version ud. The lockfile is broken again.", // have: Danish
        "Det kraschar under installationen. The lockfile is broken again.", // under: Swedish
        "Us enviare el resum de la prova. The lockfile is broken again.", // us: Catalan
        "Det var just det jag menade. The lockfile is broken again.", // just: Swedish
        "Ali more koda delovati brez tega? The lockfile is broken again.", // more: Slovene
        "Same testy nic nie sprawdzaja. The lockfile is broken again.", // same: Polish
        "Ban can sua loi nay ngay. The lockfile is broken again.", // can: Vietnamese
        "Can bey bu dosyayi inceledi mi? The lockfile is broken again.", // can: Turkish
        "Aplicatia are o eroare noua. The lockfile is broken again.", // are: Romanian
        "Be, ara ho revisem tot junts. The lockfile is broken again.", // be: Catalan
        "Or, le test echoue toujours. The lockfile is broken again.", // or: French
        "Ik heb het been gebroken tijdens het testen. The lockfile is broken again.", // been: Dutch
        "Giao dien than thien voi nguoi dung. The lockfile is broken again.", // than: Vietnamese
        "Hay them mot dong vao file nay. The lockfile is broken again.", // them: Vietnamese
        "Chi con it viec de lam. The lockfile is broken again.", // it: Vietnamese
        "Bu not defterine yazilmali. The lockfile is broken again.", // not: Turkish
        "Le but est de corriger ce test. The lockfile is broken again.", // but: French
        "Aquest any no hi ha errors. The lockfile is broken again.", // any: Catalan
        "Such den Fehler in der Datei. The lockfile is broken again.", // such: German
        "Bu his cok garip. The lockfile is broken again.", // his: Turkish
        // "don", "won", and "haven" are words in Spanish and Dutch; they count
        // as English only before an apostrophe.
        "Don Pablo revisa el codigo hoy. The lockfile is broken again.",
        "Ons team won de benchmark. The lockfile is broken again.",
        "Open de haven voor de nieuwe service. The lockfile is broken again.",
        // The requests that came back as English for "we", "of", "over",
        // "her", "by", and "my".
        "Kunnen we dit naar het Koreaans vertalen? The lockfile is broken again.",
        "Vertaal dit naar het Koreaans of Japans. The lockfile is broken again.",
        "Kun je dit over zetten naar het Koreaans? The lockfile is broken again.",
        "Her dosyayi korece cevir. The lockfile is broken again.",
        "Mohl by jsi to prelozit do korejstiny? The lockfile is broken again.",
        "Powiedz my jak to dziala w korejskim. The lockfile is broken again.",
    };
    const misses = try unexpected_expectations(&requests, null);
    defer std.testing.allocator.free(misses);
    try std.testing.expectEqualStrings("", misses);
}

test "response language expectation recognizes each English authority word" {
    // Each request has one authority word, which is also the only English word
    // of its clause.
    const requests = [_][]const u8{
        "The build fails now.",
        "Fix this bug.",
        "Fix that bug.",
        "Fix these bugs.",
        "Fix those bugs.",
        "Can you run zig build?",
        "Run your tests.",
        "Please run zig build.",
        "What broke zig build?",
        "Why is zig build slow?",
        "How slow is zig build?",
        "Should zig build pass?",
        "Would zig build pass?",
        "Could zig build pass?",
    };
    const misses = try unexpected_expectations(&requests, .latin);
    defer std.testing.allocator.free(misses);
    try std.testing.expectEqualStrings("", misses);
}

test "response language expectation keeps English that uses contractions" {
    const requests = [_][]const u8{
        "Don't touch parsing. Why does it break?",
        "Don’t touch parsing. Why does it break?",
        "Can't reproduce it locally. Why does it fail?",
        "Let's fix parsing first. Why does it break?",
        "It's broken again. Why does it break?",
        "We're stuck on parsing. Why does it break?",
        "We won't touch parsing. Why does it break?",
        "Please fix the flaky test. We can't merge it.",
        // The stem is the only English word of its clause.
        "Doesn't build on Linux. Why does it break?",
        "Didn't finish in time. Why does it break?",
        "Isn't fixed in main. Why does it break?",
        "Aren't tests flaky today? Why does it break?",
        "Wasn't tested on Linux. Why does it break?",
        "Weren't merged in time. Why does it break?",
        "Wouldn't build on Linux. Why does it break?",
        "Couldn't reproduce on Linux. Why does it break?",
        "Shouldn't build on Linux. Why does it break?",
        "Haven't touched parsing code. Why does it break?",
        "Hasn't changed in weeks. Why does it break?",
    };
    const misses = try unexpected_expectations(&requests, .latin);
    defer std.testing.allocator.free(misses);
    try std.testing.expectEqualStrings("", misses);
    // Without the apostrophe the same words belong to other languages.
    try std.testing.expect(infer_expectation("Don touch parsing. Why does it break?") == null);
    try std.testing.expect(infer_expectation("Let touch parsing. Why does it break?") == null);
}

test "response language expectation counts a contraction stem only before an English ending" {
    const apostrophes = [_][]const u8{ "'", "\u{2019}" };
    // The endings of English contractions, in either case.
    const english_endings = [_][]const u8{ "t", "s", "re", "ll", "ve", "d", "m", "T", "S", "RE" };
    // Endings that other languages put after an apostrophe, and near misses.
    const other_endings = [_][]const u8{ "", "a", "e", "da", "dan", "nin", "tt", "ss", "res", "x", "\u{131}n" };
    for (apostrophes) |apostrophe| {
        for (english_endings) |ending| {
            var buffer: [32]u8 = undefined;
            const token = try std.mem.print(&buffer, "can{s}{s}", .{ apostrophe, ending });
            errdefer std.debug.print("expected English: {s}\n", .{token});
            try std.testing.expect(is_english_function_word(token));
        }
        for (other_endings) |ending| {
            var buffer: [32]u8 = undefined;
            const token = try std.mem.print(&buffer, "Can{s}{s}", .{ apostrophe, ending });
            errdefer std.debug.print("expected not English: {s}\n", .{token});
            try std.testing.expect(!is_english_function_word(token));
        }
    }
    // Punctuation around a contraction does not change it.
    try std.testing.expect(is_english_function_word("(Don't"));
    try std.testing.expect(is_english_function_word("it's."));
    try std.testing.expect(is_english_function_word("can't,"));
    try std.testing.expect(is_english_function_word("won't-fix"));
}

test "response language expectation reads a name with a case ending as a word of its language" {
    const requests = [_][]const u8{
        // Turkish: a name with a case ending after an apostrophe.
        "Bunu Can'a Korece yaz. The lockfile is broken again.",
        "Bunu Can\u{2019}a Korece yaz. The lockfile is broken again.",
        "Bunu Can'dan Korece iste. The lockfile is broken again.",
        "Bunu Ali'nin dosyasina Korece yaz. The lockfile is broken again.",
        // A stem with no ending after its apostrophe is not a contraction.
        "Bunu Can' Korece yaz. The lockfile is broken again.",
        // French elision.
        "Je bois l'eau froide. The lockfile is broken again.",
    };
    for (requests) |prompt| {
        errdefer std.debug.print("expected no expectation for: {s}\n", .{prompt});
        try std.testing.expect(infer_expectation(prompt) == null);
    }
}

/// The Unicode space separators that split words.
const unicode_spaces = [_]u21{
    0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
    0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000,
};
/// Characters that do not split words: ones just outside each range, and the
/// Mongolian vowel separator.
const not_spaces = [_]u21{
    0x009F, 0x00A1, 0x167F, 0x1681, 0x180E, 0x1FFF, 0x200B, 0x205E, 0x2060, 0x2FFF, 0x3001,
};
/// The line breaks, which split words and also end a clause: LF, VT, FF, CR, the
/// next line, the line separator, and the paragraph separator.
const line_breaks = [_]u21{ '\n', 0x0B, 0x0C, '\r', 0x0085, 0x2028, 0x2029 };
/// Characters that do not end a clause: spaces, which only split words, and
/// characters next to the line breaks, which are not separators at all.
const not_line_breaks = [_]u21{
    ' ',    '\t',   0x0E,   0x1F,   0x7F,   0x0084, 0x0086, 0x00A0, 0x180E,
    0x2003, 0x2027, 0x202A, 0x2060, 0x3000,
};

/// `words` joined by `separator`, then `tail`, written into `buffer`.
fn joined_request(buffer: []u8, words: []const []const u8, separator: u21, tail: []const u8) ![]const u8 {
    var len: usize = 0;
    for (words, 0..) |word, index| {
        if (index > 0) len += try std.unicode.utf8Encode(separator, buffer[len..]);
        @memcpy(buffer[len..][0..word.len], word);
        len += word.len;
    }
    @memcpy(buffer[len..][0..tail.len], tail);
    return buffer[0 .. len + tail.len];
}

test "response language expectation splits words at Unicode spaces" {
    const words = [_][]const u8{ "Terjemahkan", "ke", "bahasa", "Korea." };
    const tail = " The lockfile is broken again.";
    for (unicode_spaces) |space| {
        var buffer: [128]u8 = undefined;
        const prompt = try joined_request(&buffer, &words, space, tail);
        errdefer std.debug.print("expected no expectation for U+{X:0>4}: {s}\n", .{ space, prompt });
        try std.testing.expect(infer_expectation(prompt) == null);
    }
    // Three words, one of them joined to its neighbor by a no-break space.
    try std.testing.expect(infer_expectation("Terjemahkan ke\u{A0}Korea. The lockfile is broken again.") == null);
    // The space at either end of the prompt, after the clause's full stop, and
    // before a line break.
    try std.testing.expect(infer_expectation("\u{A0}Terjemahkan ke bahasa Korea.\u{A0}The lockfile is broken again.") == null);
    try std.testing.expect(infer_expectation("Terjemahkan ke bahasa Korea.\u{A0}\nThe lockfile is broken again.") == null);
    try std.testing.expect(infer_expectation("The lockfile is broken again. Terjemahkan\u{3000}ke\u{3000}bahasa\u{3000}Korea.\u{3000}") == null);
}

test "response language expectation splits words only at the listed Unicode spaces" {
    const words = [_][]const u8{ "Terjemahkan", "ke", "bahasa", "Korea." };
    const tail = " The lockfile is broken again.";
    for (not_spaces) |character| {
        var buffer: [128]u8 = undefined;
        const prompt = try joined_request(&buffer, &words, character, tail);
        errdefer std.debug.print("expected a Latin expectation for U+{X:0>4}: {s}\n", .{ character, prompt });
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
    // A lone continuation byte or a cut-short lead is not a space.
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("Terjemahkan\xA0ke\xA0bahasa\xA0Korea. The lockfile is broken again.").?,
    );
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("Terjemahkan\xC2ke\xC2bahasa\xC2Korea. The lockfile is broken again.").?,
    );
}

test "response language expectation keeps English that has Unicode spaces" {
    const words = [_][]const u8{ "The", "lockfile", "is", "broken", "again." };
    for (unicode_spaces) |space| {
        var buffer: [128]u8 = undefined;
        const prompt = try joined_request(&buffer, &words, space, "");
        errdefer std.debug.print("expected a Latin expectation for U+{X:0>4}: {s}\n", .{ space, prompt });
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
    // White space inside a code span never counts as a word.
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("Why does `foo\u{A0}bar\u{A0}baz\u{A0}qux` fail?").?,
    );
}

test "response language expectation ends a clause at every line break" {
    const requests = [_][2][]const u8{
        .{ "Terjemahkan ke bahasa Korea", "Why is the lockfile broken again?" },
        // English first, with no full stop before the break.
        .{ "Why is the lockfile broken again", "Terjemahkan ke bahasa Korea" },
        .{ "Tolong terjemahkan teks ini", "Please check the lockfile." },
    };
    for (line_breaks) |line_break| {
        for (requests) |request| {
            var buffer: [128]u8 = undefined;
            const prompt = try joined_request(&buffer, &request, line_break, "");
            errdefer std.debug.print("expected no expectation for U+{X:0>4}: {s}\n", .{ line_break, prompt });
            try std.testing.expect(infer_expectation(prompt) == null);
        }
    }
}

test "response language expectation ends a clause at a line break beside other separators" {
    const requests = [_][]const u8{
        // At both ends of the request.
        "\rTerjemahkan ke bahasa Korea\rWhy is the lockfile broken again?\r",
        "\u{2028}\u{2029}Terjemahkan ke bahasa Korea\u{85}Why is the lockfile broken again?",
        // Doubled, in a pair, beside spaces, and after a full stop.
        "Terjemahkan ke bahasa Korea\r\rWhy is the lockfile broken again?",
        "Terjemahkan ke bahasa Korea\r\nWhy is the lockfile broken again?",
        "Terjemahkan ke bahasa Korea\u{A0}\u{2028}\u{A0}Why is the lockfile broken again?",
        "Terjemahkan ke bahasa Korea \x0b \x0c Why is the lockfile broken again?",
        "Terjemahkan ke bahasa Korea.\rWhy is the lockfile broken again?",
    };
    for (requests) |prompt| {
        errdefer std.debug.print("expected no expectation for: {s}\n", .{prompt});
        try std.testing.expect(infer_expectation(prompt) == null);
    }
}

test "response language expectation keeps English that has line breaks" {
    const requests = [_][2][]const u8{
        .{ "Please check the lockfile", "Why does it break again?" },
        .{ "Why does the parser fail", "Please read the log." },
    };
    for (line_breaks) |line_break| {
        for (requests) |request| {
            var buffer: [128]u8 = undefined;
            const prompt = try joined_request(&buffer, &request, line_break, "");
            errdefer std.debug.print("expected a Latin expectation for U+{X:0>4}: {s}\n", .{ line_break, prompt });
            try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
        }
    }
}

test "response language expectation ends a clause only at a line break" {
    const words = [_][]const u8{ "Terjemahkan ke bahasa Korea", "Why is the lockfile broken again?" };
    // A space, or a character that is not a separator, joins the two lines
    // into one clause, which has English words.
    for (not_line_breaks) |character| {
        var buffer: [128]u8 = undefined;
        const prompt = try joined_request(&buffer, &words, character, "");
        errdefer std.debug.print("expected a Latin expectation for U+{X:0>4}: {s}\n", .{ character, prompt });
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
    // A lone continuation byte or a cut-short lead is not a line break.
    const lone_bytes = [_][]const u8{ "\x85", "\xA8", "\xA9", "\xC2", "\xE2\x80" };
    for (lone_bytes) |bytes| {
        var buffer: [128]u8 = undefined;
        const prompt = try std.mem.print(&buffer, "{s}{s}{s}", .{ words[0], bytes, words[1] });
        errdefer std.debug.print("expected a Latin expectation for: {s}\n", .{prompt});
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
    // A clause of two words is too short to judge, before a break as before a
    // full stop.
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("Tolong terjemahkan\rWhy is the lockfile broken again?").?,
    );
    // Each clause counts its own words: two clauses of two words are not one
    // clause of four.
    for (line_breaks) |line_break| {
        var buffer: [128]u8 = undefined;
        const short_clauses = [_][]const u8{ "Tolong terjemahkan", "teks ini", "Why is the lockfile broken again?" };
        const prompt = try joined_request(&buffer, &short_clauses, line_break, "");
        errdefer std.debug.print("expected a Latin expectation for U+{X:0>4}: {s}\n", .{ line_break, prompt });
        try std.testing.expectEqual(Script.latin, infer_expectation(prompt).?);
    }
    // A break inside a code span ends nothing and counts no word.
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("the `a\rb` Terjemahkan ke bahasa Korea.").?,
    );
    try std.testing.expectEqual(
        Script.latin,
        infer_expectation("the `a\u{2028}b` Terjemahkan ke bahasa Korea.").?,
    );
}

const fuzz_prompt_capacity = 512;

fn fuzzInferExpectation(_: void, smith: *std.testing.Smith) anyerror!void {
    // Letters that follow the random bytes: after a space, with no space, and
    // as a base letter with a combining mark. With no space, a lead byte at
    // the end of the random bytes can claim more bytes than remain.
    const accents = [_][]const u8{ " \u{1ECB}", "\u{E9}", "e\u{301}" };
    // Clauses of three words with no English function word: with ASCII spaces,
    // with Unicode spaces, with a name that has a Turkish ending, and ending at
    // a line break other than LF.
    const bare_clauses = [_][]const u8{
        "Tolong terjemahkan ini.\n",
        "Tolong\u{A0}terjemahkan\u{202F}ini.\n",
        "Tolong\u{3000}terjemahkan\u{2003}ini.\n",
        "Bunu Can'a Korece yaz.\n",
        "Tolong terjemahkan ini\r",
        "Tolong terjemahkan ini\x0b",
        "Tolong terjemahkan ini\x0c",
        "Tolong terjemahkan ini\u{85}",
        "Tolong\u{A0}terjemahkan\u{202F}ini\u{2028}",
        "Tolong terjemahkan ini\u{2029}",
    };
    var random: [fuzz_prompt_capacity]u8 = undefined;
    const len: usize = @intCast(smith.slice(&random));
    // fx only ever expects a Latin reply.
    if (infer_expectation(random[0..len])) |script| try std.testing.expectEqual(Script.latin, script);
    // A clause of three words with no English function word means the prompt
    // may not be English.
    for (bare_clauses) |bare_clause| {
        var buffer: [fuzz_prompt_capacity + 64]u8 = undefined;
        @memcpy(buffer[0..bare_clause.len], bare_clause);
        @memcpy(buffer[bare_clause.len..][0..len], random[0..len]);
        try std.testing.expect(infer_expectation(buffer[0 .. bare_clause.len + len]) == null);
    }
    // So does a Latin letter outside ASCII.
    var lettered: [fuzz_prompt_capacity + 8]u8 = undefined;
    @memcpy(lettered[0..len], random[0..len]);
    for (accents) |accent| {
        @memcpy(lettered[len..][0..accent.len], accent);
        try std.testing.expect(infer_expectation(lettered[0 .. len + accent.len]) == null);
    }
}

test "response language expectation stays conservative on fuzzed prompts" {
    try std.testing.fuzz({}, fuzzInferExpectation, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "The lockfile is broken again.",
            "Dịch nội dung sau sang tiếng Hàn. The lockfile is broken again.",
            "Terjemahkan ke bahasa Korea. The lockfile is broken again.",
            // English words straight after a line break.
            "Why is the lockfile broken again?",
            "Why does `zig build test` fail?\n```\nconst x = 1;\n```\nPlease check.",
            "The lockfile is broken \xf0\x9f",
            // A 4-byte lead at the end that the appended "é" cannot complete.
            "The lockfile is broken again. \xf0",
            "Di\u{323}ch giu\u{301}p. The lockfile is broken again.",
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
