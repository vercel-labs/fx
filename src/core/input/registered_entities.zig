const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const paste_blocks = @import("pasted_blocks.zig");
const editor_state = @import("editor_state.zig");
const skill_contract = @import("../skills/skill_contract.zig");

const Allocator = std.mem.Allocator;

pub const SkillTokenSpan = struct {
    raw_start: usize,
    raw_end: usize,
    name: []const u8,
    path: []const u8,
    display_source: ?skill_contract.SkillSource = null,
    display_path: ?skill_contract.SkillPathDiscriminator = null,
    owns_trailing_separator: bool = false,
};

pub const Kind = enum {
    paste,
    image,
    skill,
};

pub const Entity = struct {
    kind: Kind,
    index: usize,
    id: usize = 0,
    span: entity_spans.Span,
};

const AutoSeparatorOwner = union(enum) {
    file,
    skill: usize,
};

const PendingAutoSeparator = struct {
    raw_offset: usize,
    owner: AutoSeparatorOwner,
};

pub const BindError = error{
    InvalidSkillTokenRange,
    OutOfMemory,
    Overflow,
};

/// Owns pasted block backing text and skill token strings. Image token records
/// are non-owning references to attachments held by the interactive runtime.
pub const State = struct {
    pasted_blocks: std.ArrayList(paste_blocks.PastedBlock) = .empty,
    image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
    skill_tokens: std.ArrayList(SkillTokenSpan) = .empty,
    pending_auto_separator: ?PendingAutoSeparator = null,
    next_paste_id: usize = 1,

    pub fn deinit(self: *State, alloc: Allocator) void {
        paste_blocks.deinitBlocks(alloc, &self.pasted_blocks);
        self.image_tokens.deinit(alloc);
        self.clearSkillTokens(alloc);
        self.skill_tokens.deinit(alloc);
        self.* = .{};
    }

    pub fn clearImageAndSkillTokens(self: *State, alloc: Allocator) void {
        self.image_tokens.clearRetainingCapacity();
        self.clearSkillTokens(alloc);
    }

    pub fn resetForSession(self: *State, alloc: Allocator) void {
        self.clearImageAndSkillTokens(alloc);
        if (self.pasted_blocks.items.len > 0) {
            debug_trace.logf(
                "input",
                "pasted blocks dropped count={d} reason=session_reset",
                .{self.pasted_blocks.items.len},
            );
        }
        paste_blocks.clearBlocks(alloc, &self.pasted_blocks);
        self.next_paste_id = 1;
    }

    pub fn discardPendingAutoSeparator(self: *State) void {
        self.pending_auto_separator = null;
    }

    pub fn registerPastedBlockAssumeCapacity(
        self: *State,
        block: paste_blocks.PastedBlock,
    ) void {
        var index: usize = 0;
        while (index < self.pasted_blocks.items.len and
            self.pasted_blocks.items[index].span.raw_start < block.span.raw_start) : (index += 1)
        {}
        self.pasted_blocks.insertAssumeCapacity(index, block);
    }

    pub fn registerImageTokenAssumeCapacity(
        self: *State,
        token: entity_spans.ImageTokenSpan,
    ) void {
        var index: usize = 0;
        while (index < self.image_tokens.items.len and
            self.image_tokens.items[index].span.raw_start < token.span.raw_start) : (index += 1)
        {}
        self.image_tokens.insertAssumeCapacity(index, token);
    }

    pub fn registerSkillTokenAssumeCapacity(
        self: *State,
        token: SkillTokenSpan,
    ) void {
        self.insertSkillTokenSortedAssumeCapacity(token);
    }

    pub fn isValidImageToken(
        self: *const State,
        input: []const u8,
        token: entity_spans.ImageTokenSpan,
    ) bool {
        _ = self;
        return validImageToken(input, token);
    }

    pub fn isValidSkillToken(
        self: *const State,
        input: []const u8,
        token: SkillTokenSpan,
    ) bool {
        _ = self;
        return validSkillToken(input, token);
    }

    pub fn nextPasteIdAfter(
        self: *const State,
        blocks: []const paste_blocks.PastedBlock,
    ) error{Overflow}!usize {
        var next_id = self.next_paste_id;
        for (blocks) |block| {
            if (block.id >= next_id) {
                next_id = try std.math.add(usize, block.id, 1);
            }
        }
        return next_id;
    }

    pub fn replace(
        self: *State,
        alloc: Allocator,
        next_pasted_blocks: *std.ArrayList(paste_blocks.PastedBlock),
        next_image_tokens: *std.ArrayList(entity_spans.ImageTokenSpan),
        next_skill_tokens: *std.ArrayList(SkillTokenSpan),
    ) void {
        paste_blocks.deinitBlocks(alloc, &self.pasted_blocks);
        self.image_tokens.deinit(alloc);
        self.clearSkillTokens(alloc);
        self.skill_tokens.deinit(alloc);

        self.pasted_blocks = next_pasted_blocks.*;
        next_pasted_blocks.* = .empty;
        self.image_tokens = next_image_tokens.*;
        next_image_tokens.* = .empty;
        self.skill_tokens = next_skill_tokens.*;
        next_skill_tokens.* = .empty;
        self.pending_auto_separator = null;
    }

    pub fn entityStartingAt(
        self: *const State,
        input: []const u8,
        raw_start: usize,
    ) ?Entity {
        for (self.pasted_blocks.items, 0..) |block, index| {
            if (block.span.raw_start != raw_start) continue;
            const span = paste_blocks.registeredPlaceholderSpanStartingAt(
                input,
                raw_start,
                self.pasted_blocks.items,
            ) orelse return null;
            return .{
                .kind = .paste,
                .index = index,
                .id = block.id,
                .span = .{ .raw_start = span.start, .raw_end = span.end },
            };
        }
        for (self.image_tokens.items, 0..) |token, index| {
            if (token.span.raw_start != raw_start) continue;
            if (!validImageToken(input, token)) return null;
            return .{
                .kind = .image,
                .index = index,
                .id = token.id,
                .span = token.span,
            };
        }
        for (self.skill_tokens.items, 0..) |token, index| {
            if (token.raw_start != raw_start) continue;
            if (!validSkillToken(input, token)) return null;
            return .{
                .kind = .skill,
                .index = index,
                .span = .{ .raw_start = token.raw_start, .raw_end = token.raw_end },
            };
        }
        return null;
    }

    pub fn entityEndingAt(
        self: *const State,
        input: []const u8,
        raw_end: usize,
    ) ?Entity {
        for (self.pasted_blocks.items, 0..) |block, index| {
            if (block.span.raw_end != raw_end) continue;
            if (paste_blocks.registeredPlaceholderSpanStartingAt(
                input,
                block.span.raw_start,
                self.pasted_blocks.items,
            ) == null) return null;
            return .{ .kind = .paste, .index = index, .id = block.id, .span = block.span };
        }
        for (self.image_tokens.items, 0..) |token, index| {
            if (token.span.raw_end != raw_end) continue;
            if (!validImageToken(input, token)) return null;
            return .{ .kind = .image, .index = index, .id = token.id, .span = token.span };
        }
        for (self.skill_tokens.items, 0..) |token, index| {
            if (token.raw_end != raw_end) continue;
            if (!validSkillToken(input, token)) return null;
            return .{
                .kind = .skill,
                .index = index,
                .span = .{ .raw_start = token.raw_start, .raw_end = token.raw_end },
            };
        }
        return null;
    }

    pub fn entityContaining(
        self: *const State,
        input: []const u8,
        raw_offset: usize,
    ) ?Entity {
        for (self.pasted_blocks.items, 0..) |block, index| {
            if (!block.span.contains(raw_offset)) continue;
            if (paste_blocks.registeredPlaceholderSpanStartingAt(
                input,
                block.span.raw_start,
                self.pasted_blocks.items,
            ) == null) return null;
            return .{ .kind = .paste, .index = index, .id = block.id, .span = block.span };
        }
        for (self.image_tokens.items, 0..) |token, index| {
            if (!token.span.contains(raw_offset)) continue;
            if (!validImageToken(input, token)) return null;
            return .{ .kind = .image, .index = index, .id = token.id, .span = token.span };
        }
        for (self.skill_tokens.items, 0..) |token, index| {
            const span = entity_spans.Span{ .raw_start = token.raw_start, .raw_end = token.raw_end };
            if (!span.contains(raw_offset)) continue;
            if (!validSkillToken(input, token)) return null;
            return .{ .kind = .skill, .index = index, .span = span };
        }
        return null;
    }

    pub fn entityOverlapping(
        self: *const State,
        raw_start: usize,
        raw_end: usize,
    ) ?Entity {
        const edit_span = entity_spans.Span{ .raw_start = raw_start, .raw_end = raw_end };
        for (self.pasted_blocks.items, 0..) |block, index| {
            if (!entity_spans.overlaps(block.span, edit_span)) continue;
            return .{ .kind = .paste, .index = index, .id = block.id, .span = block.span };
        }
        for (self.image_tokens.items, 0..) |token, index| {
            if (!entity_spans.overlaps(token.span, edit_span)) continue;
            return .{ .kind = .image, .index = index, .id = token.id, .span = token.span };
        }
        for (self.skill_tokens.items, 0..) |token, index| {
            const span = entity_spans.Span{ .raw_start = token.raw_start, .raw_end = token.raw_end };
            if (!entity_spans.overlaps(span, edit_span)) continue;
            return .{ .kind = .skill, .index = index, .span = span };
        }
        return null;
    }

    pub fn entityEndingAtOrContaining(
        self: *const State,
        input: []const u8,
        raw_offset: usize,
    ) ?Entity {
        if (self.entityEndingAt(input, raw_offset)) |entity| return entity;
        return self.entityContaining(input, raw_offset);
    }

    pub fn entityStartingAtOrContaining(
        self: *const State,
        input: []const u8,
        raw_offset: usize,
    ) ?Entity {
        if (self.entityStartingAt(input, raw_offset)) |entity| return entity;
        return self.entityContaining(input, raw_offset);
    }

    pub fn remove(self: *State, alloc: Allocator, entity: Entity) ?usize {
        switch (entity.kind) {
            .paste => {
                const removed = self.pasted_blocks.orderedRemove(entity.index);
                debug_trace.logf(
                    "input",
                    "placeholder backing dropped kind=paste id={d} backing_bytes={d} reason=atomic_entity_delete",
                    .{ removed.id, removed.text.len },
                );
                alloc.free(removed.text);
                return null;
            },
            .image => {
                _ = self.image_tokens.orderedRemove(entity.index);
                debug_trace.logf(
                    "input",
                    "placeholder backing dropped kind=image id={d} reason=atomic_entity_delete",
                    .{entity.id},
                );
                return entity.id;
            },
            .skill => {
                self.removeSkillTokenAt(alloc, entity.index);
                return null;
            },
        }
    }

    pub fn convertSkillTokenContaining(
        self: *State,
        alloc: Allocator,
        raw_offset: usize,
    ) void {
        if (self.skillTokenIndexContaining(raw_offset)) |index| {
            self.removeSkillTokenAt(alloc, index);
        }
    }

    pub fn shiftForInsert(
        self: *State,
        alloc: Allocator,
        raw_offset: usize,
        byte_len: usize,
    ) void {
        if (byte_len == 0) return;

        var skill_index: usize = 0;
        while (skill_index < self.skill_tokens.items.len) {
            const token = &self.skill_tokens.items[skill_index];
            if (token.owns_trailing_separator and raw_offset == token.raw_end) {
                token.owns_trailing_separator = false;
            }
            const projected = entity_spans.afterInsert(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
            }, raw_offset, byte_len) orelse {
                self.removeSkillTokenAt(alloc, skill_index);
                continue;
            };
            token.raw_start = projected.raw_start;
            token.raw_end = projected.raw_end;
            skill_index += 1;
        }

        var paste_index: usize = 0;
        while (paste_index < self.pasted_blocks.items.len) {
            const block = &self.pasted_blocks.items[paste_index];
            const projected = entity_spans.afterInsert(block.span, raw_offset, byte_len) orelse {
                debug_trace.logf(
                    "input",
                    "placeholder backing dropped kind=paste id={d} backing_bytes={d} reason=interior_insert",
                    .{ block.id, block.text.len },
                );
                const removed = self.pasted_blocks.orderedRemove(paste_index);
                alloc.free(removed.text);
                continue;
            };
            block.span = projected;
            paste_index += 1;
        }

        var image_index: usize = 0;
        while (image_index < self.image_tokens.items.len) {
            const token = &self.image_tokens.items[image_index];
            const projected = entity_spans.afterInsert(token.span, raw_offset, byte_len) orelse {
                debug_trace.logf(
                    "input",
                    "placeholder registration dropped kind=image id={d} reason=interior_insert",
                    .{token.id},
                );
                _ = self.image_tokens.orderedRemove(image_index);
                continue;
            };
            token.span = projected;
            image_index += 1;
        }
    }

    pub fn adjustForDelete(
        self: *State,
        alloc: Allocator,
        start: usize,
        end: usize,
    ) void {
        var skill_index: usize = 0;
        while (skill_index < self.skill_tokens.items.len) {
            const token = &self.skill_tokens.items[skill_index];
            if (token.owns_trailing_separator and start <= token.raw_end and end > token.raw_end) {
                token.owns_trailing_separator = false;
            }
            const projected = entity_spans.afterDelete(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
            }, start, end) orelse {
                self.removeSkillTokenAt(alloc, skill_index);
                continue;
            };
            token.raw_start = projected.raw_start;
            token.raw_end = projected.raw_end;
            skill_index += 1;
        }

        var paste_index: usize = 0;
        while (paste_index < self.pasted_blocks.items.len) {
            const block = &self.pasted_blocks.items[paste_index];
            const projected = entity_spans.afterDelete(block.span, start, end) orelse {
                const removed = self.pasted_blocks.orderedRemove(paste_index);
                debug_trace.logf(
                    "input",
                    "placeholder backing dropped kind=paste id={d} backing_bytes={d} reason=range_delete",
                    .{ removed.id, removed.text.len },
                );
                alloc.free(removed.text);
                continue;
            };
            block.span = projected;
            paste_index += 1;
        }

        var image_index: usize = 0;
        while (image_index < self.image_tokens.items.len) {
            const token = &self.image_tokens.items[image_index];
            const projected = entity_spans.afterDelete(token.span, start, end) orelse {
                debug_trace.logf(
                    "input",
                    "placeholder registration dropped kind=image id={d} reason=range_delete",
                    .{token.id},
                );
                _ = self.image_tokens.orderedRemove(image_index);
                continue;
            };
            token.span = projected;
            image_index += 1;
        }
    }

    pub fn bindSkillToken(
        self: *State,
        alloc: Allocator,
        editor: *editor_state.State,
        replace_start: usize,
        replace_end: usize,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
        display_path: ?skill_contract.SkillPathDiscriminator,
    ) BindError!void {
        if (replace_start > replace_end or replace_end > editor.input.items.len) {
            return error.InvalidSkillTokenRange;
        }

        const append_separator = shouldAppendSkillTokenSeparator(
            editor.input.items,
            replace_end,
        );
        const token_len = try std.math.add(usize, 1, name.len);
        const inserted_len = try std.math.add(
            usize,
            token_len,
            @intFromBool(append_separator),
        );
        const retained_len = editor.input.items.len - (replace_end - replace_start);
        const final_len = try std.math.add(usize, retained_len, inserted_len);
        const raw = try std.fmt.allocPrint(
            alloc,
            "${s}{s}",
            .{ name, if (append_separator) " " else "" },
        );
        defer alloc.free(raw);

        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        try editor.input.ensureTotalCapacity(alloc, final_len);
        try self.skill_tokens.ensureTotalCapacity(
            alloc,
            try std.math.add(usize, self.skill_tokens.items.len, 1),
        );

        self.pending_auto_separator = null;
        if (replace_start < replace_end) {
            self.adjustForDelete(alloc, replace_start, replace_end);
            std.debug.assert(editor.deleteTextRange(replace_start, replace_end));
        }
        _ = editor.setCursor(replace_start);
        self.convertSkillTokenContaining(alloc, replace_start);
        editor.insertSliceAssumeCapacity(raw);
        self.shiftForInsert(alloc, replace_start, raw.len);
        self.insertSkillTokenSortedAssumeCapacity(.{
            .raw_start = replace_start,
            .raw_end = replace_start + token_len,
            .name = owned_name,
            .path = owned_path,
            .display_source = display_source,
            .display_path = display_path,
            .owns_trailing_separator = append_separator,
        });
        _ = editor.setCursor(replace_start + inserted_len);
        if (append_separator) {
            self.pending_auto_separator = .{
                .raw_offset = replace_start + token_len,
                .owner = .{ .skill = replace_start },
            };
        }
    }

    pub fn skillTokenInsertedLen(
        self: *const State,
        input: []const u8,
        replace_end: usize,
        name: []const u8,
    ) usize {
        _ = self;
        return 1 + name.len + @as(
            usize,
            if (shouldAppendSkillTokenSeparator(input, replace_end)) 1 else 0,
        );
    }

    pub fn markFileCompletionSeparator(
        self: *State,
        input: []const u8,
        cursor: usize,
        raw_offset: usize,
    ) void {
        if (raw_offset >= input.len or
            input[raw_offset] != ' ' or
            cursor != raw_offset + 1)
        {
            self.pending_auto_separator = null;
            return;
        }
        self.pending_auto_separator = .{
            .raw_offset = raw_offset,
            .owner = .file,
        };
    }

    pub fn claimPendingAutoSeparator(
        self: *State,
        input: []const u8,
        cursor: usize,
        byte: u8,
    ) bool {
        const pending = self.pending_auto_separator orelse return false;
        if (byte != ' ' or
            pending.raw_offset >= input.len or
            input[pending.raw_offset] != ' ' or
            cursor != pending.raw_offset + 1)
        {
            self.pending_auto_separator = null;
            return false;
        }

        switch (pending.owner) {
            .file => {},
            .skill => |raw_start| {
                const index = self.skillTokenIndexStartingAt(raw_start) orelse {
                    self.pending_auto_separator = null;
                    return false;
                };
                const token = &self.skill_tokens.items[index];
                if (token.raw_end != pending.raw_offset or !token.owns_trailing_separator) {
                    self.pending_auto_separator = null;
                    return false;
                }
                token.owns_trailing_separator = false;
            },
        }

        self.pending_auto_separator = null;
        return true;
    }

    pub fn atomicForwardDeleteEnd(
        self: *const State,
        input: []const u8,
        cursor: usize,
        entity: Entity,
    ) usize {
        if (cursor != entity.span.raw_start or entity.kind != .skill) {
            return entity.span.raw_end;
        }
        const token = self.skill_tokens.items[entity.index];
        if (!token.owns_trailing_separator or
            token.raw_end >= input.len or
            input[token.raw_end] != ' ')
        {
            return entity.span.raw_end;
        }
        return token.raw_end + 1;
    }

    fn clearSkillTokens(self: *State, alloc: Allocator) void {
        for (self.skill_tokens.items) |token| {
            alloc.free(token.name);
            alloc.free(token.path);
        }
        self.skill_tokens.clearRetainingCapacity();
        self.pending_auto_separator = null;
    }

    fn insertSkillTokenSortedAssumeCapacity(
        self: *State,
        token: SkillTokenSpan,
    ) void {
        var index: usize = 0;
        while (index < self.skill_tokens.items.len and
            self.skill_tokens.items[index].raw_start < token.raw_start) : (index += 1)
        {}
        self.skill_tokens.insertAssumeCapacity(index, token);
    }

    fn removeSkillTokenAt(self: *State, alloc: Allocator, index: usize) void {
        const token = self.skill_tokens.orderedRemove(index);
        alloc.free(token.name);
        alloc.free(token.path);
    }

    fn skillTokenIndexStartingAt(self: *const State, raw_start: usize) ?usize {
        for (self.skill_tokens.items, 0..) |token, index| {
            if (token.raw_start == raw_start) return index;
            if (token.raw_start > raw_start) return null;
        }
        return null;
    }

    fn skillTokenIndexContaining(self: *const State, raw_offset: usize) ?usize {
        for (self.skill_tokens.items, 0..) |token, index| {
            if (token.raw_start < raw_offset and raw_offset < token.raw_end) return index;
            if (token.raw_start >= raw_offset) return null;
        }
        return null;
    }
};

fn validImageToken(input: []const u8, token: entity_spans.ImageTokenSpan) bool {
    if (!token.span.isValid(input.len)) return false;
    const match = image_attachments.matchImagePlaceholder(
        input,
        token.span.raw_start,
    ) orelse return false;
    return match.id == token.id and
        token.span.raw_start + match.length == token.span.raw_end;
}

fn validSkillToken(input: []const u8, token: SkillTokenSpan) bool {
    if (token.raw_start >= token.raw_end or token.raw_end > input.len) return false;
    const raw = input[token.raw_start..token.raw_end];
    return raw.len == token.name.len + 1 and
        raw[0] == '$' and
        std.mem.eql(u8, raw[1..], token.name);
}

fn shouldAppendSkillTokenSeparator(input: []const u8, replace_end: usize) bool {
    if (replace_end >= input.len) return true;
    const rune = display_width.decodeNextRune(input, replace_end);
    if (isWhitespaceRune(rune.codepoint)) return false;
    return isWordChar(rune.codepoint);
}

fn isWordChar(codepoint: u21) bool {
    if (codepoint == '_') return true;
    if (codepoint >= 'a' and codepoint <= 'z') return true;
    if (codepoint >= 'A' and codepoint <= 'Z') return true;
    if (codepoint >= '0' and codepoint <= '9') return true;
    if (codepoint >= 0xC0) return true;
    return false;
}

fn isWhitespaceRune(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r';
}

test "registered entity lookup accepts only canonical registered bytes" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const placeholder = "[Pasted text #1, 2 lines]";
    try state.pasted_blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "first\nsecond"),
        .line_count = 2,
        .span = .{ .raw_start = 0, .raw_end = placeholder.len },
    });

    try std.testing.expectEqual(
        Kind.paste,
        state.entityStartingAt(placeholder, 0).?.kind,
    );
    try std.testing.expect(state.entityStartingAt("[Pasted text #1, 3 lines]", 0) == null);
}

test "registered entity projections shift external edits and drop interior edits" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.skill_tokens.append(alloc, .{
        .raw_start = 4,
        .raw_end = 11,
        .name = try alloc.dupe(u8, "review"),
        .path = try alloc.dupe(u8, "/skills/review.md"),
    });

    state.shiftForInsert(alloc, 2, 3);
    try std.testing.expectEqual(@as(usize, 7), state.skill_tokens.items[0].raw_start);
    try std.testing.expectEqual(@as(usize, 14), state.skill_tokens.items[0].raw_end);

    state.adjustForDelete(alloc, 8, 9);
    try std.testing.expectEqual(@as(usize, 0), state.skill_tokens.items.len);
}

test "skill binding and separator claim form one atomic state transition" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);

    try editor.setText(alloc, "$rev");
    try state.bindSkillToken(
        alloc,
        &editor,
        0,
        editor.input.items.len,
        "review",
        "/skills/review.md",
        null,
        null,
    );
    try std.testing.expectEqualStrings("$review ", editor.input.items);
    try std.testing.expect(state.skill_tokens.items[0].owns_trailing_separator);
    try std.testing.expect(state.claimPendingAutoSeparator(
        editor.input.items,
        editor.cursor,
        ' ',
    ));
    try std.testing.expect(!state.skill_tokens.items[0].owns_trailing_separator);
    try std.testing.expectEqualStrings("$review ", editor.input.items);
}
