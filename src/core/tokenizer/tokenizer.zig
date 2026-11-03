const std = @import("std");
const bpe = @import("bpe.zig");
const claude = @import("claude.zig");

/// Model-specific encodings bundled by proto-fx. The names intentionally
/// match configured_provider.ModelMetadata.tokenizer so request construction
/// can copy a value without borrowing catalog storage.
pub const Encoding = enum {
    o200k_base,
    cl100k_base,
    claude_v3,
    claude_v47,
    claude_v5,
    claude_v5_sonnet,
    qwen3,
    deepseek_v3,
    kimi_k2,
    glm5,

    pub fn parse(raw_name: []const u8) ?Encoding {
        if (std.ascii.eqlIgnoreCase(raw_name, "o200k-base") or std.ascii.eqlIgnoreCase(raw_name, "o200k_base")) return .o200k_base;
        if (std.ascii.eqlIgnoreCase(raw_name, "cl100k-base") or std.ascii.eqlIgnoreCase(raw_name, "cl100k_base")) return .cl100k_base;
        if (std.ascii.eqlIgnoreCase(raw_name, "claude-v3") or std.ascii.eqlIgnoreCase(raw_name, "claude_v3")) return .claude_v3;
        if (std.ascii.eqlIgnoreCase(raw_name, "claude-v47") or std.ascii.eqlIgnoreCase(raw_name, "claude_v47")) return .claude_v47;
        if (std.ascii.eqlIgnoreCase(raw_name, "claude-v5") or std.ascii.eqlIgnoreCase(raw_name, "claude_v5")) return .claude_v5;
        if (std.ascii.eqlIgnoreCase(raw_name, "claude-v5-sonnet") or std.ascii.eqlIgnoreCase(raw_name, "claude_v5_sonnet")) return .claude_v5_sonnet;
        if (std.ascii.eqlIgnoreCase(raw_name, "qwen3")) return .qwen3;
        if (std.ascii.eqlIgnoreCase(raw_name, "deepseek-v3") or std.ascii.eqlIgnoreCase(raw_name, "deepseek_v3")) return .deepseek_v3;
        if (std.ascii.eqlIgnoreCase(raw_name, "kimi-k2") or std.ascii.eqlIgnoreCase(raw_name, "kimi_k2")) return .kimi_k2;
        if (std.ascii.eqlIgnoreCase(raw_name, "glm5") or std.ascii.eqlIgnoreCase(raw_name, "glm-5")) return .glm5;
        return null;
    }

    pub fn name(self: Encoding) []const u8 {
        return switch (self) {
            .o200k_base => "o200k-base",
            .cl100k_base => "cl100k-base",
            .claude_v3 => "claude-v3",
            .claude_v47 => "claude-v47",
            .claude_v5 => "claude-v5",
            .claude_v5_sonnet => "claude-v5-sonnet",
            .qwen3 => "qwen3",
            .deepseek_v3 => "deepseek-v3",
            .kimi_k2 => "kimi-k2",
            .glm5 => "glm5",
        };
    }
};

pub fn count(text: []const u8, encoding: Encoding) usize {
    return switch (encoding) {
        .o200k_base => bpe.countO200k(text),
        .cl100k_base => bpe.countCl100k(text),
        .claude_v3 => claude.count(text, .v3),
        .claude_v47 => claude.count(text, .v47),
        .claude_v5 => claude.count(text, .v5),
        .claude_v5_sonnet => claude.count(text, .v5_sonnet),
        .qwen3 => bpe.countQwen3(text),
        .deepseek_v3 => bpe.countDeepseek(text),
        .kimi_k2 => bpe.countKimi(text),
        .glm5 => bpe.countGlm5(text),
    };
}

/// Family mapping ported from packages/catalog/src/model-tokenizer.ts. An
/// explicit metadata tokenizer should be preferred by callers; this helper is
/// the fallback for built-in/provider models whose metadata has no override.
pub fn resolveModel(model_id: []const u8) ?Encoding {
    const bare = if (std.mem.lastIndexOfScalar(u8, model_id, '/')) |slash| model_id[slash + 1 ..] else model_id;
    const lower = std.ascii.allocLowerString(std.heap.c_allocator, bare) catch return null;
    defer std.heap.c_allocator.free(lower);
    if (claudeEncoding(lower)) |encoding| return encoding;
    if (isQwen35(lower)) return .qwen3;
    if (std.mem.indexOf(u8, lower, "distill") == null and
        (std.mem.eql(u8, lower, "deepseek-chat") or std.mem.eql(u8, lower, "deepseek-reasoner") or
            (std.mem.indexOf(u8, lower, "deepseek") != null and hasDeepseekVersion(lower))))
    {
        return .deepseek_v3;
    }
    if (std.mem.eql(u8, lower, "kimi-for-coding") or std.mem.eql(u8, lower, "kimi-for-coding-highspeed") or hasKimiVersion(lower)) return .kimi_k2;
    if (hasGlmVersionAtLeast5(lower)) return .glm5;
    return null;
}

const ClaudeKind = enum { opus, other };

fn claudeEncoding(lower: []const u8) ?Encoding {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, lower, search, "claude-")) |match_pos| {
        const after = match_pos + 7;
        if (after < lower.len) {
            if (claudeKindAt(lower, after)) |kind| {
                const kind_end = kind.end;
                if (kind_end < lower.len and lower[kind_end] == '-') {
                    if (parseClaudeVersion(lower, kind_end + 1)) |version| {
                        return claudeEncodingFor(kind.kind, version.major, version.minor);
                    }
                }
            }
            if (parseClaudeVersion(lower, after)) |version| {
                if (version.end < lower.len and lower[version.end] == '-') {
                    if (claudeKindAt(lower, version.end + 1)) |kind| {
                        return claudeEncodingFor(kind.kind, version.major, version.minor);
                    }
                }
            }
        }
        search = after;
    }
    return if (hasClaudeFallbackToken(lower)) .claude_v3 else null;
}

fn claudeEncodingFor(kind: ClaudeKind, major: u32, minor: u32) Encoding {
    if (kind == .opus) {
        if (major >= 5) return .claude_v5;
        if (major > 4 or (major == 4 and minor >= 7)) return .claude_v47;
        return .claude_v3;
    }
    return if (major >= 5) .claude_v5_sonnet else .claude_v3;
}

fn claudeKindAt(lower: []const u8, start: usize) ?struct { kind: ClaudeKind, end: usize } {
    const kinds = [_]struct { name: []const u8, kind: ClaudeKind }{
        .{ .name = "opus", .kind = .opus },
        .{ .name = "sonnet", .kind = .other },
        .{ .name = "haiku", .kind = .other },
        .{ .name = "fable", .kind = .other },
        .{ .name = "mythos", .kind = .other },
    };
    for (kinds) |candidate| {
        if (start + candidate.name.len <= lower.len and std.mem.eql(u8, lower[start .. start + candidate.name.len], candidate.name)) {
            return .{ .kind = candidate.kind, .end = start + candidate.name.len };
        }
    }
    return null;
}

fn parseClaudeVersion(lower: []const u8, start: usize) ?struct { major: u32, minor: u32, end: usize } {
    var i = start;
    const major_start = i;
    var major: u32 = 0;
    while (i < lower.len and lower[i] >= '0' and lower[i] <= '9') : (i += 1) major = major * 10 + lower[i] - '0';
    if (i == major_start) return null;
    var minor: u32 = 0;
    if (i < lower.len and (lower[i] == '.' or lower[i] == '-')) {
        const separator = i;
        i += 1;
        const minor_start = i;
        while (i < lower.len and lower[i] >= '0' and lower[i] <= '9') : (i += 1) minor = minor * 10 + lower[i] - '0';
        if (i == minor_start) {
            i = separator;
        } else if (i < lower.len and (lower[i] == '.' or lower[i] == '-')) {
            const patch_separator = i;
            i += 1;
            const patch_start = i;
            while (i < lower.len and lower[i] >= '0' and lower[i] <= '9') : (i += 1) {}
            if (i == patch_start) i = patch_separator;
        }
    }
    // JS `\\b` in the catalog parser permits punctuation but not another word
    // character immediately after the version.
    if (i < lower.len and ((lower[i] >= 'a' and lower[i] <= 'z') or (lower[i] >= '0' and lower[i] <= '9') or lower[i] == '_')) return null;
    return .{ .major = major, .minor = minor, .end = i };
}

fn hasClaudeFallbackToken(lower: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, lower, search, "claude")) |match_pos| {
        const before_ok = match_pos == 0 or lower[match_pos - 1] == '-' or lower[match_pos - 1] == '/' or lower[match_pos - 1] == '.' or lower[match_pos - 1] == ':';
        const end = match_pos + 6;
        const after_ok = end == lower.len or lower[end] == '-' or lower[end] == '.' or lower[end] == ':';
        if (before_ok and after_ok) return true;
        search = end;
    }
    return false;
}

fn isQwen35(lower: []const u8) bool {
    // Mirrors the catalog regex: qwen[-_ ]?(major).(minor), with no digit or
    // B/b immediately after the minor. Search the full bare model ID because
    // the catalog resolver does the same for provider-qualified variants.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, lower, search, "qwen")) |qwen| {
        var i = qwen + 4;
        if (i < lower.len and (lower[i] == '-' or lower[i] == '_' or lower[i] == ' ')) i += 1;
        const major_start = i;
        var major: u32 = 0;
        while (i < lower.len and lower[i] >= '0' and lower[i] <= '9') : (i += 1) major = major * 10 + lower[i] - '0';
        if (i != major_start and i < lower.len and lower[i] == '.') {
            i += 1;
            const minor_start = i;
            var minor: u32 = 0;
            while (i < lower.len and lower[i] >= '0' and lower[i] <= '9') : (i += 1) minor = minor * 10 + lower[i] - '0';
            const disallowed_suffix = i < lower.len and (lower[i] == 'b' or lower[i] == 'B');
            if (i != minor_start and !disallowed_suffix and (major > 3 or (major == 3 and minor >= 5))) return true;
        }
        search = qwen + 4;
    }
    return false;
}

fn isModelDelimiter(byte: u8) bool {
    return byte == '-' or byte == '_' or byte == '.' or byte == ':';
}

fn hasDeepseekVersion(lower: []const u8) bool {
    var i: usize = 0;
    while (i < lower.len) : (i += 1) {
        if (i != 0 and !isModelDelimiter(lower[i - 1])) continue;
        var end = i;
        if (end < lower.len and lower[end] == 'v') end += 1;
        if (end >= lower.len or (lower[end] != '3' and lower[end] != '4' and lower[end] != 'r')) continue;
        if (lower[end] == 'r') {
            if (end + 1 >= lower.len or lower[end + 1] != '1') continue;
            end += 2;
        } else {
            end += 1;
        }
        if (end == lower.len or isModelDelimiter(lower[end])) return true;
    }
    return false;
}

fn hasKimiVersion(lower: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, lower, search, "kimi")) |match_pos| {
        const before_ok = match_pos == 0 or isModelDelimiter(lower[match_pos - 1]);
        var i = match_pos + 4;
        if (before_ok) {
            if (i < lower.len and isModelDelimiter(lower[i])) i += 1;
            if (i < lower.len and lower[i] == 'k') i += 1;
            if (i < lower.len and (lower[i] == '2' or lower[i] == '3') and
                (i + 1 == lower.len or isModelDelimiter(lower[i + 1]))) return true;
        }
        search = match_pos + 4;
    }
    return false;
}

fn hasGlmVersionAtLeast5(lower: []const u8) bool {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, lower, search, "glm")) |match_pos| {
        const before_ok = match_pos == 0 or !((lower[match_pos - 1] >= 'a' and lower[match_pos - 1] <= 'z') or
            (lower[match_pos - 1] >= '0' and lower[match_pos - 1] <= '9'));
        var i = match_pos + 3;
        if (before_ok) {
            if (i < lower.len and lower[i] == '-') i += 1;
            const major_start = i;
            var major: u32 = 0;
            while (i < lower.len and lower[i] >= '0' and lower[i] <= '9' and i - major_start < 2) : (i += 1) major = major * 10 + lower[i] - '0';
            if (i < lower.len and lower[i] == 'v') i += 1;
            if (i != major_start and (i == lower.len or !((lower[i] >= 'a' and lower[i] <= 'z') or (lower[i] >= '0' and lower[i] <= '9') or lower[i] == '_'))) {
                if (major >= 5) return true;
            }
        }
        search = match_pos + 3;
    }
    return false;
}

test "Encoding parses canonical names without retaining input storage" {
    try std.testing.expectEqual(Encoding.claude_v5_sonnet, Encoding.parse("CLAUDE_V5_SONNET").?);
    try std.testing.expectEqual(Encoding.qwen3, Encoding.parse("qwen3").?);
    try std.testing.expectEqual(Encoding.deepseek_v3, Encoding.parse("deepseek-v3").?);
    try std.testing.expectEqual(@as(?Encoding, null), Encoding.parse("unknown-tokenizer"));
    try std.testing.expectEqualStrings("claude-v47", Encoding.claude_v47.name());
}

test "resolveModel selects family fallback and honors version separators" {
    try std.testing.expectEqual(Encoding.claude_v47, resolveModel("anthropic/claude-opus-4-7").?);
    try std.testing.expectEqual(Encoding.claude_v3, resolveModel("claude-sonnet-4-7").?);
    try std.testing.expectEqual(Encoding.claude_v5, resolveModel("claude-opus-5.5").?);
    try std.testing.expectEqual(Encoding.claude_v5_sonnet, resolveModel("claude-sonnet-5-5").?);
    try std.testing.expectEqual(Encoding.qwen3, resolveModel("qwen/qwen3.5-plus").?);
    try std.testing.expectEqual(Encoding.qwen3, resolveModel("qwen/qwen4.1").?);
    try std.testing.expectEqual(@as(?Encoding, null), resolveModel("qwen4-max"));
    try std.testing.expectEqual(Encoding.deepseek_v3, resolveModel("deepseek-reasoner").?);
    try std.testing.expectEqual(Encoding.deepseek_v3, resolveModel("deepseek-v3.1").?);
    try std.testing.expectEqual(@as(?Encoding, null), resolveModel("deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"));
    try std.testing.expectEqual(Encoding.kimi_k2, resolveModel("kimi-for-coding-highspeed").?);
    try std.testing.expectEqual(Encoding.kimi_k2, resolveModel("kimi-k3").?);
    try std.testing.expectEqual(@as(?Encoding, null), resolveModel("kimi-k20"));
    try std.testing.expectEqual(Encoding.glm5, resolveModel("zai/glm-5.2").?);
    try std.testing.expectEqual(Encoding.glm5, resolveModel("glm-5v").?);
}
