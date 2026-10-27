//! Ranks a node's entries for a query as proto's recall does: the query
//! splits into words, common words drop out unless nothing else is left,
//! and each word matches anywhere in an entry, ignoring ASCII case. Entries
//! holding any word score by BM25+ (k1 1.2, b 0.75, delta 0.5), so rare
//! words count more and long entries do not win by length alone.
const std = @import("std");
const corpus = @import("corpus.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

const k1 = 1.2;
const b = 0.75;
const delta = 0.5;
pub const max_terms = 16;
/// A snippet line keeps at most this many bytes, cut around the match.
const snippet_line_bytes = 300;
const context_lines = 2;

const stopwords = [_][]const u8{
    "a",     "an",    "the",   "is",      "are",   "was",   "were",   "be",    "been",  "being",   "have",    "has",    "had",
    "do",    "does",  "did",   "will",    "would", "could", "should", "may",   "might", "must",    "can",     "shall",  "of",
    "in",    "to",    "for",   "with",    "on",    "at",    "from",   "by",    "as",    "into",    "through", "during", "before",
    "after", "above", "below", "between", "out",   "off",   "over",   "under", "again", "further", "then",    "once",   "here",
    "there", "when",  "where", "why",     "how",   "all",   "both",   "each",  "few",   "more",    "most",    "other",  "some",
    "such",  "no",    "nor",   "not",     "only",  "own",   "same",   "so",    "than",  "too",     "very",    "just",   "about",
    "it",    "its",   "that",  "this",    "what",  "which", "who",    "whom",  "these", "those",
};

fn isStopword(word: []const u8) bool {
    for (stopwords) |stop| if (std.ascii.eqlIgnoreCase(stop, word)) return true;
    return false;
}

/// The query's words: distinct, without common words unless only those
/// were given. Slices borrow `query`; the list is owned by `arena`.
pub fn terms(arena: Allocator, query: []const u8) ![]const []const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    var meaningful: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| {
        if (contains(all.items, word) or all.items.len == max_terms) continue;
        try all.append(arena, word);
        if (word.len > 1 and !isStopword(word)) try meaningful.append(arena, word);
    }
    return if (meaningful.items.len > 0) meaningful.items else all.items;
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (std.ascii.eqlIgnoreCase(item, word)) return true;
    return false;
}

/// Occurrences of `term` in `text`, ignoring ASCII case.
pub fn count(text: []const u8, term: []const u8) u32 {
    var found: u32 = 0;
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, at, term)) |index| {
        found +|= 1;
        at = index + term.len;
    }
    return found;
}

pub const Hit = struct {
    /// Position in the entries slice.
    slot: usize,
    score: f64,
};

/// The entries holding any of `query_terms`, best first; on equal scores
/// the newer first. Owned by `arena`.
pub fn rank(arena: Allocator, entries: []const corpus.Entry, query_terms: []const []const u8) ![]Hit {
    if (query_terms.len == 0 or entries.len == 0) return &.{};
    // Term counts per entry, computed once for document frequency and score.
    const counts = try arena.alloc(u32, entries.len * query_terms.len);
    const df = try arena.alloc(u32, query_terms.len);
    @memset(df, 0);
    var total_words: u64 = 0;
    for (entries, 0..) |entry, row| {
        total_words += entry.words;
        for (query_terms, 0..) |term, column| {
            const found = count(entry.text, term) + count(entry.label(), term);
            counts[row * query_terms.len + column] = found;
            if (found > 0) df[column] += 1;
        }
    }
    const n: f64 = @floatFromInt(entries.len);
    const average: f64 = @max(1.0, @as(f64, @floatFromInt(total_words)) / n);
    var hits: std.ArrayList(Hit) = .empty;
    for (entries, 0..) |entry, row| {
        var score: f64 = 0;
        const length: f64 = @floatFromInt(entry.words);
        for (query_terms, 0..) |_, column| {
            const tf: f64 = @floatFromInt(counts[row * query_terms.len + column]);
            if (tf == 0) continue;
            const freq: f64 = @floatFromInt(df[column]);
            const idf = @log((n - freq + 0.5) / (freq + 0.5) + 1.0);
            const norm = tf * (k1 + 1.0) / (tf + k1 * (1.0 - b + b * length / average));
            score += idf * (norm + delta);
        }
        if (score > 0) try hits.append(arena, .{ .slot = row, .score = score });
    }
    std.mem.sort(Hit, hits.items, {}, better);
    return hits.items;
}

fn better(_: void, left: Hit, right: Hit) bool {
    if (left.score != right.score) return left.score > right.score;
    return left.slot > right.slot;
}

/// The first line holding a query word with up to two lines around it, and
/// notes of the lines above and below; null when no line holds one. Owned
/// by `arena`.
pub fn snippet(arena: Allocator, text: []const u8, query_terms: []const []const u8) !?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    var matched: ?usize = null;
    while (split.next()) |line| {
        if (matched == null) for (query_terms) |term| {
            if (std.ascii.findIgnoreCase(line, term) != null) {
                matched = lines.items.len;
                break;
            }
        };
        try lines.append(arena, line);
        if (matched) |at| if (lines.items.len > at + context_lines) break;
    }
    const at = matched orelse return null;
    const total = std.mem.countScalar(u8, text, '\n') + 1;
    const start = at -| context_lines;
    const end = @min(lines.items.len, at + context_lines + 1);
    var out: std.Io.Writer.Allocating = .init(arena);
    if (start > 0) try out.writer.print("...({d} lines above)\n", .{start});
    for (lines.items[start..end], start..) |line, index| {
        try out.writer.writeAll(try clipLine(arena, std.mem.trimEnd(u8, line, "\r"), if (index == at) query_terms else &.{}));
        try out.writer.writeByte('\n');
    }
    if (end < total) try out.writer.print("...({d} lines below)\n", .{total - end});
    return std.mem.trimEnd(u8, out.written(), "\n");
}

/// A long line cut to `snippet_line_bytes`, around its first match when
/// `query_terms` names one.
fn clipLine(arena: Allocator, line: []const u8, query_terms: []const []const u8) ![]const u8 {
    if (line.len <= snippet_line_bytes) return line;
    var start: usize = 0;
    for (query_terms) |term| if (std.ascii.findIgnoreCase(line, term)) |index| {
        start = index -| snippet_line_bytes / 2;
        break;
    };
    start = text_utils.utf8BackwardBoundary(line, start);
    const end = text_utils.utf8BackwardBoundary(line, @min(line.len, start + snippet_line_bytes));
    return arena.print("{s}{s} … [truncated]", .{ if (start > 0) "… " else "", line[start..end] });
}

const testing = std.testing;

test "common words drop out unless nothing else is left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try terms(arena.allocator(), "what is the retry Backoff backoff");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("retry", got[0]);
    try testing.expectEqualStrings("Backoff", got[1]);
    try testing.expectEqual(@as(usize, 2), (try terms(arena.allocator(), "the it")).len);
}

test "rare words outrank common ones and ties go to the newer entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = [_]corpus.Entry{
        .{ .index = 0, .turn = 1, .role = .user, .text = "deploy the service", .words = 3 },
        .{ .index = 1, .turn = 2, .role = .assistant, .text = "Use exponential backoff for retry storms.", .words = 6 },
        .{ .index = 2, .turn = 3, .role = .user, .text = "deploy again", .words = 2 },
        .{ .index = 3, .turn = 4, .role = .user, .text = "deploy once more", .words = 3 },
    };
    const hits = try rank(arena.allocator(), &entries, &.{ "backoff", "deploy" });
    try testing.expectEqual(@as(usize, 4), hits.len);
    try testing.expectEqual(@as(usize, 1), hits[0].slot);
    // Equal-length deploys: the shorter wins, then the newer.
    try testing.expectEqual(@as(usize, 2), hits[1].slot);
    try testing.expectEqual(@as(usize, 3), hits[2].slot);
    try testing.expectEqual(@as(u32, 2), count("Retry retry", "RETRY"));
}

test "a snippet shows the matching line with its neighbours and what it left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "one\ntwo\nthree\nfour Backoff\nfive\nsix\nseven\neight";
    const got = (try snippet(arena.allocator(), text, &.{"backoff"})).?;
    try testing.expectEqualStrings("...(1 lines above)\ntwo\nthree\nfour Backoff\nfive\nsix\n...(2 lines below)", got);
    try testing.expect((try snippet(arena.allocator(), text, &.{"absent"})) == null);
    const long = text_utils.repeat("x", 400) ++ " needle " ++ text_utils.repeat("y", 400);
    const clipped = (try snippet(arena.allocator(), long, &.{"needle"})).?;
    try testing.expect(std.mem.find(u8, clipped, "needle") != null);
    try testing.expect(std.mem.startsWith(u8, clipped, "… "));
    try testing.expect(clipped.len < 400);
}
