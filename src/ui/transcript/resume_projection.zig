const std = @import("std");
const assistant_presentation = @import("../../core/agent/assistant_presentation.zig");
const diff = @import("../../core/output/diff.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const source_preparation = @import("source_preparation.zig");
const transcript_runtime = @import("runtime.zig");
const transcript_store = @import("store.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

/// Owned, detached presentation state for one resume. All effectful artifact,
/// background, and policy decisions are resolved before values enter here.
pub const ResumeProjection = struct {
    runtime: TranscriptRuntime,
    alloc: Allocator,
    created_at_ms: i64,
    retention_cap: usize,
    publication_source: ?transcript_runtime.TranscriptPreparationSource = null,
    pending_diffs: std.ArrayList(diff.DiffEntry) = .empty,
    next_diff_id: u32,
    finalized: bool = false,
    consumed: bool = false,

    pub fn init(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
    ) !ResumeProjection {
        var detached = try transcript_store.cloneDetachedPresentationState(source, alloc);
        const retention_cap = detached.max_retained_transcript_bytes;
        detached.max_retained_transcript_bytes = std.math.maxInt(usize);
        return .{
            .runtime = detached,
            .alloc = alloc,
            .created_at_ms = created_at_ms,
            .retention_cap = retention_cap,
            .next_diff_id = next_diff_id,
        };
    }

    /// Start a detached projection with the source runtime's presentation
    /// policy but none of its conversation content.
    pub fn initEmpty(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
    ) !ResumeProjection {
        var projection = try init(alloc, source, created_at_ms, next_diff_id);
        projection.runtime.clearTranscript(alloc);
        projection.runtime.next_entry_id = 1;
        return projection;
    }

    pub fn deinit(self: *ResumeProjection) void {
        if (!self.consumed) self.runtime.deinit(self.alloc);
        if (self.publication_source) |*source| source.deinit(self.alloc);
        for (self.pending_diffs.items) |*entry| entry.deinit(std.heap.c_allocator);
        self.pending_diffs.deinit(std.heap.c_allocator);
        self.* = undefined;
    }

    fn appendEntry(self: *ResumeProjection, entry: transcript_runtime.TranscriptEntry) !u32 {
        const entry_id = entry.id();
        try self.runtime.entries.append(self.alloc, entry);
        self.runtime.next_entry_id +%= 1;
        self.runtime.replaceable_last_line = false;
        self.runtime.replaceable_start = 0;
        return entry_id;
    }

    pub fn appendNotice(self: *ResumeProjection, notice: types.SemanticNotice) !u32 {
        const owned = try types.dupeSemanticNotice(self.alloc, notice);
        errdefer types.freeSemanticNotice(self.alloc, owned);
        return self.appendEntry(.{ .semantic_notice = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .topic = owned.topic,
            .tone = owned.tone,
            .body = owned.body,
            .visibility = owned.visibility,
        } });
    }

    pub fn appendUserTurn(self: *ResumeProjection, turn: types.UserTurn) !u32 {
        const owned = try types.dupeUserTurn(self.alloc, turn);
        errdefer {
            types.freeUserTurn(self.alloc, owned);
        }
        return self.appendEntry(.{ .user_turn = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .turn = owned,
        } });
    }

    pub fn appendRawClassified(
        self: *ResumeProjection,
        text: []const u8,
        class: transcript_runtime.RawEntryClass,
    ) !u32 {
        if (text.len == 0) return 0;
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        return self.appendRawOwned(owned, class);
    }

    fn appendRawOwned(
        self: *ResumeProjection,
        owned: []u8,
        class: transcript_runtime.RawEntryClass,
    ) !u32 {
        errdefer self.alloc.free(owned);
        return self.appendEntry(.{ .raw_bytes = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .bytes = owned,
            .class = class,
        } });
    }

    pub fn appendReplaceableLine(self: *ResumeProjection, text: []const u8) !u32 {
        const entry_id = try self.appendRawClassified(text, .unknown_raw);
        if (entry_id != 0) self.runtime.replaceable_last_line = true;
        return entry_id;
    }

    pub fn appendToolStatus(
        self: *ResumeProjection,
        kind: types.ToolOutcomeKind,
        summary: []const u8,
    ) !u32 {
        const line = try transcript_runtime.formatHistoricalToolStatusLine(
            self.alloc,
            kind,
            summary,
        );
        return self.appendRawOwned(line, .tool_status);
    }

    pub fn appendAssistantText(self: *ResumeProjection, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.runtime.tailAssistantSegments()) |segments| {
            try segments.text.appendSlice(self.alloc, text);
            return;
        }
        var segments: transcript_runtime.AssistantTurnSegments = .{};
        errdefer segments.deinit(self.alloc);
        try segments.text.appendSlice(self.alloc, text);
        _ = try self.appendEntry(.{ .assistant_turn = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .segments = segments,
        } });
    }

    pub fn appendAssistantTable(
        self: *ResumeProjection,
        table: assistant_presentation.TablePayload,
    ) !void {
        _ = try self.appendEntry(.{ .assistant_table = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .table = table,
        } });
    }

    pub fn appendAssistantCodeBlock(
        self: *ResumeProjection,
        block: assistant_presentation.CodeBlockPayload,
    ) !void {
        _ = try self.appendEntry(.{ .assistant_code_block = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .block = block,
        } });
    }

    pub fn appendAssistantThematicRule(self: *ResumeProjection) !void {
        _ = try self.appendEntry(.{ .assistant_thematic_rule = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
        } });
    }

    pub fn appendCommandOutput(
        self: *ResumeProjection,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
    ) !void {
        var metrics: types.Metrics = .{};
        _ = try command_output_runtime.writeCommandOutputChunkDetached(
            &self.runtime,
            self.alloc,
            &metrics,
            self.runtime.retainedTranscriptStyles(),
            lifecycle_id,
            stream,
            text,
            true,
            self.created_at_ms,
        );
    }

    pub fn finishCommandOutput(
        self: *ResumeProjection,
        lifecycle_id: ?types.ToolLifecycleId,
    ) !void {
        try command_output_runtime.flushCommandOutputSummaryDetached(
            &self.runtime,
            self.alloc,
            self.runtime.retainedTranscriptStyles(),
            lifecycle_id,
            self.created_at_ms,
        );
    }

    pub fn attachHistoricalToolDetail(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.runtime.attachHistoricalToolDetail(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn attachHistoricalToolDetailWithLifecycle(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
        lifecycle_id: types.ToolLifecycleId,
    ) !void {
        try self.runtime.attachHistoricalToolDetailWithLifecycle(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
            lifecycle_id,
        );
    }

    pub fn attachHistoricalToolDetailAfterCommandOutput(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.runtime.attachHistoricalToolDetailAfterCommandOutputDetached(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn attachHistoricalToolCallWithoutResult(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
    ) !void {
        try self.runtime.attachHistoricalToolCallWithoutResult(
            self.alloc,
            entry_id,
            call,
        );
    }

    pub fn attachHistoricalCommandOutput(
        self: *ResumeProjection,
        entry_id: u32,
    ) void {
        self.runtime.attachHistoricalCommandOutput(self.alloc, entry_id);
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.runtime.attachHistoricalCancelledCommandDetail(
            self.alloc,
            entry_id,
            call,
            command_artifact_handle,
            replayed_output,
        );
    }

    pub fn appendDiff(self: *ResumeProjection, payload: diff.DiffEntryPayload) !void {
        const c_alloc = std.heap.c_allocator;
        var owns_payload = true;
        errdefer if (owns_payload) diff.freeDiffEntryPayload(c_alloc, payload);

        const id = self.next_diff_id;
        const wrapped = try diff.wrapWithMarkers(c_alloc, id, payload.preview);
        defer c_alloc.free(wrapped);
        _ = try self.appendRawClassified(wrapped, .diff_block);
        try self.pending_diffs.append(c_alloc, .{ .id = id, .full = payload.full });
        c_alloc.free(payload.preview);
        owns_payload = false;
        self.next_diff_id += 1;
    }

    pub fn finalize(self: *ResumeProjection) !void {
        return self.finalizeForPresentation(false);
    }

    /// A live projection may end at a valid command-output prefix. Keep that
    /// block open so later output and its terminal event can continue it.
    pub fn finalizeLivePresentation(self: *ResumeProjection) !void {
        return self.finalizeForPresentation(true);
    }

    fn finalizeForPresentation(
        self: *ResumeProjection,
        allow_open_command_block: bool,
    ) !void {
        return self.finalizeInner(allow_open_command_block) catch |err| switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    }

    fn finalizeInner(
        self: *ResumeProjection,
        allow_open_command_block: bool,
    ) !void {
        std.debug.assert(!self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(
            allow_open_command_block or
                self.runtime.command_output_display.open_command_block == null,
        );

        _ = try command_output_runtime.syncCommandOutputBlockEntries(
            &self.runtime,
            self.alloc,
        );
        var source = try source_preparation.prepareTranscriptSource(
            &self.runtime,
            self.alloc,
            null,
        );
        const full_flow = source.bytes;
        source.bytes = &.{};
        source.deinit(self.alloc);
        self.publication_source = try source_preparation.prepareFullTranscriptViewportSource(
            &self.runtime,
            self.alloc,
            full_flow,
        );

        self.runtime.max_retained_transcript_bytes = self.retention_cap;
        const retention_changed = try self.runtime.enforceStructuredRetentionAndReport(
            self.alloc,
            null,
        );
        if (!retention_changed) {
            self.runtime.transcript.clearRetainingCapacity();
            self.runtime.replaceable_last_line = false;
            self.runtime.replaceable_start = 0;
            _ = try transcript_store.appendCappedWithinCapacity(
                &self.runtime.transcript,
                self.alloc,
                self.publication_source.?.bytes,
                self.runtime.max_transcript_bytes,
                &self.runtime.replaceable_last_line,
                &self.runtime.replaceable_start,
            );
            self.runtime.last_rendered_cols = self.runtime.layout.cols;
            self.runtime.transcript_cache_origin_untrimmed =
                self.runtime.transcript.items.len == self.publication_source.?.bytes.len;
        }
        self.runtime.recomputeCursorFromTranscript();
        self.finalized = true;
    }

    pub fn install(self: *ResumeProjection, target: *TranscriptRuntime) void {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(target.pending_resume_source == null);

        std.mem.swap(@TypeOf(target.entries), &target.entries, &self.runtime.entries);
        std.mem.swap(@TypeOf(target.tool_details), &target.tool_details, &self.runtime.tool_details);
        std.mem.swap(
            @TypeOf(target.folded_command_blocks),
            &target.folded_command_blocks,
            &self.runtime.folded_command_blocks,
        );
        std.mem.swap(
            @TypeOf(target.command_output_blocks),
            &target.command_output_blocks,
            &self.runtime.command_output_blocks,
        );
        std.mem.swap(@TypeOf(target.transcript), &target.transcript, &self.runtime.transcript);
        target.next_entry_id = self.runtime.next_entry_id;
        target.last_rendered_cols = self.runtime.last_rendered_cols;
        target.transcript_cache_origin_untrimmed =
            self.runtime.transcript_cache_origin_untrimmed;
        target.command_output_display = self.runtime.command_output_display;
        target.command_output_render = self.runtime.command_output_render;
        target.replaceable_last_line = self.runtime.replaceable_last_line;
        target.replaceable_row = self.runtime.replaceable_row;
        target.replaceable_start = self.runtime.replaceable_start;
        target.pending_resume_source = self.publication_source;
        self.publication_source = null;
        target.recomputeCursorFromTranscript();
        target.reconcileDetachedInstallSource(target.pendingResumeFlow());
        target.markTranscriptDirty();

        self.consumed = true;
        self.runtime.deinit(self.alloc);
    }

    /// Transfers a finalized detached projection into a standalone transcript
    /// runtime. The caller owns the returned runtime and must deinitialize it
    /// with the same allocator.
    pub fn intoRuntime(self: *ResumeProjection) TranscriptRuntime {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(self.runtime.pending_resume_source == null);

        self.runtime.pending_resume_source = self.publication_source;
        self.publication_source = null;
        self.runtime.reconcileDetachedInstallSource(
            self.runtime.pendingResumeFlow(),
        );
        self.runtime.markTranscriptDirty();

        self.consumed = true;
        return self.runtime;
    }

    /// Transfers the full-diff sidecars that belong to the detached
    /// presentation. The caller owns the returned entries and must deinitialize
    /// each entry and the list with `std.heap.c_allocator`.
    pub fn takePendingDiffs(
        self: *ResumeProjection,
    ) std.ArrayList(diff.DiffEntry) {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        const pending = self.pending_diffs;
        self.pending_diffs = .empty;
        return pending;
    }
};

test "resume projection finalizes complete flow before one retained-tail pass" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 40,
        .cols = 80,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    source.max_retained_transcript_bytes = 96;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendNotice(.{
        .topic = "session",
        .tone = .neutral,
        .body = "resumed: fixture",
    });
    for (0..12) |index| {
        var text: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&text, "historical marker {d}\n", .{index});
        _ = try projection.appendRawClassified(line, .unknown_raw);
    }
    try projection.finalize();

    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "historical marker 0") != null);
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "historical marker 11") != null);
    try std.testing.expect(projection.runtime.entries.items.len < 13);
}

test "empty resume projection keeps layout without source conversation" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);
    _ = try source.appendRawTranscriptEntry(alloc, "main-only marker\n");

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try std.testing.expectEqual(source.layout.cols, projection.runtime.layout.cols);
    try std.testing.expectEqual(@as(usize, 0), projection.runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), projection.runtime.transcript.items.len);

    _ = try projection.appendRawClassified("child-only marker\n", .unknown_raw);
    try projection.finalize();
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "main-only marker") == null);
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "child-only marker") != null);
    try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
}

test "resume projection installs complete publication and retained continuation together" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 40,
        .cols = 80,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    source.max_retained_transcript_bytes = 96;
    defer source.deinit(alloc);

    var target: TranscriptRuntime = .{};
    target.layout = source.layout;
    target.max_retained_transcript_bytes = source.max_retained_transcript_bytes;
    defer target.deinit(alloc);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    for (0..12) |index| {
        var text: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&text, "publication marker {d}\n", .{index});
        _ = try projection.appendRawClassified(line, .unknown_raw);
    }
    try projection.finalize();
    projection.install(&target);

    try std.testing.expect(std.mem.find(u8, target.pendingResumeFlow(), "publication marker 0") != null);
    try std.testing.expect(std.mem.find(u8, target.pendingResumeFlow(), "publication marker 11") != null);
    try std.testing.expect(target.entries.items.len < 12);
    var prepared = try target.prepareTranscriptSource(alloc, null);
    defer prepared.deinit(alloc);
    try std.testing.expectEqualStrings(target.pendingResumeFlow(), prepared.bytes);
}

test "resume projection transfers a complete standalone runtime" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendAssistantText("standalone child\n");
    try projection.finalize();

    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(source.layout.cols, runtime.layout.cols);
    try std.testing.expect(std.mem.find(
        u8,
        runtime.pendingResumeFlow(),
        "standalone child",
    ) != null);
}

test "resume projection transfers standalone full diff sidecars" {
    const alloc = std.testing.allocator;
    const c_alloc = std.heap.c_allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 72;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 7);
    defer projection.deinit();
    const payload = try struct {
        fn make(a: Allocator) !diff.DiffEntryPayload {
            const preview = try a.dupe(u8, "preview\n");
            errdefer a.free(preview);
            const full_content = try a.dupe(u8, "complete diff\n");
            errdefer a.free(full_content);
            const call_id = try a.dupe(u8, "diff-call");
            return .{
                .preview = preview,
                .full = .{
                    .content = full_content,
                    .lifecycle_id = .{
                        .turn_id = 3,
                        .call_id = call_id,
                    },
                },
            };
        }
    }.make(c_alloc);
    var owns_payload = true;
    errdefer if (owns_payload) diff.freeDiffEntryPayload(c_alloc, payload);
    try projection.appendDiff(payload);
    owns_payload = false;
    try projection.finalize();

    var pending = projection.takePendingDiffs();
    defer {
        for (pending.items) |*entry| entry.deinit(c_alloc);
        pending.deinit(c_alloc);
    }
    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqual(@as(u32, 7), pending.items[0].id);
    try std.testing.expectEqualStrings(
        "complete diff\n",
        pending.items[0].full.?.content,
    );
    try std.testing.expect(std.mem.find(
        u8,
        runtime.pendingResumeFlow(),
        diff.diff_block_start_prefix,
    ) != null);
}

test "resume projection uses its explicit timestamp for command output" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(null, .stdout, "one\ntwo\n");
    try projection.finishCommandOutput(null);

    var command_entries: usize = 0;
    for (projection.runtime.entries.items) |entry| {
        if (entry != .raw_bytes or entry.raw_bytes.class != .command_output) continue;
        try std.testing.expectEqual(@as(i64, 42), entry.raw_bytes.created_at_ms);
        command_entries += 1;
    }
    try std.testing.expect(command_entries > 0);
}

test "live resume projection preserves an incomplete command block" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(alloc);

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 7,
        .call_id = "streaming-command",
    };
    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(
        lifecycle_id,
        .stdout,
        "partial output\n",
    );
    try projection.finalizeLivePresentation();
    try std.testing.expect(
        projection.runtime.command_output_display.open_command_block != null,
    );
    try std.testing.expect(
        std.mem.find(u8, projection.publication_source.?.bytes, "partial output") == null,
    );
    try std.testing.expectEqualStrings(
        "partial output",
        projection.runtime.command_output_blocks.items[0].lines.items[0].text,
    );

    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    _ = try command_output_runtime.writeCommandOutputChunkDetached(
        &runtime,
        alloc,
        &metrics,
        runtime.retainedTranscriptStyles(),
        lifecycle_id,
        .stdout,
        "completed output\n",
        true,
        43,
    );
    try command_output_runtime.flushCommandOutputSummaryDetached(
        &runtime,
        alloc,
        runtime.retainedTranscriptStyles(),
        lifecycle_id,
        44,
    );
    try std.testing.expect(
        runtime.command_output_display.open_command_block == null,
    );
}

fn checkResumeProjectionAllocationFailures(alloc: Allocator) !void {
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 64,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(std.testing.allocator);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendNotice(.{
        .topic = "session",
        .tone = .neutral,
        .body = "resumed: allocation fixture",
    });
    _ = try projection.appendUserTurn(.{ .text = @constCast("hello") });
    try projection.appendAssistantText("answer\n");
    try projection.finalize();
}

test "resume projection releases every failed detached build" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResumeProjectionAllocationFailures,
        .{},
    );
}

fn checkLiveResumeProjectionAllocationFailures(alloc: Allocator) !void {
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(std.testing.allocator);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(
        .{ .turn_id = 9, .call_id = "allocation-command" },
        .stdout,
        "partial output\n",
    );
    try projection.finalizeLivePresentation();
}

test "live resume projection releases every failed detached build" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLiveResumeProjectionAllocationFailures,
        .{},
    );
}
