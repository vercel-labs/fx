//! Program text a shell command hands to an interpreter or writes to a file.
//!
//! `python -c '...'`, `python - <<EOF`, `node -e '...'` and `node <<EOF`
//! are code cells; `cat > f.ts <<EOF` and `tee f.ts <<EOF` are file writes
//! whose body is source in the target's language. Rules match those bodies
//! with the right language, so a TypeScript rule sees TypeScript a command
//! writes. The scan is lexical and tolerates a command still streaming: an
//! open quote or heredoc runs to the end. proto-fx runs no shell Python in a
//! kernel, so every cell reports `kernel = false`.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Language = enum { python, js };

pub const Cell = struct { language: Language, start: usize, end: usize, kernel: bool = false };

pub const Write = struct { path: []const u8, start: usize, end: usize };

pub const Scan = struct {
    cells: []Cell,
    writes: []Write,
};

const Word = struct {
    /// Unquoted text, from the arena.
    text: []const u8,
    /// Bytes between the quotes of a fully quoted word, else the raw word.
    inner_start: usize,
    inner_end: usize,
};

const Heredoc = struct { delimiter: []const u8, strip_tabs: bool, command: usize };

const Command = struct {
    words: std.ArrayList(Word) = .empty,
    heredoc_body: ?[2]usize = null,
};

/// Scans `command`. Memory comes from `arena`.
pub fn scan(arena: Allocator, command: []const u8) !Scan {
    var commands: std.ArrayList(Command) = .empty;
    var pending: std.ArrayList(Heredoc) = .empty;
    try commands.append(arena, .{});
    var pos: usize = 0;
    while (pos < command.len) {
        const c = command[pos];
        switch (c) {
            ' ', '\t', '\r' => pos += 1,
            '\n' => {
                pos += 1;
                for (pending.items) |doc| pos = readBody(command, pos, doc, &commands.items[doc.command]);
                pending.clearRetainingCapacity();
                try commands.append(arena, .{});
            },
            ';', '&', '|', '(', ')' => {
                pos += 1;
                if (commands.items[commands.items.len - 1].words.items.len > 0) try commands.append(arena, .{});
            },
            '#' => {
                const word_count = commands.items[commands.items.len - 1].words.items.len;
                if (word_count == 0 or pos == 0 or std.ascii.isWhitespace(command[pos - 1])) {
                    pos = std.mem.findScalarPos(u8, command, pos, '\n') orelse command.len;
                } else pos = try readWord(arena, command, pos, &commands.items[commands.items.len - 1]);
            },
            '<' => {
                if (std.mem.startsWith(u8, command[pos..], "<<") and !std.mem.startsWith(u8, command[pos..], "<<<")) {
                    pos += 2;
                    var strip = false;
                    if (pos < command.len and command[pos] == '-') {
                        strip = true;
                        pos += 1;
                    }
                    while (pos < command.len and (command[pos] == ' ' or command[pos] == '\t')) pos += 1;
                    var scratch: Command = .{};
                    pos = try readWord(arena, command, pos, &scratch);
                    if (scratch.words.items.len == 1) {
                        try pending.append(arena, .{ .delimiter = scratch.words.items[0].text, .strip_tabs = strip, .command = commands.items.len - 1 });
                        try commands.items[commands.items.len - 1].words.append(arena, .{ .text = "<<", .inner_start = pos, .inner_end = pos });
                    }
                } else pos = try readWord(arena, command, pos, &commands.items[commands.items.len - 1]);
            },
            else => pos = try readWord(arena, command, pos, &commands.items[commands.items.len - 1]),
        }
    }
    // A heredoc whose body has not streamed in yet is empty; a body that
    // has started runs to the end of the text.
    var cells: std.ArrayList(Cell) = .empty;
    var writes: std.ArrayList(Write) = .empty;
    for (commands.items) |entry| try classify(arena, entry, &cells, &writes);
    return .{ .cells = try cells.toOwnedSlice(arena), .writes = try writes.toOwnedSlice(arena) };
}

fn readBody(command: []const u8, start: usize, doc: Heredoc, target: *Command) usize {
    var pos = start;
    while (pos < command.len) {
        const line_end = std.mem.findScalarPos(u8, command, pos, '\n') orelse command.len;
        var line = std.mem.trimEnd(u8, command[pos..line_end], "\r");
        if (doc.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
        if (std.mem.eql(u8, line, doc.delimiter)) {
            if (target.heredoc_body == null) target.heredoc_body = .{ start, pos };
            return @min(line_end + 1, command.len);
        }
        pos = line_end + 1;
    }
    if (target.heredoc_body == null) target.heredoc_body = .{ start, command.len };
    return command.len;
}

fn readWord(arena: Allocator, command: []const u8, start: usize, target: *Command) !usize {
    var text: std.ArrayList(u8) = .empty;
    var pos = start;
    var quoted_whole: ?[2]usize = null;
    var quote_count: usize = 0;
    while (pos < command.len) {
        const c = command[pos];
        switch (c) {
            ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')' => break,
            '<' => if (pos != start) break else {
                try text.append(arena, c);
                pos += 1;
            },
            '\'', '"' => {
                quote_count += 1;
                const open = pos + 1;
                var end = open;
                while (end < command.len and command[end] != c) : (end += 1) {
                    if (c == '"' and command[end] == '\\' and end + 1 < command.len) {
                        end += 1;
                        try text.append(arena, command[end]);
                        continue;
                    }
                    try text.append(arena, command[end]);
                }
                if (pos == start) quoted_whole = .{ open, end };
                pos = @min(end + 1, command.len);
            },
            '\\' => {
                if (pos + 1 < command.len) try text.append(arena, command[pos + 1]);
                pos += 2;
            },
            else => {
                try text.append(arena, c);
                pos += 1;
            },
        }
    }
    pos = @min(pos, command.len);
    const whole = if (quote_count == 1 and quoted_whole != null and (quoted_whole.?[1] + 1 >= pos)) quoted_whole.? else [2]usize{ start, pos };
    try target.words.append(arena, .{ .text = text.items, .inner_start = whole[0], .inner_end = whole[1] });
    return if (pos == start) pos + 1 else pos;
}

fn basename(word: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, word, '/') orelse return word;
    return word[slash + 1 ..];
}

fn interpreter(word: []const u8) ?Language {
    const name = basename(word);
    if (std.mem.startsWith(u8, name, "python")) {
        for (name[6..]) |c| if (!std.ascii.isDigit(c) and c != '.') return null;
        return .python;
    }
    if (std.mem.eql(u8, name, "node") or std.mem.eql(u8, name, "bun") or std.mem.eql(u8, name, "deno")) return .js;
    return null;
}

const wrappers = [_][]const u8{ "sudo", "env", "time", "exec", "nice", "command" };
const runners = [_][]const u8{ "uv", "poetry", "pixi", "pipenv", "conda", "npx" };

fn classify(arena: Allocator, command: Command, cells: *std.ArrayList(Cell), writes: *std.ArrayList(Write)) !void {
    const words = command.words.items;
    var index: usize = 0;
    while (index < words.len) {
        const w = words[index].text;
        if (std.mem.findScalar(u8, w, '=') != null and w.len > 0 and w[0] != '-' and std.mem.findScalar(u8, w, '/') == null) {
            index += 1;
            continue;
        }
        var wrapped = false;
        for (wrappers) |name| if (std.mem.eql(u8, w, name)) {
            wrapped = true;
        };
        for (runners) |name| if (std.mem.eql(u8, w, name)) {
            wrapped = true;
            if (index + 1 < words.len and std.mem.eql(u8, words[index + 1].text, "run")) index += 1;
        };
        if (!wrapped) break;
        index += 1;
    }
    if (index >= words.len) return;
    const head = words[index].text;
    if (interpreter(head)) |language| {
        var arg = index + 1;
        var script = false;
        while (arg < words.len) : (arg += 1) {
            const w = words[arg].text;
            const inline_flag = (language == .python and std.mem.eql(u8, w, "-c")) or
                (language == .js and (std.mem.eql(u8, w, "-e") or std.mem.eql(u8, w, "--eval") or std.mem.eql(u8, w, "-p")));
            if (inline_flag and arg + 1 < words.len) {
                const code = words[arg + 1];
                try cells.append(arena, .{ .language = language, .start = code.inner_start, .end = code.inner_end });
                return;
            }
            if (std.mem.eql(u8, w, "<<") or std.mem.eql(u8, w, "-")) continue;
            if (w.len > 0 and w[0] == '-') continue;
            script = true;
            break;
        }
        if (!script) if (command.heredoc_body) |body| {
            try cells.append(arena, .{ .language = language, .start = body[0], .end = body[1] });
        };
        return;
    }
    const body = command.heredoc_body orelse return;
    const is_cat = std.mem.eql(u8, head, "cat");
    const is_tee = std.mem.eql(u8, head, "tee");
    if (!is_cat and !is_tee) return;
    var arg = index + 1;
    while (arg < words.len) : (arg += 1) {
        const w = words[arg].text;
        var target: ?[]const u8 = null;
        if (std.mem.eql(u8, w, ">") or std.mem.eql(u8, w, ">>")) {
            if (arg + 1 < words.len) target = words[arg + 1].text;
        } else if (std.mem.startsWith(u8, w, ">>")) {
            target = w[2..];
        } else if (std.mem.startsWith(u8, w, ">")) {
            target = w[1..];
        } else if (is_tee and w.len > 0 and w[0] != '-' and !std.mem.eql(u8, w, "<<")) {
            target = w;
        }
        if (target) |path| if (path.len > 0) {
            try writes.append(arena, .{ .path = path, .start = body[0], .end = body[1] });
            return;
        };
    }
}

test "shell scan finds interpreter cells and heredoc writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command =
        \\cd src && python3 -c 'import os; print(os.getcwd())'
        \\cat > src/app.ts <<'EOF'
        \\const a: any = 1;
        \\EOF
        \\uv run python - <<EOF
        \\print(1)
        \\EOF
        \\node -e "console.log(1)" # python -c 'x'
        \\python script.py
    ;
    const result = try scan(arena, command);
    try std.testing.expectEqual(@as(usize, 3), result.cells.len);
    try std.testing.expectEqualStrings("import os; print(os.getcwd())", command[result.cells[0].start..result.cells[0].end]);
    try std.testing.expectEqual(Language.python, result.cells[1].language);
    try std.testing.expectEqualStrings("print(1)\n", command[result.cells[1].start..result.cells[1].end]);
    try std.testing.expectEqual(Language.js, result.cells[2].language);
    try std.testing.expectEqualStrings("console.log(1)", command[result.cells[2].start..result.cells[2].end]);
    try std.testing.expectEqual(@as(usize, 1), result.writes.len);
    try std.testing.expectEqualStrings("src/app.ts", result.writes[0].path);
    try std.testing.expectEqualStrings("const a: any = 1;\n", command[result.writes[0].start..result.writes[0].end]);
}

test "shell scan tolerates a command still streaming" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const partial = "tee lib/x.rs <<EOF\nfn f() { Box::le";
    const result = try scan(arena, partial);
    try std.testing.expectEqual(@as(usize, 1), result.writes.len);
    try std.testing.expectEqualStrings("lib/x.rs", result.writes[0].path);
    try std.testing.expectEqualStrings("fn f() { Box::le", partial[result.writes[0].start..result.writes[0].end]);
    const open_quote = try scan(arena, "python -c 'import sy");
    try std.testing.expectEqualStrings("import sy", "python -c 'import sy"[open_quote.cells[0].start..open_quote.cells[0].end]);
}
