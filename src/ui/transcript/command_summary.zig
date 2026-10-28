//! A shell command as a person reads it in a tool row (D290). A command
//! that only reads, lists or searches files reads as what it did: "Read
//! markdown.ts:1-120", "Searched "table" in markdown.ts", "Listed
//! ~/code/proto". Any other command keeps its text, without the noise that
//! says nothing about what it does: a leading `cd X &&`, `2>/dev/null`.
//!
//! This follows codex's command parser (codex-rs parse_command.rs): split
//! the command at `&&`, `||`, `;` and `|`, follow `cd` into the paths after
//! it, drop formatting helpers in a pipe such as `head -n 40` or `wc -l`,
//! and name what each remaining part reads. A part it cannot name, a
//! substitution, a redirect into a file, or anything that writes makes the
//! whole command ordinary.
//!
//! Presentation only: nothing here decides what runs, what is reviewed or
//! what is allowed.
const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    read,
    list,
    search,

    /// The verb a settled row uses.
    pub fn past(self: Kind) []const u8 {
        return switch (self) {
            .read => "Read",
            .list => "Listed",
            .search => "Searched",
        };
    }

    /// The verb a running row uses.
    pub fn present(self: Kind) []const u8 {
        return switch (self) {
            .read => "Reading",
            .list => "Listing",
            .search => "Searching",
        };
    }
};

pub const Action = struct {
    kind: Kind,
    /// What it acted on: "markdown.ts:1-120", "\"table\" in markdown.ts",
    /// "~/code/proto".
    target: []const u8,
};

/// Names a read lists before "+N".
const max_names = 3;

// ---- tokens ------------------------------------------------------------------

const Token = struct {
    /// The word with its quotes removed, or the operator.
    text: []const u8,
    op: bool = false,
};

/// Redirections that only hide output; they say nothing about the command.
fn isQuietRedirect(word: []const u8) bool {
    const quiet = [_][]const u8{ "2>/dev/null", ">/dev/null", "1>/dev/null", "&>/dev/null", "2>&1", ">&2", "1>&2" };
    for (quiet) |form| if (std.mem.eql(u8, word, form)) return true;
    return false;
}

/// Splits `command` into words and operators, quotes removed. Null when the
/// command has a form a reader cannot name without running a shell:
/// substitutions, variables, redirects into files, here-documents, groups,
/// background jobs or an open quote.
fn tokenize(arena: Allocator, command: []const u8) !?[]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var index: usize = 0;
    while (index < command.len) {
        const c = command[index];
        switch (c) {
            ' ', '\t' => {
                if (in_word) try finishWord(arena, &tokens, &word, &in_word);
                index += 1;
            },
            '\n', ';' => {
                if (in_word) try finishWord(arena, &tokens, &word, &in_word);
                try tokens.append(arena, .{ .text = ";", .op = true });
                index += 1;
            },
            '&', '|' => {
                const doubled = index + 1 < command.len and command[index + 1] == c;
                // `2>&1` and `&>/dev/null` are words; a lone `&` backgrounds.
                if (c == '&' and !doubled) {
                    const glued = in_word and word.items.len > 0 and word.items[word.items.len - 1] == '>';
                    const leads = index + 1 < command.len and command[index + 1] == '>';
                    if (!glued and !leads) return null;
                    try word.append(arena, c);
                    in_word = true;
                    index += 1;
                    continue;
                }
                if (in_word) try finishWord(arena, &tokens, &word, &in_word);
                try tokens.append(arena, .{ .text = if (doubled) (if (c == '&') "&&" else "||") else "|", .op = true });
                index += if (doubled) 2 else 1;
            },
            '\'' => {
                const end = std.mem.findScalarPos(u8, command, index + 1, '\'') orelse return null;
                try word.appendSlice(arena, command[index + 1 .. end]);
                in_word = true;
                index = end + 1;
            },
            '"' => {
                var cursor = index + 1;
                while (cursor < command.len and command[cursor] != '"') : (cursor += 1) {
                    const inner = command[cursor];
                    if (inner == '$' or inner == '`') return null;
                    if (inner == '\\' and cursor + 1 < command.len) {
                        cursor += 1;
                        try word.append(arena, command[cursor]);
                        continue;
                    }
                    try word.append(arena, inner);
                }
                if (cursor >= command.len) return null;
                in_word = true;
                index = cursor + 1;
            },
            '\\' => {
                if (index + 1 >= command.len) return null;
                try word.append(arena, command[index + 1]);
                in_word = true;
                index += 2;
            },
            '$', '`', '(', ')', '{', '}', '<' => return null,
            else => {
                try word.append(arena, c);
                in_word = true;
                index += 1;
            },
        }
    }
    if (in_word) try finishWord(arena, &tokens, &word, &in_word);
    return tokens.items;
}

fn finishWord(arena: Allocator, tokens: *std.ArrayList(Token), word: *std.ArrayList(u8), in_word: *bool) !void {
    const text = try arena.dupe(u8, word.items);
    word.clearRetainingCapacity();
    in_word.* = false;
    if (isQuietRedirect(text)) return;
    try tokens.append(arena, .{ .text = text });
}

const Part = struct {
    words: []const Token,
    /// The part reads what the previous part printed.
    piped: bool,
};

fn splitParts(arena: Allocator, tokens: []const Token) !?[]Part {
    var parts: std.ArrayList(Part) = .empty;
    var start: usize = 0;
    var piped = false;
    for (tokens, 0..) |token, index| {
        if (!token.op) {
            // A redirect into a file writes it.
            if (std.mem.findScalar(u8, token.text, '>') != null) return null;
            continue;
        }
        if (index > start) try parts.append(arena, .{ .words = tokens[start..index], .piped = piped });
        piped = std.mem.eql(u8, token.text, "|");
        start = index + 1;
    }
    if (tokens.len > start) try parts.append(arena, .{ .words = tokens[start..], .piped = piped });
    return parts.items;
}

// ---- reading ---------------------------------------------------------------------

/// What `command` reads, lists and searches, in order. Null when any part
/// of it does something else.
pub fn explore(arena: Allocator, command: []const u8) !?[]Action {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;
    const tokens = (try tokenize(arena, trimmed)) orelse return null;
    const parts = (try splitParts(arena, tokens)) orelse return null;
    var actions: std.ArrayList(Action) = .empty;
    var cwd: ?[]const u8 = null;
    for (parts) |part| {
        const head = part.words[0].text;
        const args = part.words[1..];
        if (std.mem.eql(u8, head, "cd")) {
            const target = cdTarget(args) orelse return null;
            cwd = try joinPath(arena, cwd, target);
            continue;
        }
        if (isOneOf(head, &.{ "true", "echo", "printf", "pwd" })) continue;
        if (part.piped and isFormatter(part.words)) continue;
        const action = (try summarize(arena, head, args, cwd)) orelse return null;
        try actions.append(arena, action);
    }
    if (actions.items.len == 0) return null;
    return actions.items;
}

fn isOneOf(value: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn cdTarget(args: []const Token) ?[]const u8 {
    var target: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg.text, "-") and arg.text.len > 1) continue;
        if (target != null) return null;
        target = arg.text;
    }
    return target orelse "~";
}

fn joinPath(arena: Allocator, base: ?[]const u8, path: []const u8) ![]const u8 {
    const root = base orelse return path;
    if (std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "~")) return path;
    if (std.mem.eql(u8, path, ".")) return root;
    const rest = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    return arena.print("{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), rest });
}

/// A file's name as a row lists it: its last part.
fn shortName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    return std.Io.Dir.path.basename(trimmed);
}

/// A helper in a pipe that only shapes what came before it. It may not
/// name a file of its own.
fn isFormatter(words: []const Token) bool {
    const head = words[0].text;
    if (isOneOf(head, &.{ "wc", "sort", "uniq", "cut", "tr", "column", "nl", "cat", "less", "more" })) {
        for (words[1..]) |word| {
            if (!std.mem.startsWith(u8, word.text, "-") and !isDigits(word.text)) {
                // `cut -d : -f 1` and `tr a b` take operands that are not files.
                if (isOneOf(head, &.{ "cut", "tr", "sort", "column" })) continue;
                return false;
            }
        }
        return true;
    }
    if (isOneOf(head, &.{ "head", "tail" })) {
        var index: usize = 1;
        while (index < words.len) : (index += 1) {
            const word = words[index].text;
            if (isOneOf(word, &.{ "-n", "-c" })) {
                index += 1;
                continue;
            }
            if (!std.mem.startsWith(u8, word, "-")) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, head, "grep") or std.mem.eql(u8, head, "rg")) {
        // A filter over piped output: only a pattern, no files.
        var free_words: usize = 0;
        for (words[1..]) |word| {
            if (!std.mem.startsWith(u8, word.text, "-")) free_words += 1;
        }
        return free_words <= 1;
    }
    if (std.mem.eql(u8, head, "sed")) return sedInPlace(words[1..]) == false and sedReadPath(words[1..]) == null;
    if (std.mem.eql(u8, head, "awk")) return awkFile(words[1..]) == null;
    return false;
}

fn summarize(arena: Allocator, head: []const u8, args: []const Token, cwd: ?[]const u8) !?Action {
    if (isOneOf(head, &.{ "ls", "eza", "exa", "tree", "du" })) {
        const path = firstOperand(args, &.{ "-I", "-w", "-L", "-P", "-d", "--ignore-glob", "--color", "--sort", "--time-style", "--max-depth", "-B" });
        return .{ .kind = .list, .target = try listTarget(arena, cwd, path) };
    }
    if (std.mem.eql(u8, head, "rg")) {
        if (hasFlag(args, "--files")) return .{ .kind = .list, .target = try listTarget(arena, cwd, firstOperand(args, &rg_value_flags)) };
        if (hasAnyFlag(args, &.{ "--replace", "-r", "--pre" })) return null;
        return search(arena, operands(arena, args, &rg_value_flags), cwd);
    }
    if (isOneOf(head, &.{ "grep", "egrep", "fgrep" })) return grepLike(arena, args, cwd);
    if (std.mem.eql(u8, head, "git")) {
        if (args.len == 0) return null;
        if (std.mem.eql(u8, args[0].text, "grep")) return grepLike(arena, args[1..], cwd);
        if (std.mem.eql(u8, args[0].text, "ls-files")) return .{ .kind = .list, .target = try listTarget(arena, cwd, firstOperand(args[1..], &.{})) };
        return null;
    }
    if (isOneOf(head, &.{ "ag", "ack" })) return search(arena, operands(arena, args, &.{ "-G", "-g", "--ignore-dir" }), cwd);
    if (std.mem.eql(u8, head, "fd")) {
        const found = operands(arena, args, &.{ "-t", "--type", "-e", "--extension", "-E", "--exclude", "-d", "--max-depth" });
        if (hasAnyFlag(args, &.{ "-x", "--exec", "-X", "--exec-batch" })) return null;
        if (found.len == 0) return .{ .kind = .list, .target = try listTarget(arena, cwd, null) };
        if (found.len == 1 and std.mem.findScalar(u8, found[0], '/') != null) return .{ .kind = .list, .target = try listTarget(arena, cwd, found[0]) };
        return try searchIn(arena, found[0], if (found.len > 1) found[1] else null, cwd);
    }
    if (std.mem.eql(u8, head, "find")) return findLike(arena, args, cwd);
    if (isOneOf(head, &.{ "cat", "bat", "batcat", "less", "more" })) {
        const files = operands(arena, args, &.{ "--theme", "--language", "-l", "--style", "--line-range", "-r" });
        if (files.len == 0) return null;
        return try readOf(arena, files, null);
    }
    if (std.mem.eql(u8, head, "nl")) {
        const files = operands(arena, args, &.{ "-s", "-w", "-v", "-i", "-b" });
        if (files.len != 1) return null;
        return try readOf(arena, files, null);
    }
    if (isOneOf(head, &.{ "head", "tail" })) return headTail(arena, head, args);
    if (std.mem.eql(u8, head, "sed")) {
        if (sedInPlace(args)) return null;
        const read = sedReadPath(args) orelse return null;
        const range = if (read.range) |value| try std.mem.replaceOwned(u8, arena, value, ",", "-") else null;
        return try readOf(arena, &.{read.path}, range);
    }
    if (std.mem.eql(u8, head, "awk")) {
        const file = awkFile(args) orelse return null;
        return try readOf(arena, &.{file}, null);
    }
    if (std.mem.eql(u8, head, "wc")) {
        const files = operands(arena, args, &.{});
        if (files.len == 0) return null;
        return try readOf(arena, files, null);
    }
    return null;
}

const rg_value_flags = [_][]const u8{ "-g", "--glob", "--iglob", "-t", "--type", "--type-not", "-T", "-m", "--max-count", "-A", "-B", "-C", "--context", "--max-depth", "-e", "--regexp" };

fn hasFlag(args: []const Token, flag: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg.text, flag)) return true;
    return false;
}

fn hasAnyFlag(args: []const Token, comptime flags: []const []const u8) bool {
    for (args) |arg| {
        inline for (flags) |flag| {
            if (std.mem.eql(u8, arg.text, flag) or (flag.len > 2 and std.mem.startsWith(u8, arg.text, flag ++ "="))) return true;
        }
    }
    return false;
}

/// The words that are not flags or a flag's value.
fn operands(arena: Allocator, args: []const Token, value_flags: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var skip = false;
    var rest = false;
    for (args) |arg| {
        if (skip) {
            skip = false;
            continue;
        }
        if (rest) {
            out.append(arena, arg.text) catch return out.items;
            continue;
        }
        if (std.mem.eql(u8, arg.text, "--")) {
            rest = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg.text, "-") and arg.text.len > 1) {
            for (value_flags) |flag| {
                if (std.mem.eql(u8, arg.text, flag)) skip = true;
            }
            continue;
        }
        out.append(arena, arg.text) catch return out.items;
    }
    return out.items;
}

fn firstOperand(args: []const Token, value_flags: []const []const u8) ?[]const u8 {
    var skip = false;
    for (args) |arg| {
        if (skip) {
            skip = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg.text, "-") and arg.text.len > 1) {
            for (value_flags) |flag| {
                if (std.mem.eql(u8, arg.text, flag)) skip = true;
            }
            continue;
        }
        return arg.text;
    }
    return null;
}

fn listTarget(arena: Allocator, cwd: ?[]const u8, path: ?[]const u8) ![]const u8 {
    const joined = if (path) |value| try joinPath(arena, cwd, value) else cwd orelse ".";
    return std.mem.trimEnd(u8, joined, "/");
}

fn search(arena: Allocator, found: []const []const u8, cwd: ?[]const u8) !?Action {
    if (found.len == 0) return null;
    return try searchIn(arena, found[0], if (found.len > 1) found[1] else null, cwd);
}

fn searchIn(arena: Allocator, query: []const u8, path: ?[]const u8, cwd: ?[]const u8) !Action {
    const place = path orelse cwd;
    const target = if (place) |value|
        try arena.print("\"{s}\" in {s}", .{ query, shortName(value) })
    else
        try arena.print("\"{s}\"", .{query});
    return .{ .kind = .search, .target = target };
}

fn grepLike(arena: Allocator, args: []const Token, cwd: ?[]const u8) !?Action {
    var pattern: ?[]const u8 = null;
    var found: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index].text;
        if (isOneOf(arg, &.{ "-e", "--regexp", "-f", "--file" })) {
            index += 1;
            if (index < args.len and pattern == null) pattern = args[index].text;
            continue;
        }
        if (isOneOf(arg, &.{ "-m", "--max-count", "-C", "--context", "-A", "-B", "--include", "--exclude", "--exclude-dir" })) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) continue;
        try found.append(arena, arg);
    }
    if (pattern) |value| {
        return try searchIn(arena, value, if (found.items.len > 0) found.items[0] else null, cwd);
    }
    return search(arena, found.items, cwd);
}

fn findLike(arena: Allocator, args: []const Token, cwd: ?[]const u8) !?Action {
    var path: ?[]const u8 = null;
    var query: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index].text;
        // These run programs or write files.
        if (isOneOf(arg, &.{ "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls" })) return null;
        if (isOneOf(arg, &.{ "-name", "-iname", "-path", "-ipath", "-regex", "-iregex" })) {
            index += 1;
            if (index < args.len and query == null) query = args[index].text;
            continue;
        }
        if (path == null and !std.mem.startsWith(u8, arg, "-") and !isOneOf(arg, &.{ "!", "(", ")" })) path = arg;
    }
    if (query) |value| return try searchIn(arena, value, path, cwd);
    return .{ .kind = .list, .target = try listTarget(arena, cwd, path) };
}

fn readOf(arena: Allocator, files: []const []const u8, range: ?[]const u8) !Action {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (files[0..@min(files.len, max_names)], 0..) |file, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(shortName(file));
    }
    if (files.len > max_names) try out.writer.print(", +{d}", .{files.len - max_names});
    if (range) |value| if (files.len == 1) try out.writer.print(":{s}", .{value});
    return .{ .kind = .read, .target = out.written() };
}

fn headTail(arena: Allocator, head: []const u8, args: []const Token) !?Action {
    var count: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index].text;
        if (isOneOf(arg, &.{ "-n", "-c" })) {
            index += 1;
            if (index < args.len and std.mem.eql(u8, arg, "-n")) count = args[index].text;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-n") and arg.len > 2) {
            count = arg[2..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            if (isDigits(arg[1..])) count = arg[1..];
            continue;
        }
        try files.append(arena, arg);
    }
    if (files.items.len == 0) return null;
    const range = if (std.mem.eql(u8, head, "head") and count != null and isDigits(count.?)) try arena.print("1-{s}", .{count.?}) else null;
    return try readOf(arena, files.items, range);
}

fn sedInPlace(args: []const Token) bool {
    for (args) |arg| {
        const text = arg.text;
        if (std.mem.startsWith(u8, text, "--in-place")) return true;
        if (text.len > 1 and text[0] == '-' and text[1] != '-' and std.mem.findScalar(u8, text, 'i') != null) return true;
    }
    return false;
}

const SedRead = struct { path: []const u8, range: ?[]const u8 };

/// `sed -n '10,40p' file`: the file and its lines, "10-40".
fn sedReadPath(args: []const Token) ?SedRead {
    if (!hasFlag(args, "-n")) return null;
    var script: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index].text;
        if (isOneOf(arg, &.{ "-e", "--expression" })) {
            index += 1;
            if (index < args.len) script = args[index].text;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (script == null) {
            script = arg;
            continue;
        }
        if (path != null) return null;
        path = arg;
    }
    const range = sedRange(script orelse return null) orelse return null;
    return .{ .path = path orelse return null, .range = range };
}

/// "10,40p" as "10-40", "7p" as "7"; null for any other script.
fn sedRange(script: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, script, "p")) return null;
    const core = script[0 .. script.len - 1];
    if (std.mem.findScalar(u8, core, ',')) |comma| {
        if (!isDigits(core[0..comma]) or !isDigits(core[comma + 1 ..])) return null;
        return core;
    }
    return if (isDigits(core)) core else null;
}

fn awkFile(args: []const Token) ?[]const u8 {
    var program_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index].text;
        if (isOneOf(arg, &.{ "-F", "-v", "-f" })) {
            if (std.mem.eql(u8, arg, "-f")) program_seen = true;
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (!program_seen) {
            // An awk program that writes or runs is not a read.
            if (std.mem.findAny(u8, arg, ">|") != null or std.mem.find(u8, arg, "system") != null) return null;
            program_seen = true;
            continue;
        }
        return arg;
    }
    return null;
}

// ---- display ---------------------------------------------------------------------

/// The actions as one phrase: "Read a.ts, b.ts · Searched "x" in c.ts".
/// Adjacent actions of one kind share their verb.
pub fn phrase(arena: Allocator, actions: []const Action, running: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeActions(&out.writer, actions, running);
    return out.written();
}

pub fn writeActions(writer: *std.Io.Writer, actions: []const Action, running: bool) !void {
    var previous: ?Kind = null;
    for (actions) |action| {
        if (previous == action.kind) {
            try writer.writeAll(", ");
        } else {
            if (previous != null) try writer.writeAll(" · ");
            try writer.writeAll(if (running) action.kind.present() else action.kind.past());
            try writer.writeByte(' ');
        }
        try writer.writeAll(action.target);
        previous = action.kind;
    }
}

/// The first line of `command` without what says nothing about it: a
/// leading `cd X &&`, quiet redirects and a trailing `|| true`. Returns
/// `command`'s own first line when there is nothing to drop.
pub fn clean(arena: Allocator, command: []const u8) ![]const u8 {
    const line = std.mem.trim(u8, command[0 .. std.mem.findScalar(u8, command, '\n') orelse command.len], " \t\r");
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
        if (index >= line.len) break;
        const start = index;
        while (index < line.len and line[index] != ' ' and line[index] != '\t') {
            const c = line[index];
            if (c == '\'' or c == '"') {
                index = std.mem.findScalarPos(u8, line, index + 1, c) orelse line.len - 1;
            } else if (c == '\\') {
                index += 1;
            }
            index += 1;
        }
        try words.append(arena, line[start..@min(index, line.len)]);
    }
    var kept: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    // `cd X &&` or `cd X;` before the command it leads to.
    while (at + 2 < words.items.len and std.mem.eql(u8, words.items[at], "cd")) {
        const target = words.items[at + 1];
        if (std.mem.endsWith(u8, target, ";") and target.len > 1) {
            at += 2;
            continue;
        }
        var joiner = at + 2;
        while (joiner < words.items.len and isQuietRedirect(std.mem.trimEnd(u8, words.items[joiner], ";"))) {
            if (std.mem.endsWith(u8, words.items[joiner], ";")) break;
            joiner += 1;
        }
        if (joiner >= words.items.len) break;
        const word = words.items[joiner];
        if (std.mem.endsWith(u8, word, ";") and isQuietRedirect(word[0 .. word.len - 1])) {
            if (joiner + 1 >= words.items.len) break;
            at = joiner + 1;
            continue;
        }
        if (!isOneOf(word, &.{ "&&", ";" }) or joiner + 1 >= words.items.len) break;
        at = joiner + 1;
    }
    for (words.items[at..]) |word| {
        if (isQuietRedirect(word)) continue;
        if (isQuietRedirect(std.mem.trimEnd(u8, word, ";"))) {
            if (kept.items.len > 0) kept.items[kept.items.len - 1] = try arena.print("{s};", .{kept.items[kept.items.len - 1]});
            continue;
        }
        try kept.append(arena, word);
    }
    if (kept.items.len >= 2 and std.mem.eql(u8, kept.items[kept.items.len - 1], "true") and std.mem.eql(u8, kept.items[kept.items.len - 2], "||")) {
        kept.items.len -= 2;
    }
    if (kept.items.len == 0) return line;
    const joined = try std.mem.join(arena, " ", kept.items);
    return if (std.mem.eql(u8, joined, line)) line else joined;
}

/// `text` cut to `width` columns at a word boundary, ending in " …". Falls
/// back to a cut inside a word only when the first word alone is too wide.
/// Plain text only.
pub fn clipAtWord(arena: Allocator, text: []const u8, width: usize) ![]const u8 {
    if (display_width.visibleWidth(text) <= width) return text;
    if (width < 2) return "…";
    var best: ?usize = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != ' ') continue;
        const head = std.mem.trimEnd(u8, text[0..index], " ");
        if (head.len == 0) continue;
        if (display_width.visibleWidth(head) + 2 > width) break;
        best = head.len;
    }
    const cut = best orelse {
        const prefix = display_width.prefixByWidth(text, width - 1);
        return arena.print("{s}…", .{prefix});
    };
    // A cut that keeps less than half the room reads worse than a mid-word one.
    if (display_width.visibleWidth(text[0..cut]) * 2 < width) {
        const prefix = display_width.prefixByWidth(text, width - 1);
        return arena.print("{s}…", .{prefix});
    }
    return arena.print("{s} …", .{text[0..cut]});
}

// ---- tests -----------------------------------------------------------------

fn expectExplore(command: []const u8, expected: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const actions = try explore(arena, command);
    if (expected) |want| {
        const got = actions orelse return error.TestExpectedExplore;
        try std.testing.expectEqualStrings(want, try phrase(arena, got, false));
    } else if (actions) |got| {
        std.debug.print("unexpected explore: {s}\n", .{try phrase(arena, got, false)});
        return error.TestUnexpectedExplore;
    }
}

test "standard reads, lists and searches read as what they did" {
    try expectExplore("cd ~/code/proto && sed -n '1,120p' packages/coding-agent/src/modes/components/assistant-message.ts", "Read assistant-message.ts:1-120");
    try expectExplore("cd ~/code/proto && grep -n \"table\" packages/tui/src/components/markdown.ts | head -60", "Searched \"table\" in markdown.ts");
    try expectExplore("ls -la ~/code/proto 2>/dev/null", "Listed ~/code/proto");
    try expectExplore("cd ~/code/proto && ls", "Listed ~/code/proto");
    try expectExplore("cat ~/code/proto/package.json | head -40", "Read package.json");
    try expectExplore("head -n 50 src/main.zig", "Read main.zig:1-50");
    try expectExplore("nl -ba src/a.zig | sed -n '10,40p'", "Read a.zig");
    try expectExplore("rg -n \"renderMarkdown\" ~/code/proto/packages/tui/src | head -20", "Searched \"renderMarkdown\" in src");
    try expectExplore("rg --files src | head", "Listed src");
    try expectExplore("find packages/tui/src -name '*.ts' | head -20", "Searched \"*.ts\" in src");
    try expectExplore("fd markdown packages", "Searched \"markdown\" in packages");
    try expectExplore("cd ~/code/proto && wc -l packages/tui/src/components/markdown.ts 2>/dev/null; find packages/tui/src -name '*.ts' | head -20", "Read markdown.ts · Searched \"*.ts\" in src");
    try expectExplore("cat a.ts && cat b.ts", "Read a.ts, b.ts");
    try expectExplore("git grep -n foo -- lib", "Searched \"foo\" in lib");
    try expectExplore("grep -rn \"getMarkdownTheme\" packages/coding-agent/src --include=\"*.ts\" | head -20", "Searched \"getMarkdownTheme\" in src");
    try expectExplore("ls src || true", "Listed src");
}

test "anything that is not a plain read keeps its command" {
    try expectExplore("cd ~/code/proto 2>/dev/null && git log --oneline -3 && du -sh packages", null);
    try expectExplore("python3 - <<'PY'\nprint(1)\nPY", null);
    try expectExplore("sed -i 's/a/b/' file.txt", null);
    try expectExplore("sed -n '1,10p' a.txt > out.txt", null);
    try expectExplore("cat $(ls)", null);
    try expectExplore("find . -name '*.tmp' -delete", null);
    try expectExplore("find . -exec rm {} ;", null);
    try expectExplore("rg foo --replace bar", null);
    try expectExplore("npm test", null);
    try expectExplore("cat a.txt | sh", null);
    try expectExplore("cat a &", null);
    try expectExplore("awk '{print > \"x\"}' f", null);
    try expectExplore("cat \"$HOME/x\"", null);
    try expectExplore("", null);
}

test "a command's summary drops a leading cd and quiet redirects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("git log --oneline -3 && du -sh packages", try clean(arena, "cd ~/code/proto 2>/dev/null && git log --oneline -3 && du -sh packages"));
    try std.testing.expectEqualStrings("wc -l a.ts; find pack -name '*.ts'", try clean(arena, "cd ~/code/proto && wc -l a.ts 2>/dev/null; find pack -name '*.ts'"));
    try std.testing.expectEqualStrings("npm test", try clean(arena, "npm test || true"));
    try std.testing.expectEqualStrings("echo 'a  b'", try clean(arena, "echo 'a  b'"));
    try std.testing.expectEqualStrings("cd x", try clean(arena, "cd x"));
    try std.testing.expectEqualStrings("make", try clean(arena, "cd a; make"));
}

test "long commands clip at a word boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("git log --oneline …", try clipAtWord(arena, "git log --oneline -3 && du -sh packages", 21));
    try std.testing.expectEqualStrings("short", try clipAtWord(arena, "short", 10));
    try std.testing.expectEqualStrings("abcdefghi…", try clipAtWord(arena, "abcdefghijklmnop qr", 10));
}
