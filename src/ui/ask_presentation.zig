const std = @import("std");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const diff_mod = @import("../core/output/diff.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const render_engine = @import("render_engine.zig");
const render_request = @import("render_request.zig");
const shared_theme = @import("../core/shared/theme.zig");
const shell_runtime = @import("shell_runtime.zig");
const shimmer_runtime = @import("transcript/shimmer_runtime.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const transcript_painter = @import("transcript/painter.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const ui_render = @import("render.zig");
const ui_terminal = @import("terminal/terminal.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

const restore_terminal_sequence = "\x1b[0m\x1b]8;;\x1b\\\x1b[?25h\x1b[?7h\n";
const prepare_terminal_sequence = "\x1b[0m\x1b]8;;\x1b\\\x1b[?7l";
const thinking_activity_label = "• Thinking";
/// Autowrap is on only while an outside prompt prints; see `beginOutsidePrompt`.
const outside_prompt_terminal_sequence = "\x1b[?7h";

pub const Runtime = struct {
    alloc: Allocator,
    shell: TranscriptRuntime,
    metrics: Metrics = .{},
    no_color: bool,
    thinking: bool = true,
    terminal_prepared: bool = false,
    finished: bool = false,
    /// True once an outside prompt has restarted this presentation. Tool events
    /// for calls that started before the prompt have no row here; see `pushToolLifecycle`.
    restarted_below_prompt: bool = false,
    pending_error: ?anyerror = null,
    /// Taken by every push, so only one thread writes the live area at a time.
    /// `beginOutsidePrompt` takes it too and keeps it until `endOutsidePrompt`,
    /// so pushes from other threads wait while a prompt owns the screen.
    mutex: std.Io.Mutex = .init,

    pub fn init(
        alloc: Allocator,
        header: ui_render.AskHeader,
        no_color: bool,
    ) !Runtime {
        const layout = zeroFooterLayout(try ui_terminal.queryLayout(std.posix.STDOUT_FILENO, 0));
        var terminal = shell_runtime.TerminalState{};
        const cursor = probeTerminal(&terminal, layout, no_color, .startup);
        return initConfigured(
            alloc,
            header,
            no_color,
            std.Io.File.stdout(),
            layout,
            cursor,
            shell_runtime.detectSyncUpdatesEnabled(alloc),
        );
    }

    fn initConfigured(
        alloc: Allocator,
        header: ui_render.AskHeader,
        no_color: bool,
        stdout_file: std.Io.File,
        layout: types.Layout,
        cursor: shell_runtime.CursorPosition,
        sync_updates_enabled: bool,
    ) !Runtime {
        var self = try initBare(alloc, no_color, stdout_file, layout, cursor, sync_updates_enabled);
        errdefer self.deinit();
        self.thinking = true;

        const banner = try ui_render.askHeaderMessage(alloc, header);
        defer alloc.free(banner);
        try self.shell.writeTranscriptClassified(
            alloc,
            &self.metrics,
            banner,
            true,
            .welcome,
        );
        try self.render();
        return self;
    }

    /// A presentation whose live area starts at `cursor`, with no transcript yet.
    fn initBare(
        alloc: Allocator,
        no_color: bool,
        stdout_file: std.Io.File,
        layout: types.Layout,
        cursor: shell_runtime.CursorPosition,
        sync_updates_enabled: bool,
    ) !Runtime {
        var self = Runtime{
            .alloc = alloc,
            .shell = .{
                .stdout_file = stdout_file,
                .sync_updates_enabled = sync_updates_enabled,
                .history_reset_uses_ris = shell_runtime.detectHistoryResetUsesRis(alloc),
                .layout = layout,
                .notebook = .{ .transcript_release = .{ .policy = .append_only } },
            },
            .no_color = no_color,
            .thinking = false,
        };
        errdefer self.deinit();

        try self.shell.initBacking(alloc);
        try self.shell.enableShadowVt(alloc);
        self.shell.setCommandOutputRenderPolicy(.{
            .code_highlight_theme = if (ui_render.is_light) .light else .dark,
        });
        const start = normalizeStartCursor(layout, cursor);
        self.shell.shadow_vt.?.cursor_row = start.row;
        self.shell.shadow_vt.?.cursor_col = start.col;
        self.shell.cursor_row = start.row;
        self.shell.cursor_col = start.col;

        self.terminal_prepared = true;
        try self.writeTerminalBytes(prepare_terminal_sequence);
        try self.shell.initViewport(&self.metrics, start.row);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.finished) {
            if (self.thinking and self.pending_error == null) {
                self.thinking = false;
                // Best-effort clear on teardown; stdout may already be closed.
                self.render() catch {};
            }
            // Best-effort restore on teardown; stdout may already be closed.
            self.restoreTerminal() catch {};
        }
        self.shell.deinit(self.alloc);
        self.finished = true;
    }

    pub fn semanticSink(self: *Runtime) @import("../core/agent/agent_runtime.zig").SemanticPresentationSink {
        return .{
            .ctx = self,
            .table = pushTable,
            .code_block = pushCodeBlock,
            .thematic_rule = pushThematicRule,
            .assistant_tail = pushAssistantTail,
        };
    }

    pub fn setThinking(self: *Runtime, active: bool) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        if (self.finished) return;
        if (self.thinking == active) return;
        self.thinking = active;
        self.render() catch |err| return self.failWith(err);
    }

    /// The open tail is applied at once: `fx ask` writes committed text without a pacer.
    fn pushAssistantTail(raw: *anyopaque, alloc: std.mem.Allocator, events: []assistant_presentation.Event) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        self.checkPendingError() catch |err| {
            assistant_presentation.freeEventSlice(alloc, events);
            return err;
        };
        const id = self.shell.stageAssistantTail(alloc, events);
        self.shell.applyStagedAssistantTail(self.alloc, id);
        self.render() catch |err| self.rememberFailure(err);
    }

    pub fn pushText(self: *Runtime, text: []const u8) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        if (text.len > 0) self.thinking = false;
        _ = self.shell.streamAssistantChunk(self.alloc, &self.metrics, text) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    pub fn pushToolLifecycle(self: *Runtime, event: types.ToolLifecycleEvent) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        self.thinking = false;
        _ = self.shell.applyToolLifecycle(self.alloc, event) catch |err| {
            if (err != error.UnknownToolLifecycleIdentity or !self.restarted_below_prompt) return self.failWith(err);
            debug_trace.logf("ask", "tool event for a call that started above the prompt has no row here", .{});
            return;
        };
        self.render() catch |err| return self.failWith(err);
        switch (event) {
            .turn_finished => self.shell.finishLifecycleBatch(self.alloc) catch |err| return self.failWith(err),
            else => {},
        }
    }

    pub fn pushDiffBlock(self: *Runtime, payload: diff_mod.DiffEntryPayload) !void {
        defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        self.thinking = false;
        _ = self.shell.appendRawTranscriptEntryClassified(
            self.alloc,
            payload.preview,
            .diff_block,
        ) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    pub fn pushNotice(self: *Runtime, notice: types.SemanticNotice) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        if (notice.visibility != .full_only) self.thinking = false;
        _ = self.shell.appendSemanticNotice(self.alloc, notice) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    pub fn finish(self: *Runtime) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        if (self.finished) return;
        if (self.thinking) {
            self.thinking = false;
            try self.render();
        } else {
            try self.renderPending();
        }
        try self.restoreTerminal();
        self.finished = true;
    }

    fn pushTable(raw: *anyopaque, table: assistant_presentation.TablePayload) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        self.thinking = false;
        _ = self.shell.appendAssistantTableOwned(self.alloc, table) catch |err| return self.failWith(err);
        self.render() catch |err| {
            self.rememberFailure(err);
        };
    }

    fn pushCodeBlock(raw: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        self.thinking = false;
        _ = self.shell.appendAssistantCodeBlockOwned(self.alloc, block) catch |err| return self.failWith(err);
        self.render() catch |err| {
            self.rememberFailure(err);
        };
    }

    fn pushThematicRule(raw: *anyopaque) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        self.thinking = false;
        _ = self.shell.appendAssistantThematicRule(self.alloc) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    fn lock(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Runtime) void {
        self.mutex.unlock(io_mod.getIo());
    }

    fn checkPendingError(self: *Runtime) !void {
        if (self.pending_error) |err| return err;
    }

    fn rememberFailure(self: *Runtime, err: anyerror) void {
        if (self.pending_error == null) self.pending_error = err;
    }

    /// Records `err` as the pending failure and returns it unchanged.
    fn failWith(self: *Runtime, err: anytype) @TypeOf(err) {
        self.rememberFailure(err);
        return err;
    }

    /// Draws rows that are still pending.
    fn renderPending(self: *Runtime) !void {
        if (!self.shell.render_requests.hasPending()) return;
        try self.render();
    }
    fn render(self: *Runtime) !void {
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.transcript);
        var attempt = (try self.shell.render_requests.beginAttempt()) orelse return;
        defer attempt.deinit();

        var source = try self.shell.prepareTranscriptSource(self.alloc, null);
        defer source.deinit(self.alloc);
        // A presentation restarted below a prompt can hold only rows that paint
        // nothing, such as a marker entry, until a push adds visible rows. Keep the
        // request pending for that push instead of asking the renderer for a paint.
        if (source.preview.natural_visual_rows == 0) {
            attempt.restore();
            return;
        }
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(self.alloc);
        var resolved_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
        var invalidations = attempt.snapshot.invalidations;
        self.shell.normalizeFrameInvalidations(&invalidations);

        const activity_state: render_engine.frame_layout.ActivityState = if (self.thinking)
            .{ .thinking = .{
                .gap_above_activity = self.shell.transientAssistantGapRows(),
            } }
        else
            .none;

        var solve_context = SolveContext{
            .runtime = self,
            .source = &source,
            .prepared = &prepared,
            .resolved_target = &resolved_target,
            .invalidations = invalidations,
        };
        const fixed = try render_engine.frame_fixed_point.solve(
            SolveContext,
            &solve_context,
            .{
                .terminal = self.shell.layout,
                .owned_top = self.shell.owned_top_row,
                .footer = .{ .natural_rows = 0, .min_rows = 0, .max_rows = 0 },
                .transcript = source.preview,
                .activity = activity_state,
                .prior = self.shell.committed_frame_layout,
            },
            SolveContext.prepareCandidate,
            SolveContext.resolveCandidate,
        );
        const paint = if (prepared) |*value| value else return error.MissingTranscriptPaint;
        const target = resolved_target orelse return error.MissingResolvedTranscriptTarget;

        const activity_placement: render_engine.activity_overlay.ActivityPlacement = if (self.thinking)
            if (fixed.layout.activity_row) |row|
                .{ .transient_row = .{
                    .row = row,
                    .row_count = @max(fixed.layout.activity_rows, 1),
                    .gap_above_rows = activity_state.thinking.gap_above_activity,
                } }
            else
                .none
        else
            .none;

        var plan = fixed.layout.toPaintPlan(.{
            .footer_rows = zeroFooterRows(self.shell.layout.rows),
            .viewport = target.selection(),
            .activity = activity_placement,
            .invalidation = invalidations,
            .synchronized_update = self.shell.sync_updates_enabled,
            .cursor_target = .{
                .row = activity_placement.row() orelse target.cursorRow(),
                .col = if (activity_placement.row() != null) 1 else target.cursorCol(),
                .visible = !self.thinking,
            },
            .preserve_scrollback = !self.shell.pending_scroll_compact,
            .reset_terminal = false,
        });
        var transition = try self.shell.sealTranscriptTransition(
            self.alloc,
            &source,
            paint,
            &plan,
            target,
        );
        defer transition.deinit(self.alloc);
        var paint_context = PaintContext{ .runtime = self, .prepared = paint };
        const transcript_body: render_engine.frame_builder.TranscriptBodyDisposition = switch (transition.body_disposition) {
            .paint => .paint,
            .retain_committed => |retained| .{ .retain = retained },
        };
        const result = try render_engine.frame_builder.buildAndFlushFrame(
            self.alloc,
            &self.shell,
            &self.metrics,
            .{
                .plan = plan,
                .transcript_body = transcript_body,
                .scroll_plan = fixed.scroll_plan,
                .document_append = transition.document_append,
                .body_painter = .{ .ctx = &paint_context, .paint = PaintContext.paint },
                .activity_painter = if (activity_placement != .none)
                    .{ .ctx = &paint_context, .paint = PaintContext.paintActivity }
                else
                    null,
                .presentation = if (self.no_color) .neutral else .styled,
            },
        );

        self.shell.consumeFrameScrollCommit(self.alloc, fixed.scroll_plan, result, &transition);
        if (!result.is_committed()) {
            attempt.restore();
            return error.FrameCommitFailed;
        }
        self.shell.has_committed_frame = true;
        self.shell.terminal_reset_pending = false;
        self.shell.transcript_band_dirty = false;
        attempt.commit(0, render_request.animation_interval_ms, false);
    }

    fn writeTerminalBytes(self: *Runtime, bytes: []const u8) !void {
        try self.shell.stdout_file.writeStreamingAll(io_mod.getIo(), bytes);
        self.metrics.ansi_bytes += bytes.len;
        if (self.shell.shadow_vt) |shadow| try shadow.feed(bytes);
    }

    fn restoreTerminal(self: *Runtime) !void {
        if (!self.terminal_prepared) return;
        self.terminal_prepared = false;
        try self.writeTerminalBytes(restore_terminal_sequence);
    }

    /// Called before a prompt writes below the presentation. Pending rows are
    /// drawn first, so the screen is complete. Autowrap is on while the prompt
    /// prints, so a long prompt line wraps instead of overwriting its last column.
    /// On success the lock stays held until `endOutsidePrompt`, so no other
    /// thread can write while the prompt owns the screen.
    pub fn beginOutsidePrompt(self: *Runtime) !void {
        self.lock();
        errdefer self.unlock();
        try self.checkPendingError();
        if (self.finished or !self.terminal_prepared) return;
        if (self.thinking) {
            self.thinking = false;
            self.render() catch |err| return self.failWith(err);
        } else {
            self.renderPending() catch |err| return self.failWith(err);
        }
        // The presentation's last row can end mid-line, so the prompt starts on a fresh row.
        if (self.shell.shadow_vt.?.cursor_col > 1) self.writeTerminalBytes("\r\n") catch |err| return self.failWith(err);
        self.writeTerminalBytes(outside_prompt_terminal_sequence) catch |err| return self.failWith(err);
    }

    /// Called after a prompt has read its answers. The rows the prompt wrote
    /// stay as they are: the presentation starts a new live area below the
    /// cursor, so it never paints over them. Releases the lock that
    /// `beginOutsidePrompt` took.
    pub fn endOutsidePrompt(self: *Runtime) void {
        defer self.unlock();
        if (self.finished or !self.terminal_prepared) return;
        // The presentation never saw the rows the prompt wrote or the echoed answer,
        // so the cursor comes from the terminal. The layout is the one the presentation
        // last drew with: a resize during the prompt is applied at the next draw.
        const layout = self.shell.layout;
        var terminal = shell_runtime.TerminalState{};
        const cursor = probeTerminal(&terminal, layout, self.no_color, .after_outside_prompt);
        debug_trace.logf("ask", "presentation restarts below an outside prompt cursor={d},{d} layout={d}x{d}", .{ cursor.row, cursor.col, layout.rows, layout.cols });
        self.restartBelow(layout, cursor) catch |err| self.rememberFailure(err);
    }

    /// Replaces the finished live area with an empty one at `cursor`. The old
    /// transcript is dropped, not repainted: its rows are already on screen above.
    /// Only the live area changes. The lock, the pending error and the shared
    /// flags stay as they are, so the caller's lock still covers the new area.
    fn restartBelow(self: *Runtime, layout: types.Layout, cursor: shell_runtime.CursorPosition) !void {
        const next = try initBare(self.alloc, self.no_color, self.shell.stdout_file, layout, cursor, self.shell.sync_updates_enabled);
        self.shell.deinit(self.alloc);
        self.shell = next.shell;
        self.metrics = next.metrics;
        self.restarted_below_prompt = true;
    }
};

const SolveContext = struct {
    runtime: *Runtime,
    source: *transcript_runtime.TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
    invalidations: render_engine.paint_plan.FrameInvalidationSet,
    scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

    fn prepareCandidate(
        self: *SolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        if (self.prepared.*) |*paint| {
            paint.deinit(self.runtime.alloc);
            self.prepared.* = null;
        }
        self.resolved_target.* = null;
        self.scroll_facts = null;
        if (candidate.transcript_area.isEmpty()) return .{
            .inline_advance_rows = 0,
            .occupied_transcript_rows = 0,
        };
        self.prepared.* = try self.runtime.shell.prepareTranscriptSurfacePaintFromSourceForArea(
            self.runtime.alloc,
            &self.runtime.metrics,
            self.source,
            candidate.transcript_area,
        );
        const paint = &self.prepared.*.?;
        const scroll_facts = try self.runtime.shell.prepareTranscriptScrollFactsForFrame(
            self.runtime.alloc,
            self.source,
            paint,
            false,
            false,
        );
        self.scroll_facts = scroll_facts;
        const occupied_transcript_rows = if (paint.selection.last_visible_row >= candidate.transcript_area.top)
            paint.selection.last_visible_row - candidate.transcript_area.top + 1
        else
            0;
        return .{
            .inline_advance_rows = scroll_facts.planned_rows,
            .occupied_transcript_rows = occupied_transcript_rows,
        };
    }

    fn resolveCandidate(
        self: *SolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        if (candidate.transcript_area.isEmpty()) return .{ .occupied_transcript_rows = 0 };
        const paint = if (self.prepared.*) |*value| value else return error.MissingTranscriptPaint;
        const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
        const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate);
        const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
            self.runtime.shell.committed_frame_layout.transcript_area,
            self.invalidations,
        );
        const target = try self.runtime.shell.resolveTranscriptTransitionTargetForFrame(
            self.runtime.alloc,
            self.source,
            paint,
            target_layout,
            scroll_plan,
            scroll_facts,
            destructive_invalidation,
            false,
        );
        self.resolved_target.* = target;
        return .{ .occupied_transcript_rows = target.occupiedTranscriptRows() };
    }
};

const PaintContext = struct {
    runtime: *Runtime,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,

    fn paint(raw: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) !void {
        const self: *PaintContext = @ptrCast(@alignCast(raw));
        if (surface.plan.transcript_band.isEmpty()) return;
        _ = try self.runtime.shell.paintPreparedTranscriptIntoSurface(
            self.runtime.alloc,
            surface,
            self.prepared,
        );
    }

    fn paintActivity(_: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) !void {
        if (surface.plan.activity_band.isEmpty()) return;
        _ = try shimmer_runtime.paintActivityIntoSurface(surface, .{
            .label = thinking_activity_label,
            .shimmer_pos = 0,
            .style = .live,
            .thinking_blink = true,
        });
    }
};

/// Why the terminal is probed. Startup also sets the theme. A probe after an
/// outside prompt only reads the cursor: the theme is already set, and the
/// prompt must not change it.
const TerminalProbe = enum { startup, after_outside_prompt };

/// The one terminal probe: raw mode on stdin, then the cursor position. Without
/// an answer from the terminal, the last row of `layout` is used.
fn probeTerminal(
    terminal: *shell_runtime.TerminalState,
    layout: types.Layout,
    no_color: bool,
    probe: TerminalProbe,
) shell_runtime.CursorPosition {
    const fallback = shell_runtime.CursorPosition{ .row = layout.rows, .col = 1 };
    const sets_theme = probe == .startup;
    // A light/dark pin was applied before presentation setup; leave it alone.
    const theme_locked = ui_render.themeInputLocked();
    if (sets_theme and !theme_locked) {
        const fallback_light = if (no_color) false else ui_render.explicitThemeOverride() orelse false;
        ui_render.initTheme(fallback_light, null);
    }
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return fallback;
    terminal.captureOriginalTermios() catch return fallback;
    terminal.enableRawMode() catch return fallback;
    defer terminal.disableRawMode();

    if (sets_theme and !no_color and !theme_locked) {
        const theme = ui_render.detectTheme(std.heap.c_allocator, terminal);
        if (shared_theme.sourceName()) |name| {
            // Custom themes resolve after detection picks the variant, same
            // rule as the interactive shell.
            const custom = shared_theme.resolveNamed(std.heap.c_allocator, name, theme.light, .{ .truecolor = ui_render.truecolorIsEnabled() }) catch null;
            if (custom) |resolved| {
                ui_render.applyTheme(resolved, theme.rgb);
            } else {
                ui_render.initTheme(theme.light, theme.rgb);
            }
        } else {
            ui_render.initTheme(theme.light, theme.rgb);
        }
    }
    return terminal.queryCursorPosition() catch fallback;
}

fn zeroFooterLayout(layout: types.Layout) types.Layout {
    return .{
        .rows = layout.rows,
        .cols = layout.cols,
        .content_bottom = layout.rows,
        .divider_top_row = layout.rows,
        .input_row = layout.rows,
        .divider_bottom_row = layout.rows,
        .hint_row = layout.rows,
    };
}

fn zeroFooterRows(rows: u16) render_engine.footer_layout.FooterRows {
    return .{
        .top = rows,
        .top_divider = rows,
        .banner = rows,
        .input_base = rows,
        .picker_divider = rows,
        .picker_start = rows,
        .bottom_divider = rows,
        .hint = rows,
        .total_rows = 0,
    };
}

fn normalizeStartCursor(
    layout: types.Layout,
    cursor: shell_runtime.CursorPosition,
) shell_runtime.CursorPosition {
    var row = @min(@max(cursor.row, 1), layout.rows);
    const col = @min(@max(cursor.col, 1), layout.cols);
    if (col > 1 and row < layout.rows) row += 1;
    return .{ .row = row, .col = 1 };
}

test "ask presentation paints ask header and assistant into a footerless frame without prompt echo" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-frame.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5", .effort = "high" },
        false,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 64,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    try runtime.pushText("\x1b[1manswer\x1b[22m\n");
    try runtime.finish();

    try std.testing.expect(runtime.shell.notebook.entries.items.len >= 2);
    try std.testing.expect(runtime.shell.notebook.entries.items[0] == .raw_bytes);
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.welcome,
        runtime.shell.notebook.entries.items[0].raw_bytes.class,
    );
    for (runtime.shell.notebook.entries.items) |entry| {
        try std.testing.expect(entry != .user_turn);
    }
    try std.testing.expect(runtime.shell.committed_frame_layout.footer_area.isEmpty());
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.shell.transcriptCommitDiagnostic().state,
    );
    const committed = runtime.shell.stableTranscriptProjectionForFlow(
        runtime.shell.notebook.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expect(
        committed.selection.last_visible_row <=
            runtime.shell.committed_frame_layout.transcript_area.bottom,
    );
    const shadow = runtime.shell.shadow_vt orelse return error.TestExpectedShadowVt;
    var row1: std.ArrayList(u8) = .empty;
    defer row1.deinit(alloc);
    try shadow.rowTextTrimmed(1, &row1);
    try std.testing.expect(std.mem.find(u8, row1.items, "𝒇x v") != null);
    try std.testing.expect(std.mem.find(u8, row1.items, "openai/gpt-5 · high · fx ask --help") != null);
    try std.testing.expect(std.mem.find(u8, row1.items, "Run /help for commands") == null);
    const length = try output.length(io_mod.getIo());
    try std.testing.expect(length > restore_terminal_sequence.len);
}

test "ask presentation carries the light theme into semantic code blocks" {
    const alloc = std.testing.allocator;
    ui_render.initTheme(true, null);
    defer ui_render.initTheme(false, null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-light-frame.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 48,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    try std.testing.expect(runtime.shell.retainedTranscriptStyles().code_highlight_theme == .light);
}

fn askGridRowsContaining(runtime: *Runtime, needle: []const u8) !usize {
    var count: usize = 0;
    var row: u16 = 1;
    while (row <= runtime.shell.layout.rows) : (row += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.testing.allocator);
        try runtime.shell.shadow_vt.?.rowText(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) count += 1;
    }
    return count;
}

test "ask presentation draws a provisional tail and drops it when committed text arrives" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-tail.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 48,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    const events = try alloc.alloc(assistant_presentation.Event, 1);
    events[0] = .{ .text = try alloc.dupe(u8, "Streaming bold") };
    const sink = runtime.semanticSink();
    try sink.assistant_tail.?(sink.ctx, alloc, events);
    try std.testing.expectEqual(@as(usize, 1), runtime.shell.assistant_tail.items.len);
    try std.testing.expectEqual(@as(usize, 1), try askGridRowsContaining(&runtime, "Streaming bold"));

    try runtime.pushText("Streaming bold\n");
    try std.testing.expectEqual(@as(usize, 0), runtime.shell.assistant_tail.items.len);
    try std.testing.expectEqual(@as(usize, 1), try askGridRowsContaining(&runtime, "Streaming bold"));
    try runtime.finish();
}

test "ask presentation retains a streaming write failure until finish" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try tmp.dir.createFile(std.testing.io, "ask-frame-failure.log", .{ .read = true });

    const layout = zeroFooterLayout(.{
        .rows = 12,
        .cols = 48,
        .content_bottom = 12,
        .divider_top_row = 12,
        .input_row = 12,
        .divider_bottom_row = 12,
        .hint_row = 12,
    });
    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        layout,
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();
    output.close(io_mod.getIo());

    var observed: ?anyerror = null;
    runtime.pushText("answer\n") catch |err| {
        observed = err;
    };
    const write_err = observed orelse return error.TestExpectedError;
    try std.testing.expectError(write_err, runtime.finish());
}

fn testShadowContains(alloc: Allocator, runtime: *const Runtime, needle: []const u8) !bool {
    const shadow = runtime.shell.shadow_vt orelse return error.TestExpectedShadowVt;
    var row_buf: std.ArrayList(u8) = .empty;
    defer row_buf.deinit(alloc);
    var row: u16 = 1;
    while (row <= shadow.rows) : (row += 1) {
        row_buf.clearRetainingCapacity();
        try shadow.rowTextTrimmed(row, &row_buf);
        if (std.mem.find(u8, row_buf.items, needle) != null) return true;
    }
    return false;
}

fn readTmpFile(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var file = try dir.openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

test "ask presentation shows transient thinking row on init and clears it on text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-thinking.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5", .effort = "high" },
        false,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 64,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    // First frame shows transient thinking below the header.
    try std.testing.expect(try testShadowContains(alloc, &runtime, "𝒇x v"));
    try std.testing.expect(try testShadowContains(alloc, &runtime, thinking_activity_label));

    // Streaming text clears the transient thinking row completely.
    try runtime.pushText("Final answer.\n");
    try std.testing.expect(!try testShadowContains(alloc, &runtime, thinking_activity_label));
    try std.testing.expect(!try testShadowContains(alloc, &runtime, "•"));
    try std.testing.expect(try testShadowContains(alloc, &runtime, "Final answer."));

    try runtime.finish();
    try std.testing.expect(!try testShadowContains(alloc, &runtime, thinking_activity_label));
}

test "ask presentation restores thinking after tool lifecycle and clears on setThinking(false) and finish without screen clears" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-tool-thinking.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 64,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    try std.testing.expect(try testShadowContains(alloc, &runtime, thinking_activity_label));

    const call_id: types.ToolLifecycleId = .{ .turn_id = 1, .call_id = "call_1" };
    try runtime.pushToolLifecycle(.{ .authoritative_started = .{
        .id = call_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try std.testing.expect(!try testShadowContains(alloc, &runtime, thinking_activity_label));

    try runtime.pushToolLifecycle(.{ .terminal = .{
        .id = call_id,
        .outcome = .{ .kind = .completed, .summary = "Reading README.md" },
    } });
    try runtime.setThinking(true);
    try std.testing.expect(try testShadowContains(alloc, &runtime, thinking_activity_label));

    try runtime.setThinking(false);
    try std.testing.expect(!try testShadowContains(alloc, &runtime, thinking_activity_label));

    try runtime.setThinking(true);
    try std.testing.expect(try testShadowContains(alloc, &runtime, thinking_activity_label));
    try runtime.finish();
    try std.testing.expect(!try testShadowContains(alloc, &runtime, thinking_activity_label));

    const bytes = try readTmpFile(alloc, tmp.dir, "ask-tool-thinking.log");
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[3J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1bc") == null);
}

test "ask presentation restarts below an outside prompt without repainting earlier rows" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-outside-prompt.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    const layout = zeroFooterLayout(.{
        .rows = 20,
        .cols = 60,
        .content_bottom = 20,
        .divider_top_row = 20,
        .input_row = 20,
        .divider_bottom_row = 20,
        .hint_row = 20,
    });
    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        layout,
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();
    try runtime.pushText("alpha line\nbeta line\n");

    const before_prompt: usize = @intCast(try output.length(io_mod.getIo()));
    try runtime.beginOutsidePrompt();
    try runtime.writeTerminalBytes("\nEnter a value: local-value\r\n");
    const after_prompt: usize = @intCast(try output.length(io_mod.getIo()));
    try runtime.restartBelow(layout, .{ .row = runtime.shell.shadow_vt.?.cursor_row, .col = 1 });
    runtime.unlock();
    try runtime.pushText("gamma line\n");
    try runtime.finish();

    const bytes = try io_mod.readFileToEnd(alloc, &output, 1 << 20);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes[before_prompt..after_prompt], outside_prompt_terminal_sequence) != null);
    const restarted = bytes[after_prompt..];
    try std.testing.expect(std.mem.find(u8, restarted, prepare_terminal_sequence) != null);
    try std.testing.expect(std.mem.find(u8, restarted, "gamma line") != null);
    try std.testing.expect(std.mem.find(u8, restarted, "alpha line") == null);
    try std.testing.expect(std.mem.find(u8, restarted, "𝒇x v") == null);
    try std.testing.expect(std.mem.find(u8, restarted, "Run /help") == null);
}

test "ask presentation neutralizes thinking row styling under no_color" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-nocolor-thinking.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        true,
        output,
        zeroFooterLayout(.{
            .rows = 12,
            .cols = 64,
            .content_bottom = 12,
            .divider_top_row = 12,
            .input_row = 12,
            .divider_bottom_row = 12,
            .hint_row = 12,
        }),
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    try std.testing.expect(try testShadowContains(alloc, &runtime, thinking_activity_label));
    try runtime.finish();

    const bytes = try readTmpFile(alloc, tmp.dir, "ask-nocolor-thinking.log");
    defer alloc.free(bytes);
    // Neutral presentation emits no color SGR codes (38;/48;) for header or thinking row.
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[38;") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[48;") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[3J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1bc") == null);
}

test "an outside prompt holds the presentation lock until it ends" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-outside-lock.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    const layout = zeroFooterLayout(.{
        .rows = 20,
        .cols = 60,
        .content_bottom = 20,
        .divider_top_row = 20,
        .input_row = 20,
        .divider_bottom_row = 20,
        .hint_row = 20,
    });
    var runtime = try Runtime.initConfigured(
        alloc,
        .{ .model = "openai/gpt-5" },
        false,
        output,
        layout,
        .{ .row = 1, .col = 1 },
        true,
    );
    defer runtime.deinit();

    try runtime.beginOutsidePrompt();
    try std.testing.expect(!runtime.mutex.tryLock());
    var pushed = std.atomic.Value(bool).init(false);
    const worker = try std.Thread.spawn(.{}, pushFromWorker, .{ &runtime, &pushed });
    try std.testing.expect(!pushed.load(.seq_cst));
    runtime.unlock();
    worker.join();
    try std.testing.expect(pushed.load(.seq_cst));
    try std.testing.expect(runtime.mutex.tryLock());
    runtime.unlock();
}

fn pushFromWorker(runtime: *Runtime, pushed: *std.atomic.Value(bool)) void {
    runtime.pushText("worker line\n") catch return;
    pushed.store(true, .seq_cst);
}
