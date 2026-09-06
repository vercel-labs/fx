// Renders submitted user turns and owns their row collection and wrapping.
const std = @import("std");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const visual_layout = @import("../input/visual_layout.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

const reset_style = "\x1b[0m";
const prompt_text_style = "\x1b[1m";
const restore_prompt_text_style = reset_style ++ prompt_text_style;
const user_turn_rail = "┃";
const dark_marker_style = "\x1b[38;5;255m";
const light_marker_style = "\x1b[38;5;235m";
const osc8_prefix = "\x1b]8;;";
const osc8_terminator = "\x1b\\";
const osc8_close = osc8_prefix ++ osc8_terminator;

const accent_dark = "\x1b[38;5;252m";
const accent_light = "\x1b[38;5;238m";
var accent_style: []const u8 = accent_dark;

var marker_style: []const u8 = dark_marker_style;

pub fn setStyle(light: bool, _: ?Rgb) void {
    marker_style = if (light) light_marker_style else dark_marker_style;
    accent_style = if (light) accent_light else accent_dark;
}

pub fn promptMarkerStyle() []const u8 {
    return marker_style;
}

fn emitRow(writer: *std.Io.Writer, content: []const u8) !void {
    try writer.writeAll(content);
    try writer.writeAll(reset_style);
    try writer.writeByte('\n');
}

fn lastSpaceIn(slice: []const u8) ?usize {
    var i: usize = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == ' ' or slice[i] == '\t') return i;
    }
    return null;
}

// Returns display-safe keep and skip boundaries, preferring whitespace.
const WrapCut = struct { keep_bytes: usize, skip_bytes: usize };

fn wrapCut(text: []const u8, row_budget: usize) WrapCut {
    if (row_budget == 0) return .{ .keep_bytes = 0, .skip_bytes = 0 };
    const prefix = display_width.prefixByWidthIgnoringAnsi(text, row_budget);
    if (prefix.len == text.len) return .{ .keep_bytes = prefix.len, .skip_bytes = prefix.len };

    if (lastSpaceIn(prefix)) |sp| {
        return .{ .keep_bytes = sp, .skip_bytes = sp + 1 };
    }

    // Force one display unit when no break point fits so the loop advances.
    if (prefix.len == 0) {
        var end: usize = 0;
        while (end < text.len and text[end] == 0x1b) {
            end = display_width.ansiSequenceEnd(text, end);
        }
        const unit = display_width.displayUnitAt(text, end);
        if (unit.byte_len == 0) return .{ .keep_bytes = 0, .skip_bytes = text.len };
        return .{ .keep_bytes = end + unit.byte_len, .skip_bytes = end + unit.byte_len };
    }
    return .{ .keep_bytes = prefix.len, .skip_bytes = prefix.len };
}

pub fn buildUserPromptCard(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
) ![]u8 {
    return buildUserPromptCardWithSkillTokens(alloc, text, images, cols, &.{});
}

pub fn buildUserPromptCardWithSkillTokens(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinks(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        false,
    );
}

pub fn buildUserPromptCardWithSkillTokensForTerminalPresentation(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        true,
        checkpoint,
        null,
    );
}

pub fn buildUserPromptCardTailForTerminalPresentationInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    max_rows: usize,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    // The pending-frame path retains only the newest rows that fit its current
    // transcript band; canonical formatting remains shared with ordinary turns.
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        true,
        checkpoint,
        max_rows,
    );
}

fn buildUserPromptCardWithSkillTokensAndLinks(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    linked_images: bool,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        linked_images,
        null,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn buildUserPromptCardWithSkillTokensAndLinksInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    linked_images: bool,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    max_rows: ?usize,
) ![]u8 {
    const window: usize = if (cols > 2) @as(usize, cols) - 2 else 0;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (window == 0) {
        try build_checkpoint.consume(checkpoint, text.len +| images.len);
        return out.toOwnedSlice();
    }
    if (text.len == 0 and images.len == 0) {
        return out.toOwnedSlice();
    }

    const token_text = if (skill_tokens.len > 0)
        try renderSkillTokensForCard(alloc, text, skill_tokens)
    else
        text;
    defer if (skill_tokens.len > 0) alloc.free(token_text);

    var expanded_buf: std.Io.Writer.Allocating = .init(alloc);
    defer expanded_buf.deinit();
    if (images.len > 0) {
        _ = if (linked_images)
            try image_attachments.expandPlaceholdersWithLinkedBadges(
                alloc,
                &expanded_buf.writer,
                token_text,
                images,
                null,
            )
        else
            try image_attachments.expandPlaceholdersWithBadges(
                alloc,
                &expanded_buf.writer,
                token_text,
                images,
                null,
            );
    } else {
        try expanded_buf.writer.writeAll(token_text);
    }
    const display_text = expanded_buf.written();

    var rows: std.ArrayList([]const u8) = .empty;
    defer {
        for (rows.items) |r| alloc.free(r);
        rows.deinit(alloc);
    }

    var row_buf: std.Io.Writer.Allocating = .init(alloc);
    defer row_buf.deinit();

    try collectLogicalLinesWithFirstPrefix(
        alloc,
        &rows,
        &row_buf,
        display_text,
        window,
        checkpoint,
        max_rows,
    );

    for (rows.items) |content| {
        try emitRow(&out.writer, content);
    }

    return out.toOwnedSlice();
}

fn renderSkillTokensForCard(
    alloc: std.mem.Allocator,
    text: []const u8,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var pos: usize = 0;
    for (skill_tokens) |token| {
        if (token.raw_start < pos or token.raw_end > text.len or token.raw_start >= token.raw_end) continue;
        if (token.name.len == 0) continue;

        try out.writer.writeAll(text[pos..token.raw_start]);
        try out.writer.writeAll(accent_style);
        try out.writer.writeAll(token.name);
        try out.writer.writeAll(restore_prompt_text_style);
        pos = token.raw_end;
    }
    try out.writer.writeAll(text[pos..]);
    return try out.toOwnedSlice();
}

// Dupes `content` into the row list.
fn appendRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    content: []const u8,
) !void {
    const dup = try alloc.dupe(u8, content);
    errdefer alloc.free(dup);
    try rows.append(alloc, dup);
}

fn appendVisibleRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    content: []const u8,
    max_rows: ?usize,
) !void {
    if (max_rows) |limit| {
        if (limit == 0) return;
        if (rows.items.len == limit) {
            alloc.free(rows.orderedRemove(0));
        }
    }
    try appendRow(alloc, rows, content);
}

fn writeRowPrefix(writer: *std.Io.Writer) !void {
    try writer.writeAll(marker_style);
    try writer.writeAll(user_turn_rail);
    try writer.writeAll(reset_style);
    try writer.writeByte(' ');
    try writer.writeAll(prompt_text_style);
}

fn hyperlinkStateAfter(fragment: []const u8, initial: ?[]const u8) ?[]const u8 {
    var active = initial;
    var offset: usize = 0;
    while (std.mem.findPos(u8, fragment, offset, osc8_prefix)) |start| {
        const target_start = start + osc8_prefix.len;
        const target_end = std.mem.findPos(
            u8,
            fragment,
            target_start,
            osc8_terminator,
        ) orelse break;
        const sequence_end = target_end + osc8_terminator.len;
        active = if (target_end == target_start)
            null
        else
            fragment[start..sequence_end];
        offset = sequence_end;
    }
    return active;
}

// Wraps `text` onto rows and repeats the rail so adjacent rows stay connected.
fn collectLogicalLinesWithFirstPrefix(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    row_buf: *std.Io.Writer.Allocating,
    text: []const u8,
    window: usize,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    max_rows: ?usize,
) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try build_checkpoint.tick(checkpoint);
        var active_hyperlink: ?[]const u8 = null;
        var remaining = line;
        if (remaining.len == 0) {
            row_buf.clearRetainingCapacity();
            try writeRowPrefix(&row_buf.writer);
            try appendVisibleRow(alloc, rows, row_buf.written(), max_rows);
            continue;
        }
        while (remaining.len > 0) {
            const c = wrapCut(remaining, window);
            try build_checkpoint.consume(checkpoint, @max(c.keep_bytes, c.skip_bytes));
            const fragment = remaining[0..c.keep_bytes];
            row_buf.clearRetainingCapacity();
            try writeRowPrefix(&row_buf.writer);
            if (active_hyperlink) |opener| try row_buf.writer.writeAll(opener);
            try row_buf.writer.writeAll(fragment);
            active_hyperlink = hyperlinkStateAfter(fragment, active_hyperlink);
            if (active_hyperlink != null) try row_buf.writer.writeAll(osc8_close);
            try appendVisibleRow(alloc, rows, row_buf.written(), max_rows);
            remaining = remaining[c.skip_bytes..];
        }
    }
}

test "minimum-width prompt wrapping remains interruptible" {
    const Probe = struct {
        polls: usize = 0,

        fn pending(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.polls += 1;
            return true;
        }
    };
    const alloc = std.testing.allocator;
    const text = try alloc.alloc(u8, 8 * 1024);
    defer alloc.free(text);
    @memset(text, 'x');
    var probe = Probe{};
    var checkpoint = build_checkpoint.BuildCheckpoint.init(&probe, Probe.pending);

    try std.testing.expectError(
        error.InputPending,
        buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
            alloc,
            text,
            &.{},
            2,
            &.{},
            &checkpoint,
        ),
    );
}

fn assertRowStructure(card: []const u8) !void {
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expect(std.mem.find(u8, row, user_turn_rail) != null);
        try std.testing.expect(std.mem.find(u8, row, "❯") == null);
        try std.testing.expect(std.mem.find(u8, row, "\x1b[48;") == null);
        try std.testing.expect(std.mem.find(u8, row, "\x1b[K") == null);
        try std.testing.expect(std.mem.endsWith(u8, row, reset_style));
    }
}

fn countRows(card: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len > 0) count += 1;
    }
    return count;
}

test "current presentation removes the card background and accents only the rail" {
    const alloc = std.testing.allocator;
    defer setStyle(false, null);

    setStyle(false, null);
    const card = try buildUserPromptCard(alloc, "hello", &.{}, 80);
    defer alloc.free(card);

    try std.testing.expect(std.mem.startsWith(u8, card, "\x1b[38;5;255m┃\x1b[0m \x1b[1mhello"));
    try std.testing.expect(std.mem.endsWith(u8, card, "\x1b[0m\n"));
    try std.testing.expect(std.mem.find(u8, card, "\x1b[48;") == null);
    try std.testing.expect(std.mem.find(u8, card, "\x1b[K") == null);
}

test "current presentation uses a connected rail on every prompt row" {
    const alloc = std.testing.allocator;
    defer setStyle(false, null);

    setStyle(false, null);
    const card = try buildUserPromptCard(alloc, "line one\nline two", &.{}, 80);
    defer alloc.free(card);

    try std.testing.expectEqualStrings(
        "\x1b[38;5;255m┃\x1b[0m \x1b[1mline one\x1b[0m\n" ++
            "\x1b[38;5;255m┃\x1b[0m \x1b[1mline two\x1b[0m\n",
        card,
    );
    try std.testing.expect(std.mem.find(u8, card, "❯") == null);
}

test "current presentation uses a theme-aware prompt rail" {
    const alloc = std.testing.allocator;
    defer setStyle(false, null);

    setStyle(false, null);
    const dark_card = try buildUserPromptCard(alloc, "hello", &.{}, 80);
    defer alloc.free(dark_card);
    try std.testing.expect(std.mem.startsWith(u8, dark_card, "\x1b[38;5;255m┃\x1b[0m \x1b[1mhello"));

    setStyle(true, null);
    const light_card = try buildUserPromptCard(alloc, "hello", &.{}, 80);
    defer alloc.free(light_card);
    try std.testing.expect(std.mem.startsWith(u8, light_card, "\x1b[38;5;235m┃\x1b[0m \x1b[1mhello"));
}

test "current presentation restores bold prompt text after skill tokens" {
    const alloc = std.testing.allocator;
    defer setStyle(false, null);

    setStyle(false, null);
    const tokens = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 4,
        .raw_end = 11,
        .name = "review",
        .path = "/tmp/review",
    }};
    const card = try buildUserPromptCardWithSkillTokens(
        alloc,
        "use $review now",
        &.{},
        80,
        &tokens,
    );
    defer alloc.free(card);

    try std.testing.expect(std.mem.find(u8, card, "\x1b[38;5;252mreview\x1b[0m\x1b[1m now") != null);
    try std.testing.expect(std.mem.endsWith(u8, card, "\x1b[0m\n"));
}

test "buildUserPromptCard row content width hugs message" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "hello", &.{}, 80);
    defer alloc.free(card);

    var it = std.mem.splitScalar(u8, card, '\n');
    const row = it.next() orelse return error.TestMissingRow;
    const visible_width = display_width.visibleWidthIgnoringAnsi(row);
    try std.testing.expectEqual(@as(usize, 7), visible_width);
    try std.testing.expect(visible_width < 80);
}

test "buildUserPromptCard handles degenerate cols" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "anything", &.{}, 1);
    defer alloc.free(card);

    try std.testing.expectEqual(@as(usize, 0), card.len);
}

test "buildUserPromptCard handles empty input" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "", &.{}, 80);
    defer alloc.free(card);

    try std.testing.expectEqual(@as(usize, 0), card.len);
}

test "buildUserPromptCard preserves multi-line text via \\n" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "line one\nline two", &.{}, 80);
    defer alloc.free(card);

    try assertRowStructure(card);
    try std.testing.expectEqual(@as(usize, 2), countRows(card));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, card, user_turn_rail));
    try std.testing.expect(std.mem.find(u8, card, "line one") != null);
    try std.testing.expect(std.mem.find(u8, card, "line two") != null);
}

test "buildUserPromptCardWithSkillTokens colors selected skills without dollar prefix" {
    setStyle(false, null);
    const alloc = std.testing.allocator;
    const tokens = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 4,
        .raw_end = 11,
        .name = "review",
        .path = "/tmp/review",
    }};
    const card = try buildUserPromptCardWithSkillTokens(alloc, "use $review now", &.{}, 80, &tokens);
    defer alloc.free(card);

    try std.testing.expect(std.mem.find(u8, card, accent_style) != null);
    try std.testing.expect(std.mem.find(u8, card, "review") != null);
    try std.testing.expect(std.mem.find(u8, card, "$review") == null);
}

test "buildUserPromptCardWithSkillTokens hides an ambiguous source" {
    setStyle(false, null);
    const alloc = std.testing.allocator;
    const tokens = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = 4,
        .raw_end = 11,
        .name = "review",
        .path = "/tmp/review",
        .display_source = .workspace_codex,
    }};
    const card = try buildUserPromptCardWithSkillTokens(alloc, "use $review now", &.{}, 80, &tokens);
    defer alloc.free(card);

    try std.testing.expect(std.mem.find(u8, card, "review") != null);
    try std.testing.expect(std.mem.find(u8, card, "workspace .codex") == null);
    try std.testing.expect(std.mem.find(u8, card, "$review") == null);
}

test "buildUserPromptCardWithSkillTokens only strips selected duplicate skill spans" {
    setStyle(false, null);
    const alloc = std.testing.allocator;
    const text = "raw $review then $review";
    const tokens = [_]visual_layout.SkillTokenSpan{.{
        .raw_start = "raw $review then ".len,
        .raw_end = text.len,
        .name = "review",
        .path = "/tmp/review",
    }};
    const card = try buildUserPromptCardWithSkillTokens(alloc, text, &.{}, 80, &tokens);
    defer alloc.free(card);

    try std.testing.expect(std.mem.find(u8, card, "$review then ") != null);
    try std.testing.expect(std.mem.find(u8, card, accent_style) != null);
    try std.testing.expect(std.mem.find(u8, card, "$review then $review") == null);
}

test "buildUserPromptCard wraps on word boundary" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const cols: u16 = 20;
    const card = try buildUserPromptCard(alloc, "the quick brown fox jumps over the lazy dog", &.{}, cols);
    defer alloc.free(card);

    try assertRowStructure(card);
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row) <= @as(usize, cols));
    }
}

test "buildUserPromptCard cuts within wide-char grapheme by display width" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "a😀b", &.{}, 5);
    defer alloc.free(card);

    try assertRowStructure(card);
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row) <= 5);
    }
    try std.testing.expect(std.mem.find(u8, card, "😀") != null);
}

test "buildUserPromptCard terminates when a wide glyph exceeds window" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const card = try buildUserPromptCard(alloc, "😀", &.{}, 3);
    defer alloc.free(card);

    try std.testing.expect(card.len > 0);
}

test "buildUserPromptCard handles image-only input" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const image = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/x.png"),
        .media_type = @constCast("image/png"),
    };
    const images = [_]types.ImageAttachment{image};

    const card = try buildUserPromptCard(alloc, "[Image #1]", &images, 80);
    defer alloc.free(card);

    try assertRowStructure(card);
    try std.testing.expect(std.mem.find(u8, card, "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, card, "file://") == null);
    try std.testing.expect(std.mem.find(u8, card, "/tmp/x.png") == null);
}

test "buildUserPromptCard handles image + text inline" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const image = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/x.png"),
        .media_type = @constCast("image/png"),
    };
    const images = [_]types.ImageAttachment{image};

    const card = try buildUserPromptCard(alloc, "before [Image #1] after", &images, 80);
    defer alloc.free(card);

    try assertRowStructure(card);
    try std.testing.expect(std.mem.find(u8, card, "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, card, "before ") != null);
    try std.testing.expect(std.mem.find(u8, card, " after") != null);
    try std.testing.expectEqual(@as(usize, 1), countRows(card));
}

test "buildUserPromptCard wraps when badge + text overflows" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const image = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/x.png"),
        .media_type = @constCast("image/png"),
    };
    const images = [_]types.ImageAttachment{image};

    const cols: u16 = 20;
    const card = try buildUserPromptCard(alloc, "[Image #1] the quick brown fox", &images, cols);
    defer alloc.free(card);

    try assertRowStructure(card);

    var it = std.mem.splitScalar(u8, card, '\n');
    const first_content = it.next() orelse return error.TestMissingContentRow;
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(first_content) <= @as(usize, cols));

    try std.testing.expect(std.mem.count(u8, card, user_turn_rail) > 1);
}

test "terminal image badges balance hyperlinks across narrow card rows" {
    setStyle(false, null);
    const alloc = std.testing.allocator;
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/x.png"),
        .media_type = @constCast("image/png"),
    }};

    const card = try buildUserPromptCardWithSkillTokensForTerminalPresentation(
        alloc,
        "AA [Image #1] ZZZ",
        &images,
        7,
        &.{},
    );
    defer alloc.free(card);

    var linked_cells: usize = 0;
    var rows = std.mem.splitScalar(u8, card, '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expectEqual(
            std.mem.count(u8, row, osc8_prefix) - std.mem.count(u8, row, osc8_close),
            std.mem.count(u8, row, osc8_close),
        );

        var grid = try vt_emulator.Grid.init(alloc, 80, 1);
        defer grid.deinit();
        try grid.feed(row);
        try std.testing.expectEqual(@as(u32, 0), grid.current_style.hyperlink_id);

        var col: u16 = 1;
        while (col <= grid.cols) : (col += 1) {
            const cell = grid.cellAt(1, col).?;
            if (cell.style.hyperlink_id != 0) {
                linked_cells += 1;
                try std.testing.expectEqualStrings(
                    "file:///tmp/x.png",
                    grid.hyperlinkUrl(cell.style.hyperlink_id).?,
                );
            }
            if (cell.codepoint == '┃' or cell.codepoint == 'Z' or cell.codepoint == 'A') {
                try std.testing.expectEqual(@as(u32, 0), cell.style.hyperlink_id);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, "[Image 1]".len), linked_cells);
}

test "buildUserPromptCard renders multiple inline placeholders" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/a.png"), .media_type = @constCast("image/png") },
        .{ .id = 2, .path = @constCast("/tmp/b.png"), .media_type = @constCast("image/png") },
        .{ .id = 3, .path = @constCast("/tmp/c.png"), .media_type = @constCast("image/png") },
    };

    const card = try buildUserPromptCard(alloc, "[Image #1] [Image #2] [Image #3]", &images, 80);
    defer alloc.free(card);

    try assertRowStructure(card);
    try std.testing.expect(std.mem.find(u8, card, "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, card, "[Image 2]") != null);
    try std.testing.expect(std.mem.find(u8, card, "[Image 3]") != null);
}

test "buildUserPromptCard labels each turn's image with its own id" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const first_images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
    };
    const second_images = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/two.png"), .media_type = @constCast("image/png") },
    };

    const first = try buildUserPromptCard(alloc, "[Image #1] first turn", &first_images, 80);
    defer alloc.free(first);
    const second = try buildUserPromptCard(alloc, "[Image #2] second turn", &second_images, 80);
    defer alloc.free(second);

    try assertRowStructure(first);
    try assertRowStructure(second);
    try std.testing.expect(std.mem.find(u8, first, "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, second, "[Image 2]") != null);
    try std.testing.expect(std.mem.find(u8, second, "[Image 1]") == null);
}

test "buildUserPromptCard handles leading newline with image" {
    setStyle(false, null);
    const alloc = std.testing.allocator;

    const image = types.ImageAttachment{
        .id = 1,
        .path = @constCast("/tmp/x.png"),
        .media_type = @constCast("image/png"),
    };
    const images = [_]types.ImageAttachment{image};

    const card = try buildUserPromptCard(alloc, "\n[Image #1] after", &images, 80);
    defer alloc.free(card);

    try assertRowStructure(card);
    try std.testing.expect(std.mem.find(u8, card, "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, card, "after") != null);
}

test "pending terminal card keeps only the visible tail rows" {
    const alloc = std.testing.allocator;
    const card = try buildUserPromptCardTailForTerminalPresentationInterruptible(
        alloc,
        "row0\nrow1\nrow2\nrow3\nrow4",
        &.{},
        80,
        &.{},
        2,
        null,
    );
    defer alloc.free(card);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, card, "\n"));
    try std.testing.expect(std.mem.find(u8, card, "row0") == null);
    try std.testing.expect(std.mem.find(u8, card, "row2") == null);
    try std.testing.expect(std.mem.find(u8, card, "row3") != null);
    try std.testing.expect(std.mem.find(u8, card, "row4") != null);
}
