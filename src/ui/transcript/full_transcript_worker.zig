const std = @import("std");
const builtin = @import("builtin");
const full_transcript_page = @import("../../core/output/full_transcript_page.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const types = @import("../../core/shared/types.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const source_preparation = @import("source_preparation.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");

const Allocator = std.mem.Allocator;
pub const prepared_cache_overscan_max_rows: u16 = 192;
pub const prepared_cache_max_bytes: usize = 2 * 1024 * 1024;

pub fn preparedWindowRequest(
    page_request: full_transcript_page.Request,
    total_rows: u32,
    target_offset: u32,
    visible_rows: u16,
) WindowRequest {
    const bounded_visible_rows = @max(visible_rows, 1);
    const cache_rows: u16 = @intCast(@max(
        @as(u32, bounded_visible_rows),
        @min(
            @as(u32, prepared_cache_overscan_max_rows),
            @as(u32, bounded_visible_rows) *| 3,
        ),
    ));
    const overscan = (cache_rows -| bounded_visible_rows) / 2;
    const max_start = total_rows -| cache_rows;
    return .{
        .page_request = page_request,
        .target_offset = target_offset,
        .start_row = @min(target_offset -| overscan, max_start),
        .row_count = cache_rows,
    };
}

test "prepared window always covers one complete visible viewport" {
    const request = preparedWindowRequest(
        .{ .content_revision = 1, .cols = 80, .anchor = .tail },
        1_000,
        780,
        220,
    );
    try std.testing.expectEqual(@as(u16, 220), request.row_count);
    try std.testing.expect(request.start_row <= request.target_offset);
    try std.testing.expect(
        request.start_row + @as(u32, request.row_count) >=
            request.target_offset + 220,
    );
}

pub const FullDiffSnapshot = struct {
    marker_id: u32,
    content: []u8,

    fn deinit(self: FullDiffSnapshot, alloc: Allocator) void {
        alloc.free(self.content);
    }
};

pub const Source = struct {
    request: full_transcript_page.Request,
    range: full_transcript_page.SourceRange,
    entries: std.ArrayList(transcript_blocks.TranscriptEntry) = .empty,
    details: std.ArrayList(transcript_blocks.ToolDetailRecord) = .empty,
    command_blocks: std.ArrayList(command_output_runtime.CommandOutputBlock) = .empty,
    full_diffs: std.ArrayList(FullDiffSnapshot) = .empty,
    full_diff_lifecycles: std.ArrayList(types.ToolLifecycleId) = .empty,
    styles: transcript_blocks.Styles,
    capability: ?session_child_store.SessionChildCapability = null,
    presentation: transcript_presentation.State = .{},
    visible_rows: u16 = 1,

    pub fn deinit(self: *Source, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        for (self.details.items) |*detail| detail.deinit(alloc);
        self.details.deinit(alloc);
        for (self.command_blocks.items) |*block| block.deinit(alloc);
        self.command_blocks.deinit(alloc);
        for (self.full_diffs.items) |diff| diff.deinit(alloc);
        self.full_diffs.deinit(alloc);
        for (self.full_diff_lifecycles.items) |lifecycle_id| {
            alloc.free(@constCast(lifecycle_id.call_id));
        }
        self.full_diff_lifecycles.deinit(alloc);
        if (self.capability) |*capability| capability.deinit();
        self.* = undefined;
    }

    pub fn fullDiffResolver(self: *Source) ?full_transcript_screen.FullDiffResolver {
        if (self.full_diffs.items.len == 0 and
            self.full_diff_lifecycles.items.len == 0) return null;
        return .{
            .context = self,
            .full_for_marker = fullDiffForMarker,
            .has_full_for_lifecycle = hasFullDiffForLifecycle,
        };
    }

    pub fn appendFullDiff(
        self: *Source,
        alloc: Allocator,
        marker_id: u32,
        content: []const u8,
    ) !void {
        const owned_content = try alloc.dupe(u8, content);
        errdefer alloc.free(owned_content);
        try self.full_diffs.append(alloc, .{
            .marker_id = marker_id,
            .content = owned_content,
        });
    }

    pub fn appendFullDiffLifecycle(
        self: *Source,
        alloc: Allocator,
        lifecycle_id: types.ToolLifecycleId,
    ) !void {
        const call_id = try alloc.dupe(u8, lifecycle_id.call_id);
        errdefer alloc.free(call_id);
        try self.full_diff_lifecycles.append(alloc, .{
            .turn_id = lifecycle_id.turn_id,
            .call_id = call_id,
        });
    }

    fn fullDiffForMarker(raw: *anyopaque, marker_id: u32) ?[]const u8 {
        const self: *Source = @ptrCast(@alignCast(raw));
        for (self.full_diffs.items) |diff| {
            if (diff.marker_id == marker_id) return diff.content;
        }
        return null;
    }

    fn hasFullDiffForLifecycle(
        raw: *anyopaque,
        lifecycle_id: types.ToolLifecycleId,
    ) bool {
        const self: *Source = @ptrCast(@alignCast(raw));
        for (self.full_diff_lifecycles.items) |candidate| {
            if (candidate.turn_id == lifecycle_id.turn_id and
                std.mem.eql(u8, candidate.call_id, lifecycle_id.call_id)) return true;
        }
        return false;
    }
};

pub const InstalledSource = struct {
    request: full_transcript_page.Request,
    range: full_transcript_page.SourceRange,
    // Stored projection segments borrow the snapshot's result and handle bytes.
    details: std.ArrayList(transcript_blocks.ToolDetailRecord) = .empty,
    capability: ?session_child_store.SessionChildCapability = null,

    pub fn deinit(self: *InstalledSource, alloc: Allocator) void {
        for (self.details.items) |*detail| detail.deinit(alloc);
        self.details.deinit(alloc);
        if (self.capability) |*capability| capability.deinit();
        self.* = undefined;
    }
};

pub const PreparedWindow = struct {
    source: source_preparation.TranscriptPreparationSource,
    start_row: u32,
    target_offset: u32 = 0,

    pub fn deinit(self: *PreparedWindow, alloc: Allocator) void {
        self.source.deinit(alloc);
        self.* = undefined;
    }
};

pub const Task = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    source: Source,
    projection: ?full_transcript_screen.Projection = null,
    prepared_window: ?PreparedWindow = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Task) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.projection) |*projection| {
            projection.deinit(std.heap.c_allocator);
        }
        if (self.prepared_window) |*window| {
            window.deinit(std.heap.c_allocator);
        }
        self.source.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(self);
    }

    pub fn takeProjection(self: *Task) ?full_transcript_screen.Projection {
        const projection = self.projection orelse return null;
        self.projection = null;
        return projection;
    }

    pub fn takeInstalledSource(self: *Task) InstalledSource {
        const details = self.source.details;
        self.source.details = .empty;
        const capability = self.source.capability;
        self.source.capability = null;
        return .{
            .request = self.source.request,
            .range = self.source.range,
            .details = details,
            .capability = capability,
        };
    }

    pub fn takePreparedWindow(
        self: *Task,
    ) ?PreparedWindow {
        const window = self.prepared_window orelse return null;
        self.prepared_window = null;
        return window;
    }

    fn cancelled(context: *anyopaque) bool {
        const self: *Task = @ptrCast(@alignCast(context));
        return self.cancel_requested.load(.acquire);
    }

    fn run(self: *Task) void {
        const alloc = std.heap.c_allocator;
        var projection = (if (self.source.fullDiffResolver()) |resolver|
            full_transcript_screen.buildProjectionWithResolver(
                alloc,
                self.source.entries.items,
                self.source.details.items,
                self.source.command_blocks.items,
                self.source.styles,
                self.source.request.cols,
                null,
                resolver,
            )
        else
            full_transcript_screen.buildProjection(
                alloc,
                self.source.entries.items,
                self.source.details.items,
                self.source.command_blocks.items,
                self.source.styles,
                self.source.request.cols,
                null,
            )) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        var projection_owned = true;
        defer if (projection_owned) projection.deinit(alloc);

        var checkpoint = build_checkpoint.BuildCheckpoint.init(
            self,
            Task.cancelled,
        );
        const measurement = full_transcript_screen.measureProjectionInterruptible(
            alloc,
            &projection,
            if (self.source.capability) |*capability| capability else null,
            self.source.request.cols,
            &checkpoint,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        const visible_rows = @max(self.source.visible_rows, 1);
        const selected = self.source.presentation.select_visual_offset(
            measurement.total_rows,
            visible_rows,
            measurement.item_rows,
        );
        const window_request = preparedWindowRequest(
            self.source.request,
            measurement.total_rows,
            selected.offset,
            visible_rows,
        );
        const prepared_window = prepareWindowInterruptible(
            alloc,
            &projection,
            if (self.source.capability) |*capability| capability else null,
            window_request,
            &checkpoint,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        debug_trace.logf(
            "full_transcript_cache",
            "page_built revision={d} cols={d} entries={d} details={d} blocks={d} segments={d} rows={d}",
            .{
                self.source.request.content_revision,
                self.source.request.cols,
                self.source.entries.items.len,
                self.source.details.items.len,
                self.source.command_blocks.items.len,
                projection.segments.items.len,
                measurement.total_rows,
            },
        );
        self.projection = projection;
        self.prepared_window = prepared_window;
        projection_owned = false;
        self.done.store(true, .release);
    }
};

pub fn cloneCommandBlockForPageSnapshot(
    alloc: Allocator,
    source: command_output_runtime.CommandOutputBlock,
) !command_output_runtime.CommandOutputBlock {
    const lifecycle_id: ?types.ToolLifecycleId = if (source.lifecycle_id) |id|
        .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        }
    else
        null;
    var clone = command_output_runtime.CommandOutputBlock{
        .entry_id = source.entry_id,
        .lifecycle_id = lifecycle_id,
        .total_lines = source.total_lines,
        .retained_text_bytes = source.retained_text_bytes,
        .retention_overflow = source.retention_overflow,
        .overflow_line_index = source.overflow_line_index,
    };
    errdefer clone.deinit(alloc);
    try clone.lines.ensureTotalCapacity(alloc, source.lines.items.len);
    for (source.lines.items) |line| {
        clone.lines.appendAssumeCapacity(.{
            .stream = line.stream,
            .text = try alloc.dupe(u8, line.text),
            .record_ordinal = line.record_ordinal,
            .entry_id = line.entry_id,
            .terminated = line.terminated,
            .visible = line.visible,
        });
    }
    try clone.pruned_ranges.appendSlice(alloc, source.pruned_ranges.items);
    return clone;
}

test "installed projection retains saved output and fallback after source disposal" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../../core/shared/io.zig");
    const result_store = @import("../../core/session/result_store.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(path);

    var task = Task{ .source = .{
        .request = .{ .content_revision = 1, .cols = 80, .anchor = .tail },
        .range = .{ .start = 0, .end = 1 },
        .styles = .{},
        .capability = try session_child_store.SessionChildCapability.initLegacyRoute(
            alloc,
            path,
            .tool_results,
            .writable,
        ),
    } };
    var source_owned = true;
    defer if (source_owned) task.source.deinit(alloc);
    try task.source.details.ensureTotalCapacity(alloc, 1);
    task.source.details.appendAssumeCapacity(.{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "read_file"),
    });
    const detail = &task.source.details.items[0];
    detail.result = try alloc.dupe(u8, "retained preview");
    detail.result_handle = try result_store.storeLargeResultManaged(
        alloc,
        &task.source.capability.?,
        "installed-result",
        "read_file",
        "SAVED_HEAD\nSAVED_TAIL\n",
    );
    const entries = [_]transcript_blocks.TranscriptEntry{.{ .raw_bytes = .{
        .id = 1,
        .created_at_ms = 0,
        .bytes = @constCast("Read fixture.txt\n"),
        .class = .tool_status,
    } }};
    var projection = try full_transcript_screen.buildProjection(
        alloc,
        &entries,
        task.source.details.items,
        &.{},
        .{},
        80,
        null,
    );
    var installed = task.takeInstalledSource();
    defer installed.deinit(alloc);
    defer projection.deinit(alloc);
    task.source.deinit(alloc);
    source_owned = false;

    const rendered = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        &installed.capability.?,
        80,
        20,
        0,
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "SAVED_HEAD") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "SAVED_TAIL") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Full saved result unavailable.") == null);

    // A newly built view must still have a readable preview if the file disappears.
    try result_store.deleteManaged(&installed.capability.?, installed.details.items[0].result_handle.?);
    var missing = try full_transcript_screen.buildProjection(
        alloc,
        &entries,
        installed.details.items,
        &.{},
        .{},
        80,
        null,
    );
    defer missing.deinit(alloc);
    const fallback = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &missing,
        &installed.capability.?,
        80,
        20,
        0,
        null,
    );
    defer alloc.free(fallback);
    try std.testing.expect(std.mem.find(u8, fallback, "retained preview") != null);
    try std.testing.expect(std.mem.find(u8, fallback, "Full saved result unavailable.") != null);
}

pub const Load = struct {
    task: ?*Task = null,

    pub fn deinit(self: *Load) void {
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    pub fn schedule(self: *Load, source: Source) !void {
        if (self.task != null) return error.FullTranscriptPageWorkerBusy;
        try self.start(source);
    }

    pub fn busy(self: *const Load) bool {
        return self.task != null;
    }

    pub fn cancelActive(self: *Load) void {
        const task = self.task orelse return;
        task.cancel_requested.store(true, .release);
    }

    pub fn takeCompleted(self: *Load) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task;
    }

    pub fn hasRequest(self: *const Load, request: full_transcript_page.Request) bool {
        if (self.task) |task| {
            if (full_transcript_page.sameRequest(task.source.request, request) and
                !task.cancel_requested.load(.acquire)) return true;
        }
        return false;
    }

    pub fn hasCompatibleRequest(
        self: *const Load,
        request: full_transcript_page.Request,
    ) bool {
        const task = self.task orelse return false;
        return !task.cancel_requested.load(.acquire) and
            full_transcript_page.sameSurface(task.source.request, request);
    }

    fn start(self: *Load, source: Source) !void {
        const task = try std.heap.c_allocator.create(Task);
        task.* = .{ .source = source };
        if (comptime builtin.single_threaded) {
            task.run();
            self.task = task;
            return;
        }
        task.thread = std.Thread.spawn(.{}, Task.run, .{task}) catch |err| {
            task.source.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(task);
            return err;
        };
        self.task = task;
    }
};

pub const WindowRequest = struct {
    page_request: full_transcript_page.Request,
    target_offset: u32,
    start_row: u32,
    row_count: u16,
};

pub const WindowTask = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    request: WindowRequest,
    projection: *full_transcript_screen.Projection,
    capability: ?*session_child_store.SessionChildCapability,
    prepared_window: ?PreparedWindow = null,
    failure: ?anyerror = null,

    fn run(self: *WindowTask) void {
        const alloc = std.heap.c_allocator;
        var checkpoint = build_checkpoint.BuildCheckpoint.init(
            self,
            WindowTask.cancelled,
        );
        self.prepared_window = prepareWindowInterruptible(
            alloc,
            self.projection,
            self.capability,
            self.request,
            &checkpoint,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }

    fn cancelled(context: *anyopaque) bool {
        const self: *WindowTask = @ptrCast(@alignCast(context));
        return self.cancel_requested.load(.acquire);
    }

    pub fn takePreparedWindow(self: *WindowTask) ?PreparedWindow {
        const window = self.prepared_window orelse return null;
        self.prepared_window = null;
        return window;
    }

    pub fn deinit(self: *WindowTask) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.prepared_window) |*window| {
            window.deinit(std.heap.c_allocator);
        }
        std.heap.c_allocator.destroy(self);
    }
};

fn prepareWindowInterruptible(
    alloc: Allocator,
    projection: *full_transcript_screen.Projection,
    capability: ?*session_child_store.SessionChildCapability,
    request: WindowRequest,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !PreparedWindow {
    const bytes = try full_transcript_screen.renderProjectionViewportSourceBoundedInterruptible(
        alloc,
        projection,
        capability,
        request.page_request.cols,
        request.row_count,
        request.start_row,
        prepared_cache_max_bytes,
        checkpoint,
    );
    const source = try source_preparation.prepareIndexedFullTranscriptWindowSourceInterruptible(
        alloc,
        bytes,
        request.page_request.cols,
        checkpoint,
    );
    return .{
        .source = source,
        .start_row = request.start_row,
        .target_offset = request.target_offset,
    };
}

pub const WindowLoad = struct {
    task: ?*WindowTask = null,

    pub fn deinit(self: *WindowLoad) void {
        if (self.task) |task| task.deinit();
        self.* = .{};
    }

    pub fn busy(self: *const WindowLoad) bool {
        return self.task != null;
    }

    pub fn schedule(
        self: *WindowLoad,
        request: WindowRequest,
        projection: *full_transcript_screen.Projection,
        capability: ?*session_child_store.SessionChildCapability,
    ) !void {
        if (self.task != null) return error.FullTranscriptWindowWorkerBusy;
        const task = try std.heap.c_allocator.create(WindowTask);
        task.* = .{
            .request = request,
            .projection = projection,
            .capability = capability,
        };
        if (comptime builtin.single_threaded) {
            task.run();
            self.task = task;
            return;
        }
        task.thread = std.Thread.spawn(.{}, WindowTask.run, .{task}) catch |err| {
            std.heap.c_allocator.destroy(task);
            return err;
        };
        self.task = task;
    }

    pub fn cancelActive(self: *WindowLoad) void {
        const task = self.task orelse return;
        task.cancel_requested.store(true, .release);
    }

    pub fn hasTarget(self: *const WindowLoad, target_offset: u32) bool {
        const task = self.task orelse return false;
        return task.request.target_offset == target_offset and
            !task.cancel_requested.load(.acquire);
    }

    pub fn takeCompleted(self: *WindowLoad) ?*WindowTask {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        return task;
    }
};
