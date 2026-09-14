const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_contract = @import("../input/editor_state.zig");
const io_mod = @import("../shared/io.zig");
const text_boundaries = @import("../input/text_boundaries.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ChoiceDirection = enum {
    previous,
    next,
};

pub const FreeformAction = enum {
    cursor_left,
    cursor_right,
    cursor_home,
    cursor_end,
    cursor_word_left,
    cursor_word_right,
    delete_next,
    delete_word_left,
    delete_whitespace_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
};

pub const Action = union(enum) {
    cancel,
    submit,
    next_entry,
    backspace,
    select_ordinal: u8,
    insert_ascii: u8,
    move_choice: ChoiceDirection,
    edit_freeform: FreeformAction,
};

pub const QuestionInputEvent = union(enum) {
    none,
    redraw,
    /// Answer stored, but at least one batch entry remains unanswered.
    decision: u8,
    /// Every batch entry has `answer != null`.
    all_decided,
    cancelled,
    limit_exceeded,
};

pub const FreeformInsertResult = edit_contract.InsertResult;

/// Always-on synthetic option appended to every entry by the prompt so the
/// user has a freeform escape hatch when none of the model's options fit.
/// The model never sees or chooses this slot.
pub const freeform_option_label = "Other";

pub const OwnedQuestionOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
    is_freeform_slot: bool = false,
};

pub const OwnedQuestionEntry = struct {
    question: []const u8,
    options: std.ArrayList(OwnedQuestionOption) = .empty,
    choice_index: u8 = 0,
    confirmed_choice_index: ?u8 = null,
    /// Either borrowed from an option label or a slice into
    /// `confirmed_freeform_buffer.items`. Non-null once confirmed.
    answer: ?[]const u8 = null,
    freeform_buffer: std.ArrayList(u8) = .empty,
    confirmed_freeform_buffer: std.ArrayList(u8) = .empty,
    freeform_cursor: usize = 0,
    freeform_preferred_column: ?usize = null,

    pub fn deinit(self: *OwnedQuestionEntry, alloc: Allocator) void {
        alloc.free(self.question);
        for (self.options.items) |opt| {
            alloc.free(opt.label);
            if (opt.description) |desc| alloc.free(desc);
        }
        self.options.deinit(alloc);
        self.freeform_buffer.deinit(alloc);
        self.confirmed_freeform_buffer.deinit(alloc);
    }
};

pub const EntryProjection = struct {
    question: []const u8,
    options: []const OwnedQuestionOption,
    choice_index: usize,
    freeform_buffer: []const u8,
    freeform_cursor: usize,
};

pub const Projection = struct {
    current_entry: ?EntryProjection,
    current_index: usize,
    entry_count: usize,

    pub fn isFreeformSelected(self: Projection) bool {
        const entry = self.current_entry orelse return false;
        if (entry.options.len == 0) return false;
        const selected_index = @min(entry.choice_index, entry.options.len - 1);
        return entry.options[selected_index].is_freeform_slot;
    }
};

pub const QuestionPrompt = struct {
    active: bool = false,
    entries: std.ArrayList(OwnedQuestionEntry) = .empty,
    current_index: u8 = 0,

    pub fn deinit(self: *QuestionPrompt, alloc: Allocator) void {
        self.discard(alloc, "deinit");
        self.entries.deinit(alloc);
    }

    pub fn isActive(self: QuestionPrompt) bool {
        return self.active;
    }

    /// Returns a borrowed immutable view of the active prompt. Every slice in
    /// the projection remains valid only until the next prompt mutation.
    pub fn projection(self: *const QuestionPrompt) ?Projection {
        if (!self.active) return null;
        const current_index: usize = self.current_index;
        const current_entry: ?EntryProjection = if (current_index < self.entries.items.len) blk: {
            const entry = self.entries.items[current_index];
            break :blk .{
                .question = entry.question,
                .options = entry.options.items,
                .choice_index = entry.choice_index,
                .freeform_buffer = entry.freeform_buffer.items,
                .freeform_cursor = entry.freeform_cursor,
            };
        } else null;
        return .{
            .current_entry = current_entry,
            .current_index = current_index,
            .entry_count = self.entries.items.len,
        };
    }

    pub fn discard(self: *QuestionPrompt, alloc: Allocator, reason: []const u8) void {
        self.active = false;
        self.current_index = 0;
        for (self.entries.items, 0..) |*entry, entry_index| {
            traceDraftDiscard(entry, entry_index, reason);
            entry.deinit(alloc);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn resetAfterSubmission(self: *QuestionPrompt, alloc: Allocator) void {
        self.active = false;
        self.current_index = 0;
        for (self.entries.items, 0..) |*entry, entry_index| {
            const confirmed_freeform = if (entry.confirmed_choice_index) |choice_index|
                choice_index < entry.options.items.len and
                    entry.options.items[choice_index].is_freeform_slot
            else
                false;
            if (confirmed_freeform) {
                if (!std.mem.eql(
                    u8,
                    entry.freeform_buffer.items,
                    entry.confirmed_freeform_buffer.items,
                )) {
                    traceDraftDiscardCount(
                        entry_index,
                        "accepted_submission_changed",
                        entry.freeform_buffer.items.len,
                    );
                }
            } else {
                traceDraftDiscard(entry, entry_index, "accepted_submission_unselected");
            }
            entry.deinit(alloc);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Rebuild the prompt from a batch of entries. No-op when the
    /// incoming payload is byte-for-byte identical to the current one.
    pub fn syncFrom(
        self: *QuestionPrompt,
        alloc: Allocator,
        entries: []const types.QuestionBatchEntry,
    ) !void {
        return self.syncFromOptions(alloc, entries, true);
    }

    /// Rebuild the prompt without the synthetic freeform slot.
    pub fn syncChoicesFrom(
        self: *QuestionPrompt,
        alloc: Allocator,
        entries: []const types.QuestionBatchEntry,
    ) !void {
        return self.syncFromOptions(alloc, entries, false);
    }

    fn syncFromOptions(
        self: *QuestionPrompt,
        alloc: Allocator,
        entries: []const types.QuestionBatchEntry,
        append_freeform: bool,
    ) !void {
        if (self.active and self.matches(entries, append_freeform)) return;

        self.discard(alloc, "prompt_replaced");
        try self.entries.ensureTotalCapacity(alloc, entries.len);
        for (entries) |incoming| {
            const q_copy = try alloc.dupe(u8, incoming.question);
            errdefer alloc.free(q_copy);

            var opts: std.ArrayList(OwnedQuestionOption) = .empty;
            errdefer {
                for (opts.items) |opt| {
                    alloc.free(opt.label);
                    if (opt.description) |d| alloc.free(d);
                }
                opts.deinit(alloc);
            }

            try opts.ensureTotalCapacity(alloc, incoming.options.len + @intFromBool(append_freeform));
            for (incoming.options) |opt| {
                const label_copy = try alloc.dupe(u8, opt.label);
                errdefer alloc.free(label_copy);
                const desc_copy: ?[]u8 = if (opt.description) |d|
                    try alloc.dupe(u8, d)
                else
                    null;
                opts.appendAssumeCapacity(.{
                    .label = label_copy,
                    .description = desc_copy,
                });
            }

            if (append_freeform) {
                const freeform_label_copy = try alloc.dupe(u8, freeform_option_label);
                opts.appendAssumeCapacity(.{
                    .label = freeform_label_copy,
                    .description = null,
                    .is_freeform_slot = true,
                });
            }

            self.entries.appendAssumeCapacity(.{
                .question = q_copy,
                .options = opts,
            });
        }
        self.active = true;
    }

    fn matches(self: QuestionPrompt, entries: []const types.QuestionBatchEntry, append_freeform: bool) bool {
        if (self.entries.items.len != entries.len) return false;
        for (self.entries.items, entries) |owned, incoming| {
            if (!std.mem.eql(u8, owned.question, incoming.question)) return false;
            const expected_len = incoming.options.len + @intFromBool(append_freeform);
            if (owned.options.items.len != expected_len) return false;
            for (incoming.options, 0..) |n, i| {
                const o = owned.options.items[i];
                if (!std.mem.eql(u8, o.label, n.label)) return false;
                const od: []const u8 = o.description orelse "";
                const nd: []const u8 = n.description orelse "";
                if (!std.mem.eql(u8, od, nd)) return false;
            }
            if (append_freeform) {
                const slot = owned.options.items[owned.options.items.len - 1];
                if (!slot.is_freeform_slot) return false;
            }
        }
        return true;
    }

    /// Label the user currently has highlighted in the active entry.
    pub fn selectedLabel(self: QuestionPrompt) ?[]const u8 {
        if (!self.active or self.entries.items.len == 0) return null;
        if (self.current_index >= self.entries.items.len) return null;
        const entry = self.entries.items[self.current_index];
        if (entry.options.items.len == 0) return null;
        const idx: usize = @min(entry.choice_index, entry.options.items.len - 1);
        return entry.options.items[idx].label;
    }

    pub fn apply(self: *QuestionPrompt, alloc: Allocator, action: Action) !QuestionInputEvent {
        return self.applyWithLimit(alloc, action, null);
    }

    pub fn applyBounded(
        self: *QuestionPrompt,
        alloc: Allocator,
        action: Action,
        max_len: usize,
    ) !QuestionInputEvent {
        return self.applyWithLimit(alloc, action, max_len);
    }

    fn applyWithLimit(
        self: *QuestionPrompt,
        alloc: Allocator,
        action: Action,
        max_len: ?usize,
    ) !QuestionInputEvent {
        return switch (action) {
            .cancel => .cancelled,
            .submit => self.advanceOnDecision(alloc),
            .next_entry => blk: {
                self.cycleQuestionPage();
                break :blk .redraw;
            },
            .backspace => blk: {
                if (!self.isFreeformSelected()) break :blk .none;
                self.freeformBackspace();
                break :blk .redraw;
            },
            .select_ordinal => |index| self.selectOrdinal(alloc, index),
            .insert_ascii => |byte| self.insertFreeformByte(alloc, byte, max_len),
            .move_choice => |direction| blk: {
                if (!self.hasCurrentOptions()) break :blk .none;
                self.moveChoice(switch (direction) {
                    .previous => -1,
                    .next => 1,
                });
                break :blk .redraw;
            },
            .edit_freeform => |edit| if (self.applyFreeformAction(edit))
                .redraw
            else
                .none,
        };
    }

    fn hasCurrentOptions(self: *const QuestionPrompt) bool {
        return self.active and
            self.current_index < self.entries.items.len and
            self.entries.items[self.current_index].options.items.len != 0;
    }

    fn applyFreeformAction(self: *QuestionPrompt, action: FreeformAction) bool {
        if (!self.isFreeformSelected()) return false;
        switch (action) {
            .cursor_left => self.freeformCursorLeft(),
            .cursor_right => self.freeformCursorRight(),
            .cursor_home => self.freeformCursorHome(),
            .cursor_end => self.freeformCursorEnd(),
            .cursor_word_left => self.freeformCursorWordLeft(),
            .cursor_word_right => self.freeformCursorWordRight(),
            .delete_next => self.freeformDeleteNext(),
            .delete_word_left => self.freeformDeleteWordLeft(),
            .delete_whitespace_word_left => self.freeformDeleteWhitespaceDelimitedWordLeft(),
            .delete_word_right => self.freeformDeleteWordRight(),
            .delete_to_line_start => self.freeformDeleteToLineStart(),
            .delete_to_line_end => self.freeformDeleteToLineEnd(),
        }
        return true;
    }

    fn insertFreeformByte(
        self: *QuestionPrompt,
        alloc: Allocator,
        byte: u8,
        max_len: ?usize,
    ) !QuestionInputEvent {
        if (!self.isFreeformSelected()) return .none;
        if (byte < 0x20 or byte > 0x7e) return .none;
        if (max_len) |limit| {
            return switch (try self.insertFreeformSlice(
                alloc,
                &.{byte},
                limit,
            )) {
                .inserted => .redraw,
                .inactive => .none,
                .limit_exceeded => .limit_exceeded,
            };
        }
        try self.freeformInsert(alloc, byte);
        return .redraw;
    }

    fn selectOrdinal(self: *QuestionPrompt, alloc: Allocator, index: u8) !QuestionInputEvent {
        if (!self.active or self.current_index >= self.entries.items.len) return .none;
        var entry = &self.entries.items[self.current_index];
        if (index >= entry.options.items.len) return .none;
        entry.freeform_preferred_column = null;
        entry.choice_index = index;
        if (entry.options.items[index].is_freeform_slot) return .redraw;
        return try self.advanceOnDecision(alloc);
    }

    pub fn isFreeformSelected(self: *const QuestionPrompt) bool {
        if (!self.active or self.current_index >= self.entries.items.len) return false;
        const entry = self.entries.items[self.current_index];
        if (entry.options.items.len == 0) return false;
        const idx: usize = @min(entry.choice_index, entry.options.items.len - 1);
        return entry.options.items[idx].is_freeform_slot;
    }

    pub fn freeformDraftLen(self: *const QuestionPrompt) usize {
        if (!self.isFreeformSelected()) return 0;
        return self.entries.items[self.current_index].freeform_buffer.items.len;
    }

    /// Empties the selected freeform slot in place; the field stays selected
    /// so the user can continue editing or cancel the batch.
    pub fn clearFreeformDraft(self: *QuestionPrompt, reason: []const u8) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        traceDraftDiscard(entry, self.current_index, reason);
        entry.freeform_buffer.clearRetainingCapacity();
        entry.freeform_cursor = 0;
        entry.freeform_preferred_column = null;
    }

    pub fn freeformCursorLeft(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        if (entry.freeform_cursor > 0) {
            entry.freeform_cursor = text_boundaries.previousCharacterStart(entry.freeform_buffer.items, entry.freeform_cursor);
        }
    }

    pub fn freeformCursorRight(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        if (entry.freeform_cursor < entry.freeform_buffer.items.len) {
            entry.freeform_cursor = text_boundaries.nextCharacterEnd(entry.freeform_buffer.items, entry.freeform_cursor);
        }
    }

    pub fn freeformCursorHome(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        entry.freeform_cursor = 0;
    }

    pub fn freeformCursorEnd(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        entry.freeform_cursor = entry.freeform_buffer.items.len;
    }

    pub fn freeformCursorWordLeft(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        entry.freeform_cursor = text_boundaries.previousWordStart(entry.freeform_buffer.items, entry.freeform_cursor);
    }

    pub fn freeformCursorWordRight(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        entry.freeform_cursor = text_boundaries.nextWordEnd(entry.freeform_buffer.items, entry.freeform_cursor);
    }

    pub const FreeformCursorView = struct {
        buffer: []const u8,
        cursor: usize,
        preferred_column: ?usize,
        choice_index: u8,
    };

    /// The returned buffer is borrowed until the next prompt mutation.
    pub fn freeformCursorView(self: *const QuestionPrompt) ?FreeformCursorView {
        if (!self.isFreeformSelected()) return null;
        const entry = self.entries.items[self.current_index];
        return .{
            .buffer = entry.freeform_buffer.items,
            .cursor = entry.freeform_cursor,
            .preferred_column = entry.freeform_preferred_column,
            .choice_index = entry.choice_index,
        };
    }

    pub fn applyFreeformCursorMove(
        self: *QuestionPrompt,
        cursor: usize,
        preferred_column: usize,
    ) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        std.debug.assert(cursor <= entry.freeform_buffer.items.len);
        entry.freeform_cursor = cursor;
        entry.freeform_preferred_column = preferred_column;
    }

    pub fn freeformDeleteNext(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        if (entry.freeform_cursor >= entry.freeform_buffer.items.len) return;
        const end = text_boundaries.nextCharacterEnd(entry.freeform_buffer.items, entry.freeform_cursor);
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, entry.freeform_cursor, end);
    }

    pub fn freeformDeleteWordLeft(self: *QuestionPrompt) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        const start = text_boundaries.previousWordStart(entry.freeform_buffer.items, entry.freeform_cursor);
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, start, entry.freeform_cursor);
    }

    pub fn freeformDeleteWhitespaceDelimitedWordLeft(self: *QuestionPrompt) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        const line_start = text_boundaries.logicalLineStart(entry.freeform_buffer.items, entry.freeform_cursor);
        const start = text_boundaries.previousWhitespaceDelimitedTokenStart(
            entry.freeform_buffer.items,
            entry.freeform_cursor,
            line_start,
        );
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, start, entry.freeform_cursor);
    }

    pub fn freeformDeleteWordRight(self: *QuestionPrompt) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        const end = text_boundaries.nextWordDeleteEnd(entry.freeform_buffer.items, entry.freeform_cursor);
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, entry.freeform_cursor, end);
    }

    pub fn freeformDeleteToLineStart(self: *QuestionPrompt) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        const start = text_boundaries.logicalLineStart(entry.freeform_buffer.items, entry.freeform_cursor);
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, start, entry.freeform_cursor);
    }

    pub fn freeformDeleteToLineEnd(self: *QuestionPrompt) void {
        if (!self.isFreeformSelected()) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        const line_end = text_boundaries.logicalLineEnd(entry.freeform_buffer.items, entry.freeform_cursor);
        const end = if (entry.freeform_cursor == line_end and line_end < entry.freeform_buffer.items.len)
            line_end + 1
        else
            line_end;
        _ = edit_contract.deleteRange(&entry.freeform_buffer, &entry.freeform_cursor, entry.freeform_cursor, end);
    }

    /// Inserts a bracketed-paste payload at the active freeform cursor.
    pub fn insertFreeformSlice(self: *QuestionPrompt, alloc: Allocator, bytes: []const u8, max_len: usize) !FreeformInsertResult {
        if (!self.isFreeformSelected()) return .inactive;
        if (bytes.len == 0) return .inserted;
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        var entry = &self.entries.items[self.current_index];
        if (!edit_contract.canInsert(entry.freeform_buffer.items.len, bytes.len, max_len)) return .limit_exceeded;
        try entry.freeform_buffer.insertSlice(alloc, entry.freeform_cursor, bytes);
        entry.freeform_cursor += bytes.len;
        entry.freeform_preferred_column = null;
        return .inserted;
    }

    fn freeformInsert(self: *QuestionPrompt, alloc: Allocator, byte: u8) !void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        try entry.freeform_buffer.insert(alloc, entry.freeform_cursor, byte);
        entry.freeform_cursor += 1;
        entry.freeform_preferred_column = null;
    }

    fn freeformBackspace(self: *QuestionPrompt) void {
        if (self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        entry.freeform_preferred_column = null;
        if (entry.freeform_cursor == 0) return;
        const start = text_boundaries.previousCharacterStart(entry.freeform_buffer.items, entry.freeform_cursor);
        const count = entry.freeform_cursor - start;
        std.mem.copyForwards(u8, entry.freeform_buffer.items[start..], entry.freeform_buffer.items[entry.freeform_cursor..]);
        entry.freeform_buffer.items.len -= count;
        entry.freeform_cursor = start;
    }

    /// Step back to the previous entry without touching its stored
    /// answer, so the user can revisit and submit it again.
    /// Returns `.none` when already on the first entry.
    pub fn retreatToPrevious(self: *QuestionPrompt) QuestionInputEvent {
        if (!self.active or self.current_index == 0) return .none;
        self.entries.items[self.current_index].freeform_preferred_column = null;
        self.current_index -= 1;
        self.entries.items[self.current_index].freeform_preferred_column = null;
        return .redraw;
    }

    /// Store the selected label (or freeform buffer contents) into
    /// `entries[current_index].answer`. Returns `.all_decided` once every
    /// entry has an answer; otherwise advances to the next unanswered entry
    /// and returns `.decision(answered_index)`.
    fn advanceOnDecision(self: *QuestionPrompt, alloc: Allocator) !QuestionInputEvent {
        if (self.entries.items.len == 0) return .none;
        const answered_index = self.current_index;
        if (answered_index >= self.entries.items.len) return .none;

        var entry = &self.entries.items[answered_index];
        if (entry.options.items.len == 0) return .none;
        const idx: usize = @min(entry.choice_index, entry.options.items.len - 1);
        const opt = entry.options.items[idx];
        if (opt.is_freeform_slot) {
            if (entry.freeform_buffer.items.len == 0) return .redraw;
            try entry.confirmed_freeform_buffer.ensureTotalCapacity(alloc, entry.freeform_buffer.items.len);
            entry.confirmed_freeform_buffer.clearRetainingCapacity();
            entry.confirmed_freeform_buffer.appendSliceAssumeCapacity(entry.freeform_buffer.items);
            entry.answer = entry.confirmed_freeform_buffer.items;
        } else {
            entry.answer = opt.label;
        }
        entry.freeform_preferred_column = null;
        entry.confirmed_choice_index = entry.choice_index;

        var offset: usize = 1;
        while (offset < self.entries.items.len) : (offset += 1) {
            const candidate = (answered_index + offset) % self.entries.items.len;
            if (self.entries.items[candidate].answer == null) {
                self.current_index = @intCast(candidate);
                self.entries.items[candidate].freeform_preferred_column = null;
                return .{ .decision = answered_index };
            }
        }
        self.current_index = @intCast(self.entries.items.len);
        return .all_decided;
    }

    fn cycleQuestionPage(self: *QuestionPrompt) void {
        if (!self.active or self.entries.items.len == 0) return;
        self.entries.items[self.current_index].freeform_preferred_column = null;
        const next = (@as(usize, self.current_index) + 1) % self.entries.items.len;
        self.current_index = @intCast(next);
        self.entries.items[self.current_index].freeform_preferred_column = null;
    }

    pub fn moveChoice(self: *QuestionPrompt, delta: i32) void {
        if (!self.active or self.current_index >= self.entries.items.len) return;
        var entry = &self.entries.items[self.current_index];
        const count: i32 = @intCast(entry.options.items.len);
        if (count <= 0) return;
        entry.freeform_preferred_column = null;
        var next = @as(i32, entry.choice_index) + delta;
        if (next < 0) next = count - 1;
        if (next >= count) next = 0;
        entry.choice_index = @intCast(next);
    }

    fn traceDraftDiscard(
        entry: *const OwnedQuestionEntry,
        entry_index: usize,
        reason: []const u8,
    ) void {
        if (entry.freeform_buffer.items.len == 0) return;
        traceDraftDiscardCount(entry_index, reason, entry.freeform_buffer.items.len);
    }

    fn traceDraftDiscardCount(
        entry_index: usize,
        reason: []const u8,
        byte_count: usize,
    ) void {
        debug_trace.logf(
            "input",
            "question draft discarded reason={s} entry={d} bytes={d}",
            .{ reason, entry_index, byte_count },
        );
    }
};

fn syncTestQuestion(prompt: *QuestionPrompt) !void {
    const opts = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
}

fn currentChoiceIndex(prompt: *const QuestionPrompt) u8 {
    return prompt.entries.items[prompt.current_index].choice_index;
}

test "question prompt applies typed choice and freeform actions" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .move_choice = .previous }),
    );
    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' }),
    );
    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'b' }),
    );
    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .edit_freeform = .cursor_left }),
    );
    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .edit_freeform = .delete_next }),
    );
    try std.testing.expectEqualStrings(
        "a",
        prompt.entries.items[0].freeform_buffer.items,
    );

    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.apply(std.testing.allocator, .{ .move_choice = .previous }),
    );
    try std.testing.expect(!prompt.isFreeformSelected());
    try std.testing.expectEqual(
        QuestionInputEvent.none,
        try prompt.apply(std.testing.allocator, .{ .edit_freeform = .cursor_home }),
    );
}

test "question prompt projects only borrowed immutable live state" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?Projection, null), prompt.projection());

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "Continue." },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "First?", .options = &options },
        .{ .question = "Second?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const projection = prompt.projection().?;
    try std.testing.expectEqual(@as(usize, 0), projection.current_index);
    try std.testing.expectEqual(@as(usize, 2), projection.entry_count);
    const entry = projection.current_entry.?;
    try std.testing.expectEqualStrings("First?", entry.question);
    try std.testing.expectEqual(@as(usize, 3), entry.options.len);
    try std.testing.expectEqualStrings("Continue.", entry.options[0].description.?);
    try std.testing.expect(!projection.isFreeformSelected());

    prompt.moveChoice(-1);
    const freeform = prompt.projection().?;
    try std.testing.expect(freeform.isFreeformSelected());
    try std.testing.expectEqualStrings(freeform_option_label, freeform.current_entry.?.options[2].label);

    prompt.discard(std.testing.allocator, "test_cleanup");
    try std.testing.expectEqual(@as(?Projection, null), prompt.projection());
}

fn checkQuestionPromptSyncAllocationFailures(alloc: Allocator) !void {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(alloc);

    const options = [_]types.QuestionOption{
        .{ .label = "One", .description = "first" },
        .{ .label = "Two", .description = "second" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Choose?", .options = &options },
    };
    try prompt.syncFrom(alloc, &entries);
}

test "question prompt frees partial owned-entry allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkQuestionPromptSyncAllocationFailures,
        .{},
    );
}

test "question prompt freeform allocation failure preserves prompt state" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        prompt.apply(failing.allocator(), .{ .insert_ascii = 'x' }),
    );
    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqual(@as(usize, 0), prompt.entries.items[0].freeform_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), prompt.entries.items[0].freeform_cursor);
}

test "question prompt submission allocation failure preserves the draft" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'x' });
    prompt.applyFreeformCursorMove(1, 7);

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        prompt.apply(failing.allocator(), .submit),
    );
    try std.testing.expect(prompt.entries.items[0].answer == null);
    try std.testing.expect(prompt.entries.items[0].confirmed_choice_index == null);
    try std.testing.expectEqualStrings("x", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), prompt.entries.items[0].freeform_cursor);
    try std.testing.expectEqual(
        @as(?usize, 7),
        prompt.entries.items[0].freeform_preferred_column,
    );
}

test "question prompt next-entry action cycles without answering" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts },
        .{ .question = "Q1?", .options = &opts },
        .{ .question = "Q2?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .next_entry));
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .next_entry));
    try std.testing.expectEqual(@as(u8, 2), prompt.current_index);
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .next_entry));
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    for (prompt.entries.items) |entry| try std.testing.expect(entry.answer == null);
}

test "question prompt next-entry action preserves drafts and confirmed answers" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts },
        .{ .question = "Q1?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    _ = try prompt.apply(std.testing.allocator, .submit);
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    prompt.moveChoice(1);
    try std.testing.expectEqual(@as(u8, 1), prompt.entries.items[0].choice_index);
    try std.testing.expectEqualStrings("One", prompt.entries.items[0].answer.?);

    _ = try prompt.apply(std.testing.allocator, .next_entry);
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    try std.testing.expectEqual(@as(u8, 1), prompt.entries.items[0].choice_index);
    try std.testing.expectEqualStrings("One", prompt.entries.items[0].answer.?);
}

test "question prompt answering out of order advances to the next unanswered entry" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts },
        .{ .question = "Q1?", .options = &opts },
        .{ .question = "Q2?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    _ = try prompt.apply(std.testing.allocator, .next_entry);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    switch (try prompt.apply(std.testing.allocator, .submit)) {
        .decision => |idx| try std.testing.expectEqual(@as(u8, 2), idx),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    try std.testing.expect(prompt.entries.items[0].answer == null);
    try std.testing.expect(prompt.entries.items[1].answer == null);
    try std.testing.expectEqualStrings("One", prompt.entries.items[2].answer.?);

    switch (try prompt.apply(std.testing.allocator, .submit)) {
        .decision => |idx| try std.testing.expectEqual(@as(u8, 0), idx),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);
    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .submit));
}

test "question prompt page navigation preserves a revisited freeform draft" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts },
        .{ .question = "Q1?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    prompt.moveChoice(-1);
    for ("saved") |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });
    _ = try prompt.apply(std.testing.allocator, .submit);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);

    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'x' });
    try std.testing.expectEqualStrings("savedx", prompt.entries.items[0].freeform_buffer.items);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    _ = try prompt.apply(std.testing.allocator, .next_entry);

    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqualStrings("savedx", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqualStrings("saved", prompt.entries.items[0].answer.?);
}

test "question prompt backward navigation preserves the page being left" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts },
        .{ .question = "Q1?", .options = &opts },
        .{ .question = "Q2?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    _ = try prompt.apply(std.testing.allocator, .next_entry);
    prompt.moveChoice(-1);
    for ("saved") |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });
    _ = try prompt.apply(std.testing.allocator, .submit);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    _ = try prompt.apply(std.testing.allocator, .next_entry);
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);

    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'x' });
    try std.testing.expectEqualStrings("savedx", prompt.entries.items[1].freeform_buffer.items);
    try std.testing.expectEqual(QuestionInputEvent.redraw, prompt.retreatToPrevious());

    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    try std.testing.expectEqualStrings("savedx", prompt.entries.items[1].freeform_buffer.items);
    try std.testing.expectEqualStrings("saved", prompt.entries.items[1].answer.?);
}

test "question prompt ignores insert actions while predefined option is selected" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expect(prompt.isActive());
    try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));

    for ("typing a reply hjkl") |byte| {
        try std.testing.expectEqual(QuestionInputEvent.none, try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte }));
        try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));
        try std.testing.expect(prompt.entries.items[0].answer == null);
    }
}

test "question prompt ordinal action commits predefined option" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expectEqual(QuestionInputEvent.none, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 9 }));
    try std.testing.expectEqual(QuestionInputEvent.none, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 4 }));
    try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));
    try std.testing.expect(prompt.entries.items[0].answer == null);

    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 1 }));
    try std.testing.expectEqual(@as(u8, 1), prompt.entries.items[0].choice_index);
    try std.testing.expectEqualStrings("No", prompt.entries.items[0].answer.?);
}

test "question prompt max ordinal selects freeform slot" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
        .{ .label = "Three", .description = null },
        .{ .label = "Four", .description = null },
        .{ .label = "Five", .description = null },
        .{ .label = "Six", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Choose?", .options = &opts },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 6 }));
    try std.testing.expectEqual(@as(u8, 6), currentChoiceIndex(&prompt));
    try std.testing.expect(prompt.isFreeformSelected());

    prompt.moveChoice(1);
    try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));
    for ("890") |byte| {
        try std.testing.expectEqual(QuestionInputEvent.none, try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte }));
        try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));
    }
}

test "question prompt ordinal selection stays scoped to current batch entry" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts_a = [_]types.QuestionOption{
        .{ .label = "A1", .description = null },
        .{ .label = "A2", .description = null },
    };
    const opts_b = [_]types.QuestionOption{
        .{ .label = "B1", .description = null },
        .{ .label = "B2", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "First?", .options = &opts_a },
        .{ .question = "Second?", .options = &opts_b },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    switch (try prompt.apply(std.testing.allocator, .{ .select_ordinal = 1 })) {
        .decision => |idx| try std.testing.expectEqual(@as(u8, 0), idx),
        else => return error.TestExpectedDecision,
    }

    try std.testing.expectEqualStrings("A2", prompt.entries.items[0].answer.?);
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);
    try std.testing.expectEqual(@as(u8, 0), currentChoiceIndex(&prompt));
    try std.testing.expect(prompt.entries.items[1].answer == null);

    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 1 }));
    try std.testing.expectEqualStrings("B2", prompt.entries.items[1].answer.?);
}

test "question prompt submit on single-entry batch returns all_decided" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(1);
    try std.testing.expectEqualStrings("No", prompt.selectedLabel().?);
    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .submit));
    try std.testing.expectEqualStrings("No", prompt.entries.items[0].answer.?);
}

test "question prompt submit advances through a multi-entry batch" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts_a = [_]types.QuestionOption{
        .{ .label = "A1", .description = null },
        .{ .label = "A2", .description = null },
    };
    const opts_b = [_]types.QuestionOption{
        .{ .label = "B1", .description = null },
        .{ .label = "B2", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "First?", .options = &opts_a },
        .{ .question = "Second?", .options = &opts_b },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    // Submitting entry 0 (selection A1) commits the borrowed label and advances.
    switch (try prompt.apply(std.testing.allocator, .submit)) {
        .decision => |idx| try std.testing.expectEqual(@as(u8, 0), idx),
        else => return error.TestExpectedDecision,
    }
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);

    // Submitting B2 as the last entry completes the batch.
    prompt.moveChoice(1);
    try std.testing.expectEqualStrings("B2", prompt.selectedLabel().?);
    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .submit));

    try std.testing.expectEqualStrings("A1", prompt.entries.items[0].answer.?);
    try std.testing.expectEqualStrings("B2", prompt.entries.items[1].answer.?);
}

test "question prompt cancel action returns cancelled mid-batch" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expectEqual(QuestionInputEvent.cancelled, try prompt.apply(std.testing.allocator, .cancel));
}

test "question prompt syncFrom is idempotent for identical payloads" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(1);

    try syncTestQuestion(&prompt);
    try std.testing.expectEqual(@as(u8, 1), currentChoiceIndex(&prompt));
}

test "syncFrom appends freeform slot to every entry" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const opts_a = [_]types.QuestionOption{
        .{ .label = "A1", .description = null },
        .{ .label = "A2", .description = null },
    };
    const opts_b = [_]types.QuestionOption{
        .{ .label = "B1", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &opts_a },
        .{ .question = "Q1?", .options = &opts_b },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    try std.testing.expectEqual(@as(usize, 3), prompt.entries.items[0].options.items.len);
    try std.testing.expectEqual(@as(usize, 2), prompt.entries.items[1].options.items.len);

    for (prompt.entries.items) |entry| {
        const slot = entry.options.items[entry.options.items.len - 1];
        try std.testing.expect(slot.is_freeform_slot);
        try std.testing.expectEqualStrings(freeform_option_label, slot.label);
        try std.testing.expect(slot.description == null);
    }
}

test "isFreeformSelected reflects choice index" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expect(!prompt.isFreeformSelected());
    prompt.moveChoice(-1);
    try std.testing.expectEqual(@as(u8, 3), currentChoiceIndex(&prompt));
    try std.testing.expect(prompt.isFreeformSelected());
}

test "insert actions append to the freeform draft before submission" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'h' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'o' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'l' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' });

    try std.testing.expectEqualStrings("hola", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 4), prompt.entries.items[0].freeform_cursor);
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
}

test "numeric insert actions type into the freeform buffer" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .{ .select_ordinal = 3 }));
    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .{ .insert_ascii = '4' }));
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .{ .insert_ascii = '2' }));
    try std.testing.expectEqualStrings("42", prompt.entries.items[0].freeform_buffer.items);

    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .submit));
    try std.testing.expectEqualStrings("42", prompt.entries.items[0].answer.?);
}

test "question prompt rejects non-printable insert actions" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    try std.testing.expectEqual(
        QuestionInputEvent.none,
        try prompt.apply(std.testing.allocator, .{ .insert_ascii = 0x1f }),
    );
    try std.testing.expectEqual(
        QuestionInputEvent.none,
        try prompt.apply(std.testing.allocator, .{ .insert_ascii = 0x7f }),
    );
    try std.testing.expectEqualStrings("", prompt.entries.items[0].freeform_buffer.items);
}

test "insert actions do not navigate freeform choices" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    try std.testing.expectEqual(@as(u8, 3), currentChoiceIndex(&prompt));

    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'k' });
    try std.testing.expectEqual(@as(u8, 3), currentChoiceIndex(&prompt));
    try std.testing.expectEqualStrings("k", prompt.entries.items[0].freeform_buffer.items);
}

test "submit on freeform slot stores the draft as its answer" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'x' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'y' });

    try std.testing.expectEqual(QuestionInputEvent.all_decided, try prompt.apply(std.testing.allocator, .submit));
    try std.testing.expectEqualStrings("xy", prompt.entries.items[0].answer.?);
}

test "submit on empty freeform slot keeps the question active" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .submit));
    try std.testing.expect(prompt.isActive());
    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqual(@as(u8, 0), prompt.current_index);
    try std.testing.expect(prompt.entries.items[0].answer == null);
    try std.testing.expect(prompt.entries.items[0].confirmed_choice_index == null);
}

test "moveChoice off freeform preserves buffer for re-entry" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'h' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'i' });

    prompt.moveChoice(-1);
    try std.testing.expectEqual(@as(u8, 2), currentChoiceIndex(&prompt));
    try std.testing.expectEqualStrings("hi", prompt.entries.items[0].freeform_buffer.items);

    prompt.moveChoice(1); // back to freeform
    try std.testing.expectEqual(@as(u8, 3), currentChoiceIndex(&prompt));
    try std.testing.expect(prompt.isFreeformSelected());
    try std.testing.expectEqualStrings("hi", prompt.entries.items[0].freeform_buffer.items);
}

test "backspace removes char before cursor on freeform" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'b' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'c' });
    _ = try prompt.apply(std.testing.allocator, .backspace);

    try std.testing.expectEqualStrings("ab", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 2), prompt.entries.items[0].freeform_cursor);
}

test "question freeform applies word and logical line deletions" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);

    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "alpha beta", 64),
    );
    prompt.freeformDeleteWhitespaceDelimitedWordLeft();
    try std.testing.expectEqualStrings("alpha ", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 6), prompt.entries.items[0].freeform_cursor);

    prompt.freeformDeleteWordLeft();
    try std.testing.expectEqualStrings("", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 0), prompt.entries.items[0].freeform_cursor);

    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "one two\nthree four", 64),
    );
    prompt.freeformCursorHome();
    prompt.freeformDeleteWordRight();
    try std.testing.expectEqualStrings("two\nthree four", prompt.entries.items[0].freeform_buffer.items);

    prompt.freeformCursorEnd();
    prompt.freeformCursorWordLeft();
    prompt.freeformDeleteToLineStart();
    try std.testing.expectEqualStrings("two\nfour", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, "two\n".len), prompt.entries.items[0].freeform_cursor);

    prompt.freeformDeleteToLineEnd();
    try std.testing.expectEqualStrings("two\n", prompt.entries.items[0].freeform_buffer.items);

    prompt.clearFreeformDraft("test_cleanup");
    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "alpha\nbeta", 64),
    );
    prompt.freeformCursorHome();
    prompt.freeformCursorWordRight();
    prompt.freeformDeleteToLineEnd();
    try std.testing.expectEqualStrings("alphabeta", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, "alpha".len), prompt.entries.items[0].freeform_cursor);
}

test "question freeform word deletion keeps preceding characters intact" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);

    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "one e\u{301}lan 🙂", 64),
    );
    prompt.freeformDeleteWordLeft();
    try std.testing.expectEqualStrings("one e\u{301}lan ", prompt.entries.items[0].freeform_buffer.items);
    prompt.freeformDeleteWordLeft();
    try std.testing.expectEqualStrings("one ", prompt.entries.items[0].freeform_buffer.items);
}

test "freeformCursorLeft and Right move cursor inside buffer" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'b' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'c' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'd' });

    prompt.freeformCursorLeft();
    prompt.freeformCursorLeft();
    try std.testing.expectEqual(@as(usize, 2), prompt.entries.items[0].freeform_cursor);

    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'X' });
    try std.testing.expectEqualStrings("abXcd", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 3), prompt.entries.items[0].freeform_cursor);

    prompt.freeformCursorRight();
    prompt.freeformCursorRight();
    prompt.freeformCursorRight();
    prompt.freeformCursorRight(); // clamps at end
    try std.testing.expectEqual(@as(usize, 5), prompt.entries.items[0].freeform_cursor);
}

test "question freeform nonvertical actions reset preferred column intent" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "first\nxy\nthird", 64),
    );

    const cursor_view = prompt.freeformCursorView().?;
    prompt.applyFreeformCursorMove(cursor_view.cursor, 5);
    try std.testing.expectEqual(
        @as(?usize, 5),
        prompt.entries.items[0].freeform_preferred_column,
    );
    prompt.freeformCursorLeft();
    try std.testing.expectEqual(
        @as(?usize, null),
        prompt.entries.items[0].freeform_preferred_column,
    );

    const moved_view = prompt.freeformCursorView().?;
    prompt.applyFreeformCursorMove(moved_view.cursor, 5);
    try std.testing.expectEqual(
        @as(?usize, 5),
        prompt.entries.items[0].freeform_preferred_column,
    );
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = '!' });
    try std.testing.expectEqual(
        @as(?usize, null),
        prompt.entries.items[0].freeform_preferred_column,
    );
}

test "question freeform edits graphemes with cursor actions" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.entries.items[0].choice_index = @intCast(prompt.entries.items[0].options.items.len - 1);
    try std.testing.expectEqual(FreeformInsertResult.inserted, try prompt.insertFreeformSlice(std.testing.allocator, "A🙂B", 64));
    prompt.freeformCursorLeft();
    prompt.freeformCursorLeft();
    try std.testing.expectEqual(@as(usize, 1), prompt.entries.items[0].freeform_cursor);
    prompt.freeformCursorRight();
    try std.testing.expectEqual(@as(usize, 5), prompt.entries.items[0].freeform_cursor);
    try std.testing.expectEqual(QuestionInputEvent.redraw, try prompt.apply(std.testing.allocator, .backspace));
    try std.testing.expectEqualStrings("AB", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), prompt.entries.items[0].freeform_cursor);

    prompt.entries.items[0].freeform_buffer.clearRetainingCapacity();
    prompt.entries.items[0].freeform_cursor = 0;
    try std.testing.expectEqual(
        FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "alpha beta 👨‍👩‍👧‍👦", 128),
    );
    prompt.freeformCursorWordLeft();
    try std.testing.expectEqual(@as(usize, "alpha beta ".len), prompt.entries.items[0].freeform_cursor);
    prompt.freeformDeleteNext();
    try std.testing.expectEqualStrings("alpha beta ", prompt.entries.items[0].freeform_buffer.items);
    prompt.freeformCursorHome();
    try std.testing.expectEqual(@as(usize, 0), prompt.entries.items[0].freeform_cursor);
    prompt.freeformCursorWordRight();
    try std.testing.expectEqual(@as(usize, "alpha".len), prompt.entries.items[0].freeform_cursor);
    prompt.freeformCursorEnd();
    try std.testing.expectEqual(prompt.entries.items[0].freeform_buffer.items.len, prompt.entries.items[0].freeform_cursor);
}

test "question prompt inserts pasted freeform text at the cursor" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'b' });
    prompt.freeformCursorLeft();

    try std.testing.expectEqual(FreeformInsertResult.inserted, try prompt.insertFreeformSlice(std.testing.allocator, "one\ntwo", 64));
    try std.testing.expectEqualStrings("aone\ntwob", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 8), prompt.entries.items[0].freeform_cursor);
}

test "question freeform bounded typing rejects without changing its draft" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    try std.testing.expectEqual(
        QuestionInputEvent.redraw,
        try prompt.applyBounded(std.testing.allocator, .{ .insert_ascii = 'a' }, 1),
    );
    try std.testing.expectEqual(
        QuestionInputEvent.limit_exceeded,
        try prompt.applyBounded(std.testing.allocator, .{ .insert_ascii = 'b' }, 1),
    );
    try std.testing.expectEqual(
        FreeformInsertResult.limit_exceeded,
        try prompt.insertFreeformSlice(std.testing.allocator, "é", 2),
    );
    try std.testing.expectEqualStrings("a", prompt.entries.items[0].freeform_buffer.items);
    try std.testing.expectEqual(@as(usize, 1), prompt.entries.items[0].freeform_cursor);
    try std.testing.expect(prompt.isFreeformSelected());
}

test "cancel action on freeform slot cancels whole prompt" {
    var prompt = QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTestQuestion(&prompt);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'a' });

    try std.testing.expectEqual(QuestionInputEvent.cancelled, try prompt.apply(std.testing.allocator, .cancel));
}

test "question prompt traces discarded drafts with their reason" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "question-draft.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var prompt = QuestionPrompt{};
    defer prompt.deinit(alloc);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'x' });
    prompt.discard(alloc, "cancelled");

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=cancelled entry=0 bytes=1",
    ) != null);
}

test "question prompt traces drafts that differ from accepted submissions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "question-draft-accepted.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var prompt = QuestionPrompt{};
    defer prompt.deinit(alloc);
    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'x' });
    prompt.moveChoice(1);
    _ = try prompt.apply(alloc, .submit);
    prompt.resetAfterSubmission(alloc);

    const options = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &options },
        .{ .question = "Q1?", .options = &options },
    };
    try prompt.syncFrom(alloc, &entries);
    prompt.moveChoice(-1);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'o' });
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'k' });
    _ = try prompt.apply(alloc, .submit);
    _ = try prompt.apply(alloc, .next_entry);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'x' });
    _ = try prompt.apply(alloc, .next_entry);
    _ = try prompt.apply(alloc, .submit);
    prompt.resetAfterSubmission(alloc);

    try prompt.syncFrom(alloc, &entries);
    prompt.moveChoice(-1);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'q' });
    _ = try prompt.apply(alloc, .submit);
    _ = try prompt.apply(alloc, .next_entry);
    _ = try prompt.apply(alloc, .backspace);
    _ = try prompt.apply(alloc, .next_entry);
    _ = try prompt.apply(alloc, .submit);
    prompt.resetAfterSubmission(alloc);

    try syncTestQuestion(&prompt);
    prompt.moveChoice(-1);
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'y' });
    _ = try prompt.apply(alloc, .{ .insert_ascii = 'z' });
    _ = try prompt.apply(alloc, .submit);
    prompt.resetAfterSubmission(alloc);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=accepted_submission_unselected entry=0 bytes=1",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=accepted_submission_unselected entry=0 bytes=2",
    ) == null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=accepted_submission_changed entry=0 bytes=3",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=accepted_submission_changed entry=0 bytes=2",
    ) == null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "question draft discarded reason=accepted_submission_changed entry=0 bytes=0",
    ) != null);
}
