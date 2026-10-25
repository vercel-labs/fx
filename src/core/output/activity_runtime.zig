const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const types = @import("../shared/types.zig");

pub const ToolLifecyclePhase = enum {
    provisional,
    authoritative,
    terminal,
};

pub const CancellationPresentation = enum {
    none,
    pending,
    tool_status,
    replaced,
};

const TurnCancellationState = struct {
    turn_id: u64,
    interrupted: bool = false,
    notice_presented: bool = false,
};

pub const ToolPresentationRecord = struct {
    id: types.ToolLifecycleId,
    entry_id: u32,
    tool_name: ?[]const u8,
    activity_kind: types.ToolActivityKind,
    captured_command: bool = false,
    cancellation_presentation: CancellationPresentation = .none,
    phase: ToolLifecyclePhase,
    focus_seq: u64,
};

pub const ActivityProjection = union(enum) {
    pub const Tone = enum {
        thinking,
        neutral,
        warning,
        success,
        danger,
    };

    pub const TurnThinking = struct {
        label: []const u8,
        tone: Tone = .thinking,
        /// Tail of the reasoning streamed for this step, shown under the
        /// status row while the turn is still thinking. Borrowed, and empty
        /// when the provider sent no visible reasoning.
        detail: []const u8 = "",
    };

    pub const ToolSlot = struct {
        entry_id: u32,
        fallback_label: []const u8,
        active: bool,
        kind: types.ToolActivityKind,
        thinking_label: ?[]const u8 = null,
    };

    none,
    turn_thinking: TurnThinking,
    tool_slot: ToolSlot,
};

/// Immutable view of lifecycle state. Slice fields borrow presenter-owned
/// storage and remain valid only until the next lifecycle mutation.
pub const LifecycleSnapshot = struct {
    finalized_turn_watermark: u64,
    active_tool_count: usize,
    focused_entry_id: ?u32,
    focused_activity_kind: ?types.ToolActivityKind,
    activity: ActivityProjection,
};

/// Result of one lifecycle mutation. Any slices in the terminal record share
/// the snapshot's borrowed lifetime.
pub const LifecycleTransition = struct {
    previous_focused_entry_id: ?u32,
    snapshot: LifecycleSnapshot,
    applied_activity_kind: ?types.ToolActivityKind,
    terminal_record: ?ToolPresentationRecord,

    pub fn focus_changed(self: LifecycleTransition) bool {
        return self.previous_focused_entry_id != self.snapshot.focused_entry_id;
    }
};

pub const LifecyclePresenter = struct {
    ctx: *anyopaque,
    snapshot_fn: *const fn (*anyopaque) LifecycleSnapshot,
    record_fn: *const fn (*anyopaque, types.ToolLifecycleId) ?ToolPresentationRecord,
    apply_fn: *const fn (*anyopaque, std.mem.Allocator, types.ToolLifecycleEvent) anyerror!LifecycleTransition,
    finish_batch_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!void,

    pub fn snapshot(self: LifecyclePresenter) LifecycleSnapshot {
        return self.snapshot_fn(self.ctx);
    }

    pub fn record(
        self: LifecyclePresenter,
        id: types.ToolLifecycleId,
    ) ?ToolPresentationRecord {
        return self.record_fn(self.ctx, id);
    }

    pub fn apply(
        self: LifecyclePresenter,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !LifecycleTransition {
        return self.apply_fn(
            self.ctx,
            alloc,
            event,
        );
    }

    pub fn finish_batch(
        self: LifecyclePresenter,
        alloc: std.mem.Allocator,
    ) !void {
        return self.finish_batch_fn(self.ctx, alloc);
    }
};

pub const FallbackRecord = struct {
    record: *ToolPresentationRecord,
    was_provisional: bool,
};

pub const StartAdmission = union(enum) {
    accepted,
    invalid_identity,
    finalized: u64,
};

const LifecycleContext = struct {
    pub fn hash(_: LifecycleContext, id: types.ToolLifecycleId) u64 {
        return std.hash.Wyhash.hash(id.turn_id, id.call_id);
    }

    pub fn eql(_: LifecycleContext, a: types.ToolLifecycleId, b: types.ToolLifecycleId) bool {
        return a.turn_id == b.turn_id and std.mem.eql(u8, a.call_id, b.call_id);
    }
};

const RecordMap = std.HashMapUnmanaged(
    types.ToolLifecycleId,
    ToolPresentationRecord,
    LifecycleContext,
    std.hash_map.default_max_load_percentage,
);

pub const ToolActivityState = struct {
    records: RecordMap = .empty,
    batch_finalized_turn_watermark: ?u64 = null,
    finalized_turn_watermark: u64 = 0,
    turn_cancellation: ?TurnCancellationState = null,
    next_focus_seq: u64 = 0,

    pub fn deinit(self: *ToolActivityState, alloc: std.mem.Allocator) void {
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| freeRecord(alloc, record_ptr.*);
        self.records.deinit(alloc);
        self.* = .{};
    }

    pub fn ensureRecordCapacity(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
    ) !void {
        try self.records.ensureUnusedCapacityContext(alloc, 1, .{});
    }

    pub fn record(
        self: *const ToolActivityState,
        id: types.ToolLifecycleId,
    ) ?ToolPresentationRecord {
        return self.records.getContext(id, .{});
    }

    pub fn recordPtr(
        self: *ToolActivityState,
        id: types.ToolLifecycleId,
    ) ?*ToolPresentationRecord {
        return self.records.getPtrContext(id, .{});
    }

    pub fn recordCount(self: *const ToolActivityState) usize {
        return self.records.count();
    }

    pub fn activeCount(self: *const ToolActivityState) usize {
        var count: usize = 0;
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.phase != .terminal) count += 1;
        }
        return count;
    }

    pub fn needsTurnCancellationNoticeAfterTerminal(
        self: *const ToolActivityState,
        id: types.ToolLifecycleId,
    ) bool {
        const cancellation = self.turn_cancellation orelse return false;
        if (cancellation.turn_id != id.turn_id or
            !cancellation.interrupted or
            cancellation.notice_presented)
        {
            return false;
        }
        const settling = self.record(id) orelse return false;
        switch (settling.cancellation_presentation) {
            .none => return false,
            .pending, .tool_status, .replaced => {},
        }
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id != id.turn_id or
                std.mem.eql(u8, record_ptr.id.call_id, id.call_id))
            {
                continue;
            }
            switch (record_ptr.cancellation_presentation) {
                .pending, .tool_status => return false,
                .none, .replaced => {},
            }
        }
        return true;
    }

    pub fn needsTurnCancellationNoticeAfterTurnFinished(
        self: *const ToolActivityState,
        turn_id: u64,
    ) bool {
        const cancellation = self.turn_cancellation orelse return false;
        if (cancellation.turn_id != turn_id or cancellation.notice_presented) {
            return false;
        }
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id != turn_id) continue;
            switch (record_ptr.cancellation_presentation) {
                .pending, .tool_status => return false,
                .none, .replaced => {},
            }
        }
        return true;
    }

    pub fn markTurnCancellationPresented(
        self: *ToolActivityState,
        turn_id: u64,
    ) void {
        self.turn_cancellation = .{ .turn_id = turn_id };
    }

    pub fn markTurnInterrupted(
        self: *ToolActivityState,
        turn_id: u64,
    ) void {
        if (self.turn_cancellation) |*cancellation| {
            if (cancellation.turn_id == turn_id) cancellation.interrupted = true;
        }
    }

    pub fn markTurnCancellationNoticePresented(
        self: *ToolActivityState,
        turn_id: u64,
    ) void {
        if (self.turn_cancellation) |*cancellation| {
            if (cancellation.turn_id == turn_id) cancellation.notice_presented = true;
        }
    }

    pub fn focusedRecord(
        self: *const ToolActivityState,
    ) ?*const ToolPresentationRecord {
        var focused: ?*const ToolPresentationRecord = null;
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.phase == .terminal) continue;
            if (focused == null or record_ptr.focus_seq > focused.?.focus_seq) {
                focused = record_ptr;
            }
        }
        return focused;
    }

    pub fn admitStart(
        self: *const ToolActivityState,
        id: types.ToolLifecycleId,
    ) StartAdmission {
        if (id.turn_id == 0 or id.call_id.len == 0) return .invalid_identity;
        const fence = @max(
            self.finalized_turn_watermark,
            self.batch_finalized_turn_watermark orelse 0,
        );
        if (id.turn_id <= fence) return .{ .finalized = fence };
        return .accepted;
    }

    pub fn isFenced(
        self: *const ToolActivityState,
        turn_id: u64,
    ) bool {
        return turn_id <= @max(
            self.finalized_turn_watermark,
            self.batch_finalized_turn_watermark orelse 0,
        );
    }

    pub fn putOwnedRecord(
        self: *ToolActivityState,
        id: types.ToolLifecycleId,
        tool_name: ?[]const u8,
        activity_kind: types.ToolActivityKind,
        entry_id: u32,
        phase: ToolLifecyclePhase,
    ) void {
        const focus_seq = self.claimFocus();
        self.records.putAssumeCapacityNoClobberContext(id, .{
            .id = id,
            .entry_id = entry_id,
            .tool_name = tool_name,
            .activity_kind = activity_kind,
            .cancellation_presentation = if (self.turn_cancellation) |cancellation|
                if (cancellation.turn_id == id.turn_id) .pending else .none
            else
                .none,
            .phase = phase,
            .focus_seq = focus_seq,
        }, .{});
    }

    pub fn promoteOwned(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
        record_ptr: *ToolPresentationRecord,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
    ) bool {
        const first_authoritative = record_ptr.phase != .authoritative;
        replaceToolName(alloc, record_ptr, tool_name);
        record_ptr.activity_kind = activity_kind;
        record_ptr.phase = .authoritative;
        if (first_authoritative) record_ptr.focus_seq = self.claimFocus();
        return first_authoritative;
    }

    pub fn rekeyOwned(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
        old_id: types.ToolLifecycleId,
        new_id: types.ToolLifecycleId,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
    ) void {
        var removed = self.records.fetchRemoveContext(old_id, .{}).?;
        alloc.free(@constCast(removed.value.id.call_id));
        if (removed.value.tool_name) |old_name| alloc.free(@constCast(old_name));
        removed.value.id = new_id;
        removed.value.tool_name = tool_name;
        removed.value.activity_kind = activity_kind;
        removed.value.phase = .authoritative;
        removed.value.focus_seq = self.claimFocus();
        self.records.putAssumeCapacityNoClobberContext(new_id, removed.value, .{});
    }

    pub fn shouldApplyTurnFinished(
        self: *const ToolActivityState,
        turn_id: u64,
    ) bool {
        if (turn_id == 0) return false;
        if (turn_id <= self.finalized_turn_watermark) return false;
        if (self.batch_finalized_turn_watermark) |watermark| {
            if (turn_id <= watermark) return false;
        }
        return true;
    }

    pub fn collectFallbackRecords(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
        turn_id: u64,
    ) ![]FallbackRecord {
        var count: usize = 0;
        var count_iterator = self.records.valueIterator();
        while (count_iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id == turn_id and record_ptr.phase != .terminal) {
                count += 1;
            }
        }

        const result = try alloc.alloc(FallbackRecord, count);
        var index: usize = 0;
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id != turn_id or record_ptr.phase == .terminal) continue;
            result[index] = .{
                .record = record_ptr,
                .was_provisional = record_ptr.phase == .provisional,
            };
            index += 1;
        }
        return result;
    }

    pub fn commitTurnFinished(
        self: *ToolActivityState,
        turn_id: u64,
        fallbacks: []const FallbackRecord,
    ) void {
        for (fallbacks) |fallback| {
            fallback.record.phase = .terminal;
        }
        self.batch_finalized_turn_watermark = @max(
            self.batch_finalized_turn_watermark orelse 0,
            turn_id,
        );
    }

    pub fn cleanupEntryIds(
        self: *const ToolActivityState,
        alloc: std.mem.Allocator,
        watermark: u64,
    ) ![]u32 {
        var count: usize = 0;
        var count_iterator = self.records.valueIterator();
        while (count_iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id <= watermark) count += 1;
        }

        const result = try alloc.alloc(u32, count);
        var index: usize = 0;
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id > watermark) continue;
            result[index] = record_ptr.entry_id;
            index += 1;
        }
        return result;
    }

    pub fn pausedTurnEntryIds(
        self: *const ToolActivityState,
        alloc: std.mem.Allocator,
        turn_id: u64,
    ) ![]u32 {
        var count: usize = 0;
        var count_iterator = self.records.valueIterator();
        while (count_iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id == turn_id) count += 1;
        }

        const result = try alloc.alloc(u32, count);
        var index: usize = 0;
        var iterator = self.records.valueIterator();
        while (iterator.next()) |record_ptr| {
            if (record_ptr.id.turn_id != turn_id) continue;
            result[index] = record_ptr.entry_id;
            index += 1;
        }
        return result;
    }

    pub fn releasePausedTurn(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
        turn_id: u64,
    ) void {
        while (true) {
            var removable: ?types.ToolLifecycleId = null;
            var iterator = self.records.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.id.turn_id == turn_id) {
                    removable = entry.key_ptr.*;
                    break;
                }
            }
            const id = removable orelse break;
            const removed = self.records.fetchRemoveContext(id, .{}).?;
            freeRecord(alloc, removed.value);
        }
    }

    pub fn commitCleanup(
        self: *ToolActivityState,
        alloc: std.mem.Allocator,
        watermark: u64,
    ) void {
        while (true) {
            var removable: ?types.ToolLifecycleId = null;
            var iterator = self.records.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.id.turn_id <= watermark) {
                    removable = entry.key_ptr.*;
                    break;
                }
            }
            const id = removable orelse break;
            const removed = self.records.fetchRemoveContext(id, .{}).?;
            freeRecord(alloc, removed.value);
        }
        self.finalized_turn_watermark = @max(
            self.finalized_turn_watermark,
            watermark,
        );
        self.batch_finalized_turn_watermark = null;
    }

    fn claimFocus(self: *ToolActivityState) u64 {
        self.next_focus_seq +%= 1;
        if (self.next_focus_seq == 0) self.next_focus_seq = 1;
        return self.next_focus_seq;
    }
};

pub fn replaceToolName(
    alloc: std.mem.Allocator,
    record: *ToolPresentationRecord,
    owned_tool_name: []const u8,
) void {
    if (record.tool_name) |old_name| alloc.free(@constCast(old_name));
    record.tool_name = owned_tool_name;
}

fn freeRecord(
    alloc: std.mem.Allocator,
    record: ToolPresentationRecord,
) void {
    alloc.free(@constCast(record.id.call_id));
    if (record.tool_name) |tool_name| alloc.free(@constCast(tool_name));
}

test "tool activity start admission describes invalid and finalized identities" {
    var state = ToolActivityState{};

    try std.testing.expectEqual(
        StartAdmission.invalid_identity,
        state.admitStart(.{ .turn_id = 0, .call_id = "call" }),
    );
    try std.testing.expectEqual(
        StartAdmission.invalid_identity,
        state.admitStart(.{ .turn_id = 1, .call_id = "" }),
    );
    try std.testing.expectEqual(
        StartAdmission.accepted,
        state.admitStart(.{ .turn_id = 1, .call_id = "call" }),
    );

    state.commitCleanup(std.testing.allocator, 1);
    switch (state.admitStart(.{ .turn_id = 1, .call_id = "call" })) {
        .finalized => |fence| try std.testing.expectEqual(@as(u64, 1), fence),
        .accepted, .invalid_identity => return error.TestUnexpectedResult,
    }
}

test "lifecycle transition reports focus changes from immutable snapshots" {
    const unchanged = LifecycleTransition{
        .previous_focused_entry_id = 4,
        .snapshot = .{
            .finalized_turn_watermark = 1,
            .active_tool_count = 1,
            .focused_entry_id = 4,
            .focused_activity_kind = .read,
            .activity = .none,
        },
        .applied_activity_kind = .read,
        .terminal_record = null,
    };
    try std.testing.expect(!unchanged.focus_changed());

    var changed = unchanged;
    changed.snapshot.focused_entry_id = 7;
    try std.testing.expect(changed.focus_changed());
}

/// Visual rows of live reasoning the activity band shows at most.
pub const reasoning_preview_row_limit: usize = 3;
/// Newest reasoning bytes kept for the inline preview.
pub const reasoning_preview_max_bytes: usize = 4096;
/// Preview rows align under the status label's marker.
pub const reasoning_preview_indent_width: usize = 2;

/// Keeps the newest reasoning bytes after `chunk` joins `list`. The buffer is
/// display-only, so a dropped prefix lands on a line boundary when the text
/// has one; an unbroken line keeps its newest bytes without splitting a
/// codepoint.
pub fn appendReasoningPreviewTail(
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    chunk: []const u8,
) !void {
    if (chunk.len == 0) return;
    var start: usize = 0;
    if (chunk.len >= reasoning_preview_max_bytes) {
        start = chunk.len - reasoning_preview_max_bytes;
        while (start < chunk.len and (chunk[start] & 0xc0) == 0x80) start += 1;
        list.clearRetainingCapacity();
    }
    try list.appendSlice(alloc, chunk[start..]);
    if (list.items.len <= reasoning_preview_max_bytes) return;

    const excess = list.items.len - reasoning_preview_max_bytes;
    var cut = excess;
    while (cut < list.items.len and list.items[cut] != '\n') cut += 1;
    if (cut == list.items.len) {
        cut = excess;
        while (cut < list.items.len and (list.items[cut] & 0xc0) == 0x80) cut += 1;
    } else {
        cut += 1;
    }
    if (cut >= list.items.len) {
        list.clearRetainingCapacity();
        return;
    }
    @memmove(list.items[0 .. list.items.len - cut], list.items[cut..]);
    list.shrinkRetainingCapacity(list.items.len - cut);
}

const PreviewSpan = struct { start: usize, len: usize };

/// Wraps `text` into at most the newest `reasoning_preview_row_limit` visual
/// rows. Each row already fits `cols`; the indent width is reserved here so
/// paint-time rows never need rewrapping.
fn previewSpans(
    text: []const u8,
    cols: u16,
    spans: *[reasoning_preview_row_limit]PreviewSpan,
) usize {
    const safe_cols: usize = @max(cols, 1);
    const indent: usize = @min(@as(usize, reasoning_preview_indent_width), safe_cols - 1);
    const available: usize = safe_cols - indent;
    var remaining = std.mem.trimStart(u8, text, " \t\r\n");
    var stored: usize = 0;
    while (remaining.len > 0) {
        const newline = std.mem.findScalar(u8, remaining, '\n') orelse remaining.len;
        var line = std.mem.trimEnd(u8, remaining[0..newline], " \t\r");
        remaining = if (newline < remaining.len)
            std.mem.trimStart(u8, remaining[newline + 1 ..], " \t\r\n")
        else
            "";
        while (line.len > 0) {
            var chunk = display_width.wrapCutIgnoringAnsi(line, available);
            if (chunk.len == 0) {
                const unit = display_width.displayUnitAt(line, 0);
                chunk = line[0..unit.byte_len];
            }
            const span: PreviewSpan = .{
                .start = @intFromPtr(chunk.ptr) - @intFromPtr(text.ptr),
                .len = chunk.len,
            };
            if (stored < reasoning_preview_row_limit) {
                spans[stored] = span;
                stored += 1;
            } else {
                @memmove(spans[0 .. reasoning_preview_row_limit - 1], spans[1..reasoning_preview_row_limit]);
                spans[reasoning_preview_row_limit - 1] = span;
            }
            line = std.mem.trimStart(u8, line[chunk.len..], " \t");
        }
    }
    return stored;
}

pub fn reasoningPreviewRowCount(text: []const u8, cols: u16) u16 {
    if (text.len == 0) return 0;
    var spans: [reasoning_preview_row_limit]PreviewSpan = undefined;
    return @intCast(previewSpans(text, cols, &spans));
}

/// Fills `out` with the newest preview rows, oldest first.
pub fn reasoningPreviewRows(
    text: []const u8,
    cols: u16,
    out: *[reasoning_preview_row_limit][]const u8,
) []const []const u8 {
    var spans: [reasoning_preview_row_limit]PreviewSpan = undefined;
    const stored = previewSpans(text, cols, &spans);
    for (0..stored) |i| {
        const span = spans[i];
        out[i] = text[span.start .. span.start + span.len];
    }
    return out[0..stored];
}

test "reasoning preview keeps the newest bounded tail on a line boundary" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendReasoningPreviewTail(&list, std.testing.allocator, "first line\nsecond line\n");
    try std.testing.expectEqualStrings("first line\nsecond line\n", list.items);

    const filler = try std.testing.allocator.alloc(u8, reasoning_preview_max_bytes);
    defer std.testing.allocator.free(filler);
    @memset(filler, 'x');
    try appendReasoningPreviewTail(&list, std.testing.allocator, filler);
    try std.testing.expect(list.items.len <= reasoning_preview_max_bytes);
    try std.testing.expect(list.items.len > 0);
}

test "reasoning preview rows keep only the newest three visual rows" {
    const text = "alpha beta gamma delta epsilon zeta eta theta";
    var rows: [reasoning_preview_row_limit][]const u8 = undefined;
    const shown = reasoningPreviewRows(text, 10, &rows);
    try std.testing.expectEqual(@as(usize, reasoning_preview_row_limit), shown.len);
    try std.testing.expectEqual(@as(u16, reasoning_preview_row_limit), reasoningPreviewRowCount(text, 10));
    try std.testing.expect(std.mem.find(u8, shown[shown.len - 1], "theta") != null);

    try std.testing.expectEqual(@as(u16, 0), reasoningPreviewRowCount("", 10));
    try std.testing.expectEqual(@as(u16, reasoning_preview_row_limit), reasoningPreviewRowCount(text, 1));
}

test "reasoning preview rows never split a wide codepoint" {
    var rows: [reasoning_preview_row_limit][]const u8 = undefined;
    const shown = reasoningPreviewRows("界海語 reasoning tail", 3, &rows);
    try std.testing.expect(shown.len > 0);
    for (shown) |row| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(row));
    }
}
