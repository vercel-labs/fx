const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_preview_lines: usize = 6;
pub const max_encoded_path_bytes: usize = 4 * 1024;
pub const max_encoded_label_bytes: usize = 4 * 1024;
pub const max_encoded_line_bytes: usize = 4 * 1024;
pub const max_encoded_preview_bytes: usize = 24 * 1024;
pub const max_request_projection_bytes: usize = 32 * 1024;

pub const LineOp = enum(u8) { equal, add, remove };

pub const EditKind = enum(u8) { edited, added };

pub const diff_block_start_prefix: []const u8 = "\x1b]9050;";
pub const diff_block_end_prefix: []const u8 = "\x1b]9051;";
const osc_bell: u8 = 0x07;
const trailing_newline_added_marker = "(trailing newline added)";
const trailing_newline_removed_marker = "(trailing newline removed)";

pub const DiffEntry = struct {
    id: u32,
    full: ?FullDiff = null,
    /// Set instead of `full` for resumed history: the full review is built
    /// from the saved snapshots only when someone asks to see it.
    deferred: ?DeferredFullDiff = null,

    pub fn deinit(self: *DiffEntry, alloc: Allocator) void {
        if (self.full) |full| full.deinit(alloc);
        if (self.deferred) |deferred| deferred.deinit(alloc);
    }
};

/// A saved edit whose full before/after review has not been built yet. The
/// strings name the session artifact holding both snapshots and the tool call
/// that artifact is bound to. All strings are owned by the holder.
pub const DeferredFullDiff = struct {
    call_id: []u8,
    content_handle: []u8,
    lifecycle_id: types.ToolLifecycleId,

    /// Copies every borrowed string. Caller owns the result.
    pub fn clone(
        alloc: Allocator,
        call_id: []const u8,
        content_handle: []const u8,
        lifecycle_id: types.ToolLifecycleId,
    ) !DeferredFullDiff {
        const owned_call = try alloc.dupe(u8, call_id);
        errdefer alloc.free(owned_call);
        const owned_handle = try alloc.dupe(u8, content_handle);
        errdefer alloc.free(owned_handle);
        const lifecycle_call = try alloc.dupe(u8, lifecycle_id.call_id);
        return .{
            .call_id = owned_call,
            .content_handle = owned_handle,
            .lifecycle_id = .{ .turn_id = lifecycle_id.turn_id, .call_id = lifecycle_call },
        };
    }

    pub fn deinit(self: DeferredFullDiff, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.content_handle);
        alloc.free(@constCast(self.lifecycle_id.call_id));
    }

    pub fn matches(self: DeferredFullDiff, lifecycle_id: types.ToolLifecycleId) bool {
        return self.lifecycle_id.turn_id == lifecycle_id.turn_id and
            std.mem.eql(u8, self.lifecycle_id.call_id, lifecycle_id.call_id);
    }
};

pub const FullDiff = struct {
    content: []u8,
    lifecycle_id: types.ToolLifecycleId,

    pub fn deinit(self: FullDiff, alloc: Allocator) void {
        alloc.free(self.content);
        alloc.free(@constCast(self.lifecycle_id.call_id));
    }
};

pub const DiffEntryPayload = struct {
    preview: []u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    full: ?FullDiff = null,
    deferred: ?DeferredFullDiff = null,
};

pub fn freeDiffEntryPayload(alloc: Allocator, payload: DiffEntryPayload) void {
    alloc.free(payload.preview);
    if (payload.full) |full| full.deinit(alloc);
    if (payload.deferred) |deferred| deferred.deinit(alloc);
}

test "diff entry payload has one canonical preview" {
    try std.testing.expect(@hasField(DiffEntryPayload, "preview"));
    try std.testing.expect(!@hasField(DiffEntryPayload, "quiet"));
    try std.testing.expect(!@hasField(DiffEntryPayload, "normal"));
    try std.testing.expect(!@hasField(DiffEntryPayload, "active"));
}

pub fn wrapWithMarkers(alloc: Allocator, id: u32, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var id_buf: [16]u8 = undefined;
    const id_str = try std.mem.print(&id_buf, "{d}", .{id});

    try out.appendSlice(alloc, diff_block_start_prefix);
    try out.appendSlice(alloc, id_str);
    try out.append(alloc, osc_bell);
    try out.appendSlice(alloc, content);
    try out.appendSlice(alloc, diff_block_end_prefix);
    try out.appendSlice(alloc, id_str);
    try out.append(alloc, osc_bell);
    return out.toOwnedSlice(alloc);
}

pub fn markedDiffBlockId(bytes: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, bytes, diff_block_start_prefix)) return null;
    const id_start = diff_block_start_prefix.len;
    const bell_pos = std.mem.findScalarPos(u8, bytes, id_start, osc_bell) orelse
        return null;
    const id_digits = bytes[id_start..bell_pos];
    const id = std.fmt.parseInt(u32, id_digits, 10) catch return null;

    var end_marker: [32]u8 = undefined;
    const end = std.mem.print(
        &end_marker,
        "{s}{s}{c}",
        .{ diff_block_end_prefix, id_digits, osc_bell },
    ) catch return null;
    if (!std.mem.endsWith(u8, bytes, end)) return null;
    return id;
}

pub const DiffLine = struct {
    op: LineOp,
    old_num: ?u32 = null,
    new_num: ?u32 = null,
    text: []const u8,
};

pub const PreviewOptions = struct {
    max_lines: usize = max_preview_lines,
    max_indexed_lines: usize = canonical_max_indexed_lines,
    max_matrix_cells: usize = canonical_max_matrix_cells,
    max_encoded_line_bytes: usize = max_encoded_line_bytes,
    max_encoded_preview_bytes: usize = max_encoded_preview_bytes,
};

pub const PreviewOp = enum {
    context,
    addition,
    deletion,
    elision,
    notice,
};

pub const PreviewLine = struct {
    op: PreviewOp,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
};

pub const PreviewValidationError = error{
    TooManyLines,
    PathTooLong,
    InvalidPathMetadata,
    LineTooLong,
    PreviewTooLarge,
    InvalidLineNumbers,
};

pub const FileChangePreview = struct {
    path: []const u8,
    path_basename_start: usize = 0,
    path_source_truncated: bool = false,
    lines: []const PreviewLine,
    additions: usize,
    deletions: usize,
    truncated: bool,

    pub fn validate(self: FileChangePreview) PreviewValidationError!void {
        if (self.path.len > max_encoded_path_bytes) return error.PathTooLong;
        if (self.path.len == 0 or self.path_basename_start >= self.path.len) {
            return error.InvalidPathMetadata;
        }
        if (self.lines.len > max_preview_lines) return error.TooManyLines;

        var encoded_bytes: usize = 0;
        var addition_rows: usize = 0;
        var deletion_rows: usize = 0;
        var elision_rows: usize = 0;
        var notice_rows: usize = 0;
        for (self.lines) |line| {
            if (line.text.len > max_encoded_line_bytes) return error.LineTooLong;
            encoded_bytes = std.math.add(usize, encoded_bytes, line.text.len) catch
                return error.PreviewTooLarge;
            if (encoded_bytes > max_encoded_preview_bytes) return error.PreviewTooLarge;

            const valid_numbers = switch (line.op) {
                .context => line.old_line != null and line.old_line.? > 0 and
                    line.new_line != null and line.new_line.? > 0,
                .addition => line.old_line == null and line.new_line != null and line.new_line.? > 0,
                .deletion => line.old_line != null and line.old_line.? > 0 and line.new_line == null,
                .elision, .notice => line.old_line == null and line.new_line == null,
            };
            if (!valid_numbers) return error.InvalidLineNumbers;

            switch (line.op) {
                .context => {},
                .addition => addition_rows += 1,
                .deletion => deletion_rows += 1,
                .elision => elision_rows += 1,
                .notice => notice_rows += 1,
            }
        }

        if (elision_rows > 1) return error.InvalidLineNumbers;
        if (self.additions == 0 and self.deletions == 0) {
            if (self.lines.len != 1 or notice_rows != 1) return error.InvalidLineNumbers;
            return;
        }
        if (notice_rows != 0 or addition_rows + deletion_rows == 0) {
            return error.InvalidLineNumbers;
        }
        if (addition_rows > self.additions or deletion_rows > self.deletions) {
            return error.InvalidLineNumbers;
        }
    }

    pub fn eql(a: FileChangePreview, b: FileChangePreview) bool {
        if (!std.mem.eql(u8, a.path, b.path)) return false;
        if (a.path_basename_start != b.path_basename_start) return false;
        if (a.path_source_truncated != b.path_source_truncated) return false;
        if (a.lines.len != b.lines.len) return false;
        for (a.lines, b.lines) |a_line, b_line| {
            if (!previewLineEql(a_line, b_line)) return false;
        }
        return a.additions == b.additions and
            a.deletions == b.deletions and
            a.truncated == b.truncated;
    }
};

fn previewLineEql(a: PreviewLine, b: PreviewLine) bool {
    return a.op == b.op and
        a.old_line == b.old_line and
        a.new_line == b.new_line and
        std.mem.eql(u8, a.text, b.text);
}

pub const ProjectedLine = struct {
    op: PreviewOp,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []u8,
};

pub const BoundedDiffProjection = struct {
    lines: []ProjectedLine,
    additions: usize,
    deletions: usize,
    truncated: bool,

    pub fn deinit(self: BoundedDiffProjection, alloc: Allocator) void {
        for (self.lines) |line| alloc.free(line.text);
        alloc.free(self.lines);
    }
};

/// Immutable, borrowed review source for a prepared file mutation.
///
/// Unlike `FileChangePreview`, this never selects a fixed number of changed
/// rows. It borrows the already-frozen file contents and materializes only the
/// requested viewport.
pub const FileReview = struct {
    mode: union(enum) {
        computed: []DiffLine,
        fallback: FallbackReview,
    },
    additions: usize,
    deletions: usize,

    pub fn init(
        alloc: Allocator,
        old_text: []const u8,
        new_text: []const u8,
    ) FileReviewError!FileReview {
        const old_marker = trailingNewlineMarker(old_text, new_text, true);
        const new_marker = trailingNewlineMarker(old_text, new_text, false);
        const old_line_count = try checkedReviewAdd(
            countTextLines(old_text),
            @intFromBool(old_marker != null),
        );
        const new_line_count = try checkedReviewAdd(
            countTextLines(new_text),
            @intFromBool(new_marker != null),
        );
        const indexed_lines = try checkedReviewAdd(old_line_count, new_line_count);
        const matrix_cells = try checkedReviewMul(
            try checkedReviewAdd(old_line_count, 1),
            try checkedReviewAdd(new_line_count, 1),
        );

        if (indexed_lines <= canonical_max_indexed_lines and
            matrix_cells <= canonical_max_matrix_cells)
        {
            const lines = try compute(alloc, old_text, new_text);
            var additions: usize = 0;
            var deletions: usize = 0;
            for (lines) |line| {
                switch (line.op) {
                    .equal => {},
                    .add => additions += 1,
                    .remove => deletions += 1,
                }
            }
            return .{
                .mode = .{ .computed = lines },
                .additions = additions,
                .deletions = deletions,
            };
        }

        const fallback = try FallbackReview.init(
            alloc,
            old_text,
            new_text,
            old_marker,
            new_marker,
        );
        return .{
            .mode = .{ .fallback = fallback },
            .additions = fallback.additions,
            .deletions = fallback.deletions,
        };
    }

    pub fn deinit(self: *FileReview, alloc: Allocator) void {
        switch (self.mode) {
            .computed => |lines| alloc.free(lines),
            .fallback => |fallback| {
                alloc.free(fallback.old_line_starts);
                alloc.free(fallback.new_line_starts);
            },
        }
        self.* = undefined;
    }

    pub fn rowCount(self: FileReview) usize {
        const changed = self.additions + self.deletions;
        if (changed == 0) return 1;
        return switch (self.mode) {
            .computed => |source| countComputedReviewRows(source),
            .fallback => |source| countFallbackReviewRows(source),
        };
    }

    pub fn viewport(
        self: FileReview,
        alloc: Allocator,
        start_row: usize,
        max_rows: usize,
    ) Allocator.Error!ReviewViewport {
        const total_rows = self.rowCount();
        const start = @min(start_row, total_rows);
        const count = @min(max_rows, total_rows - start);
        const lines = try alloc.alloc(ReviewLine, count);
        errdefer alloc.free(lines);

        if (self.additions == 0 and self.deletions == 0) {
            if (count == 1) {
                lines[0] = .{ .op = .notice, .text = "No content changes" };
            }
            return .{ .lines = lines, .total_rows = total_rows };
        }

        switch (self.mode) {
            .computed => |source| fillComputedReviewViewport(lines, source, start),
            .fallback => |fallback| fillFallbackReviewViewport(lines, fallback, start),
        }
        return .{ .lines = lines, .total_rows = total_rows };
    }
};

pub const FileReviewError = error{
    OutOfMemory,
    ArithmeticOverflow,
};

pub const ReviewLine = struct {
    op: PreviewOp,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
    elision_count: usize = 0,
};

pub const ReviewViewport = struct {
    lines: []ReviewLine,
    total_rows: usize,

    pub fn deinit(self: ReviewViewport, alloc: Allocator) void {
        alloc.free(self.lines);
    }
};

const FallbackReview = struct {
    old_text: []const u8,
    new_text: []const u8,
    old_line_starts: []usize,
    new_line_starts: []usize,
    prefix_count: usize,
    suffix_count: usize,
    old_middle_count: usize,
    new_middle_count: usize,
    old_marker: ?[]const u8,
    new_marker: ?[]const u8,
    additions: usize,
    deletions: usize,

    fn init(
        alloc: Allocator,
        old_text: []const u8,
        new_text: []const u8,
        old_marker: ?[]const u8,
        new_marker: ?[]const u8,
    ) FileReviewError!FallbackReview {
        const old_line_starts = try indexLineStarts(alloc, old_text);
        errdefer alloc.free(old_line_starts);
        const new_line_starts = try indexLineStarts(alloc, new_text);
        errdefer alloc.free(new_line_starts);
        const old_normal_count = old_line_starts.len;
        const new_normal_count = new_line_starts.len;
        const comparable_count = @min(old_normal_count, new_normal_count);

        var prefix_count: usize = 0;
        while (prefix_count < comparable_count) {
            const old_line = indexedTextLine(old_text, old_line_starts, prefix_count);
            const new_line = indexedTextLine(new_text, new_line_starts, prefix_count);
            if (!std.mem.eql(u8, old_line.text, new_line.text)) break;
            prefix_count += 1;
        }

        var suffix_count: usize = 0;
        while (prefix_count + suffix_count < comparable_count) {
            const old_line = indexedTextLine(
                old_text,
                old_line_starts,
                old_normal_count - suffix_count - 1,
            );
            const new_line = indexedTextLine(
                new_text,
                new_line_starts,
                new_normal_count - suffix_count - 1,
            );
            if (!std.mem.eql(u8, old_line.text, new_line.text)) break;
            suffix_count += 1;
        }

        const old_middle_count = old_normal_count - prefix_count - suffix_count;
        const new_middle_count = new_normal_count - prefix_count - suffix_count;
        return .{
            .old_text = old_text,
            .new_text = new_text,
            .old_line_starts = old_line_starts,
            .new_line_starts = new_line_starts,
            .prefix_count = prefix_count,
            .suffix_count = suffix_count,
            .old_middle_count = old_middle_count,
            .new_middle_count = new_middle_count,
            .old_marker = old_marker,
            .new_marker = new_marker,
            .additions = try checkedReviewAdd(new_middle_count, @intFromBool(new_marker != null)),
            .deletions = try checkedReviewAdd(old_middle_count, @intFromBool(old_marker != null)),
        };
    }
};

fn checkedReviewAdd(a: usize, b: usize) FileReviewError!usize {
    return std.math.add(usize, a, b) catch error.ArithmeticOverflow;
}

fn checkedReviewMul(a: usize, b: usize) FileReviewError!usize {
    return std.math.mul(usize, a, b) catch error.ArithmeticOverflow;
}

const review_context_lines: usize = 5;

const ReviewRowCounter = struct {
    count: usize = 0,

    fn append(self: *@This(), _: ReviewLine) void {
        self.count += 1;
    }

    fn isFull(_: @This()) bool {
        return false;
    }
};

const ReviewViewportWriter = struct {
    destination: []ReviewLine,
    start_row: usize,
    ordinal: usize = 0,
    written: usize = 0,

    fn append(self: *@This(), line: ReviewLine) void {
        appendReviewViewportLine(
            self.destination,
            &self.ordinal,
            &self.written,
            self.start_row,
            line,
        );
    }

    fn isFull(self: @This()) bool {
        return self.written == self.destination.len;
    }
};

fn countComputedReviewRows(source: []const DiffLine) usize {
    var counter = ReviewRowCounter{};
    visitComputedReviewRows(source, &counter);
    return counter.count;
}

fn countFallbackReviewRows(source: FallbackReview) usize {
    return equalRunRowCount(source.prefix_count) +
        source.deletions +
        source.additions +
        equalRunRowCount(source.suffix_count);
}

fn equalRunRowCount(count: usize) usize {
    return @min(count, review_context_lines) + @intFromBool(count > review_context_lines);
}

fn visitComputedReviewRows(source: []const DiffLine, visitor: anytype) void {
    var source_index: usize = 0;
    while (source_index < source.len) {
        const line = source[source_index];
        switch (line.op) {
            .equal => {
                const run_start = source_index;
                while (source_index < source.len and source[source_index].op == .equal) {
                    source_index += 1;
                }
                appendComputedEqualRun(source, run_start, source_index, visitor);
            },
            .add => {
                visitor.append(.{
                    .op = .addition,
                    .new_line = line.new_num,
                    .text = line.text,
                });
                source_index += 1;
            },
            .remove => {
                visitor.append(.{
                    .op = .deletion,
                    .old_line = line.old_num,
                    .text = line.text,
                });
                source_index += 1;
            },
        }
        if (visitor.isFull()) return;
    }
}

fn appendComputedEqualRun(
    source: []const DiffLine,
    run_start: usize,
    run_end: usize,
    visitor: anytype,
) void {
    if (run_start == 0) {
        const context_start = @max(run_start, run_end -| review_context_lines);
        appendEqualRunElision(visitor, context_start - run_start);
        appendComputedContextRange(source, context_start, run_end, visitor);
        return;
    }

    if (run_end == source.len) {
        const context_end = @min(run_end, run_start + review_context_lines);
        appendComputedContextRange(source, run_start, context_end, visitor);
        appendEqualRunElision(visitor, run_end - context_end);
        return;
    }

    const first_context_end = @min(run_end, run_start + review_context_lines);
    const last_context_start = @max(first_context_end, run_end -| review_context_lines);
    appendComputedContextRange(source, run_start, first_context_end, visitor);
    appendEqualRunElision(visitor, last_context_start - first_context_end);
    appendComputedContextRange(source, last_context_start, run_end, visitor);
}

fn appendComputedContextRange(
    source: []const DiffLine,
    start: usize,
    end: usize,
    visitor: anytype,
) void {
    for (source[start..end]) |line| {
        std.debug.assert(line.op == .equal);
        visitor.append(.{
            .op = .context,
            .old_line = line.old_num,
            .new_line = line.new_num,
            .text = line.text,
        });
    }
}

fn appendEqualRunElision(visitor: anytype, count: usize) void {
    if (count == 0) return;
    visitor.append(.{
        .op = .elision,
        .text = "",
        .elision_count = count,
    });
}

fn fillComputedReviewViewport(
    destination: []ReviewLine,
    source: []const DiffLine,
    start_row: usize,
) void {
    if (destination.len == 0) return;

    var writer = ReviewViewportWriter{
        .destination = destination,
        .start_row = start_row,
    };
    visitComputedReviewRows(source, &writer);
    std.debug.assert(writer.written == destination.len);
}

fn fillFallbackReviewViewport(
    destination: []ReviewLine,
    source: FallbackReview,
    start_row: usize,
) void {
    for (destination, 0..) |*line, offset| {
        line.* = fallbackReviewLineAt(source, start_row + offset);
    }
}

fn fallbackReviewLineAt(source: FallbackReview, ordinal: usize) ReviewLine {
    var section_start: usize = 0;
    const prefix_context_count = @min(source.prefix_count, review_context_lines);
    const prefix_elision_count = source.prefix_count - prefix_context_count;
    if (prefix_elision_count > 0) {
        if (ordinal == section_start) {
            return .{
                .op = .elision,
                .text = "",
                .elision_count = prefix_elision_count,
            };
        }
        section_start += 1;
    }

    if (ordinal < section_start + prefix_context_count) {
        const line_index = prefix_elision_count + ordinal - section_start;
        const line = indexedTextLine(source.old_text, source.old_line_starts, line_index);
        return .{
            .op = .context,
            .old_line = projectedLineNumber(line.number),
            .new_line = projectedLineNumber(line.number),
            .text = line.text,
        };
    }
    section_start += prefix_context_count;

    if (ordinal < section_start + source.old_middle_count) {
        const line_index = source.prefix_count + ordinal - section_start;
        const line = indexedTextLine(source.old_text, source.old_line_starts, line_index);
        return .{
            .op = .deletion,
            .old_line = projectedLineNumber(line.number),
            .text = line.text,
        };
    }
    section_start += source.old_middle_count;

    if (ordinal < section_start + source.new_middle_count) {
        const line_index = source.prefix_count + ordinal - section_start;
        const line = indexedTextLine(source.new_text, source.new_line_starts, line_index);
        return .{
            .op = .addition,
            .new_line = projectedLineNumber(line.number),
            .text = line.text,
        };
    }
    section_start += source.new_middle_count;

    if (source.old_marker) |marker| {
        if (ordinal == section_start) {
            return .{
                .op = .deletion,
                .old_line = projectedLineNumber(source.old_line_starts.len + 1),
                .text = marker,
            };
        }
        section_start += 1;
    }
    if (source.new_marker) |marker| {
        if (ordinal == section_start) {
            return .{
                .op = .addition,
                .new_line = projectedLineNumber(source.new_line_starts.len + 1),
                .text = marker,
            };
        }
        section_start += 1;
    }

    const suffix_context_count = @min(source.suffix_count, review_context_lines);
    if (ordinal < section_start + suffix_context_count) {
        const suffix_offset = ordinal - section_start;
        const old_line_index = source.prefix_count + source.old_middle_count + suffix_offset;
        const new_line_index = source.prefix_count + source.new_middle_count + suffix_offset;
        const old_line = indexedTextLine(source.old_text, source.old_line_starts, old_line_index);
        const new_line = indexedTextLine(source.new_text, source.new_line_starts, new_line_index);
        return .{
            .op = .context,
            .old_line = projectedLineNumber(old_line.number),
            .new_line = projectedLineNumber(new_line.number),
            .text = old_line.text,
        };
    }
    section_start += suffix_context_count;

    const suffix_elision_count = source.suffix_count - suffix_context_count;
    if (suffix_elision_count > 0 and ordinal == section_start) {
        return .{
            .op = .elision,
            .text = "",
            .elision_count = suffix_elision_count,
        };
    }
    unreachable;
}

fn appendReviewViewportLine(
    destination: []ReviewLine,
    ordinal: *usize,
    written: *usize,
    start_row: usize,
    line: ReviewLine,
) void {
    if (ordinal.* >= start_row and written.* < destination.len) {
        destination[written.*] = line;
        written.* += 1;
    }
    ordinal.* += 1;
}

const BoundedPreviewError = error{
    OutOfMemory,
    InvalidPreviewOptions,
    PreviewBudgetExceeded,
    ArithmeticOverflow,
};

pub const Stats = struct {
    additions: u32 = 0,
    deletions: u32 = 0,
};

pub const FormatStyles = struct {
    added_fg: []const u8 = "\x1b[38;5;252m",
    removed_fg: []const u8 = "\x1b[38;5;252m",
    context_fg: []const u8 = "\x1b[38;5;245m",
    // Optional accent for the line number and +/- sign only. Empty means the
    // marker stays in the line color (fully monochrome, the historical look).
    added_marker_fg: []const u8 = "",
    removed_marker_fg: []const u8 = "",
    reset: []const u8 = "\x1b[0m",
};

pub fn compute(alloc: Allocator, old_text: []const u8, new_text: []const u8) ![]DiffLine {
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(alloc);
    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(alloc);

    try appendLines(alloc, &old_lines, old_text);
    try appendLines(alloc, &new_lines, new_text);
    try appendTrailingNewlineMarker(alloc, &old_lines, &new_lines, old_text, new_text);

    const old_len = old_lines.items.len;
    const new_len = new_lines.items.len;
    const stride = new_len + 1;

    const table = try alloc.alloc(u32, (old_len + 1) * stride);
    defer alloc.free(table);
    @memset(table, 0);

    var old_index: usize = 1;
    while (old_index <= old_len) : (old_index += 1) {
        var new_index: usize = 1;
        while (new_index <= new_len) : (new_index += 1) {
            if (std.mem.eql(u8, old_lines.items[old_index - 1], new_lines.items[new_index - 1])) {
                table[old_index * stride + new_index] = table[(old_index - 1) * stride + new_index - 1] + 1;
            } else {
                const left = table[old_index * stride + new_index - 1];
                const up = table[(old_index - 1) * stride + new_index];
                table[old_index * stride + new_index] = @max(left, up);
            }
        }
    }

    var result: std.ArrayList(DiffLine) = .empty;
    errdefer result.deinit(alloc);

    var old_cursor = old_len;
    var new_cursor = new_len;
    while (old_cursor > 0 or new_cursor > 0) {
        if (old_cursor > 0 and new_cursor > 0 and std.mem.eql(u8, old_lines.items[old_cursor - 1], new_lines.items[new_cursor - 1])) {
            try result.append(alloc, .{
                .op = .equal,
                .old_num = @intCast(old_cursor),
                .new_num = @intCast(new_cursor),
                .text = old_lines.items[old_cursor - 1],
            });
            old_cursor -= 1;
            new_cursor -= 1;
        } else if (new_cursor > 0 and (old_cursor == 0 or table[old_cursor * stride + new_cursor - 1] >= table[(old_cursor - 1) * stride + new_cursor])) {
            try result.append(alloc, .{
                .op = .add,
                .new_num = @intCast(new_cursor),
                .text = new_lines.items[new_cursor - 1],
            });
            new_cursor -= 1;
        } else {
            try result.append(alloc, .{
                .op = .remove,
                .old_num = @intCast(old_cursor),
                .text = old_lines.items[old_cursor - 1],
            });
            old_cursor -= 1;
        }
    }

    std.mem.reverse(DiffLine, result.items);
    return result.toOwnedSlice(alloc);
}

pub fn buildBoundedPreview(
    alloc: Allocator,
    old_text: []const u8,
    new_text: []const u8,
    options: PreviewOptions,
) BoundedPreviewError!BoundedDiffProjection {
    try validatePreviewOptions(options);

    const old_marker = trailingNewlineMarker(old_text, new_text, true);
    const new_marker = trailingNewlineMarker(old_text, new_text, false);
    const old_line_count = try checkedAdd(countTextLines(old_text), @intFromBool(old_marker != null));
    const new_line_count = try checkedAdd(countTextLines(new_text), @intFromBool(new_marker != null));
    if (try previewUsesCompute(old_line_count, new_line_count, options)) {
        return buildComputedPreview(alloc, old_text, new_text, options);
    }
    return buildFallbackPreview(
        alloc,
        old_text,
        new_text,
        old_marker,
        new_marker,
        options,
    );
}

pub const FileChangeFullView = struct {
    after_content: []const u8,
    lifecycle_id: types.ToolLifecycleId,
};

pub fn formatFileChangePayload(
    alloc: Allocator,
    full_alloc: Allocator,
    preview: FileChangePreview,
    previous_content: ?[]const u8,
    full_view: ?FileChangeFullView,
    styles: FormatStyles,
) !DiffEntryPayload {
    const additions = std.math.cast(u32, preview.additions) orelse
        return error.DiffStatOverflow;
    const deletions = std.math.cast(u32, preview.deletions) orelse
        return error.DiffStatOverflow;
    const formatted_preview = try formatFileChangePreview(alloc, preview, styles);
    errdefer alloc.free(formatted_preview);
    const full = formatFileChangeFullDiff(
        full_alloc,
        previous_content,
        full_view,
        styles,
    ) catch |err| blk: {
        debug_trace.logf(
            "tool",
            "committed file full diff formatting unavailable err={s}",
            .{@errorName(err)},
        );
        break :blk null;
    };
    return .{
        .preview = formatted_preview,
        .additions = additions,
        .deletions = deletions,
        .full = full,
    };
}

pub fn formatPersistedFileChangePayload(
    alloc: Allocator,
    presentation: types.CommittedFilePresentation,
    styles: FormatStyles,
) !DiffEntryPayload {
    const lines = try alloc.alloc(PreviewLine, presentation.lines.len);
    defer alloc.free(lines);
    for (presentation.lines, 0..) |line, index| {
        lines[index] = .{
            .op = switch (line.kind) {
                .context => .context,
                .addition => .addition,
                .deletion => .deletion,
                .elision => .elision,
                .notice => .notice,
            },
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = line.text,
        };
    }
    const full_view = if (presentation.after_content) |after_content| if (presentation.lifecycle_id) |lifecycle_id|
        FileChangeFullView{
            .after_content = after_content,
            .lifecycle_id = lifecycle_id,
        }
    else
        null else null;
    return formatFileChangePayload(
        alloc,
        alloc,
        .{
            .path = presentation.path,
            .lines = lines,
            .additions = presentation.additions,
            .deletions = presentation.deletions,
            .truncated = presentation.truncated,
        },
        presentation.previous_content,
        full_view,
        styles,
    );
}

pub fn formatFileChangeFullDiff(
    alloc: Allocator,
    previous_content: ?[]const u8,
    full_view: ?FileChangeFullView,
    styles: FormatStyles,
) !?FullDiff {
    const snapshot = full_view orelse return null;
    var review = try FileReview.init(
        alloc,
        previous_content orelse "",
        snapshot.after_content,
    );
    defer review.deinit(alloc);
    var viewport = try review.viewport(alloc, 0, review.rowCount());
    defer viewport.deinit(alloc);

    const content = try formatFileChangeReviewLines(alloc, viewport.lines, styles);
    errdefer alloc.free(content);
    const call_id = try alloc.dupe(u8, snapshot.lifecycle_id.call_id);
    errdefer alloc.free(call_id);
    return .{
        .content = content,
        .lifecycle_id = .{
            .turn_id = snapshot.lifecycle_id.turn_id,
            .call_id = call_id,
        },
    };
}

fn formatFileChangeReviewLines(
    alloc: Allocator,
    lines: []const ReviewLine,
    styles: FormatStyles,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var max_line_number: u32 = 1;
    for (lines) |line| {
        const line_number = line.new_line orelse line.old_line orelse continue;
        max_line_number = @max(max_line_number, line_number);
    }
    const gutter_width = decimalDigits(max_line_number);

    for (lines) |line| {
        var elision_text: [64]u8 = undefined;
        const text = if (line.op == .elision)
            try std.mem.print(&elision_text, "{d} unchanged lines ⋯", .{line.elision_count})
        else
            line.text;
        try appendDiffRenderLine(alloc, &out, .{
            .op = line.op,
            .line_number = line.new_line orelse line.old_line,
            .gutter_width = gutter_width,
            .text = text,
        }, styles);
    }

    return out.toOwnedSlice(alloc);
}

pub fn formatFileChangePreview(
    alloc: Allocator,
    preview: FileChangePreview,
    styles: FormatStyles,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var max_line_number: u32 = 1;
    for (preview.lines) |line| {
        const line_number = line.new_line orelse line.old_line orelse continue;
        max_line_number = @max(max_line_number, line_number);
    }
    const gutter_width = decimalDigits(max_line_number);

    for (preview.lines) |line| {
        try appendDiffRenderLine(alloc, &out, .{
            .op = line.op,
            .line_number = line.new_line orelse line.old_line,
            .gutter_width = gutter_width,
            .text = line.text,
        }, styles);
    }

    return out.toOwnedSlice(alloc);
}

const DiffRenderLine = struct {
    op: PreviewOp,
    line_number: ?u32,
    gutter_width: usize,
    text: []const u8,
};

fn appendDiffRenderLine(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    line: DiffRenderLine,
    styles: FormatStyles,
) !void {
    const line_style = previewLineStyle(line.op, styles);
    const marker_style = previewMarkerStyle(line.op, styles);
    const accent = marker_style.len != 0;

    try out.appendSlice(alloc, line_style);
    try out.appendSlice(alloc, "  │ ");
    // The number and sign carry the accent; the text falls back to the line
    // color so only the marker is colored.
    if (accent) try out.appendSlice(alloc, marker_style);
    try appendDiffLineNumber(alloc, out, line.line_number, line.gutter_width);
    try out.append(alloc, ' ');
    try out.append(alloc, previewLineSign(line.op));
    if (accent) try out.appendSlice(alloc, line_style);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, line.text);
    try out.appendSlice(alloc, styles.reset);
    try out.append(alloc, '\n');
}

fn appendDiffElisionLine(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    gutter_width: usize,
    styles: FormatStyles,
) !void {
    try appendDiffRenderLine(alloc, out, .{
        .op = .elision,
        .line_number = null,
        .gutter_width = gutter_width,
        .text = "⋯",
    }, styles);
}

fn previewLineStyle(op: PreviewOp, styles: FormatStyles) []const u8 {
    return switch (op) {
        .addition => styles.added_fg,
        .deletion => styles.removed_fg,
        .context, .elision, .notice => styles.context_fg,
    };
}

fn previewMarkerStyle(op: PreviewOp, styles: FormatStyles) []const u8 {
    return switch (op) {
        .addition => styles.added_marker_fg,
        .deletion => styles.removed_marker_fg,
        .context, .elision, .notice => "",
    };
}

fn previewLineSign(op: PreviewOp) u8 {
    return switch (op) {
        .addition => '+',
        .deletion => '-',
        .context, .elision, .notice => ' ',
    };
}

fn appendDiffLineNumber(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    line_number: ?u32,
    width: usize,
) !void {
    var number_buffer: [10]u8 = undefined;
    const number = if (line_number) |value|
        try std.mem.print(&number_buffer, "{d}", .{value})
    else
        "";
    try out.appendNTimes(alloc, ' ', width - number.len);
    try out.appendSlice(alloc, number);
}

fn decimalDigits(value: u32) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn diffPreviewOp(op: LineOp) PreviewOp {
    return switch (op) {
        .equal => .context,
        .add => .addition,
        .remove => .deletion,
    };
}

pub fn countStats(diff: []const DiffLine) Stats {
    var stats: Stats = .{};
    for (diff) |line| {
        switch (line.op) {
            .equal => {},
            .add => stats.additions += 1,
            .remove => stats.deletions += 1,
        }
    }
    return stats;
}

pub const context_lines: usize = 2;
const max_display_lines: usize = 6;

pub fn formatUnified(
    alloc: Allocator,
    diff: []const DiffLine,
    styles: FormatStyles,
    path: ?[]const u8,
    kind: EditKind,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    _ = kind;
    _ = path;

    const include = try alloc.alloc(bool, diff.len);
    defer alloc.free(include);
    @memset(include, false);

    for (diff, 0..) |line, index| {
        if (line.op == .equal) continue;
        const start = if (index >= context_lines) index - context_lines else 0;
        const end = @min(index + context_lines + 1, diff.len);
        for (start..end) |include_index| {
            include[include_index] = true;
        }
    }

    var max_num: u32 = 1;
    for (diff, 0..) |line, index| {
        if (!include[index]) continue;
        const line_num = line.new_num orelse line.old_num orelse 0;
        if (line_num > max_num) max_num = line_num;
    }
    const gutter = decimalDigits(max_num);

    var prev_included = false;
    var emitted_any = false;
    var emitted_lines: usize = 0;
    for (diff, 0..) |line, index| {
        if (!include[index]) {
            prev_included = false;
            continue;
        }
        if (emitted_lines >= max_display_lines) {
            try appendDiffElisionLine(alloc, &out, gutter, styles);
            break;
        }
        if (!prev_included and emitted_any) {
            try appendDiffElisionLine(alloc, &out, gutter, styles);
        }

        try appendDiffRenderLine(alloc, &out, .{
            .op = diffPreviewOp(line.op),
            .line_number = line.new_num orelse line.old_num,
            .gutter_width = gutter,
            .text = line.text,
        }, styles);

        prev_included = true;
        emitted_any = true;
        emitted_lines += 1;
    }

    return out.toOwnedSlice(alloc);
}

const canonical_max_indexed_lines: usize = 16_384;
const canonical_max_matrix_cells: usize = 1_000_000;

const SelectedLine = struct {
    op: PreviewOp,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
};

const SelectionPlan = struct {
    output_count: usize,
    head_count: usize,
    tail_count: usize,
    truncated: bool,
};

const TextLine = struct {
    number: usize,
    text: []const u8,
};

const ForwardLineIterator = struct {
    text: []const u8,
    cursor: usize = 0,
    next_number: usize = 1,

    fn next(self: *ForwardLineIterator) ?TextLine {
        if (self.cursor >= self.text.len) return null;

        const start = self.cursor;
        const newline = std.mem.findScalarPos(u8, self.text, start, '\n');
        const end = newline orelse self.text.len;
        self.cursor = if (newline) |index| index + 1 else self.text.len;

        const result = TextLine{
            .number = self.next_number,
            .text = self.text[start..end],
        };
        self.next_number +|= 1;
        return result;
    }
};

const ReverseLineIterator = struct {
    text: []const u8,
    end: usize,
    next_number: usize,

    fn init(text: []const u8, line_count: usize) ReverseLineIterator {
        return .{
            .text = text,
            .end = text.len,
            .next_number = line_count,
        };
    }

    fn next(self: *ReverseLineIterator) ?TextLine {
        if (self.end == 0) return null;

        const logical_end = if (self.text[self.end - 1] == '\n') self.end - 1 else self.end;
        var start = logical_end;
        while (start > 0 and self.text[start - 1] != '\n') start -= 1;
        const result = TextLine{
            .number = self.next_number,
            .text = self.text[start..logical_end],
        };
        self.end = start;
        self.next_number -= 1;
        return result;
    }
};

fn validatePreviewOptions(options: PreviewOptions) BoundedPreviewError!void {
    if (options.max_lines == 0 or options.max_lines > max_preview_lines or
        options.max_indexed_lines == 0 or options.max_indexed_lines > canonical_max_indexed_lines or
        options.max_matrix_cells == 0 or options.max_matrix_cells > canonical_max_matrix_cells or
        options.max_encoded_line_bytes == 0 or options.max_encoded_line_bytes > max_encoded_line_bytes or
        options.max_encoded_preview_bytes == 0 or options.max_encoded_preview_bytes > max_encoded_preview_bytes)
    {
        return error.InvalidPreviewOptions;
    }
}

fn previewUsesCompute(
    old_line_count: usize,
    new_line_count: usize,
    options: PreviewOptions,
) BoundedPreviewError!bool {
    try validatePreviewOptions(options);

    const indexed_lines = try checkedAdd(old_line_count, new_line_count);
    if (indexed_lines > options.max_indexed_lines) return false;
    return try checkedMul(
        try checkedAdd(old_line_count, 1),
        try checkedAdd(new_line_count, 1),
    ) <= options.max_matrix_cells;
}

fn buildComputedPreview(
    alloc: Allocator,
    old_text: []const u8,
    new_text: []const u8,
    options: PreviewOptions,
) BoundedPreviewError!BoundedDiffProjection {
    const full_diff = compute(alloc, old_text, new_text) catch
        return error.OutOfMemory;
    defer alloc.free(full_diff);

    var additions: usize = 0;
    var deletions: usize = 0;
    for (full_diff) |line| {
        switch (line.op) {
            .equal => {},
            .add => additions = try checkedAdd(additions, 1),
            .remove => deletions = try checkedAdd(deletions, 1),
        }
    }

    const total_changed = try checkedAdd(additions, deletions);
    var selected: [max_preview_lines]SelectedLine = undefined;
    const selection = selectComputedLines(
        full_diff,
        total_changed,
        options.max_lines,
        &selected,
    );

    return materializeProjection(
        alloc,
        selected[0..selection.output_count],
        additions,
        deletions,
        selection.truncated,
        options,
    );
}

const ComputedSelection = struct {
    output_count: usize,
    truncated: bool,
};

fn selectComputedLines(
    full_diff: []const DiffLine,
    total_changed: usize,
    max_lines: usize,
    selected: *[max_preview_lines]SelectedLine,
) ComputedSelection {
    if (total_changed == 0) {
        selected[0] = .{ .op = .notice, .text = "No changes" };
        return .{ .output_count = 1, .truncated = false };
    }
    if (total_changed > max_lines) {
        const plan = selectionPlan(total_changed, max_lines);
        initializeSelection(selected, plan);
        var ordinal: usize = 0;
        for (full_diff) |line| {
            const projected = selectedLineFromDiff(line) orelse continue;
            retainSelected(
                selected,
                ordinal,
                total_changed,
                plan,
                projected,
            );
            ordinal += 1;
        }
        return .{
            .output_count = plan.output_count,
            .truncated = true,
        };
    }

    var first_changed: ?usize = null;
    var last_changed: usize = 0;
    var hunk_count: usize = 0;
    var in_hunk = false;
    for (full_diff, 0..) |line, index| {
        if (line.op == .equal) {
            in_hunk = false;
            continue;
        }
        if (!in_hunk) {
            hunk_count += 1;
            in_hunk = true;
        }
        if (first_changed == null) first_changed = index;
        last_changed = index;
    }

    const first = first_changed.?;
    const before = if (first > 0 and full_diff[first - 1].op == .equal)
        first - 1
    else
        null;
    const after = if (last_changed + 1 < full_diff.len and
        full_diff[last_changed + 1].op == .equal)
        last_changed + 1
    else
        null;
    const context_slots = max_lines - total_changed;
    const include_both = hunk_count == 1 and
        before != null and
        after != null and
        context_slots >= 2;
    const include_before = include_both or
        (hunk_count == 1 and
            before != null and
            after == null and
            context_slots >= 1);
    const include_after = include_both or
        (hunk_count == 1 and
            before == null and
            after != null and
            context_slots >= 1);

    var output_count: usize = 0;
    if (include_before) {
        selected[output_count] = selectedContextLine(
            full_diff[before.?],
        );
        output_count += 1;
    }
    for (full_diff) |line| {
        const projected = selectedLineFromDiff(line) orelse continue;
        selected[output_count] = projected;
        output_count += 1;
    }
    if (include_after) {
        selected[output_count] = selectedContextLine(
            full_diff[after.?],
        );
        output_count += 1;
    }
    return .{ .output_count = output_count, .truncated = false };
}

fn selectedLineFromDiff(line: DiffLine) ?SelectedLine {
    return switch (line.op) {
        .equal => null,
        .add => .{
            .op = .addition,
            .new_line = line.new_num,
            .text = line.text,
        },
        .remove => .{
            .op = .deletion,
            .old_line = line.old_num,
            .text = line.text,
        },
    };
}

fn selectedContextLine(line: DiffLine) SelectedLine {
    std.debug.assert(line.op == .equal);
    return .{
        .op = .context,
        .old_line = line.old_num,
        .new_line = line.new_num,
        .text = line.text,
    };
}

fn buildFallbackPreview(
    alloc: Allocator,
    old_text: []const u8,
    new_text: []const u8,
    old_marker: ?[]const u8,
    new_marker: ?[]const u8,
    options: PreviewOptions,
) BoundedPreviewError!BoundedDiffProjection {
    const old_normal_count = countTextLines(old_text);
    const new_normal_count = countTextLines(new_text);
    const comparable_count = @min(old_normal_count, new_normal_count);

    var prefix_count: usize = 0;
    var old_forward = ForwardLineIterator{ .text = old_text };
    var new_forward = ForwardLineIterator{ .text = new_text };
    while (prefix_count < comparable_count) {
        const old_line = old_forward.next().?;
        const new_line = new_forward.next().?;
        if (!std.mem.eql(u8, old_line.text, new_line.text)) break;
        prefix_count += 1;
    }

    var suffix_count: usize = 0;
    var old_reverse = ReverseLineIterator.init(old_text, old_normal_count);
    var new_reverse = ReverseLineIterator.init(new_text, new_normal_count);
    while (prefix_count + suffix_count < comparable_count) {
        const old_line = old_reverse.next().?;
        const new_line = new_reverse.next().?;
        if (!std.mem.eql(u8, old_line.text, new_line.text)) break;
        suffix_count += 1;
    }

    const old_middle_count = old_normal_count - prefix_count - suffix_count;
    const new_middle_count = new_normal_count - prefix_count - suffix_count;
    const deletions = try checkedAdd(old_middle_count, @intFromBool(old_marker != null));
    const additions = try checkedAdd(new_middle_count, @intFromBool(new_marker != null));
    const total_changed = try checkedAdd(additions, deletions);
    const plan = selectionPlan(total_changed, options.max_lines);
    var selected: [max_preview_lines]SelectedLine = undefined;
    initializeSelection(&selected, plan);

    var ordinal: usize = 0;
    old_forward = .{ .text = old_text };
    for (0..prefix_count) |_| _ = old_forward.next();
    for (0..old_middle_count) |_| {
        const line = old_forward.next().?;
        retainSelected(&selected, ordinal, total_changed, plan, .{
            .op = .deletion,
            .old_line = projectedLineNumber(line.number),
            .text = line.text,
        });
        ordinal += 1;
    }

    new_forward = .{ .text = new_text };
    for (0..prefix_count) |_| _ = new_forward.next();
    for (0..new_middle_count) |_| {
        const line = new_forward.next().?;
        retainSelected(&selected, ordinal, total_changed, plan, .{
            .op = .addition,
            .new_line = projectedLineNumber(line.number),
            .text = line.text,
        });
        ordinal += 1;
    }

    if (old_marker) |marker| {
        retainSelected(&selected, ordinal, total_changed, plan, .{
            .op = .deletion,
            .old_line = projectedLineNumber(try checkedAdd(old_normal_count, 1)),
            .text = marker,
        });
        ordinal += 1;
    }
    if (new_marker) |marker| {
        retainSelected(&selected, ordinal, total_changed, plan, .{
            .op = .addition,
            .new_line = projectedLineNumber(try checkedAdd(new_normal_count, 1)),
            .text = marker,
        });
    }

    return materializeProjection(
        alloc,
        selected[0..plan.output_count],
        additions,
        deletions,
        plan.truncated,
        options,
    );
}

fn materializeProjection(
    alloc: Allocator,
    selected: []const SelectedLine,
    additions: usize,
    deletions: usize,
    initially_truncated: bool,
    options: PreviewOptions,
) BoundedPreviewError!BoundedDiffProjection {
    if (selected.len > options.max_lines) return error.PreviewBudgetExceeded;

    const lines = try alloc.alloc(ProjectedLine, selected.len);
    errdefer alloc.free(lines);

    var initialized: usize = 0;
    errdefer for (lines[0..initialized]) |line| alloc.free(line.text);

    var encoded_bytes: usize = 0;
    var truncated = initially_truncated;
    var retained_additions: usize = 0;
    var retained_deletions: usize = 0;
    for (selected) |source| {
        retained_additions += @intFromBool(source.op == .addition);
        retained_deletions += @intFromBool(source.op == .deletion);
    }
    const omitted_additions = additions - retained_additions;
    const omitted_deletions = deletions - retained_deletions;
    for (selected, 0..) |source, index| {
        const remaining = options.max_encoded_preview_bytes - encoded_bytes;
        const row_limit = @min(options.max_encoded_line_bytes, remaining);
        var elision_buffer: [64]u8 = undefined;
        const source_text = if (source.op == .elision)
            formatElisionText(
                &elision_buffer,
                omitted_additions,
                omitted_deletions,
            )
        else
            source.text;
        const encoded = try text_utils.encodeTerminalSafe(
            alloc,
            source_text,
            row_limit,
        );
        lines[index] = .{
            .op = source.op,
            .old_line = source.old_line,
            .new_line = source.new_line,
            .text = encoded.bytes,
        };
        initialized += 1;
        encoded_bytes += encoded.bytes.len;
        truncated = truncated or encoded.truncated;
    }

    return .{
        .lines = lines,
        .additions = additions,
        .deletions = deletions,
        .truncated = truncated,
    };
}

fn selectionPlan(total_changed: usize, max_lines: usize) SelectionPlan {
    if (total_changed == 0) {
        return .{
            .output_count = 1,
            .head_count = 0,
            .tail_count = 0,
            .truncated = false,
        };
    }
    if (total_changed <= max_lines) {
        return .{
            .output_count = total_changed,
            .head_count = total_changed,
            .tail_count = 0,
            .truncated = false,
        };
    }

    const retained_lines = max_lines - 1;
    const head_count = (retained_lines + 1) / 2;
    return .{
        .output_count = max_lines,
        .head_count = head_count,
        .tail_count = retained_lines - head_count,
        .truncated = true,
    };
}

fn initializeSelection(
    selected: *[max_preview_lines]SelectedLine,
    plan: SelectionPlan,
) void {
    if (plan.output_count == 1 and plan.head_count == 0 and !plan.truncated) {
        selected[0] = .{ .op = .notice, .text = "No changes" };
    } else if (plan.truncated) {
        selected[plan.head_count] = .{ .op = .elision, .text = "" };
    }
}

fn formatElisionText(
    buffer: *[64]u8,
    omitted_additions: usize,
    omitted_deletions: usize,
) []const u8 {
    std.debug.assert(omitted_additions > 0 or omitted_deletions > 0);
    var end: usize = 0;

    if (omitted_additions > 0 and omitted_deletions > 0) {
        const prefix = "⋯ +";
        @memcpy(buffer[end..][0..prefix.len], prefix);
        end += prefix.len;
        end += std.fmt.printInt(buffer[end..], omitted_additions, 10, .lower, .{});

        const separator = " -";
        @memcpy(buffer[end..][0..separator.len], separator);
        end += separator.len;
        end += std.fmt.printInt(buffer[end..], omitted_deletions, 10, .lower, .{});
    } else {
        const prefix = if (omitted_additions > 0) "⋯ +" else "⋯ -";
        const omitted = if (omitted_additions > 0) omitted_additions else omitted_deletions;
        @memcpy(buffer[end..][0..prefix.len], prefix);
        end += prefix.len;
        end += std.fmt.printInt(buffer[end..], omitted, 10, .lower, .{});
    }

    const suffix = " omitted";
    @memcpy(buffer[end..][0..suffix.len], suffix);
    end += suffix.len;
    return buffer[0..end];
}

fn selectionSlot(
    ordinal: usize,
    total_changed: usize,
    plan: SelectionPlan,
) ?usize {
    if (!plan.truncated) return ordinal;
    if (ordinal < plan.head_count) return ordinal;

    const tail_start = total_changed - plan.tail_count;
    if (ordinal >= tail_start) {
        return plan.head_count + 1 + ordinal - tail_start;
    }
    return null;
}

fn retainSelected(
    selected: *[max_preview_lines]SelectedLine,
    ordinal: usize,
    total_changed: usize,
    plan: SelectionPlan,
    line: SelectedLine,
) void {
    if (selectionSlot(ordinal, total_changed, plan)) |slot| {
        selected[slot] = line;
    }
}

fn countTextLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn indexLineStarts(alloc: Allocator, text: []const u8) Allocator.Error![]usize {
    const starts = try alloc.alloc(usize, countTextLines(text));
    var cursor: usize = 0;
    for (starts) |*start| {
        start.* = cursor;
        cursor = if (std.mem.findScalarPos(u8, text, cursor, '\n')) |newline|
            newline + 1
        else
            text.len;
    }
    return starts;
}

fn indexedTextLine(text: []const u8, starts: []const usize, index: usize) TextLine {
    const start = starts[index];
    const end = if (index + 1 < starts.len)
        starts[index + 1] - 1
    else if (text.len > 0 and text[text.len - 1] == '\n')
        text.len - 1
    else
        text.len;
    return .{
        .number = index + 1,
        .text = text[start..end],
    };
}

fn trailingNewlineMarker(
    old_text: []const u8,
    new_text: []const u8,
    old_side: bool,
) ?[]const u8 {
    if (old_text.len == 0 or new_text.len == 0) return null;
    const old_has_trailing_newline = std.mem.endsWith(u8, old_text, "\n");
    const new_has_trailing_newline = std.mem.endsWith(u8, new_text, "\n");
    if (old_has_trailing_newline == new_has_trailing_newline) return null;
    if (old_side and old_has_trailing_newline) return trailing_newline_removed_marker;
    if (!old_side and new_has_trailing_newline) return trailing_newline_added_marker;
    return null;
}

fn checkedAdd(a: usize, b: usize) BoundedPreviewError!usize {
    return std.math.add(usize, a, b) catch error.ArithmeticOverflow;
}

fn checkedMul(a: usize, b: usize) BoundedPreviewError!usize {
    return std.math.mul(usize, a, b) catch error.ArithmeticOverflow;
}

fn projectedLineNumber(number: usize) ?u32 {
    if (number > std.math.maxInt(u32)) return null;
    return @intCast(number);
}

fn appendLines(alloc: Allocator, lines: *std.ArrayList([]const u8), text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '\n') {
            try lines.append(alloc, text[start..index]);
            start = index + 1;
        }
    }
    if (start < text.len) {
        try lines.append(alloc, text[start..]);
    }
}

fn appendTrailingNewlineMarker(
    alloc: Allocator,
    old_lines: *std.ArrayList([]const u8),
    new_lines: *std.ArrayList([]const u8),
    old_text: []const u8,
    new_text: []const u8,
) !void {
    if (old_text.len == 0 or new_text.len == 0) return;
    const old_has_trailing_newline = std.mem.endsWith(u8, old_text, "\n");
    const new_has_trailing_newline = std.mem.endsWith(u8, new_text, "\n");
    if (old_has_trailing_newline == new_has_trailing_newline) return;

    if (old_has_trailing_newline) {
        try old_lines.append(alloc, trailing_newline_removed_marker);
    } else {
        try new_lines.append(alloc, trailing_newline_added_marker);
    }
}

test "compute: identical inputs produce only equal ops" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nb\nc\n", "a\nb\nc\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 3), diff.len);
    for (diff) |line| {
        try std.testing.expectEqual(LineOp.equal, line.op);
    }
    try std.testing.expectEqual(Stats{}, countStats(diff));
}

test "compute: pure insert in the middle" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nb\n", "a\nX\nb\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 3), diff.len);
    try std.testing.expectEqual(LineOp.equal, diff[0].op);
    try std.testing.expectEqual(LineOp.add, diff[1].op);
    try std.testing.expectEqualStrings("X", diff[1].text);
    try std.testing.expectEqual(@as(?u32, null), diff[1].old_num);
    try std.testing.expectEqual(@as(?u32, 2), diff[1].new_num);
    try std.testing.expectEqual(LineOp.equal, diff[2].op);
    try std.testing.expectEqual(Stats{ .additions = 1 }, countStats(diff));
}

test "compute: pure delete" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nb\nc\n", "a\nc\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 3), diff.len);
    try std.testing.expectEqual(LineOp.remove, diff[1].op);
    try std.testing.expectEqualStrings("b", diff[1].text);
    try std.testing.expectEqual(@as(?u32, 2), diff[1].old_num);
    try std.testing.expectEqual(@as(?u32, null), diff[1].new_num);
    try std.testing.expectEqual(Stats{ .deletions = 1 }, countStats(diff));
}

test "compute: replace single line" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nold\nc\n", "a\nnew\nc\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(LineOp.remove, diff[1].op);
    try std.testing.expectEqualStrings("old", diff[1].text);
    try std.testing.expectEqual(LineOp.add, diff[2].op);
    try std.testing.expectEqualStrings("new", diff[2].text);
    try std.testing.expectEqual(Stats{ .additions = 1, .deletions = 1 }, countStats(diff));
}

test "compute: trailing-newline-only changes are visible" {
    const alloc = std.testing.allocator;

    const removed = try compute(alloc, "a\n", "a");
    defer alloc.free(removed);
    try std.testing.expectEqual(Stats{ .deletions = 1 }, countStats(removed));
    try std.testing.expectEqual(LineOp.remove, removed[1].op);
    try std.testing.expectEqualStrings(trailing_newline_removed_marker, removed[1].text);

    const added = try compute(alloc, "a", "a\n");
    defer alloc.free(added);
    try std.testing.expectEqual(Stats{ .additions = 1 }, countStats(added));
    try std.testing.expectEqual(LineOp.add, added[1].op);
    try std.testing.expectEqualStrings(trailing_newline_added_marker, added[1].text);
}

test "compute: empty old (new-file creation)" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "", "first\nsecond\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 2), diff.len);
    try std.testing.expectEqual(LineOp.add, diff[0].op);
    try std.testing.expectEqual(@as(?u32, 1), diff[0].new_num);
    try std.testing.expectEqual(LineOp.add, diff[1].op);
    try std.testing.expectEqual(@as(?u32, 2), diff[1].new_num);
    try std.testing.expectEqual(Stats{ .additions = 2 }, countStats(diff));
}

test "compute: line numbers increment monotonically" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nb\nc\n", "a\nX\nb\nc\n");
    defer alloc.free(diff);

    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(@as(?u32, 1), diff[0].old_num);
    try std.testing.expectEqual(@as(?u32, 1), diff[0].new_num);
    try std.testing.expectEqual(@as(?u32, null), diff[1].old_num);
    try std.testing.expectEqual(@as(?u32, 2), diff[1].new_num);
    try std.testing.expectEqual(@as(?u32, 2), diff[2].old_num);
    try std.testing.expectEqual(@as(?u32, 3), diff[2].new_num);
    try std.testing.expectEqual(@as(?u32, 3), diff[3].old_num);
    try std.testing.expectEqual(@as(?u32, 4), diff[3].new_num);
}

test "formatUnified: rows contain signs for changed lines" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nold\nc\n", "a\nnew\nc\n");
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, null, .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "+ new") != null);
    try std.testing.expect(std.mem.find(u8, out, "- old") != null);
}

test "formatUnified: marker accent colors only the number and sign" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nold\nc\n", "a\nnew\nc\n");
    defer alloc.free(diff);
    const styles: FormatStyles = .{
        .added_marker_fg = "[G]",
        .removed_marker_fg = "[R]",
    };
    const out = try formatUnified(alloc, diff, styles, null, .edited);
    defer alloc.free(out);

    // The accent wraps the number and sign, then the line color is reasserted
    // before the text, so the text stays neutral.
    try std.testing.expect(std.mem.find(u8, out, "[G]2 +") != null);
    try std.testing.expect(std.mem.find(u8, out, "[R]2 -") != null);
    try std.testing.expect(std.mem.find(u8, out, "+\x1b[38;5;252m new") != null);
    try std.testing.expect(std.mem.find(u8, out, "-\x1b[38;5;252m old") != null);
    // The text is never inside the accent run.
    try std.testing.expect(std.mem.find(u8, out, "[G]2 + new") == null);
}

test "formatUnified: trailing-newline-only edits render markers" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\n", "a");
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, "file.txt", .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "- (trailing newline removed)") != null);
}

test "formatUnified: gutter width fits largest line number" {
    const alloc = std.testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var index: u32 = 1;
    while (index <= 12) : (index += 1) {
        const line = try alloc.print("line{d}\n", .{index});
        defer alloc.free(line);
        try old_buf.appendSlice(alloc, line);
        try new_buf.appendSlice(alloc, line);
    }
    try new_buf.appendSlice(alloc, "extra\n");

    const diff = try compute(alloc, old_buf.items, new_buf.items);
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, null, .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "13 + extra") != null);
}

test "formatUnified: only emits changed hunks with limited context" {
    const alloc = std.testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var index: u32 = 1;
    while (index <= 20) : (index += 1) {
        const old_line = if (index == 10) "old-line-10\n" else "same\n";
        const new_line = if (index == 10) "new-line-10\n" else "same\n";
        try old_buf.appendSlice(alloc, old_line);
        try new_buf.appendSlice(alloc, new_line);
    }

    const diff = try compute(alloc, old_buf.items, new_buf.items);
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, null, .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "+ new-line-10") != null);
    try std.testing.expect(std.mem.find(u8, out, "- old-line-10") != null);
    try std.testing.expect(std.mem.find(u8, out, " 1   same") == null);
    try std.testing.expect(std.mem.find(u8, out, "20   same") == null);
}

test "formatUnified: single line-number column" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nold\nc\n", "a\nnew\nc\n");
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, null, .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "1 1 ") == null);
}

test "freeDiffEntryPayload releases all owned buffers" {
    const alloc = std.testing.allocator;
    freeDiffEntryPayload(alloc, .{
        .preview = try alloc.dupe(u8, "preview"),
        .full = .{
            .content = try alloc.dupe(u8, "full"),
            .lifecycle_id = .{
                .turn_id = 1,
                .call_id = try alloc.dupe(u8, "call"),
            },
        },
    });
}

test "formatUnified: emits diff lines without header" {
    const alloc = std.testing.allocator;
    const diff = try compute(alloc, "a\nold\nc\n", "a\nnew\nc\n");
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, "src/app/page.tsx", .added);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "+ new") != null);
    try std.testing.expect(std.mem.find(u8, out, "- old") != null);
}

test "formatUnified: separated hunks emit vertical elision row" {
    const alloc = std.testing.allocator;
    var old_buf: std.ArrayList(u8) = .empty;
    defer old_buf.deinit(alloc);
    var new_buf: std.ArrayList(u8) = .empty;
    defer new_buf.deinit(alloc);

    var index: u32 = 1;
    while (index <= 16) : (index += 1) {
        const old_line = if (index == 3)
            "old-line-3\n"
        else if (index == 14)
            "old-line-14\n"
        else
            "same\n";
        const new_line = if (index == 3)
            "new-line-3\n"
        else if (index == 14)
            "new-line-14\n"
        else
            "same\n";
        try old_buf.appendSlice(alloc, old_line);
        try new_buf.appendSlice(alloc, new_line);
    }

    const diff = try compute(alloc, old_buf.items, new_buf.items);
    defer alloc.free(diff);
    const out = try formatUnified(alloc, diff, .{}, null, .edited);
    defer alloc.free(out);

    try std.testing.expect(std.mem.find(u8, out, "\xe2\x8b\xaf") != null);
    try std.testing.expect(std.mem.find(u8, out, "+ new-line-3") != null);
}

test "persisted edit emits one canonical preview without a full snapshot" {
    const alloc = std.testing.allocator;
    const lines = [_]types.CommittedFilePresentationLine{
        .{ .kind = .addition, .new_line = 1, .text = "changed" },
    };
    const payload = try formatPersistedFileChangePayload(
        alloc,
        .{
            .path = "existing.md",
            .kind = .edited,
            .lines = &lines,
            .additions = 1,
            .deletions = 0,
            .truncated = false,
        },
        .{},
    );
    defer freeDiffEntryPayload(alloc, payload);

    try std.testing.expect(std.mem.find(u8, payload.preview, "changed") != null);
    try std.testing.expectEqual(@as(u32, 1), payload.additions);
    try std.testing.expectEqual(@as(u32, 0), payload.deletions);
    try std.testing.expect(payload.full == null);
}

test "wrapWithMarkers surrounds content with start/end OSC markers" {
    const alloc = std.testing.allocator;
    const out = try wrapWithMarkers(alloc, 7, "hello\n");
    defer alloc.free(out);

    try std.testing.expectEqualStrings("\x1b]9050;7\x07hello\n\x1b]9051;7\x07", out);
}

test "DiffEntry.deinit releases owned full detail" {
    const alloc = std.testing.allocator;
    var entry = DiffEntry{
        .id = 1,
        .full = .{
            .content = try alloc.dupe(u8, "full"),
            .lifecycle_id = .{
                .turn_id = 1,
                .call_id = try alloc.dupe(u8, "call"),
            },
        },
    };

    entry.deinit(alloc);
}

test "buildBoundedPreview preserves admitted compute ordering and line numbers" {
    const cases = [_]struct {
        old_text: []const u8,
        new_text: []const u8,
    }{
        .{
            .old_text = "a\nb\na\n",
            .new_text = "a\na\nb\n",
        },
        .{
            .old_text = "line\n",
            .new_text = "line",
        },
    };

    for (cases) |case| {
        const full_diff = try compute(std.testing.allocator, case.old_text, case.new_text);
        defer std.testing.allocator.free(full_diff);
        var preview = try buildBoundedPreview(
            std.testing.allocator,
            case.old_text,
            case.new_text,
            .{},
        );
        defer preview.deinit(std.testing.allocator);

        const stats = countStats(full_diff);
        try std.testing.expectEqual(@as(usize, stats.additions), preview.additions);
        try std.testing.expectEqual(@as(usize, stats.deletions), preview.deletions);

        var projected_index: usize = 0;
        for (full_diff) |line| {
            if (line.op == .equal) continue;
            while (preview.lines[projected_index].op == .context) {
                projected_index += 1;
            }
            const projected = preview.lines[projected_index];
            try std.testing.expectEqual(
                switch (line.op) {
                    .equal => unreachable,
                    .add => PreviewOp.addition,
                    .remove => PreviewOp.deletion,
                },
                projected.op,
            );
            try std.testing.expectEqual(line.old_num, projected.old_line);
            try std.testing.expectEqual(line.new_num, projected.new_line);
            try std.testing.expectEqualStrings(line.text, projected.text);
            projected_index += 1;
        }
        while (projected_index < preview.lines.len) : (projected_index += 1) {
            try std.testing.expectEqual(
                PreviewOp.context,
                preview.lines[projected_index].op,
            );
        }
    }
}

test "buildBoundedPreview includes symmetric context for one exact hunk" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "alpha\nbefore\nomega\n",
        "alpha\nafter\nomega\n",
        .{},
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), preview.lines.len);
    try std.testing.expectEqual(PreviewOp.context, preview.lines[0].op);
    try std.testing.expectEqual(@as(?u32, 1), preview.lines[0].old_line);
    try std.testing.expectEqual(@as(?u32, 1), preview.lines[0].new_line);
    try std.testing.expectEqualStrings("alpha", preview.lines[0].text);
    try std.testing.expectEqual(PreviewOp.deletion, preview.lines[1].op);
    try std.testing.expectEqualStrings("before", preview.lines[1].text);
    try std.testing.expectEqual(PreviewOp.addition, preview.lines[2].op);
    try std.testing.expectEqualStrings("after", preview.lines[2].text);
    try std.testing.expectEqual(PreviewOp.context, preview.lines[3].op);
    try std.testing.expectEqual(@as(?u32, 3), preview.lines[3].old_line);
    try std.testing.expectEqual(@as(?u32, 3), preview.lines[3].new_line);
    try std.testing.expectEqualStrings("omega", preview.lines[3].text);
    try std.testing.expect(!preview.truncated);
}

test "buildBoundedPreview includes one exact context only at a file boundary" {
    const cases = [_]struct {
        old_text: []const u8,
        new_text: []const u8,
        context_index: usize,
        context_text: []const u8,
    }{
        .{
            .old_text = "before\nomega\n",
            .new_text = "after\nomega\n",
            .context_index = 2,
            .context_text = "omega",
        },
        .{
            .old_text = "alpha\nbefore\n",
            .new_text = "alpha\nafter\n",
            .context_index = 0,
            .context_text = "alpha",
        },
    };
    for (cases) |case| {
        var preview = try buildBoundedPreview(
            std.testing.allocator,
            case.old_text,
            case.new_text,
            .{},
        );
        defer preview.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 3), preview.lines.len);
        try std.testing.expectEqual(
            PreviewOp.context,
            preview.lines[case.context_index].op,
        );
        try std.testing.expectEqualStrings(
            case.context_text,
            preview.lines[case.context_index].text,
        );
    }
}

test "buildBoundedPreview leaves a lone interior context slot unused" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "alpha\nbefore\nomega\n",
        "alpha\nafter\nomega\n",
        .{ .max_lines = 3 },
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), preview.lines.len);
    for (preview.lines) |line| {
        try std.testing.expect(line.op != .context);
    }
}

test "buildBoundedPreview does not synthesize context for multiple hunks" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "alpha\nbefore\nmiddle\nold\nomega\n",
        "alpha\nafter\nmiddle\nnew\nomega\n",
        .{},
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), preview.lines.len);
    for (preview.lines) |line| {
        try std.testing.expect(line.op != .context);
    }
}

test "buildBoundedPreview bounds selected rows with explicit elision" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "a\nb\nc\nd\ne\n",
        "v\nw\nx\ny\nz\n",
        .{},
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), preview.additions);
    try std.testing.expectEqual(@as(usize, 5), preview.deletions);
    try std.testing.expectEqual(@as(usize, 6), preview.lines.len);
    try std.testing.expect(preview.truncated);

    var elisions: usize = 0;
    for (preview.lines) |line| {
        if (line.op == .elision) elisions += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), elisions);
    for (preview.lines) |line| {
        if (line.op != .elision) continue;
        var retained_additions: usize = 0;
        var retained_deletions: usize = 0;
        for (preview.lines) |retained| {
            retained_additions += @intFromBool(retained.op == .addition);
            retained_deletions += @intFromBool(retained.op == .deletion);
        }
        const expected = try std.testing.allocator.print(
            "⋯ +{d} -{d} omitted",
            .{
                preview.additions - retained_additions,
                preview.deletions - retained_deletions,
            },
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, line.text);
    }
}

test "file review exposes every changed line beyond the bounded preview cap" {
    const alloc = std.testing.allocator;
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(alloc);

    for (1..31) |line_number| {
        var line: [32]u8 = undefined;
        try after.appendSlice(
            alloc,
            try std.mem.print(&line, "line {d}\n", .{line_number}),
        );
    }

    var review = try FileReview.init(alloc, "", after.items);
    defer review.deinit(alloc);

    var viewport = try review.viewport(alloc, 24, 6);
    defer viewport.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 30), review.rowCount());
    try std.testing.expectEqual(@as(usize, 6), viewport.lines.len);
    try std.testing.expectEqual(@as(?u32, 25), viewport.lines[0].new_line);
    try std.testing.expectEqualStrings("line 25", viewport.lines[0].text);
    try std.testing.expectEqual(@as(?u32, 30), viewport.lines[5].new_line);
    try std.testing.expectEqualStrings("line 30", viewport.lines[5].text);
}

test "fallback file review seeks to replacement boundaries" {
    const alloc = std.testing.allocator;
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(alloc);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(alloc);

    for (1..2049) |line_number| {
        var line: [32]u8 = undefined;
        try before.appendSlice(
            alloc,
            try std.mem.print(&line, "old-{d:0>4}\n", .{line_number}),
        );
        try after.appendSlice(
            alloc,
            try std.mem.print(&line, "new-{d:0>4}\n", .{line_number}),
        );
    }

    var review = try FileReview.init(alloc, before.items, after.items);
    defer review.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4096), review.rowCount());

    var middle = try review.viewport(alloc, 2047, 2);
    defer middle.deinit(alloc);
    try std.testing.expectEqual(PreviewOp.deletion, middle.lines[0].op);
    try std.testing.expectEqualStrings("old-2048", middle.lines[0].text);
    try std.testing.expectEqual(PreviewOp.addition, middle.lines[1].op);
    try std.testing.expectEqualStrings("new-0001", middle.lines[1].text);

    var tail = try review.viewport(alloc, review.rowCount() - 2, 2);
    defer tail.deinit(alloc);
    try std.testing.expectEqualStrings("new-2047", tail.lines[0].text);
    try std.testing.expectEqualStrings("new-2048", tail.lines[1].text);
}

test "file review projects five context lines and exact computed elisions" {
    const alloc = std.testing.allocator;
    const before =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "old-one\n" ++
        "middle-01\nmiddle-02\nmiddle-03\nmiddle-04\nmiddle-05\nmiddle-06\n" ++
        "middle-07\nmiddle-08\nmiddle-09\nmiddle-10\nmiddle-11\nmiddle-12\n" ++
        "old-two\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";
    const after =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "new-one\n" ++
        "middle-01\nmiddle-02\nmiddle-03\nmiddle-04\nmiddle-05\nmiddle-06\n" ++
        "middle-07\nmiddle-08\nmiddle-09\nmiddle-10\nmiddle-11\nmiddle-12\n" ++
        "new-two\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";

    var review = try FileReview.init(alloc, before, after);
    defer review.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 27), review.rowCount());

    var rows = try review.viewport(alloc, 0, review.rowCount());
    defer rows.deinit(alloc);
    try std.testing.expect(@hasField(ReviewLine, "elision_count"));
    try std.testing.expectEqual(PreviewOp.elision, rows.lines[0].op);
    if (comptime @hasField(ReviewLine, "elision_count")) {
        try std.testing.expectEqual(@as(usize, 3), @field(rows.lines[0], "elision_count"));
    }
    try std.testing.expectEqualStrings("", rows.lines[0].text);

    for (0..5) |index| {
        const line = rows.lines[index + 1];
        try std.testing.expectEqual(PreviewOp.context, line.op);
        try std.testing.expectEqual(@as(?u32, @intCast(index + 4)), line.old_line);
        try std.testing.expectEqual(@as(?u32, @intCast(index + 4)), line.new_line);
    }
    try std.testing.expectEqualStrings("lead-04", rows.lines[1].text);
    try std.testing.expectEqualStrings("lead-08", rows.lines[5].text);
    try std.testing.expectEqual(PreviewOp.deletion, rows.lines[6].op);
    try std.testing.expectEqualStrings("old-one", rows.lines[6].text);
    try std.testing.expectEqual(PreviewOp.addition, rows.lines[7].op);
    try std.testing.expectEqualStrings("new-one", rows.lines[7].text);

    try std.testing.expectEqualStrings("middle-01", rows.lines[8].text);
    try std.testing.expectEqualStrings("middle-05", rows.lines[12].text);
    try std.testing.expectEqual(PreviewOp.elision, rows.lines[13].op);
    if (comptime @hasField(ReviewLine, "elision_count")) {
        try std.testing.expectEqual(@as(usize, 2), @field(rows.lines[13], "elision_count"));
    }
    try std.testing.expectEqualStrings("middle-08", rows.lines[14].text);
    try std.testing.expectEqualStrings("middle-12", rows.lines[18].text);
    try std.testing.expectEqualStrings("tail-01", rows.lines[21].text);
    try std.testing.expectEqualStrings("tail-05", rows.lines[25].text);
    try std.testing.expectEqual(PreviewOp.elision, rows.lines[26].op);
    if (comptime @hasField(ReviewLine, "elision_count")) {
        try std.testing.expectEqual(@as(usize, 3), @field(rows.lines[26], "elision_count"));
    }
}

test "file review projects only proven fallback context with exact elisions" {
    const alloc = std.testing.allocator;
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(alloc);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(alloc);

    for (1..1001) |line_number| {
        var line: [16]u8 = undefined;
        const formatted = try std.mem.print(&line, "line-{d:0>4}\n", .{line_number});
        try before.appendSlice(alloc, formatted);
        try after.appendSlice(alloc, formatted);
        if (line_number == 500) {
            try after.appendSlice(alloc, "inserted-context-a\ninserted-context-b\n");
        }
    }

    var review = try FileReview.init(alloc, before.items, after.items);
    defer review.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 14), review.rowCount());

    var rows = try review.viewport(alloc, 0, review.rowCount());
    defer rows.deinit(alloc);
    try std.testing.expect(@hasField(ReviewLine, "elision_count"));
    try std.testing.expectEqual(PreviewOp.elision, rows.lines[0].op);
    if (comptime @hasField(ReviewLine, "elision_count")) {
        try std.testing.expectEqual(@as(usize, 495), @field(rows.lines[0], "elision_count"));
    }
    try std.testing.expectEqualStrings("line-0496", rows.lines[1].text);
    try std.testing.expectEqualStrings("line-0500", rows.lines[5].text);
    try std.testing.expectEqual(PreviewOp.addition, rows.lines[6].op);
    try std.testing.expectEqual(@as(?u32, 501), rows.lines[6].new_line);
    try std.testing.expectEqualStrings("inserted-context-a", rows.lines[6].text);
    try std.testing.expectEqual(PreviewOp.addition, rows.lines[7].op);
    try std.testing.expectEqual(@as(?u32, 502), rows.lines[7].new_line);
    try std.testing.expectEqualStrings("inserted-context-b", rows.lines[7].text);
    try std.testing.expectEqualStrings("line-0501", rows.lines[8].text);
    try std.testing.expectEqual(@as(?u32, 501), rows.lines[8].old_line);
    try std.testing.expectEqual(@as(?u32, 503), rows.lines[8].new_line);
    try std.testing.expectEqualStrings("line-0505", rows.lines[12].text);
    try std.testing.expectEqual(PreviewOp.elision, rows.lines[13].op);
    if (comptime @hasField(ReviewLine, "elision_count")) {
        try std.testing.expectEqual(@as(usize, 495), @field(rows.lines[13], "elision_count"));
    }
}

test "file review preserves replacements and trailing-newline markers" {
    const alloc = std.testing.allocator;

    var replacement = try FileReview.init(alloc, "old\n", "new\n");
    defer replacement.deinit(alloc);
    var replacement_rows = try replacement.viewport(alloc, 0, replacement.rowCount());
    defer replacement_rows.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), replacement_rows.lines.len);
    try std.testing.expectEqual(PreviewOp.deletion, replacement_rows.lines[0].op);
    try std.testing.expectEqualStrings("old", replacement_rows.lines[0].text);
    try std.testing.expectEqual(PreviewOp.addition, replacement_rows.lines[1].op);
    try std.testing.expectEqualStrings("new", replacement_rows.lines[1].text);

    var newline_change = try FileReview.init(alloc, "a\n", "a");
    defer newline_change.deinit(alloc);
    var newline_rows = try newline_change.viewport(alloc, 0, newline_change.rowCount());
    defer newline_rows.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), newline_rows.lines.len);
    try std.testing.expectEqual(PreviewOp.context, newline_rows.lines[0].op);
    try std.testing.expectEqualStrings("a", newline_rows.lines[0].text);
    try std.testing.expectEqual(PreviewOp.deletion, newline_rows.lines[1].op);
    try std.testing.expectEqualStrings(
        trailing_newline_removed_marker,
        newline_rows.lines[1].text,
    );
}

test "buildBoundedPreview elision reports one-sided omitted polarity" {
    const cases = [_]struct {
        old_text: []const u8,
        new_text: []const u8,
        expected: []const u8,
    }{
        .{
            .old_text = "",
            .new_text = "1\n2\n3\n4\n5\n6\n7\n",
            .expected = "⋯ +2 omitted",
        },
        .{
            .old_text = "1\n2\n3\n4\n5\n6\n7\n",
            .new_text = "",
            .expected = "⋯ -2 omitted",
        },
    };
    for (cases) |case| {
        var preview = try buildBoundedPreview(
            std.testing.allocator,
            case.old_text,
            case.new_text,
            .{},
        );
        defer preview.deinit(std.testing.allocator);

        var found = false;
        for (preview.lines) |line| {
            if (line.op != .elision) continue;
            found = true;
            try std.testing.expectEqualStrings(case.expected, line.text);
        }
        try std.testing.expect(found);
    }
}

test "buildBoundedPreview rejects LCS matrix amplification from one-byte lines" {
    const alloc = std.testing.allocator;
    const line_count = 1001;
    var old_text = try std.ArrayList(u8).initCapacity(alloc, line_count * 2);
    defer old_text.deinit(alloc);
    var new_text = try std.ArrayList(u8).initCapacity(alloc, line_count * 2);
    defer new_text.deinit(alloc);

    for (0..line_count) |_| {
        try old_text.appendSlice(alloc, "a\n");
        try new_text.appendSlice(alloc, "b\n");
    }

    var preview = try buildBoundedPreview(alloc, old_text.items, new_text.items, .{});
    defer preview.deinit(alloc);

    try std.testing.expectEqual(@as(usize, line_count), preview.additions);
    try std.testing.expectEqual(@as(usize, line_count), preview.deletions);
}

test "buildBoundedPreview streams fallback without materializing changed middle" {
    const alloc = std.testing.allocator;
    const line_count = 20_000;
    var old_text = try std.ArrayList(u8).initCapacity(alloc, line_count * 2);
    defer old_text.deinit(alloc);
    var new_text = try std.ArrayList(u8).initCapacity(alloc, line_count * 2);
    defer new_text.deinit(alloc);

    for (0..line_count) |_| {
        try old_text.appendSlice(alloc, "a\n");
        try new_text.appendSlice(alloc, "b\n");
    }

    var preview = try buildBoundedPreview(
        alloc,
        old_text.items,
        new_text.items,
        .{},
    );
    defer preview.deinit(alloc);

    try std.testing.expectEqual(@as(usize, line_count), preview.additions);
    try std.testing.expectEqual(@as(usize, line_count), preview.deletions);
    try std.testing.expect(preview.lines.len <= 6);
    try std.testing.expect(preview.truncated);
}

test "buildBoundedPreview fallback retains exact common prefix and suffix counts" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "same\nold-a\nold-b\nlast\n",
        "same\nnew-a\nlast\n",
        .{ .max_matrix_cells = 1 },
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), preview.additions);
    try std.testing.expectEqual(@as(usize, 2), preview.deletions);
    try std.testing.expectEqual(@as(usize, 3), preview.lines.len);
    try std.testing.expectEqualStrings("old-a", preview.lines[0].text);
    try std.testing.expectEqualStrings("old-b", preview.lines[1].text);
    try std.testing.expectEqualStrings("new-a", preview.lines[2].text);
    for (preview.lines) |line| {
        try std.testing.expect(line.op != .context);
    }
}

test "buildBoundedPreview fallback keeps informative elision without context" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "same\n1\n2\n3\n4\n5\n6\nlast\n",
        "same\na\nb\nc\nd\ne\nf\nlast\n",
        .{ .max_matrix_cells = 1 },
    );
    defer preview.deinit(std.testing.allocator);

    var elision_count: usize = 0;
    for (preview.lines) |line| {
        try std.testing.expect(line.op != .context);
        if (line.op == .elision) {
            elision_count += 1;
            try std.testing.expect(std.mem.find(u8, line.text, "omitted") != null);
            try std.testing.expect(std.mem.find(u8, line.text, "+") != null);
            try std.testing.expect(std.mem.find(u8, line.text, "-") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), elision_count);
}

test "buildBoundedPreview fallback never treats an aligned middle as context" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "start\nold-a\nmiddle\nold-b\nend\n",
        "start\nnew-a\nmiddle\nnew-b\nend\n",
        .{ .max_matrix_cells = 1 },
    );
    defer preview.deinit(std.testing.allocator);

    for (preview.lines) |line| {
        try std.testing.expect(line.op != .context);
    }
    try std.testing.expectEqual(@as(usize, 3), preview.deletions);
    try std.testing.expectEqual(@as(usize, 3), preview.additions);
}

test "buildBoundedPreview preserves trailing-newline markers with boundary context" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "alpha\nbeta\n",
        "alpha\nbeta",
        .{},
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), preview.lines.len);
    try std.testing.expectEqual(PreviewOp.context, preview.lines[0].op);
    try std.testing.expectEqualStrings("beta", preview.lines[0].text);
    try std.testing.expectEqual(PreviewOp.deletion, preview.lines[1].op);
    try std.testing.expectEqualStrings(
        trailing_newline_removed_marker,
        preview.lines[1].text,
    );
}

test "buildBoundedPreview bounds rows and escapes terminal controls" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "",
        "\x1b[31mred\nsecond\nthird\nfourth\nfifth\nsixth\nseventh\n",
        .{},
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(preview.truncated);
    var encoded_bytes: usize = 0;
    for (preview.lines) |line| {
        try std.testing.expect(line.text.len <= 4096);
        try std.testing.expect(std.mem.findScalar(u8, line.text, 0x1b) == null);
        try std.testing.expect(std.mem.findScalar(u8, line.text, '\n') == null);
        encoded_bytes += line.text.len;
    }
    try std.testing.expect(encoded_bytes <= max_encoded_preview_bytes);
    try std.testing.expect(std.mem.find(u8, preview.lines[0].text, "\\x1b") != null);
}

test "buildBoundedPreview enforces per-line and aggregate encoded budgets" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "",
        "\x1b\x1b\x1b\x1b\n\x1b\x1b\x1b\x1b\n",
        .{
            .max_encoded_line_bytes = 8,
            .max_encoded_preview_bytes = 12,
        },
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(preview.truncated);
    var encoded_bytes: usize = 0;
    for (preview.lines) |line| {
        try std.testing.expect(line.text.len <= 8);
        encoded_bytes += line.text.len;
    }
    try std.testing.expect(encoded_bytes <= 12);
}

test "buildBoundedPreview encoding truncation does not invent data elision" {
    var preview = try buildBoundedPreview(
        std.testing.allocator,
        "",
        "abcdefghijklmnopqrstuvwxyz\n",
        .{
            .max_encoded_line_bytes = 8,
            .max_encoded_preview_bytes = 8,
        },
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(preview.truncated);
    try std.testing.expectEqual(@as(usize, 1), preview.lines.len);
    try std.testing.expectEqual(PreviewOp.addition, preview.lines[0].op);
}

test "file change preview validates bounds and line number semantics" {
    const valid: FileChangePreview = .{
        .path = "note.txt",
        .lines = &.{
            .{ .op = .context, .old_line = 1, .new_line = 1, .text = "alpha" },
            .{ .op = .deletion, .old_line = 2, .text = "beta" },
            .{ .op = .addition, .new_line = 2, .text = "BETA" },
        },
        .additions = 1,
        .deletions = 1,
        .truncated = false,
    };
    try valid.validate();

    const invalid_lines = [_]PreviewLine{
        .{ .op = .context, .old_line = 1, .text = "missing new" },
        .{ .op = .addition, .old_line = 1, .new_line = 1, .text = "old forbidden" },
        .{ .op = .deletion, .old_line = 1, .new_line = 1, .text = "new forbidden" },
        .{ .op = .elision, .old_line = 1, .text = "..." },
        .{ .op = .notice, .new_line = 1, .text = "notice" },
        .{ .op = .addition, .new_line = 0, .text = "zero" },
    };
    for (invalid_lines) |line| {
        var invalid = valid;
        invalid.lines = &.{line};
        try std.testing.expectError(error.InvalidLineNumbers, invalid.validate());
    }

    var too_many_rows: [max_preview_lines + 1]PreviewLine = undefined;
    for (&too_many_rows) |*line| {
        line.* = .{ .op = .addition, .new_line = 1, .text = "x" };
    }
    var invalid = valid;
    invalid.lines = &too_many_rows;
    try std.testing.expectError(error.TooManyLines, invalid.validate());

    var long_path: [max_encoded_path_bytes + 1]u8 = undefined;
    invalid = valid;
    invalid.path = &long_path;
    try std.testing.expectError(error.PathTooLong, invalid.validate());

    var long_line: [max_encoded_line_bytes + 1]u8 = undefined;
    invalid = valid;
    invalid.lines = &.{.{ .op = .addition, .new_line = 1, .text = &long_line }};
    try std.testing.expectError(error.LineTooLong, invalid.validate());

    var aggregate_lines: [max_preview_lines]PreviewLine = undefined;
    var aggregate_text: [max_encoded_line_bytes]u8 = undefined;
    for (&aggregate_lines) |*line| {
        line.* = .{ .op = .addition, .new_line = 1, .text = &aggregate_text };
    }
    invalid = valid;
    invalid.lines = &aggregate_lines;
    invalid.additions = aggregate_lines.len;
    invalid.deletions = 0;
    try invalid.validate();
}
