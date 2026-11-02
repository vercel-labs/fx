//! The linter for what the model writes at compaction: the notes on each
//! turn and tool call, and the session's rules, facts, decisions and status.
//! Code checks every one against the saved turns and tool calls, without a
//! model:
//! - an entry names where it comes from, and every turn and tool call a note
//!   or entry names exists;
//! - the exact values it states, like paths, file names, `code`, versions and
//!   long numbers, appear in the turns and tool calls it is about, when this
//!   compaction has them, or in the conversation that stays after them;
//! - what an entry replaces is an earlier entry;
//! - a rule quotes the user word for word, from a message or an answer to a
//!   question;
//! - a note, or an entry about one tool call, does not call a failed tool
//!   call a success.
//! What fails a check stays, marked `[check: ...]`, so the agent confirms it
//! before relying on it. Nothing is dropped or rewritten.

const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const ledger = @import("ledger.zig");

const Allocator = std.mem.Allocator;

/// One saved turn or tool call, word for word.
pub const Record = struct {
    number: usize,
    text: []const u8,
    /// A turn's tool calls are T<first_tool> through T<last_tool>.
    first_tool: usize = 0,
    last_tool: usize = 0,
    /// A tool call that reported failure or a nonzero exit code.
    failed: bool = false,
};

pub const Sources = struct {
    /// Turns and tool calls exist through these numbers, earlier ones too.
    turn_count: usize,
    tool_count: usize,
    /// This compaction's turns, numbered in order, the turn in progress as
    /// zero, and its tool calls in order. Values are looked for in them.
    turns: []const Record,
    tools: []const Record,
    /// Every user message, and every answer the user gave a question, that a
    /// rule may quote.
    users: []const []const u8,
    /// The texts that stay in the conversation after this compaction's turns.
    /// Values are looked for in them too, but nothing can cite them.
    kept: []const []const u8 = &.{},
    /// The highest number of each kind of entry before this compaction's,
    /// counting entries only a saved ledger holds, so replacing one of them
    /// is allowed.
    highest: [checkpoint.entry_kinds.len]usize = @splat(0),
};

/// What the checks found, for the trace.
pub const Counts = struct {
    marked: usize = 0,
    no_source: usize = 0,
    missing_ids: usize = 0,
    unfound_values: usize = 0,
    bad_replaces: usize = 0,
    unquoted: usize = 0,
    failed_as_success: usize = 0,
};

/// Values past this many in one note or entry are not looked for.
const max_values = 16;

/// `written` with every note and entry that fails a check marked. `earlier`
/// are the entries of previous compactions. `arena` owns the result.
pub fn check(arena: Allocator, written: ledger.Written, earlier: []const checkpoint.Entry, sources: Sources, counts: *Counts) Allocator.Error!ledger.Written {
    var users: std.ArrayList([]const u8) = .empty;
    for (sources.users) |user| try users.append(arena, try normalized(arena, user));
    // A value found anywhere in this compaction, or in what stays after it,
    // is taken as true, even when the note names another turn or tool call
    // for it.
    var everything: std.ArrayList([]const u8) = .empty;
    for (sources.turns) |record| try everything.append(arena, record.text);
    for (sources.tools) |record| try everything.append(arena, record.text);
    try everything.appendSlice(arena, sources.users);
    try everything.appendSlice(arena, sources.kept);
    const all = everything.items;
    var result = written;

    // Notes are about this compaction's own turns and tool calls.
    const works = try arena.alloc(ledger.Note, written.works.len);
    for (works, written.works) |*slot, note| {
        var problems: Problems = .{};
        try checkCitations(arena, &problems, note.text, sources, counts);
        try checkValues(arena, &problems, note.text, all, counts);
        slot.* = .{ .number = note.number, .text = try problems.mark(arena, note.text, counts) };
    }
    result.works = works;

    const tools = try arena.alloc(ledger.Note, written.tools.len);
    for (tools, written.tools) |*slot, note| {
        var problems: Problems = .{};
        try checkCitations(arena, &problems, note.text, sources, counts);
        try checkValues(arena, &problems, note.text, all, counts);
        // A note shared by a run of calls starts with the run, like `T3–T8:`,
        // and may speak of calls that worked and calls that failed.
        const cited = try citations(arena, note.text);
        const shared = cited.len > 0 and cited[0].first == note.number and cited[0].last > note.number;
        if (!shared) try checkFailedCall(arena, &problems, note.text, note.number, sources.tools, counts);
        slot.* = .{ .number = note.number, .text = try problems.mark(arena, note.text, counts) };
    }
    result.tools = tools;

    const entries = try arena.alloc(checkpoint.Entry, written.entries.len);
    for (entries, written.entries, 0..) |*slot, entry, index| {
        var problems: Problems = .{};
        const cited = try citations(arena, entry.text);
        // Every entry says where it comes from, as the request asks. The
        // turn in progress has no ID yet.
        const sourced = cited.len > 0 or std.ascii.findIgnoreCase(entry.text, "turn in progress") != null;
        if (!sourced) {
            counts.no_source += 1;
            try problems.add(arena, "no source", .{});
        }
        try checkCitations(arena, &problems, entry.text, sources, counts);
        // An entry about one tool call states its result, like a note on it.
        if (entry.id[0] != 'R') if (onlyTool(cited)) |number| try checkFailedCall(arena, &problems, entry.text, number, sources.tools, counts);
        if (entry.id[0] == 'R') {
            try checkQuote(arena, &problems, entry.text, users.items, counts);
        } else if (namesThisCompaction(cited, sources)) {
            // An entry only about earlier compactions' turns cannot be
            // checked against this one's.
            try checkValues(arena, &problems, entry.text, all, counts);
        }
        for (try checkpoint.replacedIds(arena, entry.text)) |id| {
            const exists = hasEntry(earlier, id) or hasEntry(written.entries[0..index], id) or checkpoint.wasUsed(id, sources.highest);
            if (!exists) {
                counts.bad_replaces += 1;
                try problems.add(arena, "replaces {s}, which does not exist", .{id});
            }
        }
        slot.* = .{ .id = entry.id, .text = try problems.mark(arena, entry.text, counts) };
    }
    result.entries = entries;
    return result;
}

const Problems = struct {
    text: std.ArrayList(u8) = .empty,

    fn add(self: *Problems, arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (self.text.items.len > 0) try self.text.appendSlice(arena, "; ");
        try self.text.print(arena, fmt, args);
    }

    fn mark(self: Problems, arena: Allocator, text: []const u8, counts: *Counts) Allocator.Error![]const u8 {
        if (self.text.items.len == 0) return text;
        counts.marked += 1;
        return std.mem.concat(arena, u8, &.{ text, checkpoint.check_mark, self.text.items, "]" });
    }
};

fn hasEntry(entries: []const checkpoint.Entry, id: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

/// A turn (`M`) or tool call (`T`) a text names, or a run of them like
/// `T3–T8`.
const Citation = struct { kind: u8, first: usize, last: usize };

/// Every turn and tool call `text` names, in order.
fn citations(arena: Allocator, text: []const u8) Allocator.Error![]const Citation {
    var out: std.ArrayList(Citation) = .empty;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        // Without saved records a turn is named like `turn 3`.
        const turn_word = "turn ";
        if ((at == 0 or !isWordByte(text[at - 1])) and std.ascii.startsWithIgnoreCase(text[at..], turn_word)) {
            var end = at + turn_word.len;
            if (readNumber(text, &end)) |number| if (end >= text.len or !isWordByte(text[end])) {
                try out.append(arena, .{ .kind = 'M', .first = number, .last = number });
                at = end - 1;
                continue;
            };
        }
        const kind = text[at];
        if ((kind != 'M' and kind != 'T') or (at > 0 and isWordByte(text[at - 1]))) continue;
        var end = at + 1;
        const first = readNumber(text, &end) orelse continue;
        if (end < text.len and isWordByte(text[end])) continue;
        var last = first;
        // A run: `T3–T8`, `T3-T8` or `T3 to T8`.
        for ([_][]const u8{ "\u{2013}", "-", " to " }) |dash| {
            if (!std.mem.startsWith(u8, text[end..], dash)) continue;
            var range_end = end + dash.len;
            if (range_end < text.len and text[range_end] == kind) range_end += 1;
            const upper = readNumber(text, &range_end) orelse break;
            if (upper > first and (range_end >= text.len or !isWordByte(text[range_end]))) {
                last = upper;
                end = range_end;
            }
            break;
        }
        try out.append(arena, .{ .kind = kind, .first = first, .last = last });
        at = end - 1;
    }
    return out.items;
}

/// The number at `at.*`, moving past its digits.
fn readNumber(text: []const u8, at: *usize) ?usize {
    const start = at.*;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == start) return null;
    const value = std.fmt.parseUnsigned(usize, text[start..end], 10) catch return null;
    at.* = end;
    return value;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Every turn and tool call `text` names exists.
fn checkCitations(arena: Allocator, problems: *Problems, text: []const u8, sources: Sources, counts: *Counts) Allocator.Error!void {
    for (try citations(arena, text)) |citation| {
        const count = if (citation.kind == 'M') sources.turn_count else sources.tool_count;
        if (citation.first == 0 or citation.last > count) {
            counts.missing_ids += 1;
            try problems.add(arena, "{c}{d} does not exist", .{ citation.kind, if (citation.first == 0) 0 else citation.last });
        }
    }
}

/// One of `cited` is a turn or tool call of this compaction.
fn namesThisCompaction(cited: []const Citation, sources: Sources) bool {
    for (cited) |citation| {
        const records = if (citation.kind == 'M') sources.turns else sources.tools;
        if (findRecord(records, citation.first) != null or findRecord(records, citation.last) != null) return true;
    }
    return false;
}

/// The record numbered `wanted`; records are in number order.
fn findRecord(records: []const Record, wanted: usize) ?Record {
    var low: usize = 0;
    var high: usize = records.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (records[middle].number == wanted) return records[middle];
        if (records[middle].number < wanted) low = middle + 1 else high = middle;
    }
    return null;
}

/// The exact values of `text` appear somewhere in `all`, this compaction's
/// turns, tool calls and user messages. A value named under the wrong turn
/// or tool call passes; one found nowhere is what the model made up.
fn checkValues(arena: Allocator, problems: *Problems, text: []const u8, all: []const []const u8, counts: *Counts) Allocator.Error!void {
    var missing: std.ArrayList(u8) = .empty;
    for (try values(arena, text)) |value| {
        if (try foundIn(arena, value, all)) continue;
        // Code in backticks is often written with other spacing or
        // punctuation; it counts when every name in it is found.
        const code = std.mem.find(u8, text, try std.mem.concat(arena, u8, &.{ "`", value, "`" })) != null;
        if (code and namesFound(value, all)) continue;
        counts.unfound_values += 1;
        if (missing.items.len > 0) try missing.appendSlice(arena, ", ");
        try missing.appendSlice(arena, value);
    }
    if (missing.items.len > 0) try problems.add(arena, "not in the saved turns or tool calls: {s}", .{missing.items});
}

/// The exact values `text` states that code can look for: spans in
/// backticks or double quotes; paths; file names; versions and decimals;
/// and numbers of three or more digits. Turn and tool call IDs are not
/// values.
fn values(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try spans(arena, &out, text, "`", "`", " ");
    try spans(arena, &out, text, "\"", "\"", closing_punctuation);
    try spans(arena, &out, text, "\u{201c}", "\u{201d}", closing_punctuation);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |raw| {
        if (out.items.len >= max_values) break;
        const word = trimmedWord(raw);
        if (word.len < 3 or !exactLooking(word) or containsValue(out.items, word)) continue;
        try out.append(arena, word);
    }
    return out.items;
}

/// Spaces, and the punctuation English puts inside closing quote marks, as
/// in `“smaller documented limits,”`, which the quoted text need not have.
const closing_punctuation = " ,.;:!?";

/// Appends each span between `open` and `close`, without spaces at its
/// start or any of `end_trim` at its end.
fn spans(arena: Allocator, out: *std.ArrayList([]const u8), text: []const u8, open: []const u8, close: []const u8, end_trim: []const u8) Allocator.Error!void {
    var at: usize = 0;
    while (out.items.len < max_values) {
        const start = (std.mem.findPos(u8, text, at, open) orelse return) + open.len;
        const stop = std.mem.findPos(u8, text, start, close) orelse return;
        at = stop + close.len;
        const inner = std.mem.trimEnd(u8, std.mem.trimStart(u8, text[start..stop], " "), end_trim);
        if (inner.len >= 2 and inner.len <= 200 and !containsValue(out.items, inner)) try out.append(arena, inner);
    }
}

fn containsValue(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

/// `word` without the punctuation and quote marks around it.
fn trimmedWord(word: []const u8) []const u8 {
    const marks = [_][]const u8{ "\u{201c}", "\u{201d}", "\u{2018}", "\u{2019}", "\u{2026}" };
    var rest = word;
    while (true) {
        const before = rest.len;
        rest = std.mem.trim(u8, rest, ".,;:!?()[]{}<>\"'`*");
        for (marks) |mark| {
            if (std.mem.startsWith(u8, rest, mark)) rest = rest[mark.len..];
            if (std.mem.endsWith(u8, rest, mark)) rest = rest[0 .. rest.len - mark.len];
        }
        if (rest.len == before) return rest;
    }
}

/// A path, a file name, a version or decimal, or a number of three or more
/// digits: words whose exact form matters. IDs are not one, even joined
/// like `T47,T60` or `M9/T254`.
fn exactLooking(word: []const u8) bool {
    if (isIdList(word)) return false;
    var run: usize = 0;
    var longest_run: usize = 0;
    var dotted_digits = false;
    for (word, 0..) |byte, index| {
        if (std.ascii.isDigit(byte)) {
            run += 1;
            longest_run = @max(longest_run, run);
        } else run = 0;
        if (byte == '.' and index > 0 and index + 1 < word.len and std.ascii.isDigit(word[index - 1]) and std.ascii.isDigit(word[index + 1])) dotted_digits = true;
    }
    if (longest_run >= 3 or dotted_digits) return true;
    if (word[0] == '/' or word[0] == '~' or std.mem.startsWith(u8, word, "./") or std.mem.find(u8, word, "://") != null) return true;
    // A file name, maybe with folders and a line number: a name, a dot, and
    // an extension of two to six letters or digits. A list like
    // `search/edit/read` is not a path.
    const name = fileName(word);
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return false;
    const extension = name[dot + 1 ..];
    if (dot == 0 or extension.len < 2 or extension.len > 6) return false;
    for (extension) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return std.ascii.isAlphanumeric(name[0]) or name[0] == '_';
}

/// The file name of a path like `src/a.zig:4`: after its last slash and
/// before any line number.
fn fileName(path: []const u8) []const u8 {
    var name = path[if (std.mem.findScalarLast(u8, path, '/')) |slash| slash + 1 else 0..];
    if (std.mem.findScalar(u8, name, ':')) |colon| name = name[0..colon];
    return name;
}

/// One or more IDs joined by commas or slashes without spaces.
fn isIdList(word: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, word, ",/");
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (!isId(part)) return false;
    }
    return count > 0;
}

/// A turn, tool call or entry ID like `T12`, or a run like `T3–T9`.
fn isId(word: []const u8) bool {
    if (word.len < 2 or std.mem.findScalar(u8, "MT" ++ checkpoint.entry_kinds, word[0]) == null or !std.ascii.isDigit(word[1])) return false;
    var at: usize = 1;
    while (at < word.len and std.ascii.isDigit(word[at])) at += 1;
    if (at == word.len) return true;
    const rest = word[at..];
    const dash: usize = if (std.mem.startsWith(u8, rest, "\u{2013}")) 3 else if (rest[0] == '-') 1 else return false;
    var upper = rest[dash..];
    if (upper.len > 0 and upper[0] == word[0]) upper = upper[1..];
    if (upper.len == 0) return false;
    for (upper) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// `value` appears in one of `texts`, ignoring case. A path also counts
/// when its last two parts do, since the folders before them and line
/// numbers are often written differently, and a number with more around
/// it, like `12.3s` or `~141`, when its number does.
fn foundIn(arena: Allocator, value: []const u8, texts: []const []const u8) Allocator.Error!bool {
    if (anyHas(texts, value)) return true;
    const path = std.mem.findScalar(u8, value, ' ') == null and
        (std.mem.findScalar(u8, value, '/') != null or std.mem.findScalar(u8, fileName(value), '.') != null);
    if (path) {
        const tail = pathTail(value);
        if (tail.len >= 4 and tail.len < value.len and anyHas(texts, tail)) return true;
    }
    const numeric = try numericPart(arena, value) orelse return false;
    return numeric.len >= 3 and !std.mem.eql(u8, numeric, value) and anyHas(texts, numeric);
}

/// The last two parts of a path, without a line number, like `core/app.zig`
/// for `/repo/src/core/app.zig:12`.
fn pathTail(path: []const u8) []const u8 {
    const name_start = if (std.mem.findScalarLast(u8, path, '/')) |slash| slash + 1 else 0;
    const end = std.mem.findScalarPos(u8, path, name_start, ':') orelse path.len;
    const trimmed = path[0..end];
    const last = std.mem.findScalarLast(u8, trimmed, '/') orelse return trimmed;
    const before = std.mem.findScalarLast(u8, trimmed[0..last], '/') orelse return trimmed;
    return trimmed[before + 1 ..];
}

/// Every name of three or more letters, digits or underscores in `code`
/// appears in one of `texts`, and there is at least one.
fn namesFound(code: []const u8, texts: []const []const u8) bool {
    var names: usize = 0;
    var start: usize = 0;
    for (code, 0..) |byte, index| {
        if (isWordByte(byte)) {
            if (index + 1 < code.len and isWordByte(code[index + 1])) continue;
            const name = code[start .. index + 1];
            start = index + 1;
            if (name.len < 3) continue;
            if (!anyHas(texts, name)) return false;
            names += 1;
        } else start = index + 1;
    }
    return names > 0;
}

fn anyHas(texts: []const []const u8, value: []const u8) bool {
    for (texts) |text| if (std.ascii.findIgnoreCase(text, value) != null) return true;
    return false;
}

/// The first number in `value`, with thousands separators dropped.
fn numericPart(arena: Allocator, value: []const u8) Allocator.Error!?[]const u8 {
    const start = for (value, 0..) |byte, index| {
        if (std.ascii.isDigit(byte)) break index;
    } else return null;
    var out: std.ArrayList(u8) = .empty;
    for (value[start..]) |byte| {
        if (std.ascii.isDigit(byte) or byte == '.') {
            try out.append(arena, byte);
        } else if (byte != ',') break;
    }
    return std.mem.trimEnd(u8, out.items, ".");
}

const success_words = [_][]const u8{ "pass", "passed", "passes", "passing", "succeeded", "success", "successful", "successfully", "works", "worked", "green" };
const failure_words = [_][]const u8{ "fail", "failed", "fails", "failing", "failure", "error", "errors", "broke", "broken", "crash", "crashed", "not", "no", "timeout", "rejected", "denied", "missing", "exit", "nonzero" };

/// Marks `text` about tool call `number` when the call failed and the text
/// calls it a success.
fn checkFailedCall(arena: Allocator, problems: *Problems, text: []const u8, number: usize, tools: []const Record, counts: *Counts) Allocator.Error!void {
    const record = findRecord(tools, number) orelse return;
    if (!record.failed or !callsSuccess(text)) return;
    counts.failed_as_success += 1;
    try problems.add(arena, "T{d} failed", .{number});
}

/// The tool call `cited` names, when it names exactly one and not a run.
fn onlyTool(cited: []const Citation) ?usize {
    var found: ?usize = null;
    for (cited) |citation| {
        if (citation.kind != 'T') continue;
        if (found != null or citation.last != citation.first) return null;
        found = citation.first;
    }
    return found;
}

/// `note` says a call worked and says nothing of it failing.
fn callsSuccess(note: []const u8) bool {
    var saw_success = false;
    var words = std.mem.tokenizeAny(u8, note, " \t\r\n.,;:!?()[]\"'`-");
    while (words.next()) |word| {
        for (failure_words) |failure| if (std.ascii.eqlIgnoreCase(word, failure)) return false;
        for (success_words) |success| if (std.ascii.eqlIgnoreCase(word, success)) {
            saw_success = true;
        };
    }
    return saw_success;
}

/// A rule quotes the user: at least one quoted phrase, every one found in
/// the user's messages, ignoring case, runs of whitespace and punctuation
/// closing the quote.
fn checkQuote(arena: Allocator, problems: *Problems, rule: []const u8, users: []const []const u8, counts: *Counts) Allocator.Error!void {
    var at: usize = 0;
    var quotes: usize = 0;
    while (quote(rule, at)) |found| {
        at = found.end;
        const phrase = try normalized(arena, std.mem.trimEnd(u8, found.text, closing_punctuation));
        if (phrase.len == 0) continue;
        quotes += 1;
        const present = for (users) |user| {
            if (std.mem.find(u8, user, phrase) != null) break true;
        } else false;
        if (!present) {
            counts.unquoted += 1;
            return problems.add(arena, "not the user's exact words", .{});
        }
    }
    if (quotes == 0) {
        counts.unquoted += 1;
        try problems.add(arena, "no quote of the user's words", .{});
    }
}

const Quote = struct { text: []const u8, end: usize };

fn quote(text: []const u8, from: usize) ?Quote {
    const opens = [_][]const u8{ "\"", "\u{201c}" };
    const closes = [_][]const u8{ "\"", "\u{201d}" };
    var best: ?Quote = null;
    var best_start: usize = text.len;
    for (opens, closes) |open, close| {
        const start = std.mem.findPos(u8, text, from, open) orelse continue;
        if (start >= best_start) continue;
        const inner = start + open.len;
        const stop = std.mem.findPos(u8, text, inner, close) orelse continue;
        best_start = start;
        best = .{ .text = text[inner..stop], .end = stop + close.len };
    }
    return best;
}

/// `text` in lowercase with every run of whitespace as one space, trimmed.
fn normalized(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
        } else {
            try out.append(arena, std.ascii.toLower(byte));
        }
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

const testing = std.testing;

const test_tools = [_]Record{
    .{ .number = 7, .text = "T7 shell: zig build test\nResult:\n{\"exit_code\":1,\"output\":\"2 of 141 tests failed in src/core/app.zig\"}", .failed = true },
    .{ .number = 8, .text = "T8 read_file: src/core/app.zig\nResult:\nconst max_bytes = 16_384;\nfn resumeForWrite() void {}" },
    .{ .number = 9, .text = "T9 shell: git log\nResult:\ncommit 707afac508e1 bumped libfx to 0.0.10" },
};
const test_turns = [_]Record{.{ .number = 4, .text = "M4 turn: fix the tests\nUser 4:\nNever push to main. Keep the fix small.\n", .first_tool = 7, .last_tool = 9 }};
const test_sources: Sources = .{
    .turn_count = 4,
    .tool_count = 9,
    .turns = &test_turns,
    .tools = &test_tools,
    .users = &.{"Never push to main. Keep the fix small."},
};

fn checked(arena: Allocator, written: ledger.Written, earlier: []const checkpoint.Entry, counts: *Counts) !ledger.Written {
    return check(arena, written, earlier, test_sources, counts);
}

test "entries that name their source and state what it holds pass unmarked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]checkpoint.Entry{
        .{ .id = "F1", .text = "F1 (T7): 2 of 141 tests fail in `src/core/app.zig`" },
        .{ .id = "F2", .text = "F2 (T8, T9): max_bytes is 16_384; libfx is at 0.0.10 since commit 707afac508e1" },
        .{ .id = "F3", .text = "F3 (M4): resumeForWrite lives in src/core/app.zig" },
        .{ .id = "R1", .text = "R1 (M4): \"never push to main\"" },
        .{ .id = "R2", .text = "R2 (turn in progress): \"keep the fix small\"" },
        // Without saved records a turn is cited by its number.
        .{ .id = "R3", .text = "R3 (turn 4): \"never push to main\"" },
        .{ .id = "S1", .text = "S1 (T7): 141 tests run, 2 fail; replaces S0" },
    };
    var counts: Counts = .{};
    const earlier = [_]checkpoint.Entry{.{ .id = "S0", .text = "S0 (M1): not started" }};
    const result = try checked(arena, .{ .entries = &entries }, &earlier, &counts);
    for (entries, result.entries) |before, after| try testing.expectEqualStrings(before.text, after.text);
    try testing.expectEqual(@as(usize, 0), counts.marked);
}

test "what an entry gets wrong is marked, and the entry stays" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]checkpoint.Entry{
        .{ .id = "F1", .text = "F1: the suite has 141 tests" },
        .{ .id = "F2", .text = "F2 (T7): 3 of 142 tests fail in src/core/main.zig" },
        .{ .id = "F3", .text = "F3 (T99): the release is out" },
        .{ .id = "D1", .text = "D1 (M4): keep the fix small; replaces D7" },
        .{ .id = "R1", .text = "R1 (M4): \"never force push\"" },
        .{ .id = "R2", .text = "R2 (M4): keep it small" },
        // Numbers with more around them and case count as found.
        .{ .id = "F4", .text = "F4 (T9): LIBFX went to 0.0.10-dev after ~707AFAC508E1" },
        .{ .id = "F5", .text = "F5 (turn 9): 141 tests" },
    };
    var counts: Counts = .{};
    const result = try checked(arena, .{ .entries = &entries }, &.{}, &counts);
    try testing.expectEqualStrings("F1: the suite has 141 tests [check: no source]", result.entries[0].text);
    try testing.expectEqualStrings("F2 (T7): 3 of 142 tests fail in src/core/main.zig [check: not in the saved turns or tool calls: 142, src/core/main.zig]", result.entries[1].text);
    try testing.expectEqualStrings("F3 (T99): the release is out [check: T99 does not exist]", result.entries[2].text);
    try testing.expectEqualStrings("D1 (M4): keep the fix small; replaces D7 [check: replaces D7, which does not exist]", result.entries[3].text);
    try testing.expectEqualStrings("R1 (M4): \"never force push\" [check: not the user's exact words]", result.entries[4].text);
    try testing.expectEqualStrings("R2 (M4): keep it small [check: no quote of the user's words]", result.entries[5].text);
    try testing.expectEqualStrings(entries[6].text, result.entries[6].text);
    try testing.expectEqualStrings("F5 (turn 9): 141 tests [check: M9 does not exist]", result.entries[7].text);
    try testing.expectEqual(@as(usize, 7), counts.marked);
    try testing.expectEqual(@as(usize, 1), counts.no_source);
    try testing.expectEqual(@as(usize, 2), counts.missing_ids);
    try testing.expectEqual(@as(usize, 2), counts.unfound_values);
    try testing.expectEqual(@as(usize, 1), counts.bad_replaces);
    try testing.expectEqual(@as(usize, 2), counts.unquoted);
}

test "every entry names its source, and one about a failed call does not call it a success" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]checkpoint.Entry{
        .{ .id = "D1", .text = "D1: keep the fix small" },
        .{ .id = "S1", .text = "S1: the tests run" },
        .{ .id = "O1", .text = "O1: which branch ships it?" },
        .{ .id = "F1", .text = "F1 (T7): the tests passed" },
        .{ .id = "S2", .text = "S2 (M4, T7): the suite is green" },
        // Several calls, or a run of them, may have failed and then worked.
        .{ .id = "S3", .text = "S3 (T7, T8): the suite passes after the fix" },
        .{ .id = "S4", .text = "S4 (T7\u{2013}T9): tests pass" },
    };
    var counts: Counts = .{};
    const result = try checked(arena, .{ .entries = &entries }, &.{}, &counts);
    try testing.expectEqualStrings("D1: keep the fix small [check: no source]", result.entries[0].text);
    try testing.expectEqualStrings("S1: the tests run [check: no source]", result.entries[1].text);
    try testing.expectEqualStrings("O1: which branch ships it? [check: no source]", result.entries[2].text);
    try testing.expectEqualStrings("F1 (T7): the tests passed [check: T7 failed]", result.entries[3].text);
    try testing.expectEqualStrings("S2 (M4, T7): the suite is green [check: T7 failed]", result.entries[4].text);
    try testing.expectEqualStrings(entries[5].text, result.entries[5].text);
    try testing.expectEqualStrings(entries[6].text, result.entries[6].text);
    try testing.expectEqual(@as(usize, 5), counts.marked);
    try testing.expectEqual(@as(usize, 3), counts.no_source);
    try testing.expectEqual(@as(usize, 2), counts.failed_as_success);
}

test "an entry may replace one written before it in the same reply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]checkpoint.Entry{
        .{ .id = "S1", .text = "S1 (T7): tests fail" },
        .{ .id = "S2", .text = "S2 (T7): still failing, replaces S1" },
        .{ .id = "S3", .text = "S3 (T7): failing; replaces S4" },
    };
    var counts: Counts = .{};
    const result = try checked(arena, .{ .entries = &entries }, &.{}, &counts);
    try testing.expectEqualStrings(entries[1].text, result.entries[1].text);
    try testing.expect(std.mem.endsWith(u8, result.entries[2].text, "[check: replaces S4, which does not exist]"));

    // S4 may be saved only in the ledger of a folded compaction, which the
    // highest numbers so far count.
    var folded = test_sources;
    folded.highest = .{ 0, 0, 0, 4, 0 };
    const again = try check(arena, .{ .entries = entries[2..] }, &.{}, folded, &counts);
    try testing.expectEqualStrings(entries[2].text, again.entries[0].text);
}

test "tool notes are checked against their call, and a failed call is not a success" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const notes = [_]ledger.Note{
        .{ .number = 7, .text = "ran the tests; all 141 pass" },
        .{ .number = 8, .text = "read src/core/app.zig; max_bytes is 16_384" },
        .{ .number = 9, .text = "found libfx 0.0.11" },
    };
    var counts: Counts = .{};
    const result = try checked(arena, .{ .tools = &notes }, &.{}, &counts);
    try testing.expectEqualStrings("ran the tests; all 141 pass [check: T7 failed]", result.tools[0].text);
    try testing.expectEqualStrings(notes[1].text, result.tools[1].text);
    try testing.expectEqualStrings("found libfx 0.0.11 [check: not in the saved turns or tool calls: 0.0.11]", result.tools[2].text);
    try testing.expectEqual(@as(usize, 1), counts.failed_as_success);

    // A note on a failed call that says it failed passes.
    const honest = [_]ledger.Note{.{ .number = 7, .text = "ran the tests; they did not pass" }};
    var honest_counts: Counts = .{};
    const kept = try checked(arena, .{ .tools = &honest }, &.{}, &honest_counts);
    try testing.expectEqualStrings(honest[0].text, kept.tools[0].text);
}

test "a note shared by a run of calls is checked against the whole run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const notes = [_]ledger.Note{.{ .number = 7, .text = "T7\u{2013}T9: found src/core/app.zig and libfx 0.0.10" }};
    var counts: Counts = .{};
    const result = try checked(arena, .{ .tools = &notes }, &.{}, &counts);
    try testing.expectEqualStrings(notes[0].text, result.tools[0].text);
    try testing.expectEqual(@as(usize, 0), counts.marked);
}

test "a value named under the wrong call passes; one found nowhere is marked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const notes = [_]ledger.Note{
        .{ .number = 4, .text = "Read core/app.zig:12 (T9) and bumped libfx to 0.0.10; edited lib/other.ts" },
        // A path counts by its last two parts, code by its names; a quote
        // must be exact.
        .{ .number = 4, .text = "Read /repo/src/core/app.zig:40 and `resumeForWrite(void)`; the user wants \"exact CLI parity\"" },
    };
    var counts: Counts = .{};
    const result = try checked(arena, .{ .works = &notes }, &.{}, &counts);
    try testing.expectEqualStrings(notes[0].text ++ " [check: not in the saved turns or tool calls: lib/other.ts]", result.works[0].text);
    try testing.expectEqualStrings(notes[1].text ++ " [check: not in the saved turns or tool calls: exact CLI parity]", result.works[1].text);

    // An entry only about earlier compactions is not checked against this one.
    const entries = [_]checkpoint.Entry{.{ .id = "F9", .text = "F9 (T2): lib/other.ts holds the cache" }};
    const earlier_only = try checked(arena, .{ .entries = &entries }, &.{}, &counts);
    try testing.expectEqualStrings(entries[0].text, earlier_only.entries[0].text);
}

test "values are the words whose exact form matters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try values(arena, "Ran `zig build test` on main.zig (T12) and M3: 141 passed in 12.3s, e.g. see ~/src/fx/build.zig, and/or \"the ledger\"; 2 of 12 failed.");
    const expected = [_][]const u8{ "zig build test", "the ledger", "main.zig", "141", "12.3s", "~/src/fx/build.zig" };
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 0), (try values(arena, "F12 T3\u{2013}T9 M40 R2 search/edit/read (T47,T60,T109) (M9/T254):")).len);
    // A path with an ID-like part is still a path.
    try testing.expectEqual(@as(usize, 1), (try values(arena, "see T3/main.zig")).len);
}

test "curly quotes are checked like straight ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const users = [_][]const u8{"please use only the standard library"};
    for ([_][]const u8{ "R1 (M2): \u{201c}Use only the standard library\u{201d}", "R1 (M2): \u{201c}use no packages\u{201d}", "R1 (M2): \"use only the standard library.\"" }, [_]usize{ 0, 1, 0 }) |rule, marks| {
        var problems: Problems = .{};
        var counts: Counts = .{};
        try checkQuote(arena, &problems, rule, &users, &counts);
        try testing.expectEqual(marks, counts.unquoted);
    }
}

test "punctuation inside closing quote marks is not part of the quoted words" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const texts = [_][]const u8{"Plus a \"smaller documented limits\" section. It builds immediately."};
    for ([_][]const u8{ "\u{201c}smaller documented limits,\u{201d}", "\"smaller documented limits.\"", "`smaller documented limits`" }) |quoted| {
        const found = try values(arena, quoted);
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expect(try foundIn(arena, found[0], &texts));
    }
    // Quote marks around a paraphrase still claim exact words.
    const paraphrase = try values(arena, "the \u{201c}build immediately\u{201d} instruction");
    try testing.expect(!try foundIn(arena, paraphrase[0], &texts));
}

test "citations read single IDs and runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try citations(arena, "F3 (T40, M2): see T3\u{2013}T8, T10-T12 and T5 to T6; not T4x or ATM9");
    const want = [_]Citation{
        .{ .kind = 'T', .first = 40, .last = 40 }, .{ .kind = 'M', .first = 2, .last = 2 }, .{ .kind = 'T', .first = 3, .last = 8 },
        .{ .kind = 'T', .first = 10, .last = 12 }, .{ .kind = 'T', .first = 5, .last = 6 },
    };
    try testing.expectEqual(want.len, found.len);
    for (want, found) |expected, got| try testing.expectEqual(expected, got);
}
