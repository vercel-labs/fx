const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const edit_contract = @import("../input/editor_state.zig");
const text_boundaries = @import("../input/text_boundaries.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    active_choice: ?u8 = null,
    yes_draft: std.ArrayList(u8) = .empty,
    yes_cursor: usize = 0,
    no_draft: std.ArrayList(u8) = .empty,
    no_cursor: usize = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.discard(alloc, "deinit");
    }

    pub fn begin(self: *State, choice: u8) void {
        if (self.slotForChoice(choice) != null) self.active_choice = choice;
    }

    pub fn isActive(self: State) bool {
        return self.active_choice != null;
    }

    pub fn activeChoice(self: State) ?u8 {
        return self.active_choice;
    }

    pub fn draftForChoice(self: State, choice: u8) []const u8 {
        return switch (choice) {
            0 => self.yes_draft.items,
            2 => self.no_draft.items,
            else => "",
        };
    }

    pub fn cursorForChoice(self: State, choice: u8) usize {
        return switch (choice) {
            0 => self.yes_cursor,
            2 => self.no_cursor,
            else => 0,
        };
    }

    pub fn insert(self: *State, alloc: Allocator, byte: u8) !void {
        if (byte >= 0x80) return;
        try self.insertSlice(alloc, &.{byte});
    }

    pub fn insertSlice(self: *State, alloc: Allocator, bytes: []const u8) !void {
        const slot = self.activeSlot() orelse return;
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        try slot.draft.insertSlice(alloc, slot.cursor.*, bytes);
        slot.cursor.* += bytes.len;
    }

    pub fn backspace(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* == 0) return;
        const start = text_boundaries.previousCharacterStart(slot.draft.items, slot.cursor.*);
        const count = slot.cursor.* - start;
        @memmove(slot.draft.items[start .. slot.draft.items.len - count], slot.draft.items[slot.cursor.*..]);
        slot.draft.items.len -= count;
        slot.cursor.* = start;
    }

    pub fn cursorLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* > 0) {
            slot.cursor.* = text_boundaries.previousCharacterStart(slot.draft.items, slot.cursor.*);
        }
    }

    pub fn cursorRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* < slot.draft.items.len) {
            slot.cursor.* = text_boundaries.nextCharacterEnd(slot.draft.items, slot.cursor.*);
        }
    }

    pub fn cursorHome(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = 0;
    }

    pub fn cursorEnd(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = slot.draft.items.len;
    }

    pub fn cursorWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = text_boundaries.previousWordStart(slot.draft.items, slot.cursor.*);
    }

    pub fn cursorWordRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = text_boundaries.nextWordEnd(slot.draft.items, slot.cursor.*);
    }

    pub fn deleteNext(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* >= slot.draft.items.len) return;
        const end = text_boundaries.nextCharacterEnd(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    pub fn deleteWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const start = text_boundaries.previousWordStart(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteWhitespaceDelimitedWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const line_start = text_boundaries.logicalLineStart(slot.draft.items, slot.cursor.*);
        const start = text_boundaries.previousWhitespaceDelimitedTokenStart(
            slot.draft.items,
            slot.cursor.*,
            line_start,
        );
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteWordRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const end = text_boundaries.nextWordDeleteEnd(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    pub fn deleteToLineStart(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const start = text_boundaries.logicalLineStart(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteToLineEnd(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const line_end = text_boundaries.logicalLineEnd(slot.draft.items, slot.cursor.*);
        const end = if (slot.cursor.* == line_end and line_end < slot.draft.items.len)
            line_end + 1
        else
            line_end;
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    const Slot = struct {
        draft: *std.ArrayList(u8),
        cursor: *usize,
    };

    /// Single mapping from an amendable choice (0 = allow, 2 = deny) to the
    /// draft and cursor it owns. Every edit path dispatches through here so
    /// the two choices cannot drift.
    fn slotForChoice(self: *State, choice: u8) ?Slot {
        return switch (choice) {
            0 => .{ .draft = &self.yes_draft, .cursor = &self.yes_cursor },
            2 => .{ .draft = &self.no_draft, .cursor = &self.no_cursor },
            else => null,
        };
    }

    fn activeSlot(self: *State) ?Slot {
        return self.slotForChoice(self.active_choice orelse return null);
    }

    pub fn clearActive(self: *State) void {
        self.active_choice = null;
    }

    pub fn discard(self: *State, alloc: Allocator, reason: []const u8) void {
        self.discardDraft(alloc, &self.yes_draft, "yes", reason);
        self.discardDraft(alloc, &self.no_draft, "no", reason);
        self.active_choice = null;
        self.yes_cursor = 0;
        self.no_cursor = 0;
    }

    pub fn discardAfterSubmission(self: *State, alloc: Allocator, selected_choice: u8) void {
        if (selected_choice == 0) {
            self.yes_draft.deinit(alloc);
            self.yes_draft = .empty;
        } else {
            self.discardDraft(alloc, &self.yes_draft, "yes", "accepted_submission_unselected");
        }
        if (selected_choice == 2) {
            self.no_draft.deinit(alloc);
            self.no_draft = .empty;
        } else {
            self.discardDraft(alloc, &self.no_draft, "no", "accepted_submission_unselected");
        }
        self.active_choice = null;
        self.yes_cursor = 0;
        self.no_cursor = 0;
    }

    fn discardDraft(
        _: *State,
        alloc: Allocator,
        draft: *std.ArrayList(u8),
        choice: []const u8,
        reason: []const u8,
    ) void {
        if (draft.items.len > 0) {
            debug_trace.logf(
                "permission",
                "approval feedback discarded reason={s} choice={s} bytes={d}",
                .{ reason, choice, draft.items.len },
            );
        }
        draft.deinit(alloc);
        draft.* = .empty;
    }
};

test "approval amendment keeps separate drafts and discards them together" {
    const alloc = std.testing.allocator;
    var amendment = State{};
    defer amendment.deinit(alloc);

    amendment.begin(0);
    try amendment.insert(alloc, 'r');
    try amendment.insert(alloc, 'e');
    try std.testing.expectEqualStrings("re", amendment.draftForChoice(0));

    amendment.begin(2);
    try amendment.insert(alloc, 'n');
    try amendment.insert(alloc, 'o');
    try std.testing.expectEqualStrings("re", amendment.draftForChoice(0));
    try std.testing.expectEqualStrings("no", amendment.draftForChoice(2));

    amendment.discard(alloc, "test");
    try std.testing.expect(amendment.activeChoice() == null);
    try std.testing.expectEqualStrings("", amendment.draftForChoice(0));
    try std.testing.expectEqualStrings("", amendment.draftForChoice(2));
}

test "approval amendment edits both choices identically and clamps at draft bounds" {
    const alloc = std.testing.allocator;
    var amendment = State{};
    defer amendment.deinit(alloc);

    try amendment.insert(alloc, 'x');
    amendment.backspace();
    amendment.cursorLeft();
    amendment.cursorRight();
    try std.testing.expectEqualStrings("", amendment.draftForChoice(0));
    try std.testing.expectEqualStrings("", amendment.draftForChoice(2));

    amendment.begin(1);
    try std.testing.expect(amendment.activeChoice() == null);

    for ([_]u8{ 0, 2 }) |choice| {
        amendment.begin(choice);
        try amendment.insert(alloc, 'a');
        try amendment.insert(alloc, 'c');
        amendment.cursorLeft();
        try amendment.insert(alloc, 'b');
        amendment.cursorRight();
        amendment.backspace();
        amendment.cursorLeft();
        amendment.cursorLeft();
        amendment.cursorLeft();
        amendment.backspace();
        amendment.cursorRight();
        try std.testing.expectEqualStrings("ab", amendment.draftForChoice(choice));
        try std.testing.expectEqual(@as(usize, 1), amendment.cursorForChoice(choice));
    }
    try std.testing.expectEqualStrings("ab", amendment.draftForChoice(0));
    try std.testing.expectEqual(@as(usize, 1), amendment.cursorForChoice(0));
}

test "approval amendment edits terminal characters and navigation keys" {
    const alloc = std.testing.allocator;
    var amendment = State{};
    defer amendment.deinit(alloc);

    amendment.begin(0);
    try amendment.insertSlice(alloc, "A🙂B");
    amendment.cursorLeft();
    amendment.cursorLeft();
    try std.testing.expectEqual(@as(usize, 1), amendment.cursorForChoice(0));
    amendment.cursorRight();
    try std.testing.expectEqual(@as(usize, 5), amendment.cursorForChoice(0));
    amendment.backspace();
    try std.testing.expectEqualStrings("AB", amendment.draftForChoice(0));
    try std.testing.expectEqual(@as(usize, 1), amendment.cursorForChoice(0));

    amendment.discard(alloc, "test_reset");
    amendment.begin(2);
    try amendment.insertSlice(alloc, "alpha beta 👨‍👩‍👧‍👦");
    amendment.cursorWordLeft();
    try std.testing.expectEqual(@as(usize, "alpha beta ".len), amendment.cursorForChoice(2));
    amendment.deleteNext();
    try std.testing.expectEqualStrings("alpha beta ", amendment.draftForChoice(2));
    amendment.cursorHome();
    try std.testing.expectEqual(@as(usize, 0), amendment.cursorForChoice(2));
    amendment.cursorWordRight();
    try std.testing.expectEqual(@as(usize, "alpha".len), amendment.cursorForChoice(2));
    amendment.cursorEnd();
    try std.testing.expectEqual(amendment.draftForChoice(2).len, amendment.cursorForChoice(2));
}

test "approval amendment applies word and logical line deletions to either draft" {
    const alloc = std.testing.allocator;
    var amendment = State{};
    defer amendment.deinit(alloc);

    for ([_]u8{ 0, 2 }) |choice| {
        amendment.begin(choice);
        try amendment.insertSlice(alloc, "alpha beta");
        amendment.deleteWhitespaceDelimitedWordLeft();
        try std.testing.expectEqualStrings("alpha ", amendment.draftForChoice(choice));
        try std.testing.expectEqual(@as(usize, 6), amendment.cursorForChoice(choice));

        amendment.deleteWordLeft();
        try std.testing.expectEqualStrings("", amendment.draftForChoice(choice));
        try std.testing.expectEqual(@as(usize, 0), amendment.cursorForChoice(choice));

        try amendment.insertSlice(alloc, "one two\nthree four");
        amendment.cursorHome();
        amendment.deleteWordRight();
        try std.testing.expectEqualStrings("two\nthree four", amendment.draftForChoice(choice));

        amendment.cursorEnd();
        amendment.cursorWordLeft();
        amendment.deleteToLineStart();
        try std.testing.expectEqualStrings("two\nfour", amendment.draftForChoice(choice));
        try std.testing.expectEqual(@as(usize, "two\n".len), amendment.cursorForChoice(choice));

        amendment.deleteToLineEnd();
        try std.testing.expectEqualStrings("two\n", amendment.draftForChoice(choice));
    }

    amendment.discard(alloc, "test_reset");
    amendment.begin(0);
    try amendment.insertSlice(alloc, "alpha\nbeta");
    amendment.cursorHome();
    amendment.cursorWordRight();
    amendment.deleteToLineEnd();
    try std.testing.expectEqualStrings("alphabeta", amendment.draftForChoice(0));
    try std.testing.expectEqual(@as(usize, "alpha".len), amendment.cursorForChoice(0));
}

test "approval amendment deletion keeps terminal characters intact" {
    const alloc = std.testing.allocator;
    var amendment = State{};
    defer amendment.deinit(alloc);

    amendment.begin(0);
    try amendment.insertSlice(alloc, "one e\u{301}lan 🙂");
    amendment.deleteWordLeft();
    try std.testing.expectEqualStrings("one e\u{301}lan ", amendment.draftForChoice(0));
    amendment.deleteWordLeft();
    try std.testing.expectEqualStrings("one ", amendment.draftForChoice(0));
}

test "approval amendment traces discarded drafts with their reason" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "approval-feedback.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "permission");

    var amendment = State{};
    defer amendment.deinit(alloc);
    amendment.begin(0);
    try amendment.insert(alloc, 'y');
    amendment.begin(2);
    try amendment.insert(alloc, 'n');
    amendment.discard(alloc, "cancelled");

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "approval feedback discarded reason=cancelled choice=yes bytes=1") != null);
    try std.testing.expect(std.mem.find(u8, trace, "approval feedback discarded reason=cancelled choice=no bytes=1") != null);
}

test "approval amendment traces the unselected draft after submission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "approval-feedback-accepted.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "permission");

    var amendment = State{};
    defer amendment.deinit(alloc);
    amendment.begin(0);
    try amendment.insert(alloc, 'y');
    amendment.begin(2);
    try amendment.insert(alloc, 'n');
    amendment.discardAfterSubmission(alloc, 0);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "approval feedback discarded reason=accepted_submission_unselected choice=no bytes=1") != null);
}
