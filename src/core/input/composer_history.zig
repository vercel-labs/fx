const std = @import("std");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const paste_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ImageBlocks = std.ArrayList(types.ImageAttachment);

pub const NavigationResult = union(enum) {
    unchanged,
    limit_exceeded: usize,
    moved: usize,
};

pub const EntryView = struct {
    text: []const u8,
    pasted_blocks: []const paste_blocks.PastedBlock,
    images: []const types.ImageAttachment,
    image_tokens: []const entity_spans.ImageTokenSpan,
    skill_tokens: []const registered_entities.SkillTokenSpan,
};

pub const ActiveComposer = struct {
    edit: *editor_state.State,
    entities: *registered_entities.State,
    picker: *picker_state.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,
    images: ?*ImageBlocks,
};

const NavigationTarget = union(enum) {
    unchanged,
    entry: usize,
    draft,
};

fn navigationTarget(index: ?usize, entry_count: usize, delta: i32) NavigationTarget {
    if (entry_count == 0) return .unchanged;
    if (index) |current| {
        if (current >= entry_count) return .unchanged;
    }
    if (delta < 0) {
        if (index) |current| {
            if (current == 0) return .unchanged;
            return .{ .entry = current - 1 };
        }
        return .{ .entry = entry_count - 1 };
    }

    const current = index orelse return .unchanged;
    if (current + 1 < entry_count) return .{ .entry = current + 1 };
    return .draft;
}

const Snapshot = struct {
    text: std.ArrayList(u8) = .empty,
    pasted_blocks: std.ArrayList(paste_blocks.PastedBlock) = .empty,
    images: std.ArrayList(types.ImageAttachment) = .empty,
    image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
    skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,
    owns_image_snapshots: bool = false,

    fn view(self: *const Snapshot) EntryView {
        return .{
            .text = self.text.items,
            .pasted_blocks = self.pasted_blocks.items,
            .images = self.images.items,
            .image_tokens = self.image_tokens.items,
            .skill_tokens = self.skill_tokens.items,
        };
    }

    fn initCopy(
        alloc: Allocator,
        text: []const u8,
        pasted: []const paste_blocks.PastedBlock,
        images: []const types.ImageAttachment,
        image_tokens: []const entity_spans.ImageTokenSpan,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !Snapshot {
        var snapshot: Snapshot = .{};
        errdefer snapshot.deinit(alloc);

        try snapshot.text.appendSlice(alloc, text);
        try snapshot.pasted_blocks.ensureTotalCapacity(alloc, pasted.len);
        for (pasted) |block| {
            snapshot.pasted_blocks.appendAssumeCapacity(.{
                .id = block.id,
                .text = try alloc.dupe(u8, block.text),
                .line_count = block.line_count,
                .span = block.span,
            });
        }

        const image_copy = try types.dupeImageAttachmentSlice(alloc, images);
        snapshot.images = std.ArrayList(types.ImageAttachment).fromOwnedSlice(image_copy);
        try snapshot.image_tokens.appendSlice(alloc, image_tokens);

        try snapshot.skill_tokens.ensureTotalCapacity(alloc, skill_tokens.len);
        for (skill_tokens) |token| {
            const name = try alloc.dupe(u8, token.name);
            errdefer alloc.free(name);
            const path = try alloc.dupe(u8, token.path);
            snapshot.skill_tokens.appendAssumeCapacity(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .name = name,
                .path = path,
                .display_source = token.display_source,
                .owns_trailing_separator = token.owns_trailing_separator,
            });
        }
        return snapshot;
    }

    fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.text.deinit(alloc);
        paste_blocks.deinitBlocks(alloc, &self.pasted_blocks);
        for (self.images.items) |image| {
            if (self.owns_image_snapshots) {
                image_attachments.discardImageAttachment(alloc, image);
            } else {
                types.freeImageAttachment(alloc, image);
            }
        }
        self.images.deinit(alloc);
        self.image_tokens.deinit(alloc);
        for (self.skill_tokens.items) |token| {
            alloc.free(token.name);
            alloc.free(token.path);
        }
        self.skill_tokens.deinit(alloc);
        self.* = .{};
    }

    fn eql(a: *const Snapshot, b: *const Snapshot) bool {
        if (!std.mem.eql(u8, a.text.items, b.text.items) or
            a.pasted_blocks.items.len != b.pasted_blocks.items.len or
            a.images.items.len != b.images.items.len or
            a.image_tokens.items.len != b.image_tokens.items.len or
            a.skill_tokens.items.len != b.skill_tokens.items.len)
        {
            return false;
        }
        for (a.pasted_blocks.items, b.pasted_blocks.items) |left, right| {
            if (left.id != right.id or
                left.line_count != right.line_count or
                !std.meta.eql(left.span, right.span) or
                !std.mem.eql(u8, left.text, right.text))
            {
                return false;
            }
        }
        for (a.images.items, b.images.items) |left, right| {
            if (left.id != right.id or
                !std.mem.eql(u8, left.path, right.path) or
                !std.mem.eql(u8, left.media_type, right.media_type) or
                !optionalBytesEql(left.snapshot_path, right.snapshot_path) or
                !optionalBytesEql(left.snapshot_sha256, right.snapshot_sha256))
            {
                return false;
            }
        }
        for (a.image_tokens.items, b.image_tokens.items) |left, right| {
            if (left.id != right.id or !std.meta.eql(left.span, right.span)) {
                return false;
            }
        }
        for (a.skill_tokens.items, b.skill_tokens.items) |left, right| {
            if (left.raw_start != right.raw_start or
                left.raw_end != right.raw_end or
                !std.mem.eql(u8, left.name, right.name) or
                !std.mem.eql(u8, left.path, right.path) or
                left.display_source != right.display_source or
                left.owns_trailing_separator != right.owns_trailing_separator)
            {
                return false;
            }
        }
        return true;
    }

    fn prepareRecall(
        self: *const Snapshot,
        alloc: Allocator,
        first_image_id: usize,
    ) !Snapshot {
        if (self.images.items.len == 0) {
            return initCopy(
                alloc,
                self.text.items,
                self.pasted_blocks.items,
                &.{},
                self.image_tokens.items,
                self.skill_tokens.items,
            );
        }
        if (self.images.items.len != self.image_tokens.items.len) {
            return error.InvalidPromptHistorySnapshot;
        }
        _ = try std.math.add(usize, first_image_id, self.images.items.len);

        var prepared = Snapshot{ .owns_image_snapshots = true };
        errdefer prepared.deinit(alloc);

        var source_offset: usize = 0;
        for (self.image_tokens.items, 0..) |token, image_index| {
            if (!token.span.isValid(self.text.items.len) or
                token.span.raw_start < source_offset)
            {
                return error.InvalidPromptHistorySnapshot;
            }
            const match = image_attachments.matchImagePlaceholder(
                self.text.items,
                token.span.raw_start,
            ) orelse return error.InvalidPromptHistorySnapshot;
            if (match.id != token.id or
                token.span.raw_start + match.length != token.span.raw_end)
            {
                return error.InvalidPromptHistorySnapshot;
            }
            const attachment = image_attachments.findById(
                self.images.items,
                token.id,
            ) orelse return error.InvalidPromptHistorySnapshot;

            try prepared.text.appendSlice(
                alloc,
                self.text.items[source_offset..token.span.raw_start],
            );
            const target_start = prepared.text.items.len;
            const target_id = try std.math.add(usize, first_image_id, image_index);
            var placeholder_buf: [64]u8 = undefined;
            const placeholder = try image_attachments.formatImagePlaceholder(
                &placeholder_buf,
                target_id,
            );
            try prepared.text.appendSlice(alloc, placeholder);
            try prepared.image_tokens.append(alloc, .{
                .id = target_id,
                .span = .{
                    .raw_start = target_start,
                    .raw_end = target_start + placeholder.len,
                },
            });
            const cloned = try image_attachments.cloneVerifiedImageAttachment(
                alloc,
                attachment,
                target_id,
            );
            var cloned_owned = true;
            errdefer if (cloned_owned) {
                image_attachments.discardImageAttachment(alloc, cloned);
            };
            try prepared.images.append(alloc, cloned);
            cloned_owned = false;
            source_offset = token.span.raw_end;
        }
        try prepared.text.appendSlice(alloc, self.text.items[source_offset..]);

        try prepared.pasted_blocks.ensureTotalCapacity(
            alloc,
            self.pasted_blocks.items.len,
        );
        for (self.pasted_blocks.items) |block| {
            const raw_start = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                block.span.raw_start,
            ) orelse return error.InvalidPromptHistorySnapshot;
            const raw_end = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                block.span.raw_end,
            ) orelse return error.InvalidPromptHistorySnapshot;
            prepared.pasted_blocks.appendAssumeCapacity(.{
                .id = block.id,
                .text = try alloc.dupe(u8, block.text),
                .line_count = block.line_count,
                .span = .{ .raw_start = raw_start, .raw_end = raw_end },
            });
        }

        try prepared.skill_tokens.ensureTotalCapacity(
            alloc,
            self.skill_tokens.items.len,
        );
        for (self.skill_tokens.items) |token| {
            const raw_start = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                token.raw_start,
            ) orelse return error.InvalidPromptHistorySnapshot;
            const raw_end = image_attachments.projectOffsetThroughPlaceholderRewrite(
                self.image_tokens.items,
                prepared.image_tokens.items,
                self.text.items.len,
                token.raw_end,
            ) orelse return error.InvalidPromptHistorySnapshot;
            const name = try alloc.dupe(u8, token.name);
            errdefer alloc.free(name);
            const path = try alloc.dupe(u8, token.path);
            prepared.skill_tokens.appendAssumeCapacity(.{
                .raw_start = raw_start,
                .raw_end = raw_end,
                .name = name,
                .path = path,
                .display_source = token.display_source,
                .owns_trailing_separator = token.owns_trailing_separator,
            });
        }
        return prepared;
    }

    fn optionalBytesEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }
};

pub const State = struct {
    entries: std.ArrayList(Snapshot) = .empty,
    draft: ?Snapshot = null,
    index: ?usize = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
    }

    pub fn count(self: *const State) usize {
        return self.entries.items.len;
    }

    pub fn activeIndex(self: *const State) ?usize {
        return self.index;
    }

    pub fn draftText(self: *const State) ?[]const u8 {
        return (self.draftView() orelse return null).text;
    }

    pub fn entryText(self: *const State, entry_index: usize) ?[]const u8 {
        return (self.viewEntry(entry_index) orelse return null).text;
    }

    pub fn viewEntry(self: *const State, entry_index: usize) ?EntryView {
        if (entry_index >= self.entries.items.len) return null;
        return self.entries.items[entry_index].view();
    }

    pub fn draftView(self: *const State) ?EntryView {
        const draft = self.draft orelse return null;
        return draft.view();
    }

    pub fn record(
        self: *State,
        alloc: Allocator,
        max_entries: usize,
        text: []const u8,
        pasted: []const paste_blocks.PastedBlock,
        images: []const types.ImageAttachment,
        image_tokens: []const entity_spans.ImageTokenSpan,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !void {
        var entry = try Snapshot.initCopy(
            alloc,
            text,
            pasted,
            images,
            image_tokens,
            skill_tokens,
        );
        errdefer entry.deinit(alloc);
        if (self.entries.items.len > 0 and
            self.entries.items[self.entries.items.len - 1].eql(&entry))
        {
            entry.deinit(alloc);
            return;
        }

        try self.entries.append(alloc, entry);
        entry = .{};
        while (self.entries.items.len > max_entries) {
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit(alloc);
        }
    }

    /// Transfers ownership of the latest entry's image snapshot files when it
    /// describes the same accepted image set. Metadata remains independently
    /// owned by the history entry.
    pub fn claimLatestImageSnapshots(
        self: *State,
        expected: []const types.ImageAttachment,
    ) bool {
        if (expected.len == 0 or self.entries.items.len == 0) return false;
        const latest = &self.entries.items[self.entries.items.len - 1];
        if (latest.images.items.len != expected.len) return false;
        for (latest.images.items, expected) |recorded, pending| {
            if (recorded.id != pending.id or
                !std.mem.eql(u8, recorded.path, pending.path) or
                !std.mem.eql(u8, recorded.media_type, pending.media_type) or
                !Snapshot.optionalBytesEql(recorded.snapshot_path, pending.snapshot_path) or
                !Snapshot.optionalBytesEql(recorded.snapshot_sha256, pending.snapshot_sha256))
            {
                return false;
            }
        }
        latest.owns_image_snapshots = true;
        return true;
    }

    pub fn installTextEntries(
        self: *State,
        alloc: Allocator,
        entries: []const []const u8,
    ) !void {
        var installed: std.ArrayList(Snapshot) = .empty;
        errdefer {
            for (installed.items) |*entry| entry.deinit(alloc);
            installed.deinit(alloc);
        }
        try installed.ensureTotalCapacity(alloc, entries.len);
        for (entries) |entry| {
            installed.appendAssumeCapacity(try Snapshot.initCopy(
                alloc,
                entry,
                &.{},
                &.{},
                &.{},
                &.{},
            ));
        }

        self.clear(alloc);
        self.entries.deinit(alloc);
        self.entries = installed;
        self.resetNavigation(alloc);
    }

    pub fn resetNavigation(self: *State, alloc: Allocator) void {
        self.index = null;
        if (self.draft) |*draft| {
            draft.deinit(alloc);
            self.draft = null;
        }
    }

    pub fn clear(self: *State, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.clearRetainingCapacity();
        self.resetNavigation(alloc);
    }

    pub fn navigate(
        self: *State,
        alloc: Allocator,
        delta: i32,
        active: ActiveComposer,
        first_image_id: usize,
        max_len: usize,
    ) !NavigationResult {
        const target = navigationTarget(self.index, self.entries.items.len, delta);
        if (target == .unchanged) return .unchanged;

        const entering_history = self.index == null;
        const restoring_draft = target == .draft;
        var prepared = switch (target) {
            .unchanged => unreachable,
            .entry => |entry_index| try self.entries.items[entry_index].prepareRecall(
                alloc,
                first_image_id,
            ),
            .draft => blk: {
                const draft = self.draft orelse return error.InvalidComposerHistoryState;
                break :blk try Snapshot.initCopy(
                    alloc,
                    draft.text.items,
                    draft.pasted_blocks.items,
                    draft.images.items,
                    draft.image_tokens.items,
                    draft.skill_tokens.items,
                );
            },
        };
        defer prepared.deinit(alloc);

        const expanded_len = paste_blocks.expandedLen(
            prepared.text.items,
            prepared.pasted_blocks.items,
        ) orelse std.math.maxInt(usize);
        if (expanded_len > max_len) {
            return .{ .limit_exceeded = expanded_len };
        }
        if (prepared.images.items.len > 0 and active.images == null) {
            return error.MissingImageAttachmentOwner;
        }
        if (entering_history and active.entities.image_tokens.items.len > 0 and active.images == null) {
            return error.MissingImageAttachmentOwner;
        }
        const recalled_image_count = if (restoring_draft)
            0
        else
            prepared.images.items.len;
        const next_paste_id = try active.entities.nextPasteIdAfter(
            prepared.pasted_blocks.items,
        );

        var captured_draft: ?Snapshot = null;
        errdefer if (captured_draft) |*draft| draft.deinit(alloc);
        if (entering_history) {
            const draft_images = if (active.images) |images| images.items else &.{};
            captured_draft = try Snapshot.initCopy(
                alloc,
                active.edit.input.items,
                active.entities.pasted_blocks.items,
                draft_images,
                active.entities.image_tokens.items,
                active.entities.skill_tokens.items,
            );
        }

        replaceActiveComposer(alloc, active, &prepared);
        if (active.images) |images| {
            if (entering_history) {
                for (images.items) |image| types.freeImageAttachment(alloc, image);
                captured_draft.?.owns_image_snapshots = true;
            } else {
                for (images.items) |image| {
                    image_attachments.discardImageAttachment(alloc, image);
                }
            }
            images.deinit(alloc);
            images.* = prepared.images;
            prepared.images = .empty;
            prepared.owns_image_snapshots = false;
        }
        active.entities.next_paste_id = next_paste_id;

        if (entering_history) {
            self.draft = captured_draft.?;
            captured_draft = null;
        }
        if (restoring_draft) {
            self.index = null;
            self.draft.?.owns_image_snapshots = false;
            self.draft.?.deinit(alloc);
            self.draft = null;
            return .{ .moved = 0 };
        }
        self.index = switch (target) {
            .entry => |entry_index| entry_index,
            .unchanged, .draft => unreachable,
        };
        return .{ .moved = recalled_image_count };
    }
};

fn replaceActiveComposer(
    alloc: Allocator,
    active: ActiveComposer,
    prepared: *Snapshot,
) void {
    active.vertical_navigation.reset();
    if (active.edit.discardSelection()) |dropped_bytes| {
        debug_trace.logf(
            "input",
            "selection dropped bytes={d} reason=prompt_history_recall",
            .{dropped_bytes},
        );
    }
    active.picker.clearModelPickerFlow();

    var previous_text: std.ArrayList(u8) = .empty;
    active.edit.swapInput(&previous_text);
    active.edit.swapInput(&prepared.text);
    active.entities.replace(
        alloc,
        &prepared.pasted_blocks,
        &prepared.image_tokens,
        &prepared.skill_tokens,
    );
    previous_text.deinit(alloc);

    active.picker.resetInlinePickerEpisode();
    active.picker.model_completion_index = 0;
    active.picker.model_completion_window_start = 0;
    active.picker.resetFilePickerIndex();
    active.input_limit_rejection.* = input_limit_rejection.clear();
}

test "navigation target follows bounded older and newer history laws" {
    try std.testing.expectEqual(NavigationTarget.unchanged, navigationTarget(null, 0, -1));
    try std.testing.expectEqual(NavigationTarget{ .entry = 2 }, navigationTarget(null, 3, -1));
    try std.testing.expectEqual(NavigationTarget.unchanged, navigationTarget(0, 3, -1));
    try std.testing.expectEqual(NavigationTarget{ .entry = 1 }, navigationTarget(0, 3, 1));
    try std.testing.expectEqual(NavigationTarget.draft, navigationTarget(2, 3, 1));
    try std.testing.expectEqual(NavigationTarget.unchanged, navigationTarget(null, 3, 1));
    try std.testing.expectEqual(NavigationTarget.unchanged, navigationTarget(3, 3, -1));
}

test "record deduplicates adjacent entries and prunes the oldest" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try state.record(alloc, 2, "one", &.{}, &.{}, &.{}, &.{});
    try state.record(alloc, 2, "one", &.{}, &.{}, &.{}, &.{});
    try state.record(alloc, 2, "two", &.{}, &.{}, &.{}, &.{});
    try state.record(alloc, 2, "three", &.{}, &.{}, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expectEqualStrings("two", state.entryText(0).?);
    try std.testing.expectEqualStrings("three", state.entryText(1).?);
}

test "navigation recalls entries and restores the unsent draft" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.installTextEntries(alloc, &.{ "older", "newer" });

    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    try edit.setText(alloc, "unsent draft");
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var picker: picker_state.State = .{};
    defer picker.deinit(alloc);
    var vertical_intent: vertical_navigation.State = .{ .preferred_column = 4 };
    var limit_rejection: input_limit_rejection.State = .{ .owner = .composer };
    const active = ActiveComposer{
        .edit = &edit,
        .entities = &entities,
        .picker = &picker,
        .vertical_navigation = &vertical_intent,
        .input_limit_rejection = &limit_rejection,
        .images = null,
    };

    try std.testing.expectEqual(
        NavigationResult{ .moved = 0 },
        try state.navigate(alloc, -1, active, 1, 4096),
    );
    try std.testing.expectEqualStrings("newer", edit.input.items);
    try std.testing.expectEqualStrings("unsent draft", state.draftText().?);
    try std.testing.expectEqual(@as(?usize, 1), state.activeIndex());
    try std.testing.expectEqual(@as(?usize, null), vertical_intent.preferredColumn());
    try std.testing.expectEqual(input_limit_rejection.State{}, limit_rejection);

    try std.testing.expectEqual(
        NavigationResult{ .moved = 0 },
        try state.navigate(alloc, 1, active, 1, 4096),
    );
    try std.testing.expectEqualStrings("unsent draft", edit.input.items);
    try std.testing.expect(state.draftText() == null);
    try std.testing.expectEqual(@as(?usize, null), state.activeIndex());
}

test "oversized recall leaves active composer and history position unchanged" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.installTextEntries(alloc, &.{"oversized"});

    var edit: editor_state.State = .{};
    defer edit.deinit(alloc);
    try edit.setText(alloc, "draft");
    var entities: registered_entities.State = .{};
    defer entities.deinit(alloc);
    var picker: picker_state.State = .{};
    defer picker.deinit(alloc);
    var vertical_intent: vertical_navigation.State = .{ .preferred_column = 2 };
    var limit_rejection: input_limit_rejection.State = .{};

    try std.testing.expectEqual(
        NavigationResult{ .limit_exceeded = "oversized".len },
        try state.navigate(alloc, -1, .{
            .edit = &edit,
            .entities = &entities,
            .picker = &picker,
            .vertical_navigation = &vertical_intent,
            .input_limit_rejection = &limit_rejection,
            .images = null,
        }, 1, 4),
    );
    try std.testing.expectEqualStrings("draft", edit.input.items);
    try std.testing.expectEqual(@as(?usize, null), state.activeIndex());
    try std.testing.expect(state.draftText() == null);
    try std.testing.expectEqual(@as(?usize, 2), vertical_intent.preferredColumn());
}
