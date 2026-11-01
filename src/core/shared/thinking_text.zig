//! A reasoning trace as prose. Fenced code folds into an elision marker, as
//! proto shows a thinking trace, so a person reads the plan without the code
//! the model drafted alongside it. The durable reasoning record keeps the raw
//! trace; only its display is folded.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Largest folded trace the fixed-buffer preview path retains.
pub const preview_capacity: usize = 8192;

const Fence = struct { ch: u8, len: usize };

/// A fence opening line: up to three spaces, then three or more backticks or
/// tildes. A backtick fence may not carry another backtick after its run.
fn fenceAt(line: []const u8) ?Fence {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3 or trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var len: usize = 0;
    while (len < trimmed.len and trimmed[len] == ch) len += 1;
    if (len < 3) return null;
    if (ch == '`' and std.mem.findScalar(u8, trimmed[len..], '`') != null) return null;
    return .{ .ch = ch, .len = len };
}

/// A fence line that closes one of `len` characters or more, with only
/// whitespace after its run.
fn closesFence(line: []const u8, ch: u8, len: usize) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len < len) return false;
    var run: usize = 0;
    while (run < trimmed.len and trimmed[run] == ch) run += 1;
    if (run < len) return false;
    return std.mem.trim(u8, trimmed[run..], " \t\r").len == 0;
}

/// One or two fence characters on the last line: a fence still arriving.
fn partialFence(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed.len > 2) return false;
    for (trimmed) |byte| if (byte != '`' and byte != '~') return false;
    return true;
}

/// Appends the code-fold marker to the current line, or starts one when no
/// text has been written yet.
fn appendElision(writer: *std.Io.Writer, hidden: usize, wrote_any: *bool) !void {
    var buf: [64]u8 = undefined;
    const marker = std.mem.print(
        &buf,
        "... ({d} line{s} of code)",
        .{ hidden, if (hidden == 1) "" else "s" },
    ) catch "...";
    if (wrote_any.*) {
        try writer.writeByte(' ');
    } else {
        wrote_any.* = true;
    }
    try writer.writeAll(marker);
}

/// Starts the next source line, flushing the blank rows that separated it
/// from the previous one.
fn beginLine(writer: *std.Io.Writer, wrote_any: *bool, pending_blanks: *usize) !void {
    if (wrote_any.*) {
        try writer.writeByte('\n');
        var index: usize = 0;
        while (index < pending_blanks.*) : (index += 1) try writer.writeByte('\n');
    }
    pending_blanks.* = 0;
    wrote_any.* = true;
}

fn writeProse(writer: *std.Io.Writer, text: []const u8) !void {
    var wrote_any = false;
    var pending_blanks: usize = 0;
    var in_fence = false;
    var fence_ch: u8 = 0;
    var fence_len: usize = 0;
    var hidden: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const last = lines.peek() == null;
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (in_fence) {
            if (closesFence(line, fence_ch, fence_len)) {
                in_fence = false;
                try appendElision(writer, hidden, &wrote_any);
                hidden = 0;
            } else {
                hidden += 1;
            }
            continue;
        }
        if (fenceAt(line)) |fence| {
            in_fence = true;
            fence_ch = fence.ch;
            fence_len = fence.len;
            hidden = 0;
            continue;
        }
        if (last and partialFence(line)) continue;
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            pending_blanks += 1;
            continue;
        }
        try beginLine(writer, &wrote_any, &pending_blanks);
        try writer.writeAll(line);
    }
    if (in_fence) try appendElision(writer, hidden, &wrote_any);
}

/// The trace as prose, owned by the caller. Returns a copy when no fence is
/// present so the result always owns its bytes.
pub fn proseOnly(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeProse(&out.writer, text);
    return out.toOwnedSlice();
}

/// The trace as prose in a caller-provided buffer. A trace larger than the
/// buffer keeps its leading complete codepoints and ends there.
pub fn proseOnlyInto(buf: []u8, text: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    writeProse(&writer, text) catch {};
    var written = writer.buffered();
    while (written.len > 0 and !std.unicode.utf8ValidateSlice(written)) {
        written = written[0 .. written.len - 1];
    }
    return written;
}

test "fenced code folds into an elision marker on the line before it" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Plan the edit.\n\n```zig\nconst a = 1;\nconst b = 2;\n```\n\nThen check it.");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings(
        "Plan the edit. ... (2 lines of code)\n\n\nThen check it.",
        folded,
    );
}

test "a trace that is only code keeps its marker as the first line" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "~~~\ncode\n~~~");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("... (1 line of code)", folded);
}

test "an unfinished fence still folds and a partial fence is dropped" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Thinking.\n```\ncode\n``");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Thinking. ... (2 lines of code)", folded);
}

test "a partial fence arriving outside code is dropped" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Thinking.\n``");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Thinking.", folded);
}

test "inline backticks and indented fences are not code blocks" {
    const alloc = std.testing.allocator;
    const folded = try proseOnly(alloc, "Use `zig build` here.\n    ``` not a fence\nplain");
    defer alloc.free(folded);
    try std.testing.expectEqualStrings("Use `zig build` here.\n    ``` not a fence\nplain", folded);
}

test "the fixed-buffer path matches the allocating path and stays valid UTF-8" {
    const alloc = std.testing.allocator;
    const source = "Read the note.\n```\nline\nline\n```\n界海語";
    const folded = try proseOnly(alloc, source);
    defer alloc.free(folded);
    var buf: [128]u8 = undefined;
    const fixed = proseOnlyInto(&buf, source);
    try std.testing.expectEqualStrings(folded, fixed);

    var small: [24]u8 = undefined;
    const clipped = proseOnlyInto(&small, "界海語界海語界海語界海語界海語");
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
}
