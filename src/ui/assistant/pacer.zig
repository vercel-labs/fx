const std = @import("std");
const Allocator = std.mem.Allocator;

const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const theme_retint = @import("../../core/shared/theme_retint.zig");
const types = @import("../../core/shared/types.zig");
const HistoryTurn = types.HistoryTurn;
const FinishedPrompt = types.FinishedPrompt;

pub const EmitFn = *const fn (*anyopaque, []const u8) anyerror!void;
pub const FinishResult = union(enum) {
    committed,
    presentation_failed: anyerror,
};

pub const DeferredPresentation = struct {
    summary: ?types.TurnSummary = null,
    terminal_outcome: ?types.TurnPresentationOutcome = null,
    is_assistant: bool = false,
    turn_started_ms: ?i64 = null,
    token_progress: ?types.TurnTokenProgress = null,

    pub fn fromFinishedPrompt(finished: FinishedPrompt) DeferredPresentation {
        return .{
            .summary = finished.summary,
            .terminal_outcome = finished.terminal_outcome,
            .is_assistant = finished.turn == .assistant,
            .token_progress = if (finished.summary) |s| s.token_progress else null,
        };
    }
};

pub const FinishFn = *const fn (*anyopaque, DeferredPresentation) anyerror!FinishResult;

const FlushResult = enum {
    drained,
    blocked,
};

pub const TickCallbacks = struct {
    emit_ctx: *anyopaque,
    emit_fn: EmitFn,
    finish_ctx: *anyopaque,
    finish_fn: FinishFn,
    /// Writes the Ctrl+O line of a call held until its text was shown
    /// (`holdModelCall`), with `emit_ctx`.
    model_call_fn: ?*const fn (*anyopaque, types.ModelCallRecord) anyerror!void = null,
    /// Reports that the tail with this id is due. The caller applies it, with `emit_ctx`.
    tail_due_fn: ?*const fn (*anyopaque, u64) anyerror!void = null,
};

const TailSlot = struct {
    id: u64,
    released_target: u64,
    arrived_ns: ?i128 = null,
};

const max_tail_slots: usize = 4096;
pub const reveal_frame_ns: i128 = 16 * std.time.ns_per_ms;
const reveal_max_tick_elapsed_ns: i128 = 1 * std.time.ns_per_s;
const reveal_drain_window_ns: i128 = 100 * std.time.ns_per_ms;
const reveal_rate_window_ns: i128 = 100 * std.time.ns_per_ms;
const reveal_finish_window_ns: i128 = 100 * std.time.ns_per_ms;
const max_rate_samples: usize = 64;

const RateSample = struct {
    at_ns: i128,
    arrived: usize,
};

fn windowRate(entries: []const RateSample, now_ns: i128) f64 {
    const cutoff_ns = now_ns - reveal_rate_window_ns;
    var total_arrived: usize = 0;
    for (entries) |entry| {
        if (entry.at_ns > cutoff_ns and entry.at_ns <= now_ns) {
            total_arrived +|= entry.arrived;
        }
    }
    if (total_arrived == 0) return 0.0;
    const window_s: f64 = @as(f64, @floatFromInt(reveal_rate_window_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    return @as(f64, @floatFromInt(total_arrived)) / window_s;
}

const RevealPlan = struct {
    steps: usize,
    rate_steps: usize,
    window_steps: usize,
    finish_steps: usize,
};

fn revealPlan(
    backlog: usize,
    rate_steps_per_s: f64,
    tick_elapsed_ns: i128,
    finish_remaining_ns: ?i128,
    age_steps: usize,
) RevealPlan {
    if (backlog == 0) return .{ .steps = 0, .rate_steps = 0, .window_steps = 0, .finish_steps = 0 };
    const clamped_elapsed_ns: i128 = std.math.clamp(tick_elapsed_ns, reveal_frame_ns, reveal_max_tick_elapsed_ns);
    const backlog_u128: u128 = @intCast(backlog);
    const elapsed_u128: u128 = @intCast(clamped_elapsed_ns);
    const window_u128: u128 = @intCast(reveal_drain_window_ns);
    const window_steps: usize = @intCast(@min(backlog_u128, @divCeil(backlog_u128 *| elapsed_u128, window_u128)));

    const rate_steps: usize = if (!std.math.isFinite(rate_steps_per_s) or rate_steps_per_s <= 0.0)
        0
    else blk: {
        const elapsed_s: f64 = @as(f64, @floatFromInt(clamped_elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const scaled = @ceil(rate_steps_per_s * elapsed_s);
        if (scaled >= @as(f64, @floatFromInt(backlog))) break :blk backlog;
        if (scaled <= 0.0) break :blk 0;
        break :blk @intFromFloat(scaled);
    };

    const finish_steps: usize = if (finish_remaining_ns) |rem_ns| blk: {
        if (rem_ns <= 0) break :blk backlog;
        const frames_left_i128 = @max(@as(i128, 1), @divFloor(rem_ns, reveal_frame_ns));
        const frames_left_u128: u128 = @intCast(frames_left_i128);
        break :blk @intCast(@min(backlog_u128, @divCeil(backlog_u128, frames_left_u128)));
    } else 0;

    return .{
        .steps = std.math.clamp(@max(@max(rate_steps, window_steps), @max(finish_steps, age_steps)), @as(usize, 1), backlog),
        .rate_steps = rate_steps,
        .window_steps = window_steps,
        .finish_steps = finish_steps,
    };
}

fn revealSteps(
    backlog: usize,
    rate_steps_per_s: f64,
    tick_elapsed_ns: i128,
    finish_remaining_ns: ?i128,
) usize {
    return revealPlan(backlog, rate_steps_per_s, tick_elapsed_ns, finish_remaining_ns, 0).steps;
}

pub const SgrState = struct {
    /// The tracked foreground open. Theme-owned slots re-resolve at restore
    /// time so live theme flips retint mid-stream; anything else restores
    /// with its original bytes.
    const Foreground = enum { none, inline_code, link, other };

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    fg: Foreground = .none,
    fg_buf: [shared_theme.max_restorable_open_bytes]u8 = undefined,
    fg_len: u8 = 0,

    pub fn isActive(self: SgrState) bool {
        return self.bold or self.dim or self.italic or self.underline or self.strike or self.fg != .none;
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
        // markdown renderer emits; multi-parameter SGRs (e.g. "1;38;5;245")
        // count for every attribute and the color they carry.
        if (std.mem.eql(u8, body, "1")) self.bold = true else if (std.mem.eql(u8, body, "2")) self.dim = true else if (std.mem.eql(u8, body, "3")) self.italic = true else if (std.mem.eql(u8, body, "4")) self.underline = true else if (std.mem.eql(u8, body, "9")) self.strike = true else if (std.mem.eql(u8, body, "22")) {
            self.bold = false;
            self.dim = false;
        } else if (std.mem.eql(u8, body, "23")) self.italic = false else if (std.mem.eql(u8, body, "24")) self.underline = false else if (std.mem.eql(u8, body, "29")) self.strike = false else if (std.mem.eql(u8, body, "39")) {
            self.fg = .none;
        } else {
            // Multi-parameter SGRs (e.g. "1;38;5;245") apply each attribute
            // they carry; color-spec parameters are not attributes.
            if (std.mem.findScalar(u8, body, ';') != null) {
                var params = std.mem.splitScalar(u8, body, ';');
                while (params.next()) |param| {
                    if (std.mem.eql(u8, param, "38") or std.mem.eql(u8, param, "48")) {
                        // Skip the color space and value parameters so their
                        // digits are not mistaken for attributes.
                        if (params.next()) |space| {
                            const skip: usize = if (std.mem.eql(u8, space, "2")) 3 else 1;
                            for (0..skip) |_| _ = params.next();
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, param, "1")) self.bold = true else if (std.mem.eql(u8, param, "2")) self.dim = true else if (std.mem.eql(u8, param, "3")) self.italic = true else if (std.mem.eql(u8, param, "4")) self.underline = true else if (std.mem.eql(u8, param, "9")) self.strike = true;
                }
            }
            if (hasForegroundColor(body)) {
                if (std.mem.eql(u8, seq, shared_theme.current().inline_code_open)) {
                    self.fg = .inline_code;
                } else if (std.mem.eql(u8, seq, shared_theme.current().link_style)) {
                    self.fg = .link;
                } else if (seq.len <= self.fg_buf.len) {
                    @memcpy(self.fg_buf[0..seq.len], seq);
                    self.fg_len = @intCast(seq.len);
                    self.fg = .other;
                }
            }
        }
    }

    /// True when the SGR body sets a foreground color (a 38-prefixed extended
    /// color or a basic 30-37/90-97), including combined forms like 1;38;5;245.
    fn hasForegroundColor(body: []const u8) bool {
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |param| {
            if (std.mem.eql(u8, param, "38")) return true;
            const value = std.fmt.parseInt(u8, param, 10) catch continue;
            if ((value >= 30 and value <= 37) or (value >= 90 and value <= 97)) return true;
        }
        return false;
    }

    /// Serialize open codes for the currently-active attributes into `buf`.
    /// Returns the number of bytes written. The caller sizes `buf` for five
    /// 4-byte attribute opens plus the active foreground open (bounded at 24
    /// bytes); an oversized open is truncated by the bounds check, degrading
    /// restore to pre-fix behavior rather than corrupting the frame.
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
        switch (self.fg) {
            .none => {},
            .inline_code => append(buf, &n, shared_theme.current().inline_code_open),
            .link => append(buf, &n, shared_theme.current().link_style),
            .other => append(buf, &n, self.fg_buf[0..self.fg_len]),
        }
        return n;
    }
};

pub const AssistantPacer = struct {
    pending: std.ArrayList(u8) = .empty,
    deferred_presentation: ?DeferredPresentation = null,
    deferred_started_ns: ?i128 = null,
    /// Calls whose Ctrl+O lines wait for the text before them, which is still
    /// pending. Owned; written once that text is shown, before a deferred
    /// finish.
    held_calls: std.ArrayList(types.ModelCallRecord) = .empty,
    /// Tracks which SGR attributes the terminal should have active at the
    /// start of the next emit. Other frame-work (footer, body renders)
    /// between ticks can emit their own `\x1b[0m`, so state is restored
    /// by prefixing each emit with `\x1b[0m` + the active opens.
    sgr: SgrState = .{},
    /// Bytes ever enqueued into `pending`, and bytes that have left it. Always
    /// `pending.len == enqueued_bytes - released_bytes`.
    enqueued_bytes: u64 = 0,
    released_bytes: u64 = 0,
    tail_slots: std.ArrayList(TailSlot) = .empty,
    last_reveal_ns: ?i128 = null,
    last_tick_ns: ?i128 = null,
    rate_samples: std.ArrayList(RateSample) = .empty,
    arrived_tail_steps: usize = 0,
    prev_word_backlog: usize = 0,

    pub fn deinit(self: *AssistantPacer, alloc: Allocator) void {
        self.pending.deinit(alloc);
        if (self.tail_slots.items.len > 0) {
            const last = self.tail_slots.items[self.tail_slots.items.len - 1];
            debug_trace.logf(
                "pacer",
                "tail slot dropped kind=tail_slot size={d} reason=deinit tail_id={d}",
                .{ self.tail_slots.items.len, last.id },
            );
        }
        self.tail_slots.deinit(alloc);
        self.rate_samples.deinit(alloc);
        self.dropHeldModelCalls(alloc, "deinit");
        self.held_calls.deinit(alloc);
        if (self.deferred_presentation != null) {
            debug_trace.logf(
                "pacer",
                "deferred presentation dropped kind=deferred_presentation size=1 reason=deinit",
                .{},
            );
            self.deferred_presentation = null;
        }
        self.deferred_started_ns = null;
    }

    /// A tail waits for its bytes to leave `pending`; a hidden agent with one must still be visited.
    pub fn hasTail(self: *const AssistantPacer) bool {
        return self.tail_slots.items.len > 0;
    }

    pub fn hasPendingText(self: *const AssistantPacer) bool {
        return self.pending.items.len > 0;
    }

    pub fn hasPending(self: *const AssistantPacer) bool {
        return self.pending.items.len > 0 or self.tail_slots.items.len > 0 or self.deferred_presentation != null or self.held_calls.items.len > 0;
    }

    /// Holds a call's Ctrl+O line while the text before it is still pending,
    /// so writing the line never shows that text early. Returns false when
    /// nothing is pending and the caller writes the line now.
    pub fn holdModelCall(self: *AssistantPacer, alloc: Allocator, record: types.ModelCallRecord) !bool {
        if (self.pending.items.len == 0 and self.tail_slots.items.len == 0) return false;
        const owned = try types.dupeModelCallRecord(alloc, record);
        self.held_calls.append(alloc, owned) catch |err| {
            types.freeModelCallRecordStrings(alloc, owned);
            return err;
        };
        return true;
    }

    pub fn hasCompletedAssistantPresentationTail(self: *const AssistantPacer) bool {
        const deferred = self.deferred_presentation orelse return false;
        return deferred.terminal_outcome != null and
            deferred.terminal_outcome.? == .completed and
            deferred.summary != null and
            deferred.is_assistant;
    }

    pub fn completedAssistantPresentationTokenProgress(self: *const AssistantPacer) ?types.TurnTokenProgress {
        if (!self.hasCompletedAssistantPresentationTail()) return null;
        const deferred = self.deferred_presentation.?;
        return deferred.token_progress orelse deferred.summary.?.token_progress;
    }

    pub fn completedAssistantPresentationStartedMs(self: *const AssistantPacer) ?i64 {
        if (!self.hasCompletedAssistantPresentationTail()) return null;
        return self.deferred_presentation.?.turn_started_ms;
    }

    pub fn attachDeferredStreamMetrics(
        self: *AssistantPacer,
        turn_started_ms: i64,
        token_progress: types.TurnTokenProgress,
    ) void {
        const deferred = &(self.deferred_presentation orelse return);
        if (deferred.turn_started_ms == null and turn_started_ms > 0) {
            deferred.turn_started_ms = turn_started_ms;
        }
        if (deferred.token_progress == null) {
            deferred.token_progress = token_progress;
        }
    }

    pub fn enqueue(self: *AssistantPacer, alloc: Allocator, text: []const u8) !void {
        if (text.len == 0) return;
        try self.pending.appendSlice(alloc, text);
        self.enqueued_bytes += text.len;
    }

    /// The tail is due once every byte enqueued before this call has left
    /// `pending`. Appends to the bounded tail FIFO, dropping the oldest on overflow.
    fn setTail(self: *AssistantPacer, alloc: Allocator, tail_id: u64) !void {
        try self.appendTailSlot(alloc, tail_id, self.last_tick_ns);
    }

    pub fn setTailAt(self: *AssistantPacer, alloc: Allocator, tail_id: u64, arrived_ns: i128) !void {
        try self.appendTailSlot(alloc, tail_id, arrived_ns);
    }

    fn appendTailSlot(self: *AssistantPacer, alloc: Allocator, tail_id: u64, arrived_ns: ?i128) !void {
        if (self.tail_slots.items.len >= max_tail_slots) {
            const oldest = self.tail_slots.orderedRemove(0);
            debug_trace.logf(
                "pacer",
                "tail slot dropped kind=tail_slot size=1 reason=queue_full tail_id={d} cap={d}",
                .{ oldest.id, max_tail_slots },
            );
        }
        try self.tail_slots.append(alloc, .{
            .id = tail_id,
            .released_target = self.enqueued_bytes,
            .arrived_ns = arrived_ns,
        });
        self.arrived_tail_steps += 1;
        debug_trace.logf("pacer", "slot_queued backlog={d}", .{self.tail_slots.items.len});
    }

    fn stampUnstampedTailSlots(self: *AssistantPacer, now_ns: i128) void {
        for (self.tail_slots.items) |*slot| {
            if (slot.arrived_ns == null) slot.arrived_ns = now_ns;
        }
    }

    fn expiredTailSlotCount(self: *const AssistantPacer, now_ns: i128) usize {
        var count: usize = 0;
        for (self.tail_slots.items) |slot| {
            const arrived_ns = slot.arrived_ns orelse break;
            if (now_ns - arrived_ns >= reveal_drain_window_ns) {
                count += 1;
            } else {
                break;
            }
        }
        return count;
    }

    pub fn dropTail(self: *AssistantPacer) void {
        if (self.tail_slots.items.len == 0) return;
        const last = self.tail_slots.items[self.tail_slots.items.len - 1];
        debug_trace.logf(
            "pacer",
            "tail slot dropped kind=tail_slot size={d} reason=drop_tail tail_id={d}",
            .{ self.tail_slots.items.len, last.id },
        );
        self.tail_slots.clearRetainingCapacity();
    }

    fn tailAt(self: *const AssistantPacer, index: usize) TailSlot {
        return self.tail_slots.items[index];
    }

    fn popOldestTails(self: *AssistantPacer, count: usize) void {
        const pop_count = @min(count, self.tail_slots.items.len);
        const remaining = self.tail_slots.items.len - pop_count;
        if (remaining > 0) {
            @memmove(self.tail_slots.items[0..remaining], self.tail_slots.items[pop_count..]);
        }
        self.tail_slots.items.len = remaining;
    }

    pub fn pause(_: *AssistantPacer, _: i128) void {}

    /// Rewrites the theme colors of the text not shown yet from `from` to
    /// `to`, as the transcript's retint does for the text already shown.
    pub fn retintForTheme(self: *AssistantPacer, alloc: Allocator, from: shared_theme.Theme, to: shared_theme.Theme) !void {
        var token_buf: [theme_retint.max_tokens]theme_retint.Token = undefined;
        const tokens = theme_retint.tokens(from, to, &token_buf);
        if (tokens.len == 0) return;
        if (try theme_retint.rewrite(alloc, self.pending.items, tokens)) |replacement| {
            const old_len = self.pending.items.len;
            self.pending.deinit(alloc);
            self.pending = .fromOwnedSlice(replacement);
            if (replacement.len != old_len) self.retargetTailToPending();
        }

        // Inline code and link opens re-emit from the active theme at restore
        // time; another theme color restores with its saved bytes.
        if (self.sgr.fg == .other) {
            if (theme_retint.mapped(self.sgr.fg_buf[0..self.sgr.fg_len], tokens)) |next| {
                if (next.len <= self.sgr.fg_buf.len) {
                    @memcpy(self.sgr.fg_buf[0..next.len], next);
                    self.sgr.fg_len = @intCast(next.len);
                } else {
                    debug_trace.logf("pacer", "theme_retint_dropped_restore_color bytes={d} reason=too_long", .{next.len});
                    self.sgr.fg = .none;
                }
            }
        }
    }

    pub fn deferFinish(self: *AssistantPacer, presentation: DeferredPresentation) bool {
        if (self.pending.items.len == 0 and self.tail_slots.items.len == 0) return false;
        if (self.deferred_presentation != null) {
            debug_trace.logf(
                "pacer",
                "deferred presentation dropped kind=deferred_presentation size=1 reason=superseded",
                .{},
            );
        }
        self.deferred_presentation = presentation;
        self.deferred_started_ns = null;
        debug_trace.logf("pacer", "finish_deferred backlog={d}", .{self.tail_slots.items.len});
        return true;
    }

    fn resetRevealRate(self: *AssistantPacer) void {
        self.last_reveal_ns = null;
        self.last_tick_ns = null;
        self.rate_samples.clearRetainingCapacity();
        self.arrived_tail_steps = 0;
        self.prev_word_backlog = 0;
    }

    fn pruneRateSamples(self: *AssistantPacer, now_ns: i128) void {
        const cutoff_ns = now_ns - reveal_rate_window_ns;
        var expired: usize = 0;
        for (self.rate_samples.items) |sample| {
            if (sample.at_ns > cutoff_ns) break;
            expired += 1;
        }
        if (expired == 0) return;
        const remaining = self.rate_samples.items.len - expired;
        if (remaining > 0) {
            @memmove(self.rate_samples.items[0..remaining], self.rate_samples.items[expired..]);
        }
        self.rate_samples.items.len = remaining;
    }

    fn recordRateSample(self: *AssistantPacer, alloc: Allocator, now_ns: i128, arrived: usize) !void {
        self.pruneRateSamples(now_ns);
        if (arrived == 0) return;
        if (self.rate_samples.items.len >= max_rate_samples) {
            _ = self.rate_samples.orderedRemove(0);
        }
        try self.rate_samples.append(alloc, .{ .at_ns = now_ns, .arrived = arrived });
    }

    fn currentWindowRate(self: *const AssistantPacer, now_ns: i128) f64 {
        return windowRate(self.rate_samples.items, now_ns);
    }

    /// Drops text not yet shown, as when the answer it belongs to restarts.
    /// A deferred finish stays.
    pub fn discardPendingText(self: *AssistantPacer) void {
        self.clearPending();
        self.dropTailWithText("discard_pending_text");
        self.resetRevealRate();
        self.sgr = .{};
    }

    pub fn clear(self: *AssistantPacer, alloc: Allocator) void {
        self.clearPending();
        self.dropTailWithText("clear");
        self.dropHeldModelCalls(alloc, "clear");
        if (self.deferred_presentation != null) {
            debug_trace.logf(
                "pacer",
                "deferred presentation dropped kind=deferred_presentation size=1 reason=clear",
                .{},
            );
            self.deferred_presentation = null;
        }
        self.deferred_started_ns = null;
        self.resetRevealRate();
        self.sgr = .{};
    }

    pub fn discardDeferredPresentationForVisualEpoch(
        self: *AssistantPacer,
        alloc: Allocator,
    ) void {
        if (self.deferred_presentation == null) return;
        debug_trace.logf(
            "pacer",
            "deferred presentation dropped kind=deferred_presentation size=1 reason=visual_epoch",
            .{},
        );
        self.deferred_presentation = null;
        self.clearPending();
        self.dropTailWithText("visual_epoch");
        self.dropHeldModelCalls(alloc, "visual_epoch");
        self.deferred_started_ns = null;
        self.resetRevealRate();
        self.sgr = .{};
    }

    pub fn tick(self: *AssistantPacer, alloc: Allocator, now_ns: i128, cb: TickCallbacks) !void {
        const raw_tick_elapsed_ns: i128 = if (self.last_tick_ns) |prev| now_ns - prev else reveal_frame_ns;
        const tick_elapsed_ns: i128 = std.math.clamp(raw_tick_elapsed_ns, reveal_frame_ns, reveal_max_tick_elapsed_ns);
        defer self.last_tick_ns = now_ns;

        self.stampUnstampedTailSlots(now_ns);
        const tail_count = self.tail_slots.items.len;
        const emittable_len_at_entry = if (tail_count == 0 and self.pending.items.len > 0)
            self.emittablePrefixLen()
        else
            0;
        const word_backlog_at_entry = if (tail_count == 0 and emittable_len_at_entry > 0)
            countPendingWords(self.pending.items[0..emittable_len_at_entry])
        else
            0;

        const arrived: usize = if (tail_count > 0 or self.arrived_tail_steps > 0) blk: {
            const count = self.arrived_tail_steps;
            self.arrived_tail_steps = 0;
            break :blk count;
        } else if (self.pending.items.len > 0)
            word_backlog_at_entry -| self.prev_word_backlog
        else
            0;

        const rate_for_reveal = self.currentWindowRate(now_ns);
        try self.recordRateSample(alloc, now_ns, arrived);

        if (self.pending.items.len == 0 and tail_count == 0) {
            self.prev_word_backlog = 0;
            self.writeHeldModelCalls(alloc, cb);
            self.fireDeferredFinish(now_ns, cb);
            return;
        }

        if (self.deferred_presentation != null and self.deferred_started_ns == null) {
            self.deferred_started_ns = now_ns;
        }

        if (tail_count == 0 and emittable_len_at_entry == 0) {
            self.prev_word_backlog = 0;
            if (self.deferred_presentation != null and self.pending.items.len > 0) {
                try self.neutralizeIncompleteTail(cb);
                self.writeHeldModelCalls(alloc, cb);
                self.fireDeferredFinish(now_ns, cb);
            }
            return;
        }

        const reveal_elapsed_ns: i128 = if (self.last_reveal_ns) |prev| now_ns - prev else reveal_frame_ns;
        if (reveal_elapsed_ns < reveal_frame_ns) {
            if (tail_count == 0) self.prev_word_backlog = word_backlog_at_entry;
            return;
        }

        const finish_remaining_ns: ?i128 = if (self.deferred_presentation != null)
            (self.deferred_started_ns.? + reveal_finish_window_ns) - now_ns
        else
            null;
        if (tail_count > 0) {
            const age_steps = self.expiredTailSlotCount(now_ns);
            const plan = revealPlan(tail_count, rate_for_reveal, tick_elapsed_ns, finish_remaining_ns, age_steps);
            const k = @min(tail_count, plan.steps);
            if (k == 0) return;

            const target_slot = self.tailAt(k - 1);
            const wanted: usize = if (target_slot.released_target > self.released_bytes)
                @min(self.pending.items.len, @as(usize, @intCast(target_slot.released_target - self.released_bytes)))
            else
                0;
            var emit_len = emittablePrefixLenInSlice(self.pending.items[0..wanted]);
            if (emit_len == 0 and wanted > 0) {
                // A multi-byte UTF-8 or ANSI sequence can straddle `released_target` when
                // bytes arrive across `setTail`; emit that single unit once complete so tick does not stall.
                emit_len = firstCompleteUnitLen(self.pending.items);
            }
            if (emit_len > 0) {
                try self.emitLen(cb, emit_len);
            }
            if (self.deferred_presentation != null and self.pending.items.len > 0 and self.emittablePrefixLen() == 0) {
                try self.neutralizeIncompleteTail(cb);
            }

            var due_count: usize = 0;
            while (due_count < k and self.tailAt(due_count).released_target <= self.released_bytes) : (due_count += 1) {}
            if (emit_len > 0 or due_count > 0) {
                self.last_reveal_ns = now_ns;
                self.prev_word_backlog = 0;
            }
            if (due_count > 0) {
                const due_slot = self.tailAt(due_count - 1);
                self.popOldestTails(due_count);
                try reportDueTailSlot(due_slot, cb);
            }
            if (emit_len > 0 or due_count > 0) {
                debug_trace.logf(
                    "pacer",
                    "reveal k={d} backlog={d} rate_steps={d} window_steps={d} finish_steps={d} finishing={d}",
                    .{ k, tail_count, plan.rate_steps, plan.window_steps, plan.finish_steps, @intFromBool(self.deferred_presentation != null) },
                );
            }
        } else {
            const plan = revealPlan(word_backlog_at_entry, rate_for_reveal, tick_elapsed_ns, finish_remaining_ns, 0);
            const k = @min(word_backlog_at_entry, plan.steps);
            if (k == 0) {
                self.prev_word_backlog = word_backlog_at_entry;
                return;
            }

            const emit_len = prefixBytesForWords(self.pending.items[0..emittable_len_at_entry], k);
            if (emit_len > 0) {
                self.last_reveal_ns = now_ns;
                self.prev_word_backlog = word_backlog_at_entry - k;
                try self.emitLen(cb, emit_len);
                debug_trace.logf(
                    "pacer",
                    "reveal k={d} backlog={d} rate_steps={d} window_steps={d} finish_steps={d} finishing={d}",
                    .{ k, word_backlog_at_entry, plan.rate_steps, plan.window_steps, plan.finish_steps, @intFromBool(self.deferred_presentation != null) },
                );
            } else {
                self.prev_word_backlog = word_backlog_at_entry;
            }
            if (self.deferred_presentation != null and self.pending.items.len > 0 and self.emittablePrefixLen() == 0) {
                try self.neutralizeIncompleteTail(cb);
            }
        }

        if (self.pending.items.len == 0 and self.tail_slots.items.len == 0) {
            self.writeHeldModelCalls(alloc, cb);
            self.fireDeferredFinish(now_ns, cb);
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
        if (self.tail_slots.items.len > 0) {
            const count = self.tail_slots.items.len;
            const last_slot = self.tail_slots.items[count - 1];
            self.tail_slots.clearRetainingCapacity();
            if (last_slot.released_target <= self.released_bytes) {
                try reportDueTailSlot(last_slot, cb);
            } else {
                debug_trace.logf(
                    "pacer",
                    "tail slot dropped kind=tail_slot size={d} reason=boundary_unreached tail_id={d}",
                    .{ count, last_slot.id },
                );
            }
        }
        self.writeHeldModelCalls(alloc, cb);
        self.fireDeferredFinish(now_ns, cb);
        self.resetRevealRate();
    }

    fn reportDueTailSlot(tail: TailSlot, cb: TickCallbacks) !void {
        const report = cb.tail_due_fn orelse {
            debug_trace.logf("pacer", "tail slot dropped kind=tail_slot size=1 reason=no_reporter tail_id={d}", .{tail.id});
            return;
        };
        try report(cb.emit_ctx, tail.id);
    }

    /// A rewrite that changes the pending length moves the tail's boundary by
    /// an amount the counts cannot give, so the tail waits for all pending text.
    fn retargetTailToPending(self: *AssistantPacer) void {
        self.enqueued_bytes = self.released_bytes + self.pending.items.len;
        for (self.tail_slots.items) |*slot| {
            slot.released_target = self.enqueued_bytes;
        }
    }

    /// Writes the held call lines, whose text is now shown. A line that
    /// can't be written is traced and dropped; the turn saved it already.
    fn writeHeldModelCalls(self: *AssistantPacer, alloc: Allocator, cb: TickCallbacks) void {
        if (self.held_calls.items.len == 0) return;
        std.debug.assert(self.pending.items.len == 0 and self.tail_slots.items.len == 0);
        var calls = self.held_calls;
        self.held_calls = .empty;
        defer calls.deinit(alloc);
        for (calls.items) |record| {
            defer types.freeModelCallRecordStrings(alloc, record);
            const write = cb.model_call_fn orelse {
                debug_trace.logf("ui_activity", "model call line dropped reason=no_writer dropped=live_call_record", .{});
                continue;
            };
            write(cb.emit_ctx, record) catch |err| {
                debug_trace.logf("ui_activity", "model call line dropped err={s} dropped=live_call_record", .{@errorName(err)});
            };
        }
    }

    fn dropHeldModelCalls(self: *AssistantPacer, alloc: Allocator, reason: []const u8) void {
        if (self.held_calls.items.len == 0) return;
        debug_trace.logf("ui_activity", "model call lines dropped reason={s} count={d} dropped=live_call_record", .{ reason, self.held_calls.items.len });
        for (self.held_calls.items) |record| types.freeModelCallRecordStrings(alloc, record);
        self.held_calls.clearRetainingCapacity();
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

        self.clearPending();
        self.sgr = .{};
    }

    fn fireDeferredFinish(self: *AssistantPacer, now_ns: i128, cb: TickCallbacks) void {
        if (self.deferred_presentation) |presentation| {
            const started_ns = self.deferred_started_ns;
            self.deferred_presentation = null;
            self.deferred_started_ns = null;
            self.resetRevealRate();

            var callback_presentation = presentation;
            if (callback_presentation.summary) |*summary| {
                const started = started_ns orelse now_ns;
                if (now_ns > started) {
                    summary.turn_duration_ms += @intCast(@divFloor(now_ns - started, std.time.ns_per_ms));
                }
            }
            debug_trace.logf("pacer", "finish_fired pending={d} slots={d}", .{ self.pending.items.len, self.tail_slots.items.len });
            const result = cb.finish_fn(cb.finish_ctx, callback_presentation) catch |err| {
                debug_trace.logf(
                    "pacer",
                    "deferred finish presentation failed kind=turn_summary size=1 reason={s}",
                    .{@errorName(err)},
                );
                return;
            };
            switch (result) {
                .committed => {},
                .presentation_failed => |err| debug_trace.logf(
                    "pacer",
                    "deferred finish presentation failed kind=turn_summary size=1 reason={s}",
                    .{@errorName(err)},
                ),
            }
        }
    }

    fn emitCompletePrefix(self: *AssistantPacer, cb: TickCallbacks) !void {
        const i = self.emittablePrefixLen();
        if (i == 0) return;
        try self.emitLen(cb, i);
    }

    fn emitLen(self: *AssistantPacer, cb: TickCallbacks, len: usize) !void {
        if (len == 0) return;

        // Restore tracked SGR state because other renderers may reset it between ticks.
        if (self.sgr.isActive()) {
            var prefix_buf: [96]u8 = undefined;
            const reset = "\x1b[0m";
            @memcpy(prefix_buf[0..reset.len], reset);
            const opens_len = self.sgr.writeOpens(prefix_buf[reset.len..]);
            try cb.emit_fn(cb.emit_ctx, prefix_buf[0 .. reset.len + opens_len]);
        }

        try cb.emit_fn(cb.emit_ctx, self.pending.items[0..len]);
        self.updateSgrFromEmitted(self.pending.items[0..len]);
        self.consume(len);
    }

    fn emittablePrefixLen(self: *const AssistantPacer) usize {
        return emittablePrefixLenInSlice(self.pending.items);
    }

    fn emittablePrefixLenInSlice(bytes: []const u8) usize {
        var i: usize = 0;
        while (i < bytes.len) {
            const first = bytes[i];
            if (first == 0x1b) {
                // Keep ANSI sequences atomic and hold incomplete tails for a later tick.
                const end = display_width.ansiSequenceEnd(bytes, i);
                if (end > i) {
                    if (!ansiSequenceComplete(bytes, i, end)) break;
                    i = end;
                    continue;
                }
            }
            const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
            if (i + len > bytes.len) break;
            i += len;
        }
        return i;
    }

    fn firstCompleteUnitLen(bytes: []const u8) usize {
        if (bytes.len == 0) return 0;
        if (bytes[0] == 0x1b) {
            const end = display_width.ansiSequenceEnd(bytes, 0);
            if (end > 0 and ansiSequenceComplete(bytes, 0, end)) return end;
            return 0;
        }
        const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
        return if (len <= bytes.len) len else 0;
    }

    fn countPendingWords(emittable: []const u8) usize {
        var count: usize = 0;
        var pos: usize = 0;
        while (pos < emittable.len) {
            pos = display_width.nextWordPieceEnd(emittable, pos, true);
            count += 1;
        }
        return count;
    }

    fn prefixBytesForWords(emittable: []const u8, word_count: usize) usize {
        var pos: usize = 0;
        var steps: usize = 0;
        while (steps < word_count and pos < emittable.len) : (steps += 1) {
            pos = display_width.nextWordPieceEnd(emittable, pos, true);
        }
        return pos;
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
        // ESC ( B is whole at its final byte. One that a byte cut short,
        // with more bytes after it, cannot grow.
        if (display_width.isEscapeIntermediate(kind)) {
            return end < bytes.len or display_width.isEscapeFinal(bytes[end - 1]);
        }
        return end == start + 2;
    }

    fn clearPending(self: *AssistantPacer) void {
        self.released_bytes += self.pending.items.len;
        self.pending.clearRetainingCapacity();
    }

    /// A tail shows the text before it, so it goes with that text.
    fn dropTailWithText(self: *AssistantPacer, reason: []const u8) void {
        if (self.tail_slots.items.len == 0) return;
        const last = self.tail_slots.items[self.tail_slots.items.len - 1];
        debug_trace.logf(
            "pacer",
            "tail slot dropped kind=tail_slot size={d} reason={s} tail_id={d}",
            .{ self.tail_slots.items.len, reason, last.id },
        );
        self.tail_slots.clearRetainingCapacity();
    }

    fn consume(self: *AssistantPacer, byte_count: usize) void {
        self.released_bytes += byte_count;
        const remaining = self.pending.items.len - byte_count;
        if (remaining > 0) {
            @memmove(self.pending.items[0..remaining], self.pending.items[byte_count..]);
        }
        self.pending.items.len = remaining;
    }
};

const TestCapture = struct {
    emitted: std.ArrayList(u8) = .empty,
    emit_chunks: std.ArrayList([]u8) = .empty,
    finish_count: usize = 0,
    finish_summary: ?types.TurnSummary = null,
    /// How much text was out when each held call line was written.
    call_emitted_lens: [4]usize = undefined,
    call_count: usize = 0,
    calls_at_finish: usize = 0,
    tail_ids: [16]u64 = undefined,
    tail_count: usize = 0,

    fn emit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        try self.emitted.appendSlice(std.testing.allocator, text);
        const owned = try std.testing.allocator.dupe(u8, text);
        errdefer std.testing.allocator.free(owned);
        try self.emit_chunks.append(std.testing.allocator, owned);
    }

    fn finish(ctx: *anyopaque, presentation: DeferredPresentation) anyerror!FinishResult {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.finish_count += 1;
        self.finish_summary = presentation.summary;
        self.calls_at_finish = self.call_count;
        return .committed;
    }

    fn modelCall(ctx: *anyopaque, record: types.ModelCallRecord) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqualStrings("gen_held", record.generation_id.?);
        self.call_emitted_lens[self.call_count] = self.emitted.items.len;
        self.call_count += 1;
    }

    fn tailDue(ctx: *anyopaque, tail_id: u64) anyerror!void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.tail_ids[self.tail_count] = tail_id;
        self.tail_count += 1;
    }

    fn callbacks(self: *TestCapture) TickCallbacks {
        return .{
            .emit_ctx = self,
            .emit_fn = TestCapture.emit,
            .finish_ctx = self,
            .finish_fn = TestCapture.finish,
            .model_call_fn = TestCapture.modelCall,
            .tail_due_fn = TestCapture.tailDue,
        };
    }

    fn deinit(self: *TestCapture) void {
        self.emitted.deinit(std.testing.allocator);
        for (self.emit_chunks.items) |chunk| std.testing.allocator.free(chunk);
        self.emit_chunks.deinit(std.testing.allocator);
    }
};

fn drainPacerWithFrameTicks(
    pacer: *AssistantPacer,
    alloc: Allocator,
    start_ns: i128,
    cb: TickCallbacks,
) !i128 {
    var now_ns = start_ns;
    var ticks: usize = 0;
    while (pacer.hasPending()) : (ticks += 1) {
        try std.testing.expect(ticks < 10_000);
        try pacer.tick(alloc, now_ns, cb);
        now_ns += reveal_frame_ns;
    }
    return now_ns;
}

fn expectNoSplitEscapeInEmits(cap: *const TestCapture) !void {
    try std.testing.expect(cap.emit_chunks.items.len > 0);
    for (cap.emit_chunks.items) |chunk| {
        try std.testing.expectEqual(chunk.len, AssistantPacer.emittablePrefixLenInSlice(chunk));
    }
}

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

test "tick paces a queued rendered block to completion without splitting escapes" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    const paragraph = "A complete rendered paragraph.\n\n";
    try pacer.enqueue(alloc, paragraph);

    _ = try drainPacerWithFrameTicks(&pacer, alloc, 0, cap.callbacks());

    try std.testing.expectEqualStrings(paragraph, cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
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

    const deferred = pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn }));
    try std.testing.expect(!deferred);
    try std.testing.expect(pacer.deferred_presentation == null);
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

        fn finish(_: *anyopaque, _: DeferredPresentation) anyerror!FinishResult {
            return .committed;
        }
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

test "deferred presentation failure clears deferred_presentation, traces, and does not fail tick" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |return_error| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
        defer alloc.free(root);
        const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "pacer-fail.log" });
        defer alloc.free(trace_path);

        debug_trace.resetForTest();
        defer debug_trace.resetForTest();
        try debug_trace.configureForTestWithScopes(alloc, trace_path, "pacer");

        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = TestCapture{};
        defer cap.deinit();
        const Finish = struct {
            return_error: bool,
            calls: usize = 0,

            fn run(raw: *anyopaque, _: DeferredPresentation) !FinishResult {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.calls += 1;
                if (self.return_error) return error.InjectedPresentationCallbackError;
                return .{ .presentation_failed = error.InjectedPresentationFailure };
            }
        };
        var finish = Finish{ .return_error = return_error };
        var callbacks = cap.callbacks();
        callbacks.finish_ctx = &finish;
        callbacks.finish_fn = Finish.run;
        try pacer.enqueue(alloc, "tail");
        try std.testing.expect(pacer.deferFinish(.{ .is_assistant = true, .terminal_outcome = .completed }));

        try pacer.tick(alloc, 0, callbacks);
        try std.testing.expect(pacer.deferred_presentation == null);
        try std.testing.expect(!pacer.hasPending());
        try std.testing.expectEqual(@as(usize, 1), finish.calls);

        try pacer.tick(alloc, reveal_frame_ns, callbacks);
        try std.testing.expectEqual(@as(usize, 1), finish.calls);

        debug_trace.shutdown();
        var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
        defer file.close(std.testing.io);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(std.testing.io, &read_buf);
        const trace = try reader.interface.allocRemaining(alloc, .limited(64 * 1024));
        defer alloc.free(trace);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "deferred finish presentation failed"));
    }
}

test "finished presentation closes an incomplete text tail" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();
    try pacer.enqueue(alloc, "body \xe2\x82");
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expect(pacer.hasPending());
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn })));
    try pacer.tick(alloc, 1, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expect(!pacer.hasPending());
    try std.testing.expect(std.unicode.utf8ValidateSlice(cap.emitted.items));
    try pacer.tick(alloc, 2, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
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

    const deferred = pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn }));
    try std.testing.expect(deferred);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("hi", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expect(pacer.deferred_presentation == null);
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

    const deferred = pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn, .summary = summary }));
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

    try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
        .turn = turn,
        .summary = summary,
        .terminal_outcome = .completed,
    })));

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
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .completed,
        })));
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
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
            .turn = turn,
            .terminal_outcome = .completed,
        })));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .failed,
        })));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeCompactedTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .completed,
        })));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }

    {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        try pacer.enqueue(alloc, "tail");
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{
            .turn = turn,
            .summary = summary,
            .terminal_outcome = .interrupted,
        })));
        try std.testing.expect(!pacer.hasCompletedAssistantPresentationTail());
    }
}

const held_call: types.ModelCallRecord = .{
    .at_ms = 1_000,
    .elapsed_ms = 900,
    .provider = "gateway",
    .model = "openai/gpt-5.4",
    .generation_id = "gen_held",
};

test "a held call line waits for the text before it and lands before a deferred finish" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // With nothing pending the caller writes the line itself.
    try std.testing.expect(!try pacer.holdModelCall(alloc, held_call));
    try std.testing.expect(!pacer.hasPending());

    try pacer.enqueue(alloc, "reply\x1b[1");
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    try pacer.tick(alloc, 0, cap.callbacks());
    // The incomplete tail is still pending, so the line still waits.
    try std.testing.expectEqualStrings("reply", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 0), cap.call_count);
    try std.testing.expect(pacer.hasPending());

    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn })));
    try pacer.tick(alloc, 1, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.call_count);
    try std.testing.expectEqual(cap.emitted.items.len, cap.call_emitted_lens[0]);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expectEqual(@as(usize, 1), cap.calls_at_finish);
    try std.testing.expect(!pacer.hasPending());
}

test "a presentation boundary writes held call lines after the text they waited for" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "first");
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    try pacer.enqueue(alloc, " second");
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    try pacer.flushPresentationAtBoundary(alloc, 0, cap.callbacks());

    try std.testing.expectEqualStrings("first second", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 2), cap.call_count);
    try std.testing.expectEqual(@as(usize, 12), cap.call_emitted_lens[0]);
    try std.testing.expectEqual(@as(usize, 12), cap.call_emitted_lens[1]);
    try std.testing.expect(!pacer.hasPending());
}

test "clear drops a held call line with the text it waited for" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "text");
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    pacer.clear(alloc);
    try std.testing.expect(!pacer.hasPending());
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.call_count);
}

test "clear drops pending and deferred presentation" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);

    try pacer.enqueue(alloc, "lots of text");
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    _ = pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn }));

    try std.testing.expect(pacer.hasPending());
    pacer.clear(alloc);
    try std.testing.expect(!pacer.hasPending());
}

test "visual epoch discard drops deferred presentation, pending text, and tail slots" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    try pacer.enqueue(alloc, "stale presentation");
    try pacer.setTail(alloc, 1);
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    try std.testing.expect(pacer.deferFinish(.{ .is_assistant = true, .terminal_outcome = .completed }));

    pacer.discardDeferredPresentationForVisualEpoch(alloc);
    try std.testing.expect(!pacer.hasPending());
    try std.testing.expect(pacer.deferred_presentation == null);
    try std.testing.expect(!pacer.hasTail());
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

test "an escape with an intermediate byte emits whole, at once or when its final byte arrives" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "a\x1b(Bb");
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("a\x1b(Bb", cap.emitted.items);

    try pacer.enqueue(alloc, "c\x1b(");
    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqualStrings("a\x1b(Bbc", cap.emitted.items);
    try pacer.enqueue(alloc, "Bd");
    try pacer.tick(alloc, 2 * reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqualStrings("a\x1b(Bbc\x1b(Bd", cap.emitted.items);

    // A byte that ends no escape cuts it short, and nothing waits on it.
    try pacer.enqueue(alloc, "\x1b((\ne");
    _ = try drainPacerWithFrameTicks(&pacer, alloc, 3 * reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqualStrings("a\x1b(Bbc\x1b(Bd\x1b((\ne", cap.emitted.items);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
}

test "theme-supplied inline code color is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    const previous = shared_theme.current();
    defer shared_theme.activate(previous);
    var custom = shared_theme.fx_dark;
    custom.inline_code_open = "\x1b[38;2;130;210;206m";
    shared_theme.activate(custom);

    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;2;130;210;206mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[39m done");
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(std.mem.find(
        u8,
        cap.emitted.items,
        "code\x1b[0m\x1b[38;2;130;210;206m\x1b[39m done",
    ) != null);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
}

test "code style is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;255mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[39m done");
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "code\x1b[0m\x1b[38;5;255m\x1b[39m done") != null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[39m") != null);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
}

test "light code style is restored across rendered blocks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;235mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.enqueue(alloc, "\x1b[39m done");
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(std.mem.find(
        u8,
        cap.emitted.items,
        "code\x1b[0m\x1b[38;5;235m\x1b[39m done",
    ) != null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[39m") != null);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
}

test "theme change retints active code before the next block" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "\x1b[38;5;255mcode");
    try pacer.tick(alloc, 0, cap.callbacks());
    const emitted_before_theme_change = cap.emitted.items.len;

    // Production flips the active theme first; the pacer's restore re-resolves
    // theme-owned opens against it.
    const previous = shared_theme.current();
    defer shared_theme.activate(previous);
    shared_theme.activate(shared_theme.fx_light);
    try pacer.retintForTheme(alloc, shared_theme.fx_dark, shared_theme.fx_light);
    try pacer.enqueue(alloc, "\x1b[39m");
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    const after_theme_change = cap.emitted.items[emitted_before_theme_change..];
    try std.testing.expect(std.mem.find(u8, after_theme_change, "\x1b[0m\x1b[38;5;235m") != null);
    try std.testing.expect(std.mem.find(u8, after_theme_change, "\x1b[38;5;255m") == null);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);
}

test "theme change retints a queued inline code opener before it is emitted" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "x\x1b[38;5;235mcode\x1b[39m");
    try pacer.retintForTheme(alloc, shared_theme.fx_light, shared_theme.fx_dark);
    try pacer.tick(alloc, 0, cap.callbacks());

    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[38;5;255m") != null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[38;5;235m") == null);
}

test "theme change retints queued custom inline code and links to their own colors" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    var dark = shared_theme.fx_dark;
    dark.name = "probe-dark";
    dark.inline_code_open = "\x1b[38;2;136;192;208m";
    dark.link_style = "\x1b[38;2;129;161;193m";
    var light = shared_theme.fx_light;
    light.name = "probe-light";
    light.inline_code_open = "\x1b[38;2;23;108;116m";
    light.link_style = "\x1b[38;2;0;100;176m";

    try pacer.enqueue(alloc, "x\x1b[38;2;136;192;208mcode\x1b[39m \x1b[38;2;129;161;193mlink\x1b[39m");
    try pacer.retintForTheme(alloc, dark, light);
    try pacer.tick(alloc, 0, cap.callbacks());
    try pacer.tick(alloc, 100_000_000, cap.callbacks());

    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[38;2;23;108;116mcode") != null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "\x1b[38;2;0;100;176mlink") != null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "136;192;208") == null);
    try std.testing.expect(std.mem.find(u8, cap.emitted.items, "129;161;193") == null);
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
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(std.mem.find(
        u8,
        cap.emitted.items,
        "Heading\x1b[0m\x1b[4m\x1b[24m",
    ) != null);
    try std.testing.expect(!pacer.hasPending());
    try expectNoSplitEscapeInEmits(&cap);

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

test "link color is tracked and restored like the themed inline-code color" {
    const link_open = shared_theme.current().link_style;
    var sgr: SgrState = .{};
    sgr.apply("\x1b[4m");
    sgr.apply(link_open);
    try std.testing.expect(sgr.fg == .link);
    try std.testing.expect(sgr.isActive());

    var opens: [96]u8 = undefined;
    const opens_len = sgr.writeOpens(&opens);
    const serialized = opens[0..opens_len];
    try std.testing.expect(std.mem.find(u8, serialized, "\x1b[4m") != null);
    try std.testing.expect(std.mem.find(u8, serialized, link_open) != null);

    sgr.apply("\x1b[39m");
    try std.testing.expect(sgr.fg == .none);
    sgr.apply("\x1b[24m");
    try std.testing.expect(!sgr.isActive());
}

test "any foreground color restores after a row reset, not just known opens" {
    var sgr: SgrState = .{};
    sgr.apply("\x1b[38;5;204m");
    try std.testing.expect(sgr.fg == .other);

    var opens: [32]u8 = undefined;
    const opens_len = sgr.writeOpens(&opens);
    try std.testing.expectEqualStrings("\x1b[38;5;204m", opens[0..opens_len]);

    // Combined forms carry the color with the attribute.
    sgr.apply("\x1b[1;38;2;255;0;0m");
    try std.testing.expect(sgr.fg == .other);
    try std.testing.expect(sgr.bold);
    const combined_len = sgr.writeOpens(&opens);
    try std.testing.expectEqualStrings("\x1b[1m\x1b[1;38;2;255;0;0m", opens[0..combined_len]);

    sgr.apply("\x1b[39m");
    try std.testing.expect(sgr.fg == .none);
    try std.testing.expect(sgr.bold);
}

test "a tail is due only once the bytes enqueued before it have left" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // Ten bytes enqueued; the last two are an incomplete UTF-8 sequence, so
    // only eight leave on the first tick.
    try pacer.enqueue(alloc, "abcdefgh\xe2\x82");
    try pacer.setTail(alloc, 1);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);
    try std.testing.expectEqual(@as(usize, 2), pacer.pending.items.len);

    try pacer.enqueue(alloc, "\xac");
    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try expectNoSplitEscapeInEmits(&cap);
}

test "a tail set with nothing pending is due on the next tick" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.setTail(alloc, 5);
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 5), cap.tail_ids[0]);
}

test "dropTail cancels the tail" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "abc");
    try pacer.setTail(alloc, 1);
    pacer.dropTail();

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("abc", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);
}

test "tail FIFO reveal reaching a newer slot reports only the newest id and never reports older ones" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // Warm up arrival rate (>= 80/s) inside the 100ms window so a 2-slot burst reveals both in one tick.
    for (101..109) |warmup_id| {
        try pacer.enqueue(alloc, "w ");
        try pacer.setTail(alloc, warmup_id);
    }
    const next_ns = try drainPacerWithFrameTicks(&pacer, alloc, 0, cap.callbacks());
    cap.tail_count = 0;

    try pacer.enqueue(alloc, "abc");
    try pacer.setTail(alloc, 1);
    try pacer.enqueue(alloc, "def");
    try pacer.setTail(alloc, 2);
    try std.testing.expectEqual(@as(usize, 2), pacer.tail_slots.items.len);

    try pacer.tick(alloc, next_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 2), cap.tail_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), pacer.tail_slots.items.len);

    try pacer.tick(alloc, next_ns + reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expect(!pacer.hasPending());
}

test "bytes enqueued after a tail do not delay it" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "abc");
    try pacer.setTail(alloc, 1);
    try pacer.enqueue(alloc, "\xe2\x82");

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("abc", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), pacer.pending.items.len);
}

test "clear drops the tail with the text before it" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "abc");
    try pacer.setTail(alloc, 1);
    pacer.clear(alloc);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);
}

test "discardPendingText drops the tail with the text before it" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.enqueue(alloc, "abc");
    try pacer.setTail(alloc, 1);
    pacer.discardPendingText();

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);
}

test "a theme retint that changes the pending length makes the tail wait for all pending text" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    var light = shared_theme.fx_light;
    light.name = "tail-light";
    light.inline_code_open = "\x1b[38;5;1m";
    var dark = shared_theme.fx_dark;
    dark.name = "tail-dark";
    dark.inline_code_open = "\x1b[38;2;136;192;208m";

    // The last two bytes are an incomplete UTF-8 sequence that stays pending.
    try pacer.enqueue(alloc, "x\x1b[38;5;1mcode\xe2\x82");
    try pacer.setTail(alloc, 1);
    try pacer.retintForTheme(alloc, light, dark);

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);
    try std.testing.expectEqual(@as(usize, 2), pacer.pending.items.len);

    try pacer.enqueue(alloc, "\xac");
    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try expectNoSplitEscapeInEmits(&cap);
}

test "windowRate computes sliding-window arrival rate over reveal_rate_window_ns" {
    const samples = [_]RateSample{
        .{ .at_ns = 0, .arrived = 10 },
        .{ .at_ns = 50 * std.time.ns_per_ms, .arrived = 4 },
        .{ .at_ns = 100 * std.time.ns_per_ms, .arrived = 5 },
        .{ .at_ns = 150 * std.time.ns_per_ms, .arrived = 3 },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), windowRate(&.{}, 100 * std.time.ns_per_ms), 0.001);
    // At 100ms, cutoff is 0ms so t=0 is excluded; t=50ms and t=100ms (9 steps) are inside.
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), windowRate(&samples, 100 * std.time.ns_per_ms), 0.001);
    // At 150ms, t=50ms is excluded; t=100ms and t=150ms (8 steps) are inside.
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), windowRate(&samples, 150 * std.time.ns_per_ms), 0.001);
    // After 300ms idle gap, all samples are outside the window.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), windowRate(&samples, 450 * std.time.ns_per_ms), 0.001);
}

test "revealSteps computes backlog-proportional steps, rate-elapsed steps, and deadline finish steps" {
    try std.testing.expectEqual(@as(usize, 0), revealSteps(0, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 0), revealSteps(0, 100.0, reveal_frame_ns, 0));

    try std.testing.expectEqual(@as(usize, 1), revealSteps(1, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 1), revealSteps(6, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 4), revealSteps(20, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 160), revealSteps(1000, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 8), revealSteps(44, 0.0, reveal_frame_ns, null));
    try std.testing.expectEqual(@as(usize, 15), revealSteps(44, 0.0, 32 * std.time.ns_per_ms, null));
    try std.testing.expectEqual(@as(usize, 39), revealSteps(100, 1200.0, 32 * std.time.ns_per_ms, null));
    try std.testing.expectEqual(@as(usize, 100), revealSteps(100, 700.0, 100 * std.time.ns_per_ms, null));
    // Deadline finish: rem=68ms -> frames_left=4 -> ceil(100/4)=25; rem<=0 releases all.
    try std.testing.expectEqual(@as(usize, 25), revealSteps(100, 0.0, reveal_frame_ns, 68 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 100), revealSteps(100, 0.0, 32 * std.time.ns_per_ms, 0));
    try std.testing.expectEqual(@as(usize, 100), revealSteps(100, 0.0, 32 * std.time.ns_per_ms, -5 * std.time.ns_per_ms));
}

test "rate matching drains 24-step burst at 218/s and backlog 134 at rate 0" {
    // Burst of 24 steps with rate ~218/s drains in <= 7 ticks.
    {
        var backlog: usize = 24;
        var ticks: usize = 0;
        while (backlog > 0) : (ticks += 1) {
            const k = revealSteps(backlog, 218.0, reveal_frame_ns, null);
            try std.testing.expect(k >= 1);
            backlog -= k;
        }
        try std.testing.expect(ticks <= 7);
    }

    // Backlog 134 at rate 0: window step starts at ceil(134 * 16 / 100) = 22 and drains monotonically.
    {
        try std.testing.expectEqual(@as(usize, 22), revealSteps(134, 0.0, reveal_frame_ns, null));
        var backlog: usize = 134;
        var ticks: usize = 0;
        while (backlog > 0) : (ticks += 1) {
            const k = revealSteps(backlog, 0.0, reveal_frame_ns, null);
            try std.testing.expect(k >= 1);
            backlog -= k;
        }
        try std.testing.expectEqual(@as(usize, 0), backlog);
        try std.testing.expect(ticks > 0);
    }

    try std.testing.expectEqual(@as(usize, 0), revealSteps(0, 218.0, reveal_frame_ns, null));
}

test "hasPending is true with only tail slots queued" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);

    try std.testing.expect(!pacer.hasPending());
    try pacer.setTail(alloc, 1);
    try std.testing.expect(pacer.hasPending());
    pacer.dropTail();
    try std.testing.expect(!pacer.hasPending());
}

test "holdModelCall holds while only tail slots are queued and writes after they drain" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.setTail(alloc, 1);
    try pacer.setTail(alloc, 2);
    try std.testing.expect(try pacer.holdModelCall(alloc, held_call));
    try std.testing.expect(pacer.hasPending());

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(usize, 0), cap.call_count);
    try std.testing.expect(pacer.hasPending());

    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 2), cap.tail_count);
    try std.testing.expectEqual(@as(usize, 1), cap.call_count);
    try std.testing.expect(!pacer.hasPending());
}

test "deferred finish waits while only tail slots are queued and fires after they are revealed" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    try pacer.setTail(alloc, 1);
    try pacer.setTail(alloc, 2);
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn })));

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), cap.finish_count);
    try std.testing.expect(pacer.hasPending());

    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, 2), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 2), cap.tail_ids[1]);
    try std.testing.expectEqual(@as(usize, 1), cap.finish_count);
    try std.testing.expect(!pacer.hasPending());
}

test "tail FIFO paces multiple slots and reports only the k-th slot due" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    const k1 = revealSteps(7, 0.0, reveal_frame_ns, null);
    for (1..8) |step| {
        try pacer.enqueue(alloc, "w ");
        try pacer.setTail(alloc, step);
    }

    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(usize, k1 * 2), cap.emitted.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);
    try std.testing.expectEqual(@as(u64, k1), cap.tail_ids[0]);
    try std.testing.expectEqual(7 - k1, pacer.tail_slots.items.len);

    // Below frame threshold: releases nothing.
    try pacer.tick(alloc, reveal_frame_ns - 1, cap.callbacks());
    try std.testing.expectEqual(@as(usize, k1 * 2), cap.emitted.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.tail_count);

    // At frame threshold: releases k2 steps according to revealSteps(remaining, windowRate, frame).
    const k2 = revealSteps(pacer.tail_slots.items.len, pacer.currentWindowRate(reveal_frame_ns), reveal_frame_ns, null);
    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    try std.testing.expectEqual(@as(usize, (k1 + k2) * 2), cap.emitted.items.len);
    try std.testing.expectEqual(@as(usize, 2), cap.tail_count);
    try std.testing.expectEqual(@as(u64, k1 + k2), cap.tail_ids[1]);
}

test "tail FIFO overflow drops the oldest slot" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);

    for (1..max_tail_slots + 3) |id| {
        try pacer.setTail(alloc, id);
    }
    try std.testing.expectEqual(max_tail_slots, pacer.tail_slots.items.len);
    try std.testing.expectEqual(@as(u64, 3), pacer.tailAt(0).id);
    try std.testing.expectEqual(@as(u64, max_tail_slots + 2), pacer.tailAt(max_tail_slots - 1).id);
}

test "without tail slots, tick releases whole words at revealSteps pace" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    const words = [_][]const u8{ "one ", "two ", "three ", "four ", "five ", "six ", "seven " };
    for (words) |w| try pacer.enqueue(alloc, w);

    const k1 = revealSteps(words.len, 0.0, reveal_frame_ns, null);
    try pacer.tick(alloc, 0, cap.callbacks());
    var expected_len: usize = 0;
    for (words[0..k1]) |w| expected_len += w.len;
    try std.testing.expectEqual(expected_len, cap.emitted.items.len);
    try std.testing.expect(pacer.hasPending());

    const k2 = revealSteps(words.len - k1, pacer.currentWindowRate(reveal_frame_ns), reveal_frame_ns, null);
    try pacer.tick(alloc, reveal_frame_ns, cap.callbacks());
    for (words[k1 .. k1 + k2]) |w| expected_len += w.len;
    try std.testing.expectEqual(expected_len, cap.emitted.items.len);
}

const StepJumpCapture = struct {
    reveals: usize = 0,
    last_tail_id: u64 = 0,
    max_jump: u64 = 0,

    fn emit(_: *anyopaque, _: []const u8) anyerror!void {}

    fn finish(_: *anyopaque, _: DeferredPresentation) anyerror!FinishResult {
        return .committed;
    }

    fn tailDue(ctx: *anyopaque, tail_id: u64) anyerror!void {
        const self: *StepJumpCapture = @ptrCast(@alignCast(ctx));
        const jump = tail_id - self.last_tail_id;
        if (jump > self.max_jump) self.max_jump = jump;
        self.last_tail_id = tail_id;
        self.reveals += 1;
    }

    fn callbacks(self: *StepJumpCapture) TickCallbacks {
        return .{
            .emit_ctx = self,
            .emit_fn = StepJumpCapture.emit,
            .finish_ctx = self,
            .finish_fn = StepJumpCapture.finish,
            .tail_due_fn = StepJumpCapture.tailDue,
        };
    }
};

test "after 300ms idle gap, burst of 44 steps caps first reveal at 8 when rate has decayed" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = StepJumpCapture{};

    var next_id: u64 = 1;
    try pacer.setTail(alloc, next_id);
    next_id += 1;
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqual(@as(u64, 1), cap.last_tail_id);

    // Seed an active rate (> 30/s) so the 300ms idle gap exercises window expiry.
    var t_ms: i128 = 16;
    while (t_ms <= 64) : (t_ms += 16) {
        for (0..2) |_| {
            try pacer.setTail(alloc, next_id);
            next_id += 1;
        }
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expect(pacer.currentWindowRate(t_ms * std.time.ns_per_ms) > 30.0);

    // 300ms of idle 8ms ticks expire all samples from the 100ms window.
    const idle_end_ms = t_ms + 300;
    while (t_ms <= idle_end_ms) : (t_ms += 8) {
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expect(pacer.currentWindowRate((idle_end_ms + 8) * std.time.ns_per_ms) < 30.0);

    cap.max_jump = 0;
    const prev_reveals = cap.reveals;
    const base_id = cap.last_tail_id;
    for (0..44) |_| {
        try pacer.setTail(alloc, next_id);
        next_id += 1;
    }
    try pacer.tick(alloc, (idle_end_ms + 8) * std.time.ns_per_ms, cap.callbacks());
    const first_jump = cap.last_tail_id - base_id;
    try std.testing.expect(first_jump >= 1 and first_jump <= 8);
    try std.testing.expect(pacer.tail_slots.items.len > 0);

    var drain_ms = idle_end_ms + 8;
    while (pacer.tail_slots.items.len > 0) {
        drain_ms += 16;
        try pacer.tick(alloc, drain_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expectEqual(next_id - 1, cap.last_tail_id);
    try std.testing.expect(cap.reveals - prev_reveals > 1);
}

test "steady 85 steps/s keeps backlog bounded across 8ms, 16ms, and 32ms ticks" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        tick_ms: i128,
        total_ticks: usize,
        settle_after: usize,
        max_backlog: usize,
    }{
        .{ .tick_ms = 8, .total_ticks = 120, .settle_after = 25, .max_backlog = 2 },
        .{ .tick_ms = 16, .total_ticks = 80, .settle_after = 10, .max_backlog = 2 },
        .{ .tick_ms = 32, .total_ticks = 100, .settle_after = 10, .max_backlog = 4 },
    };
    for (cases) |case| {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = StepJumpCapture{};

        var next_id: u64 = 1;
        var accum: f64 = 0.0;
        const per_tick: f64 = 85.0 * (@as(f64, @floatFromInt(case.tick_ms)) / 1000.0);
        for (0..case.total_ticks) |idx| {
            accum += per_tick;
            const arrived: usize = @intFromFloat(@floor(accum));
            accum -= @floatFromInt(arrived);
            for (0..arrived) |_| {
                try pacer.setTail(alloc, next_id);
                next_id += 1;
            }
            try pacer.tick(alloc, @as(i128, @intCast(idx)) * case.tick_ms * std.time.ns_per_ms, cap.callbacks());
            if (idx >= case.settle_after) {
                try std.testing.expect(pacer.tail_slots.items.len <= case.max_backlog);
            }
        }
    }
}

test "steady 700 steps/s from nothing with 32ms ticks keeps backlog <= 60 and finishes within 130ms" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = StepJumpCapture{};

    var next_id: u64 = 1;
    var accum: f64 = 0.0;
    var t_ms: i128 = 0;
    for (0..20) |idx| {
        t_ms = @as(i128, @intCast(idx)) * 32;
        accum += 700.0 * 0.032;
        const arrived: usize = @intFromFloat(@floor(accum));
        accum -= @floatFromInt(arrived);
        for (0..arrived) |_| {
            try pacer.setTail(alloc, next_id);
            next_id += 1;
        }
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
        try std.testing.expect(pacer.tail_slots.items.len <= 60);
    }

    const last_arrival_ms = t_ms;
    const turn = try makeAssistantTurn(alloc);
    defer types.freeHistoryTurn(alloc, turn);
    if (pacer.tail_slots.items.len > 0) {
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn })));
    }
    while (pacer.tail_slots.items.len > 0) {
        t_ms += 32;
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expect(t_ms - last_arrival_ms <= 130);
    try std.testing.expectEqual(next_id - 1, cap.last_tail_id);
}

test "finish deferred with backlog 100 and 32ms ticks reveals all within 130ms" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |after_quiet| {
        var pacer = AssistantPacer{};
        defer pacer.deinit(alloc);
        var cap = StepJumpCapture{};

        var t_ms: i128 = 0;
        if (after_quiet) {
            while (t_ms <= 1000) : (t_ms += 32) {
                try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
            }
            try std.testing.expectApproxEqAbs(@as(f64, 0.0), pacer.currentWindowRate(t_ms * std.time.ns_per_ms), 0.001);
        }

        for (1..101) |id| {
            try pacer.setTail(alloc, id);
        }
        const turn = try makeAssistantTurn(alloc);
        defer types.freeHistoryTurn(alloc, turn);
        try std.testing.expect(pacer.deferFinish(DeferredPresentation.fromFinishedPrompt(.{ .turn = turn })));

        const start_ms = t_ms;
        while (pacer.hasPending()) {
            try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
            if (!pacer.hasPending()) break;
            t_ms += 32;
        }
        try std.testing.expect(t_ms - start_ms <= 130);
        try std.testing.expectEqual(@as(u64, 100), cap.last_tail_id);
    }
}

test "Gemini-like bursts (24 steps every 110ms, 8ms ticks) release <= 8 steps per reveal" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = StepJumpCapture{};

    var next_id: u64 = 1;
    var next_burst_ms: i128 = 0;
    var t_ms: i128 = 0;
    while (t_ms <= 2000) : (t_ms += 8) {
        while (next_burst_ms <= t_ms) : (next_burst_ms += 110) {
            for (0..24) |_| {
                try pacer.setTail(alloc, next_id);
                next_id += 1;
            }
        }
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expect(cap.reveals > 0);
    try std.testing.expect(cap.max_jump <= 8);
}

test "a 32ms tick interval releases twice the burst term of a 16ms tick at the same backlog and rate 0" {
    const alloc = std.testing.allocator;

    var pacer_16 = AssistantPacer{};
    defer pacer_16.deinit(alloc);
    var cap_16 = StepJumpCapture{};

    var pacer_32 = AssistantPacer{};
    defer pacer_32.deinit(alloc);
    var cap_32 = StepJumpCapture{};

    try pacer_16.setTail(alloc, 1);
    try pacer_32.setTail(alloc, 1);
    try pacer_16.tick(alloc, 0, cap_16.callbacks());
    try pacer_32.tick(alloc, 0, cap_32.callbacks());

    var next_id: u64 = 2;
    for (0..50) |_| {
        try pacer_16.setTail(alloc, next_id);
        try pacer_32.setTail(alloc, next_id);
        next_id += 1;
    }

    try pacer_16.tick(alloc, 16 * std.time.ns_per_ms, cap_16.callbacks());
    try pacer_32.tick(alloc, 32 * std.time.ns_per_ms, cap_32.callbacks());

    try std.testing.expectEqual(@as(u64, 8), cap_16.last_tail_id - 1);
    try std.testing.expectEqual(@as(u64, 16), cap_32.last_tail_id - 1);
    try std.testing.expectEqual((cap_16.last_tail_id - 1) * 2, cap_32.last_tail_id - 1);
}

test "1s ticks with a 65-step backlog drain within 2 ticks" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = StepJumpCapture{};

    for (1..66) |id| {
        try pacer.setTail(alloc, id);
    }

    // Tick 1 uses default 1-frame elapsed (last_tick_ns is null); tick 2 sees 1s elapsed and drains the rest.
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expect(pacer.hasPending());

    try pacer.tick(alloc, 1 * std.time.ns_per_s, cap.callbacks());
    try std.testing.expect(!pacer.hasPending());
    try std.testing.expectEqual(@as(u64, 65), cap.last_tail_id);
}

test "a 24-step burst with 16ms frame gate reveals every slot within reveal_drain_window_ns plus one frame" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = StepJumpCapture{};

    for (1..25) |id| {
        try pacer.setTail(alloc, id);
    }

    var t_ms: i128 = 0;
    while (pacer.hasPending()) : (t_ms += 10) {
        try std.testing.expect(t_ms <= 500);
        try pacer.tick(alloc, t_ms * std.time.ns_per_ms, cap.callbacks());
    }
    try std.testing.expectEqual(@as(u64, 24), cap.last_tail_id);
    // Final reveal time `t_ms - 10` must be within reveal_drain_window_ns + 16ms.
    try std.testing.expect((t_ms - 10) * std.time.ns_per_ms <= reveal_drain_window_ns + reveal_frame_ns);
}

test "multi-byte UTF-8 sequence straddling a tail slot released_target drains cleanly without splitting" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // First two bytes of "中" (\xe4\xb8\xad) sit before the tail; final byte arrives after.
    try pacer.enqueue(alloc, "ab\xe4\xb8");
    try pacer.setTail(alloc, 1);
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("ab", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);

    try pacer.enqueue(alloc, "\xadxyz");
    try pacer.setTail(alloc, 2);
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(!pacer.hasPending());
    try std.testing.expectEqualStrings("ab\xe4\xb8\xadxyz", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 2), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try std.testing.expectEqual(@as(u64, 2), cap.tail_ids[1]);
    try expectNoSplitEscapeInEmits(&cap);
}

test "ANSI SGR sequence straddling a tail slot released_target drains cleanly without splitting" {
    const alloc = std.testing.allocator;
    var pacer = AssistantPacer{};
    defer pacer.deinit(alloc);
    var cap = TestCapture{};
    defer cap.deinit();

    // Prefix of "\x1b[0m" sits before the tail; terminator arrives after.
    try pacer.enqueue(alloc, "ab\x1b[0");
    try pacer.setTail(alloc, 1);
    try pacer.tick(alloc, 0, cap.callbacks());
    try std.testing.expectEqualStrings("ab", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 0), cap.tail_count);

    try pacer.enqueue(alloc, "mhi");
    try pacer.setTail(alloc, 2);
    _ = try drainPacerWithFrameTicks(&pacer, alloc, reveal_frame_ns, cap.callbacks());

    try std.testing.expect(!pacer.hasPending());
    try std.testing.expectEqualStrings("ab\x1b[0mhi", cap.emitted.items);
    try std.testing.expectEqual(@as(usize, 2), cap.tail_count);
    try std.testing.expectEqual(@as(u64, 1), cap.tail_ids[0]);
    try std.testing.expectEqual(@as(u64, 2), cap.tail_ids[1]);
    try expectNoSplitEscapeInEmits(&cap);
}
