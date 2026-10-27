//! Text for people, cut from text written for the model. A person never
//! needs an id: job ids (`bg_3`, `<worker>-t2`) and terminal session ids
//! (`shell-…`) stay in tool results, and rows say "the job" instead. A
//! failure row carries one short reason: the line of an error or a
//! traceback that says what went wrong.
const std = @import("std");
const text_utils = @import("text_utils.zig");

const Allocator = std.mem.Allocator;

/// The widest reason a row carries, in bytes before terminal encoding.
pub const max_reason_bytes = 80;

const IdKind = enum { job, worker_turn, terminal };

/// The id at `text[start..]`, as its kind and length, or null.
fn idAt(text: []const u8, start: usize) ?struct { kind: IdKind, len: usize } {
    if (start > 0 and isIdByte(text[start - 1])) return null;
    const rest = text[start..];
    if (std.mem.startsWith(u8, rest, "bg_")) {
        const digits = countWhile(rest[3..], std.ascii.isDigit);
        if (digits > 0 and !continuesId(rest, 3 + digits)) return .{ .kind = .job, .len = 3 + digits };
    }
    if (std.mem.startsWith(u8, rest, "shell-")) {
        const body = countWhile(rest[6..], isIdByte);
        if (body >= 4) return .{ .kind = .terminal, .len = 6 + body };
    }
    // A worker turn: a 12-byte worker id, "-t", and the turn number.
    if (rest.len >= 15 and countWhile(rest[0..12], isWorkerIdByte) == 12 and looksRandom(rest[0..12]) and std.mem.startsWith(u8, rest[12..], "-t")) {
        const digits = countWhile(rest[14..], std.ascii.isDigit);
        if (digits > 0 and !continuesId(rest, 14 + digits)) return .{ .kind = .worker_turn, .len = 14 + digits };
    }
    return null;
}

fn determinerBefore(text: []const u8, start: usize) bool {
    const before = std.mem.trimEnd(u8, text[0..start], " ");
    const word_start = if (std.mem.findScalarLast(u8, before, ' ')) |space| space + 1 else 0;
    const word = before[word_start..];
    for ([_][]const u8{ "no", "unknown", "the", "a", "an", "that", "this" }) |determiner| {
        if (std.ascii.eqlIgnoreCase(word, determiner)) return true;
    }
    return false;
}

fn isIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

/// Generated worker ids mix cases or digits; a hyphenated word does not.
fn looksRandom(text: []const u8) bool {
    var lower = false;
    var other = false;
    for (text) |byte| {
        if (std.ascii.isLower(byte)) lower = true;
        if (std.ascii.isUpper(byte) or std.ascii.isDigit(byte)) other = true;
    }
    return lower and other;
}

fn isWorkerIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn continuesId(text: []const u8, end: usize) bool {
    return end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_');
}

fn countWhile(text: []const u8, comptime pred: fn (u8) bool) usize {
    var count: usize = 0;
    while (count < text.len and pred(text[count])) count += 1;
    return count;
}

/// `text` with every job, worker turn and terminal id replaced by what a
/// person calls it: "Job bg_3 reads no input" becomes "The job reads no
/// input". Allocated in `arena`; returns `text` itself when it holds no id.
pub fn scrubIds(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var copied: usize = 0;
    var index: usize = 0;
    var changed = false;
    while (index < text.len) {
        const id = idAt(text, index) orelse {
            index += 1;
            continue;
        };
        var end = index + id.len;
        var start = index;
        // A quoted id loses its quotes with it.
        if (start > 0 and text[start - 1] == '`' and end < text.len and text[end] == '`') {
            start -= 1;
            end += 1;
        }
        // "Job bg_3" already names the thing: it becomes "The job".
        var noun: []const u8 = switch (id.kind) {
            .job => "job",
            .worker_turn => "worker turn",
            .terminal => "terminal",
        };
        var capital = start == 0 or (start >= 2 and text[start - 2] == '.');
        for ([_][]const u8{ "worker turn ", "job ", "session ", "terminal ", "turn " }) |lead| {
            if (start < lead.len or !std.ascii.eqlIgnoreCase(text[start - lead.len .. start], lead)) continue;
            if (start > lead.len and std.ascii.isAlphanumeric(text[start - lead.len - 1])) continue;
            start -= lead.len;
            noun = lead[0 .. lead.len - 1];
            capital = std.ascii.isUpper(text[start]);
            // "No session shell-…" keeps its own determiner: "No session".
            if (determinerBefore(text, start)) {
                try out.writer.writeAll(text[copied..start]);
                try out.writer.writeAll(text[start .. start + noun.len]);
                copied = end;
                index = end;
                changed = true;
                break;
            }
            break;
        }
        if (copied == end) continue;
        const article: []const u8 = if (capital) "The " else "the ";
        try out.writer.writeAll(text[copied..start]);
        try out.writer.writeAll(article);
        for (noun) |byte| try out.writer.writeByte(std.ascii.toLower(byte));
        copied = end;
        index = end;
        changed = true;
    }
    if (!changed) return text;
    try out.writer.writeAll(text[copied..]);
    return out.written();
}

/// The one line of `output` that says what went wrong, terminal safe and
/// bounded, or null when nothing does. A Python traceback ends with the
/// exception; other output leads with its error.
pub fn failureReason(arena: Allocator, output: []const u8) !?[]const u8 {
    const line = structuredReason(arena, output) orelse firstSentence(reasonLine(output) orelse return null);
    const scrubbed = try scrubIds(arena, line);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, scrubbed, max_reason_bytes);
    if (!encoded.truncated) return encoded.bytes;
    const body = std.mem.trimEnd(u8, encoded.bytes[0 .. encoded.bytes.len - "...".len], " ");
    return try arena.print("{s}…", .{body});
}

/// A structured tool error, `{"error":{"code":"ExecutionTerminal"}}`, as
/// the words its code stands for.
fn structuredReason(arena: Allocator, output: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "{\"error\"")) return null;
    const Body = struct { @"error": struct { code: []const u8 = "", message: ?[]const u8 = null } };
    const body = std.json.parseFromSliceLeaky(Body, arena, trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    if (body.@"error".message) |message| if (message.len > 0) return message;
    const known = [_][2][]const u8{
        .{ "ExecutionTerminal", "the session has ended" },
        .{ "ExecutionNotFound", "no such session" },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, body.@"error".code, entry[0])) return entry[1];
    }
    return if (body.@"error".code.len > 0) body.@"error".code else null;
}

/// A long line's first sentence: "The job reads no input." rather than
/// the advice after it.
fn firstSentence(line: []const u8) []const u8 {
    if (line.len <= max_reason_bytes) return line;
    const end = std.mem.find(u8, line, ". ") orelse return line;
    return line[0..end];
}

fn reasonLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var traceback = false;
    var error_line: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "Traceback (most recent call last)")) traceback = true;
        if (first == null) first = line;
        last = line;
        if (error_line == null and looksLikeError(line)) error_line = line;
    }
    if (traceback) return last;
    return error_line orelse first;
}

/// "error: …", "fatal: …", "cat: x: No such file", "Error: …".
fn looksLikeError(line: []const u8) bool {
    const markers = [_][]const u8{ "error", "Error", "ERROR", "fatal", "No such file", "not found", "denied", "failed", "Failed" };
    for (markers) |marker| {
        if (std.mem.find(u8, line, marker) != null) return true;
    }
    return false;
}

test "ids become the words a person uses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("The job reads no input: use a tty.", try scrubIds(arena, "Job bg_4 reads no input: use a tty."));
    try std.testing.expectEqualStrings("The worker turn failed.", try scrubIds(arena, "Worker turn `aOMijHlF31qr-t1` failed."));
    try std.testing.expectEqualStrings("Sent to the worker turn", try scrubIds(arena, "Sent to aOMijHlF31qr-t2"));
    try std.testing.expectEqualStrings("No session", try scrubIds(arena, "No session shell-yGovafW-1x"));
    try std.testing.expectEqualStrings("Sending input to the terminal", try scrubIds(arena, "Sending input to shell-yGovafW-1x"));
    try std.testing.expectEqualStrings("The job settled", try scrubIds(arena, "bg_12 settled"));
    const plain = "nothing here, bg_x or abg_3";
    try std.testing.expectEqual(plain.ptr, (try scrubIds(arena, plain)).ptr);
}

test "a failure reason is the line that names the error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const traceback =
        \\Traceback (most recent call last):
        \\  File "<stdin>", line 2, in <module>
        \\AttributeError: module 'os' has no attribute 'nope'
        \\
    ;
    try std.testing.expectEqualStrings("AttributeError: module 'os' has no attribute 'nope'", (try failureReason(arena, traceback)).?);
    try std.testing.expectEqualStrings("cat: nope.txt: No such file or directory", (try failureReason(arena, "cat: nope.txt: No such file or directory\n")).?);
    try std.testing.expectEqualStrings("compiling 3 files", (try failureReason(arena, "compiling 3 files\nwarning: x\n")).?);
    try std.testing.expect((try failureReason(arena, " \n\n")) == null);
    try std.testing.expectEqualStrings("the session has ended", (try failureReason(arena, "{\"error\":{\"tool\":\"shell\",\"code\":\"ExecutionTerminal\"}}")).?);
    try std.testing.expectEqualStrings("The job reads no input", (try failureReason(arena, "Job bg_4 reads no input. Background shell jobs run without a terminal, so use shell with tty=true.")).?);
    const long = (try failureReason(arena, "error: " ++ text_utils.repeat("x", 300))).?;
    try std.testing.expect(std.mem.endsWith(u8, long, "…"));
    try std.testing.expect(long.len <= max_reason_bytes + "…".len);
}
