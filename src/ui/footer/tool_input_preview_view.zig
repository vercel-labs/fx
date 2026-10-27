//! The streaming tool call as a block under the activity row: the call's
//! header, then the end of what the model is writing, highlighted. Only the
//! newest call is drawn this way; once it starts, its settled transcript
//! block is plain. Rows are rendered when the preview or the width changes,
//! so frames in between cost nothing.
const std = @import("std");
const preview_contract = @import("../../core/shared/tool_input_preview.zig");
const display_width = @import("../../core/shared/display_width.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const code_highlight = @import("../../core/agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../../core/agent/presentation/code_highlight_languages.zig");
const python_outline = @import("../transcript/python_outline.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Tail = preview_contract.Tail;

/// Body rows under the header, counting the "earlier lines" row.
pub const body_row_limit: usize = 8;
const body_indent = "    ";

/// Rendered rows of the newest preview, kept until it or the width changes.
pub const Cache = struct {
    version: u32 = 0,
    cols: u16 = 0,
    body_rows: usize = 0,
    valid: bool = false,
    len: usize = 0,
    rows: [12 * 1024]u8 = undefined,
    scratch: [64 * 1024]u8 = undefined,

    /// Styled rows joined by newlines, each fitting `cols`; empty when no
    /// call is streaming. A short terminal gets fewer body rows, so the
    /// transcript keeps most of the screen.
    pub fn view(self: *Cache, tail: *const Tail, cols: u16, screen_rows: u16) []const u8 {
        if (!tail.active or cols < 8 or screen_rows < 8) return "";
        const body_rows = @min(body_row_limit, @max(2, screen_rows / 4));
        if (self.valid and self.version == tail.version and self.cols == cols and self.body_rows == body_rows) return self.rows[0..self.len];
        var fixed = std.heap.FixedBufferAllocator.init(&self.scratch);
        const text = render(fixed.allocator(), tail, cols, body_rows) catch "";
        const len = @min(text.len, self.rows.len);
        // A cut never splits a row's escape: rows end before the cut.
        const end = if (len < text.len) std.mem.findScalarLast(u8, text[0..len], '\n') orelse 0 else len;
        @memcpy(self.rows[0..end], text[0..end]);
        self.len = end;
        self.version = tail.version;
        self.cols = cols;
        self.body_rows = body_rows;
        self.valid = true;
        return self.rows[0..self.len];
    }
};

/// The block's rows, allocated in `arena`.
pub fn render(arena: Allocator, tail: *const Tail, cols: u16, body_rows: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const width: usize = cols;
    const body = std.mem.trimEnd(u8, tail.body(), "\n");
    const theme: code_highlight.Theme = if (shared_theme.current().light) .light else .dark;

    var code = body;
    var language: ?*const code_highlight_languages.Profile = null;
    var header_value: []const u8 = tail.subject();
    const verb = verbFor(tail);
    switch (tail.body_kind) {
        .command => {
            if (python_outline.script(body)) |found| {
                header_value = found.interpreter;
                code = std.mem.trimEnd(u8, found.code, "\n");
                language = code_highlight_languages.resolve("python");
            } else if (std.mem.findScalar(u8, body, '\n') == null and tail.earlier_lines == 0) {
                // A one-line command reads in the header itself.
                header_value = body;
                code = "";
            } else {
                language = code_highlight_languages.resolve("sh");
            }
        },
        .content => language = languageForPath(tail.subject()),
        .diff, .text => {},
    }

    // Header: the marker, the verb, then what it acts on.
    try out.appendSlice(arena, ui_render.permission_auto_style);
    try out.appendSlice(arena, "● ");
    try out.appendSlice(arena, ui_render.reset_style);
    const header_room = width -| 2;
    const head_plain = if (header_value.len > 0)
        try arena.print("{s} {s}", .{ verb, firstLine(header_value) })
    else
        verb;
    const head_cut = display_width.prefixByWidth(head_plain, header_room);
    if (tail.body_kind == .command and header_value.len > 0 and code.len == 0 and head_cut.len > verb.len + 1) {
        try out.appendSlice(arena, verb);
        try out.append(arena, ' ');
        try appendHighlighted(arena, &out, head_cut[verb.len + 1 ..], code_highlight_languages.resolve("sh"), theme);
    } else {
        try out.appendSlice(arena, head_cut);
    }
    try out.appendSlice(arena, ui_render.reset_style);
    if (code.len == 0) return out.items;

    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, code, '\n');
    while (split.next()) |line| try lines.append(arena, line);
    const earlier_in_code = if (lines.items.len > body_rows) lines.items.len - (body_rows - 1) else 0;
    const earlier = earlier_in_code + tail.earlier_lines;
    const shown = lines.items[earlier_in_code..];
    if (earlier > 0) {
        try out.append(arena, '\n');
        try out.appendSlice(arena, ui_render.dim_style);
        try out.appendSlice(arena, display_width.prefixByWidth(
            try arena.print("{s}… {d} earlier line{s}", .{ body_indent, earlier, if (earlier == 1) "" else "s" }),
            width,
        ));
        try out.appendSlice(arena, ui_render.reset_style);
    }
    const room = width -| body_indent.len;
    for (shown) |raw| {
        const expanded = try std.mem.replaceOwned(u8, arena, std.mem.trimEnd(u8, raw, "\r"), "\t", "    ");
        const cut = display_width.prefixByWidth(expanded, room);
        try out.append(arena, '\n');
        try out.appendSlice(arena, body_indent);
        switch (tail.body_kind) {
            .diff => {
                const style = if (std.mem.startsWith(u8, cut, "+"))
                    ui_render.green_style
                else if (std.mem.startsWith(u8, cut, "-"))
                    ui_render.red_style
                else
                    ui_render.dim_style;
                try out.appendSlice(arena, style);
                try out.appendSlice(arena, cut);
            },
            .text => {
                try out.appendSlice(arena, ui_render.dim_style);
                try out.appendSlice(arena, cut);
            },
            .command, .content => try appendHighlighted(arena, &out, cut, language, theme),
        }
        try out.appendSlice(arena, ui_render.reset_style);
    }
    return out.items;
}

fn appendHighlighted(
    arena: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    language: ?*const code_highlight_languages.Profile,
    theme: code_highlight.Theme,
) !void {
    const profile = language orelse return out.appendSlice(arena, text);
    try out.appendSlice(arena, try code_highlight.highlight(arena, text, profile, theme, null));
}

fn verbFor(tail: *const Tail) []const u8 {
    const name = tail.toolName();
    return switch (tail.body_kind) {
        .command => "Running",
        .content => "Writing",
        .diff => "Editing",
        .text => if (std.mem.eql(u8, name, "web_search"))
            "Searching"
        else if (std.mem.eql(u8, name, "web_fetch"))
            "Fetching"
        else if (std.mem.eql(u8, name, "fleet"))
            "Briefing"
        else if (std.mem.eql(u8, name, "jobs"))
            "Writing to"
        else
            "Preparing",
    };
}

fn firstLine(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
}

fn languageForPath(path: []const u8) ?*const code_highlight_languages.Profile {
    const base = std.Io.Dir.path.basename(path);
    if (std.ascii.eqlIgnoreCase(base, "makefile")) return code_highlight_languages.resolve("make");
    if (std.ascii.eqlIgnoreCase(base, "dockerfile")) return code_highlight_languages.resolve("dockerfile");
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return null;
    return code_highlight_languages.resolve(base[dot + 1 ..]);
}

fn plain(arena: Allocator, styled: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < styled.len) {
        if (styled[index] == 0x1b) {
            index = display_width.ansiSequenceEnd(styled, index);
            continue;
        }
        try out.append(arena, styled[index]);
        index += 1;
    }
    return out.items;
}

test "a streaming python heredoc reads as its interpreter and code tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tail: Tail = .{};
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "python3 - <<'PY'\nimport os\n");
    for (0..12) |index| try body.print(arena, "x{d} = {d}\n", .{ index, index });
    tail.apply(.{ .call_id = "c", .tool_name = "shell", .body = body.items, .body_kind = .command });
    const rows = try render(arena, &tail, 40, body_row_limit);
    const text = try plain(arena, rows);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("● Running python3", lines.next().?);
    try std.testing.expectEqualStrings("    … 6 earlier lines", lines.next().?);
    try std.testing.expectEqualStrings("    x5 = 5", lines.next().?);
    try std.testing.expectEqual(@as(usize, body_row_limit + 1), std.mem.count(u8, text, "\n") + 1);
    // Highlighting is applied to the live block.
    try std.testing.expect(rows.len > text.len);
    var row_iter = std.mem.splitScalar(u8, rows, '\n');
    while (row_iter.next()) |row| try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row) <= 40);
}

test "one-line commands sit in the header and edits read as diff lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tail: Tail = .{};
    tail.apply(.{ .call_id = "c", .tool_name = "shell", .body = "ls -la src", .body_kind = .command });
    try std.testing.expectEqualStrings("● Running ls -la src", try plain(arena, try render(arena, &tail, 80, body_row_limit)));
    tail.apply(.{ .call_id = "d", .tool_name = "edit_file", .subject = "app.py", .body = "-return 1\n+return 2", .body_kind = .diff });
    try std.testing.expectEqualStrings("● Editing app.py\n    -return 1\n    +return 2", try plain(arena, try render(arena, &tail, 80, body_row_limit)));
    tail.apply(.{ .call_id = "e", .tool_name = "web_search", .subject = "zig 0.17 release notes" });
    try std.testing.expectEqualStrings("● Searching zig 0.17 release notes", try plain(arena, try render(arena, &tail, 80, body_row_limit)));

    var cache: Cache = .{};
    const first = cache.view(&tail, 80, 40);
    try std.testing.expect(first.ptr == cache.view(&tail, 80, 40).ptr);
    // A short screen keeps two body rows.
    tail.apply(.{ .call_id = "f", .tool_name = "write_file", .subject = "a.txt", .body = "1\n2\n3\n4\n5\n6", .body_kind = .content });
    try std.testing.expectEqualStrings("● Writing a.txt\n    … 5 earlier lines\n    6", try plain(arena, cache.view(&tail, 80, 10)));
    try std.testing.expect(tail.clear());
    try std.testing.expectEqualStrings("", cache.view(&tail, 80, 40));
}
