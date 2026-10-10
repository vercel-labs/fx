//! Turns, tool calls and earlier compactions saved by context compaction, and
//! search over them.
//!
//! Each is one file in the session's tool-results store: tool call T12 with
//! its input and output unchanged in `compacted-T12.txt`, turn 12 word for
//! word in `compacted-M12.txt`, and the first compaction a later one folded
//! away, whole, in `compacted-L1.txt`. The first line of every file is an index line
//! that says what it is, so a match there counts more. Conversation archives
//! written by the previous compactor are searched too, one message or tool
//! result at a time.
//!
//! Search is plain word matching; singular and plural count as one word.
//! Rare words count more than common ones (BM25), and a query's words found
//! together in its order count more still.
//! Each result shows the whole record when it is short, otherwise the lines
//! that match best.

const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const trace = @import("trace.zig");

const Allocator = std.mem.Allocator;

/// Where records are kept: plain named files that fx-compactor's caller
/// provides, such as a session's tool-results folder. The store checks names
/// and reports missing files as `FileNotFound`.
pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ FileNotFound, StoreFailed, OutOfMemory };

    pub const VTable = struct {
        /// Saves `content` as `name`, replacing any file of that name.
        write: *const fn (context: *anyopaque, alloc: Allocator, name: []const u8, content: []const u8) Error!void,
        /// The name of every file. `arena` owns the list.
        list: *const fn (context: *anyopaque, arena: Allocator) Error![]const []const u8,
        /// Up to `max_bytes` from the start of `name`. `arena` owns them.
        read: *const fn (context: *anyopaque, arena: Allocator, name: []const u8, max_bytes: usize) Error![]const u8,
    };

    pub fn write(self: Store, alloc: Allocator, name: []const u8, content: []const u8) Error!void {
        return self.vtable.write(self.context, alloc, name, content);
    }

    pub fn list(self: Store, arena: Allocator) Error![]const []const u8 {
        return self.vtable.list(self.context, arena);
    }

    pub fn read(self: Store, arena: Allocator, name: []const u8, max_bytes: usize) Error![]const u8 {
        return self.vtable.read(self.context, arena, name, max_bytes);
    }
};

pub const Kind = enum {
    tool,
    turn,
    /// An earlier compaction, saved whole when the next one folds it.
    ledger,

    fn letter(kind: Kind) u8 {
        return switch (kind) {
            .tool => 'T',
            .turn => 'M',
            .ledger => 'L',
        };
    }

    fn noun(kind: Kind, count: usize) []const u8 {
        const one = count == 1;
        return switch (kind) {
            .tool => if (one) "tool call" else "tool calls",
            .turn => if (one) "turn" else "turns",
            .ledger => if (one) "earlier compaction" else "earlier compactions",
        };
    }
};

/// T12 is tool call 12; M12 is turn 12; L2 is the second compaction, saved
/// when the third one folded it.
pub const Id = struct {
    kind: Kind,
    number: usize,
};

const file_prefix = "compacted-";
const file_suffix = ".txt";
/// Only this much of one file is searched; it bounds memory.
const max_file_bytes = 8 * 1024 * 1024;
/// A result shows at most this much of its record.
const shown_bytes = 3000;
/// A word in an index line counts as often as this many in the body.
const index_line_weight = 3;
const max_terms = 32;
const archive_heading = "### ";
const archive_tool_call_heading = "### Tool call";

pub const search_result_limit = 5;
pub const max_search_phrases = 3;
pub const max_file_name_bytes = file_prefix.len + 1 + 20 + file_suffix.len;

/// `compacted-T<number>.txt` or `compacted-M<number>.txt` in `buffer`.
pub fn fileName(buffer: *[max_file_name_bytes]u8, id: Id) []const u8 {
    // The buffer holds any usize in decimal.
    const digits_start = file_prefix.len + 1;
    buffer[0..file_prefix.len].* = file_prefix.*;
    buffer[file_prefix.len] = id.kind.letter();
    const end = digits_start + std.fmt.printInt(buffer[digits_start..], id.number, 10, .lower, .{});
    buffer[end..][0..file_suffix.len].* = file_suffix.*;
    return buffer[0 .. end + file_suffix.len];
}

/// Parses an ID the agent types: "T12", "M12", "L2", or lowercase. Zero is
/// not an ID.
pub fn parseId(text: []const u8) ?Id {
    if (text.len < 2) return null;
    const kind: Kind = switch (text[0]) {
        'T', 't' => .tool,
        'M', 'm' => .turn,
        'L', 'l' => .ledger,
        else => return null,
    };
    return .{ .kind = kind, .number = parseNumber(text[1..]) orelse return null };
}

fn parseFileName(name: []const u8) ?Id {
    if (!std.mem.startsWith(u8, name, file_prefix) or !std.mem.endsWith(u8, name, file_suffix)) return null;
    const id = name[file_prefix.len .. name.len - file_suffix.len];
    if (id.len == 0 or !std.ascii.isUpper(id[0])) return null;
    return parseId(id);
}

fn parseNumber(digits: []const u8) ?usize {
    if (digits.len == 0) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const number = std.fmt.parseUnsigned(usize, digits, 10) catch return null;
    return if (number == 0) null else number;
}

/// Saves one record unchanged. A committed compaction never saves an ID it
/// already used, so replacing an existing file only ever overwrites leftovers
/// from a compaction that did not commit.
pub fn save(alloc: Allocator, store: Store, id: Id, content: []const u8) Store.Error!void {
    var buffer: [max_file_name_bytes]u8 = undefined;
    return store.write(alloc, fileName(&buffer, id), content);
}

/// No session numbers this many turns, tool calls or compactions. A saved
/// number above it is damage, and numbering on from it would overflow.
pub const max_number: usize = 1 << 30;

/// The highest turn, tool call and ledger numbers saved; zero when there are
/// none.
pub const Highest = struct { turns: usize = 0, tools: usize = 0, ledgers: usize = 0 };

pub fn highestSaved(arena: Allocator, store: Store) Store.Error!Highest {
    var highest: Highest = .{};
    for (try store.list(arena)) |name| {
        const id = parseFileName(name) orelse continue;
        if (id.number > max_number) {
            trace.log(true, "a saved record numbered past every session is left out of the numbering name={s}", .{name});
            continue;
        }
        switch (id.kind) {
            .turn => highest.turns = @max(highest.turns, id.number),
            .tool => highest.tools = @max(highest.tools, id.number),
            .ledger => highest.ledgers = @max(highest.ledgers, id.number),
        }
    }
    return highest;
}

/// The whole of file `name` when it is exactly `bytes` long and no larger
/// than a searched file, else null. `arena` owns the bytes.
pub fn readExact(arena: Allocator, store: Store, name: []const u8, bytes: usize) Allocator.Error!?[]const u8 {
    const problem: []const u8 = problem: {
        if (bytes > max_file_bytes) break :problem "ResultSizeUnsupported";
        // One byte more than expected shows a file that grew.
        const content = store.read(arena, name, bytes + 1) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :problem @errorName(err),
        };
        if (content.len == bytes) return content;
        break :problem "ResultSizeMismatch";
    };
    trace.log(true, "earlier state file unavailable handle={s} err={s}", .{ name, problem });
    return null;
}

/// One searchable record: a saved turn or tool call, or one turn of an
/// earlier conversation archive.
const Doc = struct {
    /// Null for part of an archive.
    id: ?Id,
    /// The archive's file name, for parts of an archive.
    archive: []const u8 = "",
    /// The index line; empty for archive parts.
    title: []const u8,
    body: []const u8,
    /// Where `body` starts in its file.
    offset: usize,
    file_bytes: usize,
    length: usize = 0,
    score: f64 = 0,
    /// Bit `n` is set when the record holds every word of query `n`.
    complete: u32 = 0,

    /// On equal scores the conversation outranks tool output, which outranks
    /// a saved ledger repeating both; then newer first.
    fn better(_: void, a: Doc, b: Doc) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.rank() != b.rank()) return a.rank() < b.rank();
        return (if (a.id) |id| id.number else 0) > (if (b.id) |id| id.number else 0);
    }

    fn rank(doc: Doc) u2 {
        const id = doc.id orelse return 0;
        return switch (id.kind) {
            .turn => 0,
            .tool => 1,
            .ledger => 2,
        };
    }
};

/// The searched words, lowercase and distinct, and each multi-word query as
/// a sequence of those words.
const Query = struct {
    terms: []const []const u8,
    phrases: []const []const usize,
    /// Each query with any words, as typed, and its words.
    texts: []const []const u8 = &.{},
    words: []const []const usize = &.{},
};

/// Only this many queries are told apart by `Doc.complete`.
const max_counted_queries = 32;

comptime {
    std.debug.assert(max_search_phrases <= max_counted_queries);
}

/// Searches every saved turn and tool call, and earlier conversation
/// archives, for `queries` and returns the best `limit` results as text for
/// the agent. Caller owns the returned text.
pub fn search(alloc: Allocator, store: Store, queries: []const []const u8, limit: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const query = try prepareQuery(arena, queries);
    if (query.terms.len == 0) return error.EmptySearch;

    var docs: std.ArrayList(Doc) = .empty;
    for (try store.list(arena)) |name| {
        const id = parseFileName(name);
        if (id == null and !isEarlierArchive(name)) continue;
        const content = store.read(arena, name, max_file_bytes) catch |err| switch (err) {
            // Removed between listing and opening.
            error.FileNotFound => continue,
            else => return err,
        };
        if (id) |value| {
            const title_end = std.mem.findScalar(u8, content, '\n') orelse content.len;
            const body_start = @min(content.len, title_end + 1);
            try docs.append(arena, .{ .id = value, .title = content[0..title_end], .body = content[body_start..], .offset = body_start, .file_bytes = content.len });
        } else {
            try appendArchiveParts(arena, &docs, name, content);
        }
    }
    const weights = try score(arena, docs.items, query);

    std.mem.sort(Doc, docs.items, {}, Doc.better);
    var found: usize = 0;
    while (found < @min(limit, docs.items.len) and docs.items[found].score > 0) found += 1;
    return formatResults(alloc, arena, queries, query, weights, docs.items, found);
}

/// For each query, how many records hold all of its words, and the first and
/// last of each kind. IDs count up in time order, so this finds the earliest
/// and latest of look-alike records even when the best matches are others.
fn writeCoverage(writer: *std.Io.Writer, query: Query, docs: []const Doc) !void {
    var any = false;
    for (query.texts, 0..) |text, query_index| {
        const bit = @as(u32, 1) << @intCast(query_index);
        const Span = struct { count: usize = 0, first: usize = std.math.maxInt(usize), last: usize = 0 };
        var spans = std.EnumArray(Kind, Span).initFill(.{});
        var archive_parts: usize = 0;
        for (docs) |doc| {
            if (doc.complete & bit == 0) continue;
            const id = doc.id orelse {
                archive_parts += 1;
                continue;
            };
            const span = spans.getPtr(id.kind);
            span.count += 1;
            span.first = @min(span.first, id.number);
            span.last = @max(span.last, id.number);
        }
        try writer.writeAll("Every word of ");
        try std.json.Stringify.value(text, .{}, writer);
        var parts: usize = 0;
        for ([_]Kind{ .turn, .tool, .ledger }) |kind| {
            const span = spans.get(kind);
            if (span.count == 0) continue;
            try writer.writeAll(if (parts == 0) " is in " else ", ");
            try writer.print("{d} {s}", .{ span.count, kind.noun(span.count) });
            if (span.count == 1) {
                try writer.print(" ({c}{d})", .{ kind.letter(), span.first });
            } else {
                try writer.print(" (first {c}{d}, last {c}{d})", .{ kind.letter(), span.first, kind.letter(), span.last });
            }
            parts += 1;
        }
        if (archive_parts > 0) {
            try writer.writeAll(if (parts == 0) " is in " else ", ");
            try writer.print("{d} earlier archive {s}", .{ archive_parts, if (archive_parts == 1) "part" else "parts" });
            parts += 1;
        }
        if (parts == 0) try writer.writeAll(" is in no saved record");
        try writer.writeAll(".\n");
        any = any or parts > 0;
    }
    if (any) try writer.writeAll("IDs count up in time order: a lower number came earlier.\n");
}

/// Transcripts of earlier conversation saved by the previous compactor. They
/// hold what came before fx saved numbered turns and tool calls.
fn isEarlierArchive(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "result-source-") and std.mem.endsWith(u8, name, file_suffix);
}

/// Splits an archive into one record per message and per tool result, at
/// their headings. Tool calls stay with the message that made them.
fn appendArchiveParts(arena: Allocator, docs: *std.ArrayList(Doc), name: []const u8, content: []const u8) !void {
    var start: usize = 0;
    var at: usize = 0;
    while (at < content.len) {
        const line_end = std.mem.findScalarPos(u8, content, at, '\n') orelse content.len;
        const line = content[at..line_end];
        if (at > start and std.mem.startsWith(u8, line, archive_heading) and !std.mem.startsWith(u8, line, archive_tool_call_heading)) {
            try docs.append(arena, .{ .id = null, .archive = name, .title = "", .body = content[start..at], .offset = start, .file_bytes = content.len });
            start = at;
        }
        at = line_end + 1;
    }
    if (start < content.len) try docs.append(arena, .{ .id = null, .archive = name, .title = "", .body = content[start..], .offset = start, .file_bytes = content.len });
}

/// Letters (and any non-ASCII bytes) and digits form separate words, so
/// "2GB" and "2 GB" both read as "2", "gb". An escaped `\n`, `\t` or `\r`
/// separates words too, as it does inside saved shell results, which are
/// JSON.
const Tokens = struct {
    text: []const u8,
    index: usize = 0,

    const Class = enum { letter, digit, other };

    fn class(byte: u8) Class {
        if (std.ascii.isDigit(byte)) return .digit;
        if (std.ascii.isAlphabetic(byte) or byte >= 0x80) return .letter;
        return .other;
    }

    fn next(self: *Tokens) ?[]const u8 {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (byte == '\\' and self.index + 1 < self.text.len and std.mem.findScalar(u8, "ntr", self.text[self.index + 1]) != null) {
                self.index += 2;
            } else if (class(byte) == .other) {
                self.index += 1;
            } else break;
        }
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const kind = class(self.text[start]);
        while (self.index < self.text.len and class(self.text[self.index]) == kind) self.index += 1;
        return self.text[start..self.index];
    }
};

fn prepareQuery(arena: Allocator, queries: []const []const u8) !Query {
    var terms: std.ArrayList([]const u8) = .empty;
    var phrases: std.ArrayList([]const usize) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var all_words: std.ArrayList([]const usize) = .empty;
    for (queries) |text| {
        var words: std.ArrayList(usize) = .empty;
        var tokens: Tokens = .{ .text = text };
        while (tokens.next()) |token| {
            const index = termIndex(terms.items, token) orelse blk: {
                if (terms.items.len == max_terms) continue;
                try terms.append(arena, try std.ascii.allocLowerString(arena, singular(token)));
                break :blk terms.items.len - 1;
            };
            try words.append(arena, index);
        }
        if (words.items.len > 1) try phrases.append(arena, words.items);
        if (words.items.len > 0 and texts.items.len < max_counted_queries) {
            try texts.append(arena, std.mem.trim(u8, text, " \t\r\n"));
            try all_words.append(arena, words.items);
        }
    }
    return .{ .terms = terms.items, .phrases = phrases.items, .texts = texts.items, .words = all_words.items };
}

fn termIndex(terms: []const []const u8, token: []const u8) ?usize {
    const word = singular(token);
    for (terms, 0..) |term, index| {
        if (term.len == word.len and std.ascii.eqlIgnoreCase(term, word)) return index;
    }
    return null;
}

/// A word without a plain plural `s`, so "sessions" matches "session". Short
/// words and words ending in "ss" stay as they are.
fn singular(word: []const u8) []const u8 {
    if (word.len <= 3) return word;
    const last = std.ascii.toLower(word[word.len - 1]);
    const before = std.ascii.toLower(word[word.len - 2]);
    return if (last == 's' and before != 's') word[0 .. word.len - 1] else word;
}

/// Counts query words in `text`, adding `weight` for each, and marks which
/// phrases appear in it. Returns the number of words in `text`.
fn countTerms(text: []const u8, query: Query, weight: u32, counts: []u32, phrase_hits: []bool) usize {
    var progress: [max_search_phrases]usize = @splat(0);
    var length: usize = 0;
    var tokens: Tokens = .{ .text = text };
    while (tokens.next()) |token| {
        length += 1;
        const term = termIndex(query.terms, token);
        if (term) |index| counts[index] += weight;
        for (query.phrases, 0..) |phrase, index| {
            const matched = &progress[index];
            if (term != null and phrase[matched.*] == term.?) {
                matched.* += 1;
                if (matched.* == phrase.len) {
                    phrase_hits[index] = true;
                    matched.* = 0;
                }
            } else {
                matched.* = @intFromBool(term != null and phrase[0] == term.?);
            }
        }
    }
    return length;
}

/// BM25 over all records, plus the weight of each phrase found whole.
/// Returns each query word's weight.
fn score(arena: Allocator, docs: []Doc, query: Query) ![]const f64 {
    if (docs.len == 0) return &.{};
    const terms = query.terms.len;
    const counts = try arena.alloc(u32, docs.len * terms);
    @memset(counts, 0);
    const hits = try arena.alloc(bool, docs.len * query.phrases.len);
    @memset(hits, false);
    var total_length: usize = 0;
    for (docs, 0..) |*doc, index| {
        const doc_counts = counts[index * terms ..][0..terms];
        const doc_hits = hits[index * query.phrases.len ..][0..query.phrases.len];
        doc.length = countTerms(doc.title, query, index_line_weight, doc_counts, doc_hits) +
            countTerms(doc.body, query, 1, doc_counts, doc_hits);
        total_length += doc.length;
    }

    const count: f64 = @floatFromInt(docs.len);
    const average: f64 = @max(1.0, @as(f64, @floatFromInt(total_length)) / count);
    const weights = try termWeights(arena, docs.len, counts, terms);
    const k1 = 1.2;
    const b = 0.75;
    for (docs, 0..) |*doc, index| {
        const doc_counts = counts[index * terms ..][0..terms];
        const length: f64 = @floatFromInt(doc.length);
        var total: f64 = 0;
        for (doc_counts, weights) |raw, weight| {
            if (raw == 0) continue;
            const frequency: f64 = @floatFromInt(raw);
            total += weight * frequency * (k1 + 1) / (frequency + k1 * (1 - b + b * length / average));
        }
        for (query.phrases, hits[index * query.phrases.len ..][0..query.phrases.len]) |phrase, hit| {
            if (hit) for (phrase) |term| {
                total += weights[term];
            };
        }
        doc.score = total;
        for (query.words, 0..) |words, query_index| {
            const all = for (words) |term| {
                if (doc_counts[term] == 0) break false;
            } else true;
            if (all) doc.complete |= @as(u32, 1) << @intCast(query_index);
        }
    }
    return weights;
}

/// How much each word counts: more the fewer records contain it.
fn termWeights(arena: Allocator, doc_count: usize, counts: []const u32, terms: usize) ![]f64 {
    const weights = try arena.alloc(f64, terms);
    const n: f64 = @floatFromInt(doc_count);
    for (weights, 0..) |*weight, term| {
        var containing: f64 = 0;
        for (0..doc_count) |doc| {
            if (counts[doc * terms + term] > 0) containing += 1;
        }
        weight.* = @log(1 + (n - containing + 0.5) / (containing + 0.5));
    }
    return weights;
}

/// The best `found` of `all`, which is sorted best first, after the coverage
/// of each query over all of them.
fn formatResults(alloc: Allocator, arena: Allocator, queries: []const []const u8, query: Query, weights: []const f64, all: []const Doc, found: usize) ![]u8 {
    const docs = all[0..found];
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("<saved_search query=");
    try std.json.Stringify.value(queries, .{}, writer);
    try writer.print(" matches=\"{d}\">\n", .{docs.len});
    if (docs.len == 0) try writer.writeAll("(no saved turns or tool calls match)\n") else try writeCoverage(writer, query, all);
    for (docs, 1..) |doc, rank| {
        try writer.print("\n[{d}] ", .{rank});
        if (doc.id != null) {
            try writer.writeAll(doc.title);
        } else {
            try writer.print("Earlier conversation archive {s}, bytes {d}–{d}", .{ doc.archive, doc.offset + 1, doc.offset + doc.body.len });
        }
        try writer.writeByte('\n');
        const shown = try excerpt(arena, doc.body, query, weights);
        if (shown.len < doc.body.len) {
            const start = doc.offset + (shown.ptr - doc.body.ptr);
            try writer.print("(bytes {d}–{d} of {d}; ", .{ start + 1, start + shown.len, doc.file_bytes });
            if (doc.id) |id| {
                try writer.print("open {c}{d} for all of it)\n", .{ id.kind.letter(), id.number });
            } else {
                try writer.writeAll("read more with its handle, start_byte and byte_count)\n");
            }
        }
        try writer.writeAll(std.mem.trimEnd(u8, shown, "\n"));
        try writer.writeByte('\n');
    }
    try writer.writeAll("</saved_search>\n");
    if (docs.len > 0) try writer.writeAll("Open a turn, tool call or earlier compaction by its ID (like M12, T12 or L2) with read_tool_result; read an archive by its handle with start_byte and byte_count.\n");
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const Hit = struct { at: usize, term: usize };

/// All of `body` when it is short. Otherwise the `shown_bytes` that hold the
/// most query words, weighted by rarity, wherever they are. Shell results are
/// one JSON line with their line breaks escaped, so each end moves to a nearby
/// newline or escaped `\n` when there is one. Never splits a UTF-8 character.
fn excerpt(arena: Allocator, body: []const u8, query: Query, weights: []const f64) ![]const u8 {
    if (body.len <= shown_bytes) return body;
    var hits: std.ArrayList(Hit) = .empty;
    var tokens: Tokens = .{ .text = body };
    while (tokens.next()) |token| {
        if (termIndex(query.terms, token)) |term| try hits.append(arena, .{ .at = token.ptr - body.ptr, .term = term });
    }
    if (hits.items.len == 0) return body[0..text_utils.utf8BackwardBoundary(body, shown_bytes)];

    // Slide over the hits, keeping room around the words for context.
    const span = shown_bytes * 3 / 4;
    var counts: [max_terms]u32 = @splat(0);
    var covered: f64 = 0;
    var best: f64 = -1;
    var best_first: usize = 0;
    var best_last: usize = 0;
    var end: usize = 0;
    for (hits.items, 0..) |hit, first| {
        while (end < hits.items.len and hits.items[end].at < hit.at + span) : (end += 1) {
            const term = hits.items[end].term;
            if (counts[term] == 0) covered += weights[term];
            counts[term] += 1;
        }
        if (covered > best) {
            best = covered;
            best_first = first;
            best_last = end - 1;
        }
        counts[hit.term] -= 1;
        if (counts[hit.term] == 0) covered -= weights[hit.term];
    }

    // Center the matching words, then move each end to a nearby line break.
    const words_start = hits.items[best_first].at;
    const words_end = hits.items[best_last].at;
    var to = @min(body.len, ((words_start + words_end) / 2 -| shown_bytes / 2) + shown_bytes);
    var from = to -| shown_bytes;
    const slack = shown_bytes / 4;
    if (from > 0) if (breakAfter(body[from..@min(words_start, from + slack)])) |offset| {
        from += offset;
    };
    const tail = @max(words_end, to -| slack);
    if (to < body.len and tail < to) if (breakBefore(body[tail..to])) |offset| {
        to = tail + offset;
    };
    while (from > 0 and from < body.len and body[from] & 0xc0 == 0x80) from += 1;
    while (to < body.len and to > from and body[to] & 0xc0 == 0x80) to -= 1;
    return body[from..to];
}

/// Offset just past the first line break in `text`.
fn breakAfter(text: []const u8) ?usize {
    for (text, 0..) |byte, index| {
        if (byte == '\n') return index + 1;
        if (byte == '\\' and index + 1 < text.len and text[index + 1] == 'n') return index + 2;
    }
    return null;
}

/// Offset just past the last line break in `text`.
fn breakBefore(text: []const u8) ?usize {
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (text[index] == '\n') return index + 1;
        if (index > 0 and text[index] == 'n' and text[index - 1] == '\\') return index + 1;
    }
    return null;
}

const testing = std.testing;

/// Files kept in memory, standing in for a session's folder in tests.
pub const MemoryStore = struct {
    alloc: Allocator,
    files: std.array_hash_map.String([]u8) = .empty,
    /// Every write fails, like a store that cannot be written.
    fail: bool = false,

    pub fn deinit(self: *MemoryStore) void {
        for (self.files.keys(), self.files.values()) |name, content| {
            self.alloc.free(name);
            self.alloc.free(content);
        }
        self.files.deinit(self.alloc);
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .context = self, .vtable = &.{ .write = write, .list = list, .read = read } };
    }

    /// The saved record `number` of `kind`, or null.
    pub fn find(self: *const MemoryStore, kind: Kind, number: usize) ?[]const u8 {
        var buffer: [max_file_name_bytes]u8 = undefined;
        return self.files.get(fileName(&buffer, .{ .kind = kind, .number = number }));
    }

    fn write(context: *anyopaque, _: Allocator, name: []const u8, content: []const u8) Store.Error!void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        if (self.fail) return error.StoreFailed;
        const copy = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(copy);
        const entry = try self.files.getOrPut(self.alloc, name);
        if (entry.found_existing) {
            self.alloc.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = self.alloc.dupe(u8, name) catch |err| {
                _ = self.files.orderedRemove(name);
                return err;
            };
        }
        entry.value_ptr.* = copy;
    }

    fn list(context: *anyopaque, arena: Allocator) Store.Error![]const []const u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return arena.dupe([]const u8, self.files.keys());
    }

    fn read(context: *anyopaque, arena: Allocator, name: []const u8, max_bytes: usize) Store.Error![]const u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        const content = self.files.get(name) orelse return error.FileNotFound;
        return arena.dupe(u8, content[0..@min(content.len, max_bytes)]);
    }
};

test "a file is read back only when it has exactly the expected size" {
    var memory: MemoryStore = .{ .alloc = testing.allocator };
    defer memory.deinit();
    const store = memory.store();
    try store.write(testing.allocator, "result-state.txt", "twelve bytes");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("twelve bytes", (try readExact(arena, store, "result-state.txt", 12)).?);
    try testing.expect(try readExact(arena, store, "result-state.txt", 11) == null);
    try testing.expect(try readExact(arena, store, "result-state.txt", 13) == null);
    try testing.expect(try readExact(arena, store, "result-missing.txt", 12) == null);
    try testing.expect(try readExact(arena, store, "result-state.txt", max_file_bytes + 1) == null);
}

test "IDs map to one file name each" {
    var buffer: [max_file_name_bytes]u8 = undefined;
    try testing.expectEqualStrings("compacted-T12.txt", fileName(&buffer, .{ .kind = .tool, .number = 12 }));
    try testing.expectEqualStrings("compacted-M3.txt", fileName(&buffer, .{ .kind = .turn, .number = 3 }));
    try testing.expectEqual(Id{ .kind = .tool, .number = 12 }, parseId("t12").?);
    try testing.expectEqual(Id{ .kind = .turn, .number = 12 }, parseId("M12").?);
    try testing.expectEqual(Id{ .kind = .turn, .number = 12 }, parseFileName("compacted-M12.txt").?);
    try testing.expectEqualStrings("compacted-L2.txt", fileName(&buffer, .{ .kind = .ledger, .number = 2 }));
    try testing.expectEqual(Id{ .kind = .ledger, .number = 2 }, parseId("l2").?);
    for ([_][]const u8{ "T", "T0", "12", "T1x", "T-1", "../T1", "X1", "M", "L0" }) |bad| {
        try testing.expect(parseId(bad) == null);
    }
    try testing.expect(parseFileName("compacted-T0.txt") == null);
    try testing.expect(parseFileName("compacted-t1.txt") == null);
    try testing.expect(parseFileName("result-shell-1.txt") == null);
}

test "words match in any form and order, and rare words count more" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();

    try save(alloc, store, .{ .kind = .turn, .number = 21 }, "M21 turn: okay so you saying that if 2 GB exeeds then what happens ?\nUser 21:\nokay so you saying that if 2 GB exeeds then what happens ?\n\nAssistant, final reply:\nNothing happens: 2GB is not a limit in the disk-reserve design.\n");
    try save(alloc, store, .{ .kind = .tool, .number = 7 }, "T7 shell: ls\nResult:\nthe limit is the limit is the limit\n");
    try save(alloc, store, .{ .kind = .tool, .number = 8 }, "T8 shell: du -sh\nResult:\nunrelated output\n");
    try store.write(alloc, "result-shell-aaaa-bbbb.txt", "2 GB limit");

    const found = try search(alloc, store, &.{"2gb limit"}, 5);
    defer alloc.free(found);
    try testing.expect(std.mem.find(u8, found, "matches=\"2\"") != null);
    // The turn has every word; the tool only repeats the common one.
    const turn = std.mem.find(u8, found, "[1] M21 turn:").?;
    try testing.expect(turn < std.mem.find(u8, found, "[2] T7 shell").?);
    // Short records are shown whole.
    try testing.expect(std.mem.find(u8, found, "Nothing happens: 2GB is not a limit in the disk-reserve design.") != null);
    try testing.expect(std.mem.find(u8, found, "result-shell") == null);

    // Singular and plural are the same word.
    const plural = try search(alloc, store, &.{"limits"}, 5);
    defer alloc.free(plural);
    try testing.expect(std.mem.find(u8, plural, "matches=\"2\"") != null);
    try testing.expectEqualStrings("session", singular("sessions"));
    try testing.expectEqualStrings("process", singular("process"));
    try testing.expectEqualStrings("gbs", singular("gbs"));

    const none = try search(alloc, store, &.{"zebra quantum"}, 5);
    defer alloc.free(none);
    try testing.expect(std.mem.find(u8, none, "(no saved turns or tool calls match)") != null);
    try testing.expectError(error.EmptySearch, search(alloc, store, &.{ " ", "" }, 5));
}

test "a phrase found whole outranks its words found apart, and index lines count more" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();
    try save(alloc, store, .{ .kind = .tool, .number = 1 }, "T1 read_file: notes.md\nResult:\nrecovery comes first; the session list is second\n");
    try save(alloc, store, .{ .kind = .tool, .number = 2 }, "T2 read_file: plan.md\nResult:\nwe fixed session recovery today\n");
    try save(alloc, store, .{ .kind = .tool, .number = 3 }, "T3 shell: bun test session-recovery.test.ts\nResult:\nok\n");
    try save(alloc, store, .{ .kind = .tool, .number = 4 }, "T4 shell: ls\nResult:\nnothing\n");

    const found = try search(alloc, store, &.{"session recovery"}, 5);
    defer alloc.free(found);
    try testing.expect(std.mem.find(u8, found, "[1] T3 shell").? < std.mem.find(u8, found, "[2] T2 read_file").?);
    try testing.expect(std.mem.find(u8, found, "[2] T2 read_file").? < std.mem.find(u8, found, "[3] T1 read_file").?);
    try testing.expect(std.mem.find(u8, found, "T4 shell") == null);
}

test "each search says which records hold all its words, first and last, beyond the results shown" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();
    try save(alloc, store, .{ .kind = .tool, .number = 1 }, "T1 shell: zig build test\nResult:\n8199/8199 tests passed\n");
    try save(alloc, store, .{ .kind = .tool, .number = 2 }, "T2 shell: zig build test\nResult:\n8195/8199 tests passed (2 failed)\n");
    try save(alloc, store, .{ .kind = .tool, .number = 3 }, "T3 shell: zig build test\nResult:\n8202/8206 tests passed (2 failed)\n");
    try save(alloc, store, .{ .kind = .tool, .number = 5 }, "T5 shell: zig build test\nResult:\ntests failed, tests failed, tests failed\n");
    try save(alloc, store, .{ .kind = .turn, .number = 1 }, "M1 turn: fix it\nUser 1:\nfix it\n\nAssistant, final reply:\nThe tests failed twice.\n");

    // The best match is the latest look-alike; the first one is still named.
    const found = try search(alloc, store, &.{ "tests failed", "zebra" }, 1);
    defer alloc.free(found);
    try testing.expect(std.mem.find(u8, found, "[1] T5 shell") != null);
    try testing.expect(std.mem.find(u8, found, "[2]") == null);
    try testing.expect(std.mem.find(u8, found, "Every word of \"tests failed\" is in 1 turn (M1), 3 tool calls (first T2, last T5).\n") != null);
    try testing.expect(std.mem.find(u8, found, "Every word of \"zebra\" is in no saved record.\n") != null);
    try testing.expect(std.mem.find(u8, found, "IDs count up in time order: a lower number came earlier.\n") != null);
    // The coverage comes before the results.
    try testing.expect(std.mem.find(u8, found, "Every word of").? < std.mem.find(u8, found, "[1] T5").?);

    const none = try search(alloc, store, &.{"zebra"}, 5);
    defer alloc.free(none);
    try testing.expect(std.mem.find(u8, none, "Every word of") == null);
    try testing.expect(std.mem.find(u8, none, "IDs count up") == null);
}

test "long records show the lines that match best" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "T5 shell: cat big.log\nResult:\n");
    for (0..400) |line| try content.print(alloc, "line {d} filler text\n", .{line});
    try content.appendSlice(alloc, "the checksum mismatch is in chunk 7\n");
    for (400..800) |line| try content.print(alloc, "line {d} filler text\n", .{line});
    try save(alloc, store, .{ .kind = .tool, .number = 5 }, content.items);

    const found = try search(alloc, store, &.{"checksum mismatch"}, 5);
    defer alloc.free(found);
    try testing.expect(std.mem.find(u8, found, "the checksum mismatch is in chunk 7") != null);
    try testing.expect(std.mem.find(u8, found, "; open T5 for all of it)") != null);
    try testing.expect(std.mem.find(u8, found, "line 399 filler text") != null);
    try testing.expect(std.mem.find(u8, found, "line 0 filler text") == null);
    try testing.expect(found.len < shown_bytes + 1000);
}

test "earlier conversation archives are searched one message at a time" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();

    try save(alloc, store, .{ .kind = .tool, .number = 1 }, "T1 shell: du -sh sessions\nResult:\n2 GB used on disk\n");
    const archive_text = "## Purpose\nold archive\n### Original user\nwhat should we cap?\n### Original assistant\nMaybe 64 MB per command.\n" ++
        "### Original user\nokay so you saying that if 2 GB exeeds then what happens ?\n" ++
        "### Original assistant\nNothing special happens at 2 GB. In the disk-reserve design, 2 GB is not a limit.\n" ++
        "### Tool call (not a completion result): name=shell; id=c1; argument_excerpt=df -h\n" ++
        "### Tool result shell id=c1 status=success\nFilesystem 2 GB free\n";
    try store.write(alloc, "result-source-aaaa-bbbb.txt", archive_text);

    const found = try search(alloc, store, &.{"2 GB is not a limit"}, 5);
    defer alloc.free(found);
    // The reply is one record with the tool call it made; the tool result is
    // another.
    const start = std.mem.find(u8, archive_text, "### Original assistant\nNothing").?;
    const end = std.mem.find(u8, archive_text, "### Tool result").?;
    const expected = try alloc.print("[1] Earlier conversation archive result-source-aaaa-bbbb.txt, bytes {d}–{d}\n### Original assistant\nNothing special happens at 2 GB.", .{ start + 1, end });
    defer alloc.free(expected);
    try testing.expect(std.mem.find(u8, found, expected) != null);
    try testing.expect(std.mem.find(u8, found, "argument_excerpt=df -h") != null);
    // Only matching parts are shown, not the rest of the archive.
    try testing.expect(std.mem.find(u8, found, "64 MB") == null);

    // The archive's name is not searched.
    const by_name = try search(alloc, store, &.{"aaaa"}, 5);
    defer alloc.free(by_name);
    try testing.expect(std.mem.find(u8, by_name, "matches=\"0\"") != null);
}

test "conversation outranks tool output, and both a saved ledger, on equal scores" {
    var docs = [_]Doc{
        .{ .id = .{ .kind = .ledger, .number = 1 }, .title = "", .body = "", .offset = 0, .file_bytes = 0, .score = 1 },
        .{ .id = .{ .kind = .tool, .number = 9 }, .title = "", .body = "", .offset = 0, .file_bytes = 0, .score = 1 },
        .{ .id = .{ .kind = .turn, .number = 2 }, .title = "", .body = "", .offset = 0, .file_bytes = 0, .score = 1 },
        .{ .id = .{ .kind = .tool, .number = 10 }, .title = "", .body = "", .offset = 0, .file_bytes = 0, .score = 1 },
    };
    std.mem.sort(Doc, &docs, {}, Doc.better);
    try testing.expectEqual(Kind.turn, docs[0].id.?.kind);
    try testing.expectEqual(@as(usize, 10), docs[1].id.?.number);
    try testing.expectEqual(Kind.ledger, docs[3].id.?.kind);
}

test "excerpts of one long line never split a UTF-8 character" {
    const line = text_utils.repeat("é", 2000) ++ " needle " ++ text_utils.repeat("ü", 2000);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const query = try prepareQuery(arena, &.{"needle"});
    const shown = try excerpt(arena, line, query, &.{1});
    try testing.expect(shown.len <= shown_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(shown));
    try testing.expect(std.mem.find(u8, shown, "needle") != null);
}

test "long shell results show the matching part of their one JSON line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = "{\"session_id\":null,\"output_delta\":\"" ++ text_utils.repeat("noise row here\\n", 400) ++ "total sessions: 11,355\\n" ++ text_utils.repeat("more noise\\n", 400) ++ "\"}";
    const query = try prepareQuery(arena, &.{"total sessions"});
    // A word right after an escaped newline is still that word.
    var counts: [max_terms]u32 = @splat(0);
    var phrase_hits: [max_search_phrases]bool = @splat(false);
    _ = countTerms(body, query, 1, counts[0..query.terms.len], phrase_hits[0..query.phrases.len]);
    try testing.expectEqual(@as(u32, 1), counts[0]);
    try testing.expect(phrase_hits[0]);

    const shown = try excerpt(arena, body, query, &.{ 1, 1 });
    try testing.expect(shown.len <= shown_bytes);
    try testing.expect(std.mem.find(u8, shown, "total sessions: 11,355") != null);
    try testing.expect(std.mem.find(u8, shown, "session_id") == null);
    // Both ends fall on escaped line breaks.
    try testing.expect(std.mem.startsWith(u8, shown, "noise row here\\n"));
    try testing.expect(std.mem.endsWith(u8, shown, "more noise\\n"));
}

test "a session with no saved records finds nothing" {
    const alloc = testing.allocator;
    var memory: MemoryStore = .{ .alloc = alloc };
    defer memory.deinit();
    const store = memory.store();
    const found = try search(alloc, store, &.{"anything"}, 5);
    defer alloc.free(found);
    try testing.expect(std.mem.find(u8, found, "matches=\"0\"") != null);
}
