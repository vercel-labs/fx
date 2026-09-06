const std = @import("std");
const language_script = @import("../../shared/language_script.zig");

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

pub fn infer_expectation(prompt: []const u8) ?Script {
    if (may_request_language_switch(prompt)) return null;
    const script = evidence(prompt).script orelse return null;
    return if (script == .latin and has_english_authority_signal(prompt)) script else null;
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
        evidence("English transcript payload with sparse 界 markers. " ** 16).script.?,
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
