//! The notes of fx-compactor, kept beside the user's messages and the
//! assistant's final replies, which stay word for word: what the assistant
//! did in between, a line for every tool call, and the session's rules,
//! facts, decisions and status. The conversation's model writes them for the
//! new turns only; nothing it wrote before is ever changed. When a later
//! compaction folds the previous one away, the model also writes the summary
//! that stands in for it, saved whole as its L record. This file says what
//! the model is asked for and reads what it wrote:
//! - a note counts only for a turn or tool call of this compaction;
//! - entries are only added: one repeated word for word is left out, and one
//!   whose ID is taken is kept under the next free ID.
//! lint.zig then checks what the notes and entries say.
//! It also lists, from the tool calls alone, the skills and MCP tools used,
//! and finds the sentences of the user's messages that may set rules, so the
//! model files them instead of relying on its own recall.

const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const trace = @import("trace.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// How the model starts the notes of a turn: `Turn 12`, or `Turn in
/// progress`.
pub const turn_label = "Turn";
pub const in_between_label = "In between:";

/// A turn the notes are asked for, and the tool calls it shows.
pub const Heading = struct {
    number: usize,
    /// T<first_tool> through T<last_tool>; zero when it shows none.
    first_tool: usize = 0,
    last_tool: usize = 0,
    /// For a model reading the conversation itself, where turns and tool
    /// calls carry no IDs: how the turn's first user message begins, and a
    /// line naming each tool call, like `T12 shell: zig build test`.
    begins: []const u8 = "",
    tools: []const []const u8 = &.{},
};

/// What one request asks notes for.
pub const Asked = struct {
    /// The complete turns to note, in order.
    turns: []const Heading = &.{},
    /// A turn still in progress follows them; its number is not used.
    open: ?Heading = null,
    /// The highest number of each kind of entry so far, in `entry_kinds`
    /// order; new entries are numbered above them.
    highest: [entry_kinds.len]usize = @splat(0),
    /// Turns and tool calls can be opened later by their IDs.
    saved: bool,
    /// The request follows the conversation itself rather than the turns
    /// written out with their IDs.
    after_conversation: bool = false,
    /// The previous compaction is saved whole as L<fold> and its turns leave
    /// what the next assistant sees, so the model summarizes it. Zero when
    /// there is none.
    fold: usize = 0,
};

/// A request that follows the conversation reads like the user's next
/// message, so the model is told not to note it.
const from_fx = " This request comes from fx, not from the user, so leave it and the writing of these notes out of every note and entry.";

/// Appends the request for the notes. It lists the exact headings to write,
/// since a model given an example heading may copy it instead.
pub fn writeRequest(alloc: Allocator, text: *std.ArrayList(u8), asked: Asked) Allocator.Error!void {
    try text.appendSlice(alloc, if (asked.after_conversation)
        "Write the compaction notes for the turns of the conversation above that are listed below; the turns after them stay in the conversation as they are. Answer with text only and call no tools." ++ from_fx
    else
        "Write the compaction notes for the new turns above.");
    try text.appendSlice(alloc, " The user's messages and the assistant's final replies stay in the conversation word for word, so do not repeat them.");
    try text.appendSlice(alloc, if (asked.saved)
        " Every tool call stays saved whole under its ID; your notes tell the assistant that continues this work which ones are worth opening."
    else
        " The tool calls will not be available later, so keep in your notes the details from them that the work still needs.");
    if (asked.turns.len > 0 or asked.open != null) {
        try text.appendSlice(alloc, "\n\nWrite these headings, in this order and without skipping any, each followed by its notes:\n\n");
        try writeHeadings(alloc, text, asked.turns, asked.open);
        if (asked.after_conversation) try text.appendSlice(alloc, "\nUnder each heading above are the turn's tool calls in order, with their IDs, so you can find them in the conversation; do not copy those lines.\n");
        try text.appendSlice(alloc, "\nUnder each heading:\n" ++ in_between_label ++
            " one to three sentences on what the assistant did before its final reply: what it looked at, what it found, what it changed or decided. Leave out what the final reply already says. Write \"none\" when there was nothing.\n" ++
            "Then one line for every tool call of the turn, starting with its ID like `T<number>:`, at most 15 words: why it was used and what it showed that matters. Calls with one purpose may share a line that starts `T<first>\u{2013}T<last>:`.\n");
        if (asked.open != null) try text.appendSlice(alloc, if (asked.after_conversation)
            "For the turn in progress, give its notes so far, through the last tool call listed under its heading; the calls after it stay in the conversation.\n"
        else
            "For the turn in progress, give its notes so far.\n");
        try text.append(alloc, '\n');
    } else {
        try text.appendSlice(alloc, "\n\n");
    }
    try text.appendSlice(alloc, "Then only the new entries of these sections, each starting with its ID and the turn or tool call it comes from, like `F<number> (T<number>):`:\n\n");
    try text.print(alloc, "Rules:\nR1, R2, ...: each new instruction, rule or preference from the user, quoted word for word in double quotes, with {s}{s}.\n\n", .{
        if (asked.saved) "the ID of its turn, like M<number>" else "its turn, like `(turn <number>)`",
        if (asked.open != null) ", or `(turn in progress)` for the turn still in progress" else "",
    });
    try text.appendSlice(alloc, "Facts:\nF1, F2, ...: facts the work depends on, from these turns: names, paths, values, results, causes.\n\n" ++
        "Decisions:\nD1, D2, ...: each decision and why. When it changes an earlier entry, end with \"replaces\" and that entry's ID.\n\n" ++
        "Status:\nS1, S2, ...: where each part of the work stands now. When it updates an earlier entry, or answers or finishes an earlier open entry, end with \"replaces\" and that entry's ID.\n\n" ++
        "Open:\nO1, O2, ...: questions waiting on the user, and next steps the user asked for.\n\n");
    if (asked.fold > 0) try writeEarlierSection(alloc, text, asked.fold, asked.after_conversation);
    try text.appendSlice(alloc, "Never repeat or rewrite an entry that already exists; add a new one that replaces it. Write \"none\" under a section with nothing new.");
    try writeHighestIds(alloc, text, asked.highest);
    try text.appendSlice(alloc, " Be exact: say what was verified, and mark anything only planned, assumed or not checked. Write only these notes.");
}

/// The section for the summary that stands in for the previous compaction,
/// saved whole as L<fold>.
fn writeEarlierSection(alloc: Allocator, text: *std.ArrayList(u8), fold: usize, after_conversation: bool) Allocator.Error!void {
    try text.print(alloc, "Earlier:\nthree to five sentences that stand in for the earlier compacted conversation {s}, which is saved whole as L{d} and leaves what the next assistant sees: what the user wanted, what was done and found, the decisions still in force, and where the work stood when it ended. Cover only that conversation; the turns after it and any turn in progress stay in view with the user's messages word for word, so leave them out. Its rules, status and open entries stay as they are, so do not repeat them.\n\n", .{
        if (after_conversation) "at the start of the conversation above" else "shown above",
        fold,
    });
}

const entry_kinds = checkpoint.entry_kinds;

/// Appends the request for what a first reply left out: the complete turns
/// `missing`, and with a nonzero `fold` the summary of the previous
/// compaction, saved whole as L<fold>. `highest` counts every entry so far,
/// the first reply's too.
pub fn writeFollowUp(alloc: Allocator, text: *std.ArrayList(u8), missing: []const Heading, highest: [entry_kinds.len]usize, after_conversation: bool, fold: usize) Allocator.Error!void {
    if (missing.len == 0) {
        try text.appendSlice(alloc, "Your notes left out the summary of the earlier compacted conversation. Write only that now, under this heading:\n\n");
        try writeEarlierSection(alloc, text, fold, after_conversation);
        if (after_conversation) try text.appendSlice(alloc, "Answer with text only and call no tools." ++ from_fx);
        return;
    }
    try text.appendSlice(alloc, "Your notes on the turns above left some out. Write the notes for only these turns now, each heading followed by its notes:\n\n");
    try writeHeadings(alloc, text, missing, null);
    if (after_conversation) try text.appendSlice(alloc, "\nUnder each heading above are the turn's tool calls, so you can find them; do not copy those lines. Answer with text only and call no tools." ++ from_fx ++ "\n");
    try text.appendSlice(alloc, "\nUnder each heading, " ++ in_between_label ++ " with what the assistant did before its final reply, then a line for every tool call, starting with its ID, on why it was used and what it showed.\n\n" ++
        "Then any new entries from those turns under the same sections, each starting with its ID and the turn or tool call it comes from.");
    try writeHighestIds(alloc, text, highest);
    if (fold > 0) {
        try text.appendSlice(alloc, " Your notes also left out the summary of the earlier compacted conversation; after the entries, write it under this heading:\n\n");
        try writeEarlierSection(alloc, text, fold, after_conversation);
        try text.appendSlice(alloc, "Write only these notes.");
    } else {
        try text.appendSlice(alloc, " Write only these notes.");
    }
}

/// One line per turn, like `Turn 3 (T10–T19)`, then `Turn in progress`,
/// each with how it begins and its tool calls when it has them.
fn writeHeadings(alloc: Allocator, text: *std.ArrayList(u8), turns: []const Heading, open: ?Heading) Allocator.Error!void {
    for (turns) |turn| {
        try text.print(alloc, turn_label ++ " {d}", .{turn.number});
        try writeHeadingRest(alloc, text, turn);
    }
    if (open) |turn| {
        try text.appendSlice(alloc, turn_label ++ " in progress");
        try writeHeadingRest(alloc, text, turn);
    }
}

fn writeHeadingRest(alloc: Allocator, text: *std.ArrayList(u8), turn: Heading) Allocator.Error!void {
    if (turn.first_tool == 0) {
        try text.appendSlice(alloc, " (no tool calls)");
    } else if (turn.first_tool == turn.last_tool) {
        try text.print(alloc, " (T{d})", .{turn.first_tool});
    } else {
        try text.print(alloc, " (T{d}\u{2013}T{d})", .{ turn.first_tool, turn.last_tool });
    }
    if (turn.begins.len > 0) try text.print(alloc, ", which begins \u{201c}{s}\u{201d}", .{turn.begins});
    try text.append(alloc, '\n');
    for (turn.tools) |line| try text.print(alloc, "  {s}\n", .{line});
}

/// Asks for new entries numbered after the highest of each kind, so no ID
/// ever names two entries.
fn writeHighestIds(alloc: Allocator, text: *std.ArrayList(u8), highest: [entry_kinds.len]usize) Allocator.Error!void {
    var written: usize = 0;
    for (entry_kinds, highest) |kind, number| {
        if (number == 0) continue;
        try text.print(alloc, "{s}{c}{d}", .{ if (written == 0) " The highest IDs so far: " else ", ", kind, number });
        written += 1;
    }
    try text.appendSlice(alloc, if (written > 0) ". Number new entries after them." else " Number each kind from 1.");
}

/// One user message and its turn, M<turn>. Zero for messages from an older
/// checkpoint format, which have no saved turn.
pub const Message = struct { turn: usize, text: []const u8, in_progress: bool = false };

/// A sentence from the user's messages that may set a rule.
pub const Candidate = struct { turn: usize, text: []const u8, in_progress: bool = false };

/// At most this much candidate text goes into one request, oldest first.
const max_candidate_bytes = 12 * 1024;
/// Longer lines are pasted output, not the user's own instructions.
const max_candidate_line_bytes = 400;

/// Sentences of `messages` that may set rules, found without a model, oldest
/// first and without repeats: ones with words like "never", "only" or
/// "not a". A short one keeps up to two sentences before it, so "Don't build
/// it." keeps what "it" was. Questions, code blocks and lines that look like
/// pasted output are skipped, and so are sentences a rule in `filed` already
/// quotes, so a turn still in progress at each compaction is not filed
/// again. They are recall only: the model decides which still apply. `arena`
/// owns the result.
pub fn candidates(arena: Allocator, messages: []const Message, filed: []const checkpoint.Entry) Allocator.Error![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    var bytes: usize = 0;
    for (messages) |message| {
        var before: [2][]const u8 = .{ "", "" };
        var fenced = false;
        var lines = std.mem.splitScalar(u8, message.text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "```")) {
                fenced = !fenced;
                continue;
            }
            if (fenced or line.len == 0 or line.len > max_candidate_line_bytes or !looksWritten(line)) continue;
            var sentences: Sentences = .{ .text = line };
            while (sentences.next()) |sentence| {
                defer {
                    before[0] = before[1];
                    before[1] = sentence;
                }
                if (sentence[sentence.len - 1] == '?') continue;
                const words = try lowerWords(arena, sentence);
                if (!hasRuleWords(words)) continue;
                const text = if (needsContext(words))
                    try joinSentences(arena, &.{ before[0], before[1], sentence })
                else
                    sentence;
                const seen = for (out.items) |item| {
                    if (std.mem.eql(u8, item.text, text)) break true;
                } else false;
                const quoted = for (filed) |entry| {
                    if (std.mem.startsWith(u8, entry.id, "R") and std.mem.find(u8, entry.text, sentence) != null) break true;
                } else false;
                if (seen or quoted) continue;
                if (bytes + text.len > max_candidate_bytes) {
                    trace.log(false, "rule candidates over their room; the newest are left out candidates={d} bytes={d}", .{ out.items.len, bytes });
                    return out.items;
                }
                bytes += text.len;
                try out.append(arena, .{ .turn = message.turn, .text = text, .in_progress = message.in_progress });
            }
        }
    }
    return out.items;
}

/// Appends the candidates to the request, for the model to file.
pub fn writeCandidates(alloc: Allocator, text: *std.ArrayList(u8), found: []const Candidate, saved: bool) Allocator.Error!void {
    if (found.len == 0) return;
    try text.appendSlice(alloc, "\n\nSentences from the user's messages that may set rules, found by code. File each one that still applies under Rules, quoted exactly with its turn ID; leave out complaints, reports and requests meant only for that moment:\n");
    for (found) |candidate| {
        if (candidate.in_progress) {
            try text.appendSlice(alloc, "- turn in progress: ");
        } else if (candidate.turn == 0) {
            try text.appendSlice(alloc, "- earlier message: ");
        } else if (saved) {
            try text.print(alloc, "- M{d}: ", .{candidate.turn});
        } else {
            try text.print(alloc, "- turn {d}: ", .{candidate.turn});
        }
        try text.print(alloc, "\"{s}\"\n", .{candidate.text});
    }
}

/// Most of `line` is words, not code, paths, a pasted table or a quoted
/// transcript.
fn looksWritten(line: []const u8) bool {
    for ([_][]const u8{ "\u{2503}", "\u{2502}", "|", ">" }) |quoted| if (std.mem.startsWith(u8, line, quoted)) return false;
    var written: usize = 0;
    for (line) |byte| written += @intFromBool(std.ascii.isAlphabetic(byte) or byte == ' ' or byte == '\'' or byte == ',');
    return written * 10 >= line.len * 7;
}

/// The sentences of one line, split after `.`, `!` or `?` before a space.
const Sentences = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Sentences) ?[]const u8 {
        while (self.at < self.text.len) {
            const start = self.at;
            var end = start;
            while (end < self.text.len) : (end += 1) {
                const byte = self.text[end];
                if ((byte == '.' or byte == '!' or byte == '?') and (end + 1 == self.text.len or self.text[end + 1] == ' ')) {
                    end += 1;
                    break;
                }
            }
            self.at = end;
            const sentence = std.mem.trim(u8, self.text[start..end], " ");
            if (sentence.len > 0) return sentence;
        }
        return null;
    }
};

/// The words of `sentence`, lowercase, with curly apostrophes made straight.
fn lowerWords(arena: Allocator, sentence: []const u8) Allocator.Error![]const []const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < sentence.len) : (index += 1) {
        if (std.mem.startsWith(u8, sentence[index..], "\u{2019}")) {
            try plain.append(arena, '\'');
            index += "\u{2019}".len - 1;
        } else {
            try plain.append(arena, std.ascii.toLower(sentence[index]));
        }
    }
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, plain.items, " \t,;:()\"`*_.!");
    while (tokens.next()) |word| try words.append(arena, word);
    return words.items;
}

fn hasRuleWords(words: []const []const u8) bool {
    const single = [_][]const u8{ "never", "don't", "dont", "avoid", "always", "only", "must", "mustn't", "every", "ignore", "skip", "stop" };
    const pairs = [_][2][]const u8{ .{ "do", "not" }, .{ "instead", "of" }, .{ "rather", "than" }, .{ "at", "most" }, .{ "make", "sure" }, .{ "no", "longer" }, .{ "no", "more" } };
    const after_not = [_][]const u8{ "a", "an", "the", "by", "from", "to", "in" };
    for (words, 0..) |word, index| {
        for (single) |cue| if (std.mem.eql(u8, word, cue)) return true;
        const next = if (index + 1 < words.len) words[index + 1] else "";
        for (pairs) |pair| if (std.mem.eql(u8, word, pair[0]) and std.mem.eql(u8, next, pair[1])) return true;
        if (std.mem.eql(u8, word, "not")) for (after_not) |cue| if (std.mem.eql(u8, next, cue)) return true;
        if (std.mem.eql(u8, word, "under") and next.len > 0 and std.ascii.isDigit(next[0])) return true;
    }
    return false;
}

/// A short sentence, or one about "it" or "that", needs the ones before it.
fn needsContext(words: []const []const u8) bool {
    if (words.len < 7) return true;
    const skip = [_][]const u8{ "don't", "dont", "do", "not", "never", "only", "always", "please", "just", "so", "and", "but", "then" };
    const pronouns = [_][]const u8{ "it", "that", "this", "them", "those", "these" };
    for (words) |word| {
        const skipped = for (skip) |filler| {
            if (std.mem.eql(u8, word, filler)) break true;
        } else false;
        if (skipped) continue;
        for (pronouns) |pronoun| if (std.mem.eql(u8, word, pronoun)) return true;
        return false;
    }
    return false;
}

fn joinSentences(arena: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        if (part.len == 0) continue;
        if (text.items.len > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, part);
    }
    return text.items;
}

/// A note for one turn or tool call.
pub const Note = struct { number: usize, text: []const u8 };

/// What the notes may be for: the turns and tool calls of one request. The
/// turn in progress is turn zero.
pub const Known = struct {
    turns: []const usize,
    tools: []const usize,
    open: bool = false,
};

/// What the model wrote for one request, read. lint.zig checks what it says.
pub const Written = struct {
    /// What the assistant did in between, per turn.
    works: []const Note = &.{},
    /// Why a tool was used and what it showed, per tool call.
    tools: []const Note = &.{},
    /// The new entries, in the order written.
    entries: []const checkpoint.Entry = &.{},
    /// The complete turns the reply wrote an in-between line for, even
    /// `none`, or kept a reply in none of the asked form as the notes of.
    noted: []const usize = &.{},
    /// The summary of the earlier compacted conversation, when asked for.
    earlier: []const u8 = "",
    /// Entries left out because they repeat an existing entry word for word.
    repeated: usize = 0,
    /// Entries kept under the next free ID because theirs was taken.
    renumbered: usize = 0,
    /// Notes left out because this request has no such turn or tool call.
    unknown: usize = 0,

    pub fn work(self: Written, turn: usize) []const u8 {
        return noteFor(self.works, turn);
    }

    pub fn tool(self: Written, number: usize) []const u8 {
        return noteFor(self.tools, number);
    }
};

fn noteFor(notes: []const Note, number: usize) []const u8 {
    for (notes) |note| if (note.number == number) return note.text;
    return "";
}

/// Notes longer than this are cut at a character boundary; the model is
/// asked for far less.
const max_work_bytes = 1200;
const max_tool_note_bytes = 300;
/// The summary of earlier compactions replaces the one before it, so this
/// bounds it however many there are.
const max_earlier_bytes = 2400;
/// An entry numbered this far above the highest of its kind is renumbered.
const max_id_gap = 1000;
/// A reply in none of the asked form may say more, for every turn at once.
const max_unread_bytes = 8 * 1024;

/// Reads the model's notes. Notes for turns and tool calls that `known`
/// does not have are left out, like entries repeating one of `earlier` word
/// for word and lines copied with the mark of an entry another replaced. An
/// entry whose ID is taken, by `highest` or by an earlier entry of the reply,
/// or numbered far above the highest, is kept under the next free ID. A reply
/// in none of the asked form becomes the notes of the newest turn, or with no
/// turn asked for, the summary of earlier compactions. `arena` owns the
/// result.
pub fn read(arena: Allocator, reply: []const u8, known: Known, earlier: []const checkpoint.Entry, highest: [entry_kinds.len]usize) Allocator.Error!Written {
    const Building = struct { number: usize, text: std.ArrayList(u8) = .empty, limit: usize };
    var works: std.ArrayList(Building) = .empty;
    var tool_notes: std.ArrayList(Building) = .empty;
    var sections: std.ArrayList(u8) = .empty;
    var earlier_summary: std.ArrayList(u8) = .empty;
    var current: ?*Building = null;
    var turn: ?usize = null;
    var in_sections = false;
    var in_earlier = false;
    var unknown: usize = 0;
    var noted: std.ArrayList(usize) = .empty;

    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const plain = try undecorated(arena, line);
        if (turnNumber(plain)) |number| {
            turn = number;
            in_sections = false;
            in_earlier = false;
            current = null;
            continue;
        }
        if (earlierRest(plain)) |rest| {
            in_earlier = true;
            in_sections = false;
            turn = null;
            current = null;
            if (rest.len > 0) try earlier_summary.print(arena, "{s}\n", .{rest});
            continue;
        }
        if (sectionRest(plain)) |rest| {
            in_sections = true;
            in_earlier = false;
            turn = null;
            current = null;
            try sections.print(arena, "{s}\n", .{rest});
            continue;
        }
        if (in_earlier) {
            try earlier_summary.print(arena, "{s}\n", .{line});
            continue;
        }
        if (in_sections) {
            try sections.print(arena, "{s}\n", .{raw});
            continue;
        }
        const number = turn orelse continue;
        if (inBetweenRest(plain)) |work_text| {
            current = null;
            const allowed = if (number == 0) known.open else contains(known.turns, number);
            if (!allowed) {
                unknown += 1;
                continue;
            }
            if (number > 0 and !contains(noted.items, number)) try noted.append(arena, number);
            try works.append(arena, .{ .number = number, .limit = max_work_bytes });
            current = &works.items[works.items.len - 1];
            try current.?.text.appendSlice(arena, work_text);
        } else if (toolNote(plain)) |found| {
            current = null;
            if (!contains(known.tools, found.number) or (found.last > 0 and !contains(known.tools, found.last))) {
                unknown += 1;
                continue;
            }
            if (isNone(found.text)) continue;
            // A run of calls shares one note, kept on its first call.
            try tool_notes.append(arena, .{ .number = found.number, .limit = max_tool_note_bytes });
            current = &tool_notes.items[tool_notes.items.len - 1];
            if (found.last > 0) try current.?.text.print(arena, "T{d}\u{2013}T{d}: ", .{ found.number, found.last });
            try current.?.text.appendSlice(arena, found.text);
        } else if (isToolsLabel(plain)) {
            current = null;
        } else if (line.len == 0) {
            current = null;
        } else if (current) |note| {
            try note.text.print(arena, " {s}", .{line});
        }
    }

    // A reply in none of the asked form is kept whole as the notes of the
    // newest turn it covers rather than lost; asked for no turn, only for the
    // summary of earlier compactions, it is that summary.
    if (works.items.len == 0 and tool_notes.items.len == 0 and sections.items.len == 0 and earlier_summary.items.len == 0 and unknown == 0) {
        const newest: ?usize = if (known.open) 0 else if (known.turns.len > 0) known.turns[known.turns.len - 1] else null;
        if (newest) |number| {
            const text = std.mem.trim(u8, reply, " \t\r\n");
            try works.append(arena, .{ .number = number, .limit = max_unread_bytes });
            try works.items[0].text.appendSlice(arena, text);
            if (number > 0 and text.len > 0) try noted.append(arena, number);
        } else {
            try earlier_summary.appendSlice(arena, reply);
        }
    }

    var written: Written = .{ .unknown = unknown, .noted = noted.items };
    for ([_]*std.ArrayList(Building){ &works, &tool_notes }, [_]*[]const Note{ &written.works, &written.tools }) |building, out| {
        var notes: std.ArrayList(Note) = .empty;
        for (building.items) |*note| {
            const text = std.mem.trim(u8, note.text.items, " ");
            if (text.len == 0 or isNone(text) or noteFor(notes.items, note.number).len > 0) continue;
            const cut = text_utils.utf8BackwardBoundary(text, @min(text.len, note.limit));
            if (cut < text.len) trace.log(false, "a compaction note was cut to {d} bytes number={d} bytes={d}", .{ cut, note.number, text.len });
            try notes.append(arena, .{ .number = note.number, .text = text[0..cut] });
        }
        out.* = notes.items;
    }

    const summary = std.mem.trim(u8, earlier_summary.items, " \t\r\n");
    if (!isNone(summary)) {
        const cut = text_utils.utf8BackwardBoundary(summary, @min(summary.len, max_earlier_bytes));
        if (cut < summary.len) trace.log(false, "the summary of earlier compactions was cut to {d} bytes bytes={d}", .{ cut, summary.len });
        written.earlier = summary[0..cut];
    }

    // New IDs are kept first, so a taken one never pushes a later entry off
    // the ID the model gave it; taken ones, and numbers far above the
    // highest, then get the next free IDs. A taken ID may be a rewrite or a
    // new entry, so both entries stay.
    const Fate = enum { repeat, keep, renumber };
    const found = try items(arena, sections.items);
    const fates = try arena.alloc(Fate, found.len);
    const before = checkpoint.highestIds(.{ .entries = earlier, .highest = highest });
    var next = before;
    for (found, fates, 0..) |item, *fate, index| {
        const rest = entryRest(item);
        const repeats = for (earlier) |entry| {
            if (std.mem.eql(u8, entry.id, item.id) and std.mem.eql(u8, entry.text[entry.id.len..], rest)) break true;
        } else false;
        if (repeats or copiesReplaced(rest)) {
            fate.* = .repeat;
            written.repeated += 1;
            continue;
        }
        const kind = std.mem.findScalar(u8, entry_kinds, item.id[0]).?;
        const number = std.fmt.parseUnsigned(usize, item.id[1..], 10) catch 0;
        const reused = for (found[0..index], fates[0..index]) |other, other_fate| {
            if (other_fate == .keep and std.mem.eql(u8, other.id, item.id)) break true;
        } else false;
        // Far above the highest is a slip, not a real number; renumbered, the
        // numbers stay small and never run out.
        if (number <= before[kind] or reused or number - before[kind] > max_id_gap) {
            fate.* = .renumber;
            continue;
        }
        fate.* = .keep;
        next[kind] = @max(next[kind], number);
    }
    var entries: std.ArrayList(checkpoint.Entry) = .empty;
    for (found, fates) |item, fate| {
        const id = switch (fate) {
            .repeat => continue,
            .keep => item.id,
            .renumber => renumbered: {
                const kind = std.mem.findScalar(u8, entry_kinds, item.id[0]).?;
                next[kind] +|= 1;
                written.renumbered += 1;
                break :renumbered try std.fmt.allocPrint(arena, "{c}{d}", .{ entry_kinds[kind], next[kind] });
            },
        };
        try entries.append(arena, .{ .id = id, .text = try std.mem.concat(arena, u8, &.{ id, entryRest(item) }) });
    }
    if (written.renumbered > 0) trace.log(false, "compaction entries renumbered because their IDs were taken or far above the highest count={d}", .{written.renumbered});
    written.entries = entries.items;
    return written;
}

fn contains(numbers: []const usize, number: usize) bool {
    return std.mem.findScalar(usize, numbers, number) != null;
}

fn isNone(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, text, "."), "none");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// `line` without Markdown around it: leading `#`, `-`, `*` and `>`, and
/// every `**`.
fn undecorated(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    const start = std.mem.trimStart(u8, line, "#-*> \t");
    if (std.mem.find(u8, start, "**") == null) return start;
    return std.mem.replaceOwned(u8, arena, start, "**", "");
}

/// The turn a line like `Turn 12`, `[Turn 12]:`, `Turn 12 (T40–T45)` or
/// `Turn in progress` starts the notes of; zero for the turn in progress.
fn turnNumber(plain: []const u8) ?usize {
    var rest = std.mem.trim(u8, plain, "[]: ");
    if (!startsWithIgnoreCase(rest, turn_label ++ " ")) return null;
    rest = std.mem.trimStart(u8, rest[turn_label.len..], "[ ");
    const in_progress = "in progress";
    if (startsWithIgnoreCase(rest, in_progress)) return if (endsHeading(rest[in_progress.len..])) 0 else null;
    const digits = for (rest, 0..) |c, index| {
        if (!std.ascii.isDigit(c)) break index;
    } else rest.len;
    if (digits == 0 or !endsHeading(rest[digits..])) return null;
    const number = std.fmt.parseUnsigned(usize, rest[0..digits], 10) catch return null;
    return if (number > 0) number else null;
}

/// After its turn a heading has nothing, or its tool calls or a title set
/// off like ` (T40–T45)`, `: title` or ` – title`. A sentence like `Turn 12
/// was slow` is not a heading.
fn endsHeading(rest: []const u8) bool {
    const after = std.mem.trimStart(u8, rest, " ");
    for ([_][]const u8{ "(", ":", "]", "\u{2013}", "\u{2014}", "-" }) |mark| {
        if (std.mem.startsWith(u8, after, mark)) return true;
    }
    return after.len == 0;
}

/// What follows `In between:` or `In-between:` on its line, or null when
/// `plain` does not start with either.
fn inBetweenRest(plain: []const u8) ?[]const u8 {
    for ([_][]const u8{ in_between_label, "In-between:" }) |label| {
        if (startsWithIgnoreCase(plain, label)) return std.mem.trim(u8, plain[label.len..], " ");
    }
    return null;
}

/// What follows the `Earlier:` heading of the summary of earlier compactions
/// on its line, or null when `plain` is not it.
fn earlierRest(plain: []const u8) ?[]const u8 {
    for ([_][]const u8{ "Earlier summary", "Earlier" }) |heading| {
        if (!startsWithIgnoreCase(plain, heading)) continue;
        const after = plain[heading.len..];
        if (after.len == 0) return after;
        if (after[0] == ':') return std.mem.trim(u8, after[1..], " ");
    }
    return null;
}

/// What follows a section heading like `Rules:` or `Facts of the session:`
/// on its line, or null when `plain` is not one.
fn sectionRest(plain: []const u8) ?[]const u8 {
    const headings = [_][]const u8{ "Rules of the session", "Facts of the session", "Status and open", "Rules", "Facts", "Decisions", "Status", "Open" };
    for (headings) |heading| {
        if (!startsWithIgnoreCase(plain, heading)) continue;
        const after = plain[heading.len..];
        if (after.len == 0) return after;
        if (after[0] == ':') return std.mem.trim(u8, after[1..], " ");
    }
    return null;
}

const ToolNote = struct {
    number: usize,
    /// The last call of a run of calls sharing the note; zero for one call.
    last: usize = 0,
    text: []const u8,
};

/// A tool note like `T40: ran the tests` or `T40 (shell) - ran the tests`,
/// or one for a run of calls like `T40–T44: read the loader`.
fn toolNote(plain: []const u8) ?ToolNote {
    var rest = plain;
    const number = toolNumber(&rest) orelse return null;
    var last: usize = 0;
    var after = std.mem.trimStart(u8, rest, " ");
    for ([_][]const u8{ "\u{2013}", "\u{2014}", "-", "to " }) |dash| {
        if (!std.mem.startsWith(u8, after, dash)) continue;
        var end = std.mem.trimStart(u8, after[dash.len..], " ");
        if (toolNumber(&end)) |range_end| if (range_end > number) {
            last = range_end;
            after = std.mem.trimStart(u8, end, " ");
        };
        break;
    }
    while (after.len > 0 and (after[0] == '(' or after[0] == '[')) {
        const close = std.mem.findScalar(u8, after, if (after[0] == '(') ')' else ']') orelse return null;
        after = std.mem.trimStart(u8, after[close + 1 ..], " ");
    }
    for ([_][]const u8{ ":", "-", "\u{2014}", "\u{2013}" }) |separator| {
        if (std.mem.startsWith(u8, after, separator)) return .{ .number = number, .last = last, .text = std.mem.trim(u8, after[separator.len..], " ") };
    }
    return null;
}

/// Reads `T` and its digits from the start of `text`, moving past them.
fn toolNumber(text: *[]const u8) ?usize {
    const start = text.*;
    if (start.len < 2 or start[0] != 'T') return null;
    var digits: usize = 1;
    while (digits < start.len and std.ascii.isDigit(start[digits])) digits += 1;
    if (digits == 1) return null;
    const number = std.fmt.parseUnsigned(usize, start[1..digits], 10) catch return null;
    text.* = start[digits..];
    return number;
}

/// A line like `T: none` or `Tools: none`, which names no call.
fn isToolsLabel(plain: []const u8) bool {
    return startsWithIgnoreCase(plain, "T:") or startsWithIgnoreCase(plain, "Tools:");
}

/// A line copied from the compacted conversation, where an entry a later one
/// replaced ends like ` (replaced by S2)`.
fn copiesReplaced(rest: []const u8) bool {
    const line = std.mem.trimEnd(u8, rest, " .");
    const at = std.mem.findLast(u8, line, checkpoint.replaced_mark) orelse return false;
    const tail = line[at + checkpoint.replaced_mark.len ..];
    return tail.len > 1 and tail[tail.len - 1] == ')' and checkpoint.isEntryId(tail[0 .. tail.len - 1]);
}

/// An entry's text after its ID, without the bullet, check box or bold mark
/// around the ID: ` (T3): ...` of `- [x] **F1** (T3): ...`, saved after the
/// ID as `F1 (T3): ...`.
fn entryRest(item: Item) []const u8 {
    // Nothing that may come before an ID contains one.
    const at = std.mem.find(u8, item.text, item.id).?;
    const rest = item.text[at + item.id.len ..];
    return if (std.mem.startsWith(u8, rest, "**")) rest[2..] else rest;
}

const Item = struct {
    /// Like `D3`.
    id: []const u8,
    /// The item's line and the indented lines that continue it.
    text: []const u8,
};

/// The items of a ledger, in order. An item starts with its ID, after any
/// bullet, check box or bold mark, followed by `:`, `.` or `)`.
fn items(arena: Allocator, text: []const u8) Allocator.Error![]const Item {
    var out: std.ArrayList(Item) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const line_end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
        const id = itemId(text[at..line_end]) orelse {
            at = line_end + 1;
            continue;
        };
        var end = line_end;
        while (end < text.len) {
            const next_end = std.mem.findScalarPos(u8, text, end + 1, '\n') orelse text.len;
            const next = text[end + 1 .. next_end];
            const continues = next.len > 0 and (next[0] == ' ' or next[0] == '\t') and std.mem.trim(u8, next, " \t").len > 0 and itemId(next) == null;
            if (!continues) break;
            end = next_end;
        }
        try out.append(arena, .{ .id = id, .text = text[at..end] });
        at = end + 1;
    }
    return out.items;
}

fn itemId(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (true) {
        if (std.mem.startsWith(u8, rest, "- ") or std.mem.startsWith(u8, rest, "* ")) {
            rest = rest[2..];
        } else if (rest.len >= 3 and rest[0] == '[' and rest[2] == ']') {
            rest = std.mem.trimStart(u8, rest[3..], " ");
        } else if (std.mem.startsWith(u8, rest, "**")) {
            rest = rest[2..];
        } else break;
    }
    if (rest.len < 3 or std.mem.findScalar(u8, entry_kinds, rest[0]) == null) return null;
    var digits: usize = 1;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 1) return null;
    var after = rest[digits..];
    if (std.mem.startsWith(u8, after, "**")) after = after[2..];
    // A reference may sit between the ID and its colon, like `R1 (M2):`.
    after = std.mem.trimStart(u8, after, " ");
    while (after.len > 0 and (after[0] == '(' or after[0] == '[')) {
        const close = std.mem.findScalar(u8, after, if (after[0] == '(') ')' else ']') orelse return null;
        after = std.mem.trimStart(u8, after[close + 1 ..], " ");
    }
    if (after.len == 0 or std.mem.findScalar(u8, ":.)", after[0]) == null) return null;
    return rest[0..digits];
}

/// One tool call, as the list of skills and MCP tools reads it.
pub const Call = struct {
    number: usize,
    name: []const u8,
    arguments: []const u8,
};

/// `earlier` with the skills and MCP tools that `calls` used added, each
/// counted, in the order first used. `arena` owns the result.
pub fn addUsed(arena: Allocator, earlier: []const checkpoint.Used, calls: []const Call) Allocator.Error![]const checkpoint.Used {
    var list: std.ArrayList(checkpoint.Used) = .empty;
    for (earlier) |entry| {
        var copy = entry;
        copy.name = try arena.dupe(u8, entry.name);
        try list.append(arena, copy);
    }
    for (calls) |call| {
        const found = try usedBy(arena, call) orelse continue;
        const entry = for (list.items) |*existing| {
            if (existing.kind == found.kind and std.mem.eql(u8, existing.name, found.name)) break existing;
        } else {
            try list.append(arena, .{ .kind = found.kind, .name = found.name, .first_tool = call.number, .last_tool = call.number });
            continue;
        };
        entry.calls += 1;
        entry.last_tool = call.number;
    }
    return list.items;
}

const Found = struct { kind: checkpoint.Used.Kind, name: []const u8 };

/// The skill or MCP tool a call used: a `skill` call's location (and
/// resource), an MCP tool by its name, or an `mcp_features` call by its
/// server and action.
fn usedBy(arena: Allocator, call: Call) Allocator.Error!?Found {
    if (std.mem.eql(u8, call.name, "skill")) {
        const location = try stringArgument(arena, call.arguments, "location") orelse return null;
        const resource = try stringArgument(arena, call.arguments, "resource") orelse "";
        const name = if (resource.len == 0) location else try std.fmt.allocPrint(arena, "{s} {s}", .{ location, resource });
        return .{ .kind = .skill, .name = name };
    }
    if (std.mem.eql(u8, call.name, "mcp_features")) {
        const server = try stringArgument(arena, call.arguments, "server") orelse "";
        const action = try stringArgument(arena, call.arguments, "action") orelse "";
        return .{ .kind = .mcp, .name = try std.fmt.allocPrint(arena, "mcp_features {s} {s}", .{ server, action }) };
    }
    if (std.mem.startsWith(u8, call.name, "mcp_") and !std.mem.eql(u8, call.name, "mcp_select_tool")) {
        return .{ .kind = .mcp, .name = try arena.dupe(u8, call.name) };
    }
    return null;
}

/// The string `field` of JSON object `arguments`, or null.
fn stringArgument(arena: Allocator, arguments: []const u8, field: []const u8) Allocator.Error!?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    const found = value.object.get(field) orelse return null;
    return if (found == .string) found.string else null;
}

const testing = std.testing;

test "a saved entry with an empty ID is skipped when new IDs are numbered" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try writeHighestIds(testing.allocator, &text, checkpoint.highestIds(.{ .entries = &.{ .{ .id = "", .text = "" }, .{ .id = "F4", .text = "F4 (T1): x" } } }));
    try testing.expectEqualStrings(" The highest IDs so far: F4. Number new entries after them.", text.items);
}

test "entries are found by their IDs, with the lines that continue them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = "Rules:\n- R1 (M1): \"never force push\"\n\nDecisions:\n- D1 (M3): Regex, not a Zig parser.\n  It is simpler.\n\nStatus:\n- S1 (M4): build passes\nOpen:\nO2: add a README";
    const found = try items(arena_state.allocator(), text);
    try testing.expectEqual(@as(usize, 4), found.len);
    try testing.expectEqualStrings("R1", found[0].id);
    try testing.expectEqualStrings("- D1 (M3): Regex, not a Zig parser.\n  It is simpler.", found[1].text);
    try testing.expectEqualStrings("O2", found[3].id);

    for ([_][]const u8{ "**D12**: bold", "* F4) found", "- R1 (M1): \"never force push\"", "- S3 [T4, T5]: fixed", "- **F7** (T12) (M3): ran", "- R2(M1): no space" }) |line| try testing.expect(itemId(line) != null);
    for ([_][]const u8{ "- F2F meeting", "- S3 bucket", "Decisions:", "- D: none", "R12", "- S3 (the bucket) holds it", "- F4 (unclosed: x", "- E1: evidence is no longer a kind", "T12: a tool note" }) |line| try testing.expect(itemId(line) == null);
}

test "notes are read per turn and tool call, and entries only ever add" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reply =
        \\## Turn 3
        \\In between: Read the loader and found dates kept as text,
        \\then fixed the parser.
        \\- T8: read to find where dates are parsed
        \\T9 (shell): ran the tests; 1 of 6 failed
        \\T99: a tool call this compaction does not have
        \\
        \\**Turn 4**
        \\In between: none
        \\
        \\Turn in progress
        \\In between: started the release notes
        \\
        \\Rules:
        \\- R2 (M3): "Store every price as integer cents."
        \\- R3 (M4): "keep it short"
        \\Facts: F4 (T8): dates were parsed as text
        \\Decisions:
        \\- D1 (M3): a rewrite of an entry that already exists
        \\- D2 (M4): no cache; replaces D1
        \\Status:
        \\none
    ;
    const earlier = [_]checkpoint.Entry{.{ .id = "D1", .text = "D1 (M2): cache in a pickle file" }};
    const written = try read(arena, reply, .{ .turns = &.{ 3, 4 }, .tools = &.{ 8, 9 }, .open = true }, &earlier, @splat(0));

    try testing.expectEqualStrings("Read the loader and found dates kept as text, then fixed the parser.", written.work(3));
    try testing.expectEqualStrings("", written.work(4));
    try testing.expectEqualStrings("started the release notes", written.work(0));
    try testing.expectEqualStrings("read to find where dates are parsed", written.tool(8));
    try testing.expectEqualStrings("ran the tests; 1 of 6 failed", written.tool(9));
    try testing.expectEqual(@as(usize, 1), written.unknown);

    // The entry under D1's ID is kept under the next free ID, after the D2
    // the model numbered right, and D1 stays too; entries keep their text as
    // written.
    try testing.expectEqual(@as(usize, 0), written.repeated);
    try testing.expectEqual(@as(usize, 1), written.renumbered);
    try testing.expectEqual(@as(usize, 5), written.entries.len);
    try testing.expectEqualStrings("R2 (M3): \"Store every price as integer cents.\"", written.entries[0].text);
    try testing.expectEqualStrings("R3 (M4): \"keep it short\"", written.entries[1].text);
    try testing.expectEqualStrings("F4", written.entries[2].id);
    try testing.expectEqualStrings("D3 (M3): a rewrite of an entry that already exists", written.entries[3].text);
    try testing.expectEqualStrings("D2 (M4): no cache; replaces D1", written.entries[4].text);

    // An entry repeated word for word is left out, and so is a line copied
    // with the mark of an entry another replaced. One whose ID only a saved
    // ledger still holds is renumbered above it.
    const again = try read(arena,
        \\Decisions:
        \\- D1 (M2): cache in a pickle file
        \\- D1 (M2): cache in a file (replaced by D2)
        \\- D5 (M2): cache on disk (replaced by D6).
        \\- D8 (M5): the old loader (replaced by a new one) stays for tests
        \\- D4 (M5): keep the pickle cache
    , .{ .turns = &.{5}, .tools = &.{} }, &earlier, .{ 0, 0, 6, 0, 0 });
    try testing.expectEqual(@as(usize, 3), again.repeated);
    try testing.expectEqual(@as(usize, 2), again.entries.len);
    try testing.expectEqualStrings("D8 (M5): the old loader (replaced by a new one) stays for tests", again.entries[0].text);
    try testing.expectEqualStrings("D9 (M5): keep the pickle cache", again.entries[1].text);

    // Asked for no turn, only for the summary of earlier compactions, a
    // reply without its heading is that summary.
    const summary_only = try read(arena, "The user fixed the build; the tests pass.", .{ .turns = &.{}, .tools = &.{8} }, &earlier, @splat(0));
    try testing.expectEqualStrings("The user fixed the build; the tests pass.", summary_only.earlier);
    try testing.expectEqual(@as(usize, 0), summary_only.works.len);

    // An ID far above the highest is renumbered, so numbers never run out.
    const far = try read(arena, "Facts:\n- F18446744073709551615 (T8): the parser is slow\n- F1000 (T8): the loader is fast", .{ .turns = &.{3}, .tools = &.{8} }, &.{}, @splat(0));
    try testing.expectEqual(@as(usize, 1), far.renumbered);
    try testing.expectEqualStrings("F1001 (T8): the parser is slow", far.entries[0].text);
    try testing.expectEqualStrings("F1000 (T8): the loader is fast", far.entries[1].text);

    // Without a turn in progress, its notes are left out.
    const closed = try read(arena, reply, .{ .turns = &.{3}, .tools = &.{8} }, &.{}, @splat(0));
    try testing.expectEqualStrings("", closed.work(0));
    try testing.expectEqualStrings("", closed.work(4));
}

test "a run of tool calls may share a note, kept on its first call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reply =
        \\Turn 2
        \\In between: Traced the loader.
        \\T1–T4: located the loader and its callers
        \\T5-T6: ran the tests
        \\T7 to T8: none
        \\T9 - read the config
        \\T10–T99: a run this compaction does not have
        \\
        \\Turn 3
        \\In between: Answered from memory.
        \\T: none.
    ;
    const known: Known = .{ .turns = &.{ 2, 3 }, .tools = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } };
    const written = try read(arena, reply, known, &.{}, @splat(0));
    try testing.expectEqualStrings("T1–T4: located the loader and its callers", written.tool(1));
    try testing.expectEqualStrings("", written.tool(2));
    try testing.expectEqualStrings("T5–T6: ran the tests", written.tool(5));
    try testing.expectEqualStrings("", written.tool(7));
    try testing.expectEqualStrings("read the config", written.tool(9));
    try testing.expectEqual(@as(usize, 1), written.unknown);
    // A line naming no call is not part of the turn's note.
    try testing.expectEqualStrings("Answered from memory.", written.work(3));
}

test "a reply in none of the asked form becomes the newest turn's notes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prose = "The reads completed.\nKeep SENTINEL_42 in mind.";
    const complete = try read(arena, prose, .{ .turns = &.{ 3, 4 }, .tools = &.{7} }, &.{}, @splat(0));
    try testing.expectEqual(@as(usize, 1), complete.works.len);
    try testing.expectEqualStrings(prose, complete.work(4));
    try testing.expectEqualStrings("", complete.work(3));
    const running = try read(arena, prose, .{ .turns = &.{3}, .tools = &.{}, .open = true }, &.{}, @splat(0));
    try testing.expectEqualStrings(prose, running.work(0));
    // A reply in the asked form for other turns is not taken as prose.
    const misplaced = try read(arena, "Turn 9\nIn between: elsewhere", .{ .turns = &.{3}, .tools = &.{} }, &.{}, @splat(0));
    try testing.expectEqual(@as(usize, 0), misplaced.works.len);
    try testing.expectEqual(@as(usize, 1), misplaced.unknown);
}

test "skills and MCP tools are listed from their calls, counted in the order first used" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const earlier = [_]checkpoint.Used{.{ .kind = .skill, .name = "skill:ab:4/fx-conventions", .first_tool = 2, .last_tool = 2 }};
    const calls = [_]Call{
        .{ .number = 7, .name = "read_file", .arguments = "{\"path\":\"a.zig\"}" },
        .{ .number = 8, .name = "mcp_linear_list_issues", .arguments = "{}" },
        .{ .number = 9, .name = "skill", .arguments = "{\"location\":\"skill:ab:4/fx-conventions\"}" },
        .{ .number = 10, .name = "mcp_select_tool", .arguments = "{\"name\":\"mcp_linear_get_issue\"}" },
        .{ .number = 11, .name = "mcp_linear_list_issues", .arguments = "{\"team\":\"fx\"}" },
        .{ .number = 12, .name = "mcp_features", .arguments = "{\"action\":\"resource_read\",\"server\":\"linear\"}" },
        .{ .number = 13, .name = "skill", .arguments = "{\"location\":\"skill:ab:4/zig\",\"resource\":\"references/io.md\"}" },
        .{ .number = 14, .name = "skill", .arguments = "not json" },
    };
    const used = try addUsed(arena, &earlier, &calls);
    try testing.expectEqual(@as(usize, 4), used.len);
    try testing.expectEqual(@as(usize, 2), used[0].calls);
    try testing.expectEqual(@as(usize, 9), used[0].last_tool);
    try testing.expectEqualStrings("mcp_linear_list_issues", used[1].name);
    try testing.expectEqual(@as(usize, 2), used[1].calls);
    try testing.expectEqual(@as(usize, 8), used[1].first_tool);
    try testing.expectEqual(@as(usize, 11), used[1].last_tool);
    try testing.expectEqualStrings("mcp_features linear resource_read", used[2].name);
    try testing.expectEqual(checkpoint.Used.Kind.skill, used[3].kind);
    try testing.expectEqualStrings("skill:ab:4/zig references/io.md", used[3].name);
}

test "sentences that may set rules are found in the user's messages, with what a short one refers to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]Message{
        .{ .turn = 2, .text = "Before you start, some rules for this whole task: use only the Python standard library, no third-party packages. Never modify anything under src/, the tool only reads it. Say OK." },
        .{ .turn = 5, .text = "Add an evaluator for integer literals. Never use eval() or exec() for this. Add tests and run them." },
        .{ .turn = 7, .text = "so don't do fix 3 ?\n```\nnever run this in production\n```\n\u{2503} it never resolves custom themes\n> only quoted text" },
        .{ .turn = 22, .text = "What about a --diff option that compares the limits against another git revision? Actually no, that's too complex for now. Don\u{2019}t build it." },
        .{ .turn = 23, .text = "Write the README in under 30 lines." },
        .{ .turn = 24, .text = "Never modify anything under src/, the tool only reads it." },
        .{ .turn = 0, .text = "Keep going, but don't touch the tests.", .in_progress = true },
    };
    const found = try candidates(arena, &messages, &.{});
    const expected = [_]Candidate{
        .{ .turn = 2, .text = "Before you start, some rules for this whole task: use only the Python standard library, no third-party packages." },
        .{ .turn = 2, .text = "Never modify anything under src/, the tool only reads it." },
        .{ .turn = 5, .text = "Never use eval() or exec() for this." },
        .{ .turn = 22, .text = "What about a --diff option that compares the limits against another git revision? Actually no, that's too complex for now. Don\u{2019}t build it." },
        .{ .turn = 23, .text = "Write the README in under 30 lines." },
        .{ .turn = 0, .text = "Keep going, but don't touch the tests.", .in_progress = true },
    };
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| {
        try testing.expectEqual(want.turn, got.turn);
        try testing.expectEqual(want.in_progress, got.in_progress);
        try testing.expectEqualStrings(want.text, got.text);
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try writeCandidates(testing.allocator, &text, found[1..2], true);
    try writeCandidates(testing.allocator, &text, found[5..], true);
    try testing.expect(std.mem.find(u8, text.items, "File each one that still applies under Rules") != null);
    try testing.expect(std.mem.find(u8, text.items, "- M2: \"Never modify anything under src/, the tool only reads it.\"\n") != null);
    try testing.expect(std.mem.find(u8, text.items, "- turn in progress: \"Keep going, but don't touch the tests.\"\n") != null);

    // A sentence a rule already quotes is not offered again; only rules
    // count, not a fact that happens to quote it.
    const filed = [_]checkpoint.Entry{
        .{ .id = "R1", .text = "R1 (turn in progress): \u{201C}Keep going, but don't touch the tests.\u{201D}" },
        .{ .id = "F2", .text = "F2 (M5): the user said \"Never use eval() or exec() for this.\"" },
    };
    const later = [_]Message{ messages[1], messages[6] };
    const unfiled = try candidates(arena, &later, &filed);
    try testing.expectEqual(@as(usize, 1), unfiled.len);
    try testing.expectEqualStrings("Never use eval() or exec() for this.", unfiled[0].text);
}

test "the request asks only for the new turns and numbers entries after the highest" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    const entries = [_]checkpoint.Entry{
        .{ .id = "R2", .text = "R2 (M1): \"x\"" },
        .{ .id = "F7", .text = "F7 (T3): y" },
        .{ .id = "S1", .text = "S1 (M2): z" },
    };
    const turns = [_]Heading{ .{ .number = 4, .first_tool = 10, .last_tool = 19 }, .{ .number = 5 }, .{ .number = 9, .first_tool = 20, .last_tool = 20 } };
    try writeRequest(testing.allocator, &text, .{ .turns = &turns, .open = .{ .number = 0, .first_tool = 21, .last_tool = 23 }, .highest = checkpoint.highestIds(.{ .entries = &entries }), .saved = true });
    const headings = "without skipping any, each followed by its notes:\n\nTurn 4 (T10\u{2013}T19)\nTurn 5 (no tool calls)\nTurn 9 (T20)\nTurn in progress (T21\u{2013}T23)\n\nUnder each heading:\nIn between:";
    for ([_][]const u8{ headings, "`T<number>:`", "For the turn in progress", "\nRules:\n", "\nFacts:\n", "\nDecisions:\n", "\nStatus:\n", "\nOpen:\n", "like M<number>", "which ones are worth opening" }) |part| {
        try testing.expect(std.mem.find(u8, text.items, part) != null);
    }
    try testing.expect(std.mem.find(u8, text.items, " The highest IDs so far: R2, F7, S1. Number new entries after them.") != null);
    // A status closes an open entry the turns answered or finished, which
    // otherwise stays in force for good.
    try testing.expect(std.mem.find(u8, text.items, "or answers or finishes an earlier open entry, end with \"replaces\" and that entry's ID.") != null);
    // No example ID the model could copy as a real one.
    for ([_][]const u8{ "T40", "M2", "replaces D", "replaces S" }) |example| try testing.expect(std.mem.find(u8, text.items, example) == null);
    text.clearRetainingCapacity();
    try writeRequest(testing.allocator, &text, .{ .saved = false });
    try testing.expect(std.mem.find(u8, text.items, " Number each kind from 1.") != null);
    try testing.expect(std.mem.find(u8, text.items, "will not be available later") != null);
    try testing.expect(std.mem.find(u8, text.items, "in progress") == null);
    try testing.expect(std.mem.find(u8, text.items, "Under each heading") == null);
}

test "a heading counts with its tool calls or a title after it, but not inside a sentence" {
    for ([_][]const u8{ "Turn 12", "[Turn 12]:", "Turn 12 (T40\u{2013}T45)", "Turn 12: fixing the loader", "Turn 12 \u{2013} fixing the loader", "Turn 12 - build" }) |line| {
        try testing.expectEqual(@as(?usize, 12), turnNumber(line));
    }
    try testing.expectEqual(@as(?usize, 0), turnNumber("Turn in progress (T50\u{2013}T52)"));
    for ([_][]const u8{ "Turn 12 was slow", "Turn 12a", "Turn in progressive", "Turn 0", "Turns 1 to 3" }) |line| {
        try testing.expectEqual(@as(?usize, null), turnNumber(line));
    }
}
