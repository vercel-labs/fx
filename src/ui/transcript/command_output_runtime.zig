// Host contract:
// - fields: command_output_blocks, folded_command_blocks,
//   command_output_display, command_output_render,
//   entries, transcript, transcript_band_dirty, replaceable_last_line,
//   replaceable_start, footer_viewport, viewport_top_row, cursor_row,
//   cursor_col, layout
// - methods: assertCanMutateTranscript, appendRawBytesEntryClassified,
//   attachCommandOutputEntryForLifecycle,
//   writeRecordedCommandOutputChunkAtomic,
//   flushRecordedCommandOutputSummaryAtomic,
//   rebuildTranscriptCacheFromEntries,
//   rebuildTranscriptCacheAfterStructuredRewrite,
//   recomputeCursorFromTranscript, enforceStructuredRetention,
//   enforceStructuredRetentionAndReport

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const render_engine = @import("../render_engine.zig");
const assistant_wrap = @import("../render_engine/assistant_wrap.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;

const Styles = transcript_blocks.Styles;

fn requestTranscriptPaint(shell: anytype, entry_id: ?u32) void {
    const Runtime = @TypeOf(shell.*);
    if (entry_id) |dirty_entry_id| {
        if (comptime @hasDecl(Runtime, "markTranscriptCommandOutputDirtyFrom")) {
            shell.markTranscriptCommandOutputDirtyFrom(dirty_entry_id);
            return;
        }
    }
    if (comptime @hasDecl(Runtime, "markTranscriptCommandOutputDirty")) {
        shell.markTranscriptCommandOutputDirty();
    } else if (comptime @hasDecl(Runtime, "markTranscriptContentDirty")) {
        shell.markTranscriptContentDirty();
    } else if (comptime @hasDecl(Runtime, "markTranscriptDirty")) {
        shell.markTranscriptDirty();
    } else {
        shell.transcript_band_dirty = true;
    }
}

fn commandBlockDirtyEntryId(block: CommandOutputBlock) ?u32 {
    if (block.entry_id) |entry_id| return entry_id;
    if (block.live_entry_ids.items.len > 0) return block.live_entry_ids.items[0];
    if (block.source_entry_ids.items.len > 0) return block.source_entry_ids.items[0];
    for (block.lines.items) |line| {
        if (line.entry_id) |entry_id| return entry_id;
    }
    return null;
}

pub fn openCommandOutputDirtyEntryId(shell: anytype) ?u32 {
    const index = shell.command_output_display.open_command_block orelse return null;
    if (index >= shell.command_output_blocks.items.len) return null;
    return commandBlockDirtyEntryId(shell.command_output_blocks.items[index]);
}

pub fn commandOutputDirtyEntryIdForLifecycle(
    shell: anytype,
    lifecycle_id: ?types.ToolLifecycleId,
) ?u32 {
    const index = commandOutputBlockIndexForLifecycle(shell, lifecycle_id) orelse
        return null;
    return commandBlockDirtyEntryId(shell.command_output_blocks.items[index]);
}

pub const CommandOutputLine = struct {
    stream: command_output_content.Stream,
    text: []u8,
    record_ordinal: usize = 0,
    entry_id: ?u32 = null,
    terminated: bool = false,
    visible: bool = true,
};

pub const CommandOutputPrunedRange = struct {
    anchor_entry_id: u32,
    start_record: usize,
    end_record: usize,
};

const command_output_line_descriptor_bytes = @sizeOf(CommandOutputLine);
const command_output_entry_descriptor_bytes = @sizeOf(transcript_blocks.TranscriptEntry);
const command_output_source_id_descriptor_bytes = @sizeOf(u32);
const command_output_pruned_range_descriptor_bytes = @sizeOf(CommandOutputPrunedRange);

pub const CommandOutputBlock = struct {
    entry_id: ?u32 = null,
    lifecycle_id: ?types.ToolLifecycleId = null,
    total_lines: usize = 0,
    retained_text_bytes: usize = 0,
    lines: std.ArrayList(CommandOutputLine) = .empty,
    decoders: [2]command_output_content.Decoder = .{ .{}, .{} },
    open_line_indices: [2]?usize = .{ null, null },
    overflow_open_records: [2]bool = .{ false, false },
    overflow_record_visible: [2]bool = .{ false, false },
    retention_overflow: bool = false,
    /// First retained record whose text became incomplete at the structured
    /// cap. Records before this index are stable for active Ctrl-O projection.
    overflow_line_index: ?usize = null,
    pruned_ranges: std.ArrayList(CommandOutputPrunedRange) = .empty,
    live_entry_ids: std.ArrayList(u32) = .empty,
    source_entry_ids: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *CommandOutputBlock, alloc: Allocator) void {
        if (self.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        for (self.lines.items) |line| alloc.free(line.text);
        self.lines.deinit(alloc);
        self.pruned_ranges.deinit(alloc);
        self.live_entry_ids.deinit(alloc);
        self.source_entry_ids.deinit(alloc);
    }

    pub fn canReconstructEntries(self: CommandOutputBlock) bool {
        return self.pruned_ranges.items.len == 0 and
            self.lines.items.len >= self.live_entry_ids.items.len and
            self.lines.items.len >= self.source_entry_ids.items.len;
    }
};

pub const FoldedCommandBlock = struct {
    summary_transcript_index: usize = 0,
    summary_entry_id: ?u32 = null,
    lines: std.ArrayList(CommandOutputLine) = .empty,

    pub fn deinit(self: *FoldedCommandBlock, alloc: Allocator) void {
        for (self.lines.items) |line| alloc.free(line.text);
        self.lines.deinit(alloc);
    }
};

pub const CommandOutputRenderPolicy = struct {
    styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    },
};

test "command output render policy has no presentation mode" {
    try std.testing.expect(!@hasField(CommandOutputRenderPolicy, "output_level"));
}

pub const compact_output_row_limit: usize = 5;

pub const CommandOutputEntryProjection = struct {
    entry_id: u32,
    byte_start: usize,
    byte_end: usize,
};

pub const CommandOutputProjection = struct {
    bytes: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(CommandOutputEntryProjection) = .empty,

    pub fn deinit(self: *CommandOutputProjection, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    pub fn bytesForEntry(self: *const CommandOutputProjection, entry_id: u32) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.entry_id != entry_id) continue;
            return self.bytes.items[entry.byte_start..entry.byte_end];
        }
        return null;
    }
};

pub fn foldedBlockRetainedBytes(block: FoldedCommandBlock) usize {
    var total: usize = 0;
    for (block.lines.items) |line| total += line.text.len;
    return total;
}

pub fn commandOutputBlockRetainedBytes(block: CommandOutputBlock) usize {
    var total = block.retained_text_bytes;
    for (block.lines.items) |line| {
        total +|= command_output_line_descriptor_bytes;
        if (line.entry_id != null) total +|= command_output_entry_descriptor_bytes;
    }
    total +|= block.pruned_ranges.items.len *|
        (command_output_pruned_range_descriptor_bytes +| command_output_entry_descriptor_bytes);
    total +|= (block.live_entry_ids.items.len +| block.source_entry_ids.items.len) *|
        command_output_source_id_descriptor_bytes;
    return total;
}

pub fn commandOutputLineRetainedBytes(text_bytes: usize) usize {
    return text_bytes +| command_output_line_descriptor_bytes +|
        command_output_entry_descriptor_bytes +|
        command_output_source_id_descriptor_bytes;
}

pub fn commandOutputAdmissionBytes(raw: []const u8) usize {
    var decoder: command_output_content.Decoder = .{};
    var sink: CommandOutputAdmissionSink = .{};
    if (raw.len > 0) sink.beginRecord() catch return std.math.maxInt(usize);
    decoder.append(raw, &sink) catch return std.math.maxInt(usize);
    return sink.text_bytes +|
        sink.record_count *| commandOutputLineRetainedBytes(0);
}

const CommandOutputAdmissionSink = struct {
    text_bytes: usize = 0,
    current_record_bytes: usize = 0,
    record_count: usize = 0,
    open: bool = false,

    pub fn beginRecord(self: *CommandOutputAdmissionSink) error{}!void {
        if (self.open) return;
        self.open = true;
        self.current_record_bytes = 0;
        self.record_count +|= 1;
    }

    pub fn appendText(self: *CommandOutputAdmissionSink, bytes: []const u8) error{}!void {
        try self.beginRecord();
        self.text_bytes +|= bytes.len;
        self.current_record_bytes +|= bytes.len;
    }

    pub fn finishLine(self: *CommandOutputAdmissionSink) error{}!void {
        try self.beginRecord();
        self.open = false;
        self.current_record_bytes = 0;
    }

    pub fn replaceLine(self: *CommandOutputAdmissionSink) error{}!void {
        try self.beginRecord();
        self.text_bytes -|= self.current_record_bytes;
        self.current_record_bytes = 0;
    }
};

pub fn commandArtifactHandleFromResult(result: []const u8) ?[]const u8 {
    const prefix = "output_file=";
    var truncated = false;
    var has_stdout_bytes = false;
    var has_stderr_bytes = false;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "<stdout>") or std.mem.eql(u8, line, "<stderr>")) return null;
        if (std.mem.eql(u8, line, "truncated=true")) {
            truncated = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "stdout_bytes=")) {
            has_stdout_bytes = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "stderr_bytes=")) {
            has_stderr_bytes = true;
            continue;
        }
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (!truncated or !has_stdout_bytes or !has_stderr_bytes) return null;

        const path = line[prefix.len..];
        const handle = std.fs.path.basename(path);
        if (std.mem.startsWith(u8, handle, "fx-command-") and
            std.mem.endsWith(u8, handle, ".log") and
            !std.mem.endsWith(u8, handle, ".stdout.log") and
            !std.mem.endsWith(u8, handle, ".stderr.log"))
        {
            return handle;
        }
        return null;
    }
    return null;
}

pub fn removeFoldedCommandBlock(shell: anytype, alloc: Allocator, index: usize) void {
    var block = shell.folded_command_blocks.orderedRemove(index);
    block.deinit(alloc);

    if (shell.command_output_display.open_block) |open| {
        if (open == index) {
            shell.command_output_display.open_block = null;
        } else if (open > index) {
            shell.command_output_display.open_block = open - 1;
        }
    }
}

pub fn removeCommandOutputBlock(shell: anytype, alloc: Allocator, index: usize) void {
    var block = shell.command_output_blocks.orderedRemove(index);
    block.deinit(alloc);

    if (shell.command_output_display.open_command_block) |open| {
        if (open == index) {
            shell.command_output_display.open_command_block = null;
        } else if (open > index) {
            shell.command_output_display.open_command_block = open - 1;
        }
    }
}

pub fn resetCommandOutputDisplay(shell: anytype, alloc: Allocator, reason: []const u8) void {
    if (shell.command_output_display.open_command_block) |index| {
        if (index < shell.command_output_blocks.items.len and shell.command_output_blocks.items[index].entry_id == null) {
            debug_trace.logf("command_output", "dropping buffered command output lines={d} reason={s}", .{ shell.command_output_blocks.items[index].total_lines, reason });
            removeCommandOutputBlock(shell, alloc, index);
        }
    }
    shell.command_output_display = .{};
}

pub fn setCommandOutputRenderPolicy(shell: anytype, styles: Styles) void {
    shell.command_output_render = .{
        .styles = styles,
    };
}

const PreparedCanonicalRecord = struct {
    text: []u8,
    placeholder: []u8,
};

const PreparedCanonicalBatch = struct {
    block_index: usize,
    stream: command_output_content.Stream,
    total_record_count: usize,
    retained_bytes_after: usize,
    records: std.ArrayList(PreparedCanonicalRecord) = .empty,

    fn deinit(self: *PreparedCanonicalBatch, alloc: Allocator) void {
        for (self.records.items) |record| {
            alloc.free(record.text);
            alloc.free(record.placeholder);
        }
        self.records.deinit(alloc);
        self.* = undefined;
    }
};

/// One owner-level decision for both direct and recorded command-output writes.
/// Prepared canonical buffers remain owned by this value until apply transfers
/// them into the transcript block.
pub const PreparedCommandOutputMutation = union(enum) {
    decode,
    overflow_fragment: usize,
    count_only: struct {
        block_index: usize,
        record_count: usize,
    },
    canonical_batch: PreparedCanonicalBatch,

    pub fn deinit(self: *PreparedCommandOutputMutation, alloc: Allocator) void {
        switch (self.*) {
            .canonical_batch => |*batch| batch.deinit(alloc),
            .decode, .overflow_fragment, .count_only => {},
        }
        self.* = undefined;
    }

    pub fn requiresRecordedShadow(self: PreparedCommandOutputMutation) bool {
        return switch (self) {
            .decode => true,
            .overflow_fragment, .count_only, .canonical_batch => false,
        };
    }
};

pub fn prepareCommandOutputMutation(
    shell: anytype,
    alloc: Allocator,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
) !PreparedCommandOutputMutation {
    const block_index = commandOutputBlockIndexForLifecycle(
        shell,
        lifecycle_id,
    ) orelse
        return .decode;
    const block = &shell.command_output_blocks.items[block_index];

    const stream_index = commandStreamIndex(stream);
    if (record and
        block.overflow_open_records[stream_index] and
        block.decoders[stream_index].isIdle() and
        std.mem.indexOfAny(u8, text, "\r\n\x1b") == null)
    {
        return .{ .overflow_fragment = block_index };
    }

    if (record and
        block.retention_overflow and
        block.open_line_indices[stream_index] == null and
        !block.overflow_open_records[stream_index] and
        text.len > 0 and text[text.len - 1] == '\n' and
        isCountOnlyCommandOutput(text))
    {
        const record_count = std.mem.count(u8, text, "\n");
        if (record_count > 0) {
            return .{ .count_only = .{
                .block_index = block_index,
                .record_count = record_count,
            } };
        }
    }

    if (!record or
        block.total_lines < compact_output_row_limit + 1 or
        block.open_line_indices[stream_index] != null or
        block.overflow_open_records[stream_index])
    {
        return .decode;
    }

    var canonical: command_output_content.CanonicalOutput = .{};
    defer canonical.deinit(alloc);
    try canonical.append(
        alloc,
        switch (stream) {
            .stdout => .stdout,
            .stderr => .stderr,
        },
        text,
    );
    if (canonical.records.items.len == 0) return .decode;
    for (canonical.records.items) |canonical_record| {
        if (!canonical_record.terminated) return .decode;
    }

    const cap = commandOutputRetentionCap(shell);
    var retained = retainedCommandOutputBytes(shell, block_index);
    var retained_count: usize = 0;
    if (!block.retention_overflow) {
        for (canonical.records.items) |canonical_record| {
            const footprint = commandOutputLineRetainedBytes(
                canonical_record.text.items.len,
            );
            if (retained > cap or footprint > cap - retained) break;
            retained += footprint;
            retained_count += 1;
        }
    }

    var batch = PreparedCanonicalBatch{
        .block_index = block_index,
        .stream = stream,
        .total_record_count = canonical.records.items.len,
        .retained_bytes_after = retained,
    };
    errdefer batch.deinit(alloc);
    try batch.records.ensureTotalCapacityPrecise(alloc, retained_count);
    for (canonical.records.items[0..retained_count]) |canonical_record| {
        const owned_text = try alloc.dupe(u8, canonical_record.text.items);
        errdefer alloc.free(owned_text);
        const placeholder = try alloc.alloc(u8, 0);
        batch.records.appendAssumeCapacity(.{
            .text = owned_text,
            .placeholder = placeholder,
        });
    }
    return .{ .canonical_batch = batch };
}

fn isCountOnlyCommandOutput(text: []const u8) bool {
    for (text) |byte| {
        if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) continue;
        return false;
    }
    return true;
}

pub fn applyPreparedCommandOutputMutation(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
    mutation: *PreparedCommandOutputMutation,
) !?u32 {
    return applyPreparedCommandOutputMutationAt(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        record,
        mutation,
        null,
    );
}

fn applyPreparedCommandOutputMutationAt(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
    mutation: *PreparedCommandOutputMutation,
    created_at_ms: ?i64,
) !?u32 {
    return switch (mutation.*) {
        .decode => applyDecodedCommandOutputMutation(
            shell,
            alloc,
            metrics,
            styles,
            lifecycle_id,
            stream,
            text,
            record,
            created_at_ms,
        ),
        .overflow_fragment => |block_index| blk: {
            std.debug.assert(block_index < shell.command_output_blocks.items.len);
            shell.command_output_blocks.items[block_index]
                .overflow_record_visible[commandStreamIndex(stream)] = true;
            requestTranscriptPaint(
                shell,
                commandBlockDirtyEntryId(shell.command_output_blocks.items[block_index]),
            );
            break :blk null;
        },
        .count_only => |prepared| blk: {
            std.debug.assert(prepared.block_index < shell.command_output_blocks.items.len);
            shell.command_output_blocks.items[prepared.block_index].total_lines +|=
                prepared.record_count;
            requestTranscriptPaint(
                shell,
                commandBlockDirtyEntryId(shell.command_output_blocks.items[prepared.block_index]),
            );
            break :blk null;
        },
        .canonical_batch => |*batch| applyCanonicalCommandOutputBatch(
            shell,
            alloc,
            styles,
            batch,
            created_at_ms,
        ),
    };
}

fn applyDecodedCommandOutputMutation(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
    created_at_ms: ?i64,
) !?u32 {
    setCommandOutputRenderPolicy(shell, styles);

    const command_block_index = try ensureOpenCommandOutputBlock(shell, alloc, lifecycle_id);
    const Shell = @TypeOf(shell.*);
    var sink = CommandOutputRecordSink(Shell){
        .shell = shell,
        .alloc = alloc,
        .block_index = command_block_index,
        .stream = stream,
        .record = record,
        .created_at_ms = created_at_ms,
    };
    defer sink.pending_bytes.deinit(alloc);
    const content_stream: command_output_content.Stream = switch (stream) {
        .stdout => .stdout,
        .stderr => .stderr,
    };
    try sink.beginRecord();
    try shell.command_output_blocks.items[command_block_index]
        .decoders[streamIndex(content_stream)]
        .append(text, &sink);
    try sink.flushPending();
    _ = metrics;
    requestTranscriptPaint(
        shell,
        sink.first_entry_id orelse commandBlockDirtyEntryId(
            shell.command_output_blocks.items[command_block_index],
        ),
    );
    return sink.first_entry_id;
}

fn applyCanonicalCommandOutputBatch(
    shell: anytype,
    alloc: Allocator,
    styles: Styles,
    batch: *PreparedCanonicalBatch,
    created_at_ms: ?i64,
) !?u32 {
    const retained_count = batch.records.items.len;
    try shell.command_output_blocks.items[batch.block_index]
        .lines.ensureUnusedCapacity(alloc, retained_count);
    try shell.command_output_blocks.items[batch.block_index]
        .live_entry_ids.ensureUnusedCapacity(alloc, retained_count);
    try shell.entries.ensureUnusedCapacity(alloc, retained_count);

    setCommandOutputRenderPolicy(shell, styles);
    var block = &shell.command_output_blocks.items[batch.block_index];
    var first_entry_id: ?u32 = null;
    const first_record_ordinal = block.total_lines;
    for (batch.records.items, 0..) |prepared_record, record_index| {
        const entry_id = shell.next_entry_id;
        shell.next_entry_id +%= 1;
        shell.entries.appendAssumeCapacity(.{ .raw_bytes = .{
            .id = entry_id,
            .created_at_ms = created_at_ms orelse io_mod.milliTimestamp(),
            .bytes = prepared_record.placeholder,
            .class = .command_output,
        } });
        block.lines.appendAssumeCapacity(.{
            .stream = batch.stream,
            .text = prepared_record.text,
            .record_ordinal = first_record_ordinal +| record_index,
            .entry_id = entry_id,
            .terminated = true,
        });
        block.live_entry_ids.appendAssumeCapacity(entry_id);
        block.retained_text_bytes +|= prepared_record.text.len;
        if (first_entry_id == null) first_entry_id = entry_id;
    }
    batch.records.clearRetainingCapacity();

    const dropped_count = batch.total_record_count - retained_count;
    block.total_lines +|= batch.total_record_count;
    if (dropped_count > 0 and !block.retention_overflow) {
        block.retention_overflow = true;
        block.overflow_line_index = block.lines.items.len;
        debug_trace.logf(
            "command_output",
            "command output retention cap reached retained={d} cap={d}; subsequent records count only",
            .{ batch.retained_bytes_after, commandOutputRetentionCap(shell) },
        );
    }
    requestTranscriptPaint(
        shell,
        first_entry_id orelse commandBlockDirtyEntryId(block.*),
    );
    return first_entry_id;
}

pub fn writeCommandOutputChunk(shell: anytype, alloc: Allocator, metrics: *Metrics, styles: Styles, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
    return writeCommandOutputChunkForLifecycle(
        shell,
        alloc,
        metrics,
        styles,
        null,
        stream,
        text,
        record,
    );
}

pub fn writeCommandOutputChunkForLifecycle(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
) !void {
    if (text.len == 0) return;
    const Runtime = @TypeOf(shell.*);
    if (record and comptime @hasDecl(Runtime, "writeRecordedCommandOutputChunkAtomic")) {
        const entry_id = try shell.writeRecordedCommandOutputChunkAtomic(
            alloc,
            metrics,
            styles,
            lifecycle_id,
            stream,
            text,
        );
        if (entry_id != null and comptime @hasDecl(Runtime, "forgetShimmer")) {
            shell.forgetShimmer();
        }
        return;
    }

    _ = try writeCommandOutputChunkUncommitted(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        record,
    );
}

pub fn writeCommandOutputChunkUncommitted(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
) !?u32 {
    return writeCommandOutputChunkAt(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        record,
        null,
    );
}

fn writeCommandOutputChunkAt(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
    created_at_ms: ?i64,
) !?u32 {
    var mutation = try prepareCommandOutputMutation(
        shell,
        alloc,
        lifecycle_id,
        stream,
        text,
        record,
    );
    defer mutation.deinit(alloc);
    return applyPreparedCommandOutputMutationAt(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        record,
        &mutation,
        created_at_ms,
    );
}

pub fn writeCommandOutputChunkDetached(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
    record: bool,
    created_at_ms: i64,
) !?u32 {
    return writeCommandOutputChunkAt(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        record,
        created_at_ms,
    );
}

pub fn flushCommandOutputSummary(shell: anytype, alloc: Allocator, metrics: *Metrics, styles: Styles, record: bool) !void {
    return flushCommandOutputSummaryForLifecycle(
        shell,
        alloc,
        metrics,
        styles,
        null,
        record,
    );
}

pub fn flushCommandOutputSummaryForLifecycle(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    record: bool,
) !void {
    const Runtime = @TypeOf(shell.*);
    if (record and comptime @hasDecl(Runtime, "flushRecordedCommandOutputSummaryAtomic")) {
        if (commandOutputBlockIndexForLifecycle(shell, lifecycle_id) != null) {
            return shell.flushRecordedCommandOutputSummaryAtomic(
                alloc,
                metrics,
                styles,
                lifecycle_id,
            );
        }
    }

    _ = try flushCommandOutputSummaryUncommitted(
        shell,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        record,
    );
}

pub fn openCommandOutputLifecycleId(
    shell: anytype,
) ?types.ToolLifecycleId {
    const index = shell.command_output_display.open_command_block orelse return null;
    if (index >= shell.command_output_blocks.items.len) return null;
    return shell.command_output_blocks.items[index].lifecycle_id;
}

pub fn flushCommandOutputSummaryUncommitted(
    shell: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    record: bool,
) !bool {
    _ = metrics;
    setCommandOutputRenderPolicy(shell, styles);

    const block_index = commandOutputBlockIndexForLifecycle(
        shell,
        lifecycle_id,
    ) orelse return false;
    const was_displayed = shell.command_output_display.open_command_block == block_index;
    try finishCommandOutputBlock(
        shell,
        alloc,
        block_index,
        record,
        null,
    );
    var retention_changed = false;
    if (record) {
        // Completion makes the block pruneable; retention must not treat
        // a terminal count-only block as still active.
        if (was_displayed) {
            shell.command_output_display.open_command_block = null;
        }
        retention_changed = try consolidateCommandOutputBlock(
            shell,
            alloc,
            block_index,
        );
    } else {
        removeCommandOutputBlock(shell, alloc, block_index);
    }
    if (was_displayed) shell.command_output_display = .{};
    return retention_changed;
}

/// Finish one detached historical command block without rebuilding or
/// retaining the growing transcript. A resume projection synchronizes all
/// command entries once during finalization.
pub fn flushCommandOutputSummaryDetached(
    shell: anytype,
    alloc: Allocator,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    created_at_ms: i64,
) !void {
    setCommandOutputRenderPolicy(shell, styles);
    const block_index = commandOutputBlockIndexForLifecycle(
        shell,
        lifecycle_id,
    ) orelse return;
    const was_displayed = shell.command_output_display.open_command_block == block_index;
    try finishCommandOutputBlock(shell, alloc, block_index, true, created_at_ms);
    if (was_displayed) shell.command_output_display.open_command_block = null;
    try sealCommandOutputBlock(shell, alloc, block_index);
    if (was_displayed) shell.command_output_display = .{};
}

fn finishCommandOutputBlock(
    shell: anytype,
    alloc: Allocator,
    block_index: usize,
    record: bool,
    created_at_ms: ?i64,
) !void {
    const Shell = @TypeOf(shell.*);
    inline for ([_]command_output_content.Stream{ .stdout, .stderr }) |stream| {
        var sink = CommandOutputRecordSink(Shell){
            .shell = shell,
            .alloc = alloc,
            .block_index = block_index,
            .stream = stream,
            .record = record,
            .created_at_ms = created_at_ms,
        };
        defer sink.pending_bytes.deinit(alloc);
        const content_stream: command_output_content.Stream = switch (stream) {
            .stdout => .stdout,
            .stderr => .stderr,
        };
        try shell.command_output_blocks.items[block_index]
            .decoders[streamIndex(content_stream)]
            .finish(&sink);
        try sink.flushPending();
        const stream_index = commandStreamIndex(stream);
        try discardEmptyProvisionalRecord(
            shell,
            alloc,
            block_index,
            stream_index,
        );
        var block = &shell.command_output_blocks.items[block_index];
        block.open_line_indices[stream_index] = null;
        if (block.overflow_open_records[stream_index] and
            !block.overflow_record_visible[stream_index])
        {
            block.total_lines -|= 1;
        }
        block.overflow_open_records[stream_index] = false;
        block.overflow_record_visible[stream_index] = false;
    }
}

fn discardEmptyProvisionalRecord(
    shell: anytype,
    alloc: Allocator,
    block_index: usize,
    stream_index: usize,
) !void {
    var block = &shell.command_output_blocks.items[block_index];
    const line_index = block.open_line_indices[stream_index] orelse return;
    const line = block.lines.items[line_index];
    if (line.visible or line.terminated or line.text.len > 0) return;

    if (line.entry_id) |entry_id| {
        const ids = [_]u32{entry_id};
        removeRawEntriesByIds(shell, alloc, &ids);
        removeEntryId(&block.live_entry_ids, entry_id);
        removeEntryId(&block.source_entry_ids, entry_id);
    }
    alloc.free(line.text);
    _ = block.lines.orderedRemove(line_index);
    block.total_lines -|= 1;
    for (&block.open_line_indices) |*open_index| {
        if (open_index.*) |open| {
            if (open == line_index) {
                open_index.* = null;
            } else if (open > line_index) {
                open_index.* = open - 1;
            }
        }
    }
    if (block.overflow_line_index) |overflow_index| {
        block.overflow_line_index = if (overflow_index == line_index)
            null
        else if (overflow_index > line_index)
            overflow_index - 1
        else
            overflow_index;
    }
}

fn removeEntryId(ids: *std.ArrayList(u32), entry_id: u32) void {
    for (ids.items, 0..) |candidate, index| {
        if (candidate != entry_id) continue;
        _ = ids.orderedRemove(index);
        return;
    }
}

pub fn trimRetainedCommandOutputLine(
    shell: anytype,
    alloc: Allocator,
    block_index: usize,
    line_index: usize,
) !bool {
    var block = &shell.command_output_blocks.items[block_index];
    for (block.open_line_indices) |open_index| {
        if (open_index == line_index) return false;
    }
    const line = block.lines.items[line_index];
    const entry_id = line.entry_id;
    var empty_anchor_bytes: ?[]u8 = null;
    errdefer if (empty_anchor_bytes) |bytes| alloc.free(bytes);
    if (entry_id != null and rawEntryIndex(shell, entry_id.?) != null) {
        try block.pruned_ranges.ensureUnusedCapacity(alloc, 1);
        empty_anchor_bytes = try alloc.alloc(u8, 0);
    }

    std.debug.assert(block.retained_text_bytes >= line.text.len);
    block.retained_text_bytes -= line.text.len;
    alloc.free(line.text);
    _ = block.lines.orderedRemove(line_index);
    for (&block.open_line_indices) |*open_index| {
        if (open_index.*) |open| {
            if (open > line_index) open_index.* = open - 1;
        }
    }
    if (entry_id) |id| {
        removeEntryId(&block.live_entry_ids, id);
        removeEntryId(&block.source_entry_ids, id);
        if (empty_anchor_bytes) |bytes| {
            const entry_index = rawEntryIndex(shell, id).?;
            var raw = &shell.entries.items[entry_index].raw_bytes;
            alloc.free(raw.bytes);
            raw.bytes = bytes;
            raw.class = .command_output;
            empty_anchor_bytes = null;
            block.pruned_ranges.appendAssumeCapacity(.{
                .anchor_entry_id = id,
                .start_record = line.record_ordinal,
                .end_record = line.record_ordinal +| 1,
            });
        }
    }
    _ = coalesceCommandOutputPrunedRanges(shell, alloc, block_index);
    block.retention_overflow = true;
    block.overflow_line_index = if (block.overflow_line_index) |overflow_index|
        @min(overflow_index, line_index)
    else
        line_index;
    return true;
}

fn ensureOpenCommandOutputBlock(
    shell: anytype,
    alloc: Allocator,
    lifecycle_id: ?types.ToolLifecycleId,
) !usize {
    if (commandOutputBlockIndexForLifecycle(shell, lifecycle_id)) |index| {
        if (shell.command_output_display.open_command_block != index) {
            debug_trace.logf(
                "command_output",
                "switching command output display to matching lifecycle",
                .{},
            );
        }
        shell.command_output_display.open_command_block = index;
        return index;
    }
    const owned_lifecycle_id = try dupeLifecycleId(alloc, lifecycle_id);
    errdefer if (owned_lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    try shell.command_output_blocks.append(alloc, .{ .lifecycle_id = owned_lifecycle_id });
    const index = shell.command_output_blocks.items.len - 1;
    shell.command_output_display.open_command_block = index;
    return index;
}

fn commandOutputBlockIndexForLifecycle(
    shell: anytype,
    lifecycle_id: ?types.ToolLifecycleId,
) ?usize {
    if (shell.command_output_display.open_command_block) |index| {
        if (index < shell.command_output_blocks.items.len and sameLifecycleId(
            shell.command_output_blocks.items[index].lifecycle_id,
            lifecycle_id,
        )) return index;
    }
    if (lifecycle_id == null) return null;
    var index = shell.command_output_blocks.items.len;
    while (index > 0) {
        index -= 1;
        if (sameLifecycleId(
            shell.command_output_blocks.items[index].lifecycle_id,
            lifecycle_id,
        )) return index;
    }
    return null;
}

fn CommandOutputRecordSink(comptime Shell: type) type {
    return struct {
        shell: *Shell,
        alloc: Allocator,
        block_index: usize,
        stream: command_output_content.Stream,
        record: bool,
        created_at_ms: ?i64,
        first_entry_id: ?u32 = null,
        pending_line_index: ?usize = null,
        pending_bytes: std.ArrayList(u8) = .empty,

        const Self = @This();
        const RecordTarget = union(enum) {
            retained: usize,
            dropped,
        };

        pub fn appendText(self: *Self, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            const target = try self.ensureOpenRecord();
            switch (target) {
                .dropped => {
                    self.shell.command_output_blocks.items[self.block_index]
                        .overflow_record_visible[commandStreamIndex(self.stream)] = true;
                    return;
                },
                .retained => |line_index| {
                    var block = &self.shell.command_output_blocks.items[self.block_index];
                    const stream_index = commandStreamIndex(self.stream);
                    block.lines.items[line_index].visible = true;
                    if (block.overflow_open_records[stream_index]) return;
                    if (self.pending_line_index != null and
                        self.pending_line_index.? != line_index)
                    {
                        try self.flushPending();
                    }
                    self.pending_line_index = line_index;
                    const pending_len = try std.math.add(
                        usize,
                        self.pending_bytes.items.len,
                        bytes.len,
                    );
                    if (!self.canRetain(pending_len)) {
                        try self.flushPending();
                        self.traceOverflowTransition(block.retention_overflow);
                        block.retention_overflow = true;
                        block.overflow_line_index = if (block.overflow_line_index) |index|
                            @min(index, line_index)
                        else
                            line_index;
                        block.overflow_open_records[stream_index] = true;
                        return;
                    }
                    try self.pending_bytes.appendSlice(self.alloc, bytes);
                },
            }
        }

        pub fn finishLine(self: *Self) !void {
            const target = try self.ensureOpenRecord();
            const stream_index = commandStreamIndex(self.stream);
            try self.flushPending();
            switch (target) {
                .retained => |line_index| {
                    const line = &self.shell.command_output_blocks.items[self.block_index]
                        .lines.items[line_index];
                    line.visible = true;
                    line.terminated = true;
                },
                .dropped => {
                    self.shell.command_output_blocks.items[self.block_index]
                        .overflow_record_visible[stream_index] = true;
                },
            }
            var block = &self.shell.command_output_blocks.items[self.block_index];
            block.open_line_indices[stream_index] = null;
            block.overflow_open_records[stream_index] = false;
            block.overflow_record_visible[stream_index] = false;
        }

        pub fn replaceLine(self: *Self) !void {
            const stream_index = commandStreamIndex(self.stream);
            var block = &self.shell.command_output_blocks.items[self.block_index];
            const line_index = block.open_line_indices[stream_index] orelse {
                // A descriptor-capped record has no retained line to clear,
                // but it is still the same logical record after a bare CR.
                // Keep the open marker so the replacement bytes do not count
                // a second record.
                block.overflow_record_visible[stream_index] = false;
                return;
            };
            if (self.pending_line_index == line_index) {
                self.pending_bytes.clearRetainingCapacity();
                self.pending_line_index = null;
            } else {
                try self.flushPending();
            }
            const old_text = block.lines.items[line_index].text;
            const replacement = try self.alloc.alloc(u8, 0);
            block.lines.items[line_index].text = replacement;
            self.alloc.free(old_text);
            block.lines.items[line_index].terminated = false;
            block.retained_text_bytes -|= old_text.len;
            block.overflow_open_records[stream_index] = false;
            block.overflow_record_visible[stream_index] = false;
            if (block.overflow_line_index == line_index and
                block.total_lines == block.lines.items.len)
            {
                block.overflow_line_index = null;
                block.retention_overflow = false;
            }
        }

        fn ensureOpenRecord(self: *Self) !RecordTarget {
            const stream_index = commandStreamIndex(self.stream);
            var block = &self.shell.command_output_blocks.items[self.block_index];
            if (block.open_line_indices[stream_index]) |line_index| {
                return .{ .retained = line_index };
            }
            if (block.overflow_open_records[stream_index]) return .dropped;

            const record_ordinal = block.total_lines;
            block.total_lines = try std.math.add(usize, block.total_lines, 1);
            const entry_descriptor_bytes: usize = if (self.record)
                command_output_entry_descriptor_bytes +|
                    command_output_source_id_descriptor_bytes
            else
                0;
            const descriptor_bytes = command_output_line_descriptor_bytes +|
                entry_descriptor_bytes;
            if (!self.canRetain(descriptor_bytes)) {
                self.traceOverflowTransition(block.retention_overflow);
                block.retention_overflow = true;
                if (block.overflow_line_index == null) {
                    block.overflow_line_index = block.lines.items.len;
                }
                block.overflow_open_records[stream_index] = true;
                block.overflow_record_visible[stream_index] = false;
                return .dropped;
            }

            var entry_id: ?u32 = null;
            if (self.record) {
                const placeholder = try self.alloc.alloc(u8, 0);
                var placeholder_owned = true;
                errdefer if (placeholder_owned) self.alloc.free(placeholder);
                entry_id = if (self.created_at_ms) |created_at_ms|
                    try self.shell.appendRawBytesEntryClassifiedAt(
                        self.alloc,
                        placeholder,
                        .command_output,
                        created_at_ms,
                    )
                else
                    try self.shell.appendRawBytesEntryClassified(
                        self.alloc,
                        placeholder,
                        .command_output,
                    );
                placeholder_owned = false;
                try block.live_entry_ids.append(self.alloc, entry_id.?);
                if (self.first_entry_id == null) self.first_entry_id = entry_id;
            }

            const line_text = try self.alloc.alloc(u8, 0);
            var line_text_owned = true;
            errdefer if (line_text_owned) self.alloc.free(line_text);
            try block.lines.append(self.alloc, .{
                .stream = self.stream,
                .text = line_text,
                .record_ordinal = record_ordinal,
                .entry_id = entry_id,
                .visible = false,
            });
            line_text_owned = false;
            const line_index = block.lines.items.len - 1;
            block.open_line_indices[stream_index] = line_index;
            return .{ .retained = line_index };
        }

        fn beginRecord(self: *Self) !void {
            _ = try self.ensureOpenRecord();
        }

        fn flushPending(self: *Self) !void {
            const line_index = self.pending_line_index orelse return;
            defer {
                self.pending_bytes.clearRetainingCapacity();
                self.pending_line_index = null;
            }
            if (self.pending_bytes.items.len == 0) return;
            var block = &self.shell.command_output_blocks.items[self.block_index];
            const old_text = block.lines.items[line_index].text;
            const replacement = try self.alloc.alloc(
                u8,
                try std.math.add(usize, old_text.len, self.pending_bytes.items.len),
            );
            @memcpy(replacement[0..old_text.len], old_text);
            @memcpy(replacement[old_text.len..], self.pending_bytes.items);
            self.alloc.free(old_text);
            block.lines.items[line_index].text = replacement;
            block.retained_text_bytes = try std.math.add(
                usize,
                block.retained_text_bytes,
                self.pending_bytes.items.len,
            );
        }

        fn canRetain(self: *Self, additional_bytes: usize) bool {
            const cap = commandOutputRetentionCap(self.shell);
            const retained = retainedCommandOutputBytes(self.shell, self.block_index);
            return retained <= cap and additional_bytes <= cap - retained;
        }

        fn traceOverflowTransition(self: *Self, already_overflowed: bool) void {
            if (already_overflowed) return;
            const cap = commandOutputRetentionCap(self.shell);
            const retained = retainedCommandOutputBytes(self.shell, self.block_index);
            debug_trace.logf(
                "command_output",
                "command output retention cap reached retained={d} cap={d}; subsequent records count only",
                .{ retained, cap },
            );
        }
    };
}

fn commandOutputRetentionCap(shell: anytype) usize {
    const Shell = @TypeOf(shell.*);
    return if (comptime @hasField(Shell, "max_retained_transcript_bytes"))
        shell.max_retained_transcript_bytes
    else
        std.math.maxInt(usize);
}

fn retainedCommandOutputBytes(shell: anytype, block_index: usize) usize {
    if (commandOutputRetentionCap(shell) == std.math.maxInt(usize)) return 0;
    const Shell = @TypeOf(shell.*);
    return if (comptime @hasDecl(Shell, "retainedStructuredBytesForCommandOutput"))
        shell.retainedStructuredBytesForCommandOutput()
    else
        commandOutputBlockRetainedBytes(shell.command_output_blocks.items[block_index]);
}

test "unbounded command output admission does not scan retained state" {
    const CountingShell = struct {
        max_retained_transcript_bytes: usize = std.math.maxInt(usize),
        command_output_blocks: std.ArrayList(CommandOutputBlock) = .empty,
        retained_scan_count: usize = 0,

        fn retainedStructuredBytesForCommandOutput(self: *@This()) usize {
            self.retained_scan_count += 1;
            return 123;
        }
    };

    var shell: CountingShell = .{};
    defer shell.command_output_blocks.deinit(std.testing.allocator);
    try shell.command_output_blocks.append(std.testing.allocator, .{});

    try std.testing.expectEqual(@as(usize, 0), retainedCommandOutputBytes(&shell, 0));
    try std.testing.expectEqual(@as(usize, 0), shell.retained_scan_count);
}

fn commandStreamIndex(stream: command_output_content.Stream) usize {
    return switch (stream) {
        .stdout => 0,
        .stderr => 1,
    };
}

fn streamIndex(stream: command_output_content.Stream) usize {
    return switch (stream) {
        .stdout => 0,
        .stderr => 1,
    };
}

pub fn sameLifecycleId(
    lhs: ?types.ToolLifecycleId,
    rhs: ?types.ToolLifecycleId,
) bool {
    if (lhs) |left| {
        const right = rhs orelse return false;
        return left.turn_id == right.turn_id and std.mem.eql(u8, left.call_id, right.call_id);
    }
    return rhs == null;
}

fn dupeLifecycleId(
    alloc: Allocator,
    lifecycle_id: ?types.ToolLifecycleId,
) !?types.ToolLifecycleId {
    const id = lifecycle_id orelse return null;
    return .{
        .turn_id = id.turn_id,
        .call_id = try alloc.dupe(u8, id.call_id),
    };
}

fn consolidateCommandOutputBlock(
    shell: anytype,
    alloc: Allocator,
    index: usize,
) !bool {
    try shell.assertCanMutateTranscript();

    try sealCommandOutputBlock(shell, alloc, index);

    _ = try syncCommandOutputBlockEntries(shell, alloc);

    if (comptime @hasDecl(@TypeOf(shell.*), "rebuildTranscriptCacheAfterStructuredRewrite")) {
        try shell.rebuildTranscriptCacheAfterStructuredRewrite(
            alloc,
            "command output consolidation",
        );
    } else {
        try shell.rebuildTranscriptCacheFromEntries(alloc, "command output consolidation");
    }
    shell.recomputeCursorFromTranscript();
    requestTranscriptPaint(shell, null);
    if (comptime @hasDecl(@TypeOf(shell.*), "enforceStructuredRetentionAndReport")) {
        return shell.enforceStructuredRetentionAndReport(alloc, shell.command_output_blocks.items[index].entry_id);
    }
    try shell.enforceStructuredRetention(alloc, shell.command_output_blocks.items[index].entry_id);
    return false;
}

fn sealCommandOutputBlock(
    shell: anytype,
    alloc: Allocator,
    index: usize,
) !void {
    var block = &shell.command_output_blocks.items[index];
    try block.source_entry_ids.appendSlice(alloc, block.live_entry_ids.items);
    block.live_entry_ids.clearRetainingCapacity();
    var entry_id: ?u32 = null;
    for (block.source_entry_ids.items) |source_entry_id| {
        if (rawEntryIndex(shell, source_entry_id) == null) continue;
        entry_id = source_entry_id;
        break;
    }
    block.entry_id = entry_id;
    if (entry_id) |id| {
        if (comptime @hasDecl(@TypeOf(shell.*), "attachCommandOutputEntryForLifecycle")) {
            shell.attachCommandOutputEntryForLifecycle(block.lifecycle_id, id);
        }
    }
    if (entry_id) |retained_entry_id| {
        if (comptime @hasDecl(@TypeOf(shell.*), "fullTranscriptAnchorEntryId") and
            @hasDecl(@TypeOf(shell.*), "retargetFullTranscriptAnchor"))
        {
            if (shell.fullTranscriptAnchorEntryId()) |full_anchor_entry_id| {
                if (containsEntryId(block.source_entry_ids.items, full_anchor_entry_id) and
                    rawEntryIndex(shell, full_anchor_entry_id) == null)
                {
                    shell.retargetFullTranscriptAnchor(retained_entry_id);
                }
            }
        }
    }
}

fn rawEntryIndex(shell: anytype, id: u32) ?usize {
    for (shell.entries.items, 0..) |entry, index| {
        if (entry == .raw_bytes and entry.raw_bytes.id == id) return index;
    }
    return null;
}

fn removeRawEntriesByIds(shell: anytype, alloc: Allocator, ids: []const u32) void {
    if (ids.len == 0) return;

    var i: usize = 0;
    while (i < shell.entries.items.len) {
        const entry = shell.entries.items[i];
        if (entry == .raw_bytes and containsEntryId(ids, entry.raw_bytes.id)) {
            var removed = shell.entries.orderedRemove(i);
            removed.deinit(alloc);
            shell.replaceable_last_line = false;
            shell.replaceable_start = 0;
            continue;
        }
        i += 1;
    }
}

fn containsEntryId(ids: []const u32, id: u32) bool {
    for (ids) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

pub fn isPrunedRangeAnchor(block: CommandOutputBlock, entry_id: u32) bool {
    for (block.pruned_ranges.items) |range| {
        if (range.anchor_entry_id == entry_id) return true;
    }
    return false;
}

pub fn commandBlockOwnsEntry(block: CommandOutputBlock, entry_id: u32) bool {
    return block.entry_id == entry_id or
        isPrunedRangeAnchor(block, entry_id) or
        containsEntryId(block.live_entry_ids.items, entry_id) or
        containsEntryId(block.source_entry_ids.items, entry_id);
}

fn commandBlockOwnsSourcePosition(block: CommandOutputBlock, entry_id: u32) bool {
    if (commandBlockOwnsEntry(block, entry_id)) return true;
    for (block.lines.items) |line| {
        if (line.entry_id == entry_id) return true;
    }
    return false;
}

fn commandEntriesShareRun(
    shell: anytype,
    block: CommandOutputBlock,
    lhs_entry_id: u32,
    rhs_entry_id: u32,
) bool {
    const lhs_index = rawEntryIndex(shell, lhs_entry_id) orelse return false;
    const rhs_index = rawEntryIndex(shell, rhs_entry_id) orelse return false;
    const start = @min(lhs_index, rhs_index);
    const end = @max(lhs_index, rhs_index);
    for (shell.entries.items[start + 1 .. end]) |entry| {
        if (!commandBlockOwnsSourcePosition(block, entry.id())) return false;
    }
    return true;
}

fn retargetCommandOutputEntryIdentity(
    shell: anytype,
    block_index: usize,
    removed_entry_id: u32,
    retained_entry_id: u32,
) void {
    var block = &shell.command_output_blocks.items[block_index];
    if (block.entry_id == removed_entry_id) block.entry_id = retained_entry_id;
    const Shell = @TypeOf(shell.*);
    if (comptime @hasField(Shell, "tool_details")) {
        for (shell.tool_details.items) |*detail| {
            if (detail.command_output_entry_id == removed_entry_id) {
                detail.command_output_entry_id = retained_entry_id;
            }
        }
    }
    if (comptime @hasDecl(Shell, "fullTranscriptAnchorEntryId") and
        @hasDecl(Shell, "retargetFullTranscriptAnchor"))
    {
        if (shell.fullTranscriptAnchorEntryId() == removed_entry_id) {
            shell.retargetFullTranscriptAnchor(retained_entry_id);
        }
    }
}

pub fn coalesceCommandOutputPrunedRanges(
    shell: anytype,
    alloc: Allocator,
    block_index: usize,
) bool {
    var changed = false;
    var left_index: usize = 0;
    while (left_index < shell.command_output_blocks.items[block_index].pruned_ranges.items.len) {
        var right_index = left_index + 1;
        while (right_index < shell.command_output_blocks.items[block_index].pruned_ranges.items.len) {
            const block = shell.command_output_blocks.items[block_index];
            const left = block.pruned_ranges.items[left_index];
            const right = block.pruned_ranges.items[right_index];
            const ordinal_adjacent = left.end_record == right.start_record or
                right.end_record == left.start_record;
            if (!ordinal_adjacent or !commandEntriesShareRun(
                shell,
                block,
                left.anchor_entry_id,
                right.anchor_entry_id,
            )) {
                right_index += 1;
                continue;
            }

            const keep_right = block.entry_id == right.anchor_entry_id and
                block.entry_id != left.anchor_entry_id;
            const retained_entry_id = if (keep_right)
                right.anchor_entry_id
            else
                left.anchor_entry_id;
            const removed_entry_id = if (keep_right)
                left.anchor_entry_id
            else
                right.anchor_entry_id;
            const merged_start = @min(left.start_record, right.start_record);
            const merged_end = @max(left.end_record, right.end_record);

            var mutable_block = &shell.command_output_blocks.items[block_index];
            mutable_block.pruned_ranges.items[left_index] = .{
                .anchor_entry_id = retained_entry_id,
                .start_record = merged_start,
                .end_record = merged_end,
            };
            _ = mutable_block.pruned_ranges.orderedRemove(right_index);
            const ids = [_]u32{removed_entry_id};
            removeRawEntriesByIds(shell, alloc, &ids);
            retargetCommandOutputEntryIdentity(
                shell,
                block_index,
                removed_entry_id,
                retained_entry_id,
            );
            changed = true;
        }
        left_index += 1;
    }
    return changed;
}

const CompactLinePlan = struct {
    visible_rows: usize = 0,
    hidden: bool = false,
};

/// Builds the block-wide compact command projection for the active width.
/// Row admission is physical rather than callback/logical-line based, with at
/// most five rows reserved for command output and its process presentation.
pub fn renderCompactCommandOutput(
    alloc: Allocator,
    block: CommandOutputBlock,
    policy: CommandOutputRenderPolicy,
    cols: u16,
) !CommandOutputProjection {
    return renderCompactCommandOutputWithProcessPresentation(
        alloc,
        block,
        policy,
        cols,
        null,
    );
}

pub fn renderCompactCommandOutputWithProcessPresentation(
    alloc: Allocator,
    block: CommandOutputBlock,
    policy: CommandOutputRenderPolicy,
    cols: u16,
    process_presentation: ?types.CommandProcessPresentation,
) !CommandOutputProjection {
    var projection: CommandOutputProjection = .{};
    errdefer projection.deinit(alloc);

    const plans = try alloc.alloc(CompactLinePlan, block.lines.items.len);
    defer alloc.free(plans);
    @memset(plans, .{});

    var remaining_rows: usize = if (cols == 0)
        0
    else
        compact_output_row_limit -| @intFromBool(process_presentation != null);
    var hidden_records = block.total_lines -| block.lines.items.len;
    const final_position = finalCommandOutputPosition(block);

    if (cols > 0) {
        for (block.lines.items, 0..) |line, index| {
            if (!line.visible) continue;
            if (remaining_rows == 0) {
                plans[index].hidden = true;
                hidden_records += 1;
                continue;
            }
            var prefix = try assistant_wrap.wrapLiteralCommandOutputPrefix(
                alloc,
                line.text,
                cols,
                remaining_rows,
            );
            defer prefix.deinit(alloc);
            const row_count = hardLineCount(prefix.bytes);
            plans[index].visible_rows = row_count;
            remaining_rows -|= plans[index].visible_rows;
            const retention_prefix_incomplete = block.retention_overflow and
                block.overflow_line_index == index;
            plans[index].hidden = prefix.has_more or retention_prefix_incomplete;
            if (plans[index].hidden) {
                hidden_records += 1;
            }
        }
    }
    const projection_enabled = cols > 0;
    const terminal_hidden_records = if (projection_enabled) hidden_records else 0;
    const terminal_process = if (projection_enabled) process_presentation else null;

    for (block.lines.items, 0..) |line, index| {
        const entry_id = commandOutputLineEntryId(block, index) orelse continue;
        const final_line = if (final_position) |position|
            position == .line and position.line == index
        else
            false;
        const has_content = plans[index].visible_rows > 0 or
            (final_line and (terminal_hidden_records > 0 or terminal_process != null));
        if (has_content and projection.bytes.items.len > 0) {
            try projection.bytes.append(alloc, '\n');
        }
        const byte_start = projection.bytes.items.len;

        if (plans[index].visible_rows > 0) {
            var prefix = try assistant_wrap.wrapLiteralCommandOutputPrefix(
                alloc,
                line.text,
                cols,
                plans[index].visible_rows,
            );
            defer prefix.deinit(alloc);
            try appendDimmedCommandRows(
                &projection.bytes,
                alloc,
                policy.styles,
                prefix.bytes,
            );
        }
        if (final_line) {
            try appendCompactTerminalRows(
                &projection.bytes,
                alloc,
                policy.styles,
                cols,
                byte_start,
                terminal_process,
                terminal_hidden_records,
            );
        }

        try projection.entries.append(alloc, .{
            .entry_id = entry_id,
            .byte_start = byte_start,
            .byte_end = projection.bytes.items.len,
        });
    }

    for (block.pruned_ranges.items, 0..) |range, index| {
        const final_range = if (final_position) |position|
            position == .pruned_range and position.pruned_range == index
        else
            false;
        const has_content = final_range and
            (terminal_hidden_records > 0 or terminal_process != null);
        if (has_content) {
            if (projection.bytes.items.len > 0) try projection.bytes.append(alloc, '\n');
        }
        const byte_start = projection.bytes.items.len;
        if (has_content) {
            try appendCompactTerminalRows(
                &projection.bytes,
                alloc,
                policy.styles,
                cols,
                byte_start,
                terminal_process,
                terminal_hidden_records,
            );
        }
        try projection.entries.append(alloc, .{
            .entry_id = range.anchor_entry_id,
            .byte_start = byte_start,
            .byte_end = projection.bytes.items.len,
        });
    }

    return projection;
}

const CompactFinalPosition = union(enum) {
    line: usize,
    pruned_range: usize,
};

fn finalCommandOutputPosition(block: CommandOutputBlock) ?CompactFinalPosition {
    var best_end: usize = 0;
    var best: ?CompactFinalPosition = null;
    for (block.lines.items, 0..) |line, index| {
        if (commandOutputLineEntryId(block, index) == null) continue;
        const ordinal = if (index > 0 and line.record_ordinal == 0)
            index
        else
            line.record_ordinal;
        const record_end = ordinal +| 1;
        if (best == null or record_end >= best_end) {
            best_end = record_end;
            best = .{ .line = index };
        }
    }
    for (block.pruned_ranges.items, 0..) |range, index| {
        if (best == null or range.end_record >= best_end) {
            best_end = range.end_record;
            best = .{ .pruned_range = index };
        }
    }
    return best;
}

fn appendCompactTerminalRows(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    styles: Styles,
    cols: u16,
    entry_start: usize,
    process_presentation: ?types.CommandProcessPresentation,
    hidden_records: usize,
) !void {
    if (process_presentation) |presentation| {
        if (out.items.len > entry_start) try out.append(alloc, '\n');
        const status = try processStatusRow(alloc, presentation, cols);
        defer alloc.free(status);
        try appendDimmedCommandRows(out, alloc, styles, status);
    }
    if (hidden_records > 0) {
        if (out.items.len > entry_start) try out.append(alloc, '\n');
        const hint = try foldedHint(alloc, hidden_records, cols);
        defer alloc.free(hint);
        try appendDimmedCommandRows(out, alloc, styles, hint);
    }
}

pub fn processPresentationForBlock(
    shell: anytype,
    block: CommandOutputBlock,
) ?types.CommandProcessPresentation {
    const Shell = @TypeOf(shell.*);
    if (comptime !@hasField(Shell, "tool_details")) return null;
    for (shell.tool_details.items) |detail| {
        if (!detail.isCapturedCommand()) continue;
        if (detail.lifecycle_id != null and block.lifecycle_id != null and
            sameLifecycleId(detail.lifecycle_id, block.lifecycle_id))
        {
            return detail.command_process_presentation;
        }
        if (detail.command_output_entry_id != null and
            detail.command_output_entry_id == block.entry_id)
        {
            return detail.command_process_presentation;
        }
    }
    return null;
}

fn commandOutputLineEntryId(block: CommandOutputBlock, index: usize) ?u32 {
    if (block.lines.items[index].entry_id) |entry_id| return entry_id;
    if (index < block.source_entry_ids.items.len) return block.source_entry_ids.items[index];
    if (index < block.live_entry_ids.items.len) return block.live_entry_ids.items[index];
    if (index == 0) return block.entry_id;
    return null;
}

fn hardLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return std.mem.count(u8, bytes, "\n") + 1;
}

fn appendDimmedCommandRows(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    styles: Styles,
    bytes: []const u8,
) !void {
    return appendDimmedCommandRowsWithGutterStyle(out, alloc, styles, bytes, false);
}

fn appendDimmedCommandRowsWithPrimaryGutter(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    styles: Styles,
    bytes: []const u8,
) !void {
    return appendDimmedCommandRowsWithGutterStyle(out, alloc, styles, bytes, true);
}

fn appendDimmedCommandRowsWithGutterStyle(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    styles: Styles,
    bytes: []const u8,
    primary_gutter: bool,
) !void {
    if (bytes.len == 0) return;

    var row_start: usize = 0;
    while (row_start < bytes.len) {
        const newline_offset = std.mem.findScalar(u8, bytes[row_start..], '\n');
        const row_end = if (newline_offset) |offset| row_start + offset else bytes.len;
        const row = bytes[row_start..row_end];
        if (primary_gutter and std.mem.startsWith(u8, row, "│")) {
            try out.appendSlice(alloc, styles.reset_style);
            try out.appendSlice(alloc, "│");
            try out.appendSlice(alloc, styles.dim_style);
            try out.appendSlice(alloc, row["│".len..]);
        } else {
            try out.appendSlice(alloc, styles.dim_style);
            try out.appendSlice(alloc, row);
        }
        try out.appendSlice(alloc, styles.reset_style);
        if (newline_offset == null) break;
        try out.append(alloc, '\n');
        row_start = row_end + 1;
    }
}

test "dimmed command rows frame physical lines independently" {
    const alloc = std.testing.allocator;
    const styles = Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "<reset>",
        .dim_style = "<dim>",
        .red_style = "",
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendDimmedCommandRows(&out, alloc, styles, "│ one");
    try std.testing.expectEqualStrings("<dim>│ one<reset>", out.items);

    out.clearRetainingCapacity();
    try appendDimmedCommandRows(&out, alloc, styles, "│ one\n\n│ three\n");
    try std.testing.expectEqualStrings(
        "<dim>│ one<reset>\n" ++
            "<dim><reset>\n" ++
            "<dim>│ three<reset>\n",
        out.items,
    );
}

fn foldedHint(alloc: Allocator, hidden_records: usize, cols: u16) ![]u8 {
    const noun = if (hidden_records == 1) "line" else "lines";
    const candidates = [_][]u8{
        try std.fmt.allocPrint(alloc, "│ … {d} {s} more (ctrl o to view)", .{ hidden_records, noun }),
        try std.fmt.allocPrint(alloc, "│ … {d} more (ctrl o)", .{hidden_records}),
        try std.fmt.allocPrint(alloc, "│ … {d} more", .{hidden_records}),
    };
    defer for (candidates) |candidate| alloc.free(candidate);

    for (candidates) |candidate| {
        if (display_width.visibleWidthIgnoringAnsi(candidate) <= cols) {
            return alloc.dupe(u8, candidate);
        }
    }
    return alloc.dupe(
        u8,
        display_width.prefixByWidthIgnoringAnsi(candidates[candidates.len - 1], cols),
    );
}

fn processStatusRow(
    alloc: Allocator,
    presentation: types.CommandProcessPresentation,
    cols: u16,
) ![]u8 {
    const full = switch (presentation) {
        .exit_code => |code| try std.fmt.allocPrint(alloc, "│ exit code {d}", .{code}),
        .signal => |signal| try std.fmt.allocPrint(alloc, "│ signal {d}", .{signal}),
        .timed_out => try alloc.dupe(u8, "│ timed out"),
        .output_capture_failed => try alloc.dupe(u8, "│ output capture failed"),
    };
    defer alloc.free(full);
    return alloc.dupe(u8, display_width.prefixByWidthIgnoringAnsi(full, cols));
}

/// Width-aware, uncapped projection for one retained logical command record.
/// Both streams deliberately share the same neutral style; callers preserve
/// stream order separately.
pub fn renderFullCommandOutputRecord(
    alloc: Allocator,
    styles: Styles,
    text: []const u8,
    cols: u16,
) ![]u8 {
    const wrapped = try assistant_wrap.wrapLiteralCommandOutput(alloc, text, cols);
    defer alloc.free(wrapped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendDimmedCommandRows(&out, alloc, styles, wrapped);
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

pub fn renderCommandOutputRecordWithPrimaryGutter(
    alloc: Allocator,
    styles: Styles,
    text: []const u8,
    cols: u16,
) ![]u8 {
    const wrapped = try assistant_wrap.wrapLiteralCommandOutput(alloc, text, cols);
    defer alloc.free(wrapped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendDimmedCommandRowsWithPrimaryGutter(&out, alloc, styles, wrapped);
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

test "compact and full command output style every wrapped row" {
    const alloc = std.testing.allocator;
    const text = "paragraph words\n\n\tvalue";
    const styles = Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "<reset>",
        .dim_style = "<dim>",
        .red_style = "",
    };
    const expected_rows =
        "<dim>│ paragraph<reset>\n" ++
        "<dim>│ words<reset>\n" ++
        "<dim>│ <reset>\n" ++
        "<dim>│       value<reset>";

    var block: CommandOutputBlock = .{ .total_lines = 1 };
    defer block.deinit(alloc);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, text),
        .entry_id = 10,
        .terminated = true,
    });

    var compact = try renderCompactCommandOutput(alloc, block, .{
        .styles = styles,
    }, 16);
    defer compact.deinit(alloc);
    try std.testing.expectEqualStrings(expected_rows, compact.bytes.items);

    const full = try renderFullCommandOutputRecord(alloc, styles, text, 16);
    defer alloc.free(full);
    try std.testing.expectEqualStrings(expected_rows ++ "\n", full);

    const primary_gutter = try renderCommandOutputRecordWithPrimaryGutter(
        alloc,
        styles,
        text,
        16,
    );
    defer alloc.free(primary_gutter);
    try std.testing.expectEqualStrings(
        "<reset>│<dim> paragraph<reset>\n" ++
            "<reset>│<dim> words<reset>\n" ++
            "<reset>│<dim> <reset>\n" ++
            "<reset>│<dim>       value<reset>\n",
        primary_gutter,
    );
}

test "compact command output caps physical rows" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{};
    defer block.deinit(alloc);

    for (0..7) |index| {
        const text = try std.fmt.allocPrint(alloc, "line-{d}", .{index + 1});
        try block.lines.append(alloc, .{
            .stream = .stdout,
            .text = text,
            .entry_id = @intCast(index + 10),
            .terminated = true,
        });
    }
    block.total_lines = block.lines.items.len;
    block.retained_text_bytes = 42;

    const styles = Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var compact = try renderCompactCommandOutput(alloc, block, .{
        .styles = styles,
    }, 40);
    defer compact.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, compact.bytes.items, "\n") + 1);
    try std.testing.expect(std.mem.find(u8, compact.bytes.items, "│ line-5") != null);
    try std.testing.expect(std.mem.find(u8, compact.bytes.items, "│ line-6") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes.items, "│ … 2 lines more (ctrl o to view)") != null);
}

test "compact command output stays bounded at one and two columns" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{ .total_lines = 1 };
    defer block.deinit(alloc);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "abcdefghijklmnopqrst"),
        .entry_id = 10,
    });
    const styles = Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    for ([_]u16{ 1, 2 }) |cols| {
        var projection = try renderCompactCommandOutput(alloc, block, .{
            .styles = styles,
        }, cols);
        defer projection.deinit(alloc);

        try std.testing.expectEqual(
            @as(usize, compact_output_row_limit + 1),
            hardLineCount(projection.bytes.items),
        );
        var rows = std.mem.splitScalar(u8, projection.bytes.items, '\n');
        while (rows.next()) |row| {
            try std.testing.expect(
                display_width.visibleWidthIgnoringAnsi(row) <= cols,
            );
        }
    }
}

test "compact zero width prefix matches the first five full rows" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{ .total_lines = 1 };
    defer block.deinit(alloc);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.append(alloc, 'a');
    for (0..2000) |_| try text.appendSlice(alloc, "\xcc\x81");
    const line_text = try text.toOwnedSlice(alloc);
    var line_text_owned = true;
    errdefer if (line_text_owned) alloc.free(line_text);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = line_text,
        .entry_id = 10,
    });
    line_text_owned = false;

    const styles = Styles{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var compact = try renderCompactCommandOutput(alloc, block, .{
        .styles = styles,
    }, 4);
    defer compact.deinit(alloc);
    const full = try renderFullCommandOutputRecord(
        alloc,
        styles,
        block.lines.items[0].text,
        4,
    );
    defer alloc.free(full);

    try std.testing.expectEqual(@as(usize, 6), hardLineCount(compact.bytes.items));
    var compact_rows = std.mem.splitScalar(u8, compact.bytes.items, '\n');
    var full_rows = std.mem.splitScalar(u8, full, '\n');
    for (0..compact_output_row_limit) |_| {
        try std.testing.expectEqualStrings(full_rows.next().?, compact_rows.next().?);
    }
    const hint = compact_rows.next() orelse return error.TestExpectedHint;
    try std.testing.expect(std.mem.find(u8, hint, "…") != null);
    try std.testing.expect(compact_rows.next() == null);
    try std.testing.expectEqual(
        @as(usize, compact_output_row_limit *
            (assistant_wrap.literal_command_zero_width_row_byte_limit / 2)),
        std.mem.count(u8, compact.bytes.items, "\xcc\x81"),
    );
}

test "compact incomplete retained record shows one hidden line" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{
        .total_lines = 1,
        .retention_overflow = true,
        .overflow_line_index = 0,
    };
    defer block.deinit(alloc);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "retained prefix"),
        .entry_id = 10,
    });

    var compact = try renderCompactCommandOutput(alloc, block, .{
        .styles = .{
            .system_notice_label_style = "",
            .system_notice_text_style = "",
            .reset_style = "",
            .dim_style = "",
            .red_style = "",
        },
    }, 80);
    defer compact.deinit(alloc);

    try std.testing.expectEqualStrings(
        "│ retained prefix\n│ … 1 line more (ctrl o to view)",
        compact.bytes.items,
    );
}

test "compact hint stays at the final owned source entry" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{ .total_lines = 2 };
    defer block.deinit(alloc);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "one two three four five six seven eight nine ten"),
        .entry_id = 10,
    });
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "later hidden record"),
        .record_ordinal = 1,
        .entry_id = 30,
    });

    var projection = try renderCompactCommandOutput(alloc, block, .{
        .styles = .{
            .system_notice_label_style = "",
            .system_notice_text_style = "",
            .reset_style = "",
            .dim_style = "",
            .red_style = "",
        },
    }, 12);
    defer projection.deinit(alloc);

    const first = projection.bytesForEntry(10).?;
    const final = projection.bytesForEntry(30).?;
    try std.testing.expect(std.mem.find(u8, first, "ctrl o") == null);
    try std.testing.expect(std.mem.find(u8, final, "│ … 2 more") != null);
}

test "compact process row consumes payload budget before final hint" {
    const alloc = std.testing.allocator;
    var block: CommandOutputBlock = .{ .total_lines = 6 };
    defer block.deinit(alloc);
    for (0..6) |index| {
        try block.lines.append(alloc, .{
            .stream = .stdout,
            .text = try std.fmt.allocPrint(alloc, "line-{d}", .{index + 1}),
            .record_ordinal = index,
            .entry_id = @intCast(index + 1),
        });
    }

    var projection = try renderCompactCommandOutputWithProcessPresentation(
        alloc,
        block,
        .{
            .styles = .{
                .system_notice_label_style = "",
                .system_notice_text_style = "",
                .reset_style = "",
                .dim_style = "",
                .red_style = "",
            },
        },
        80,
        .{ .exit_code = 7 },
    );
    defer projection.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 6), hardLineCount(projection.bytes.items));
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-4") != null);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-5") == null);
    const final = projection.bytesForEntry(6).?;
    const status_index = std.mem.find(u8, final, "│ exit code 7") orelse
        return error.TestExpectedStatus;
    const hint_index = std.mem.find(u8, final, "│ … 2 lines more") orelse
        return error.TestExpectedHint;
    try std.testing.expect(status_index < hint_index);
}

test "compact process row names timeout and output capture causes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        presentation: types.CommandProcessPresentation,
        expected: []const u8,
    }{
        .{ .presentation = .timed_out, .expected = "│ timed out" },
        .{ .presentation = .output_capture_failed, .expected = "│ output capture failed" },
    };
    for (cases) |case| {
        const row = try processStatusRow(alloc, case.presentation, 80);
        defer alloc.free(row);
        try std.testing.expectEqualStrings(case.expected, row);
    }
}

pub fn syncCommandOutputBlockEntries(shell: anytype, alloc: Allocator) !bool {
    if (shell.command_output_blocks.items.len == 0) return false;
    var changed = false;
    const cols: u16 = if (shell.layout.cols > 0) shell.layout.cols else 80;
    var entry_indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer entry_indices.deinit(alloc);
    for (shell.entries.items, 0..) |entry, index| {
        if (entry != .raw_bytes) continue;
        const result = try entry_indices.getOrPut(alloc, entry.raw_bytes.id);
        if (!result.found_existing) result.value_ptr.* = index;
    }
    for (shell.command_output_blocks.items) |block| {
        var projection = try renderCompactCommandOutputWithProcessPresentation(
            alloc,
            block,
            shell.command_output_render,
            cols,
            processPresentationForBlock(shell, block),
        );
        defer projection.deinit(alloc);
        for (block.lines.items, 0..) |_, line_index| {
            const entry_id = commandOutputLineEntryId(block, line_index) orelse continue;
            changed = try syncCommandOutputEntry(
                shell,
                alloc,
                projection,
                entry_id,
                &entry_indices,
            ) or changed;
        }
        for (block.pruned_ranges.items) |range| {
            changed = try syncCommandOutputEntry(
                shell,
                alloc,
                projection,
                range.anchor_entry_id,
                &entry_indices,
            ) or changed;
        }
    }
    return changed;
}

fn syncCommandOutputEntry(
    shell: anytype,
    alloc: Allocator,
    projection: CommandOutputProjection,
    entry_id: u32,
    entry_indices: *const std.AutoHashMapUnmanaged(u32, usize),
) !bool {
    const desired = projection.bytesForEntry(entry_id) orelse "";
    const entry_index = entry_indices.get(entry_id) orelse return false;
    var raw = &shell.entries.items[entry_index].raw_bytes;
    raw.class = .command_output;
    if (std.mem.eql(u8, raw.bytes, desired)) return false;
    const replacement = try alloc.dupe(u8, desired);
    alloc.free(raw.bytes);
    raw.bytes = replacement;
    return true;
}
