const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const input_reset = @import("input_reset.zig");
const io_mod = @import("../shared/io.zig");
const pasted_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Owns staged replacement bytes before commit and the displaced editor buffer
/// afterward. Always call `deinit` with the allocator used by `prepare`.
pub const Prepared = struct {
    input: std.ArrayList(u8) = .empty,
    dropped_entities: DroppedEntities = .{},

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        self.input.deinit(alloc);
        self.* = .{};
    }
};

const DroppedEntities = struct {
    pasted_blocks: usize = 0,
    image_tokens: usize = 0,
    skill_tokens: usize = 0,
};

/// Borrows the Core state changed by one whole-composer text replacement.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,

    /// Stages an exact replacement and records the entities it supersedes
    /// without mutating composer state.
    pub fn prepare(
        self: State,
        alloc: Allocator,
        text: []const u8,
    ) Allocator.Error!Prepared {
        var prepared: Prepared = .{
            .dropped_entities = .{
                .pasted_blocks = self.entities.pasted_blocks.items.len,
                .image_tokens = self.entities.image_tokens.items.len,
                .skill_tokens = self.entities.skill_tokens.items.len,
            },
        };
        errdefer prepared.deinit(alloc);
        try prepared.input.appendSlice(alloc, text);
        return prepared;
    }

    pub fn replace(
        self: State,
        alloc: Allocator,
        text: []const u8,
    ) Allocator.Error!void {
        var prepared_replacement = try self.prepare(alloc, text);
        defer prepared_replacement.deinit(alloc);
        self.commit(alloc, &prepared_replacement);
    }

    /// Swaps in staged text and resets metadata without further allocation.
    /// On return, `prepared_replacement` owns the displaced editor buffer.
    pub fn commit(
        self: State,
        alloc: Allocator,
        prepared_replacement: *Prepared,
    ) void {
        self.vertical_navigation.reset();
        input_reset.discardSelectionWithTrace(self.edit, "input_replaced");
        self.picker.clearModelPickerFlow();
        self.picker.clearProviderPickerFlow();
        traceDroppedEntities(prepared_replacement.dropped_entities);
        pasted_blocks.clearBlocks(alloc, &self.entities.pasted_blocks);
        self.entities.clearImageAndSkillTokens(alloc);
        self.edit.swapInput(&prepared_replacement.input);
        self.history.reset(alloc);
        self.picker.resetInlinePickerEpisode();
        self.picker.model_completion_index = 0;
        self.picker.model_completion_window_start = 0;
        self.picker.resetFilePickerIndex();
        self.input_limit_rejection.* = input_limit_rejection.clear();
    }
};

fn traceDroppedEntities(entities: DroppedEntities) void {
    if (entities.pasted_blocks > 0) {
        debug_trace.logf(
            "input",
            "pasted blocks dropped count={d} reason=input_replaced",
            .{entities.pasted_blocks},
        );
    }
    if (entities.image_tokens > 0) {
        debug_trace.logf(
            "input",
            "image tokens dropped count={d} reason=input_replaced",
            .{entities.image_tokens},
        );
    }
    if (entities.skill_tokens > 0) {
        debug_trace.logf(
            "input",
            "skill tokens dropped count={d} reason=input_replaced",
            .{entities.skill_tokens},
        );
    }
}

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.history.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
    }

    fn state(self: *Fixture) State {
        return .{
            .edit = &self.edit,
            .history = &self.history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    fn seed(self: *Fixture, alloc: Allocator) !void {
        try self.edit.setText(alloc, "old draft");
        _ = self.edit.beginSelection(0);
        _ = self.edit.extendSelection(self.edit.input.items.len);

        var prepared = try self.history.prepare(
            alloc,
            0,
            "",
            "old draft",
            0,
            "old draft".len,
        );
        defer prepared.deinit(alloc);
        self.history.commit(alloc, &prepared);

        try self.picker.beginModelPickerFlow(
            alloc,
            "provider/model",
            2,
            true,
            .effort,
        );
        self.picker.slash_completion_index = 4;
        self.picker.slash_completion_window_start = 2;
        self.picker.dismissInlinePicker(.file);
        self.picker.model_completion_index = 5;
        self.picker.model_completion_window_start = 3;
        self.picker.file_completion_index = 6;
        self.picker.file_completion_window_start = 4;

        {
            const pasted_backing = try alloc.dupe(u8, "pasted backing");
            errdefer alloc.free(pasted_backing);
            try self.entities.pasted_blocks.append(alloc, .{
                .id = 7,
                .text = pasted_backing,
                .line_count = 1,
            });
        }
        try self.entities.image_tokens.append(alloc, .{
            .id = 8,
            .span = .{ .raw_start = 0, .raw_end = 0 },
        });
        {
            const skill_name = try alloc.dupe(u8, "review");
            errdefer alloc.free(skill_name);
            const skill_path = try alloc.dupe(u8, "/tmp/review/SKILL.md");
            errdefer alloc.free(skill_path);
            try self.entities.skill_tokens.append(alloc, .{
                .raw_start = 0,
                .raw_end = 0,
                .name = skill_name,
                .path = skill_path,
            });
        }

        self.vertical_navigation.preferred_column = 9;
        self.input_limit_rejection = input_limit_rejection.begin(
            .{},
            .composer,
        ).next;
    }
};

test "whole composer replacement owns semantic cleanup and cursor state" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.seed(alloc);

    const replacement = "next\nh\xc3\xa9";
    try fixture.state().replace(alloc, replacement);

    try std.testing.expectEqualStrings(replacement, fixture.edit.input.items);
    try std.testing.expectEqual(replacement.len, fixture.edit.cursor);
    try std.testing.expect(fixture.edit.selectionRange() == null);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
    try std.testing.expect(!fixture.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_window_start);
    try std.testing.expect(!fixture.picker.isInlinePickerDismissed(.file));
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_window_start);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.file_completion_window_start);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.entities.skill_tokens.items.len);
    try std.testing.expectEqual(
        @as(?usize, null),
        fixture.vertical_navigation.preferredColumn(),
    );
    try std.testing.expect(fixture.input_limit_rejection.owner == null);
}

test "whole composer replacement preserves all state when staging fails" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.seed(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        fixture.state().replace(failing.allocator(), "replacement"),
    );

    try std.testing.expectEqualStrings("old draft", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, "old draft".len), fixture.edit.cursor);
    try std.testing.expectEqual(
        editor_state.SelectionRange{ .start = 0, .end = "old draft".len },
        fixture.edit.selectionRange().?,
    );
    try std.testing.expect(fixture.history.peekUndo() != null);
    try std.testing.expect(fixture.picker.hasPendingModelPickerSelection());
    try std.testing.expectEqual(@as(usize, 4), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 2), fixture.picker.slash_completion_window_start);
    try std.testing.expect(fixture.picker.isInlinePickerDismissed(.file));
    try std.testing.expectEqual(@as(usize, 5), fixture.picker.model_completion_index);
    try std.testing.expectEqual(@as(usize, 3), fixture.picker.model_completion_window_start);
    try std.testing.expectEqual(@as(usize, 6), fixture.picker.file_completion_index);
    try std.testing.expectEqual(@as(usize, 4), fixture.picker.file_completion_window_start);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.pasted_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.skill_tokens.items.len);
    try std.testing.expectEqual(
        @as(?usize, 9),
        fixture.vertical_navigation.preferredColumn(),
    );
    try std.testing.expectEqual(.composer, fixture.input_limit_rejection.owner.?);
}

test "prepared replacement traces entities cleared by its caller before commit" {
    const alloc = std.testing.allocator;
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.seed(alloc);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var prepared = try fixture.state().prepare(alloc, "replacement");
    defer prepared.deinit(alloc);
    pasted_blocks.clearBlocks(alloc, &fixture.entities.pasted_blocks);
    fixture.entities.clearImageAndSkillTokens(alloc);
    fixture.state().commit(alloc, &prepared);

    const zio = io_mod.getIo();
    var trace_file = try std.Io.Dir.openFileAbsolute(zio, trace_path, .{});
    defer trace_file.close(zio);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "pasted blocks dropped count=1 reason=input_replaced") != null);
    try std.testing.expect(std.mem.find(u8, trace, "image tokens dropped count=1 reason=input_replaced") != null);
    try std.testing.expect(std.mem.find(u8, trace, "skill tokens dropped count=1 reason=input_replaced") != null);
}
