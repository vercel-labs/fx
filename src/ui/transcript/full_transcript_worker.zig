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

const Allocator = std.mem.Allocator;

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

pub const Task = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    source: Source,
    source_owned: bool = true,
    projection: ?full_transcript_screen.Projection = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Task) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.projection) |*projection| {
            projection.deinit(std.heap.c_allocator);
        }
        if (self.source_owned) self.source.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(self);
    }

    pub fn takeProjection(self: *Task) ?full_transcript_screen.Projection {
        const projection = self.projection orelse return null;
        self.projection = null;
        return projection;
    }

    pub fn takeSource(self: *Task) Source {
        std.debug.assert(self.source_owned);
        self.source_owned = false;
        return self.source;
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
