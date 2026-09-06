const std = @import("std");
const editor_state = @import("editor_state.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const ModelPickerStage = enum {
    model,
    effort,
    fast,
};

/// Columns of the `/provider` picker, left to right. Each stage owns one
/// whitespace-free token in the composer, so the next column anchors under the
/// argument it belongs to.
pub const ProviderPickerStage = enum {
    provider,
    method,
    team,
    /// Which detected key to use, or `new` to paste one.
    key_source,
    /// Not a list: the column is the masked API key field.
    api_key,
};

pub const InlinePickerKind = enum {
    slash,
    model,
    provider,
    file,
    skill,
};

const InlinePickerSuppression = union(enum) {
    dismissed_until_trigger_change: InlinePickerKind,
    history_slash_recall_until_edit,

    fn kind(self: InlinePickerSuppression) InlinePickerKind {
        return switch (self) {
            .dismissed_until_trigger_change => |suppressed_kind| suppressed_kind,
            .history_slash_recall_until_edit => .slash,
        };
    }
};

pub const model_picker_fast_options = [_][]const u8{ "normal", "fast" };

/// `/login` and `/setup` are aliases of `/provider`: all open the same
/// columnar picker. Typed text keeps whichever spelling the user wrote;
/// executing the bare command reseeds the composer with the canonical
/// `/provider ` prefix.
pub const provider_prefix = "/provider ";
pub const login_prefix = "/login ";
const setup_prefix = "/setup ";
pub const provider_picker_prefixes = [_][]const u8{ provider_prefix, login_prefix, setup_prefix };

pub fn providerPickerPrefix(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, input, " \t\r\n");
    const len = providerPickerPrefixLen(trimmed) orelse return null;
    return trimmed[0..len];
}

pub const ModelPickerQuery = struct {
    stage: ModelPickerStage,
    query: []const u8,
    token_start: usize,
};

pub const ProviderPickerQuery = struct {
    stage: ProviderPickerStage,
    /// The `/provider ` or `/login ` the user typed, kept verbatim so rewriting
    /// the composer does not swap one alias for the other.
    prefix: []const u8,
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
    inline_picker_suppression: ?InlinePickerSuppression = null,
    model_completion_index: usize = 0,
    model_completion_window_start: usize = 0,
    model_completion_anchor_current: bool = false,
    model_picker_stage: ModelPickerStage = .model,
    model_picker_pending_model: std.ArrayList(u8) = .empty,
    model_picker_effort_index: usize = 0,
    model_picker_effort_window_start: usize = 0,
    model_picker_fast_index: usize = 0,
    model_picker_fast_window_start: usize = 0,
    provider_picker_stage: ProviderPickerStage = .provider,
    provider_picker_pending_provider: std.ArrayList(u8) = .empty,
    provider_picker_pending_method: std.ArrayList(u8) = .empty,
    provider_column_index: usize = 0,
    provider_column_window_start: usize = 0,
    method_column_index: usize = 0,
    method_column_window_start: usize = 0,
    team_column_index: usize = 0,
    team_column_window_start: usize = 0,
    key_source_column_index: usize = 0,
    key_source_column_window_start: usize = 0,
    file_completion_index: usize = 0,
    file_completion_window_start: usize = 0,
    file_picker_episode_seen: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.model_picker_pending_model.deinit(alloc);
        self.provider_picker_pending_provider.deinit(alloc);
        self.provider_picker_pending_method.deinit(alloc);
        self.* = .{};
    }

    pub fn resetInlinePickerEpisode(self: *State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.inline_picker_suppression = null;
    }

    pub fn resetInlinePickerForHistoryRecall(self: *State, editor: *const editor_state.State) void {
        self.resetInlinePickerEpisode();
        self.inline_picker_suppression = suppressionForHistoryRecall(
            self.inlinePickerTriggerKind(editor),
        );
    }

    pub fn dismissInlinePicker(self: *State, kind: InlinePickerKind) void {
        self.inline_picker_suppression = .{ .dismissed_until_trigger_change = kind };
    }

    pub fn isInlinePickerDismissed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return switch (suppression) {
            .dismissed_until_trigger_change => |dismissed| dismissed == kind,
            .history_slash_recall_until_edit => false,
        };
    }

    pub fn isInlinePickerSuppressed(self: *const State, kind: InlinePickerKind) bool {
        const suppression = self.inline_picker_suppression orelse return false;
        return suppression.kind() == kind;
    }

    pub fn reconcileInlinePickerAfterEdit(self: *State, editor: *const editor_state.State) void {
        self.slash_completion_index = 0;
        self.slash_completion_window_start = 0;
        self.reconcileProviderPickerAfterEdit(editor);
        self.inline_picker_suppression = suppressionAfterEdit(
            self.inline_picker_suppression,
            self.inlinePickerTriggerKind(editor),
        );
    }

    /// An edit that breaks the committed provider or method token orphans the
    /// later columns: the text no longer names the choice they refine. Degrade
    /// to the provider column so the picker follows the text instead of dying.
    fn reconcileProviderPickerAfterEdit(self: *State, editor: *const editor_state.State) void {
        if (self.provider_picker_stage == .provider) return;
        if (self.rawProviderPickerQuery(editor) != null) return;
        const trimmed = editor.input.items[leadingWhitespaceLen(editor.input.items)..];
        if (providerPickerPrefixLen(trimmed) == null) return;
        self.clearProviderPickerFlow();
    }

    pub fn resetFilePickerIndex(self: *State) void {
        self.file_completion_index = 0;
        self.file_completion_window_start = 0;
    }

    pub fn activeFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.isInlinePickerSuppressed(.file)) return null;
        return self.rawFilePickerQuery(editor);
    }

    pub fn activeModelPickerQuery(self: *const State, editor: *const editor_state.State) ?ModelPickerQuery {
        if (self.isInlinePickerSuppressed(.model)) return null;
        return self.rawModelPickerQuery(editor);
    }

    pub fn activeProviderPickerQuery(self: *const State, editor: *const editor_state.State) ?ProviderPickerQuery {
        if (self.isInlinePickerDismissed(.provider)) return null;
        return self.rawProviderPickerQuery(editor);
    }

    pub fn activeInlineSkillQuery(self: *const State, editor: *const editor_state.State) ?InlineSkillQuery {
        if (self.isInlinePickerSuppressed(.skill)) return null;
        return findInlineSkillQuery(editor.input.items, editor.cursor);
    }

    pub fn activeInlineSlashQuery(self: *const State, editor: *const editor_state.State) ?InlineSlashQuery {
        if (self.isInlinePickerSuppressed(.slash)) return null;
        return findInlineSlashQuery(editor.input.items, editor.cursor);
    }

    fn rawFilePickerQuery(self: *const State, editor: *const editor_state.State) ?FilePickerQuery {
        if (self.rawModelPickerQuery(editor) != null) return null;
        if (self.rawProviderPickerQuery(editor) != null) return null;
        const command_text = std.mem.trimStart(u8, editor.input.items, " \t\r\n");
        if (tokenMatchesAt(command_text, 0, "/mcp")) return null;
        return findFilePickerQuery(editor.input.items, editor.cursor);
    }

    pub fn inlinePickerTriggerKind(self: *const State, editor: *const editor_state.State) ?InlinePickerKind {
        if (self.rawModelPickerQuery(editor) != null) return .model;
        if (self.rawProviderPickerQuery(editor) != null) return .provider;
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

    fn rawProviderPickerQuery(self: *const State, editor: *const editor_state.State) ?ProviderPickerQuery {
        const items = editor.input.items;
        const trim_start = leadingWhitespaceLen(items);
        const trimmed = items[trim_start..];
        const prefix_len = providerPickerPrefixLen(trimmed) orelse return null;

        const stage = self.provider_picker_stage;
        if (stage == .provider) return .{
            .stage = .provider,
            .prefix = trimmed[0..prefix_len],
            .query = trimmed[prefix_len..],
            .token_start = trim_start + prefix_len,
        };

        const method: ?[]const u8 = switch (stage) {
            .team, .key_source, .api_key => self.provider_picker_pending_method.items,
            .provider, .method => null,
        };
        const token_start = providerPickerTokenStart(
            trimmed,
            prefix_len,
            self.provider_picker_pending_provider.items,
            method,
        ) orelse return null;
        return .{
            .stage = stage,
            .prefix = trimmed[0..prefix_len],
            .query = trimmed[token_start..],
            .token_start = trim_start + token_start,
        };
    }

    /// The composer text changed, so whichever column is open no longer has a
    /// trustworthy highlighted row.
    pub fn resetActiveCompletionIndex(self: *State) void {
        self.resetActiveModelPickerIndex();
        self.resetActiveProviderPickerIndex();
    }

    fn resetActiveProviderPickerIndex(self: *State) void {
        switch (self.provider_picker_stage) {
            .provider => {
                self.provider_column_index = 0;
                self.provider_column_window_start = 0;
            },
            .method => {
                self.method_column_index = 0;
                self.method_column_window_start = 0;
            },
            .team => {
                self.team_column_index = 0;
                self.team_column_window_start = 0;
            },
            .key_source => {
                self.key_source_column_index = 0;
                self.key_source_column_window_start = 0;
            },
            .api_key => {},
        }
    }

    /// Records the tokens already committed to the composer so the later
    /// columns can anchor under their own argument. Leaves prior state intact
    /// when the copy fails.
    pub fn beginProviderPickerFlow(
        self: *State,
        alloc: Allocator,
        provider: []const u8,
        method: []const u8,
        stage: ProviderPickerStage,
    ) Allocator.Error!void {
        const stable_provider = try alloc.dupe(u8, provider);
        defer alloc.free(stable_provider);
        const stable_method = try alloc.dupe(u8, method);
        defer alloc.free(stable_method);

        try self.provider_picker_pending_provider.ensureTotalCapacity(alloc, stable_provider.len);
        try self.provider_picker_pending_method.ensureTotalCapacity(alloc, stable_method.len);
        self.provider_picker_pending_provider.clearRetainingCapacity();
        self.provider_picker_pending_provider.appendSliceAssumeCapacity(stable_provider);
        self.provider_picker_pending_method.clearRetainingCapacity();
        self.provider_picker_pending_method.appendSliceAssumeCapacity(stable_method);
        self.provider_picker_stage = stage;
        // A column is entered with nothing typed, so a highlight left over from
        // an earlier visit would point at an unrelated row.
        self.resetActiveProviderPickerIndex();
    }

    pub fn clearProviderPickerFlow(self: *State) void {
        self.provider_picker_stage = .provider;
        self.provider_picker_pending_provider.clearRetainingCapacity();
        self.provider_picker_pending_method.clearRetainingCapacity();
        self.provider_column_index = 0;
        self.provider_column_window_start = 0;
        self.method_column_index = 0;
        self.method_column_window_start = 0;
        self.team_column_index = 0;
        self.team_column_window_start = 0;
        self.key_source_column_index = 0;
        self.key_source_column_window_start = 0;
    }

    pub fn isModelShapedInput(self: *const State, editor: *const editor_state.State) bool {
        return isBareModelCommandAtCursor(editor) or self.rawModelPickerQuery(editor) != null;
    }

    fn resetActiveModelPickerIndex(self: *State) void {
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

fn suppressionForHistoryRecall(trigger: ?InlinePickerKind) ?InlinePickerSuppression {
    if (trigger != .slash) return null;
    return .history_slash_recall_until_edit;
}

fn suppressionAfterEdit(
    current: ?InlinePickerSuppression,
    trigger: ?InlinePickerKind,
) ?InlinePickerSuppression {
    const suppression = current orelse return null;
    return switch (suppression) {
        .dismissed_until_trigger_change => |dismissed| if (trigger == dismissed)
            suppression
        else
            null,
        .history_slash_recall_until_edit => null,
    };
}

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

/// Compacts `labels` and its parallel `annotations` in place to the entries
/// matching `query`, keeping the two arrays aligned.
pub fn filterAnnotatedLabels(
    query: []const u8,
    labels: [][]const u8,
    annotations: [][]const u8,
    count: usize,
) usize {
    const normalized_query = std.mem.trim(u8, query, " \t");
    if (normalized_query.len == 0) return count;

    var kept: usize = 0;
    for (0..count) |i| {
        if (!text_utils.containsIgnoreCase(labels[i], normalized_query)) continue;
        labels[kept] = labels[i];
        annotations[kept] = annotations[i];
        kept += 1;
    }
    return kept;
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

    var index = cursor;
    while (index > 0) {
        const byte = items[index - 1];
        if (isFilePickerTerminator(byte)) return null;
        index -= 1;
        if (byte != '$') continue;
        return .{
            .query = items[index + 1 .. cursor],
            .dollar_offset = index,
            .token_start = index + 1,
        };
    }
    return null;
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
    if (effort_start >= trimmed.len) return null;

    var effort_end = effort_start;
    while (effort_end < trimmed.len and trimmed[effort_end] != ' ' and trimmed[effort_end] != '\t') : (effort_end += 1) {}
    return skipPickerSpaces(trimmed, effort_end);
}

fn providerPickerPrefixLen(trimmed: []const u8) ?usize {
    for (provider_picker_prefixes) |prefix| {
        if (trimmed.len < prefix.len) continue;
        if (std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return prefix.len;
    }
    return null;
}

/// Walks past the tokens the picker already committed. Matching them verbatim
/// rather than scanning for whitespace keeps the anchor correct even when an
/// option label is not a single word.
fn providerPickerTokenStart(
    trimmed: []const u8,
    prefix_len: usize,
    provider: []const u8,
    method: ?[]const u8,
) ?usize {
    if (provider.len == 0) return null;
    const after_prefix = trimmed[prefix_len..];
    if (!tokenMatchesAt(after_prefix, 0, provider)) return null;

    const cursor = skipPickerSpaces(trimmed, prefix_len + provider.len);
    const wanted_method = method orelse return cursor;
    if (wanted_method.len == 0) return null;
    if (!tokenMatchesAt(trimmed, cursor, wanted_method)) return null;
    return skipPickerSpaces(trimmed, cursor + wanted_method.len);
}

/// True when `token` sits at `start` as a whole word. Without the boundary
/// check a committed `vercel` would also claim `vercelfoo`, re-anchoring the
/// picker mid-token in text that no longer names the choice.
fn tokenMatchesAt(bytes: []const u8, start: usize, token: []const u8) bool {
    if (bytes.len - start < token.len) return false;
    if (!std.mem.eql(u8, bytes[start..][0..token.len], token)) return false;
    const end = start + token.len;
    return end == bytes.len or bytes[end] == ' ' or bytes[end] == '\t';
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

test "skill query binds the nearest dollar anywhere at the cursor" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    const cases = [_]struct {
        input: []const u8,
        query: []const u8,
        dollar_offset: usize,
    }{
        .{ .input = "$", .query = "", .dollar_offset = 0 },
        .{ .input = "$blue", .query = "blue", .dollar_offset = 0 },
        .{ .input = "use $", .query = "", .dollar_offset = "use ".len },
        .{ .input = "price$100", .query = "100", .dollar_offset = "price".len },
        .{ .input = "one$two$three", .query = "three", .dollar_offset = "one$two".len },
    };

    for (cases) |case| {
        try editor.setText(alloc, case.input);
        const maybe_query = state.activeInlineSkillQuery(&editor);
        try std.testing.expect(maybe_query != null);
        const query = maybe_query.?;
        try std.testing.expectEqualStrings(case.query, query.query);
        try std.testing.expectEqual(case.dollar_offset, query.dollar_offset);
        try std.testing.expectEqual(case.dollar_offset + 1, query.token_start);
    }

    try editor.setText(alloc, "price$100 tail");
    try std.testing.expect(state.activeInlineSkillQuery(&editor) == null);
    _ = editor.setCursor("price$10".len);
    try std.testing.expect(state.activeInlineSkillQuery(&editor) == null);
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

test "MCP arguments stay literal while ordinary file queries remain eligible" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    const literal_inputs = [_][]const u8{
        "/mcp add memory npx -y @modelcontextprotocol/server-memory@2026.8.31",
        " \t/mcp\tadd memory npx @scope/package",
        "\n/mcp add memory npx @scope/package",
    };
    for (literal_inputs) |input| {
        try editor.setText(alloc, input);
        try std.testing.expect(state.activeFilePickerQuery(&editor) == null);
        try std.testing.expect(state.inlinePickerTriggerKind(&editor) != .file);
        _ = editor.setCursor(input.len - 1);
        try std.testing.expect(state.activeFilePickerQuery(&editor) == null);
    }

    const file_inputs = [_][]const u8{
        "read @src/main.zig",
        "/mcpx @src/main.zig",
        "explain /mcp @src/main.zig",
        "/review @src/main.zig",
    };
    for (file_inputs) |input| {
        try editor.setText(alloc, input);
        try std.testing.expectEqualStrings("src/main.zig", state.activeFilePickerQuery(&editor).?.query);
        try std.testing.expectEqual(InlinePickerKind.file, state.inlinePickerTriggerKind(&editor).?);
    }
}

test "MCP argument edits and history do not retain file picker ownership" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "read @scope/package");
    state.dismissInlinePicker(.file);
    try editor.setText(alloc, "/mcp add memory npx @scope/package");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expect(!state.isInlinePickerSuppressed(.file));
    state.resetInlinePickerForHistoryRecall(&editor);
    try std.testing.expect(state.activeFilePickerQuery(&editor) == null);
    try std.testing.expect(state.inlinePickerTriggerKind(&editor) != .file);

    try editor.setText(alloc, "read @scope/package");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expectEqualStrings("scope/package", state.activeFilePickerQuery(&editor).?.query);
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

test "provider picker opens on both command aliases and keeps the typed one" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    for (provider_picker_prefixes) |prefix| {
        try editor.setText(alloc, prefix);
        const query = state.activeProviderPickerQuery(&editor).?;
        try std.testing.expectEqual(ProviderPickerStage.provider, query.stage);
        try std.testing.expectEqualStrings(prefix, query.prefix);
        try std.testing.expectEqualStrings("", query.query);
        try std.testing.expectEqual(prefix.len, query.token_start);
        try std.testing.expectEqual(InlinePickerKind.provider, state.inlinePickerTriggerKind(&editor).?);
    }

    try editor.setText(alloc, "/provider gro");
    try std.testing.expectEqualStrings("gro", state.activeProviderPickerQuery(&editor).?.query);
}

test "provider picker columns anchor under the argument they belong to" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginProviderPickerFlow(alloc, "vercel", "", .method);
    try editor.setText(alloc, "/provider vercel ");
    const method = state.activeProviderPickerQuery(&editor).?;
    try std.testing.expectEqual(ProviderPickerStage.method, method.stage);
    try std.testing.expectEqual("/provider vercel ".len, method.token_start);
    try std.testing.expectEqualStrings("", method.query);

    try state.beginProviderPickerFlow(alloc, "vercel", "account", .team);
    try editor.setText(alloc, "/provider vercel account acme");
    const team = state.activeProviderPickerQuery(&editor).?;
    try std.testing.expectEqual(ProviderPickerStage.team, team.stage);
    try std.testing.expectEqual("/provider vercel account ".len, team.token_start);
    try std.testing.expectEqualStrings("acme", team.query);

    // Editing away the committed token retires the column instead of anchoring
    // the list under text that no longer names the choice.
    try editor.setText(alloc, "/provider codex account acme");
    try std.testing.expect(state.activeProviderPickerQuery(&editor) == null);
}

test "provider picker takes the composer back from the file and slash pickers" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try editor.setText(alloc, "/provider @vercel");
    try std.testing.expect(state.activeProviderPickerQuery(&editor) != null);
    try std.testing.expect(state.activeFilePickerQuery(&editor) == null);

    state.dismissInlinePicker(.provider);
    try std.testing.expect(state.activeProviderPickerQuery(&editor) == null);
}

test "clearing the provider picker flow returns the picker to the provider column" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginProviderPickerFlow(alloc, "vercel", "account", .team);
    state.team_column_index = 3;
    try std.testing.expect(state.provider_picker_pending_provider.items.len > 0);

    state.clearProviderPickerFlow();
    try std.testing.expectEqual(ProviderPickerStage.provider, state.provider_picker_stage);
    try std.testing.expectEqual(@as(usize, 0), state.team_column_index);
    try std.testing.expect(state.provider_picker_pending_provider.items.len == 0);
}

test "annotation filtering keeps labels and annotations aligned" {
    var labels = [_][]const u8{ "vercel", "codex", "grok" };
    var annotations = [_][]const u8{ "current", "", "" };

    try std.testing.expectEqual(@as(usize, 3), filterAnnotatedLabels("", &labels, &annotations, 3));

    const count = filterAnnotatedLabels("ok", &labels, &annotations, 3);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("grok", labels[0]);
    try std.testing.expectEqualStrings("", annotations[0]);
}

test "editing a committed token degrades the provider picker to the provider column" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginProviderPickerFlow(alloc, "vercel", "", .method);
    try editor.setText(alloc, "/provider verc");
    state.reconcileInlinePickerAfterEdit(&editor);

    const query = state.activeProviderPickerQuery(&editor).?;
    try std.testing.expectEqual(ProviderPickerStage.provider, query.stage);
    try std.testing.expectEqualStrings("verc", query.query);

    // Unrelated text leaves the flow alone; clearing the composer resets it
    // through clearCurrent instead.
    try state.beginProviderPickerFlow(alloc, "vercel", "", .method);
    try editor.setText(alloc, "hello world");
    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expectEqual(ProviderPickerStage.method, state.provider_picker_stage);
}

test "committed tokens only match at word boundaries" {
    const alloc = std.testing.allocator;
    var editor: editor_state.State = .{};
    defer editor.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);

    try state.beginProviderPickerFlow(alloc, "vercel", "", .method);
    try editor.setText(alloc, "/provider vercelfoo bar");
    try std.testing.expect(state.rawProviderPickerQuery(&editor) == null);

    state.reconcileInlinePickerAfterEdit(&editor);
    try std.testing.expectEqual(ProviderPickerStage.provider, state.provider_picker_stage);
}
