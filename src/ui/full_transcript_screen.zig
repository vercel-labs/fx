const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const tool_result_display = @import("../core/tooling/tool_result_display.zig");
const command_output_content = @import("../core/tooling/command_output_content.zig");
const command_replay_store = @import("../core/session/command_replay_store.zig");
const result_store = @import("../core/session/result_store.zig");
const session_child_store = @import("../core/session/session_child_store.zig");
const diff_mod = @import("../core/output/diff.zig");
const transcript_presentation = @import("../core/output/transcript_presentation.zig");
const full_transcript_metadata = @import("../core/output/full_transcript_metadata.zig");
const assistant_wrap = @import("render_engine/assistant_wrap.zig");
const build_checkpoint = @import("render_engine/build_checkpoint.zig");
const transcript_blocks = @import("render_engine/transcript_blocks.zig");
const command_output_runtime = @import("transcript/command_output_runtime.zig");
const tool_group_projection = @import("transcript/tool_group_projection.zig");
const user_message_card = @import("assistant/user_message_card.zig");
const ui_render = @import("render.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const BuildCheckpoint = build_checkpoint.BuildCheckpoint;

const PendingInputProbe = struct {
    polls: usize = 0,

    fn pending(context: *anyopaque) bool {
        const self: *PendingInputProbe = @ptrCast(@alignCast(context));
        self.polls += 1;
        return true;
    }
};

test "projection source index resolves direct tool and command associations" {
    const alloc = std.testing.allocator;
    const block_call_id = try alloc.dupe(u8, "command-7");
    defer alloc.free(block_call_id);
    const lookup_call_id = try alloc.dupe(u8, "command-7");
    defer alloc.free(lookup_call_id);
    var block = command_output_runtime.CommandOutputBlock{
        .entry_id = 20,
        .lifecycle_id = .{ .turn_id = 7, .call_id = block_call_id },
        .retention_overflow = true,
    };
    try block.source_entry_ids.append(alloc, 21);
    defer block.source_entry_ids.deinit(alloc);
    const blocks = [_]command_output_runtime.CommandOutputBlock{block};
    const details = [_]ToolDetailRecord{.{
        .entry_id = 10,
        .tool_name = @constCast("run_command"),
        .lifecycle_id = .{ .turn_id = 7, .call_id = lookup_call_id },
        .command_output_entry_id = 20,
    }};

    var index = try ProjectionSourceIndex.build(alloc, &details, &blocks, null);
    defer index.deinit(alloc);

    try std.testing.expect(index.detailForEntry(10) == &details[0]);
    try std.testing.expectEqual(@as(?usize, 0), index.commandBlockIndexForEntry(20));
    try std.testing.expectEqual(
        @as(?usize, 0),
        index.commandBlockIndexForLifecycle(.{ .turn_id = 7, .call_id = lookup_call_id }),
    );
    try std.testing.expectEqual(@as(?usize, 0), index.commandBlockIndexForDetail(&details[0]));
    try std.testing.expect(index.commandSourceOwned(21));
}

test "interruptible full projection checks inside one oversized assistant entry" {
    const alloc = std.testing.allocator;
    var entries = [_]transcript_blocks.TranscriptEntry{.{ .assistant_turn = .{
        .id = 1,
        .segments = .{},
    } }};
    defer entries[0].assistant_turn.segments.deinit(alloc);
    try entries[0].assistant_turn.segments.text.appendNTimes(alloc, 'x', 16 * 1024);

    var probe = PendingInputProbe{};
    var checkpoint = BuildCheckpoint.init(&probe, PendingInputProbe.pending);
    try std.testing.expectError(
        error.InputPending,
        buildProjectionWithDiffResolverInterruptible(
            alloc,
            &entries,
            &.{},
            &.{},
            .{},
            80,
            null,
            null,
            &checkpoint,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.polls);

    var retry = try buildProjectionWithDiffResolverInterruptible(
        alloc,
        &entries,
        &.{},
        &.{},
        .{},
        80,
        null,
        null,
        null,
    );
    defer retry.deinit(alloc);
    var baseline = try buildProjectionWithDiffResolverInterruptible(
        alloc,
        &entries,
        &.{},
        &.{},
        .{},
        80,
        null,
        null,
        null,
    );
    defer baseline.deinit(alloc);
    const retry_bytes = try renderProjectionViewportSource(
        alloc,
        &retry,
        null,
        80,
        std.math.maxInt(u16),
        0,
    );
    defer alloc.free(retry_bytes);
    const baseline_bytes = try renderProjectionViewportSource(
        alloc,
        &baseline,
        null,
        80,
        std.math.maxInt(u16),
        0,
    );
    defer alloc.free(baseline_bytes);
    try std.testing.expectEqualStrings(baseline_bytes, retry_bytes);
}

test "interruptible full projection measurement checks inside one static segment" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    const bytes = try alloc.alloc(u8, 16 * 1024);
    @memset(bytes, 'x');
    try projection.segments.append(alloc, .{ .static = bytes });

    var probe = PendingInputProbe{};
    var checkpoint = BuildCheckpoint.init(&probe, PendingInputProbe.pending);
    try std.testing.expectError(
        error.InputPending,
        measureProjectionInterruptible(alloc, &projection, null, 80, &checkpoint),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.polls);

    const completed = try measureProjectionInterruptible(alloc, &projection, null, 80, null);
    try std.testing.expect(completed.total_rows > 0);
}

test "interruptible stored result measurement preserves projection state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const content = try alloc.alloc(u8, 16 * 1024);
    defer alloc.free(content);
    @memset(content, 'x');
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "interruptible-result",
        "read_file",
        content,
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = "preview",
    } });

    var probe = PendingInputProbe{};
    var checkpoint = BuildCheckpoint.init(&probe, PendingInputProbe.pending);
    try std.testing.expectError(
        error.InputPending,
        measureProjectionInterruptible(alloc, &projection, &capability, 80, &checkpoint),
    );
    const stored = projection.segments.items[0].stored_result;
    try std.testing.expectEqual(StoredResultKind.tool_result, stored.kind);
    try std.testing.expectEqualStrings(handle, stored.handle);
    try std.testing.expect(stored.fallback_handle == null);
    try std.testing.expect(!stored.unavailable);

    var baseline = Projection{ .styles = .{} };
    defer baseline.deinit(alloc);
    try baseline.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = "preview",
    } });
    const retry_measurement = try measureProjection(alloc, &projection, &capability, 80);
    const baseline_measurement = try measureProjection(alloc, &baseline, &capability, 80);
    try std.testing.expectEqual(baseline_measurement.total_rows, retry_measurement.total_rows);
    const retry = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(retry_measurement.total_rows),
        0,
    );
    defer alloc.free(retry);
    const uninterrupted = try renderProjectionViewportSource(
        alloc,
        &baseline,
        &capability,
        80,
        @intCast(baseline_measurement.total_rows),
        0,
    );
    defer alloc.free(uninterrupted);
    try std.testing.expectEqualStrings(uninterrupted, retry);
}

test "interruptible full projection rendering retries after cancellation" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    const bytes = try alloc.alloc(u8, 16 * 1024);
    @memset(bytes, 'x');
    try projection.segments.append(alloc, .{ .static = bytes });
    _ = try measureProjection(alloc, &projection, null, 80);

    var probe = PendingInputProbe{};
    var checkpoint = BuildCheckpoint.init(&probe, PendingInputProbe.pending);
    try std.testing.expectError(
        error.InputPending,
        renderProjectionViewportSourceWithSelection(
            alloc,
            &projection,
            null,
            80,
            std.math.maxInt(u16),
            .{ .fixed_offset = 0 },
            &checkpoint,
            std.math.maxInt(usize),
        ),
    );

    const completed = try renderProjectionViewportSource(
        alloc,
        &projection,
        null,
        80,
        std.math.maxInt(u16),
        0,
    );
    defer alloc.free(completed);
    try std.testing.expect(completed.len > 0);
}

pub const FullDiffResolver = struct {
    context: *anyopaque,
    full_for_marker: *const fn (context: *anyopaque, id: u32) ?[]const u8,
    has_full_for_lifecycle: *const fn (context: *anyopaque, lifecycle_id: types.ToolLifecycleId) bool,
};

pub const ViewportOffsetSelector = struct {
    context: *anyopaque,
    select_offset: *const fn (context: *anyopaque, measurement: ProjectionMeasurement, visible_rows: u16) u32,
};

const StoredResultKind = enum {
    tool_result,
    command_result,
    command_artifact,
    command_replay,
};

const StoredResult = struct {
    kind: StoredResultKind = .tool_result,
    handle: []const u8,
    preview: ?[]const u8,
    framed_bytes: usize = 0,
    fallback_handle: ?[]const u8 = null,
    fallback_artifact_handle: ?[]const u8 = null,
    retained_command_fallback: ?[]u8 = null,
    start_record: usize = 0,
    end_record: ?usize = null,
    unavailable: bool = false,
    required_replay_unavailable: bool = false,
    line_prefix: []const u8 = "  ",

    fn deinit(self: StoredResult, alloc: Allocator) void {
        if (self.retained_command_fallback) |bytes| alloc.free(bytes);
    }
};

const CommandArtifactReader = struct {
    file: session_child_store.ManagedFile,
    size: usize,

    fn deinit(self: *CommandArtifactReader) void {
        self.file.deinit();
        self.* = undefined;
    }
};

const StoredResultReader = union(StoredResultKind) {
    tool_result: result_store.ResultReader,
    command_result: result_store.ResultReader,
    command_artifact: CommandArtifactReader,
    command_replay: command_replay_store.Reader,

    fn deinit(self: *StoredResultReader) void {
        switch (self.*) {
            .tool_result => |*reader| reader.deinit(),
            .command_result => |*reader| reader.deinit(),
            .command_artifact => |*reader| reader.deinit(),
            .command_replay => |*reader| reader.deinit(),
        }
        self.* = undefined;
    }

    fn size(self: *const StoredResultReader) usize {
        return switch (self.*) {
            .tool_result => |reader| reader.size,
            .command_result => |reader| reader.size,
            .command_artifact => |reader| reader.size,
            .command_replay => |reader| reader.size,
        };
    }

    fn readPage(
        self: *StoredResultReader,
        alloc: Allocator,
        offset: usize,
        max_bytes: usize,
    ) ![]u8 {
        return switch (self.*) {
            .tool_result => |*reader| reader.readPage(alloc, offset, max_bytes),
            .command_result => |*reader| reader.readPage(alloc, offset, max_bytes),
            .command_artifact => |*reader| reader.file.readRange(
                alloc,
                @intCast(offset),
                @min(max_bytes, reader.size -| offset),
            ),
            .command_replay => error.InvalidReplayPageRead,
        };
    }
};

const Segment = union(enum) {
    static: []u8,
    stored_result: StoredResult,
};

const ProjectionCheckpoint = struct {
    row: u32,
    col: u16,
    row_has_bytes: bool,
};

const ProjectionWindowStart = struct {
    segment_index: usize,
    checkpoint: ProjectionCheckpoint,
};

/// A width-rendered Ctrl-O document. Static transcript bytes and retained
/// command fallbacks are owned by the projection; stored-result handles remain
/// borrowed and are read through the session capability only on demand.
pub const Projection = struct {
    segments: std.ArrayList(Segment) = .empty,
    anchor_segment_index: ?usize = null,
    item_boundaries: std.ArrayList(ItemBoundary) = .empty,
    measured_item_rows: std.ArrayList(transcript_presentation.ItemRow) = .empty,
    measured_segment_checkpoints: std.ArrayList(ProjectionCheckpoint) = .empty,
    measurement_cols: ?u16 = null,
    measured_total_rows: u32 = 0,
    measured_anchor_row: ?u32 = null,
    styles: transcript_blocks.Styles,

    fn invalidateMeasurement(self: *Projection) void {
        self.measurement_cols = null;
        self.measured_total_rows = 0;
        self.measured_anchor_row = null;
    }

    fn windowStart(self: *const Projection, cols: u16, start_row: u32) ProjectionWindowStart {
        const origin = ProjectionCheckpoint{
            .row = 0,
            .col = 1,
            .row_has_bytes = false,
        };
        if (self.measurement_cols != cols or
            self.measured_segment_checkpoints.items.len != self.segments.items.len)
        {
            return .{ .segment_index = 0, .checkpoint = origin };
        }

        var selected = ProjectionWindowStart{ .segment_index = 0, .checkpoint = origin };
        for (self.measured_segment_checkpoints.items, 0..) |checkpoint, index| {
            if (checkpoint.row > start_row) break;
            const starts_inside_visible_row = checkpoint.row == start_row and
                (checkpoint.row_has_bytes or checkpoint.col != 1);
            if (starts_inside_visible_row) continue;
            selected = .{ .segment_index = index, .checkpoint = checkpoint };
        }
        return selected;
    }

    pub fn deinit(self: *Projection, alloc: Allocator) void {
        for (self.segments.items) |segment| switch (segment) {
            .static => |bytes| alloc.free(bytes),
            .stored_result => |stored| stored.deinit(alloc),
        };
        self.segments.deinit(alloc);
        self.item_boundaries.deinit(alloc);
        self.measured_item_rows.deinit(alloc);
        self.measured_segment_checkpoints.deinit(alloc);
        self.* = undefined;
    }
};

const ItemBoundary = struct {
    entry_id: u32,
    segment_index: usize,
};

test "projection applies actions by transcript position after lifecycle reposition" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{ .id = 2, .bytes = "second\n" } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "third\n" } },
        .{ .raw_bytes = .{ .id = 1, .bytes = "old status\n" } },
    };
    const actions = [_]transcript_blocks.EntryRenderAction{
        .keep,
        .keep,
        .{ .override = .{ .kind = .tool_status, .bytes = "new status\n" } },
    };
    var projection = try buildProjectionWithEntryActionsInterruptible(
        alloc,
        &entries,
        &.{},
        &.{},
        .{},
        80,
        null,
        null,
        &actions,
        null,
    );
    defer projection.deinit(alloc);
    const rendered = try renderProjectionViewportSource(alloc, &projection, null, 80, 10, 0);
    defer alloc.free(rendered);

    try std.testing.expect(std.mem.find(u8, rendered, "new status") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "old status") == null);
}

pub const ProjectionMeasurement = struct {
    total_rows: u32,
    anchor_row: ?u32,
    item_rows: []const transcript_presentation.ItemRow = &.{},
};

/// Owns the in-progress static writer while composing a Projection, so every
/// build-time segment boundary transfers through one place.
const ProjectionBuilder = struct {
    alloc: Allocator,
    projection: Projection,
    projection_cols: u16,
    out: std.Io.Writer.Allocating,

    fn init(
        alloc: Allocator,
        projection_styles: transcript_blocks.Styles,
        projection_cols: u16,
    ) ProjectionBuilder {
        return .{
            .alloc = alloc,
            .projection = .{ .styles = projection_styles },
            .projection_cols = projection_cols,
            .out = .init(alloc),
        };
    }

    fn deinit(self: *ProjectionBuilder) void {
        self.out.deinit();
        self.projection.deinit(self.alloc);
        self.* = undefined;
    }

    fn staticOut(self: *ProjectionBuilder) *std.Io.Writer.Allocating {
        return &self.out;
    }

    fn styles(self: *const ProjectionBuilder) transcript_blocks.Styles {
        return self.projection.styles;
    }

    fn markAnchor(self: *ProjectionBuilder) !void {
        try self.flushStatic();
        self.projection.anchor_segment_index = self.projection.segments.items.len;
    }

    fn markEntry(self: *ProjectionBuilder, entry_id: u32) !void {
        try self.flushStatic();
        try self.projection.item_boundaries.append(self.alloc, .{
            .entry_id = entry_id,
            .segment_index = self.projection.segments.items.len,
        });
    }

    fn appendStoredResult(self: *ProjectionBuilder, stored: StoredResult) !void {
        errdefer stored.deinit(self.alloc);
        try self.flushStatic();
        try self.projection.segments.append(self.alloc, .{ .stored_result = stored });
    }

    fn finish(self: *ProjectionBuilder) !Projection {
        try self.flushStatic();
        try self.projection.measured_item_rows.ensureTotalCapacity(
            self.alloc,
            self.projection.item_boundaries.items.len,
        );
        try self.projection.measured_segment_checkpoints.ensureTotalCapacity(
            self.alloc,
            self.projection.segments.items.len,
        );
        self.out.deinit();
        const projection = self.projection;
        self.* = undefined;
        return projection;
    }

    fn flushStatic(self: *ProjectionBuilder) !void {
        if (self.out.written().len == 0) return;
        const bytes = try self.out.toOwnedSlice();
        errdefer self.alloc.free(bytes);
        try self.projection.segments.append(self.alloc, .{ .static = bytes });
        self.out = .init(self.alloc);
    }
};

test "full projection replaces a compact command entry with the retained command block" {
    const alloc = std.testing.allocator;

    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .created_at_ms = 0, .bytes = @constCast("● Ran command\n"), .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .created_at_ms = 0, .bytes = @constCast("│ first\n│ ... 2 command lines folded\n"), .class = .command_output } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 2 }};
    defer blocks[0].deinit(alloc);
    try blocks[0].lines.append(alloc, .{ .stream = .stdout, .text = try alloc.dupe(u8, "first\n") });
    try blocks[0].lines.append(alloc, .{ .stream = .stdout, .text = try alloc.dupe(u8, "second\n") });
    try blocks[0].lines.append(alloc, .{ .stream = .stderr, .text = try alloc.dupe(u8, "third\n") });
    blocks[0].total_lines = blocks[0].lines.items.len;
    blocks[0].retained_text_bytes = "first\n".len + "second\n".len + "third\n".len;

    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_entry_id = 2,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        1,
    );
    defer projection.deinit(alloc);
    const rendered = try renderProjectionViewportSource(alloc, &projection, null, 80, 12, 0);
    defer alloc.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "│ first") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│ second") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│ third") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "folded") == null);
    try std.testing.expectEqual(@as(?u32, 0), (try measureProjection(alloc, &projection, null, 80)).anchor_row);
}

test "full projection wraps retained command records with a gutter on every physical row" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("│ compact\n"),
        .class = .command_output,
    } }};
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 1 }};
    defer blocks[0].deinit(alloc);
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "paragraph words"),
    });
    blocks[0].total_lines = 1;
    blocks[0].retained_text_bytes = "paragraph words".len;

    var projection = try buildProjection(
        alloc,
        &entries,
        &.{},
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        16,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 16, 8, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "│ paragraph\n│ words\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "│ paragraph words") == null);
}

test "full projection keeps noncontiguous retained command records at source entries" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .subagent_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact first\n"),
            .class = .command_output,
        } },
        .{ .raw_bytes = .{
            .id = 3,
            .created_at_ms = 0,
            .bytes = @constCast("UNRELATED_NOTICE\n"),
            .class = .subagent_status,
        } },
        .{ .raw_bytes = .{
            .id = 4,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact second\n"),
            .class = .command_output,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 2 }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.appendSlice(alloc, &.{ 2, 4 });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "FULL_FIRST"),
        .record_ordinal = 0,
        .entry_id = 2,
        .terminated = true,
    });
    try blocks[0].lines.append(alloc, .{
        .stream = .stderr,
        .text = try alloc.dupe(u8, "FULL_SECOND"),
        .record_ordinal = 1,
        .entry_id = 4,
        .terminated = true,
    });
    blocks[0].total_lines = 2;
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(u8, "exit_code=0\n<stdout>\nSTORED_DUPLICATE\n</stdout>\n"),
        .command_output_entry_id = 2,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 20, 0);
    defer alloc.free(source);
    const first = std.mem.indexOf(u8, source, "FULL_FIRST") orelse return error.TestExpectedFirstRecord;
    const notice = std.mem.indexOf(u8, source, "UNRELATED_NOTICE") orelse return error.TestExpectedNotice;
    const second = std.mem.indexOf(u8, source, "FULL_SECOND") orelse return error.TestExpectedSecondRecord;
    try std.testing.expect(first < notice and notice < second);
    try std.testing.expect(std.mem.indexOf(u8, source, "STORED_DUPLICATE") == null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "  result"));
}

test "full projection matches file details to full diffs by marker and lifecycle" {
    const alloc = std.testing.allocator;
    const compact_first = try @import("../core/output/diff.zig").wrapWithMarkers(
        alloc,
        101,
        "\x1b[38;5;252m  │ \x1b[38;5;203m1 -\x1b[38;5;252m ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnCOMPACT_FIRST_TAIL\x1b[0m\n",
    );
    defer alloc.free(compact_first);
    const compact_second = try @import("../core/output/diff.zig").wrapWithMarkers(
        alloc,
        102,
        "\x1b[38;5;252m  │ \x1b[38;5;77m1 +\x1b[38;5;252m ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnCOMPACT_SECOND_TAIL\x1b[0m\n",
    );
    defer alloc.free(compact_second);
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .created_at_ms = 0, .bytes = @constCast("● Write first.txt\n"), .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .created_at_ms = 0, .bytes = compact_first, .class = .diff_block } },
        .{ .raw_bytes = .{ .id = 3, .created_at_ms = 0, .bytes = @constCast("● Write second.txt\n"), .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .created_at_ms = 0, .bytes = compact_second, .class = .diff_block } },
    };
    var details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = try alloc.dupe(u8, "write_file"),
            .arguments_json = try alloc.dupe(u8, "{\"content\":\"RAW_FIRST\\\\n\"}"),
            .lifecycle_id = .{ .turn_id = 41, .call_id = try alloc.dupe(u8, "first") },
        },
        .{
            .entry_id = 3,
            .tool_name = try alloc.dupe(u8, "write_file"),
            .arguments_json = try alloc.dupe(u8, "{\"content\":\"RAW_SECOND\\\\n\"}"),
            .lifecycle_id = .{ .turn_id = 41, .call_id = try alloc.dupe(u8, "second") },
        },
    };
    defer for (&details) |*detail| detail.deinit(alloc);

    const Resolver = struct {
        const full_first = "\x1b[38;5;252m  │ \x1b[38;5;203m1 -\x1b[38;5;252m ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnFULL_FIRST_TAIL\x1b[0m\n";

        fn fullForMarker(_: *anyopaque, id: u32) ?[]const u8 {
            return if (id == 101) full_first else null;
        }

        fn hasFullForLifecycle(_: *anyopaque, lifecycle_id: types.ToolLifecycleId) bool {
            return lifecycle_id.turn_id == 41 and std.mem.eql(u8, lifecycle_id.call_id, "first");
        }
    };
    var resolver_context: u8 = 0;
    const styles: transcript_blocks.Styles = .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" };
    var projection = try buildProjectionWithResolver(
        alloc,
        &entries,
        &details,
        &.{},
        styles,
        48,
        null,
        .{
            .context = &resolver_context,
            .full_for_marker = Resolver.fullForMarker,
            .has_full_for_lifecycle = Resolver.hasFullForLifecycle,
        },
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, null, 48);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 48, @intCast(measurement.total_rows), 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "  │     FULL_FIRST_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "COMPACT_FIRST_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RAW_FIRST") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "  │     COMPACT_SECOND_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RAW_SECOND") != null);

    var wide_projection = try buildProjectionWithResolver(
        alloc,
        &entries,
        &details,
        &.{},
        styles,
        120,
        null,
        .{
            .context = &resolver_context,
            .full_for_marker = Resolver.fullForMarker,
            .has_full_for_lifecycle = Resolver.hasFullForLifecycle,
        },
    );
    defer wide_projection.deinit(alloc);
    const wide_measurement = try measureProjection(alloc, &wide_projection, null, 120);
    const wide_source = try renderProjectionViewportSource(
        alloc,
        &wide_projection,
        null,
        120,
        @intCast(wide_measurement.total_rows),
        0,
    );
    defer alloc.free(wide_source);

    try std.testing.expect(std.mem.indexOf(u8, wide_source, "FULL_FIRST_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_source, "COMPACT_SECOND_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_source, "  │     ") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide_source, "RAW_SECOND") != null);
}

test "full projection preserves inline block gaps around expanded tool detail" {
    const alloc = std.testing.allocator;
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .user_turn = .{ .id = 1, .turn = .{
            .text = try alloc.dupe(u8, "Read the config."),
            .images = try alloc.alloc(types.ImageAttachment, 0),
        } } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .raw_bytes = .{
            .id = 3,
            .bytes = try alloc.dupe(u8, "● Read config\n"),
            .class = .subagent_status,
        } },
        .{ .assistant_turn = .{ .id = 4, .segments = .{} } },
    };
    defer for (&entries) |*entry| entry.deinit(alloc);
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "Summary before tool");
    try entries[3].assistant_turn.segments.text.appendSlice(alloc, "Summary after tool");

    var details = [_]ToolDetailRecord{.{
        .entry_id = 3,
        .tool_name = try alloc.dupe(u8, "read_file"),
        .arguments_json = try alloc.dupe(u8, "{\"path\":\"config\"}"),
        .result = try alloc.dupe(u8, "value"),
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 20, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "\n\n  Summary before tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "  value\n\n  Summary after tool") != null);
}

test "full tool detail keeps wrapped rails primary while output stays secondary" {
    const alloc = std.testing.allocator;
    const styles = transcript_blocks.Styles{
        .reset_style = "<reset>",
        .dim_style = "<dim>",
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try appendTerminalSafeToolOutput(
        &out.writer,
        alloc,
        styles,
        "alpha beta gamma delta",
        16,
    );

    try std.testing.expectEqualStrings(
        "<reset>│<dim>  alpha beta<reset>\n" ++
            "<reset>│<dim>  gamma delta<reset>\n",
        out.written(),
    );
}

test "full projection retains consecutive in-memory tool details" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .created_at_ms = 0, .bytes = @constCast("● Listed .\n"), .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .created_at_ms = 0, .bytes = @constCast("● Read README.md\n"), .class = .tool_status } },
    };
    var details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = try alloc.dupe(u8, "glob_files"),
            .arguments_json = try alloc.dupe(u8, "{\"path\":\".\"}"),
            .result = try alloc.dupe(u8, "LIST_FULL_DETAIL_MARKER"),
        },
        .{
            .entry_id = 2,
            .tool_name = try alloc.dupe(u8, "read_file"),
            .arguments_json = try alloc.dupe(u8, "{\"path\":\"README.md\"}"),
            .result = try alloc.dupe(u8, "READ_FULL_DETAIL_MARKER"),
        },
    };
    defer for (&details) |*detail| detail.deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 24, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "LIST_FULL_DETAIL_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "READ_FULL_DETAIL_MARKER") != null);
}

test "full projection applies modern width clipping to a tool status" {
    const alloc = std.testing.allocator;
    var entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .bytes = try alloc.dupe(u8, "● Searched a deliberately long query that reaches FULL_STATUS_TAIL\n"),
        .class = .tool_status,
    } }};
    defer entries[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &.{},
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        24,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 24, 8, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "FULL_STATUS_TAIL") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "…") != null);
}

test "full projection preserves semantic arguments clipped from a tool heading" {
    const alloc = std.testing.allocator;
    const command = "printf a deliberately long command with FULL_ARGUMENT_TAIL";
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .bytes = @constCast("● Ran printf a deliberately long command with FULL_ARGUMENT_TAIL\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "terminal"),
        .captured_command = true,
        .arguments_json = try std.fmt.allocPrint(
            alloc,
            "{{\"action\":\"exec\",\"command\":\"{s}\",\"profile\":\"clean\"}}",
            .{command},
        ),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        24,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, null, 24);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        null,
        24,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "command: printf") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "FULL_ARGUMENT_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "action: exec") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "profile: clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "{\"command\"") == null);
}

test "stored result projection streams terminal-safe head middle and tail pages" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "HEAD-SENTINEL ");
    try content.appendNTimes(alloc, 'x', result_store.full_read_chunk_bytes - 16);
    try content.appendSlice(alloc, "\x1b[31m\xf0\x9f\x98\x80");
    const half_result_bytes = 4 * 1024 * 1024;
    try content.appendNTimes(alloc, 'x', half_result_bytes - content.items.len);
    try content.appendSlice(alloc, "MIDDLE-SENTINEL");
    try content.appendNTimes(alloc, 'x', half_result_bytes);
    try content.appendSlice(alloc, "TAIL-SENTINEL");
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "paged-detail",
        "read_file",
        content.items,
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "before\n") });
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = "preview",
    } });
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "after\n") });

    const measurement = try measureProjection(alloc, &projection, &capability, 24);
    try std.testing.expect(measurement.total_rows > 3);

    var bounded_memory: [512 * 1024]u8 = undefined;
    var bounded_alloc = std.heap.FixedBufferAllocator.init(&bounded_memory);
    const bounded_measurement = try measureProjection(
        bounded_alloc.allocator(),
        &projection,
        &capability,
        24,
    );
    try std.testing.expectEqual(measurement.total_rows, bounded_measurement.total_rows);

    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        24,
        3,
        measurement.total_rows - 3,
    );
    defer alloc.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, tail, "TAIL-SENTINEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "after") != null);

    // Every physical row reserves the two-cell result prefix. Escaping ESC
    // adds three cells while the four-byte emoji occupies two, so the marker
    // begins one content cell past its raw byte offset.
    const middle_marker_row = @as(u32, 1) +
        @as(u32, @intCast((half_result_bytes + 1) / (24 - 2)));
    const middle = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        24,
        3,
        middle_marker_row,
    );
    defer alloc.free(middle);
    try std.testing.expect(std.mem.indexOf(u8, middle, "MIDDL") != null);
    try std.testing.expect(std.mem.indexOf(u8, middle, "E-SENTINEL") != null);

    const head = try renderProjectionViewportSource(alloc, &projection, &capability, 24, 3, 0);
    defer alloc.free(head);
    try std.testing.expect(std.mem.indexOf(u8, head, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "HEAD-SENTINEL") != null);
}

test "stored Unicode result remains pageable at the minimum projection width" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.appendSlice(alloc, "MIN_WIDTH_HEAD_");
    for (0..8_192) |_| try content.appendSlice(alloc, "👩‍💻界é");
    try content.appendSlice(alloc, "_MIN_WIDTH_TAIL");
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "minimum-width-unicode",
        "read_file",
        content.items,
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = null,
        .line_prefix = "│  ",
    } });

    var bounded_memory: [512 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&bounded_memory);
    const measurement = try measureProjection(
        bounded.allocator(),
        &projection,
        &capability,
        1,
    );
    try std.testing.expect(measurement.total_rows > 8_192);

    const head = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        1,
        32,
        0,
    );
    defer alloc.free(head);
    try std.testing.expect(std.unicode.utf8ValidateSlice(head));
    try std.testing.expect(std.mem.indexOf(u8, head, "MIN_WIDTH_HEAD") != null);

    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        1,
        32,
        measurement.total_rows -| 32,
    );
    defer alloc.free(tail);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail));
    try std.testing.expect(std.mem.indexOf(u8, tail, "MIN_WIDTH_TAIL") != null);
}

test "stored result projection preserves line breaks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "multiline-detail",
        "read_file",
        "<path>README.md</path>\n<content>\nFIRST_RESULT_LINE\nSECOND_RESULT_LINE\nTHIRD_RESULT_LINE\n</content>",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = null,
    } });

    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    try std.testing.expectEqual(@as(u32, 3), measurement.total_rows);

    const source = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 3, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "FIRST_RESULT_LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "SECOND_RESULT_LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "THIRD_RESULT_LINE") != null);
}

test "stored tool result repeats its rail on every physical wrap row" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "wrapped-detail",
        "grep_files",
        "alpha beta gamma delta epsilon zeta",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = null,
        .line_prefix = "│  ",
    } });

    const measurement = try measureProjection(alloc, &projection, &capability, 16);
    try std.testing.expect(measurement.total_rows > 1);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        16,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(source);

    try std.testing.expectEqual(
        @as(usize, measurement.total_rows),
        std.mem.count(u8, source, "│"),
    );
}

test "projection measurement cache is reused at one width and recomputed after resize" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{} };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{
        .static = try alloc.dupe(u8, "12345678901234567890\nsecond\n"),
    });

    const narrow = try measureProjection(alloc, &projection, null, 10);
    try std.testing.expectEqual(@as(?u16, 10), projection.measurement_cols);
    const cached = try measureProjection(alloc, &projection, null, 10);
    try std.testing.expectEqual(narrow.total_rows, cached.total_rows);
    try std.testing.expectEqual(@as(?u16, 10), projection.measurement_cols);

    const wide = try measureProjection(alloc, &projection, null, 20);
    try std.testing.expect(wide.total_rows < narrow.total_rows);
    try std.testing.expectEqual(@as(?u16, 20), projection.measurement_cols);
}

test "measured segment checkpoints preserve viewport bytes from a full walk" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    for ([_][]const u8{
        "row-0\nrow-1\nrow-2\n",
        "\x1b[31mmid",
        "dle\x1b[0m\nrow-4 wide \xe7\x95\x8c\n",
        "row-5\nrow-6\n",
    }) |bytes| {
        try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, bytes) });
    }
    try projection.measured_segment_checkpoints.ensureTotalCapacity(
        alloc,
        projection.segments.items.len,
    );

    for (0..7) |offset| {
        _ = try measureProjection(alloc, &projection, null, 12);
        const accelerated = try renderProjectionViewportSource(
            alloc,
            &projection,
            null,
            12,
            2,
            @intCast(offset),
        );
        defer alloc.free(accelerated);

        projection.invalidateMeasurement();
        const full_walk = try renderProjectionViewportSource(
            alloc,
            &projection,
            null,
            12,
            2,
            @intCast(offset),
        );
        defer alloc.free(full_walk);
        try std.testing.expectEqualStrings(full_walk, accelerated);
    }

    _ = try measureProjection(alloc, &projection, null, 12);
    try std.testing.expect(projection.windowStart(12, 4).segment_index > 0);
}

test "viewport selector receives the same-walk measurement and its offset picks the window" {
    const alloc = std.testing.allocator;

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "one\ntwo\n") });
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "three\nfour\n") });
    projection.anchor_segment_index = 1;

    const Recorder = struct {
        calls: u32 = 0,
        measurement: ?ProjectionMeasurement = null,
        visible_rows: ?u16 = null,

        fn selectOffset(context: *anyopaque, measurement: ProjectionMeasurement, visible_rows: u16) u32 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.measurement = measurement;
            self.visible_rows = visible_rows;
            return measurement.anchor_row.?;
        }
    };
    var recorder = Recorder{};

    const selected = try renderProjectionViewportSourceWithSelector(alloc, &projection, null, 80, 2, .{
        .context = &recorder,
        .select_offset = Recorder.selectOffset,
    });
    defer alloc.free(selected);

    try std.testing.expectEqual(@as(u32, 1), recorder.calls);
    try std.testing.expectEqual(@as(u32, 4), recorder.measurement.?.total_rows);
    try std.testing.expectEqual(@as(?u32, 2), recorder.measurement.?.anchor_row);
    try std.testing.expectEqual(@as(?u16, 2), recorder.visible_rows);

    const direct = try renderProjectionViewportSource(alloc, &projection, null, 80, 2, 2);
    defer alloc.free(direct);
    try std.testing.expectEqualStrings(direct, selected);
}

test "viewport selector sees the degraded measurement when a stored segment is unavailable" {
    const alloc = std.testing.allocator;

    const dim = "\x1b[38;5;245m";
    const reset = "\x1b[39m";

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = reset,
        .dim_style = dim,
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "head\n") });
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = "missing-handle",
        .preview = "preview-line",
        .line_prefix = "│  ",
    } });

    const Recorder = struct {
        calls: u32 = 0,
        measurement: ?ProjectionMeasurement = null,
        visible_rows: ?u16 = null,

        fn selectOffset(context: *anyopaque, measurement: ProjectionMeasurement, visible_rows: u16) u32 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.measurement = measurement;
            self.visible_rows = visible_rows;
            return 0;
        }
    };
    var recorder = Recorder{};

    const selected = try renderProjectionViewportSourceWithSelector(alloc, &projection, null, 80, 8, .{
        .context = &recorder,
        .select_offset = Recorder.selectOffset,
    });
    defer alloc.free(selected);

    // The unreadable segment degrades during the measure walk, so the selector
    // must be handed the post-degrade totals, not the pre-degrade document.
    const post_degrade = try measureProjection(alloc, &projection, null, 80);
    try std.testing.expectEqual(@as(u32, 1), recorder.calls);
    try std.testing.expectEqual(post_degrade.total_rows, recorder.measurement.?.total_rows);
    try std.testing.expectEqual(@as(?u16, 8), recorder.visible_rows);
    try std.testing.expect(std.mem.indexOf(u8, selected, "preview-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "Full saved result unavailable.") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, dim ++ "│") == null);
    try std.testing.expect(std.mem.indexOf(u8, selected, reset ++ "│" ++ dim ++ "  preview-line" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, reset ++ "│" ++ dim ++ "  Full saved result unavailable." ++ reset) != null);
}

test "a window walk degrade re-selects the offset in the same frame" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "degrade-detail",
        "read_file",
        "STORED_LINE_ONE\nSTORED_LINE_TWO\nSTORED_LINE_THREE\n",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "head\n") });
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = "stored-preview",
    } });

    const Saboteur = struct {
        calls: u32 = 0,
        last_total_rows: ?u32 = null,
        visible_rows: ?u16 = null,
        capability: *session_child_store.SessionChildCapability,
        handle: []const u8,

        fn selectOffset(context: *anyopaque, measurement: ProjectionMeasurement, visible_rows: u16) u32 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.last_total_rows = measurement.total_rows;
            self.visible_rows = visible_rows;
            if (self.calls == 1) result_store.deleteManaged(self.capability, self.handle) catch {};
            return 0;
        }
    };
    var saboteur = Saboteur{ .capability = &capability, .handle = handle };

    const selected = try renderProjectionViewportSourceWithSelector(alloc, &projection, &capability, 80, 8, .{
        .context = &saboteur,
        .select_offset = Saboteur.selectOffset,
    });
    defer alloc.free(selected);

    // Deleting the stored result between the measure and window walks forces
    // the window walk to degrade; the pipeline must re-measure and re-select
    // rather than emit a window at the stale offset.
    try std.testing.expectEqual(@as(u32, 2), saboteur.calls);
    try std.testing.expectEqual(@as(?u16, 8), saboteur.visible_rows);
    const post_degrade = try measureProjection(alloc, &projection, &capability, 80);
    try std.testing.expectEqual(post_degrade.total_rows, saboteur.last_total_rows.?);
    try std.testing.expect(std.mem.indexOf(u8, selected, "stored-preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "Full saved result unavailable.") != null);
}

test "full projection prefers a persisted command artifact over the compact tool sidecar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "commands");
    const command_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "commands");
    defer alloc.free(command_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        command_dir,
        .command_artifacts,
        .writable,
    );
    defer capability.deinit();

    const artifact_name = "fx-command-full-transcript.log";
    var artifact = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        artifact_name,
    );
    defer artifact.deinit();
    try artifact.writeAll(
        "COMMAND_ARTIFACT_HEAD\n" ++
            "<stdout>\n" ++
            "LITERAL_ARTIFACT_ENVELOPE\n" ++
            "</stdout>\n" ++
            "COMMAND_ARTIFACT_TAIL\n",
    );
    try artifact.sync();

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 2 }};
    defer blocks[0].deinit(alloc);
    const retained_duplicate = try alloc.dupe(u8, "RETAINED_COMMAND_DUPLICATE\n");
    try blocks[0].lines.append(alloc, .{ .stream = .stdout, .text = retained_duplicate });
    blocks[0].total_lines = 1;
    blocks[0].retained_text_bytes = retained_duplicate.len;
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(u8, "bounded sidecar preview"),
        .result_handle = try alloc.dupe(u8, "missing-compact-sidecar.txt"),
        .command_artifact_handle = try alloc.dupe(u8, artifact_name),
        .command_output_entry_id = 2,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        8,
        measurement.total_rows -| 8,
    );
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "COMMAND_ARTIFACT_HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "COMMAND_ARTIFACT_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<stdout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "LITERAL_ARTIFACT_ENVELOPE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "RETAINED_COMMAND_DUPLICATE") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Full saved result unavailable.") == null);

    const degraded_measurement = try measureProjection(alloc, &projection, null, 80);
    const degraded = try renderProjectionViewportSource(
        alloc,
        &projection,
        null,
        80,
        8,
        degraded_measurement.total_rows -| 8,
    );
    defer alloc.free(degraded);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "RETAINED_COMMAND_DUPLICATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "Full saved result unavailable.") != null);
}

test "stored command artifact appends records beyond the callback count once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "commands");
    const command_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "commands");
    defer alloc.free(command_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        command_dir,
        .command_artifacts,
        .writable,
    );
    defer capability.deinit();

    const artifact_name = "fx-command-late-tail.log";
    var artifact = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        artifact_name,
    );
    defer artifact.deinit();
    try artifact.writeAll("CALLBACK_0\nCALLBACK_1\nARTIFACT_LATE_TAIL\n");
    try artifact.sync();

    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .subagent_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact callback 0\n"),
            .class = .command_output,
        } },
        .{ .raw_bytes = .{
            .id = 3,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact callback 1\n"),
            .class = .command_output,
        } },
        .{ .raw_bytes = .{
            .id = 4,
            .created_at_ms = 0,
            .bytes = @constCast("FOLLOWING_STATIC_BLOCK\n"),
            .class = .tool_status,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .total_lines = 2,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.appendSlice(alloc, &.{ 2, 3 });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "CALLBACK_0"),
        .record_ordinal = 0,
        .entry_id = 2,
        .terminated = true,
    });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "CALLBACK_1"),
        .record_ordinal = 1,
        .entry_id = 3,
        .terminated = true,
    });
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_artifact_handle = try alloc.dupe(u8, artifact_name),
        .command_output_entry_id = 2,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(source);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "CALLBACK_0"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "CALLBACK_1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "ARTIFACT_LATE_TAIL"));
    const callback = std.mem.find(u8, source, "CALLBACK_1") orelse
        return error.TestExpectedCallbackRecord;
    const tail = std.mem.find(u8, source, "ARTIFACT_LATE_TAIL") orelse
        return error.TestExpectedArtifactTail;
    const following = std.mem.find(u8, source, "FOLLOWING_STATIC_BLOCK") orelse
        return error.TestExpectedFollowingBlock;
    try std.testing.expect(callback < tail and tail < following);
}

test "full projection prefers ordered replay and omits command envelopes and input" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    capture.appendAccepted(capture_alloc, .stdout, "A");
    capture.appendAccepted(capture_alloc, .stderr, "B\n");
    capture.appendAccepted(capture_alloc, .stdout, "\n");
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran printf replay\n"),
        .class = .tool_status,
    } }};
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 2 }};
    defer blocks[0].deinit(alloc);
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "RETAINED_DUPLICATE"),
    });
    blocks[0].total_lines = 1;
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .arguments_json = try alloc.dupe(u8, "{\"command\":\"printf replay\"}"),
        .result = try alloc.dupe(u8, "exit_code=0\n<stdout>\nWRONG_ENVELOPE\n</stdout>\n"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .command_process_presentation = .{ .exit_code = 7 },
        .outcome = .completed,
        .command_output_entry_id = 2,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(@min(measurement.total_rows, 20)),
        0,
    );
    defer alloc.free(source);

    const a_index = std.mem.indexOf(u8, source, "│ A") orelse return error.TestExpectedStdout;
    const b_index = std.mem.indexOf(u8, source, "│ B") orelse return error.TestExpectedStderr;
    try std.testing.expect(a_index < b_index);
    try std.testing.expect(std.mem.indexOf(u8, source, "RETAINED_DUPLICATE") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "WRONG_ENVELOPE") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<stdout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "  input") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "│ exit code 7"));
}

test "cancelled command detail keeps its semantic heading without raw arguments" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("■ Cancelled ./z.sh\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .arguments_json = try alloc.dupe(u8, "{\"command\":\"./z.sh\"}"),
        .outcome = .cancelled,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 8, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "Cancelled ./z.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "  input") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "{\"command\":\"./z.sh\"}") == null);
}

test "head-pruned command replay fills absolute prefix and suffix ranges once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    capture.appendAccepted(
        capture_alloc,
        .stdout,
        "LOST_HEAD\nSURVIVING_RECORD\nLOST_SUFFIX\n",
    );
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact survivor\n"),
            .class = .command_output,
        } },
        .{ .raw_bytes = .{
            .id = 3,
            .created_at_ms = 0,
            .bytes = @constCast("PRUNED_RANGE_NOTICE\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 4,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact lost suffix\n"),
            .class = .command_output,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .total_lines = 3,
        .retention_overflow = true,
        .overflow_line_index = 1,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.appendSlice(alloc, &.{ 2, 4 });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "SURVIVING_RECORD"),
        .record_ordinal = 1,
        .entry_id = 2,
        .terminated = true,
    });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "INCOMPLETE_SUFFIX_PREFIX"),
        .record_ordinal = 2,
        .entry_id = 4,
    });
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .command_output_entry_id = 2,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(source);
    const head = std.mem.indexOf(u8, source, "LOST_HEAD") orelse return error.TestExpectedLostHead;
    const survivor = std.mem.indexOf(u8, source, "SURVIVING_RECORD") orelse return error.TestExpectedSurvivor;
    const notice = std.mem.indexOf(u8, source, "PRUNED_RANGE_NOTICE") orelse return error.TestExpectedNotice;
    const suffix = std.mem.indexOf(u8, source, "LOST_SUFFIX") orelse return error.TestExpectedLostSuffix;
    try std.testing.expect(head < survivor and survivor < notice and notice < suffix);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "SURVIVING_RECORD"));
    try std.testing.expect(std.mem.indexOf(u8, source, "INCOMPLETE_SUFFIX_PREFIX") == null);
}

test "active overflow marker is replaced by the terminal source" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact stable\n"),
            .class = .command_output,
        } },
        .{ .raw_bytes = .{
            .id = 3,
            .created_at_ms = 0,
            .bytes = @constCast("ACTIVE_UNRELATED_NOTICE\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 4,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact unstable\n"),
            .class = .command_output,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .retention_overflow = true,
        .overflow_line_index = 1,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.appendSlice(alloc, &.{ 2, 4 });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "stable prefix"),
        .record_ordinal = 0,
        .entry_id = 2,
        .terminated = true,
    });
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "UNSTABLE_TRUNCATED_RECORD"),
        .record_ordinal = 1,
        .entry_id = 4,
    });
    blocks[0].total_lines = 2;
    var active_details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_entry_id = 2,
    }};
    defer active_details[0].deinit(alloc);

    var active = try buildProjection(
        alloc,
        &entries,
        &active_details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer active.deinit(alloc);
    const active_measurement = try measureProjection(alloc, &active, null, 80);
    const active_source = try renderProjectionViewportSource(
        alloc,
        &active,
        null,
        80,
        @intCast(active_measurement.total_rows),
        0,
    );
    defer alloc.free(active_source);
    try std.testing.expect(std.mem.indexOf(u8, active_source, "│ stable prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_source, "UNSTABLE_TRUNCATED_RECORD") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        active_source,
        "│ … full output available when command finishes",
    ) != null);
    const active_stable = std.mem.indexOf(u8, active_source, "│ stable prefix") orelse
        return error.TestExpectedStablePrefix;
    const active_notice = std.mem.indexOf(u8, active_source, "ACTIVE_UNRELATED_NOTICE") orelse
        return error.TestExpectedNotice;
    const active_marker = std.mem.indexOf(
        u8,
        active_source,
        "available when command finishes",
    ) orelse return error.TestExpectedActiveMarker;
    try std.testing.expect(active_stable < active_notice and active_notice < active_marker);

    active_details[0].outcome = .completed;
    active_details[0].result = try alloc.dupe(
        u8,
        "exit_code=0\n<stdout>\nstable prefix\nTERMINAL_COMPLETE_TAIL\n</stdout>\n",
    );
    var terminal = try buildProjection(
        alloc,
        &entries,
        &active_details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer terminal.deinit(alloc);
    const terminal_measurement = try measureProjection(alloc, &terminal, null, 80);
    const terminal_source = try renderProjectionViewportSource(
        alloc,
        &terminal,
        null,
        80,
        @intCast(terminal_measurement.total_rows),
        0,
    );
    defer alloc.free(terminal_source);
    try std.testing.expect(std.mem.indexOf(u8, terminal_source, "TERMINAL_COMPLETE_TAIL") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, terminal_source, "│ stable prefix"));
    const terminal_stable = std.mem.indexOf(u8, terminal_source, "│ stable prefix") orelse
        return error.TestExpectedStablePrefix;
    const terminal_notice = std.mem.indexOf(u8, terminal_source, "ACTIVE_UNRELATED_NOTICE") orelse
        return error.TestExpectedNotice;
    const terminal_tail = std.mem.indexOf(u8, terminal_source, "TERMINAL_COMPLETE_TAIL") orelse
        return error.TestExpectedTerminalTail;
    try std.testing.expect(terminal_stable < terminal_notice and terminal_notice < terminal_tail);
    try std.testing.expect(std.mem.indexOf(
        u8,
        terminal_source,
        "available when command finishes",
    ) == null);
}

test "corrupt required replay keeps a safe fallback and permanent marker" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    const handle = "fx-command-replay-corrupt.bin";
    var corrupt = try capability.createExclusiveFile(alloc, .command_artifacts, handle);
    defer corrupt.deinit();
    try corrupt.writeAll("not replay");
    try corrupt.sync();
    defer capability.delete(.command_artifacts, handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{ .entry_id = 2 }};
    defer blocks[0].deinit(alloc);
    try blocks[0].lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "SAFE_RETAINED_FALLBACK"),
    });
    blocks[0].total_lines = 1;
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = .{ .available = .{
            .handle = try alloc.dupe(u8, handle),
            .framed_bytes = "not replay".len,
        } },
        .outcome = .completed,
        .command_output_entry_id = 2,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 10, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "SAFE_RETAINED_FALLBACK") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "│ … full output unavailable") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "available when command finishes",
    ) == null);
}

test "unavailable replay extracts a grammar-valid inline command fallback" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(
            u8,
            "exit_code=0\n<stdout>\nINLINE_COMMAND_FALLBACK\n</stdout>\n",
        ),
        .command_output_replay = .unavailable,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 10, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "│ INLINE_COMMAND_FALLBACK") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "exit_code=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<stdout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "</stdout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Full saved result unavailable") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "│ … full output unavailable") != null);
}

test "unavailable replay terminal-safes an ambiguous inline command fallback" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(
            u8,
            "exit_code=0\n<stdout>\n\x1b[2JAMBIGUOUS_INLINE\n</stdout>\ntrailing bytes\n",
        ),
        .command_output_replay = .unavailable,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 12, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "AMBIGUOUS_INLINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\\x1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Full saved result unavailable") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "│ … full output unavailable") != null);
}

test "stored command detail keeps one normal gap before a following assistant" {
    const alloc = std.testing.allocator;
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .tool_status,
        } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "AFTER_COMMAND");
    defer entries[1].deinit(alloc);
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(
            u8,
            "exit_code=0\n<stdout>\nCOMMAND_RESULT\n</stdout>\n",
        ),
        .command_output_replay = .unavailable,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 20, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "│ … full output unavailable\n\n  AFTER_COMMAND",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "│ … full output unavailable\n\n\n  AFTER_COMMAND",
    ) == null);
}

test "deferred command replay keeps one normal gap before a following assistant" {
    const alloc = std.testing.allocator;
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact placeholder\n"),
            .class = .command_output,
        } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
    };
    try entries[2].assistant_turn.segments.text.appendSlice(alloc, "AFTER_DEFERRED_COMMAND");
    defer entries[2].deinit(alloc);
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .total_lines = 1,
        .retention_overflow = true,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].pruned_ranges.append(alloc, .{
        .anchor_entry_id = 2,
        .start_record = 0,
        .end_record = 1,
    });
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(u8, "exit_code=0\n<stdout>\nDEFERRED_RESULT\n</stdout>\n"),
        .command_output_replay = .unavailable,
        .command_output_entry_id = 2,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 20, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "│ … full output unavailable\n\n  AFTER_DEFERRED_COMMAND",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "│ … full output unavailable\n\n\n  AFTER_DEFERRED_COMMAND",
    ) == null);
}

test "legacy command result without replay does not claim permanent loss" {
    const alloc = std.testing.allocator;
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran legacy command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(u8, "preflight result \x1b[2JLEGACY_COMMAND_RESULT"),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 10, 0);
    defer alloc.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "LEGACY_COMMAND_RESULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\\x1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "full output unavailable") == null);
}

test "bounded command source rejects a truncated absolute record range" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const handle = "fx-command-artifact-short-range.bin";
    var artifact = try capability.createExclusiveFile(alloc, .command_artifacts, handle);
    defer artifact.deinit();
    try artifact.writeAll("ONLY_RECORD\n");
    try artifact.sync();
    defer capability.delete(.command_artifacts, handle) catch {};

    var walker = ProjectionRowWalker.initMeasure(80, null);
    try std.testing.expectError(
        error.CommandProjectionRecordMissing,
        appendCommandStoredResultContent(
            alloc,
            &walker,
            &capability,
            .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
            .{
                .kind = .command_artifact,
                .handle = handle,
                .preview = null,
                .start_record = 0,
                .end_record = 2,
            },
        ),
    );
}

test "oversized newline-free replay stays paged through measurement and tail rendering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    for (0..270) |_| capture.appendAccepted(capture_alloc, .stdout, &chunk);
    capture.appendAccepted(capture_alloc, .stdout, "OVERSIZED_REPLAY_TAIL");
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);

    var bounded_memory: [512 * 1024]u8 = undefined;
    var bounded_alloc = std.heap.FixedBufferAllocator.init(&bounded_memory);
    const measurement = try measureProjection(
        bounded_alloc.allocator(),
        &projection,
        &capability,
        80,
    );
    try std.testing.expect(measurement.total_rows > 10_000);
    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        3,
        measurement.total_rows -| 3,
    );
    defer alloc.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, tail, "OVERSIZED_REPLAY_TAIL") != null);
    var lines = std.mem.splitScalar(u8, tail, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "│ "));
    }
}

test "oversized replay keeps shared orphan wrapping in the paged record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    for (0..49) |_| capture.appendAccepted(capture_alloc, .stdout, &chunk);
    capture.appendAccepted(capture_alloc, .stdout, "xxxxxxxx aaa bbb ccc ddd\n");
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        14,
        null,
    );
    defer projection.deinit(alloc);

    const measurement = try measureProjection(alloc, &projection, &capability, 14);
    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        14,
        2,
        measurement.total_rows -| 2,
    );
    defer alloc.free(tail);
    var logical_record: std.ArrayList(u8) = .empty;
    defer logical_record.deinit(alloc);
    try logical_record.appendNTimes(alloc, 'x', 49 * chunk.len + 8);
    try logical_record.appendSlice(alloc, " aaa bbb ccc ddd");
    const expected = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
        alloc,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        logical_record.items,
        14,
    );
    defer alloc.free(expected);
    const final_separator = std.mem.findScalarLast(u8, expected[0 .. expected.len - 1], '\n') orelse
        return error.TestExpectedWrappedRecord;
    const prior_separator = std.mem.findScalarLast(u8, expected[0..final_separator], '\n') orelse
        return error.TestExpectedWrappedRecord;
    try std.testing.expectEqualStrings(expected[prior_separator + 1 ..], tail);
}

test "oversized zero width replay has bounded measurement and visible output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    capture.appendAccepted(capture_alloc, .stdout, "a");
    var combining_chunk: [4096]u8 = undefined;
    for (0..combining_chunk.len / 2) |index| {
        combining_chunk[index * 2] = 0xcc;
        combining_chunk[index * 2 + 1] = 0x81;
    }
    for (0..80) |_| capture.appendAccepted(capture_alloc, .stdout, &combining_chunk);
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);

    var bounded_memory: [128 * 1024]u8 = undefined;
    var bounded_alloc = std.heap.FixedBufferAllocator.init(&bounded_memory);
    const measurement = try measureProjection(
        bounded_alloc.allocator(),
        &projection,
        &capability,
        80,
    );
    try std.testing.expect(measurement.total_rows > 1000);
    const selected_row = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        1,
        measurement.total_rows -| 1,
    );
    defer alloc.free(selected_row);
    try std.testing.expect(selected_row.len < 512);
    const full = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(full);
    try std.testing.expectEqual(
        @as(usize, 80 * (combining_chunk.len / 2)),
        std.mem.count(u8, full, "\xcc\x81"),
    );
}

test "oversized interleaved replay preserves more than sixty four record ordinals" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 8, &capability);
    capture.appendAccepted(capture_alloc, .stdout, "\xc3");
    var stderr_record: std.ArrayList(u8) = .empty;
    defer stderr_record.deinit(alloc);
    for (0..100) |index| {
        stderr_record.clearRetainingCapacity();
        var prefix_buffer: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "E{d:0>3}-", .{index});
        try stderr_record.appendSlice(alloc, prefix);
        try stderr_record.appendNTimes(alloc, 'x', 2048);
        if (index == 99) try stderr_record.appendSlice(alloc, "-INTERLEAVED_TAIL");
        try stderr_record.append(alloc, '\n');
        capture.appendAccepted(capture_alloc, .stderr, stderr_record.items);
    }
    capture.appendAccepted(capture_alloc, .stdout, "\xa9 progress\rDONE\n");
    capture.appendAccepted(capture_alloc, .stdout, "\x1b[31m\x1b[0m");
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .command_output_replay = try types.dupeCommandOutputReplay(alloc, replay),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);

    var bounded_memory: [512 * 1024]u8 = undefined;
    var bounded_alloc = std.heap.FixedBufferAllocator.init(&bounded_memory);
    const measurement = try measureProjection(
        bounded_alloc.allocator(),
        &projection,
        &capability,
        80,
    );
    const head = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 8, 0);
    defer alloc.free(head);
    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        4,
        measurement.total_rows -| 4,
    );
    defer alloc.free(tail);
    const done_index = std.mem.indexOf(u8, head, "│ DONE") orelse return error.TestExpectedStdout;
    const first_stderr_index = std.mem.indexOf(u8, head, "│ E000-") orelse return error.TestExpectedStderr;
    try std.testing.expect(done_index < first_stderr_index);
    try std.testing.expect(std.mem.indexOf(u8, head, "progress") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "INTERLEAVED_TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "\x1b") == null);
}

test "opaque command sources back a stored artifact without a duplicate static row" {
    const alloc = std.testing.allocator;
    const marker = "│ OPAQUE_RETAINED_COMMAND\n";
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran command\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast(marker),
            .class = .command_output,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .total_lines = 1,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.append(alloc, 2);
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result = try alloc.dupe(u8, "bounded preview"),
        .command_artifact_handle = try alloc.dupe(u8, "missing-command.log"),
        .command_output_entry_id = 2,
    }};
    defer details[0].deinit(alloc);

    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);

    var stored_segments: usize = 0;
    for (projection.segments.items) |segment| switch (segment) {
        .static => |bytes| try std.testing.expect(std.mem.indexOf(u8, bytes, marker) == null),
        .stored_result => |stored| {
            stored_segments += 1;
            const retained = stored.retained_command_fallback orelse
                return error.TestExpectedRetainedCommandFallback;
            try std.testing.expectEqualStrings(marker, retained);
        },
    };
    try std.testing.expectEqual(@as(usize, 1), stored_segments);

    const degraded = try renderProjectionViewportSource(alloc, &projection, null, 80, 8, 0);
    defer alloc.free(degraded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, degraded, marker));
}

test "stored result projection yields a terminal-safe source window for the shared painter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "shared-source",
        "read_file",
        "<path>README.md</path>\n<content>\nFIRST_SOURCE_LINE\nSECOND_SOURCE_LINE\nTHIRD_SOURCE_LINE\n</content>",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "before\n") });
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = null,
    } });
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "after\n") });

    const source = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 5, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "FIRST_SOURCE_LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "SECOND_SOURCE_LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "THIRD_SOURCE_LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<path>") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\\x0a") == null);
}

test "stored tool result keeps every physical rail primary and body secondary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "styled-source",
        "read_file",
        "<path>README.md</path>\n<content>\nalpha beta gamma delta epsilon\nsecond row\n</content>",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    const reset = "\x1b[39m";
    const dim = "\x1b[38;5;245m";
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = reset,
        .dim_style = dim,
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .kind = .tool_result,
        .handle = handle,
        .preview = null,
        .line_prefix = "│  ",
    } });

    const measurement = try measureProjection(alloc, &projection, &capability, 16);
    const source = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        16,
        @intCast(measurement.total_rows),
        0,
    );
    defer alloc.free(source);

    try std.testing.expect(measurement.total_rows >= 3);
    const styled_rows = std.mem.count(u8, source, reset ++ "│" ++ dim);
    try std.testing.expectEqual(
        @as(usize, measurement.total_rows),
        styled_rows,
    );
    try std.testing.expect(std.mem.indexOf(u8, source, dim ++ "│") == null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        std.mem.trimEnd(u8, source, "\n"),
        reset,
    ));
}

test "missing stored result renders the retained preview and partial notice" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = "missing-result.txt",
        .preview = "retained preview",
    } });

    const source = try renderProjectionViewportSource(alloc, &projection, null, 80, 3, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "retained preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Full saved result unavailable.") != null);
}

test "missing command artifact uses the retained tool result sidecar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    const fallback_handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "command-fallback",
        "run_command",
        "exit_code=0\n<stdout>\nRETAINED_COMMAND_FALLBACK\n</stdout>\n",
    );
    defer alloc.free(fallback_handle);
    defer result_store.deleteManaged(&capability, fallback_handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .stored_result = .{
        .kind = .command_artifact,
        .handle = "fx-command-missing.log",
        .preview = "preview",
        .fallback_handle = fallback_handle,
    } });

    const source = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 3, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "RETAINED_COMMAND_FALLBACK") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<stdout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Full saved result unavailable.") == null);
}

test "paged command result removes an envelope split across source pages" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const prefix = "exit_code=0\n<stdout>\n";
    const tail_marker = "PAGED_RESULT_TAIL";
    const body_len = result_store.full_read_chunk_bytes - 2 - prefix.len;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try result.appendSlice(alloc, prefix);
    try result.appendNTimes(alloc, 'x', body_len - tail_marker.len);
    try result.appendSlice(alloc, tail_marker);
    try result.appendSlice(alloc, "\n</stdout>\n");
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "paged-command-result",
        "run_command",
        result.items,
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("● Ran command\n"),
        .class = .tool_status,
    } }};
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result_handle = try alloc.dupe(u8, handle),
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &.{},
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    const head = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 3, 0);
    defer alloc.free(head);
    const tail = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        3,
        measurement.total_rows -| 3,
    );
    defer alloc.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, head, "exit_code=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "<stdout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail, tail_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "</stdout>") == null);
}

test "resumed command detail pages its exact result handle without replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "resumed-command-result",
        "run_command",
        "exit_code=0\n<stdout>\nRESUMED_EXACT_RESULT\n</stdout>\n",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .created_at_ms = 0,
            .bytes = @constCast("● Ran resumed command\n"),
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .created_at_ms = 0,
            .bytes = @constCast("│ compact resumed placeholder\n"),
            .class = .command_output,
        } },
    };
    var blocks = [_]command_output_runtime.CommandOutputBlock{.{
        .entry_id = 2,
        .total_lines = 1,
    }};
    defer blocks[0].deinit(alloc);
    try blocks[0].source_entry_ids.append(alloc, 2);
    var details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "run_command"),
        .result_handle = try alloc.dupe(u8, handle),
        .command_output_entry_id = 2,
        .outcome = .completed,
    }};
    defer details[0].deinit(alloc);
    var projection = try buildProjection(
        alloc,
        &entries,
        &details,
        &blocks,
        .{ .system_notice_label_style = "", .system_notice_text_style = "", .reset_style = "", .dim_style = "", .red_style = "" },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const source = try renderProjectionViewportSource(alloc, &projection, &capability, 80, 10, 0);
    defer alloc.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "RESUMED_EXACT_RESULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "compact resumed placeholder") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "exit_code=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<stdout>") == null);
}

test "projection measurement continues across a stored segment boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    // Envelope trimming leaves the stored segment ending mid-row.
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "boundary-detail",
        "read_file",
        "<path>x</path>\n<content>\nALPHA\nBRAVO\n</content>",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "before\n") });
    try projection.segments.append(alloc, .{ .stored_result = .{
        .handle = handle,
        .preview = null,
    } });
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "\nafter\n") });

    // before / ALPHA / BRAVO / after: the newline opening the final static
    // segment terminates BRAVO's row rather than counting as a row of its own.
    const measurement = try measureProjection(alloc, &projection, &capability, 80);
    try std.testing.expectEqual(@as(u32, 4), measurement.total_rows);

    const last_row = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        1,
        measurement.total_rows - 1,
    );
    defer alloc.free(last_row);
    try std.testing.expect(std.mem.indexOf(u8, last_row, "after") != null);

    const past_end = try renderProjectionViewportSource(
        alloc,
        &projection,
        &capability,
        80,
        1,
        measurement.total_rows,
    );
    defer alloc.free(past_end);
    try std.testing.expectEqualStrings("", past_end);

    const saturated = try renderProjectionViewportSource(
        alloc,
        &projection,
        null,
        10,
        std.math.maxInt(u16),
        std.math.maxInt(u32),
    );
    defer alloc.free(saturated);
    try std.testing.expectEqualStrings("", saturated);
}

test "projection window applies the carriage return column reset measurement uses" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "AAAAAAAAA\rBB\n") });

    const measurement = try measureProjection(alloc, &projection, null, 10);
    try std.testing.expectEqual(@as(u32, 1), measurement.total_rows);

    // The overwritten tail must not wrap onto a row past the measured document.
    const row = try renderProjectionViewportSource(alloc, &projection, null, 10, 1, 0);
    defer alloc.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "BB") != null);
}

test "projection window applies positional tab measurement and preserves bytes" {
    const alloc = std.testing.allocator;
    const text = "1234567\tXYZ\n";
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, text) });

    const measurement = try measureProjection(alloc, &projection, null, 10);
    try std.testing.expectEqual(@as(u32, 2), measurement.total_rows);

    const full = try renderProjectionViewportSource(alloc, &projection, null, 10, 2, 0);
    defer alloc.free(full);
    try std.testing.expectEqualStrings(text, full);

    const wrapped_tail = try renderProjectionViewportSource(alloc, &projection, null, 10, 1, 1);
    defer alloc.free(wrapped_tail);
    try std.testing.expectEqualStrings("Z\n", wrapped_tail);
}

test "projection window handles scroll offsets at and past the document tail" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    } };
    defer projection.deinit(alloc);
    try projection.segments.append(alloc, .{ .static = try alloc.dupe(u8, "one\ntwo\nthree\n") });

    const measurement = try measureProjection(alloc, &projection, null, 10);
    try std.testing.expectEqual(@as(u32, 3), measurement.total_rows);

    const tail = try renderProjectionViewportSource(alloc, &projection, null, 10, 5, 2);
    defer alloc.free(tail);
    try std.testing.expect(std.mem.indexOf(u8, tail, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "two") == null);

    const past_end = try renderProjectionViewportSource(
        alloc,
        &projection,
        null,
        10,
        5,
        measurement.total_rows + 100,
    );
    defer alloc.free(past_end);
    try std.testing.expectEqualStrings("", past_end);
}

pub fn buildProjection(
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    details: []const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
    anchor_entry_id: ?u32,
) !Projection {
    return buildProjectionWithDiffResolverInterruptible(
        alloc,
        entries,
        details,
        command_blocks,
        styles,
        cols,
        anchor_entry_id,
        null,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildProjectionWithResolver(
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    details: []const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
    anchor_entry_id: ?u32,
    full_diff_resolver: ?FullDiffResolver,
) !Projection {
    return buildProjectionWithDiffResolverInterruptible(
        alloc,
        entries,
        details,
        command_blocks,
        styles,
        cols,
        anchor_entry_id,
        full_diff_resolver,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn buildProjectionWithDiffResolverInterruptible(
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    details: []const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
    anchor_entry_id: ?u32,
    full_diff_resolver: ?FullDiffResolver,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var group_projection = try tool_group_projection.buildExpandedStyledInterruptible(
        alloc,
        entries,
        details,
        cols,
        .{
            .marker_style = user_message_card.promptMarkerStyle(),
            .text_style = ui_render.statusline_style,
            .reset_style = "\x1b[0m",
        },
        styles,
        checkpoint,
    );
    defer group_projection.deinit(alloc);
    return buildProjectionWithEntryActionsInterruptible(
        alloc,
        entries,
        details,
        command_blocks,
        styles,
        cols,
        anchor_entry_id,
        full_diff_resolver,
        group_projection.entry_actions.items,
        checkpoint,
    );
}

pub fn buildProjectionWithEntryActionsInterruptible(
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    details: []const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
    anchor_entry_id: ?u32,
    full_diff_resolver: ?FullDiffResolver,
    entry_actions: []const transcript_blocks.EntryRenderAction,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    std.debug.assert(entry_actions.len == entries.len);
    var builder = ProjectionBuilder.init(alloc, styles, cols);
    errdefer builder.deinit();
    var source_index = try ProjectionSourceIndex.build(alloc, details, command_blocks, checkpoint);
    defer source_index.deinit(alloc);
    const emitted_command_blocks = try alloc.alloc(bool, command_blocks.len);
    defer alloc.free(emitted_command_blocks);
    @memset(emitted_command_blocks, false);

    var context = ProjectionComposeContext{
        .alloc = alloc,
        .builder = &builder,
        .entries = entries,
        .source_index = &source_index,
        .entry_actions = entry_actions,
        .anchor_entry_id = anchor_entry_id,
        .emitted_command_blocks = emitted_command_blocks,
        .full_diff_resolver = full_diff_resolver,
        .cols = cols,
        .checkpoint = checkpoint,
    };
    const sink = transcript_blocks.FullPresentationSink{
        .context = &context,
        .skip_entry = ProjectionComposeContext.skipEntry,
        .override_kind = ProjectionComposeContext.overrideKind,
        .append_override = ProjectionComposeContext.appendOverride,
        .before_entry = ProjectionComposeContext.beforeEntry,
        .append_detail = ProjectionComposeContext.appendDetail,
    };
    try transcript_blocks.renderEntriesForFullPresentationInterruptible(
        alloc,
        entries,
        cols,
        builder.styles(),
        &sink,
        builder.staticOut(),
        checkpoint,
    );
    return builder.finish();
}

/// Counts the visual document without materializing stored sidecars. A valid
/// handle is scanned in fixed-size raw pages through the terminal-safe encoder.
fn measureProjection(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
) !ProjectionMeasurement {
    return measureProjectionInterruptible(alloc, projection, capability, cols, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn measureProjectionInterruptible(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    checkpoint: ?*BuildCheckpoint,
) !ProjectionMeasurement {
    if (projection.measurement_cols == cols) return .{
        .total_rows = projection.measured_total_rows,
        .anchor_row = projection.measured_anchor_row,
        .item_rows = projection.measured_item_rows.items,
    };
    while (true) {
        var item_rows: std.ArrayList(transcript_presentation.ItemRow) = .empty;
        defer item_rows.deinit(alloc);
        var segment_checkpoints: std.ArrayList(ProjectionCheckpoint) = .empty;
        defer segment_checkpoints.deinit(alloc);
        const capture_item_rows = projection.measured_item_rows.capacity >=
            projection.item_boundaries.items.len;
        const capture_segment_checkpoints = projection.measured_segment_checkpoints.capacity >=
            projection.segments.items.len;
        if (capture_item_rows) {
            try item_rows.ensureTotalCapacity(
                alloc,
                projection.item_boundaries.items.len,
            );
        }
        if (capture_segment_checkpoints) {
            try segment_checkpoints.ensureTotalCapacity(
                alloc,
                projection.segments.items.len,
            );
        }

        var walker = ProjectionRowWalker.initMeasure(cols, checkpoint);
        const anchor_row = walkProjectionSegments(
            alloc,
            projection,
            capability,
            &walker,
            0,
            0,
            if (capture_item_rows) &item_rows else null,
            if (capture_segment_checkpoints) &segment_checkpoints else null,
        ) catch |err| switch (err) {
            error.StoredSegmentDegraded => continue,
            else => |other| return other,
        };
        projection.measured_item_rows.items.len = 0;
        projection.measured_item_rows.appendSliceAssumeCapacity(item_rows.items);
        projection.measured_segment_checkpoints.items.len = 0;
        projection.measured_segment_checkpoints.appendSliceAssumeCapacity(
            segment_checkpoints.items,
        );
        projection.measured_total_rows = walker.totalRows();
        projection.measured_anchor_row = anchor_row;
        projection.measurement_cols = cols;
        return .{
            .total_rows = projection.measured_total_rows,
            .anchor_row = projection.measured_anchor_row,
            .item_rows = projection.measured_item_rows.items,
        };
    }
}

fn walkProjectionSegments(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    walker: *ProjectionRowWalker,
    start_segment_index: usize,
    start_item_index: usize,
    item_rows: ?*std.ArrayList(transcript_presentation.ItemRow),
    segment_checkpoints: ?*std.ArrayList(ProjectionCheckpoint),
) !?u32 {
    var anchor_row: ?u32 = null;
    var boundary_index = start_item_index;
    for (projection.segments.items[start_segment_index..], start_segment_index..) |*segment, index| {
        if (segment_checkpoints) |captured| {
            captured.appendAssumeCapacity(walker.checkpoint());
        }
        while (boundary_index < projection.item_boundaries.items.len and
            projection.item_boundaries.items[boundary_index].segment_index == index)
        {
            const boundary = projection.item_boundaries.items[boundary_index];
            if (item_rows) |captured| captured.appendAssumeCapacity(.{
                .entry_id = boundary.entry_id,
                .row = walker.totalRows(),
            });
            boundary_index += 1;
        }
        if (projection.anchor_segment_index) |anchor_index| {
            if (anchor_index == index) anchor_row = walker.totalRows();
        }
        const keep_scanning = switch (segment.*) {
            .static => |bytes| try walker.append(bytes),
            .stored_result => |*stored| if (stored.unavailable)
                try appendStoredResultFallback(alloc, walker, projection.styles, stored.*)
            else
                appendStoredResultContent(alloc, walker, capability, projection.styles, stored.*) catch |err| {
                    if (err == error.InputPending) return err;
                    // Rows walked so far are stale once the segment degrades.
                    _ = degradeStoredResult(stored, err);
                    projection.invalidateMeasurement();
                    return error.StoredSegmentDegraded;
                },
        };
        if (!keep_scanning) break;
    }
    if (item_rows) |captured| while (boundary_index < projection.item_boundaries.items.len) : (boundary_index += 1) {
        const boundary = projection.item_boundaries.items[boundary_index];
        captured.appendAssumeCapacity(.{
            .entry_id = boundary.entry_id,
            .row = walker.totalRows(),
        });
    };
    if (projection.anchor_segment_index) |anchor_index| {
        if (anchor_index == projection.segments.items.len) anchor_row = walker.totalRows();
    }
    return anchor_row;
}

/// Single row-geometry walk (wrap rules of `visualRowsForLine`) behind both
/// measurement and window extraction, so scroll bounds cannot disagree with
/// the rows the window yields. A window captures rows [start_row, end_row).
const ProjectionRowWalker = struct {
    cols: u16,
    row: u32 = 0,
    col: u16 = 1,
    row_has_bytes: bool = false,
    window: ?Window = null,
    build_checkpoint: ?*BuildCheckpoint = null,
    max_output_bytes: usize = std.math.maxInt(usize),

    const Window = struct {
        writer: std.Io.Writer.Allocating,
        start_row: u32,
        end_row: u32,
    };

    fn initMeasure(cols: u16, build_checkpoint_ptr: ?*BuildCheckpoint) ProjectionRowWalker {
        return .{ .cols = @max(cols, 1), .build_checkpoint = build_checkpoint_ptr };
    }

    fn initWindow(
        alloc: Allocator,
        cols: u16,
        start_row: u32,
        visible_rows: u16,
        build_checkpoint_ptr: ?*BuildCheckpoint,
    ) ProjectionRowWalker {
        return initWindowAt(alloc, cols, start_row, visible_rows, .{
            .row = 0,
            .col = 1,
            .row_has_bytes = false,
        }, build_checkpoint_ptr);
    }

    fn initWindowAt(
        alloc: Allocator,
        cols: u16,
        start_row: u32,
        visible_rows: u32,
        start_checkpoint: ProjectionCheckpoint,
        build_checkpoint_ptr: ?*BuildCheckpoint,
    ) ProjectionRowWalker {
        return .{
            .cols = @max(cols, 1),
            .row = start_checkpoint.row,
            .col = start_checkpoint.col,
            .row_has_bytes = start_checkpoint.row_has_bytes,
            .build_checkpoint = build_checkpoint_ptr,
            .window = .{
                .writer = .init(alloc),
                .start_row = start_row,
                .end_row = start_row +| visible_rows,
            },
        };
    }

    fn checkpoint(self: *const ProjectionRowWalker) ProjectionCheckpoint {
        return .{
            .row = self.row,
            .col = self.col,
            .row_has_bytes = self.row_has_bytes,
        };
    }

    fn deinit(self: *ProjectionRowWalker) void {
        if (self.window) |*window| window.writer.deinit();
        self.* = undefined;
    }

    /// Rows the walked content occupies so far; a final partial row counts.
    fn totalRows(self: *const ProjectionRowWalker) u32 {
        return self.row +| @intFromBool(self.row_has_bytes);
    }

    fn windowFilled(self: *const ProjectionRowWalker) bool {
        const window = self.window orelse return false;
        return self.row >= window.end_row;
    }

    fn emit(self: *ProjectionRowWalker, bytes: []const u8) !void {
        if (self.window) |*window| {
            if (self.row >= window.start_row) {
                if (bytes.len > self.max_output_bytes -| window.writer.written().len) {
                    return error.PreparedWindowTooLarge;
                }
                try window.writer.writer.writeAll(bytes);
            }
        }
    }

    /// Returns false once the armed window is fully captured.
    fn append(self: *ProjectionRowWalker, bytes: []const u8) !bool {
        return self.appendWithSoftWrapPrefix(bytes, "");
    }

    fn appendWithSoftWrapPrefix(
        self: *ProjectionRowWalker,
        bytes: []const u8,
        soft_wrap_prefix: []const u8,
    ) !bool {
        var index: usize = 0;
        while (index < bytes.len) {
            try build_checkpoint.tick(self.build_checkpoint);
            if (self.windowFilled()) return false;
            const ch = bytes[index];
            if (ch == 0x1b) {
                const end = display_width.ansiSequenceEnd(bytes, index);
                try self.emit(bytes[index..end]);
                self.row_has_bytes = true;
                index = end;
                continue;
            }
            if (ch == '\n') {
                try self.emit(bytes[index .. index + 1]);
                self.row +|= 1;
                self.col = 1;
                self.row_has_bytes = false;
                index += 1;
                continue;
            }
            if (ch == '\r') {
                try self.emit(bytes[index .. index + 1]);
                self.col = 1;
                self.row_has_bytes = true;
                index += 1;
                continue;
            }
            if (ch == '\t') {
                try self.emit(bytes[index .. index + 1]);
                self.col = display_width.nextTabStopColumn(self.col, self.cols);
                self.row_has_bytes = true;
                index += 1;
                continue;
            }
            if (ch < 32) {
                try self.emit(bytes[index .. index + 1]);
                self.row_has_bytes = true;
                index += 1;
                continue;
            }
            const unit = display_width.displayUnitAt(bytes, index);
            const width = unit.cell_width;
            if (width > 0 and display_width.shouldWrapAt(self.col, @intCast(width), self.cols)) {
                self.row +|= 1;
                self.col = 1;
                self.row_has_bytes = false;
                if (self.windowFilled()) return false;
                const prefix_width = display_width.visibleWidthIgnoringAnsi(soft_wrap_prefix);
                if (prefix_width > 0 and
                    prefix_width + width <= self.cols)
                {
                    try self.emit(soft_wrap_prefix);
                    self.col = 1 + @as(u16, @intCast(prefix_width));
                    self.row_has_bytes = true;
                }
            }
            try self.emit(bytes[index .. index + unit.byte_len]);
            self.row_has_bytes = true;
            if (width > 0) self.col +|= @intCast(width);
            index += unit.byte_len;
        }
        return !self.windowFilled();
    }

    fn toOwnedSlice(self: *ProjectionRowWalker) ![]u8 {
        return self.window.?.writer.toOwnedSlice();
    }
};

const StoredResultRange = struct {
    start: usize,
    end: usize,
};

const CommandBodyRange = struct {
    stream: command_output_content.Stream,
    start: usize,
    end: usize,
};

const PagedReaderCursor = struct {
    reader: *StoredResultReader,
    checkpoint: ?*BuildCheckpoint,
    page: ?[]u8 = null,
    page_start: usize = 0,

    fn deinit(self: *PagedReaderCursor, alloc: Allocator) void {
        if (self.page) |page| alloc.free(page);
        self.* = undefined;
    }

    fn byteAt(self: *PagedReaderCursor, alloc: Allocator, offset: usize) !u8 {
        if (offset >= self.reader.size()) return error.UnexpectedEndOfResult;
        try self.ensurePage(alloc, offset);
        return self.page.?[offset - self.page_start];
    }

    fn startsWithAt(
        self: *PagedReaderCursor,
        alloc: Allocator,
        offset: usize,
        expected: []const u8,
    ) !bool {
        const end = std.math.add(usize, offset, expected.len) catch return false;
        if (end > self.reader.size()) return false;
        for (expected, 0..) |byte, index| {
            if (try self.byteAt(alloc, offset + index) != byte) return false;
        }
        return true;
    }

    fn findFrom(
        self: *PagedReaderCursor,
        alloc: Allocator,
        start: usize,
        needle: []const u8,
    ) !?usize {
        if (needle.len == 0) return start;
        var offset = start;
        while (offset < self.reader.size()) : (offset += 1) {
            try build_checkpoint.tick(self.checkpoint);
            if (try self.startsWithAt(alloc, offset, needle)) return offset;
        }
        return null;
    }

    fn ensurePage(self: *PagedReaderCursor, alloc: Allocator, offset: usize) !void {
        if (self.page) |page| {
            if (offset >= self.page_start and offset < self.page_start + page.len) return;
            alloc.free(page);
            self.page = null;
        }
        self.page_start = offset;
        const page = try self.reader.readPage(
            alloc,
            offset,
            @min(result_store.full_read_chunk_bytes, self.reader.size() - offset),
        );
        if (page.len == 0) {
            alloc.free(page);
            return error.UnexpectedEndOfResult;
        }
        self.page = page;
    }
};

const CommandBodyRanges = struct {
    items: [2]CommandBodyRange = undefined,
    len: usize = 0,

    fn append(self: *CommandBodyRanges, range: CommandBodyRange) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = range;
        self.len += 1;
    }
};

fn commandResultBodyRanges(
    alloc: Allocator,
    reader: *StoredResultReader,
    checkpoint: ?*BuildCheckpoint,
) !CommandBodyRanges {
    var cursor = PagedReaderCursor{ .reader = reader, .checkpoint = checkpoint };
    defer cursor.deinit(alloc);

    const status_end = try cursor.findFrom(alloc, 0, "\n") orelse
        return error.InvalidCommandResultEnvelope;
    if (!try validForegroundStatusRange(alloc, &cursor, status_end)) {
        return error.InvalidCommandResultEnvelope;
    }
    var offset = status_end + 1;
    if (try cursor.startsWithAt(alloc, offset, "(no output)\n")) {
        if (offset + "(no output)\n".len != reader.size()) {
            return error.InvalidCommandResultEnvelope;
        }
        return .{};
    }

    var ranges = CommandBodyRanges{};
    for ([_]command_output_content.Stream{ .stdout, .stderr }) |stream| {
        const label = @tagName(stream);
        var open_buffer: [16]u8 = undefined;
        const open = std.fmt.bufPrint(&open_buffer, "<{s}>\n", .{label}) catch
            unreachable;
        if (!try cursor.startsWithAt(alloc, offset, open)) continue;
        const body_start = offset + open.len;

        var close_buffer: [20]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buffer, "\n</{s}>\n", .{label}) catch
            unreachable;
        const close_start = try cursor.findFrom(alloc, body_start, close) orelse
            return error.InvalidCommandResultEnvelope;
        ranges.append(.{
            .stream = stream,
            .start = body_start,
            .end = close_start,
        });
        offset = close_start + close.len;
    }
    if (ranges.len == 0 or offset != reader.size()) {
        return error.InvalidCommandResultEnvelope;
    }
    return ranges;
}

fn validForegroundStatusRange(
    alloc: Allocator,
    cursor: *PagedReaderCursor,
    status_end: usize,
) !bool {
    if (status_end > 64) return false;
    var status_buffer: [64]u8 = undefined;
    for (0..status_end) |index| {
        status_buffer[index] = try cursor.byteAt(alloc, index);
    }
    return command_output_content.validForegroundStatus(status_buffer[0..status_end]);
}

const CommandFrame = struct {
    stream: command_output_content.Stream,
    payload: []u8,
};

const RangedCommandFrameReader = struct {
    reader: StoredResultReader,
    ranges: CommandBodyRanges,
    range_index: usize = 0,
    offset: usize = 0,

    fn deinit(self: *RangedCommandFrameReader) void {
        self.reader.deinit();
        self.* = undefined;
    }

    fn next(self: *RangedCommandFrameReader, alloc: Allocator) !?CommandFrame {
        while (self.range_index < self.ranges.len) {
            const range = self.ranges.items[self.range_index];
            if (self.offset == 0) self.offset = range.start;
            if (self.offset >= range.end) {
                self.range_index += 1;
                self.offset = 0;
                continue;
            }
            const page = try self.reader.readPage(
                alloc,
                self.offset,
                @min(result_store.full_read_chunk_bytes, range.end - self.offset),
            );
            errdefer alloc.free(page);
            if (page.len == 0) return error.UnexpectedEndOfResult;
            self.offset += page.len;
            return .{ .stream = range.stream, .payload = page };
        }
        return null;
    }
};

const CommandFrameReader = union(enum) {
    replay: command_replay_store.Reader,
    ranged: RangedCommandFrameReader,

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        checkpoint: ?*BuildCheckpoint,
    ) !CommandFrameReader {
        var source: CommandFrameReader = undefined;
        try initInto(&source, alloc, capability, stored, checkpoint);
        return source;
    }

    // noinline keeps the comptime-known error returns behind a call
    // boundary; inlined into a `!CommandFrameReader` result location they
    // each materialize a union-sized (~8KB) error-union constant.
    noinline fn initInto(
        out: *CommandFrameReader,
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        checkpoint: ?*BuildCheckpoint,
    ) !void {
        const managed = capability orelse return error.ResultHandleUnavailable;
        switch (stored.kind) {
            .command_replay => out.* = .{ .replay = try command_replay_store.Reader.open(
                alloc,
                managed,
                .{ .handle = stored.handle, .framed_bytes = stored.framed_bytes },
            ) },
            .command_artifact, .command_result => {
                var reader = try openStoredResultReader(alloc, capability, stored);
                errdefer reader.deinit();
                var ranges = CommandBodyRanges{};
                if (stored.kind == .command_result) {
                    ranges = try commandResultBodyRanges(alloc, &reader, checkpoint);
                } else {
                    ranges.append(.{
                        .stream = .stdout,
                        .start = 0,
                        .end = reader.size(),
                    });
                }
                out.* = .{ .ranged = .{
                    .reader = reader,
                    .ranges = ranges,
                } };
            },
            .tool_result => return error.NotCommandStoredResult,
        }
    }

    fn deinit(self: *CommandFrameReader) void {
        switch (self.*) {
            .replay => |*reader| reader.deinit(),
            .ranged => |*reader| reader.deinit(),
        }
        self.* = undefined;
    }

    fn next(self: *CommandFrameReader, alloc: Allocator) !?CommandFrame {
        return switch (self.*) {
            .replay => |*reader| if (try reader.next(alloc)) |frame|
                .{ .stream = frame.stream, .payload = frame.payload }
            else
                null,
            .ranged => |*reader| reader.next(alloc),
        };
    }
};

const command_projection_scratch_bytes: usize = 192 * 1024;
const command_record_exact_bytes: usize = 16 * 1024;

fn appendCommandStoredResultContent(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    capability: ?*session_child_store.SessionChildCapability,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
) !bool {
    if (try appendBoundedCommandSource(alloc, walker, capability, styles, stored)) |keep_scanning| {
        return keep_scanning;
    }
    return appendMergedCommandSource(alloc, walker, capability, styles, stored);
}

/// Returns null when canonical content exceeds the bounded scratch budget.
fn appendBoundedCommandSource(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    capability: ?*session_child_store.SessionChildCapability,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
) !?bool {
    if (stored.kind == .command_replay and
        stored.framed_bytes > command_projection_scratch_bytes)
    {
        return null;
    }
    const scratch = alloc.alloc(u8, command_projection_scratch_bytes) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    defer alloc.free(scratch);
    var scratch_alloc = std.heap.FixedBufferAllocator.init(scratch);

    var source = try CommandFrameReader.init(alloc, capability, stored, walker.build_checkpoint);
    defer source.deinit();
    var output: command_output_content.CanonicalOutput = .{};
    defer output.deinit(scratch_alloc.allocator());

    while (try source.next(alloc)) |frame| {
        defer alloc.free(frame.payload);
        output.append(scratch_alloc.allocator(), frame.stream, frame.payload) catch |err| switch (err) {
            error.OutOfMemory => return null,
        };
    }
    output.finish(scratch_alloc.allocator()) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };

    const end_record = stored.end_record orelse output.records.items.len;
    if (stored.start_record > output.records.items.len or
        end_record > output.records.items.len or
        stored.start_record > end_record)
    {
        return error.CommandProjectionRecordMissing;
    }
    for (output.records.items[stored.start_record..end_record]) |record| {
        const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            alloc,
            styles,
            record.text.items,
            walker.cols,
        );
        defer alloc.free(rendered);
        if (!try walker.append(rendered)) return false;
        if (!std.mem.endsWith(u8, rendered, "\n")) {
            if (!try walker.append("\n")) return false;
        }
    }
    return true;
}

const PagedLiteralCommandRecord = struct {
    walker: *ProjectionRowWalker,
    styles: transcript_blocks.Styles,
    exact: std.ArrayList(u8) = .empty,
    streaming: bool = false,
    pending_row: std.ArrayList(u8) = .empty,
    pending_separator_spaces: usize = 0,
    pending_valid: bool = false,
    row: std.ArrayList(u8) = .empty,
    row_width: u16 = 0,
    last_space_byte: ?usize = null,
    zero_width_run_bytes: usize = 0,
    emitted_any: bool = false,

    fn deinit(self: *PagedLiteralCommandRecord, alloc: Allocator) void {
        self.exact.deinit(alloc);
        self.pending_row.deinit(alloc);
        self.row.deinit(alloc);
        self.* = undefined;
    }

    fn append(self: *PagedLiteralCommandRecord, alloc: Allocator, text: []const u8) !void {
        if (!self.streaming) {
            if (text.len <= command_record_exact_bytes -| self.exact.items.len) {
                try self.exact.appendSlice(alloc, text);
                return;
            }
            self.streaming = true;
            try self.appendStreaming(alloc, self.exact.items);
            self.exact.clearRetainingCapacity();
        }
        try self.appendStreaming(alloc, text);
    }

    fn appendStreaming(self: *PagedLiteralCommandRecord, alloc: Allocator, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            const byte = text[offset];
            if (byte == '\t') {
                const absolute_col = self.gutterWidth() + self.row_width + 1;
                const next_col = display_width.nextTabStopColumn(absolute_col, self.walker.cols);
                const spaces = next_col -| absolute_col;
                self.zero_width_run_bytes = 0;
                try self.row.appendNTimes(alloc, ' ', spaces);
                self.row_width += spaces;
                offset += 1;
                continue;
            }
            const unit = display_width.displayUnitAt(text, offset);
            const width_usize = unit.cell_width;
            if (byte == ' ') {
                try self.appendSpace(alloc);
            } else if (width_usize == 0) {
                if (self.zero_width_run_bytes +| unit.byte_len <=
                    assistant_wrap.literal_command_zero_width_row_byte_limit)
                {
                    try self.row.appendSlice(alloc, text[offset .. offset + unit.byte_len]);
                    self.zero_width_run_bytes += unit.byte_len;
                } else {
                    try self.emitCurrentRow(alloc, 0);
                    try self.row.appendSlice(alloc, text[offset .. offset + unit.byte_len]);
                    self.zero_width_run_bytes = unit.byte_len;
                }
            } else {
                self.zero_width_run_bytes = 0;
                const width: u16 = @intCast(width_usize);
                try self.appendVisibleUnit(alloc, text[offset .. offset + unit.byte_len], width);
            }
            offset += unit.byte_len;
        }
    }

    fn finish(self: *PagedLiteralCommandRecord, alloc: Allocator) !void {
        if (!self.streaming) {
            const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
                alloc,
                self.styles,
                self.exact.items,
                self.walker.cols,
            );
            defer alloc.free(rendered);
            if (!try self.walker.append(rendered)) return error.WindowFilled;
            return;
        }
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(alloc);
        if (self.pending_valid) {
            try tail.appendSlice(alloc, self.pending_row.items);
            try tail.appendNTimes(alloc, ' ', self.pending_separator_spaces);
        }
        try tail.appendSlice(alloc, self.row.items);
        if (tail.items.len == 0 and self.emitted_any) return;
        const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            alloc,
            self.styles,
            tail.items,
            self.walker.cols,
        );
        defer alloc.free(rendered);
        if (!try self.walker.append(rendered)) return error.WindowFilled;
    }

    fn reset(self: *PagedLiteralCommandRecord) void {
        self.exact.clearRetainingCapacity();
        self.streaming = false;
        self.pending_row.clearRetainingCapacity();
        self.pending_separator_spaces = 0;
        self.pending_valid = false;
        self.row.clearRetainingCapacity();
        self.row_width = 0;
        self.last_space_byte = null;
        self.zero_width_run_bytes = 0;
        self.emitted_any = false;
    }

    fn appendVisibleUnit(
        self: *PagedLiteralCommandRecord,
        alloc: Allocator,
        bytes: []const u8,
        unit_width: u16,
    ) !void {
        const content_cols = self.contentCols();
        var display_bytes = bytes;
        var display_width_cells = unit_width;
        if (unit_width > content_cols) {
            display_bytes = "?";
            display_width_cells = 1;
        }
        while (self.row_width + display_width_cells > content_cols) {
            if (self.last_space_byte != null) {
                try self.wrapAtLastSpace(alloc);
            } else {
                try self.emitCurrentRow(alloc, 0);
            }
        }
        try self.row.appendSlice(alloc, display_bytes);
        self.row_width += display_width_cells;
    }

    fn appendSpace(self: *PagedLiteralCommandRecord, alloc: Allocator) !void {
        self.zero_width_run_bytes = 0;
        if (self.row_width >= self.contentCols()) {
            try self.emitCurrentRow(alloc, 1);
            return;
        }
        const space_index = self.row.items.len;
        try self.row.append(alloc, ' ');
        if (space_index > 0 and self.row.items[space_index - 1] != ' ') {
            self.last_space_byte = space_index;
        }
        self.row_width += 1;
    }

    fn wrapAtLastSpace(self: *PagedLiteralCommandRecord, alloc: Allocator) !void {
        const break_index = self.last_space_byte.?;
        var suffix_start = break_index;
        while (suffix_start < self.row.items.len and self.row.items[suffix_start] == ' ') : (suffix_start += 1) {}
        try self.queueRow(
            alloc,
            self.row.items[0..break_index],
            suffix_start - break_index,
        );
        const suffix_len = self.row.items.len - suffix_start;
        std.mem.copyForwards(u8, self.row.items[0..suffix_len], self.row.items[suffix_start..]);
        self.row.items.len = suffix_len;
        self.remeasureRow();
    }

    fn emitCurrentRow(
        self: *PagedLiteralCommandRecord,
        alloc: Allocator,
        separator_spaces: usize,
    ) !void {
        try self.queueRow(alloc, self.row.items, separator_spaces);
        self.row.clearRetainingCapacity();
        self.row_width = 0;
        self.last_space_byte = null;
    }

    fn queueRow(
        self: *PagedLiteralCommandRecord,
        alloc: Allocator,
        content: []const u8,
        separator_spaces: usize,
    ) !void {
        if (self.pending_valid) try self.emitPendingRow();
        self.pending_row.clearRetainingCapacity();
        try self.pending_row.appendSlice(alloc, content);
        self.pending_separator_spaces = separator_spaces;
        self.pending_valid = true;
        self.emitted_any = true;
    }

    fn emitPendingRow(self: *PagedLiteralCommandRecord) !void {
        if (self.gutterWidth() > 0) {
            if (!try self.walker.append(self.styles.reset_style)) return error.WindowFilled;
            if (!try self.walker.append("│")) return error.WindowFilled;
            if (!try self.walker.append(self.styles.dim_style)) return error.WindowFilled;
            if (!try self.walker.append(" ")) return error.WindowFilled;
        } else {
            if (!try self.walker.append(self.styles.dim_style)) return error.WindowFilled;
        }
        if (!try self.walker.append(self.pending_row.items)) return error.WindowFilled;
        if (!try self.walker.append(self.styles.reset_style)) return error.WindowFilled;
        if (!try self.walker.append("\n")) return error.WindowFilled;
        self.pending_row.clearRetainingCapacity();
        self.pending_separator_spaces = 0;
        self.pending_valid = false;
    }

    fn remeasureRow(self: *PagedLiteralCommandRecord) void {
        self.row_width = @intCast(@min(
            display_width.visibleWidthIgnoringAnsi(self.row.items),
            std.math.maxInt(u16),
        ));
        self.last_space_byte = null;
        for (self.row.items, 0..) |byte, index| {
            if (byte == ' ' and index > 0 and self.row.items[index - 1] != ' ') {
                self.last_space_byte = index;
            }
        }
    }

    fn gutterWidth(self: *const PagedLiteralCommandRecord) u16 {
        return if (self.walker.cols >= 3) 2 else 0;
    }

    fn contentCols(self: *const PagedLiteralCommandRecord) u16 {
        return @max(self.walker.cols -| self.gutterWidth(), 1);
    }
};

test "paged command records match shared wrapping geometry" {
    const alloc = std.testing.allocator;
    const text = try alloc.alloc(u8, command_record_exact_bytes + 1);
    defer alloc.free(text);
    @memset(text, 'x');
    @memcpy(text[0..11], "aa\tbbbbbbbb");
    const styles = transcript_blocks.Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    for ([_]u16{ 1, 2, 5, 10, 16, 80 }) |cols| {
        const expected = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            alloc,
            styles,
            text,
            cols,
        );
        defer alloc.free(expected);
        var walker = ProjectionRowWalker.initWindow(
            alloc,
            cols,
            0,
            std.math.maxInt(u16),
            null,
        );
        defer walker.deinit();
        var projector = PagedLiteralCommandRecord{
            .walker = &walker,
            .styles = styles,
        };
        defer projector.deinit(alloc);

        try projector.append(alloc, text);
        try projector.finish(alloc);
        const actual = try walker.toOwnedSlice();
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

const TaggedCommandByte = struct {
    stream: command_output_content.Stream,
    byte: u8,
};

const CommandByteReader = struct {
    source: CommandFrameReader,
    checkpoint: ?*BuildCheckpoint,
    frame: ?CommandFrame = null,
    frame_offset: usize = 0,

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        checkpoint: ?*BuildCheckpoint,
    ) !CommandByteReader {
        return .{
            .source = try CommandFrameReader.init(alloc, capability, stored, checkpoint),
            .checkpoint = checkpoint,
        };
    }

    fn deinit(self: *CommandByteReader, alloc: Allocator) void {
        if (self.frame) |frame| alloc.free(frame.payload);
        self.source.deinit();
        self.* = undefined;
    }

    fn next(self: *CommandByteReader, alloc: Allocator) !?TaggedCommandByte {
        try build_checkpoint.tick(self.checkpoint);
        if (self.source == .replay) {
            const byte = try self.source.replay.nextByte() orelse return null;
            return .{ .stream = byte.stream, .byte = byte.value };
        }
        while (true) {
            if (self.frame) |frame| {
                if (self.frame_offset < frame.payload.len) {
                    const byte = frame.payload[self.frame_offset];
                    self.frame_offset += 1;
                    return .{ .stream = frame.stream, .byte = byte };
                }
                alloc.free(frame.payload);
                self.frame = null;
                self.frame_offset = 0;
            }
            self.frame = try self.source.next(alloc) orelse return null;
        }
    }
};

const RecordOrderReader = struct {
    bytes: CommandByteReader,
    decoders: [2]command_output_content.Decoder = .{ .{}, .{} },
    open: [2]bool = .{ false, false },
    pending_byte: ?TaggedCommandByte = null,
    created: ?command_output_content.Stream = null,
    finished: bool = false,

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        checkpoint: ?*BuildCheckpoint,
    ) !RecordOrderReader {
        return .{ .bytes = try CommandByteReader.init(alloc, capability, stored, checkpoint) };
    }

    fn deinit(self: *RecordOrderReader, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.* = undefined;
    }

    fn nextRecord(self: *RecordOrderReader, alloc: Allocator) !?command_output_content.Stream {
        if (self.finished) return null;
        while (true) {
            if (self.pending_byte) |tagged| {
                self.pending_byte = null;
                try self.consume(tagged);
                if (self.created) |stream| {
                    self.created = null;
                    return stream;
                }
                continue;
            }
            const tagged = try self.bytes.next(alloc) orelse {
                inline for ([_]command_output_content.Stream{ .stdout, .stderr }) |stream| {
                    var sink = RecordOrderSink{ .reader = self, .stream = stream };
                    try self.decoders[@intFromEnum(stream)].finish(&sink);
                }
                self.finished = true;
                if (self.created) |stream| {
                    self.created = null;
                    return stream;
                }
                return null;
            };
            const index = @intFromEnum(tagged.stream);
            if (!self.open[index]) {
                self.open[index] = true;
                self.pending_byte = tagged;
                return tagged.stream;
            }
            try self.consume(tagged);
            if (self.created) |stream| {
                self.created = null;
                return stream;
            }
        }
    }

    fn consume(self: *RecordOrderReader, tagged: TaggedCommandByte) !void {
        const one = [_]u8{tagged.byte};
        var sink = RecordOrderSink{ .reader = self, .stream = tagged.stream };
        try self.decoders[@intFromEnum(tagged.stream)].append(&one, &sink);
    }
};

const RecordOrderSink = struct {
    reader: *RecordOrderReader,
    stream: command_output_content.Stream,

    fn ensureOpen(self: *RecordOrderSink) void {
        const index = @intFromEnum(self.stream);
        if (self.reader.open[index]) return;
        self.reader.open[index] = true;
        self.reader.created = self.stream;
    }

    pub fn appendText(self: *RecordOrderSink, _: []const u8) !void {
        self.ensureOpen();
    }

    pub fn finishLine(self: *RecordOrderSink) !void {
        self.ensureOpen();
        self.reader.open[@intFromEnum(self.stream)] = false;
    }

    pub fn replaceLine(self: *RecordOrderSink) !void {
        self.ensureOpen();
    }
};

const RecordGeneration = struct {
    final_generation: usize,
    valid: bool,
};

const StreamGenerationReader = struct {
    stream: command_output_content.Stream,
    bytes: CommandByteReader,
    decoder: command_output_content.Decoder = .{},
    open: bool = false,
    generation: usize = 0,
    visible: bool = false,
    terminated: bool = false,
    finished: bool = false,

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        stream: command_output_content.Stream,
        checkpoint: ?*BuildCheckpoint,
    ) !StreamGenerationReader {
        return .{
            .stream = stream,
            .bytes = try CommandByteReader.init(alloc, capability, stored, checkpoint),
        };
    }

    fn deinit(self: *StreamGenerationReader, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.* = undefined;
    }

    fn nextRecord(self: *StreamGenerationReader, alloc: Allocator) !?RecordGeneration {
        if (self.finished) return null;
        while (try self.bytes.next(alloc)) |tagged| {
            if (tagged.stream != self.stream) continue;
            if (!self.open) self.beginRecord();
            self.terminated = false;
            const one = [_]u8{tagged.byte};
            var sink = StreamGenerationSink{ .reader = self };
            try self.decoder.append(&one, &sink);
            if (self.terminated) return self.takeCompleted(true);
        }
        var sink = StreamGenerationSink{ .reader = self };
        try self.decoder.finish(&sink);
        self.finished = true;
        if (!self.open) return null;
        return self.takeCompleted(false);
    }

    fn beginRecord(self: *StreamGenerationReader) void {
        self.open = true;
        self.generation = 0;
        self.visible = false;
    }

    fn takeCompleted(self: *StreamGenerationReader, terminated: bool) RecordGeneration {
        const result = RecordGeneration{
            .final_generation = self.generation,
            .valid = terminated or self.visible,
        };
        self.open = false;
        self.generation = 0;
        self.visible = false;
        self.terminated = false;
        return result;
    }
};

const StreamGenerationSink = struct {
    reader: *StreamGenerationReader,

    pub fn appendText(self: *StreamGenerationSink, _: []const u8) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.visible = true;
    }

    pub fn finishLine(self: *StreamGenerationSink) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.terminated = true;
    }

    pub fn replaceLine(self: *StreamGenerationSink) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.generation += 1;
        self.reader.visible = false;
    }
};

const StreamProjectionReader = struct {
    stream: command_output_content.Stream,
    bytes: CommandByteReader,
    decoder: command_output_content.Decoder = .{},
    projector: PagedLiteralCommandRecord,
    open: bool = false,
    generation: usize = 0,
    visible: bool = false,
    terminated: bool = false,
    target_generation: usize = 0,
    emit: bool = false,
    finished: bool = false,

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
        stream: command_output_content.Stream,
        walker: *ProjectionRowWalker,
        styles: transcript_blocks.Styles,
    ) !StreamProjectionReader {
        return .{
            .stream = stream,
            .bytes = try CommandByteReader.init(alloc, capability, stored, walker.build_checkpoint),
            .projector = .{ .walker = walker, .styles = styles },
        };
    }

    fn deinit(self: *StreamProjectionReader, alloc: Allocator) void {
        self.projector.deinit(alloc);
        self.bytes.deinit(alloc);
        self.* = undefined;
    }

    fn projectNext(
        self: *StreamProjectionReader,
        alloc: Allocator,
        expected: RecordGeneration,
        should_emit: bool,
    ) !void {
        if (self.finished) return error.CommandProjectionRecordMissing;
        self.target_generation = expected.final_generation;
        self.emit = expected.valid and should_emit;
        self.projector.reset();
        while (try self.bytes.next(alloc)) |tagged| {
            if (tagged.stream != self.stream) continue;
            if (!self.open) self.beginRecord();
            self.terminated = false;
            const one = [_]u8{tagged.byte};
            var sink = StreamProjectionSink{ .reader = self, .alloc = alloc };
            try self.decoder.append(&one, &sink);
            if (self.terminated) return self.completeRecord(alloc, expected, true);
        }
        var sink = StreamProjectionSink{ .reader = self, .alloc = alloc };
        try self.decoder.finish(&sink);
        self.finished = true;
        if (!self.open) return error.CommandProjectionRecordMissing;
        return self.completeRecord(alloc, expected, false);
    }

    fn beginRecord(self: *StreamProjectionReader) void {
        self.open = true;
        self.generation = 0;
        self.visible = false;
    }

    fn completeRecord(
        self: *StreamProjectionReader,
        alloc: Allocator,
        expected: RecordGeneration,
        terminated: bool,
    ) !void {
        const valid = terminated or self.visible;
        if (self.generation != expected.final_generation or valid != expected.valid) {
            return error.CommandProjectionGenerationMismatch;
        }
        if (self.emit) try self.projector.finish(alloc);
        self.projector.reset();
        self.open = false;
        self.generation = 0;
        self.visible = false;
        self.terminated = false;
    }
};

const StreamProjectionSink = struct {
    reader: *StreamProjectionReader,
    alloc: Allocator,

    pub fn appendText(self: *StreamProjectionSink, bytes: []const u8) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.visible = true;
        if (self.reader.emit and self.reader.generation == self.reader.target_generation) {
            try self.reader.projector.append(self.alloc, bytes);
        }
    }

    pub fn finishLine(self: *StreamProjectionSink) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.terminated = true;
    }

    pub fn replaceLine(self: *StreamProjectionSink) !void {
        if (!self.reader.open) self.reader.beginRecord();
        self.reader.generation += 1;
        self.reader.visible = false;
        self.reader.projector.reset();
    }
};

fn appendMergedCommandSource(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    capability: ?*session_child_store.SessionChildCapability,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
) !bool {
    var order = try RecordOrderReader.init(alloc, capability, stored, walker.build_checkpoint);
    defer order.deinit(alloc);
    var generations = [2]StreamGenerationReader{
        try .init(alloc, capability, stored, .stdout, walker.build_checkpoint),
        try .init(alloc, capability, stored, .stderr, walker.build_checkpoint),
    };
    defer for (&generations) |*reader| reader.deinit(alloc);
    var projections = [2]StreamProjectionReader{
        try .init(alloc, capability, stored, .stdout, walker, styles),
        try .init(alloc, capability, stored, .stderr, walker, styles),
    };
    defer for (&projections) |*reader| reader.deinit(alloc);

    var record_ordinal: usize = 0;
    while (try order.nextRecord(alloc)) |stream| {
        const index = @intFromEnum(stream);
        const generation = try generations[index].nextRecord(alloc) orelse
            return error.CommandProjectionRecordMissing;
        const in_range = record_ordinal >= stored.start_record and
            (stored.end_record == null or record_ordinal < stored.end_record.?);
        const emit = generation.valid and in_range;
        projections[index].projectNext(alloc, generation, emit) catch |err| switch (err) {
            error.WindowFilled => return false,
            else => |other| return other,
        };
        if (generation.valid) record_ordinal += 1;
    }
    if (record_ordinal < stored.start_record) return error.CommandProjectionRecordMissing;
    if (stored.end_record) |end_record| {
        if (record_ordinal < end_record) return error.CommandProjectionRecordMissing;
    }
    return true;
}

const StoredResultSourceStream = struct {
    reader: StoredResultReader,
    range: StoredResultRange,
    offset: usize,
    terminal_safe: TerminalSafeIndentedWriter = .{},

    fn init(
        alloc: Allocator,
        capability: ?*session_child_store.SessionChildCapability,
        stored: StoredResult,
    ) !StoredResultSourceStream {
        var reader = try openStoredResultReader(alloc, capability, stored);
        errdefer reader.deinit();
        const range = try storedResultPresentationRange(alloc, &reader);
        return .{
            .reader = reader,
            .range = range,
            .offset = range.start,
            .terminal_safe = .{ .prefix = stored.line_prefix },
        };
    }

    fn deinit(self: *StoredResultSourceStream) void {
        self.reader.deinit();
        self.* = undefined;
    }

    fn hasMore(self: StoredResultSourceStream) bool {
        return self.offset < self.range.end;
    }

    fn readNextPage(
        self: *StoredResultSourceStream,
        alloc: Allocator,
    ) ![]u8 {
        std.debug.assert(self.hasMore());
        const page = try self.reader.readPage(
            alloc,
            self.offset,
            @min(result_store.full_read_chunk_bytes, self.range.end - self.offset),
        );
        errdefer alloc.free(page);
        if (page.len == 0) return error.UnexpectedEndOfResult;
        self.offset += page.len;
        return page;
    }

    fn appendPage(
        self: *StoredResultSourceStream,
        writer: *std.Io.Writer,
        page: []const u8,
    ) !void {
        try self.terminal_safe.append(writer, page);
    }

    fn appendTail(
        self: *StoredResultSourceStream,
        tail: *std.Io.Writer.Allocating,
    ) !void {
        try self.terminal_safe.finish(&tail.writer);
    }
};

fn storedResultPresentationRange(
    alloc: Allocator,
    reader: *StoredResultReader,
) !StoredResultRange {
    switch (reader.*) {
        .command_artifact => return .{ .start = 0, .end = reader.size() },
        .command_replay => return error.InvalidReplayPageRead,
        .tool_result, .command_result => {},
    }

    const probe_len = @min(reader.size(), result_store.read_default_bytes);
    const prefix = try reader.readPage(alloc, 0, probe_len);
    defer alloc.free(prefix);
    const start = contentEnvelopeStart(prefix) orelse return .{ .start = 0, .end = reader.size() };

    const suffix_len = @min(reader.size(), "</content>\n".len);
    const suffix_start = reader.size() - suffix_len;
    const suffix = try reader.readPage(alloc, suffix_start, suffix_len);
    defer alloc.free(suffix);
    if (!std.mem.endsWith(u8, suffix, "</content>")) return .{ .start = 0, .end = reader.size() };

    var suffix_end = suffix.len - "</content>".len;
    while (suffix_end > 0 and (suffix[suffix_end - 1] == '\n' or suffix[suffix_end - 1] == '\r')) {
        suffix_end -= 1;
    }
    const end = suffix_start + suffix_end;
    return if (end >= start) .{ .start = start, .end = end } else .{ .start = 0, .end = reader.size() };
}

fn contentEnvelopeStart(body: []const u8) ?usize {
    var start: usize = 0;
    if (std.mem.startsWith(u8, body, "<path>")) {
        const path_close = std.mem.find(u8, body, "</path>") orelse return null;
        start = path_close + "</path>".len;
        while (start < body.len and (body[start] == '\n' or body[start] == '\r')) : (start += 1) {}
    }
    if (!std.mem.startsWith(u8, body[start..], "<content>")) return null;
    start += "<content>".len;
    while (start < body.len and (body[start] == '\n' or body[start] == '\r')) : (start += 1) {}
    return start;
}

/// Writes terminal-safe tool detail while retaining LF as the line boundary.
/// Other controls still go through the shared terminal-safe encoder.
const TerminalSafeIndentedWriter = struct {
    encoder: text_utils.IncrementalTerminalSafeEncoder = .{},
    line_start: bool = true,
    prefix: []const u8 = "  ",
    line_suffix: []const u8 = "",

    fn append(
        self: *TerminalSafeIndentedWriter,
        writer: *std.Io.Writer,
        raw: []const u8,
    ) !void {
        var start: usize = 0;
        while (start < raw.len) {
            var separator = start;
            while (separator < raw.len and raw[separator] != '\n' and raw[separator] != '\t') : (separator += 1) {}
            if (separator == raw.len) break;

            try self.writePrefix(writer);
            try self.encoder.append(writer, raw[start..separator]);
            try self.encoder.finish(writer);
            if (raw[separator] == '\n') {
                try writer.writeAll(self.line_suffix);
                try writer.writeByte('\n');
                self.line_start = true;
            } else {
                try writer.writeAll("    ");
            }
            start = separator + 1;
        }
        if (start < raw.len) {
            try self.writePrefix(writer);
            try self.encoder.append(writer, raw[start..]);
        }
    }

    fn finish(self: *TerminalSafeIndentedWriter, writer: *std.Io.Writer) !void {
        if (!self.line_start) {
            try self.encoder.finish(writer);
            try writer.writeAll(self.line_suffix);
        }
    }

    fn writePrefix(self: *TerminalSafeIndentedWriter, writer: *std.Io.Writer) !void {
        if (!self.line_start) return;
        try writer.writeAll(self.prefix);
        self.line_start = false;
    }
};

fn appendStoredResultContent(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    capability: ?*session_child_store.SessionChildCapability,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
) !bool {
    if (stored.kind != .tool_result) {
        if (!try appendCommandStoredResultContent(
            alloc,
            walker,
            capability,
            styles,
            stored,
        )) return false;
        if (stored.required_replay_unavailable) {
            return appendPermanentCommandUnavailable(walker, styles);
        }
        return true;
    }
    var source = try StoredResultSourceStream.init(alloc, capability, stored);
    defer source.deinit();
    const styled_prefix = try styledSecondaryLinePrefix(alloc, styles, stored.line_prefix);
    defer alloc.free(styled_prefix);
    source.terminal_safe.prefix = styled_prefix;
    source.terminal_safe.line_suffix = styles.reset_style;
    while (source.hasMore()) {
        const page = try source.readNextPage(alloc);
        defer alloc.free(page);
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        defer encoded.deinit();
        try source.appendPage(&encoded.writer, page);
        if (!try walker.appendWithSoftWrapPrefix(encoded.written(), styled_prefix)) return false;
    }
    var tail: std.Io.Writer.Allocating = .init(alloc);
    defer tail.deinit();
    try source.appendTail(&tail);
    return walker.appendWithSoftWrapPrefix(tail.written(), styled_prefix);
}

fn styledSecondaryLinePrefix(
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    line_prefix: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeSecondaryLinePrefix(&out.writer, styles, line_prefix);
    return out.toOwnedSlice();
}

fn writeSecondaryLinePrefix(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
    line_prefix: []const u8,
) !void {
    if (std.mem.startsWith(u8, line_prefix, "│")) {
        try writer.writeAll(styles.reset_style);
        try writer.writeAll("│");
        try writer.writeAll(styles.dim_style);
        try writer.writeAll(line_prefix["│".len..]);
    } else {
        try writer.writeAll(styles.dim_style);
        try writer.writeAll(line_prefix);
    }
}

fn beginSecondaryRailLine(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
) !void {
    try writer.writeAll(styles.reset_style);
    try writer.writeAll("│");
    try writer.writeAll(styles.dim_style);
}

fn endSecondaryRailLine(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
) !void {
    try writer.writeAll(styles.reset_style);
    try writer.writeByte('\n');
}

fn writeSecondaryRailLine(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
    text: []const u8,
) !void {
    try beginSecondaryRailLine(writer, styles);
    try writer.writeAll(text);
    try endSecondaryRailLine(writer, styles);
}

fn writeSecondaryPrefixedLine(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
    prefix: []const u8,
    text: []const u8,
) !void {
    try writeSecondaryLinePrefix(writer, styles, prefix);
    try writer.writeAll(text);
    try writer.writeAll(styles.reset_style);
    try writer.writeByte('\n');
}

fn appendStoredResultFallback(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
) !bool {
    const styled_prefix = try styledSecondaryLinePrefix(alloc, styles, stored.line_prefix);
    defer alloc.free(styled_prefix);
    if (stored.required_replay_unavailable) {
        if (stored.retained_command_fallback) |retained| {
            if (!try walker.append(retained)) return false;
        } else {
            const fallback = try storedResultFallbackBytes(
                alloc,
                styles,
                stored,
                styled_prefix,
            );
            defer alloc.free(fallback);
            if (!try walker.appendWithSoftWrapPrefix(fallback, styled_prefix)) return false;
        }
        return appendPermanentCommandUnavailable(walker, styles);
    }
    const fallback = try storedResultFallbackBytes(
        alloc,
        styles,
        stored,
        styled_prefix,
    );
    defer alloc.free(fallback);
    if (!try walker.appendWithSoftWrapPrefix(fallback, styled_prefix)) return false;
    if (stored.retained_command_fallback) |retained| return walker.append(retained);
    return true;
}

fn appendSavedResultUnavailable(
    alloc: Allocator,
    walker: *ProjectionRowWalker,
    styles: transcript_blocks.Styles,
    line_prefix: []const u8,
) !bool {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try writeSecondaryPrefixedLine(
        &line.writer,
        styles,
        line_prefix,
        "Full saved result unavailable.",
    );
    return walker.append(line.written());
}

fn appendPermanentCommandUnavailable(
    walker: *ProjectionRowWalker,
    styles: transcript_blocks.Styles,
) !bool {
    if (!try walker.append(styles.reset_style)) return false;
    if (!try walker.append("│")) return false;
    if (!try walker.append(styles.dim_style)) return false;
    if (!try walker.append(" … full output unavailable")) return false;
    if (!try walker.append(styles.reset_style)) return false;
    return walker.append("\n");
}

fn openStoredResultReader(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    stored: StoredResult,
) !StoredResultReader {
    var reader: StoredResultReader = undefined;
    try openStoredResultReaderInto(&reader, alloc, capability, stored);
    return reader;
}

// noinline keeps the comptime-known error returns behind a call boundary;
// inlined into a `!StoredResultReader` result location they each materialize
// a union-sized (~8KB) error-union constant.
noinline fn openStoredResultReaderInto(
    out: *StoredResultReader,
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    stored: StoredResult,
) !void {
    const managed = capability orelse return error.ResultHandleUnavailable;
    switch (stored.kind) {
        .tool_result => out.* = .{ .tool_result = try result_store.openReaderManaged(alloc, managed, stored.handle) },
        .command_result => out.* = .{ .command_result = try result_store.openReaderManaged(alloc, managed, stored.handle) },
        .command_artifact => {
            var file = try managed.openFileReadOnly(alloc, .command_artifacts, stored.handle);
            errdefer file.deinit();
            const stat = try file.stat();
            const size = std.math.cast(usize, stat.size) orelse return error.ResultTooLarge;
            out.* = .{ .command_artifact = .{ .file = file, .size = size } };
        },
        .command_replay => out.* = .{ .command_replay = try command_replay_store.Reader.open(
            alloc,
            managed,
            .{ .handle = stored.handle, .framed_bytes = stored.framed_bytes },
        ) },
    }
}

fn activateStoredResultFallback(stored: *StoredResult, err: anyerror) bool {
    if (stored.kind == .command_replay) {
        stored.required_replay_unavailable = true;
        if (stored.fallback_artifact_handle) |artifact_handle| {
            debug_trace.logf(
                "full_transcript",
                "command_replay_unavailable handle_bytes={d} err={s}; using command artifact fallback",
                .{ stored.handle.len, @errorName(err) },
            );
            stored.kind = .command_artifact;
            stored.handle = artifact_handle;
            stored.fallback_artifact_handle = null;
            return true;
        }
        if (stored.fallback_handle) |result_handle| {
            debug_trace.logf(
                "full_transcript",
                "command_replay_unavailable handle_bytes={d} err={s}; using stored result fallback",
                .{ stored.handle.len, @errorName(err) },
            );
            stored.kind = .command_result;
            stored.handle = result_handle;
            stored.fallback_handle = null;
            return true;
        }
        return false;
    }
    if (stored.kind != .command_artifact) return false;
    const fallback_handle = stored.fallback_handle orelse return false;
    debug_trace.logf(
        "full_transcript",
        "command_artifact_unavailable handle_bytes={d} err={s}; using stored result fallback",
        .{ stored.handle.len, @errorName(err) },
    );
    stored.kind = .command_result;
    stored.handle = fallback_handle;
    stored.fallback_handle = null;
    return true;
}

const StoredResultDegradation = enum { retry, unavailable };

/// One-way (command artifact, then retained tool result, then unavailable),
/// which bounds the measurement retry and the render restart.
fn degradeStoredResult(stored: *StoredResult, err: anyerror) StoredResultDegradation {
    if (activateStoredResultFallback(stored, err)) return .retry;
    stored.unavailable = true;
    logStoredResultUnavailable(stored.handle, err);
    return .unavailable;
}

fn storedResultFallbackBytes(
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    stored: StoredResult,
    styled_prefix: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(styles.reset_style);
    var terminal_safe = TerminalSafeIndentedWriter{
        .prefix = styled_prefix,
        .line_suffix = styles.reset_style,
    };
    try terminal_safe.append(
        &out.writer,
        tool_result_display.contentForDisplay(stored.preview orelse ""),
    );
    try terminal_safe.finish(&out.writer);
    if (!terminal_safe.line_start) try out.writer.writeByte('\n');
    try writeSecondaryPrefixedLine(
        &out.writer,
        styles,
        stored.line_prefix,
        "Full saved result unavailable.",
    );
    return out.toOwnedSlice();
}

fn logStoredResultUnavailable(handle: []const u8, err: anyerror) void {
    debug_trace.logf(
        "full_transcript",
        "stored_result_unavailable handle_bytes={d} err={s}",
        .{ handle.len, @errorName(err) },
    );
}

/// Reads the selected Ctrl-O visual window as normal terminal source bytes.
/// The caller sends these bytes through the same prepared-transcript painter
/// that renders compact inline output; this helper never constructs a grid.
/// The window emits only rows the document reaches, so an offset at or past
/// the document end yields an empty window.
fn renderProjectionViewportSource(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    scroll_offset: u32,
) ![]u8 {
    return renderProjectionViewportSourceInterruptible(
        alloc,
        projection,
        capability,
        cols,
        visible_rows,
        scroll_offset,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn renderProjectionViewportSourceInterruptible(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    scroll_offset: u32,
    checkpoint: ?*BuildCheckpoint,
) ![]u8 {
    return renderProjectionViewportSourceWithSelection(
        alloc,
        projection,
        capability,
        cols,
        visible_rows,
        .{ .fixed_offset = scroll_offset },
        checkpoint,
        std.math.maxInt(usize),
    );
}

pub fn renderProjectionViewportSourceBoundedInterruptible(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    scroll_offset: u32,
    max_bytes: usize,
    checkpoint: ?*BuildCheckpoint,
) ![]u8 {
    return renderProjectionViewportSourceWithSelection(
        alloc,
        projection,
        capability,
        cols,
        visible_rows,
        .{ .fixed_offset = scroll_offset },
        checkpoint,
        max_bytes,
    );
}

/// Measures the projection, lets the selector pick the scroll offset against
/// that same-walk measurement, and reads the selected window. A stored segment
/// degrading during the window walk restarts the whole pipeline, so the
/// emitted window always matches the document the offset was selected for.
fn renderProjectionViewportSourceWithSelector(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    offset_selector: ViewportOffsetSelector,
) ![]u8 {
    return renderProjectionViewportSourceWithSelectorInterruptible(
        alloc,
        projection,
        capability,
        cols,
        visible_rows,
        offset_selector,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn renderProjectionViewportSourceWithSelectorInterruptible(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    offset_selector: ViewportOffsetSelector,
    checkpoint: ?*BuildCheckpoint,
) ![]u8 {
    return renderProjectionViewportSourceWithSelection(
        alloc,
        projection,
        capability,
        cols,
        visible_rows,
        .{ .selector = offset_selector },
        checkpoint,
        std.math.maxInt(usize),
    );
}

const ViewportSelection = union(enum) {
    fixed_offset: u32,
    selector: ViewportOffsetSelector,
};

fn renderProjectionViewportSourceWithSelection(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    selection: ViewportSelection,
    checkpoint: ?*BuildCheckpoint,
    max_bytes: usize,
) ![]u8 {
    if (cols == 0 or visible_rows == 0) return error.InvalidViewport;
    while (true) {
        const offset = switch (selection) {
            .fixed_offset => |fixed_offset| fixed_offset,
            .selector => |selector| blk: {
                const measurement = try measureProjectionInterruptible(
                    alloc,
                    projection,
                    capability,
                    cols,
                    checkpoint,
                );
                break :blk selector.select_offset(selector.context, measurement, visible_rows);
            },
        };
        return renderProjectionWindow(alloc, projection, capability, cols, visible_rows, offset, checkpoint, max_bytes) catch |err| switch (err) {
            error.StoredSegmentDegraded => continue,
            else => |other| return other,
        };
    }
}

fn renderProjectionWindow(
    alloc: Allocator,
    projection: *Projection,
    capability: ?*session_child_store.SessionChildCapability,
    cols: u16,
    visible_rows: u16,
    scroll_offset: u32,
    checkpoint: ?*BuildCheckpoint,
    max_bytes: usize,
) ![]u8 {
    const start = projection.windowStart(cols, scroll_offset);
    debug_trace.logf(
        "full_transcript_cache",
        "window cols={d} offset={d} visible={d} segments={d} checkpoints={d} start_segment={d} start_row={d}",
        .{
            cols,
            scroll_offset,
            visible_rows,
            projection.segments.items.len,
            projection.measured_segment_checkpoints.items.len,
            start.segment_index,
            start.checkpoint.row,
        },
    );
    var walker = ProjectionRowWalker.initWindowAt(
        alloc,
        cols,
        scroll_offset,
        visible_rows,
        start.checkpoint,
        checkpoint,
    );
    defer walker.deinit();
    walker.max_output_bytes = max_bytes;
    _ = try walkProjectionSegments(
        alloc,
        projection,
        capability,
        &walker,
        start.segment_index,
        0,
        null,
        null,
    );
    return walker.toOwnedSlice();
}

const LifecycleContext = struct {
    pub fn hash(_: LifecycleContext, id: types.ToolLifecycleId) u64 {
        return std.hash.Wyhash.hash(id.turn_id, id.call_id);
    }

    pub fn eql(_: LifecycleContext, lhs: types.ToolLifecycleId, rhs: types.ToolLifecycleId) bool {
        return lhs.turn_id == rhs.turn_id and std.mem.eql(u8, lhs.call_id, rhs.call_id);
    }
};

const CommandLifecycleIndex = std.HashMapUnmanaged(
    types.ToolLifecycleId,
    usize,
    LifecycleContext,
    std.hash_map.default_max_load_percentage,
);

const SourceEntryAssociation = struct {
    detail_index: ?usize = null,
    command_block_index: ?usize = null,
    command_source_owned: bool = false,
};

const ProjectionSourceIndex = struct {
    details: []const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    by_entry: std.AutoHashMapUnmanaged(u32, SourceEntryAssociation) = .empty,
    command_by_lifecycle: CommandLifecycleIndex = .empty,
    detail_by_command_block: []?usize,

    fn build(
        alloc: Allocator,
        details: []const ToolDetailRecord,
        command_blocks: []const command_output_runtime.CommandOutputBlock,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !ProjectionSourceIndex {
        const detail_by_command_block = try alloc.alloc(?usize, command_blocks.len);
        @memset(detail_by_command_block, null);
        var index = ProjectionSourceIndex{
            .details = details,
            .command_blocks = command_blocks,
            .detail_by_command_block = detail_by_command_block,
        };
        errdefer index.deinit(alloc);

        for (command_blocks, 0..) |block, block_index| {
            try build_checkpoint.tick(checkpoint);
            if (block.lifecycle_id) |lifecycle_id| {
                const result = try index.command_by_lifecycle.getOrPut(alloc, lifecycle_id);
                if (!result.found_existing) result.value_ptr.* = block_index;
            }
            if (block.entry_id) |entry_id| try index.addCommandEntry(alloc, entry_id, block_index);
            for (block.pruned_ranges.items) |range| {
                try build_checkpoint.tick(checkpoint);
                try index.addCommandEntry(alloc, range.anchor_entry_id, block_index);
            }
            for (block.live_entry_ids.items) |entry_id| {
                try build_checkpoint.tick(checkpoint);
                try index.addCommandEntry(alloc, entry_id, block_index);
            }
            for (block.source_entry_ids.items) |entry_id| {
                try build_checkpoint.tick(checkpoint);
                try index.addCommandEntry(alloc, entry_id, block_index);
            }
        }

        for (details, 0..) |*detail, detail_index| {
            try build_checkpoint.tick(checkpoint);
            const association = try index.entryAssociation(alloc, detail.entry_id);
            if (association.detail_index == null) association.detail_index = detail_index;

            const block_index = index.commandBlockIndexForDetail(detail);
            if (block_index) |value| {
                if (index.detail_by_command_block[value] == null) {
                    index.detail_by_command_block[value] = detail_index;
                }
            }

            const has_stored_result = storedResultForDetail(detail) != null;
            if (detail.command_output_entry_id) |entry_id| {
                const output_block_index = index.commandBlockIndexForEntry(entry_id);
                if (output_block_index == null or
                    commandSourceIsOwned(detail, command_blocks[output_block_index.?], has_stored_result))
                {
                    try index.markCommandSourceOwned(alloc, entry_id);
                }
            }
            if (block_index) |value| {
                const block = command_blocks[value];
                if (!commandSourceIsOwned(detail, block, has_stored_result)) continue;
                for (block.source_entry_ids.items) |entry_id| {
                    try build_checkpoint.tick(checkpoint);
                    try index.markCommandSourceOwned(alloc, entry_id);
                }
                for (block.live_entry_ids.items) |entry_id| {
                    try build_checkpoint.tick(checkpoint);
                    try index.markCommandSourceOwned(alloc, entry_id);
                }
            }
        }
        return index;
    }

    fn deinit(self: *ProjectionSourceIndex, alloc: Allocator) void {
        alloc.free(self.detail_by_command_block);
        self.command_by_lifecycle.deinit(alloc);
        self.by_entry.deinit(alloc);
        self.* = undefined;
    }

    fn entryAssociation(
        self: *ProjectionSourceIndex,
        alloc: Allocator,
        entry_id: u32,
    ) !*SourceEntryAssociation {
        const result = try self.by_entry.getOrPut(alloc, entry_id);
        if (!result.found_existing) result.value_ptr.* = .{};
        return result.value_ptr;
    }

    fn addCommandEntry(
        self: *ProjectionSourceIndex,
        alloc: Allocator,
        entry_id: u32,
        block_index: usize,
    ) !void {
        const association = try self.entryAssociation(alloc, entry_id);
        if (association.command_block_index == null) association.command_block_index = block_index;
    }

    fn markCommandSourceOwned(
        self: *ProjectionSourceIndex,
        alloc: Allocator,
        entry_id: u32,
    ) !void {
        const association = try self.entryAssociation(alloc, entry_id);
        association.command_source_owned = true;
    }

    fn detailForEntry(self: *const ProjectionSourceIndex, entry_id: u32) ?*const ToolDetailRecord {
        const detail_index = (self.by_entry.get(entry_id) orelse return null).detail_index orelse return null;
        return &self.details[detail_index];
    }

    fn commandBlockIndexForEntry(self: *const ProjectionSourceIndex, entry_id: u32) ?usize {
        return (self.by_entry.get(entry_id) orelse return null).command_block_index;
    }

    fn renderableCommandBlockIndexForEntry(self: *const ProjectionSourceIndex, entry_id: u32) ?usize {
        const block_index = self.commandBlockIndexForEntry(entry_id) orelse return null;
        const block = self.command_blocks[block_index];
        return if (block.canReconstructEntries() or block.retention_overflow) block_index else null;
    }

    fn commandBlockIndexForLifecycle(
        self: *const ProjectionSourceIndex,
        lifecycle_id: types.ToolLifecycleId,
    ) ?usize {
        return self.command_by_lifecycle.get(lifecycle_id);
    }

    fn commandBlockIndexForDetail(
        self: *const ProjectionSourceIndex,
        detail: *const ToolDetailRecord,
    ) ?usize {
        if (detail.command_output_entry_id) |entry_id| {
            if (self.commandBlockIndexForEntry(entry_id)) |block_index| return block_index;
        }
        const lifecycle_id = detail.lifecycle_id orelse return null;
        return self.commandBlockIndexForLifecycle(lifecycle_id);
    }

    fn detailForCommandBlock(
        self: *const ProjectionSourceIndex,
        block_index: usize,
    ) ?*const ToolDetailRecord {
        const detail_index = self.detail_by_command_block[block_index] orelse return null;
        return &self.details[detail_index];
    }

    fn commandSourceOwned(self: *const ProjectionSourceIndex, entry_id: u32) bool {
        return (self.by_entry.get(entry_id) orelse return false).command_source_owned;
    }
};

fn commandSourceIsOwned(
    detail: *const ToolDetailRecord,
    block: command_output_runtime.CommandOutputBlock,
    has_stored_result: bool,
) bool {
    return block.canReconstructEntries() or
        has_stored_result or
        isActivePartialCommand(detail, block);
}

const ProjectionComposeContext = struct {
    alloc: Allocator,
    builder: *ProjectionBuilder,
    entries: []const transcript_blocks.TranscriptEntry,
    source_index: *const ProjectionSourceIndex,
    entry_actions: []const transcript_blocks.EntryRenderAction,
    anchor_entry_id: ?u32,
    emitted_command_blocks: []bool,
    full_diff_resolver: ?FullDiffResolver,
    cols: u16,
    entry_index: usize = 0,
    checkpoint: ?*BuildCheckpoint,

    fn fromOpaque(context: *anyopaque) *ProjectionComposeContext {
        return @ptrCast(@alignCast(context));
    }

    fn skipEntry(
        context: *anyopaque,
        entry: transcript_blocks.TranscriptEntry,
        entry_index: usize,
    ) bool {
        const self = fromOpaque(context);
        self.entry_index = entry_index;
        if (self.entryAction(entry) == .hide) return true;
        if (self.source_index.renderableCommandBlockIndexForEntry(entry.id()) != null) return false;
        if (self.source_index.commandSourceOwned(entry.id())) return true;
        return false;
    }

    fn overrideKind(context: *anyopaque, entry: transcript_blocks.TranscriptEntry) ?transcript_blocks.TranscriptBlockKind {
        const self = fromOpaque(context);
        if (self.diffForEntry(entry) != null) return .diff_block;
        if (self.source_index.renderableCommandBlockIndexForEntry(entry.id()) != null) return .command_output;
        return switch (self.entryAction(entry)) {
            .override => |value| value.kind,
            .keep, .hide => null,
        };
    }

    fn appendOverride(
        context: *anyopaque,
        entry: transcript_blocks.TranscriptEntry,
        out: *std.Io.Writer.Allocating,
    ) !bool {
        const self = fromOpaque(context);
        if (self.diffForEntry(entry)) |diff| {
            const reflowed = try transcript_blocks.reflowDiffBlock(self.alloc, diff, self.cols);
            defer self.alloc.free(reflowed);
            try out.writer.writeAll(reflowed);
            return std.mem.endsWith(u8, reflowed, "\n");
        }
        if (self.source_index.renderableCommandBlockIndexForEntry(entry.id())) |index| {
            return appendCommandBlockAtEntry(self, out, index, entry.id());
        }
        return switch (self.entryAction(entry)) {
            .override => |value| blk: {
                try out.writer.writeAll(value.bytes);
                break :blk std.mem.endsWith(u8, value.bytes, "\n");
            },
            .keep, .hide => false,
        };
    }

    fn beforeEntry(
        context: *anyopaque,
        entry_id: u32,
        out: *std.Io.Writer.Allocating,
    ) !void {
        const self = fromOpaque(context);
        try self.builder.markEntry(entry_id);
        const entry = self.entries[self.entry_index];
        std.debug.assert(entry.id() == entry_id);
        if (metadataKind(entry)) |kind| {
            var header_buf: [80]u8 = undefined;
            if (full_transcript_metadata.formatHeader(
                &header_buf,
                self.metadataCreatedAtMs(entry),
                kind,
            )) |header| {
                try out.writer.writeAll(self.builder.styles().dim_style);
                try out.writer.writeAll("  ");
                try out.writer.writeAll(header);
                try out.writer.writeAll(self.builder.styles().reset_style);
                try out.writer.writeByte('\n');
            }
        }
        if (self.anchor_entry_id != null and self.anchor_entry_id.? == entry_id) {
            try self.builder.markAnchor();
        }
    }

    fn metadataCreatedAtMs(
        self: *const ProjectionComposeContext,
        entry: transcript_blocks.TranscriptEntry,
    ) i64 {
        switch (entry) {
            .raw_bytes => |raw| if (raw.class == .tool_status) {
                if (self.source_index.detailForEntry(entry.id())) |detail| {
                    if (detail.created_at_ms > 0) return detail.created_at_ms;
                }
            },
            else => {},
        }
        return entry.createdAtMs();
    }

    fn appendDetail(
        context: *anyopaque,
        entry_id: u32,
        out: *std.Io.Writer.Allocating,
    ) !transcript_blocks.FullDetailAppend {
        const self = fromOpaque(context);
        const detail = self.source_index.detailForEntry(entry_id) orelse return .{};
        return appendDetailContent(
            out,
            self.builder,
            self.entries,
            detail,
            self.source_index,
            self.full_diff_resolver,
            self.checkpoint,
        );
    }

    fn entryAction(self: *const ProjectionComposeContext, entry: transcript_blocks.TranscriptEntry) transcript_blocks.EntryRenderAction {
        std.debug.assert(self.entries[self.entry_index].id() == entry.id());
        return self.entry_actions[self.entry_index];
    }

    fn diffForEntry(
        self: *const ProjectionComposeContext,
        entry: transcript_blocks.TranscriptEntry,
    ) ?[]const u8 {
        if (self.fullDiffForEntry(entry)) |full| return full;
        const raw = switch (entry) {
            .raw_bytes => |value| value,
            else => return null,
        };
        if (raw.class != .diff_block) return null;
        return markedDiffContent(raw.bytes) orelse raw.bytes;
    }

    fn fullDiffForEntry(
        self: *const ProjectionComposeContext,
        entry: transcript_blocks.TranscriptEntry,
    ) ?[]const u8 {
        const resolver = self.full_diff_resolver orelse return null;
        const raw = switch (entry) {
            .raw_bytes => |value| value,
            else => return null,
        };
        if (raw.class != .diff_block) return null;
        const id = diff_mod.markedDiffBlockId(raw.bytes) orelse return null;
        return resolver.full_for_marker(resolver.context, id);
    }
};

fn metadataKind(
    entry: transcript_blocks.TranscriptEntry,
) ?full_transcript_metadata.Kind {
    return switch (entry) {
        .user_turn => |user| if (std.mem.startsWith(
            u8,
            std.mem.trimStart(u8, user.turn.text, " \t\r\n"),
            "/issue",
        ))
            .issue
        else
            .prompt,
        .assistant_turn => .response,
        .semantic_notice => |notice| if (notice.tone == .@"error")
            .error_notice
        else
            .notice,
        .raw_bytes => |raw| switch (raw.class) {
            .tool_status => .tool,
            .subagent_status => .task,
            .turn_summary => .usage,
            else => null,
        },
        .assistant_table,
        .assistant_code_block,
        .assistant_thematic_rule,
        => null,
    };
}

fn markedDiffContent(bytes: []const u8) ?[]const u8 {
    _ = diff_mod.markedDiffBlockId(bytes) orelse return null;
    const start_marker_end = std.mem.indexOfScalarPos(
        u8,
        bytes,
        diff_mod.diff_block_start_prefix.len,
        0x07,
    ) orelse return null;
    const content_start = start_marker_end + 1;
    const content_end = std.mem.lastIndexOf(u8, bytes, diff_mod.diff_block_end_prefix) orelse
        return null;
    if (content_end < content_start) return null;
    return bytes[content_start..content_end];
}

fn isCapturedCommandDetail(detail: *const ToolDetailRecord) bool {
    return detail.isCapturedCommand();
}

fn isActivePartialCommand(
    detail: *const ToolDetailRecord,
    block: command_output_runtime.CommandOutputBlock,
) bool {
    return isCapturedCommandDetail(detail) and
        detail.outcome == null and
        storedResultForDetail(detail) == null and
        block.retention_overflow;
}

fn commandLineEntryId(
    block: command_output_runtime.CommandOutputBlock,
    line_index: usize,
) ?u32 {
    const line = block.lines.items[line_index];
    if (line.entry_id) |entry_id| return entry_id;
    if (line_index < block.source_entry_ids.items.len) return block.source_entry_ids.items[line_index];
    if (line_index < block.live_entry_ids.items.len) return block.live_entry_ids.items[line_index];
    return block.entry_id;
}

fn commandLineRecordOrdinal(
    block: command_output_runtime.CommandOutputBlock,
    line_index: usize,
) usize {
    const ordinal = block.lines.items[line_index].record_ordinal;
    // Hand-built legacy/test blocks predate explicit ordinals and leave every
    // line at the default zero. Runtime-ingested records are strictly ordered.
    if (line_index > 0 and ordinal == 0) return line_index;
    return ordinal;
}

fn commandDeferredAnchorEntryId(
    block: command_output_runtime.CommandOutputBlock,
) ?u32 {
    var best_end: usize = 0;
    var best_entry_id: ?u32 = null;
    for (block.lines.items, 0..) |_, line_index| {
        const entry_id = commandLineEntryId(block, line_index) orelse continue;
        const record_end = commandLineRecordOrdinal(block, line_index) +| 1;
        if (best_entry_id == null or record_end >= best_end) {
            best_end = record_end;
            best_entry_id = entry_id;
        }
    }
    for (block.pruned_ranges.items) |range| {
        if (best_entry_id == null or range.end_record >= best_end) {
            best_end = range.end_record;
            best_entry_id = range.anchor_entry_id;
        }
    }
    if (best_entry_id) |entry_id| return entry_id;
    if (block.source_entry_ids.items.len > 0) return block.source_entry_ids.items[block.source_entry_ids.items.len - 1];
    if (block.live_entry_ids.items.len > 0) return block.live_entry_ids.items[block.live_entry_ids.items.len - 1];
    return block.entry_id;
}

fn stableCommandRecordCount(block: command_output_runtime.CommandOutputBlock) usize {
    if (!block.retention_overflow) return block.lines.items.len;
    return @min(
        block.overflow_line_index orelse block.lines.items.len,
        block.lines.items.len,
    );
}

fn appendDeferredCommandRange(
    context: *ProjectionComposeContext,
    out: *std.Io.Writer.Allocating,
    detail: *const ToolDetailRecord,
    start_record: usize,
    end_record: usize,
) !bool {
    if (start_record >= end_record) return true;
    const styles = context.builder.styles();
    if (storedResultForDetail(detail)) |stored_value| {
        var stored = stored_value;
        stored.start_record = start_record;
        stored.end_record = end_record;
        stored.retained_command_fallback = try context.alloc.alloc(u8, 0);
        try context.builder.appendStoredResult(stored);
        return true;
    }
    if (detail.result) |result| {
        const parsed = try appendInlineCommandResultRange(
            &out.writer,
            context.alloc,
            styles,
            result,
            context.cols,
            start_record,
            end_record,
        );
        if (parsed) return true;
    }
    try appendPermanentCommandUnavailableToWriter(&out.writer, styles);
    return true;
}

fn terminalStoredCommandSource(detail: *const ToolDetailRecord) ?StoredResult {
    const stored = storedResultForDetail(detail) orelse return null;
    if (stored.kind == .tool_result or stored.handle.len == 0) return null;
    return stored;
}

fn appendOpenEndedStoredCommandTail(
    context: *ProjectionComposeContext,
    stored_value: StoredResult,
    start_record: usize,
) !void {
    var stored = stored_value;
    stored.start_record = start_record;
    stored.end_record = null;
    stored.retained_command_fallback = try context.alloc.alloc(u8, 0);
    try context.builder.appendStoredResult(stored);
}

fn prunedRangeCoveringRecord(
    block: command_output_runtime.CommandOutputBlock,
    record_ordinal: usize,
) ?command_output_runtime.CommandOutputPrunedRange {
    for (block.pruned_ranges.items) |range| {
        if (record_ordinal >= range.start_record and
            record_ordinal < range.end_record) return range;
    }
    return null;
}

fn nextPrunedRangeStart(
    block: command_output_runtime.CommandOutputBlock,
    start_record: usize,
    end_record: usize,
) ?usize {
    var next: ?usize = null;
    for (block.pruned_ranges.items) |range| {
        if (range.start_record <= start_record or range.start_record >= end_record) continue;
        next = if (next) |current| @min(current, range.start_record) else range.start_record;
    }
    return next;
}

fn appendDeferredCommandGap(
    context: *ProjectionComposeContext,
    out: *std.Io.Writer.Allocating,
    detail: *const ToolDetailRecord,
    block: command_output_runtime.CommandOutputBlock,
    start_record: usize,
    end_record: usize,
) !bool {
    var cursor = start_record;
    var ends_with_newline = true;
    while (cursor < end_record) {
        if (prunedRangeCoveringRecord(block, cursor)) |range| {
            cursor = @min(range.end_record, end_record);
            continue;
        }
        const next_range = nextPrunedRangeStart(block, cursor, end_record) orelse end_record;
        ends_with_newline = try appendDeferredCommandRange(
            context,
            out,
            detail,
            cursor,
            next_range,
        );
        cursor = next_range;
    }
    return ends_with_newline;
}

fn representedCommandRecordEnd(
    block: command_output_runtime.CommandOutputBlock,
    stable_count: usize,
) usize {
    var end_record: usize = 0;
    for (block.lines.items[0..stable_count], 0..) |_, line_index| {
        end_record = @max(end_record, commandLineRecordOrdinal(block, line_index) +| 1);
    }
    for (block.pruned_ranges.items) |range| {
        end_record = @max(end_record, range.end_record);
    }
    return end_record;
}

fn appendCommandBlockAtEntry(
    context: *ProjectionComposeContext,
    out: *std.Io.Writer.Allocating,
    block_index: usize,
    entry_id: u32,
) !bool {
    const block = context.source_index.command_blocks[block_index];
    const styles = context.builder.styles();
    const detail = context.source_index.detailForCommandBlock(block_index);
    const active_partial = if (detail) |command_detail|
        isActivePartialCommand(command_detail, block)
    else
        false;
    const terminal_source = if (detail) |command_detail|
        !active_partial and
            (storedResultForDetail(command_detail) != null or command_detail.result != null)
    else
        false;
    const stored_terminal_source = if (detail) |command_detail|
        if (!active_partial) terminalStoredCommandSource(command_detail) else null
    else
        null;
    var ends_with_newline = false;
    if (terminal_source) {
        for (block.pruned_ranges.items) |range| {
            if (range.anchor_entry_id != entry_id) continue;
            ends_with_newline = try appendDeferredCommandRange(
                context,
                out,
                detail.?,
                range.start_record,
                range.end_record,
            );
        }
    }
    const stable_count = stableCommandRecordCount(block);
    for (block.lines.items[0..stable_count], 0..) |line, line_index| {
        if (!line.visible) continue;
        if (commandLineEntryId(block, line_index) != entry_id) continue;
        const prior_ordinal = if (line_index == 0)
            0
        else
            commandLineRecordOrdinal(block, line_index - 1) +| 1;
        const record_ordinal = commandLineRecordOrdinal(block, line_index);
        if (record_ordinal < prior_ordinal) return error.CommandProjectionOrdinalMismatch;
        if (terminal_source and record_ordinal > prior_ordinal) {
            ends_with_newline = try appendDeferredCommandGap(
                context,
                out,
                detail.?,
                block,
                prior_ordinal,
                record_ordinal,
            );
        }
        const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            context.alloc,
            styles,
            line.text,
            context.cols,
        );
        defer context.alloc.free(rendered);
        try out.writer.writeAll(rendered);
        ends_with_newline = std.mem.endsWith(u8, rendered, "\n");
    }

    const anchor_entry_id = commandDeferredAnchorEntryId(block) orelse return ends_with_newline;
    if (anchor_entry_id != entry_id or context.emitted_command_blocks[block_index]) {
        return ends_with_newline;
    }
    context.emitted_command_blocks[block_index] = true;
    if (detail) |command_detail| {
        if (active_partial) {
            try writeSecondaryRailLine(
                &out.writer,
                styles,
                " … full output available when command finishes",
            );
            ends_with_newline = true;
        } else {
            if (block.retention_overflow) {
                const suffix_start = representedCommandRecordEnd(block, stable_count);
                if (suffix_start < block.total_lines) {
                    ends_with_newline = try appendDeferredCommandGap(
                        context,
                        out,
                        command_detail,
                        block,
                        suffix_start,
                        block.total_lines,
                    );
                }
            }
            if (stored_terminal_source) |stored| {
                try appendOpenEndedStoredCommandTail(
                    context,
                    stored,
                    block.total_lines,
                );
                ends_with_newline = true;
            }
        }
        if (command_detail.command_process_presentation) |presentation| {
            try appendCommandProcessPresentation(
                &out.writer,
                context.alloc,
                styles,
                presentation,
                context.cols,
            );
            ends_with_newline = true;
        }
    }
    return ends_with_newline;
}

fn appendCommandBlock(
    writer: *std.Io.Writer,
    alloc: Allocator,
    block: command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
) !bool {
    var ends_with_newline = false;
    for (block.lines.items) |line| {
        if (!line.visible) continue;
        const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            alloc,
            styles,
            line.text,
            cols,
        );
        defer alloc.free(rendered);
        try writer.writeAll(rendered);
        ends_with_newline = std.mem.endsWith(u8, rendered, "\n");
    }
    return ends_with_newline;
}

fn appendStableActiveCommandPrefix(
    writer: *std.Io.Writer,
    alloc: Allocator,
    block: command_output_runtime.CommandOutputBlock,
    styles: transcript_blocks.Styles,
    cols: u16,
) !void {
    const stable_end = @min(block.overflow_line_index orelse block.lines.items.len, block.lines.items.len);
    for (block.lines.items[0..stable_end]) |line| {
        if (!line.visible) continue;
        const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
            alloc,
            styles,
            line.text,
            cols,
        );
        defer alloc.free(rendered);
        try writer.writeAll(rendered);
    }
    try writeSecondaryRailLine(
        writer,
        styles,
        " … full output available when command finishes",
    );
}

fn appendRetainedCommandEntries(
    writer: *std.Io.Writer,
    entries: []const transcript_blocks.TranscriptEntry,
    block: command_output_runtime.CommandOutputBlock,
) !bool {
    var ends_with_newline = false;
    for (entries) |entry| {
        const raw = switch (entry) {
            .raw_bytes => |value| value,
            else => continue,
        };
        if (!command_output_runtime.commandBlockOwnsEntry(block, raw.id)) continue;
        try writer.writeAll(raw.bytes);
        ends_with_newline = std.mem.endsWith(u8, raw.bytes, "\n");
    }
    return ends_with_newline;
}

fn storedResultForDetail(detail: *const ToolDetailRecord) ?StoredResult {
    if (detail.command_output_replay) |replay| switch (replay) {
        .available => |descriptor| return .{
            .kind = .command_replay,
            .handle = descriptor.handle,
            .framed_bytes = descriptor.framed_bytes,
            .preview = detail.result,
            .fallback_artifact_handle = detail.command_artifact_handle,
            .fallback_handle = detail.result_handle,
        },
        .unavailable => {
            if (detail.command_artifact_handle) |handle| {
                return .{
                    .kind = .command_artifact,
                    .handle = handle,
                    .preview = detail.result,
                    .fallback_handle = detail.result_handle,
                    .required_replay_unavailable = true,
                };
            }
            if (detail.result_handle) |handle| {
                return .{
                    .kind = .command_result,
                    .handle = handle,
                    .preview = detail.result,
                    .required_replay_unavailable = true,
                };
            }
            return .{
                .kind = .command_replay,
                .handle = "",
                .preview = detail.result,
                .unavailable = true,
                .required_replay_unavailable = true,
            };
        },
    };
    if (detail.command_artifact_handle) |handle| {
        return .{
            .kind = .command_artifact,
            .handle = handle,
            .preview = detail.result,
            .fallback_handle = detail.result_handle,
        };
    }
    if (detail.result_handle) |handle| {
        return .{
            .kind = if (isCapturedCommandDetail(detail)) .command_result else .tool_result,
            .handle = handle,
            .preview = detail.result,
        };
    }
    return null;
}

fn transcriptHasEntry(
    entries: []const transcript_blocks.TranscriptEntry,
    entry_id: u32,
) bool {
    for (entries) |entry| {
        if (entry.id() == entry_id) return true;
    }
    return false;
}

fn appendTerminalSafeToolOutput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    raw: []const u8,
    cols: u16,
) !void {
    return appendTerminalSafeToolOutputInterruptible(
        writer,
        alloc,
        styles,
        raw,
        cols,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn appendTerminalSafeToolOutputInterruptible(
    writer: *std.Io.Writer,
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    raw: []const u8,
    cols: u16,
    checkpoint: ?*BuildCheckpoint,
) !void {
    if (raw.len == 0) return;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    var encoder = TerminalSafeIndentedWriter{ .prefix = "" };
    try encoder.append(&encoded.writer, raw);
    try encoder.finish(&encoded.writer);

    const bytes = encoded.written();
    const ends_with_newline = std.mem.endsWith(u8, bytes, "\n");
    const wrap_source = bytes[0 .. bytes.len - @intFromBool(ends_with_newline)];
    const wrapped = try assistant_wrap.wrapLiteralToolOutputInterruptible(
        alloc,
        wrap_source,
        cols,
        checkpoint,
    );
    defer alloc.free(wrapped);
    var row_start: usize = 0;
    while (row_start < wrapped.len) {
        const newline_offset = std.mem.findScalar(u8, wrapped[row_start..], '\n');
        const row_end = if (newline_offset) |offset| row_start + offset else wrapped.len;
        const row = wrapped[row_start..row_end];
        if (std.mem.startsWith(u8, row, "│")) {
            try writer.writeAll(styles.reset_style);
            try writer.writeAll("│");
            try writer.writeAll(styles.dim_style);
            try writer.writeAll(row["│".len..]);
        } else {
            try writer.writeAll(styles.dim_style);
            try writer.writeAll(row);
        }
        try writer.writeAll(styles.reset_style);
        if (newline_offset == null) break;
        try writer.writeByte('\n');
        row_start = row_end + 1;
    }
    if (wrapped.len > 0 or ends_with_newline) try writer.writeByte('\n');
}

fn argumentVisibleInToolHeading(
    entries: []const transcript_blocks.TranscriptEntry,
    entry_id: u32,
    value: []const u8,
    cols: u16,
) bool {
    if (value.len == 0) return false;
    for (entries) |entry| {
        if (entry.id() != entry_id) continue;
        const raw = switch (entry) {
            .raw_bytes => |candidate| candidate,
            else => return false,
        };
        if (raw.class != .tool_status or std.mem.find(u8, raw.bytes, value) == null) return false;
        return display_width.visibleWidthIgnoringAnsi(raw.bytes) <= cols;
    }
    return false;
}

fn appendFullSemanticArguments(
    writer: *std.Io.Writer,
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    detail: *const ToolDetailRecord,
    styles: transcript_blocks.Styles,
    cols: u16,
    checkpoint: ?*BuildCheckpoint,
) !bool {
    const arguments_json = detail.arguments_json orelse return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch {
        var fallback: std.Io.Writer.Allocating = .init(alloc);
        defer fallback.deinit();
        try fallback.writer.writeAll("arguments: ");
        try fallback.writer.writeAll(arguments_json);
        try appendTerminalSafeToolOutputInterruptible(
            writer,
            alloc,
            styles,
            fallback.written(),
            cols,
            checkpoint,
        );
        return arguments_json.len > 0;
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => {
            var fallback: std.Io.Writer.Allocating = .init(alloc);
            defer fallback.deinit();
            try fallback.writer.writeAll("arguments: ");
            try std.json.Stringify.value(parsed.value, .{}, &fallback.writer);
            try appendTerminalSafeToolOutputInterruptible(
                writer,
                alloc,
                styles,
                fallback.written(),
                cols,
                checkpoint,
            );
            return true;
        },
    };

    var appended = false;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const value = entry.value_ptr.*;
        if (isCapturedCommandDetail(detail) and
            std.mem.eql(u8, entry.key_ptr.*, "action") and
            value == .string and
            std.mem.eql(u8, value.string, "exec")) continue;
        if (value == .string and argumentVisibleInToolHeading(
            entries,
            detail.entry_id,
            value.string,
            cols,
        )) continue;

        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try line.writer.print("{s}: ", .{entry.key_ptr.*});
        switch (value) {
            .string => |text| try line.writer.writeAll(text),
            else => try std.json.Stringify.value(value, .{}, &line.writer),
        }
        try appendTerminalSafeToolOutputInterruptible(
            writer,
            alloc,
            styles,
            line.written(),
            cols,
            checkpoint,
        );
        appended = true;
    }
    return appended;
}

fn detailHasAdjacentFullDiff(
    entries: []const transcript_blocks.TranscriptEntry,
    entry_id: u32,
    resolver: FullDiffResolver,
) bool {
    var found_detail = false;
    for (entries) |entry| {
        if (!found_detail) {
            found_detail = entry.id() == entry_id;
            continue;
        }
        const raw = switch (entry) {
            .raw_bytes => |candidate| candidate,
            else => return false,
        };
        if (raw.class != .diff_block) return false;
        const id = diff_mod.markedDiffBlockId(raw.bytes) orelse return false;
        return resolver.full_for_marker(resolver.context, id) != null;
    }
    return false;
}

fn appendDetailContent(
    out: *std.Io.Writer.Allocating,
    builder: *ProjectionBuilder,
    entries: []const transcript_blocks.TranscriptEntry,
    detail: *const ToolDetailRecord,
    source_index: *const ProjectionSourceIndex,
    full_diff_resolver: ?FullDiffResolver,
    checkpoint: ?*BuildCheckpoint,
) !transcript_blocks.FullDetailAppend {
    const alloc = builder.alloc;
    const styles = builder.styles();
    const command_blocks = source_index.command_blocks;
    const owned_command_block_index = source_index.commandBlockIndexForDetail(detail);
    const command_block_index = if (owned_command_block_index) |block_index|
        if (command_blocks[block_index].canReconstructEntries()) block_index else null
    else
        null;
    const deferred_command_source = if (owned_command_block_index) |block_index| blk: {
        const block = command_blocks[block_index];
        break :blk (block.canReconstructEntries() or block.retention_overflow) and
            if (commandDeferredAnchorEntryId(block)) |entry_id|
                transcriptHasEntry(entries, entry_id)
            else
                false;
    } else false;
    const full_diff_covers_arguments = if (full_diff_resolver) |resolver|
        (if (detail.lifecycle_id) |lifecycle_id|
            resolver.has_full_for_lifecycle(resolver.context, lifecycle_id)
        else
            false) or detailHasAdjacentFullDiff(entries, detail.entry_id, resolver)
    else
        false;
    var semantic_arguments: std.Io.Writer.Allocating = .init(alloc);
    defer semantic_arguments.deinit();
    const has_semantic_arguments = !full_diff_covers_arguments and
        try appendFullSemanticArguments(
            &semantic_arguments.writer,
            alloc,
            entries,
            detail,
            styles,
            builder.projection_cols,
            checkpoint,
        );
    const authoritative_stored_result = storedResultForDetail(detail);
    const active_partial = if (owned_command_block_index) |block_index|
        isActivePartialCommand(detail, command_blocks[block_index])
    else
        false;
    const stored_result = if (deferred_command_source)
        null
    else
        authoritative_stored_result;
    const has_detail = has_semantic_arguments or
        stored_result != null or
        detail.result != null or
        command_block_index != null or
        active_partial or
        deferred_command_source;
    if (!has_detail) return .{};

    try out.writer.writeByte('\n');
    var ends_with_newline = has_semantic_arguments;
    if (has_semantic_arguments) try out.writer.writeAll(semantic_arguments.written());
    if (stored_result) |stored_value| {
        var stored = stored_value;
        stored.line_prefix = "│  ";
        if (isCapturedCommandDetail(detail) and stored.kind == .command_replay) {
            stored.retained_command_fallback = try degradedInlineCommandFallback(
                alloc,
                entries,
                detail,
                command_blocks,
                owned_command_block_index,
                styles,
                builder.projection_cols,
            );
        } else if (owned_command_block_index) |block_index| {
            var fallback: std.Io.Writer.Allocating = .init(alloc);
            errdefer fallback.deinit();
            const block = command_blocks[block_index];
            _ = if (block.canReconstructEntries())
                try appendCommandBlock(&fallback.writer, alloc, block, styles, builder.projection_cols)
            else
                try appendRetainedCommandEntries(&fallback.writer, entries, block);
            stored.retained_command_fallback = try fallback.toOwnedSlice();
        }
        try builder.appendStoredResult(stored);
        ends_with_newline = stored.kind != .tool_result;
    } else if (deferred_command_source) {
        ends_with_newline = true;
    } else if (active_partial) {
        try appendStableActiveCommandPrefix(
            &out.writer,
            alloc,
            command_blocks[owned_command_block_index.?],
            styles,
            builder.projection_cols,
        );
        ends_with_newline = true;
    } else if (detail.result) |result| {
        if (isCapturedCommandDetail(detail)) {
            var rendered: std.Io.Writer.Allocating = .init(alloc);
            defer rendered.deinit();
            const parsed = try appendInlineCommandResult(
                &rendered.writer,
                alloc,
                styles,
                result,
                builder.projection_cols,
            );
            if (!parsed) {
                if (command_block_index) |block_index| {
                    _ = try appendCommandBlock(
                        &rendered.writer,
                        alloc,
                        command_blocks[block_index],
                        styles,
                        builder.projection_cols,
                    );
                } else {
                    try appendTerminalSafeToolOutputInterruptible(
                        &rendered.writer,
                        alloc,
                        styles,
                        tool_result_display.contentForDisplay(result),
                        builder.projection_cols,
                        checkpoint,
                    );
                }
            }
            try out.writer.writeAll(rendered.written());
        } else {
            const display = tool_result_display.contentForDisplay(result);
            try appendTerminalSafeToolOutputInterruptible(
                &out.writer,
                alloc,
                styles,
                display,
                builder.projection_cols,
                checkpoint,
            );
        }
        ends_with_newline = true;
    }
    if (!deferred_command_source and stored_result == null and detail.result == null and !active_partial) {
        if (command_block_index) |block_index| {
            ends_with_newline = try appendCommandBlock(
                &out.writer,
                alloc,
                command_blocks[block_index],
                styles,
                builder.projection_cols,
            );
        }
    }
    if (!deferred_command_source) {
        if (detail.command_process_presentation) |presentation| {
            try appendCommandProcessPresentation(
                &out.writer,
                alloc,
                styles,
                presentation,
                builder.projection_cols,
            );
            ends_with_newline = true;
        }
    }
    return .{ .attached = true, .ends_with_newline = ends_with_newline };
}

fn degradedInlineCommandFallback(
    alloc: Allocator,
    entries: []const transcript_blocks.TranscriptEntry,
    detail: *const ToolDetailRecord,
    command_blocks: []const command_output_runtime.CommandOutputBlock,
    owned_command_block_index: ?usize,
    styles: transcript_blocks.Styles,
    cols: u16,
) ![]u8 {
    var fallback: std.Io.Writer.Allocating = .init(alloc);
    errdefer fallback.deinit();

    if (detail.result) |result| {
        if (try appendInlineCommandResult(
            &fallback.writer,
            alloc,
            styles,
            result,
            cols,
        )) return fallback.toOwnedSlice();
    }

    if (owned_command_block_index) |block_index| {
        const block = command_blocks[block_index];
        _ = if (block.canReconstructEntries())
            try appendCommandBlock(&fallback.writer, alloc, block, styles, cols)
        else
            try appendRetainedCommandEntries(&fallback.writer, entries, block);
        if (fallback.written().len > 0) return fallback.toOwnedSlice();
    }

    if (detail.result) |result| {
        try appendTerminalSafeIndented(
            &fallback.writer,
            alloc,
            tool_result_display.contentForDisplay(result),
        );
    }
    return fallback.toOwnedSlice();
}

fn appendCommandProcessPresentation(
    writer: *std.Io.Writer,
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    presentation: types.CommandProcessPresentation,
    cols: u16,
) !void {
    const text = switch (presentation) {
        .exit_code => |code| try std.fmt.allocPrint(alloc, "exit code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(alloc, "signal {d}", .{signal}),
        .timed_out => try alloc.dupe(u8, "timed out"),
        .output_capture_failed => try alloc.dupe(u8, "output capture failed"),
    };
    defer alloc.free(text);
    const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
        alloc,
        styles,
        text,
        cols,
    );
    defer alloc.free(rendered);
    try writer.writeAll(rendered);
    if (!std.mem.endsWith(u8, rendered, "\n")) try writer.writeByte('\n');
}

fn appendInlineCommandResult(
    writer: *std.Io.Writer,
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    result: []const u8,
    cols: u16,
) !bool {
    return appendInlineCommandResultRange(
        writer,
        alloc,
        styles,
        result,
        cols,
        0,
        std.math.maxInt(usize),
    );
}

fn appendInlineCommandResultRange(
    writer: *std.Io.Writer,
    alloc: Allocator,
    styles: transcript_blocks.Styles,
    result: []const u8,
    cols: u16,
    start_record: usize,
    requested_end_record: usize,
) !bool {
    if (try command_output_content.canonicalizeForegroundResult(alloc, result)) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit(alloc);
        if (requested_end_record != std.math.maxInt(usize) and
            requested_end_record > parsed.records.items.len) return false;
        const end_record = @min(requested_end_record, parsed.records.items.len);
        if (start_record > end_record) return false;
        for (parsed.records.items[start_record..end_record]) |record| {
            const rendered = try command_output_runtime.renderCommandOutputRecordWithPrimaryGutter(
                alloc,
                styles,
                record.text.items,
                cols,
            );
            defer alloc.free(rendered);
            try writer.writeAll(rendered);
            if (!std.mem.endsWith(u8, rendered, "\n")) try writer.writeByte('\n');
        }
        return true;
    }
    return false;
}

fn appendPermanentCommandUnavailableToWriter(
    writer: *std.Io.Writer,
    styles: transcript_blocks.Styles,
) !void {
    try writeSecondaryRailLine(writer, styles, " … full output unavailable");
}

fn appendTerminalSafeIndented(writer: *std.Io.Writer, alloc: Allocator, raw: []const u8) !void {
    _ = alloc;
    var stream = TerminalSafeIndentedWriter{};
    try stream.append(writer, raw);
    try stream.finish(writer);
    if (!stream.line_start) try writer.writeByte('\n');
}
