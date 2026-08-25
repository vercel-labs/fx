const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const kill_ring = @import("kill_ring.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_boundaries = @import("text_boundaries.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const DeleteKind = enum {
    whitespace_word_left,
    line_start,
    line_end,
};

const DeleteRequest = struct {
    bounds: kill_ring.LineBounds,
    range: kill_ring.DeleteRange,
};

/// Borrows the Core state changed by composer kill and yank actions.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    ring: *kill_ring.State,
    history: *edit_history.State,
    active: kill_ring.ActiveComposer,

    pub fn delete(self: State, alloc: Allocator, kind: DeleteKind) !bool {
        if (kind == .whitespace_word_left) {
            self.active.vertical_navigation.reset();
        }
        const request = deleteRequest(
            self.active.edit,
            self.active.entities,
            kind,
        ) orelse return false;
        return self.deleteRange(alloc, request);
    }

    pub fn yank(
        self: State,
        alloc: Allocator,
        first_image_id: usize,
        max_len: usize,
    ) !kill_ring.YankResult {
        const selection = self.active.edit.selectionRange();
        const start = if (selection) |range| range.start else self.active.edit.cursor;
        const removed = if (selection) |range|
            self.active.edit.input.items[range.start..range.end]
        else
            "";
        const selection_has_entity = if (selection) |range|
            self.active.entities.entityOverlapping(range.start, range.end) != null
        else
            false;
        const structured = self.ring.images.items.len > 0 or
            self.ring.image_tokens.items.len > 0 or
            self.ring.skill_tokens.items.len > 0 or
            selection_has_entity;
        var prepared = if (structured)
            edit_history.Prepared.boundary
        else
            try self.history.prepare(
                alloc,
                start,
                removed,
                self.ring.text.items,
                self.active.edit.cursor,
                start + self.ring.text.items.len,
            );
        defer prepared.deinit(alloc);

        const result = try self.ring.yank(
            alloc,
            self.active,
            first_image_id,
            max_len,
        );
        switch (result) {
            .inserted => self.history.commit(alloc, &prepared),
            .inactive, .limit_exceeded => {},
        }
        return result;
    }

    fn deleteRange(
        self: State,
        alloc: Allocator,
        request: DeleteRequest,
    ) !bool {
        const structured = self.active.entities.entityOverlapping(
            request.range.start,
            request.range.end,
        ) != null;
        var prepared = if (structured)
            edit_history.Prepared.boundary
        else
            try self.history.prepare(
                alloc,
                request.range.start,
                self.active.edit.input.items[request.range.start..request.range.end],
                "",
                self.active.edit.cursor,
                request.range.start,
            );
        defer prepared.deinit(alloc);

        const changed = try self.ring.deleteRange(
            alloc,
            self.active,
            request.bounds,
            request.range,
        );
        if (changed) self.history.commit(alloc, &prepared);
        return changed;
    }
};

fn deleteRequest(
    edit: *const editor_state.State,
    entities: *const registered_entities.State,
    kind: DeleteKind,
) ?DeleteRequest {
    if (edit.selectionRange()) |selection| {
        return .{
            .bounds = .{
                .start = selection.start,
                .cursor = selection.end,
                .end = selection.end,
            },
            .range = .{ .start = selection.start, .end = selection.end },
        };
    }

    const bounds = kill_ring.lineBounds(edit.input.items, edit.cursor);
    const range = switch (kind) {
        .whitespace_word_left => whitespaceWordLeftRange(
            edit.input.items,
            bounds,
            entities,
        ),
        .line_start => kill_ring.DeleteRange{
            .start = bounds.start,
            .end = bounds.cursor,
        },
        .line_end => kill_ring.DeleteRange{
            .start = bounds.cursor,
            .end = if (bounds.cursor == bounds.end and bounds.end < edit.input.items.len)
                bounds.end + 1
            else
                bounds.end,
        },
    };
    if (range.start >= range.end) return null;
    return .{ .bounds = bounds, .range = range };
}

fn whitespaceWordLeftRange(
    input: []const u8,
    bounds: kill_ring.LineBounds,
    entities: *const registered_entities.State,
) kill_ring.DeleteRange {
    var start = bounds.cursor;
    while (start > bounds.start) {
        const previous = text_boundaries.previousCharacterStart(input, start);
        const rune = display_width.decodeNextRune(input, previous);
        if (!isWhitespaceRune(rune.codepoint)) break;
        start = previous;
    }
    while (start > bounds.start) {
        if (entities.entityEndingAt(input, start)) |entity| {
            start = entity.span.raw_start;
            break;
        }
        const previous = text_boundaries.previousCharacterStart(input, start);
        const rune = display_width.decodeNextRune(input, previous);
        if (isWhitespaceRune(rune.codepoint)) break;
        start = previous;
    }
    return .{ .start = start, .end = bounds.cursor };
}

fn isWhitespaceRune(codepoint: u21) bool {
    return codepoint <= 0x7f and std.ascii.isWhitespace(@intCast(codepoint));
}

const Fixture = struct {
    ring: kill_ring.State = .{},
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.ring.deinit(alloc);
        self.edit.deinit(alloc);
        self.history.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
    }

    fn state(self: *Fixture) State {
        return .{
            .ring = &self.ring,
            .history = &self.history,
            .active = .{
                .edit = &self.edit,
                .entities = &self.entities,
                .picker = &self.picker,
                .vertical_navigation = &self.vertical_navigation,
                .input_limit_rejection = &self.input_limit_rejection,
                .images = null,
            },
        };
    }
};

test "delete requests keep selection precedence and logical line ownership pure" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "alpha\nleftMIDright\ngamma");
    fixture.edit.cursor = "alpha\nleftMID".len;

    try std.testing.expectEqual(
        DeleteRequest{
            .bounds = .{
                .start = "alpha\n".len,
                .cursor = "alpha\nleftMID".len,
                .end = "alpha\nleftMIDright".len,
            },
            .range = .{
                .start = "alpha\n".len,
                .end = "alpha\nleftMID".len,
            },
        },
        deleteRequest(&fixture.edit, &fixture.entities, .line_start).?,
    );
    try std.testing.expectEqual(
        DeleteRequest{
            .bounds = .{
                .start = "alpha\n".len,
                .cursor = "alpha\nleftMID".len,
                .end = "alpha\nleftMIDright".len,
            },
            .range = .{
                .start = "alpha\nleftMID".len,
                .end = "alpha\nleftMIDright".len,
            },
        },
        deleteRequest(&fixture.edit, &fixture.entities, .line_end).?,
    );

    _ = fixture.edit.beginSelection(14);
    _ = fixture.edit.extendSelection(8);
    for (std.enums.values(DeleteKind)) |kind| {
        try std.testing.expectEqual(
            DeleteRequest{
                .bounds = .{ .start = 8, .cursor = 14, .end = 14 },
                .range = .{ .start = 8, .end = 14 },
            },
            deleteRequest(&fixture.edit, &fixture.entities, kind).?,
        );
    }
}

test "plain kill and yank each record one edit history delta" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "foo-bar  ");
    fixture.edit.cursor = fixture.edit.input.items.len;

    try std.testing.expect(try fixture.state().delete(
        alloc,
        .whitespace_word_left,
    ));
    try std.testing.expectEqualStrings("", fixture.edit.input.items);
    try std.testing.expectEqualStrings("foo-bar  ", fixture.ring.text.items);
    try std.testing.expectEqualStrings(
        "foo-bar  ",
        fixture.history.peekUndo().?.removed.items,
    );

    fixture.history.reset(alloc);
    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 0 },
        try fixture.state().yank(alloc, 1, 4096),
    );
    try std.testing.expectEqualStrings("foo-bar  ", fixture.edit.input.items);
    try std.testing.expectEqualStrings(
        "foo-bar  ",
        fixture.history.peekUndo().?.inserted.items,
    );
}

test "structured kill and yank remain edit history boundaries" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "$rev");
    try fixture.entities.bindSkillToken(
        alloc,
        &fixture.edit,
        0,
        fixture.edit.input.items.len,
        "review",
        "/skills/review.md",
        null,
        null,
    );

    var before_kill = try fixture.history.prepare(alloc, 0, "", "x", 0, 1);
    defer before_kill.deinit(alloc);
    fixture.history.commit(alloc, &before_kill);
    try std.testing.expect(try fixture.state().delete(alloc, .line_start));
    try std.testing.expect(fixture.history.peekUndo() == null);

    var before_yank = try fixture.history.prepare(alloc, 0, "", "x", 0, 1);
    defer before_yank.deinit(alloc);
    fixture.history.commit(alloc, &before_yank);
    try std.testing.expectEqual(
        kill_ring.YankResult{ .inserted = 0 },
        try fixture.state().yank(alloc, 1, 4096),
    );
    try std.testing.expect(fixture.history.peekUndo() == null);
}

test "history allocation failure preserves composer and kill ring state" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "alpha");
    fixture.edit.cursor = fixture.edit.input.items.len;
    try fixture.ring.text.appendSlice(alloc, "previous kill");

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        fixture.state().delete(failing.allocator(), .line_start),
    );
    try std.testing.expectEqualStrings("alpha", fixture.edit.input.items);
    try std.testing.expectEqualStrings("previous kill", fixture.ring.text.items);
    try std.testing.expect(fixture.history.peekUndo() == null);
}
