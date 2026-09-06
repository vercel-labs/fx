const std = @import("std");

pub const max_query_bytes: usize = 4 * 1024;
// Distinct tokens require at least one byte each and a separator between them.
pub const max_query_tokens: usize = (max_query_bytes + 1) / 2;

pub const PrepareError = error{
    QueryTooLong,
};

pub const PreparedQuery = struct {
    raw: []const u8,
    tokens: [max_query_tokens][]const u8,
    token_count: usize,

    pub fn tokenSlice(self: *const PreparedQuery) []const []const u8 {
        return self.tokens[0..self.token_count];
    }
};

inline fn failPreparedQuery(err: anytype) @TypeOf(err)!PreparedQuery {
    return @errorCast(failPreparedQueryDynamic(err));
}

noinline fn failPreparedQueryDynamic(err: anyerror) anyerror!PreparedQuery {
    return err;
}

test "prepared query failures preserve exact error types and identities" {
    const too_long = failPreparedQuery(error.QueryTooLong);
    try std.testing.expect(@TypeOf(too_long) == error{QueryTooLong}!PreparedQuery);
    try std.testing.expectError(error.QueryTooLong, too_long);
}

pub const Score = struct {
    exact_identity: bool = false,
    strong_hits: usize = 0,
    weak_hits: usize = 0,
};

pub fn prepare(query: []const u8) PrepareError!PreparedQuery {
    if (query.len > max_query_bytes) return failPreparedQuery(error.QueryTooLong);

    var prepared = PreparedQuery{
        .raw = query,
        .tokens = undefined,
        .token_count = 0,
    };
    var start: ?usize = null;
    for (query, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |token_start| {
            appendToken(&prepared, query[token_start..index]);
            start = null;
        }
    }
    if (start) |token_start| {
        appendToken(&prepared, query[token_start..]);
    }
    return prepared;
}

pub fn score(
    query: *const PreparedQuery,
    exact_identities: []const []const u8,
    strong_fields: []const []const u8,
    weak_fields: []const []const u8,
) ?Score {
    var result = Score{
        .exact_identity = containsCompleteIdentity(query.raw, exact_identities),
    };

    for (query.tokenSlice()) |token| {
        if (containsAnyCompleteToken(strong_fields, token)) {
            result.strong_hits += 1;
        } else if (containsAnySubstring(weak_fields, token)) {
            result.weak_hits += 1;
        }
    }

    if (!result.exact_identity and
        result.strong_hits == 0 and
        result.weak_hits == 0 and
        query.raw.len != 0)
    {
        return null;
    }
    return result;
}

pub fn order(a: Score, b: Score) std.math.Order {
    var result = std.math.order(@intFromBool(a.exact_identity), @intFromBool(b.exact_identity));
    if (result != .eq) return result;
    result = std.math.order(a.strong_hits +| a.weak_hits, b.strong_hits +| b.weak_hits);
    if (result != .eq) return result;
    return std.math.order(a.strong_hits, b.strong_hits);
}

fn appendToken(
    prepared: *PreparedQuery,
    token: []const u8,
) void {
    for (prepared.tokenSlice()) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, token)) return;
    }
    std.debug.assert(prepared.token_count < max_query_tokens);
    prepared.tokens[prepared.token_count] = token;
    prepared.token_count += 1;
}

fn containsAnyCompleteToken(fields: []const []const u8, token: []const u8) bool {
    for (fields) |field| {
        if (containsCompleteTokenIgnoreCase(field, token)) return true;
    }
    return false;
}

fn containsAnySubstring(fields: []const []const u8, token: []const u8) bool {
    for (fields) |field| {
        if (containsIgnoreCase(field, token)) return true;
    }
    return false;
}

fn containsCompleteTokenIgnoreCase(field: []const u8, token: []const u8) bool {
    if (token.len == 0 or token.len > field.len) return false;

    var start: usize = 0;
    while (start <= field.len - token.len) : (start += 1) {
        const end = start + token.len;
        if (!std.ascii.eqlIgnoreCase(field[start..end], token)) continue;
        if (start > 0 and std.ascii.isAlphanumeric(field[start - 1])) continue;
        if (end < field.len and std.ascii.isAlphanumeric(field[end])) continue;
        return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start <= haystack.len - needle.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

pub fn containsCompleteIdentity(raw: []const u8, identities: []const []const u8) bool {
    for (raw, 0..) |_, start| {
        for (identities) |identity| {
            if (identity.len == 0 or identity.len > raw.len - start) continue;
            const end = start + identity.len;
            if (!std.ascii.eqlIgnoreCase(raw[start..end], identity)) continue;
            if (start > 0 and isIdentityByte(raw[start - 1])) continue;
            if (end < raw.len and isIdentityByte(raw[end])) continue;
            return true;
        }
    }
    return false;
}

fn isIdentityByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

test "prepared queries accept long requests within the byte bound" {
    const query = "workflow " ** 100;
    const prepared = try prepare(query);
    try std.testing.expectEqualStrings(query, prepared.raw);
    try std.testing.expectEqual(@as(usize, 1), prepared.token_count);
}

test "prepared queries enforce bounds and deduplicate case-insensitively" {
    const prepared = try prepare("GitHub github GITHUB issue");
    try std.testing.expectEqual(@as(usize, 2), prepared.token_count);
    try std.testing.expectEqualStrings("GitHub", prepared.tokenSlice()[0]);
    try std.testing.expectEqualStrings("issue", prepared.tokenSlice()[1]);

    _ = try prepare("a" ** max_query_bytes);
    try std.testing.expectError(error.QueryTooLong, prepare("a" ** (max_query_bytes + 1)));

    const max_tokens = "a " ** max_query_tokens;
    _ = try prepare(max_tokens);
    try std.testing.expectError(error.QueryTooLong, prepare(max_tokens ++ "a"));
}

test "scores preserve exact punctuation identities and fuzzy partial matches" {
    const identities = [_][]const u8{"read/file"};
    const strong = [_][]const u8{"read/file"};
    const weak = [_][]const u8{"Read a file from the workspace"};

    const exact_query = try prepare("please use read/file now");
    const exact = score(&exact_query, &identities, &strong, &weak).?;
    try std.testing.expect(exact.exact_identity);

    const separated_query = try prepare("please use read file now");
    const separated = score(&separated_query, &identities, &strong, &weak).?;
    try std.testing.expect(!separated.exact_identity);

    const partial_query = try prepare("please use read/files now");
    const partial = score(&partial_query, &identities, &strong, &weak).?;
    try std.testing.expect(!partial.exact_identity);
    try std.testing.expect(partial.strong_hits > 0);
}

test "scores count distinct strong and weak hits with stable ordering" {
    const no_identities = [_][]const u8{};
    const strong = [_][]const u8{"brave web search"};
    const weak = [_][]const u8{"Find current public information"};

    const query = try prepare("web public public unrelated");
    const relevance = score(&query, &no_identities, &strong, &weak).?;
    try std.testing.expectEqual(@as(usize, 1), relevance.strong_hits);
    try std.testing.expectEqual(@as(usize, 1), relevance.weak_hits);

    const empty_query = try prepare("");
    try std.testing.expectEqual(Score{}, score(&empty_query, &no_identities, &strong, &weak).?);

    const irrelevant_query = try prepare("calendar");
    try std.testing.expect(score(&irrelevant_query, &no_identities, &strong, &weak) == null);

    try std.testing.expectEqual(.gt, order(.{ .exact_identity = true }, .{ .strong_hits = 64 }));
    try std.testing.expectEqual(.lt, order(.{ .strong_hits = 1 }, .{ .weak_hits = 64 }));
    try std.testing.expectEqual(.eq, order(relevance, relevance));

    const large = Score{ .strong_hits = 65_536 };
    try std.testing.expectEqual(.gt, order(large, .{ .strong_hits = 65_535 }));
}

test "strong fields require complete normalized query tokens" {
    const query = try prepare("send an email");
    const no_identities = [_][]const u8{};
    const analysis_names = [_][]const u8{"analysis-tools"};
    const analysis_descriptions = [_][]const u8{"Analyze local source code"};
    const mail_names = [_][]const u8{"mail-helper"};
    const mail_descriptions = [_][]const u8{"Send email messages to recipients"};

    const analysis = score(
        &query,
        &no_identities,
        &analysis_names,
        &analysis_descriptions,
    ).?;
    const mail = score(
        &query,
        &no_identities,
        &mail_names,
        &mail_descriptions,
    ).?;

    try std.testing.expectEqual(@as(usize, 0), analysis.strong_hits);
    try std.testing.expectEqual(@as(usize, 1), analysis.weak_hits);
    try std.testing.expectEqual(@as(usize, 2), mail.weak_hits);
    try std.testing.expectEqual(.gt, order(mail, analysis));

    const ui_query = try prepare("ui");
    const ui_names = [_][]const u8{"terminal-ui-review"};
    try std.testing.expectEqual(
        @as(usize, 1),
        score(&ui_query, &no_identities, &ui_names, &.{}).?.strong_hits,
    );
}

test "matched query coverage precedes strong field tie breaking" {
    const query = try prepare("send email");
    const no_identities = [_][]const u8{};
    const one_name_match = score(
        &query,
        &no_identities,
        &.{"send-tool"},
        &.{},
    ).?;
    const two_description_matches = score(
        &query,
        &no_identities,
        &.{"mail-helper"},
        &.{"Send email messages to recipients"},
    ).?;

    try std.testing.expectEqual(@as(usize, 1), one_name_match.strong_hits);
    try std.testing.expectEqual(@as(usize, 2), two_description_matches.weak_hits);
    try std.testing.expectEqual(.gt, order(two_description_matches, one_name_match));

    const equal_coverage_strong = Score{ .strong_hits = 1, .weak_hits = 1 };
    const equal_coverage_weak = Score{ .weak_hits = 2 };
    try std.testing.expectEqual(.gt, order(equal_coverage_strong, equal_coverage_weak));
}
