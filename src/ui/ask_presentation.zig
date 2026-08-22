const std = @import("std");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const diff_mod = @import("../core/output/diff.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const render_engine = @import("render_engine.zig");
const render_request = @import("render_request.zig");
const shell_runtime = @import("shell_runtime.zig");
const transcript_painter = @import("transcript/painter.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const ui_render = @import("render.zig");
const ui_terminal = @import("terminal/terminal.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

const restore_terminal_sequence = "\x1b[0m\x1b]8;;\x1b\\\x1b[?25h\x1b[?7h\n";
const prepare_terminal_sequence = "\x1b[0m\x1b]8;;\x1b\\\x1b[?7l";

pub const Runtime = struct {
    alloc: Allocator,
    shell: TranscriptRuntime,
    metrics: Metrics = .{},
    no_color: bool,
    terminal_prepared: bool = false,
    finished: bool = false,
    pending_error: ?anyerror = null,

    pub fn init(
        alloc: Allocator,
        user: types.UserTurn,
        no_color: bool,
    ) !Runtime {
        const stdout_fd = if (comptime @import("builtin").os.tag == .windows) @as(std.posix.fd_t, @ptrFromInt(1)) else std.posix.STDOUT_FILENO;
        const layout = zeroFooterLayout(try ui_terminal.queryLayout(stdout_fd, 0));
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
        var self = Runtime{
            .alloc = alloc,
            .shell = .{
                .stdout_file = stdout_file,
                .sync_updates_enabled = sync_updates_enabled,
                .history_reset_uses_ris = shell_runtime.detectHistoryResetUsesRis(alloc),
                .layout = layout,
                .transcript_release = .{ .policy = .append_only },
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
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.streamAssistantChunk(self.alloc, &self.metrics, text);
        try self.render();
    }

    pub fn pushToolLifecycle(self: *Runtime, event: types.ToolLifecycleEvent) !void {
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.applyToolLifecycle(self.alloc, event);
        try self.render();
        switch (event) {
            .turn_finished => try self.shell.finishLifecycleBatch(self.alloc),
            else => {},
        }
    }

    pub fn pushDiffBlock(self: *Runtime, payload: diff_mod.DiffEntryPayload) !void {
        defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.appendRawTranscriptEntryClassified(
            self.alloc,
            payload.preview,
            .diff_block,
        );
        try self.render();
    }

    pub fn pushNotice(self: *Runtime, notice: types.SemanticNotice) !void {
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.appendSemanticNotice(self.alloc, notice);
        try self.render();
    }

    pub fn finish(self: *Runtime) !void {
        try self.checkPendingError();
        if (self.finished) return;
        if (self.shell.render_requests.hasPending()) try self.render();
        try self.restoreTerminal();
        self.finished = true;
    }

    fn pushTable(raw: *anyopaque, table: assistant_presentation.TablePayload) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.appendAssistantTableOwned(self.alloc, table);
        self.render() catch |err| {
            self.rememberFailure(err);
        };
    }

    fn pushCodeBlock(raw: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.appendAssistantCodeBlockOwned(self.alloc, block);
        self.render() catch |err| {
            self.rememberFailure(err);
        };
    }

    fn pushThematicRule(raw: *anyopaque) !void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        try self.checkPendingError();
        errdefer |err| self.rememberFailure(err);
        _ = try self.shell.appendAssistantThematicRule(self.alloc);
        try self.render();
    }

    fn checkPendingError(self: *Runtime) !void {
        if (self.pending_error) |err| return err;
    }

    fn rememberFailure(self: *Runtime, err: anyerror) void {
        if (self.pending_error == null) self.pending_error = err;
    }

    fn refreshGeometry(self: *Runtime) !void {
        if (comptime @import("builtin").os.tag == .windows) return;
        const queried = ui_terminal.queryLayout(std.posix.STDOUT_FILENO, 0) catch return;
        const layout = zeroFooterLayout(queried);
        if (layout.rows == self.shell.layout.rows and layout.cols == self.shell.layout.cols) return;
        try shell_runtime.applyResizeWithLayout(&self.shell, &self.metrics, layout, true);
    }

    fn render(self: *Runtime) !void {
        try self.refreshGeometry();
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.transcript);
        var attempt = (try self.shell.render_requests.beginAttempt()) orelse return;
        defer attempt.deinit();

        var source = try self.shell.prepareTranscriptSource(self.alloc, null);
        defer source.deinit(self.alloc);
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
    const fallback_light = if (no_color) false else ui_render.explicitThemeOverride() orelse false;
    ui_render.initTheme(fallback_light, null);
    if (comptime @import("builtin").os.tag == .windows) return fallback;
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0) return fallback;
    terminal.captureOriginalTermios() catch return fallback;
    terminal.enableRawMode() catch return fallback;
    defer terminal.disableRawMode();

    if (!no_color) {
        const theme = ui_render.detectTheme(std.heap.c_allocator, terminal);
        ui_render.initTheme(theme.light, theme.rgb);
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

    try std.testing.expect(runtime.shell.entries.items.len >= 3);
    try std.testing.expect(runtime.shell.entries.items[0] == .raw_bytes);
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.welcome,
        runtime.shell.entries.items[0].raw_bytes.class,
    );
    try std.testing.expect(runtime.shell.entries.items[1] == .user_turn);
    try std.testing.expect(runtime.shell.committed_frame_layout.footer_area.isEmpty());
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.shell.transcriptCommitDiagnostic().state,
    );
    const committed = runtime.shell.stableTranscriptProjectionForFlow(
        runtime.shell.transcript.items,
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
