const std = @import("std");
const Allocator = std.mem.Allocator;

const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const HistoryTurn = types.HistoryTurn;
const FinishedPrompt = types.FinishedPrompt;

pub const EmitFn = *const fn (*anyopaque, []const u8) anyerror!void;
pub const FinishFn = *const fn (*anyopaque, FinishedPrompt) anyerror!void;

pub const DeferredFinishCommit = enum {
    uncommitted,
    committed,
};

pub const DeferredPresentationCallbacks = struct {
    ctx: *anyopaque,
    append_history: *const fn (*anyopaque, *const FinishedPrompt) anyerror!DeferredFinishCommit,
};

const FlushResult = enum {
    drained,
    blocked,
};

pub const TickCallbacks = struct {
    emit_ctx: *anyopaque,
    emit_fn: EmitFn,
    finish_ctx: *anyopaque,
    finish_fn: FinishFn,
};

pub const SgrState = struct {
    const CodeForeground = enum {
        none,
        dark,
        light,
    };

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    code_fg: CodeForeground = .none,

    pub fn isActive(self: SgrState) bool {
        return self.bold or self.dim or self.italic or self.underline or self.strike or self.code_fg != .none;
    }

    /// Update based on a complete ANSI sequence (including `\x1b[` prefix and
    /// terminator). Unrecognized sequences are ignored, so non-SGR escapes
    /// (cursor moves, erasures, etc.) do not confuse the tracker.
    pub fn apply(self: *SgrState, seq: []const u8) void {
        if (seq.len < 3) return;
        if (seq[0] != 0x1b or seq[1] != '[') return;
        if (seq[seq.len - 1] != 'm') return;
        const body = seq[2 .. seq.len - 1];

        if (body.len == 0 or std.mem.eql(u8, body, "0")) {
            self.* = .{};
            return;
        }

        // Exact full-body match against the known single-parameter codes the
        // markdown renderer emits. Recognized multi-parameter SGRs are
        // matched whole (e.g. "38;5;245"); anything else is ignored.
        if (std.mem.eql(u8, body, "1")) self.bold = true else if (std.mem.eql(u8, body, "2")) self.dim = true else if (std.mem.eql(u8, body, "3")) self.italic = true else if (std.mem.eql(u8, body, "4")) self.underline = true else if (std.mem.eql(u8, body, "9")) self.strike = true else if (std.mem.eql(u8, body, "22")) {
            self.bold = false;
            self.dim = false;
        } else if (std.mem.eql(u8, body, "23")) self.italic = false else if (std.mem.eql(u8, body, "24")) self.underline = false else if (std.mem.eql(u8, body, "29")) self.strike = false else if (std.mem.eql(u8, body, "39")) {
            self.code_fg = .none;
        } else if (std.mem.eql(u8, body, "38;5;245")) self.code_fg = .dark else if (std.mem.eql(u8, body, "38;5;247")) self.code_fg = .light;
    }

    /// Serialize open codes for the currently-active attributes into `buf`.
    /// Returns the number of bytes written (always fits in 31 bytes: five
    /// 4-byte attribute opens and the 11-byte code-foreground open).
    pub fn writeOpens(self: SgrState, buf: []u8) usize {
        var n: usize = 0;
        const append = struct {
            fn f(dst: []u8, pos: *usize, src: []const u8) void {
                if (pos.* + src.len <= dst.len) {
                    @memcpy(dst[pos.* .. pos.* + src.len], src);
                    pos.* += src.len;
                }
            }
        }.f;
        if (self.bold) append(buf, &n, "\x1b[1m");
        if (self.dim) append(buf, &n, "\x1b[2m");
        if (self.italic) append(buf, &n, "\x1b[3m");
        if (self.underline) append(buf, &n, "\x1b[4m");
        if (self.strike) append(buf, &n, "\x1b[9m");
        switch (self.code_fg) {
            .none => {},
            .dark => append(buf, &n, "\x1b[38;5;245m"),
            .light => append(buf, &n, "\x1b[38;5;247m"),
        }
        return n;
    }
};

pub const AssistantPacer = struct {
    pending: std.ArrayList(u8) = .empty,
    deferred_turn: ?FinishedPrompt = null,
    deferred_started_ns: ?i128 = null,
    /// Tracks which SGR attributes the terminal should have active at the
    /// start of the next emit. Other frame-work (footer, body renders)
    /// between ticks can emit their own `\x1b[0m`, so state is restored
    /// by prefixing each emit with `\x1b[0m` + the active opens.
    sgr: SgrState = .{},

    pub fn deinit(self: *AssistantPacer, alloc: Allocator) void {
        self.pending.deinit(alloc);
        if (self.deferred_turn) |finished| {
            types.freeFinishedPrompt(alloc, finished);
            self.deferred_turn = null;
        }
        self.deferred_started_ns = null;
    }

    pub fn hasPending(self: *const AssistantPacer) bool {
        return self.pending.items.len > 0 or self.deferred_turn != null;
    }

    pub fn hasCompletedAssistantPresentationTail(self: *const AssistantPacer) bool {
        const finished = self.deferred_turn orelse return false;
        return finished.terminal_outcome != null and
            finished.terminal_outcome.? == .completed and
            finished.summary != null and
            finished.turn == .assistant;
    }

    pub fn completedAssistantPresentationTokenProgress(self: *const AssistantPacer) ?types.TurnTokenProgress {
        if (!self.hasCompletedAssistantPresentationTail()) return null;
        return self.deferred_turn.?.summary.?.token_progress;
    }

    pub fn enqueue(self: *AssistantPacer, alloc: Allocator, text: []const u8) !void {
        if (text.len == 0) return;
        try self.pending.appendSlice(alloc, text);
    }

    pub fn pause(_: *AssistantPacer, _: i128) void {}

    pub fn rethemeInlineCode(self: *AssistantPacer, light: bool) void {
        const from = if (light) "\x1b[38;5;245m" else "\x1b[38;5;247m";
        const to = if (light) "\x1b[38;5;247m" else "\x1b[38;5;245m";

        var index: usize = 0;
        while (index + from.len <= self.pending.items.len) {
            if (std.mem.startsWith(u8, self.pending.items[index..], from)) {
                @memcpy(self.pending.items[index..][0..to.len], to);
                index += to.len;
            } else {
                index += 1;
            }
        }

        if (self.sgr.code_fg != .none) {
            self.sgr.code_fg = if (light) .light else .dark;
        }
    }

    pub fn deferFinish(self: *AssistantPacer, alloc: Allocator, finished: FinishedPrompt) !bool {
        if (self.pending.items.len == 0) return false;
        if (self.deferred_turn) |old| {
            types.freeFinishedPrompt(alloc, old);
            self.deferred_turn = null;
        }
        self.deferred_turn = try types.dupeFinishedPrompt(alloc, finished);
        self.deferred_started_ns = null;
        return true;
    }

    pub fn clear(self: *AssistantPacer, alloc: Allocator) void {
        self.pending.clearRetainingCapacity();
        if (self.deferred_turn) |finished| {
            types.freeFinishedPrompt(alloc, finished);
            self.deferred_turn = null;
        }
        self.deferred_started_ns = null;
        self.sgr = .{};
    }

    pub fn discardDeferredPresentationForVisualEpoch(
        self: *AssistantPacer,
        alloc: Allocator,
        callbacks: DeferredPresentationCallbacks,
    ) !bool {
        const finished = self.deferred_turn orelse return true;
        if (try callbacks.append_history(callbacks.ctx, &finished) == .uncommitted) return false;

        self.deferred_turn = null;
        types.freeFinishedPrompt(alloc, finished);
        self.pending.clearRetainingCapacity();
        self.deferred_started_ns = null;
        self.sgr = .{};
        return true;
    }

    pub fn tick(self: *AssistantPacer, alloc: Allocator, now_ns: i128, cb: TickCallbacks) !void {
        if (self.pending.items.len == 0) {
            try self.fireDeferredFinish(alloc, now_ns, cb);
            return;
        }

        if (self.deferred_turn != null and self.deferred_started_ns == null) {
            self.deferred_started_ns = now_ns;
        }

        if (try self.emitPendingBlock(cb) == .drained) {
            try self.fireDeferredFinish(alloc, now_ns, cb);
        }
    }

    pub fn flushPresentationAtBoundary(
        self: *AssistantPacer,
        alloc: Allocator,
        now_ns: i128,
        cb: TickCallbacks,
    ) !void {
        if (self.pending.items.len > 0) {
            switch (try self.emitPendingBlock(cb)) {
                .drained => {},
                .blocked => try self.neutralizeIncompleteTail(cb),
            }
        }
        try self.fireDeferredFinish(alloc, now_ns, cb);
    }

    fn emitPendingBlock(self: *AssistantPacer, cb: TickCallbacks) !FlushResult {
        try self.emitCompletePrefix(cb);
        if (self.pending.items.len == 0) {
            return .drained;
        }
        return .blocked;
    }

    fn neutralizeIncompleteTail(self: *AssistantPacer, cb: TickCallbacks) !void {
        const tail = self.pending.items;
        std.debug.assert(tail.len > 0);
        if (tail[0] == 0x1b) {
            const kind: []const u8 = if (tail.len == 1)
                "escape"
            else if (tail[1] == '[')
                "csi"
            else if (tail[1] == ']')
                "osc"
            else
                "escape";
            try cb.emit_fn(cb.emit_ctx, "\xef\xbf\xbd\x1b[0m");
            debug_trace.logf(
                "ui_activity",
                "neutralized incomplete assistant control tail kind={s} bytes={d}",
                .{ kind, tail.len },
            );
        } else {
            try cb.emit_fn(cb.emit_ctx, "\xef\xbf\xbd\x1b[0m");
            debug_trace.logf(
                "ui_activity",
                "neutralized incomplete assistant utf8 tail bytes={d}",
                .{tail.len},
            );
        }

        self.pending.clearRetainingCapacity();
        self.sgr = .{};
    }

    fn fireDeferredFinish(self: *AssistantPacer, alloc: Allocator, now_ns: i128, cb: TickCallbacks) !void {
        if (self.deferred_turn) |finished| {
            self.deferred_turn = null;
            const started_ns = self.deferred_started_ns;
            self.deferred_started_ns = null;
            var callback_finished = finished;
            if (callback_finished.summary) |*summary| {
                const started = started_ns orelse now_ns;
                if (now_ns > started) {
                    summary.turn_duration_ms += @intCast(@divFloor(now_ns - started, std.time.ns_per_ms));
                }
            }
            defer types.freeFinishedPrompt(alloc, callback_finished);
            try cb.finish_fn(cb.finish_ctx, callback_finished);
        }
    }

    fn emitCompletePrefix(self: *AssistantPacer, cb: TickCallbacks) !void {
        const i = self.emittablePrefixLen();
        if (i == 0) return;

        // Restore tracked SGR state because other renderers may reset it between ticks.
        if (self.sgr.isActive()) {
            var prefix_buf: [48]u8 = undefined;
            const reset = "\x1b[0m";
            @memcpy(prefix_buf[0..reset.len], reset);
            const opens_len = self.sgr.writeOpens(prefix_buf[reset.len..]);
            try cb.emit_fn(cb.emit_ctx, prefix_buf[0 .. reset.len + opens_len]);
        }

        try cb.emit_fn(cb.emit_ctx, self.pending.items[0..i]);
        self.updateSgrFromEmitted(self.pending.items[0..i]);
        self.consume(i);
    }

    fn emittablePrefixLen(self: *const AssistantPacer) usize {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const first = self.pending.items[i];
            if (first == 0x1b) {
                // Keep ANSI sequences atomic and hold incomplete tails for a later tick.
                const end = display_width.ansiSequenceEnd(self.pending.items, i);
                if (end > i) {
                    if (!ansiSequenceComplete(self.pending.items, i, end)) break;
                    i = end;
                    continue;
                }
            }
            const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
            if (i + len > self.pending.items.len) break;
            i += len;
        }
        return i;
    }

    fn updateSgrFromEmitted(self: *AssistantPacer, bytes: []const u8) void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            if (bytes[idx] == 0x1b) {
                const end = display_width.ansiSequenceEnd(bytes, idx);
                if (end > idx) self.sgr.apply(bytes[idx..end]);
                idx = if (end > idx) end else idx + 1;
                continue;
            }
            idx += 1;
        }
    }

    fn ansiSequenceComplete(bytes: []const u8, start: usize, end: usize) bool {
        if (end <= start + 1) return false;
        if (start + 1 >= bytes.len) return false;
        const kind = bytes[start + 1];
        if (kind == '[') {
            if (end <= start + 2) return false;
            const last = bytes[end - 1];
            return last >= '@' and last <= '~';
        }
        if (kind == ']') {
            if (end <= start + 2) return false;
            const last = bytes[end - 1];
            if (last == 0x07) return true;
            if (end >= start + 4 and bytes[end - 2] == 0x1b and last == '\\') return true;
            return false;
        }
        return end == start + 2;
    }

    fn consume(self: *AssistantPacer, byte_count: usize) void {
        const remaining = self.pending.items.len - byte_count;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[byte_count..]);
        }
        self.pending.items.len = remaining;
    }
};

const TestCapture = struct {
    emitted: std.ArrayList(u8) = .empty,
    finish_count: usize = 0,
    finish_summary: ?types.TurnSummary = null,

    fn emit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        try self.emitted.appendSlice(std.testing.allocator, text);
    }

    fn finish(ctx: *anyopaque, finished: FinishedPrompt) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.finish_count += 1;
        self.finish_summary = finished.summary;
    }

    fn callbacks(self: *TestCapture) TickCallbacks {
        return .{
            .emit_ctx = self,
            .emit_fn = TestCapture.emit,
            .finish_ctx = self,
            .finish_fn = TestCapture.finish,
        };
    }

    fn deinit(self: *TestCapture) void {
        self.emitted.deinit(std.testing.allocator);
    }
};

fn makeAssistantTurn(alloc: Allocator) !HistoryTurn {
    return .{ .assistant = .{
        .user = .{
            .text = try alloc.dupe(u8, "u"),
            .images = &.{},
        },
        .assistant = try alloc.dupe(u8, "a"),
    } };
}

fn makeCompactedTurn(alloc: Allocator) !HistoryTurn {
    return .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } };
}

test "tick emits one queued rendered block atomically" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    const paragraph = "A complete rendered paragraph.\n\n";
    try pacer.enqueue(alloc, paragraph);

    try pacer.tick(alloc, 0, cap.callbacks());

    try std.testing.expectEqualStrings(paragraph, cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
}

test "presentation boundary emits the queued block before continuing" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    const paragraph = "Explanation before a tool.\n";
    try pacer.enqueue(alloc, paragraph);

    try pacer.flushPresentationAtBoundary(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings(paragraph, cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
}

test "tick emits a complete UTF-8 block" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "áñ");

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("áñ", cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
}

test "partial UTF-8 at buffer tail is held until rest arrives" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // 0xc3 begins a two-byte sequence.
    try pacer.enqueue(alloc, &[_]u8{0xc3});

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.emitted.items.len);
    try std.testing.expectEqual(@as(usize, 1), pacer.pending.items.len);

    try pacer.enqueue(alloc, &[_]u8{0xa1});
    try pacer.tick(alloc, 1, cap.callbacks());
    try std.testing.expectEqualStrings("á", cap.emitted.items);
}

test "large rendered block emits in one tick" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    var big: [1000]u8 = undefined;
    @memset(&big, 'x');
    try pacer.enqueue(alloc, &big);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualSlices(u8, &big, cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
}

test "deferFinish returns false when buffer empty" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);

    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);

    const deferred = try pacer.deferFinish(alloc, .{ .turn = turn });
    try std.testing.expect(!deferred);
    try std.testing.expect(pacer.deferred_turn == null);
}

test "presentation boundary neutralizes only the incomplete ANSI or UTF-8 tail" {
    const alloc = std.testing.allocator;

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = TestCapture{};
        defer cap.deinit();

        try pacer.enqueue(alloc, "visible\x1b[1");
        try pacer.tick(alloc, 0, cap.callbacks());
        try pacer.tick(alloc, 100 * std.time.ns_per_ms, cap.callbacks());
        try std.testing.expectEqualStrings("visible", cap.emitted.items);
        try pacer.flushPresentationAtBoundary(alloc, 100 * std.time.ns_per_ms, cap.callbacks());

        try std.testing.expectEqualStrings("visible\xef\xbf\xbd\x1b[0m", cap.emitted.items);
        try std.testing.expect(!pacer.hasPending());
        try std.testing.expect(!pacer.sgr.isActive());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = TestCapture{};
        defer cap.deinit();

        try pacer.enqueue(alloc, &.{0xc3});
        try pacer.flushPresentationAtBoundary(alloc, 0, cap.callbacks());

        try std.testing.expectEqualStrings("\xef\xbf\xbd\x1b[0m", cap.emitted.items);
        try std.testing.expect(!pacer.hasPending());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = TestCapture{};
        defer cap.deinit();

        try pacer.enqueue(alloc, "visible\x1b]52;c;unsafe");
        try pacer.tick(alloc, 0, cap.callbacks());
        try pacer.tick(alloc, 100 * std.time.ns_per_ms, cap.callbacks());
        try pacer.flushPresentationAtBoundary(alloc, 100 * std.time.ns_per_ms, cap.callbacks());

        try std.testing.expectEqualStrings("visible\xef\xbf\xbd\x1b[0m", cap.emitted.items);
        try std.testing.expect(std.mem.find(u8, cap.emitted.items, "52;c;unsafe") == null);
        try std.testing.expect(!pacer.hasPending());
    }
}

test "presentation boundary preserves callback errors and pending bytes" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    try pacer.enqueue(alloc, "\x1b[1");

    const Failing = struct {
        fn emit(_: *anyopaque, _: []const u8) anyerror!void {
            return error.InjectedEmitFailure;
        }

        fn finish(_: *anyopaque, _: FinishedPrompt) anyerror!void {}
    };
    var ctx: u8 = 0;
    const callbacks: TickCallbacks = .{
        .emit_ctx = &ctx,
        .emit_fn = Failing.emit,
        .finish_ctx = &ctx,
        .finish_fn = Failing.finish,
    };

    try std.testing.expectError(
        error.InjectedEmitFailure,
        pacer.flushPresentationAtBoundary(alloc, 0, callbacks),
    );
    try std.testing.expectEqualStrings("\x1b[1", pacer.pending.items);
}

test "deferFinish defers and fires when buffer drains" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "hi");

    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);

    const deferred = try pacer.deferFinish(alloc, .{ .turn = turn });
    try std.testing.expect(deferred);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("hi", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expect(pacer.deferred_turn == null);
}

test "deferFinish carries summary only after pending text drains" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "hi");

    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    const summary: types.TurnSummary = .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    };

    const deferred = try pacer.deferFinish(alloc, .{ .turn = turn, .summary = summary });
    try std.testing.expect(deferred);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("hi", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expectEqual(@as(u64, 5_000), cap.finish_summary.?.token_progress.output_tokens);
    try std.testing.expectEqual(@as(u64, 130_000), cap.finish_summary.?.turn_duration_ms);
}

test "presentation boundary emits text before deferred finish" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "tail");
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    const summary: types.TurnSummary = .{
        .thinking_duration_ms = 1_000,
        .turn_duration_ms = 2_000,
        .token_progress = .{ .output_tokens = 3 },
    };

    try std.testing.expect(try pacer.deferFinish(alloc, .{
        .turn = turn,
        .summary = summary,
        .terminal_outcome = .completed,
    }));

    try pacer.flushPresentationAtBoundary(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("tail", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expectEqual(@as(u64, 3), cap.finish_summary.?.token_progress.output_tokens);
    try std.testing.expect(!pacer.hasPending());
}

test "completed assistant summary is the only deferred presentation tail" {
    const alloc = std.testing.allocator;
    const summary: types.TurnSummary = .{
        .thinking_duration_ms = 1_000,
        .turn_duration_ms = 2_000,
        .token_progress = .{ .input_tokens = 50_000, .output_tokens = 20_000 },
    };

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(try pacer.deferFinish(alloc, .{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .completed,
        }));
        try std.testing.expect(pacer.hasCompletedAssistantPresentationTail());
        try std.testing.expectEqual(summary.token_progress, pacer.completedAssistantPresentationTokenProgress().?);
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "error bytes");
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(try pacer.deferFinish(alloc, .{
            .turn = turn,
            .terminal_outcome = .completed,
        }));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(try pacer.deferFinish(alloc, .{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .failed,
        }));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeCompactedTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(try pacer.deferFinish(alloc, .{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .completed,
        }));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(try pacer.deferFinish(alloc, .{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .interrupted,
        }));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }
}

test "clear drops pending and deferred turn" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);

    try pacer.enqueue(alloc, "lots of text");
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    _ = try pacer.deferFinish(alloc, .{ .turn = turn });

    try std.testing.expect(pacer.hasPending());
    pacer.clear(alloc);
    try std.testing.expect(!pacer.hasPending());
}

test "visual epoch discard retains uncommitted deferred finish and drops committed presentation" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    try pacer.enqueue(alloc, "stale presentation");
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expect(try pacer.deferFinish(alloc, .{ .turn = turn }));

    const Capture = struct {
        outcome: DeferredFinishCommit = .uncommitted,
        calls: usize = 0,

        fn append(ctx: *anyopaque, _: *const FinishedPrompt) anyerror!DeferredFinishCommit {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return self.outcome;
        }
    };
    var capture = Capture{};
    const callbacks: DeferredPresentationCallbacks = .{
        .ctx = &capture,
        .append_history = Capture.append,
    };

    try std.testing.expect(!try pacer.discardDeferredPresentationForVisualEpoch(alloc, callbacks));
    try std.testing.expect(pacer.hasPending());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.outcome = .committed;
    try std.testing.expect(try pacer.discardDeferredPresentationForVisualEpoch(alloc, callbacks));
    try std.testing.expect(!pacer.hasPending());
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "ANSI-styled block emits atomically" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[1mhi\x1b[22m!");

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("\x1b[1mhi\x1b[22m!", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 0), pacer.pending.items.len);
}

test "incomplete ANSI sequence at tail is held until completion arrives" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "x\x1b[1");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.tick(alloc, 3_000_000, cap.callbacks());
    try std.testing.expectEqualStrings("x", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 3), pacer.pending.items.len);

    try pacer.enqueue(alloc, "my");
    try pacer.tick(alloc, 100_000_000, cap.callbacks());
    try std.testing.expectEqualStrings("x\x1b[1my", cap.emitted.items);
}

test "code style is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;245mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[39m done");
    try pacer.tick(alloc, 1, cap.callbacks());

    try std.testing.expect(std.mem.indexOf(u8, cap.emitted.items, "code\x1b[0m\x1b[38;5;245m\x1b[39m done") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.emitted.items, "\x1b[39m") != null);
}

test "light code style is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;247mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[39m done");
    try pacer.tick(alloc, 1, cap.callbacks());

    try std.testing.expect(std.mem.indexOf(
        u8,
        cap.emitted.items,
        "code\x1b[0m\x1b[38;5;247m\x1b[39m done",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.emitted.items, "\x1b[39m") != null);
}

test "theme change retints active code before the next block" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;245mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    const emitted_before_theme_change = cap.emitted.items.len;

    pacer.rethemeInlineCode(true);
    try pacer.enqueue(alloc, "\x1b[39m");
    try pacer.tick(alloc, 1, cap.callbacks());

    const after_theme_change = cap.emitted.items[emitted_before_theme_change..];
    try std.testing.expect(std.mem.indexOf(u8, after_theme_change, "\x1b[0m\x1b[38;5;247m") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_theme_change, "\x1b[38;5;245m") == null);
}

test "theme change retints a queued inline code opener before it is emitted" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "x\x1b[38;5;247mcode\x1b[39m");
    pacer.rethemeInlineCode(false);
    try pacer.tick(alloc, 0, cap.callbacks());

    try std.testing.expect(std.mem.indexOf(u8, cap.emitted.items, "\x1b[38;5;245m") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.emitted.items, "\x1b[38;5;247m") == null);
}

test "underline style is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[4mHeading");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[24m");
    try pacer.tick(alloc, 1, cap.callbacks());

    try std.testing.expect(std.mem.indexOf(
        u8,
        cap.emitted.items,
        "Heading\x1b[0m\x1b[4m\x1b[24m",
    ) != null);

    var sgr: SgrState = .{};
    sgr.apply("\x1b[4m");
    try std.testing.expect(sgr.isActive());
    var opens: [16]u8 = undefined;
    const opens_len = sgr.writeOpens(&opens);
    try std.testing.expectEqualStrings("\x1b[4m", opens[0..opens_len]);
    sgr.apply("\x1b[24m");
    try std.testing.expect(!sgr.isActive());
}

test "no sgr prefix emitted when state is clean" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "hello");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.tick(alloc, 100_000_000, cap.callbacks());
    try std.testing.expectEqualStrings("hello", cap.emitted.items);
}

test "sgr state clears after closing code" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[1mA\x1b[22mB");
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expect(!pacer.sgr.bold);
}

test "tick on empty pacer without deferred finish is a no-op" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.tick(alloc, 1_000_000_000, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.emitted.items.len);
    try std.testing.expectEqual(@as(usize, 0), cap.finish_count);
}
