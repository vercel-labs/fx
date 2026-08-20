const std = @import("std");
const editor_state = @import("editor_state.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const ModelPickerStage = enum {
    model,
    effort,
    fast,
};

pub const InlinePickerKind = enum {
    slash,
    model,
    file,
    skill,
};

pub const model_picker_fast_options = [_][]const u8{ "normal", "fast" };

pub const ModelPickerQuery = struct {
    stage: ModelPickerStage,
    query: []const u8,
    token_start: usize,
};

pub const FilePickerQuery = struct {
    /// Bytes between `@` and the cursor, without the leading `@`.
    query: []const u8,
    /// Byte offset of the `@` in the composer text.
    at_offset: usize,
    /// Byte offset where `query` begins.
    token_start: usize,
    /// The query begins with `@"` and stays open across spaces.
    quoted: bool = false,
};

pub const InlineSkillQuery = struct {
    /// Bytes between `$` and the cursor, without the leading `$`.
    query: []const u8,
    /// Byte offset of the `$` in the composer text.
    dollar_offset: usize,
    /// Byte offset where `query` begins.
    token_start: usize,
};

pub const InlineSlashQuery = struct {
    /// Slash command prefix through the cursor, including the leading `/`.
    prefix: []const u8,
};

/// Owns layout-independent composer picker state. Call `deinit` with the
/// allocator used by `beginModelPickerFlow`.
pub const State = struct {
    slash_completion_index: usize = 0,
    slash_completion_window_start: usize = 0,
    dismissed_inline_picker: ?InlinePickerKind = null,
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor_current: bool = false,
    model_picker_stage: ModelPickerStage = .model,
    model_picker_pending_model: std.ArrayList(u8) = .empty,
    model_picker_effort_index: usize = 0,
    model_picker_effort_window_start: usize = 0,
    model_picker_fast_index: usize = 0,
    model_picker_fast_window_start: usize = 0,
    file_completion_index: usize = 0,
    file_completion_window_start: usize = 0,
    file_picker_episode_seen: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.model_picker_pending_model.deinit(alloc);
        self.* = .{};
    }

    pub fn resetInlinePickerEpisode(self: *State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.dismissed_inline_picker = null;
    }

    pub fn dismissInlinePicker(self: *State, kind: InlinePickerKind) void {
        self.dismissed_inline_picker = kind;
    }

    pub fn isInlinePickerDismissed(self: *const State, kind: InlinePickerKind) bool {
        return self.dismissed_inline_picker == kind;
    }

    pub fn reconcileInlinePickerAfterEdit(self: *State, editor: *const editor_state.State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        const dismissed = self.dismissed_inline_picker orelse return;
        if (self.inlinePickerTriggerKind(editor) != dismissed) self.dismissed_inline_picker = null;
    }

    pub fn resetFilePickerIndex(self: *State) void {
        self.file_completion_index = 0;
        self.file_completion_window_start = 0;
    }

    pub fn activeFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.isInlinePickerDismissed(.file)) return null;
        return self.rawFilePickerQuery(editor);
    }

    pub fn activeModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        if (self.isInlinePickerDismissed(.model)) return null;
        return self.rawModelPickerQuery(editor);
    }

    pub fn activeInlineSkillQuery(self: *const State, editor: *const editor_state.State) ?InlineSkillQuery {
        if (self.isInlinePickerDismissed(.skill)) return null;
        return findInlineSkillQuery(editor.input.items, editor.cursor);
    }

    pub fn activeInlineSlashQuery(self: *const State, editor: *const editor_state.State) ?InlineSlashQuery {
        if (self.isInlinePickerDismissed(.slash)) return null;
        return findInlineSlashQuery(editor.input.items, editor.cursor);
    }

    fn rawFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.rawModelPickerQuery(editor) != null) return null;
        return findFilePickerQuery(editor.input.items, editor.cursor);
    }

    pub fn inlinePickerTriggerKind(self: *const State, editor: *const editor_state.State) ?InlinePickerKind {
        if (self.rawModelPickerQuery(editor) != null) return .model;
        if (self.rawFilePickerQuery(editor) != null) return .file;
        if (findInlineSkillQuery(editor.input.items, editor.cursor) != null) return .skill;
        if (findInlineSlashQuery(editor.input.items, editor.cursor) != null) return .slash;
        const trimmed = std.mem.trimStart(u8, editor.input.items, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '/') return .slash;
        return null;
    }

    fn rawModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        const items = editor.input.items;
        const trim_start = leadingWhitespaceLen(items);
        const trimmed = items[trim_start..];
        const prefix = "/model ";
        if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

        switch (self.model_picker_stage) {
            .model => return .{
                .stage = .model,
                .query = trimmed[prefix.len..],
                .token_start = trim_start + prefix.len,
            },
            .effort => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .effort) orelse return null;
                return .{
                    .stage = .effort,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
            .fast => {
                const token_start = modelPickerTokenStart(trimmed, self.model_picker_pending_model.items, .fast) orelse return null;
                return .{
                    .stage = .fast,
                    .query = trimmed[token_start..],
                    .token_start = trim_start + token_start,
                };
            },
        }
    }

    pub fn isModelShapedInput(self: *const State, editor: *const editor_state.State) bool {
        return isBareModelCommandAtCursor(editor) or self.rawModelPickerQuery(editor) != null;
    }

    pub fn resetActiveModelPickerIndex(self: *State) void {
        switch (self.model_picker_stage) {
            .model => {
                self.model_completion_index = 0;
                self.model_completion_window_start = 0;
                self.model_completion_anchor_current = false;
            },
            .effort => {
                self.model_picker_effort_index = 0;
                self.model_picker_effort_window_start = 0;
            },
            .fast => {
                self.model_picker_fast_index = 0;
                self.model_picker_fast_window_start = 0;
            },
        }
    }

    pub fn beginModelPickerFlow(
        self: *State,
        alloc: Allocator,
        model: []const u8,
        effort_index: usize,
        fast_mode: bool,
        stage: ModelPickerStage,
    ) Allocator.Error!void {
        const stable_model = try alloc.dupe(u8, model);
        defer alloc.free(stable_model);

        try self.model_picker_pending_model.ensureTotalCapacity(alloc, stable_model.len);
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_pending_model.appendSliceAssumeCapacity(stable_model);
        self.model_picker_stage = stage;
        self.model_picker_effort_index = effort_index;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = if (fast_mode) 1 else 0;
        self.model_picker_fast_window_start = 0;
    }

    pub fn clearModelPickerFlow(self: *State) void {
        self.model_picker_stage = .model;
        self.model_picker_pending_model.clearRetainingCapacity();
        self.model_picker_effort_index = 0;
        self.model_picker_effort_window_start = 0;
        self.model_picker_fast_index = 0;
        self.model_picker_fast_window_start = 0;
        self.model_completion_index = 0;
        self.model_completion_window_start = 0;
        self.model_completion_anchor_current = false;
    }

    pub fn hasPendingModelPickerSelection(self: *const State) bool {
        return self.model_picker_pending_model.items.len > 0;
    }

    pub fn selectedModelPickerEffortIndex(self: *const State) usize {
        return self.model_picker_effort_index;
    }

    pub fn selectedModelPickerFast(self: *const State) bool {
        return self.model_picker_fast_index % model_picker_fast_options.len == 1;
    }
};

pub fn isBareModelCommandAtCursor(editor: *const editor_state.State) bool {
    if (editor.cursor != editor.input.items.len) return false;
    const trimmed = std.mem.trimStart(u8, editor.input.items, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "/model");
}

pub fn filterCompletionLabels(query: []const u8, options: []const []const u8, out: [][]const u8) usize {
    const normalized_query = std.mem.trim(u8, query, " \t");
    var count: usize = 0;
    for (options) |option| {
        if (count >= out.len) break;
        if (normalized_query.len == 0 or text_utils.containsIgnoreCase(option, normalized_query)) {
            out[count] = option;
            count += 1;
        }
    }
    return count;
}

pub fn isFilePickerTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn leadingWhitespaceLen(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

fn findFilePickerQuery(items: []const u8, cursor: usize) ?FilePickerQuery {
    if (cursor > items.len) return null;

    var index = cursor;
    while (index > 0) {
        const byte = items[index - 1];
        if (byte == '@') {
            const at_offset = index - 1;
            if (at_offset > 0 and !isFilePickerStartBoundary(items[at_offset - 1])) {
                index -= 1;
                continue;
            }
            const quoted = index < cursor and items[index] == '"';
            const token_start = index + @intFromBool(quoted);
            return .{
                .query = items[token_start..cursor],
                .at_offset = at_offset,
                .token_start = token_start,
                .quoted = quoted,
            };
        }
        if (isFilePickerTerminator(byte)) break;
        index -= 1;
    }

    index = cursor;
    while (index > 1) {
        const byte = items[index - 1];
        if (byte == '\t' or byte == '\n' or byte == '\r') return null;
        if (byte == '"') {
            const at_offset = index - 2;
            if (items[at_offset] != '@') return null;
            if (at_offset > 0 and !isFilePickerStartBoundary(items[at_offset - 1])) return null;
            return .{
                .query = items[index..cursor],
                .at_offset = at_offset,
                .token_start = index,
                .quoted = true,
            };
        }
        index -= 1;
    }

    return null;
}

fn findInlineSkillQuery(items: []const u8, cursor: usize) ?InlineSkillQuery {
    if (cursor != items.len) return null;

    var token_start = cursor;
    while (token_start > 0 and !isFilePickerTerminator(items[token_start - 1])) {
        token_start -= 1;
    }
    if (token_start == 0 or token_start == cursor or items[token_start] != '$') return null;

    const query_start = token_start + 1;
    if (query_start == cursor) return null;
    return .{
        .query = items[query_start..cursor],
        .dollar_offset = token_start,
        .token_start = query_start,
    };
}

fn findInlineSlashQuery(items: []const u8, cursor: usize) ?InlineSlashQuery {
    if (cursor != items.len) return null;

    var token_start = cursor;
    while (token_start > 0 and !isFilePickerTerminator(items[token_start - 1])) {
        token_start -= 1;
    }
    if (token_start == 0 or token_start + 1 >= cursor or items[token_start] != '/') return null;
    if (std.mem.trim(u8, items[0..token_start], " \t\r\n").len == 0) return null;

    return .{ .prefix = items[token_start..cursor] };
}

fn isFilePickerStartBoundary(byte: u8) bool {
    if (isFilePickerTerminator(byte)) return true;
    return switch (byte) {
        '(', '[', '{', '<', '\'', '"', '`' => true,
        else => false,
    };
}

fn modelPickerTokenStart(trimmed: []const u8, model: []const u8, stage: ModelPickerStage) ?usize {
    const prefix = "/model ";
    if (trimmed.len < prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;
    if (model.len == 0) return null;

    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len < model.len or !std.mem.eql(u8, after_prefix[0..model.len], model)) return null;

    const after_model = prefix.len + model.len;
    if (stage == .effort) return skipPickerSpaces(trimmed, after_model);

    const effort_start = skipPickerSpaces(trimmed, after_model);
    if (effort_start >= trimmed.len) return effort_start;

    var effort_end = effort_start;
    while (effort_end < trimmed.len and trimmed[effort_end] != ' ' and trimmed[effort_end] != '\t') : (effort_end += 1) {}
    return skipPickerSpaces(trimmed, effort_end);
}

fn skipPickerSpaces(bytes: []const u8, start: usize) usize {
    var index = start;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return index;
}

test "picker state resolves model file skill and slash queries" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "/model gpt");
    const model_query = state.activeModelPickerQuery(&editor).?;
    try std.testing.expectEqual(ModelPickerStage.model, model_query.stage);
    try std.testing.expectEqualStrings("gpt", model_query.query);

    try editor.setText(alloc, "open (@src/main.zig");
    const file_query = state.activeFilePickerQuery(&editor).?;
    try std.testing.expectEqualStrings("src/main.zig", file_query.query);

    try editor.setText(alloc, "use $blueprint");
    try std.testing.expectEqualStrings("blueprint", state.activeInlineSkillQuery(&editor).?.query);

    try editor.setText(alloc, "then /help");
    try std.testing.expectEqualStrings("/help", state.activeInlineSlashQuery(&editor).?.prefix);
}

test "model picker query takes precedence over file syntax" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "/model @provider");
    try std.testing.expect(state.activeModelPickerQuery(&editor) != null);
    try std.testing.expectEqual(@as(?FilePickerQuery, null), state.activeFilePickerQuery(&editor));
}

test "picker dismissal lasts for one trigger episode" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "use $blueprint");
    state.dismissInlinePicker(.skill);
    try std.testing.expect(state.activeInlineSkillQuery(&editor) == null);

    try editor.setText(alloc, "use $blueprintx");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expect(state.isInlinePickerDismissed(.skill));

    try editor.setText(alloc, "use blueprint ");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expect(!state.isInlinePickerDismissed(.skill));
}

test "file picker state transitions activation dismissal and recovery" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "plain text");
    try std.testing.expect(state.activeFilePickerQuery(&editor) == null);

    try editor.setText(alloc, "@");
    try std.testing.expectEqualStrings("", state.activeFilePickerQuery(&editor).?.query);

    try editor.setText(alloc, "@./scoped/@types");
    try std.testing.expectEqualStrings("./scoped/@types", state.activeFilePickerQuery(&editor).?.query);

    try editor.setText(alloc, "@\"./space dir/item");
    const quoted = state.activeFilePickerQuery(&editor).?;
    try std.testing.expect(quoted.quoted);
    try std.testing.expectEqualStrings("./space dir/item", quoted.query);

    state.dismissInlinePicker(.file);
    try std.testing.expect(state.activeFilePickerQuery(&editor) == null);

    try editor.setText(alloc, "@\"./space dir/item.txt");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expect(state.isInlinePickerDismissed(.file));

    try editor.setText(alloc, "plain text");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expect(!state.isInlinePickerDismissed(.file));

    try editor.setText(alloc, "@~/Downloads");
    try std.testing.expectEqualStrings("~/Downloads", state.activeFilePickerQuery(&editor).?.query);

    try editor.setText(alloc, "@~/Downloads/file.txt ");
    try std.testing.expect(state.activeFilePickerQuery(&editor) == null);
}

test "model picker flow accepts aliased pending model input" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginModelPickerFlow(alloc, "openai/gpt-5", 2, false, .effort);
    const aliased_model = state.model_picker_pending_model.items;
    try state.beginModelPickerFlow(alloc, aliased_model, 3, true, .fast);

    try std.testing.expectEqual(ModelPickerStage.fast, state.model_picker_stage);
    try std.testing.expectEqualStrings("openai/gpt-5", state.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 3), state.selectedModelPickerEffortIndex());
    try std.testing.expect(state.selectedModelPickerFast());
}

test "model picker fast stage accepts a model without an effort token" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginModelPickerFlow(alloc, "zai/glm-5.2", 0, true, .fast);
    try editor.setText(alloc, "/model zai/glm-5.2 ");
    const query = state.activeModelPickerQuery(&editor).?;
    try std.testing.expectEqual(ModelPickerStage.fast, query.stage);
    try std.testing.expectEqualStrings("", query.query);
}

test "model picker flow preserves state when allocation fails" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginModelPickerFlow(alloc, "old", 2, false, .effort);

    var failing = std.testing.FailingAllocator.init(alloc, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    var large_model: [4096]u8 = undefined;
    @memset(&large_model, 'x');
    try std.testing.expectError(
        error.OutOfMemory,
        state.beginModelPickerFlow(
            failing.allocator(),
            &large_model,
            5,
            true,
            .fast,
        ),
    );

    try std.testing.expectEqual(ModelPickerStage.effort, state.model_picker_stage);
    try std.testing.expectEqualStrings("old", state.model_picker_pending_model.items);
    try std.testing.expectEqual(@as(usize, 2), state.model_picker_effort_index);
    try std.testing.expect(!state.selectedModelPickerFast());
}

test "completion label filtering is trimmed and case insensitive" {
    const options = [_][]const u8{ "High", "xhigh", "max" };
    var matches: [options.len][]const u8 = undefined;
    const count = filterCompletionLabels(" H ", &options, &matches);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("High", matches[0]);
    try std.testing.expectEqualStrings("xhigh", matches[1]);
}
