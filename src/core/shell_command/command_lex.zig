const std = @import("std");

const whitespace = " \t\r\n";

pub const LexError = error{
    EmbeddedNul,
    InvalidUtf8,
    MalformedEscape,
    UnbalancedQuote,
};

pub const PipeSegment = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub const ArgvToken = struct {
    raw: []const u8,
    value: []u8,
    start: usize,
    end: usize,
    quoted: bool = false,
};

pub const Argv = struct {
    tokens: []ArgvToken = &.{},

    pub fn deinit(self: *Argv, alloc: std.mem.Allocator) void {
        for (self.tokens) |token| alloc.free(token.value);
        alloc.free(self.tokens);
        self.* = .{};
    }
};

pub const RedirectionKind = enum {
    read_path,
    write_path,
    read_write_path,
    unsupported,
};

const ShellScan = struct {
    in_single: bool = false,
    in_double: bool = false,
    escaped: bool = false,

    fn unquoted(self: *ShellScan, input: []const u8, index: usize) LexError!?u8 {
        const ch = input[index];
        if (self.escaped) {
            self.escaped = false;
            return null;
        }
        if (ch == '\\' and !self.in_single) {
            if (index + 1 >= input.len) return error.MalformedEscape;
            self.escaped = true;
            return null;
        }
        if (ch == '\'' and !self.in_double) {
            self.in_single = !self.in_single;
            return null;
        }
        if (ch == '"' and !self.in_single) {
            self.in_double = !self.in_double;
            return null;
        }
        if (self.in_single or self.in_double) return null;
        return ch;
    }

    fn finish(self: ShellScan) LexError!void {
        if (self.escaped) return error.MalformedEscape;
        if (self.in_single or self.in_double) return error.UnbalancedQuote;
    }
};

pub fn pipe_segments(alloc: std.mem.Allocator, command: []const u8) ![]PipeSegment {
    try check_input(command);

    var segments: std.ArrayList(PipeSegment) = .empty;
    errdefer segments.deinit(alloc);

    var scan: ShellScan = .{};
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = try scan.unquoted(command, i) orelse continue;

        if (ch == '|') {
            if (i > 0 and command[i - 1] == '>') continue;
            if (i + 1 < command.len and command[i + 1] == '|') {
                i += 1;
                continue;
            }
            try segments.append(alloc, trim_segment(command, segment_start, i));
            segment_start = i + 1;
        }
    }

    try scan.finish();
    try segments.append(alloc, trim_segment(command, segment_start, command.len));
    return segments.toOwnedSlice(alloc);
}

fn trim_segment(command: []const u8, raw_start: usize, raw_end: usize) PipeSegment {
    var start = raw_start;
    var end = raw_end;
    while (start < end and is_whitespace(command[start])) : (start += 1) {}
    while (end > start and is_whitespace(command[end - 1])) : (end -= 1) {}
    return .{ .text = command[start..end], .start = start, .end = end };
}

/// Conservative shell-shape detector for syntax that needs a real shell parser.
/// It recognizes common unquoted compound/subshell ASCII metacharacters only;
/// it intentionally does not model every POSIX shell grammar production.
pub fn unsafe_compound_indicator(command: []const u8) bool {
    if (check_input(command)) |_| {} else |_| return true;

    var scan: ShellScan = .{};
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const maybe_ch = scan.unquoted(command, i) catch return true;
        const ch = maybe_ch orelse continue;

        if (ch == '$' and i + 1 < command.len and command[i + 1] == '(') return true;
        if (ch == '`') return true;
        if (ch == '(' or ch == ')' or ch == '{' or ch == '}') return true;
        if (ch == ';' or ch == '\n') return true;
        if (ch == '&') {
            if (i + 1 < command.len and command[i + 1] == '>') continue;
            if (i > 0 and command[i - 1] == '>') continue;
            return true;
        }
        if (ch == '|' and i + 1 < command.len and command[i + 1] == '|') return true;
    }
    scan.finish() catch return true;
    return false;
}

pub fn tokenize_argv(alloc: std.mem.Allocator, command: []const u8) !Argv {
    try check_input(command);

    var tokens: std.ArrayList(ArgvToken) = .empty;
    errdefer {
        for (tokens.items) |token| alloc.free(token.value);
        tokens.deinit(alloc);
    }
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(alloc);

    var token_start: usize = 0;
    var token_active = false;
    var token_quoted = false;
    var in_single = false;
    var in_double = false;

    var i: usize = 0;
    while (i < command.len) {
        const ch = command[i];

        if (!in_single and !in_double) {
            if (is_whitespace(ch)) {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                token_active = false;
                token_quoted = false;
                i += 1;
                continue;
            }

            if (redirection_operator_len(command, i)) |op_len| {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                try append_operator_token(alloc, &tokens, command, i, i + op_len);
                token_active = false;
                token_quoted = false;
                i += op_len;
                continue;
            }

            if (control_operator_len(command, i)) |op_len| {
                if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, i, token_quoted);
                try append_operator_token(alloc, &tokens, command, i, i + op_len);
                token_active = false;
                token_quoted = false;
                i += op_len;
                continue;
            }
        }

        if (!token_active) {
            token_start = i;
            token_active = true;
        }

        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            token_quoted = true;
            i += 1;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            token_quoted = true;
            i += 1;
            continue;
        }
        if (ch == '\\' and !in_single) {
            if (i + 1 >= command.len) return error.MalformedEscape;
            const next = command[i + 1];
            // Inside double quotes, a backslash quotes only `$`, `` ` ``, `"`,
            // `\`, and newline. Before any other character the shell keeps it.
            const keeps_backslash = in_double and switch (next) {
                '$', '`', '"', '\\', '\n' => false,
                else => true,
            };
            if (keeps_backslash) try value.append(alloc, ch);
            try value.append(alloc, next);
            i += 2;
            continue;
        }

        try value.append(alloc, ch);
        i += 1;
    }

    if (in_single or in_double) return error.UnbalancedQuote;
    if (token_active) try finish_token(alloc, &tokens, &value, command, token_start, command.len, token_quoted);
    return .{ .tokens = try tokens.toOwnedSlice(alloc) };
}

fn finish_token(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayList(ArgvToken),
    value: *std.ArrayList(u8),
    command: []const u8,
    start: usize,
    end: usize,
    quoted: bool,
) !void {
    const owned = try alloc.dupe(u8, value.items);
    value.clearRetainingCapacity();
    errdefer alloc.free(owned);
    try tokens.append(alloc, .{
        .raw = command[start..end],
        .value = owned,
        .start = start,
        .end = end,
        .quoted = quoted,
    });
}

fn append_operator_token(
    alloc: std.mem.Allocator,
    tokens: *std.ArrayList(ArgvToken),
    command: []const u8,
    start: usize,
    end: usize,
) !void {
    const owned = try alloc.dupe(u8, command[start..end]);
    errdefer alloc.free(owned);
    try tokens.append(alloc, .{
        .raw = command[start..end],
        .value = owned,
        .start = start,
        .end = end,
    });
}

fn redirection_operator_len(input: []const u8, start: usize) ?usize {
    const ch = input[start];
    if (ch == '&' and start + 1 < input.len and input[start + 1] == '>') {
        if (start + 2 < input.len and input[start + 2] == '>') return 3;
        return 2;
    }
    if (ch == '<') {
        if (start + 2 < input.len and input[start + 1] == '<' and input[start + 2] == '<') return 3;
        if (start + 1 < input.len and (input[start + 1] == '<' or input[start + 1] == '&' or input[start + 1] == '>')) return 2;
        return 1;
    }
    if (ch == '>') {
        if (start + 1 < input.len and (input[start + 1] == '>' or input[start + 1] == '|' or input[start + 1] == '&')) return 2;
        return 1;
    }
    return null;
}

pub fn redirection_kind(value: []const u8) ?RedirectionKind {
    if (std.mem.eql(u8, value, "<")) return .read_path;
    if (std.mem.eql(u8, value, "<>")) return .read_write_path;
    if (std.mem.eql(u8, value, "<<") or std.mem.eql(u8, value, "<<<") or std.mem.eql(u8, value, "<&")) return .unsupported;

    if (std.mem.eql(u8, value, ">") or
        std.mem.eql(u8, value, ">>") or
        std.mem.eql(u8, value, ">|") or
        std.mem.eql(u8, value, "&>") or
        std.mem.eql(u8, value, "&>>") or
        std.mem.eql(u8, value, ">&"))
    {
        return .write_path;
    }
    return null;
}

fn control_operator_len(input: []const u8, start: usize) ?usize {
    return switch (input[start]) {
        ';', '(', ')', '{', '}' => 1,
        '|' => if (start + 1 < input.len and input[start + 1] == '|') 2 else 1,
        '&' => if (start + 1 < input.len and input[start + 1] == '&') 2 else 1,
        else => null,
    };
}

pub fn wrapper_strip_argv(argv: []const ArgvToken) ?[]const ArgvToken {
    var rest = argv;
    while (rest.len > 0) {
        if (is_safe_env_assignment(rest[0].value)) {
            rest = rest[1..];
            continue;
        }

        const command = rest[0].value;
        if (std.mem.eql(u8, command, "env")) {
            rest = strip_env(rest) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, command, "nice")) {
            rest = strip_nice(rest) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, command, "stdbuf")) {
            rest = strip_stdbuf(rest) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, command, "unbuffer") or std.mem.eql(u8, command, "nohup")) {
            if (rest.len < 2) return null;
            rest = rest[1..];
            continue;
        }
        if (std.mem.eql(u8, command, "time")) {
            rest = strip_time(rest) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, command, "timeout")) {
            rest = strip_timeout(rest) orelse return null;
            continue;
        }
        return rest;
    }
    return rest;
}

fn strip_env(argv: []const ArgvToken) ?[]const ArgvToken {
    var index: usize = 1;
    var saw_assignment = false;
    while (index < argv.len and is_safe_env_assignment(argv[index].value)) : (index += 1) {
        saw_assignment = true;
    }
    if (!saw_assignment or index >= argv.len) return null;
    return argv[index..];
}

fn strip_nice(argv: []const ArgvToken) ?[]const ArgvToken {
    var index: usize = 1;
    if (index < argv.len) {
        const arg = argv[index].value;
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--adjustment")) {
            if (index + 1 >= argv.len or !is_signed_integer(argv[index + 1].value)) return null;
            index += 2;
        } else if (std.mem.startsWith(u8, arg, "--adjustment=")) {
            if (!is_signed_integer(arg["--adjustment=".len..])) return null;
            index += 1;
        } else if (arg.len > 1 and arg[0] == '-' and is_signed_integer(arg[1..])) {
            index += 1;
        }
    }
    if (index >= argv.len) return null;
    return argv[index..];
}

fn strip_stdbuf(argv: []const ArgvToken) ?[]const ArgvToken {
    var index: usize = 1;
    var saw_option = false;
    while (index < argv.len) {
        const arg = argv[index].value;
        if (!std.mem.startsWith(u8, arg, "-")) break;
        saw_option = true;
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-e") or
            std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "--error"))
        {
            if (index + 1 >= argv.len or has_shell_metachar(argv[index + 1].raw)) return null;
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-i") or std.mem.startsWith(u8, arg, "-o") or std.mem.startsWith(u8, arg, "-e") or
            std.mem.startsWith(u8, arg, "--input=") or std.mem.startsWith(u8, arg, "--output=") or std.mem.startsWith(u8, arg, "--error="))
        {
            if (has_shell_metachar(argv[index].raw)) return null;
            index += 1;
            continue;
        }
        return null;
    }
    if (!saw_option or index >= argv.len) return null;
    return argv[index..];
}

fn strip_time(argv: []const ArgvToken) ?[]const ArgvToken {
    var index: usize = 1;
    while (index < argv.len and std.mem.eql(u8, argv[index].value, "-p")) : (index += 1) {}
    if (index >= argv.len) return null;
    return argv[index..];
}

fn strip_timeout(argv: []const ArgvToken) ?[]const ArgvToken {
    var index: usize = 1;
    while (index < argv.len) {
        const arg = argv[index].value;
        if (!std.mem.startsWith(u8, arg, "-") or std.mem.eql(u8, arg, "-")) break;

        if (std.mem.eql(u8, arg, "--foreground") or std.mem.eql(u8, arg, "--preserve-status") or std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kill-after")) {
            if (index + 1 >= argv.len or !is_duration(argv[index + 1].value) or has_shell_metachar(argv[index + 1].raw)) return null;
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
            if (index + 1 >= argv.len or !is_signal(argv[index + 1].value) or has_shell_metachar(argv[index + 1].raw)) return null;
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--kill-after=")) {
            if (!is_duration(arg["--kill-after=".len..]) or has_shell_metachar(argv[index].raw)) return null;
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--signal=")) {
            if (!is_signal(arg["--signal=".len..]) or has_shell_metachar(argv[index].raw)) return null;
            index += 1;
            continue;
        }
        return null;
    }

    if (index >= argv.len or !is_duration(argv[index].value) or has_shell_metachar(argv[index].raw)) return null;
    index += 1;
    if (index >= argv.len) return null;
    return argv[index..];
}

pub fn is_safe_env_assignment(token: []const u8) bool {
    const eq = std.mem.findScalar(u8, token, '=') orelse return false;
    if (eq == 0) return false;
    return is_safe_env_name(token[0..eq]);
}

fn is_safe_env_name(name: []const u8) bool {
    return std.mem.eql(u8, name, "CI") or
        std.mem.eql(u8, name, "NODE_ENV") or
        std.mem.eql(u8, name, "BUN_ENV") or
        std.mem.eql(u8, name, "DENO_ENV") or
        std.mem.eql(u8, name, "PYTHONUNBUFFERED") or
        std.mem.eql(u8, name, "PYTHONWARNINGS") or
        std.mem.eql(u8, name, "RUST_LOG") or
        std.mem.eql(u8, name, "RUST_BACKTRACE") or
        std.mem.eql(u8, name, "TERM") or
        std.mem.eql(u8, name, "COLORTERM") or
        std.mem.eql(u8, name, "NO_COLOR") or
        std.mem.eql(u8, name, "FORCE_COLOR") or
        std.mem.eql(u8, name, "CLICOLOR") or
        std.mem.eql(u8, name, "CLICOLOR_FORCE") or
        std.mem.eql(u8, name, "LANG") or
        std.mem.eql(u8, name, "LC_ALL") or
        std.mem.eql(u8, name, "LC_CTYPE") or
        std.mem.eql(u8, name, "LC_MESSAGES") or
        std.mem.eql(u8, name, "TZ") or
        std.mem.eql(u8, name, "CC") or
        std.mem.eql(u8, name, "CXX") or
        std.mem.eql(u8, name, "AR") or
        std.mem.eql(u8, name, "AS") or
        std.mem.eql(u8, name, "LD") or
        std.mem.eql(u8, name, "CFLAGS") or
        std.mem.eql(u8, name, "CXXFLAGS") or
        std.mem.eql(u8, name, "CPPFLAGS") or
        std.mem.eql(u8, name, "LDFLAGS") or
        std.mem.eql(u8, name, "MAKEFLAGS") or
        std.mem.eql(u8, name, "CMAKE_BUILD_TYPE");
}

fn check_input(input: []const u8) LexError!void {
    if (std.mem.findScalar(u8, input, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
}

fn is_whitespace(ch: u8) bool {
    return std.mem.findScalar(u8, whitespace, ch) != null;
}

fn is_signed_integer(value: []const u8) bool {
    if (value.len == 0) return false;
    const start: usize = if (value[0] == '+' or value[0] == '-') 1 else 0;
    if (start >= value.len) return false;
    for (value[start..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn is_duration(value: []const u8) bool {
    if (value.len == 0) return false;
    var saw_digit = false;
    var saw_dot = false;
    for (value, 0..) |ch, i| {
        if (std.ascii.isDigit(ch)) {
            saw_digit = true;
            continue;
        }
        if (ch == '.' and !saw_dot and i + 1 < value.len) {
            saw_dot = true;
            continue;
        }
        if (i + 1 == value.len and (ch == 's' or ch == 'm' or ch == 'h' or ch == 'd')) return saw_digit;
        return false;
    }
    return saw_digit;
}

fn is_signal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn has_shell_metachar(value: []const u8) bool {
    for (value) |ch| {
        switch (ch) {
            ';', '&', '|', '(', ')', '{', '}', '<', '>', '$', '`', '\'', '"' => return true,
            else => {},
        }
    }
    return false;
}

test "pipe_segments splits unquoted pipes" {
    const alloc = std.testing.allocator;
    const segments = try pipe_segments(alloc, "printf a | grep a | wc -l");
    defer alloc.free(segments);

    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("printf a", segments[0].text);
    try std.testing.expectEqualStrings("grep a", segments[1].text);
    try std.testing.expectEqualStrings("wc -l", segments[2].text);
}

test "pipe_segments ignores quoted pipes" {
    const alloc = std.testing.allocator;
    const segments = try pipe_segments(alloc, "printf 'a|b' | grep \"c|d\"");
    defer alloc.free(segments);

    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("printf 'a|b'", segments[0].text);
    try std.testing.expectEqualStrings("grep \"c|d\"", segments[1].text);
}

test "pipe_segments ignores escaped pipes" {
    const alloc = std.testing.allocator;
    const segments = try pipe_segments(alloc, "printf a\\|b | cat");
    defer alloc.free(segments);

    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("printf a\\|b", segments[0].text);
}

test "pipe_segments does not split logical or" {
    const alloc = std.testing.allocator;
    const segments = try pipe_segments(alloc, "grep x file || true");
    defer alloc.free(segments);

    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("grep x file || true", segments[0].text);
}

test "pipe_segments keeps overwrite pipe redirection within its segment" {
    const alloc = std.testing.allocator;
    const segments = try pipe_segments(alloc, "printf x >| out | cat");
    defer alloc.free(segments);

    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("printf x >| out", segments[0].text);
    try std.testing.expectEqualStrings("cat", segments[1].text);
}

test "pipe_segments reports unbalanced quotes" {
    try std.testing.expectError(error.UnbalancedQuote, pipe_segments(std.testing.allocator, "printf 'x | cat"));
}

test "pipe_segments reports malformed trailing escapes" {
    try std.testing.expectError(error.MalformedEscape, pipe_segments(std.testing.allocator, "printf x\\"));
}

test "pipe_segments rejects embedded nul and invalid utf8" {
    try std.testing.expectError(error.EmbeddedNul, pipe_segments(std.testing.allocator, "cat \x00 file"));
    try std.testing.expectError(error.InvalidUtf8, pipe_segments(std.testing.allocator, "cat \xff"));
}

test "tokenize_argv decodes single and double quoted tokens" {
    var argv = try tokenize_argv(std.testing.allocator, "grep 'hello world' \"file name.txt\"");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), argv.tokens.len);
    try std.testing.expectEqualStrings("hello world", argv.tokens[1].value);
    try std.testing.expectEqualStrings("file name.txt", argv.tokens[2].value);
    try std.testing.expect(argv.tokens[1].quoted);
}

test "tokenize_argv keeps a double-quoted backslash unless it quotes a special character" {
    var argv = try tokenize_argv(std.testing.allocator, "printf \"a\\&b\" \"\\$x \\` \\\" \\\\\" a\\&b");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), argv.tokens.len);
    try std.testing.expectEqualStrings("a\\&b", argv.tokens[1].value);
    try std.testing.expectEqualStrings("$x ` \" \\", argv.tokens[2].value);
    try std.testing.expectEqualStrings("a&b", argv.tokens[3].value);
}

test "tokenize_argv preserves raw byte offsets" {
    var argv = try tokenize_argv(std.testing.allocator, "  cat 'a b'");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), argv.tokens[0].start);
    try std.testing.expectEqual(@as(usize, 5), argv.tokens[0].end);
    try std.testing.expectEqualStrings("'a b'", argv.tokens[1].raw);
}

test "tokenize_argv handles escaped spaces without splitting" {
    var argv = try tokenize_argv(std.testing.allocator, "cat file\\ name.txt");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), argv.tokens.len);
    try std.testing.expectEqualStrings("file name.txt", argv.tokens[1].value);
    try std.testing.expectEqualStrings("file\\ name.txt", argv.tokens[1].raw);
}

test "tokenize_argv emits redirection operators as tokens" {
    var argv = try tokenize_argv(std.testing.allocator, "printf ok>out.txt &>> log.txt >&err.txt < in.txt <> state.txt << EOF <<< value <& 0");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(">", argv.tokens[2].value);
    try std.testing.expectEqualStrings("&>>", argv.tokens[4].value);
    try std.testing.expectEqualStrings(">&", argv.tokens[6].value);
    try std.testing.expectEqualStrings("err.txt", argv.tokens[7].value);
    try std.testing.expectEqualStrings("<", argv.tokens[8].value);
    try std.testing.expectEqualStrings("<>", argv.tokens[10].value);
    try std.testing.expectEqualStrings("<<", argv.tokens[12].value);
    try std.testing.expectEqualStrings("<<<", argv.tokens[14].value);
    try std.testing.expectEqualStrings("<&", argv.tokens[16].value);
}

test "redirection_kind classifies shell redirects" {
    try std.testing.expectEqual(RedirectionKind.read_path, redirection_kind("<").?);
    try std.testing.expectEqual(RedirectionKind.read_write_path, redirection_kind("<>").?);
    try std.testing.expectEqual(RedirectionKind.write_path, redirection_kind(">").?);
    try std.testing.expectEqual(RedirectionKind.write_path, redirection_kind("&>>").?);
    try std.testing.expectEqual(RedirectionKind.unsupported, redirection_kind("<<").?);
    try std.testing.expectEqual(RedirectionKind.unsupported, redirection_kind("<<<").?);
    try std.testing.expectEqual(RedirectionKind.unsupported, redirection_kind("<&").?);
    try std.testing.expect(redirection_kind("|") == null);
}

test "tokenize_argv distinguishes empty argv from tokenization failure" {
    var argv = try tokenize_argv(std.testing.allocator, "   \t ");
    defer argv.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), argv.tokens.len);

    try std.testing.expectError(error.UnbalancedQuote, tokenize_argv(std.testing.allocator, "\"unterminated"));
}

test "tokenize_argv reports malformed trailing escapes" {
    try std.testing.expectError(error.MalformedEscape, tokenize_argv(std.testing.allocator, "printf x\\"));
}

test "tokenize_argv rejects embedded nul and invalid utf8" {
    try std.testing.expectError(error.EmbeddedNul, tokenize_argv(std.testing.allocator, "cat \x00 file"));
    try std.testing.expectError(error.InvalidUtf8, tokenize_argv(std.testing.allocator, "cat \xff"));
}

test "unsafe_compound_indicator detects subshells and groups" {
    try std.testing.expect(unsafe_compound_indicator("echo $(pwd)"));
    try std.testing.expect(unsafe_compound_indicator("(cd src; make)"));
    try std.testing.expect(unsafe_compound_indicator("{ echo hi; }"));
    try std.testing.expect(!unsafe_compound_indicator("grep '(' file"));
}

test "unsafe_compound_indicator detects logical control syntax" {
    try std.testing.expect(unsafe_compound_indicator("cd src && touch x"));
    try std.testing.expect(unsafe_compound_indicator("grep x file || true"));
    try std.testing.expect(unsafe_compound_indicator("sleep 1 &"));
    try std.testing.expect(!unsafe_compound_indicator("printf a | grep a"));
}

test "unsafe_compound_indicator ignores escaped and quoted compound characters" {
    try std.testing.expect(!unsafe_compound_indicator("printf \\& \\| \\;"));
    try std.testing.expect(!unsafe_compound_indicator("printf \"$(literal)\""));
}

test "wrapper_strip_argv strips safe env and process wrappers" {
    var argv = try tokenize_argv(std.testing.allocator, "env NODE_ENV=prod nice -n 5 timeout --foreground 10s grep x file");
    defer argv.deinit(std.testing.allocator);

    const stripped = wrapper_strip_argv(argv.tokens).?;
    try std.testing.expectEqualStrings("grep", stripped[0].value);
    try std.testing.expectEqualStrings("file", stripped[2].value);
}

test "wrapper_strip_argv declines ambiguous wrappers" {
    var env_argv = try tokenize_argv(std.testing.allocator, "env -i grep x");
    defer env_argv.deinit(std.testing.allocator);
    try std.testing.expect(wrapper_strip_argv(env_argv.tokens) == null);

    var timeout_argv = try tokenize_argv(std.testing.allocator, "timeout --kill-after '1;rm' 10s grep x");
    defer timeout_argv.deinit(std.testing.allocator);
    try std.testing.expect(wrapper_strip_argv(timeout_argv.tokens) == null);
}

/// Pieces of generated commands, weighted toward the quoting, escapes, and
/// operators where two readings of a command can disagree.
const fuzz_fragments = [_][]const u8{
    " ",    "\t", "a",    "-x", "=",  "'",    "\"",     "\\",
    "\\ ",  "''", "\"\"", "|",  "||", "&",    "&&",     ";",
    "(",    ")",  ">",    ">>", "<",  "2>&1", "&>",     "<<<",
    ">|",   "$",  "`",    "#",  "\n", "\r",   "\u{e9}", "\x00",
    "\xff",
};

fn writeFuzzCommand(smith: *std.testing.Smith, out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..smith.valueRangeAtMost(u8, 0, 24)) |_| {
        if (smith.boolWeighted(3, 1)) {
            try out.writeAll(fuzz_fragments[smith.index(fuzz_fragments.len)]);
            continue;
        }
        var raw: [8]u8 = undefined;
        try out.writeAll(raw[0..smith.slice(&raw)]);
    }
}

fn fuzzTokenize(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeFuzzCommand(smith, &writer) catch |err| switch (err) {
        // A full buffer ends the command early, which is still a command.
        error.WriteFailed => {},
    };
    const command = writer.buffered();

    var argv = tokenize_argv(alloc, command) catch |err| {
        // Both read quotes and escapes the same way, so both reject it.
        try std.testing.expectError(err, pipe_segments(alloc, command));
        return;
    };
    defer argv.deinit(alloc);
    alloc.free(try pipe_segments(alloc, command));

    var previous_end: usize = 0;
    for (argv.tokens) |token| {
        try std.testing.expect(previous_end <= token.start and token.start < token.end and token.end <= command.len);
        try std.testing.expectEqualStrings(command[token.start..token.end], token.raw);
        previous_end = token.end;
    }

    // Lexing the values again, each in single quotes, gives the same values.
    var requoted: std.ArrayList(u8) = .empty;
    defer requoted.deinit(alloc);
    for (argv.tokens, 0..) |token, index| {
        if (index > 0) try requoted.append(alloc, ' ');
        try requoted.append(alloc, '\'');
        for (token.value) |byte| {
            if (byte == '\'') try requoted.appendSlice(alloc, "'\\''") else try requoted.append(alloc, byte);
        }
        try requoted.append(alloc, '\'');
    }
    var again = try tokenize_argv(alloc, requoted.items);
    defer again.deinit(alloc);
    try std.testing.expectEqual(argv.tokens.len, again.tokens.len);
    for (argv.tokens, again.tokens) |original, round_trip| {
        try std.testing.expectEqualStrings(original.value, round_trip.value);
        try std.testing.expect(round_trip.quoted);
    }
}

test "lexing generated commands is consistent and round-trips through quoting" {
    try std.testing.fuzz({}, fuzzTokenize, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").command_lex.*),
    });
}
