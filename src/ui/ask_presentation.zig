const std = @import("std");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const diff_mod = @import("../core/output/diff.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const render_engine = @import("render_engine.zig");
const render_request = @import("render_request.zig");
const shared_theme = @import("../core/shared/theme.zig");
const shell_runtime = @import("shell_runtime.zig");
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
/// Autowrap is on only while an outside prompt prints; see `beginOutsidePrompt`.
const outside_prompt_terminal_sequence = "\x1b[?7h";

pub const Runtime = struct {
    alloc: Allocator,
    shell: TranscriptRuntime,
    metrics: Metrics = .{},
    no_color: bool,
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
        user: types.UserTurn,
        no_color: bool,
    ) !Runtime {
        const layout = zeroFooterLayout(try ui_terminal.queryLayout(std.posix.STDOUT_FILENO, 0));
        var terminal = shell_runtime.TerminalState{};
        const cursor = probeTerminal(&terminal, layout, no_color);
        return initConfigured(
            alloc,
            user,
            no_color,
            std.Io.File.stdout(),
            layout,
            cursor,
            shell_runtime.detectSyncUpdatesEnabled(alloc),
        );
    }

    fn initConfigured(
        alloc: Allocator,
        user: types.UserTurn,
        no_color: bool,
        stdout_file: std.Io.File,
        layout: types.Layout,
        cursor: shell_runtime.CursorPosition,
        sync_updates_enabled: bool,
    ) !Runtime {
        var self = try initBare(alloc, no_color, stdout_file, layout, cursor, sync_updates_enabled);
        errdefer self.deinit();

        const welcome = try ui_render.welcomeMessage(alloc);
        defer alloc.free(welcome);
        try self.shell.writeTranscriptClassified(
            alloc,
            &self.metrics,
            welcome,
            true,
            .welcome,
        );
        const owned_user = try types.dupeUserTurn(alloc, user);
        _ = try self.shell.appendUserTurnOwned(alloc, owned_user);
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
        if (!self.finished) self.restoreTerminal() catch {};
        self.shell.deinit(self.alloc);
        self.finished = true;
    }

    pub fn semanticSink(self: *Runtime) @import("../core/agent/agent_runtime.zig").SemanticPresentationSink {
        return .{
            .ctx = self,
            .table = pushTable,
            .code_block = pushCodeBlock,
            .thematic_rule = pushThematicRule,
        };
    }

    pub fn pushText(self: *Runtime, text: []const u8) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        _ = self.shell.streamAssistantChunk(self.alloc, &self.metrics, text) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    pub fn pushToolLifecycle(self: *Runtime, event: types.ToolLifecycleEvent) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
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
        _ = self.shell.appendSemanticNotice(self.alloc, notice) catch |err| return self.failWith(err);
        self.render() catch |err| return self.failWith(err);
    }

    pub fn finish(self: *Runtime) !void {
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
        if (self.finished) return;
        try self.renderPending();
        try self.restoreTerminal();
        self.finished = true;
    }

    fn pushTable(raw: *anyopaque, table: assistant_presentation.TablePayload) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.lock();
        defer self.unlock();
        try self.checkPendingError();
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

    fn refreshGeometry(self: *Runtime) !void {
        const queried = ui_terminal.queryLayout(std.posix.STDOUT_FILENO, 0) catch return;
        const layout = zeroFooterLayout(queried);
        if (layout.rows == self.shell.layout.rows and layout.cols == self.shell.layout.cols) return;
        try shell_runtime.applyResizeWithLayout(&self.shell, &self.metrics, layout, true);
    }

    /// Draws rows that are still pending.
    fn renderPending(self: *Runtime) !void {
        if (!self.shell.render_requests.hasPending()) return;
        try self.render();
    }

    fn render(self: *Runtime) !void {
        try self.refreshGeometry();
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
                .prior = self.shell.committed_frame_layout,
            },
            SolveContext.prepareCandidate,
            SolveContext.resolveCandidate,
        );
        const paint = if (prepared) |*value| value else return error.MissingTranscriptPaint;
        const target = resolved_target orelse return error.MissingResolvedTranscriptTarget;

        var plan = fixed.layout.toPaintPlan(.{
            .footer_rows = zeroFooterRows(self.shell.layout.rows),
            .viewport = target.selection(),
            .invalidation = invalidations,
            .synchronized_update = self.shell.sync_updates_enabled,
            .cursor_target = .{
                .row = target.cursorRow(),
                .col = target.cursorCol(),
                .visible = true,
            },
            .preserve_scrollback = !self.shell.pending_scroll_compact,
            .reset_terminal = self.shell.terminal_reset_pending,
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
        self.renderPending() catch |err| return self.failWith(err);
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
        const layout = zeroFooterLayout(ui_terminal.queryLayout(std.posix.STDOUT_FILENO, 0) catch |err| return self.rememberFailure(err));
        const cursor = cursorAfterOutsidePrompt(layout);
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
};

fn probeTerminal(
    terminal: *shell_runtime.TerminalState,
    layout: types.Layout,
    no_color: bool,
) shell_runtime.CursorPosition {
    const fallback = shell_runtime.CursorPosition{ .row = layout.rows, .col = 1 };
    // A light/dark pin was applied before presentation setup; leave it alone.
    const theme_locked = ui_render.themeInputLocked();
    if (!theme_locked) {
        const fallback_light = if (no_color) false else ui_render.explicitThemeOverride() orelse false;
        ui_render.initTheme(fallback_light, null);
    }
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return fallback;
    terminal.captureOriginalTermios() catch return fallback;
    terminal.enableRawMode() catch return fallback;
    defer terminal.disableRawMode();

    if (!no_color and !theme_locked) {
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

/// Where the cursor is after an answered prompt. The presentation never saw the
/// rows the prompt wrote or the echoed answer, so it asks the terminal. Without
/// an answer from the terminal, the last row is used.
fn cursorAfterOutsidePrompt(layout: types.Layout) shell_runtime.CursorPosition {
    const fallback = shell_runtime.CursorPosition{ .row = layout.rows, .col = 1 };
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return fallback;
    var terminal = shell_runtime.TerminalState{};
    terminal.captureOriginalTermios() catch return fallback;
    terminal.enableRawMode() catch return fallback;
    defer terminal.disableRawMode();
    return terminal.queryCursorPosition() catch fallback;
}

test "ask presentation paints Minimal prompt and assistant into a footerless frame" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "ask-frame.log", .{ .read = true });
    defer output.close(io_mod.getIo());

    const prompt = types.UserTurn{ .text = @constCast("show **markdown**") };
    var runtime = try Runtime.initConfigured(
        alloc,
        prompt,
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

    try runtime.pushText("\x1b[1manswer\x1b[22m\n");
    try runtime.finish();

    try std.testing.expect(runtime.shell.notebook.entries.items.len >= 3);
    try std.testing.expect(runtime.shell.notebook.entries.items[0] == .raw_bytes);
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.welcome,
        runtime.shell.notebook.entries.items[0].raw_bytes.class,
    );
    try std.testing.expect(runtime.shell.notebook.entries.items[1] == .user_turn);
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
    try std.testing.expect(runtime.shell.shadow_vt.?.cellAt(1, 1) != null);
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
        .{ .text = @constCast("show code") },
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
        .{ .text = @constCast("show output") },
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
        .{ .text = @constCast("go") },
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
    try std.testing.expect(std.mem.find(u8, restarted, "Run /help") == null);
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
        .{ .text = @constCast("go") },
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
