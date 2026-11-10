// Activity rendering is surface-owned.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const render_request = @import("../render_request.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const frame_surface = render_engine.frame_surface;
const paint_plan = render_engine.paint_plan;

const surface_shimmer_paint_trace_fmt = "shimmer_surface_paint row={d} visible={s} over_footer={s} label_bytes={d} label_hash={x}";

pub const ActivityPaintInput = struct {
    label: []const u8,
    tool_label: ?[]const u8 = null,
    shimmer_pos: i16,
    style: ActivityPaintStyle = .thinking,
    /// Wall-clock blink state synced to the elapsed counter; null falls back
    /// to the frame-phase blink.
    thinking_blink: ?bool = null,
};

pub const ActivityPaintStyle = enum {
    thinking,
    /// `thinking`'s bullet and color with the bullet always shown.
    live,
    tool_marker,
    neutral,
    warning,
    success,
    danger,
};

fn activityRowLabel(label: []const u8) []const u8 {
    var end = label.len;
    if (std.mem.findScalar(u8, label, '\n')) |idx| end = @min(end, idx);
    if (std.mem.findScalar(u8, label, '\r')) |idx| end = @min(end, idx);
    return label[0..end];
}

fn omissionMarker(cols: u16) []const u8 {
    return switch (cols) {
        0 => "",
        1 => ".",
        2 => "..",
        else => "...",
    };
}

const ActivityLabelPreview = struct {
    bytes: []const u8,
    allocation: ?[]u8 = null,

    fn deinit(self: ActivityLabelPreview, alloc: std.mem.Allocator) void {
        if (self.allocation) |allocation| alloc.free(allocation);
    }
};

fn previewActivityRowLabel(alloc: std.mem.Allocator, label: []const u8, cols: u16) !ActivityLabelPreview {
    const row = activityRowLabel(label);
    if (display_width.visibleWidthIgnoringAnsi(row) <= cols) return .{ .bytes = row };

    const marker = omissionMarker(cols);
    const prefix = display_width.prefixByWidthIgnoringAnsi(row, @as(usize, cols) - marker.len);
    const allocation = try alloc.alloc(u8, prefix.len + marker.len);
    @memcpy(allocation[0..prefix.len], prefix);
    @memcpy(allocation[prefix.len..], marker);
    return .{ .bytes = allocation, .allocation = allocation };
}

/// A static status row whose text, after the status sign, starts the row: a
/// mark that starts it has no base, since the sign's space is none, so
/// `display_width.writeRowPart` draws it on a circle of its own.
fn previewStaticActivityRow(alloc: std.mem.Allocator, row: []const u8, cols: u16) !ActivityLabelPreview {
    const text_start = display_width.statusPrefixEnd(row);
    if (display_width.bareMarkInRow(row[text_start..]) == null) return previewActivityRowLabel(alloc, row, cols);

    var drawn: std.Io.Writer.Allocating = .init(alloc);
    errdefer drawn.deinit();
    try drawn.writer.writeAll(row[0..text_start]);
    var at_row_start = true;
    try display_width.writeRowPart(&drawn.writer, row[text_start..], &at_row_start);
    const with_circle = try drawn.toOwnedSlice();
    errdefer alloc.free(with_circle);

    // The circle is a cell of the row, and the marks after it take none, so
    // the cut keeps them with it.
    const preview = try previewActivityRowLabel(alloc, with_circle, cols);
    if (preview.allocation != null) {
        alloc.free(with_circle);
        return preview;
    }
    return .{ .bytes = preview.bytes, .allocation = with_circle };
}

fn appendStaticActivityLine(
    out: *std.Io.Writer,
    prefix: []const u8,
    continuation_indent_width: usize,
    chunk: []const u8,
    first: bool,
) !void {
    if (!first) try out.writeByte('\n');
    if (first) {
        try out.writeAll(prefix);
    } else {
        try out.splatByteAll(' ', continuation_indent_width);
    }
    // The chunk starts a row after the sign or the indent, neither of which is
    // a base for a mark.
    var at_row_start = true;
    try display_width.writeRowPart(out, chunk, &at_row_start);
}

fn wrappedStaticActivityLabel(
    alloc: std.mem.Allocator,
    label: []const u8,
    cols: u16,
    max_rows: u16,
    preserve_trailing_context: bool,
) !ActivityLabelPreview {
    const row = activityRowLabel(label);
    const prefix_end = display_width.statusPrefixEnd(row);
    const prefix = row[0..prefix_end];
    const prefix_width = display_width.visibleWidthIgnoringAnsi(prefix);
    if (max_rows <= 1 or prefix_width + display_width.rowWidthIgnoringAnsi(row[prefix_end..]) <= cols) {
        return previewStaticActivityRow(alloc, row, cols);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    const safe_cols = @max(@as(usize, cols), 1);
    const continuation_indent_width = @max(prefix_width, 1);
    var remaining = row[prefix_end..];
    var row_count: u16 = 0;
    var first = true;
    while (remaining.len > 0 and row_count < max_rows) {
        const indent_width = if (first) prefix_width else continuation_indent_width;
        const available = if (safe_cols > indent_width) safe_cols - indent_width else 1;
        const last_row = row_count + 1 == max_rows;
        if (last_row and display_width.rowWidthIgnoringAnsi(remaining) > available) {
            const marker = omissionMarker(@intCast(@min(available, std.math.maxInt(u16))));
            const content_width = available -| marker.len;
            if (preserve_trailing_context) {
                const suffix = display_width.suffixByWidthIgnoringAnsi(remaining, content_width);
                try appendStaticActivityLine(&out.writer, prefix, continuation_indent_width, marker, first);
                try out.writer.writeAll(suffix);
            } else {
                // A bare mark stays whole on its row, so with no cell left for
                // text the row holds the omission marker alone.
                var chunk = if (content_width == 0)
                    remaining[0..0]
                else
                    display_width.rowWrapCutIgnoringAnsi(remaining, content_width);
                if (chunk.len == 0 and content_width > 0) {
                    const unit = display_width.displayUnitAt(remaining, 0);
                    chunk = remaining[0..unit.byte_len];
                }
                try appendStaticActivityLine(&out.writer, prefix, continuation_indent_width, chunk, first);
                try out.writer.writeAll(marker);
            }
            remaining = "";
        } else {
            var chunk = display_width.rowWrapCutIgnoringAnsi(remaining, available);
            if (chunk.len == 0) {
                const unit = display_width.displayUnitAt(remaining, 0);
                chunk = remaining[0..unit.byte_len];
            }
            try appendStaticActivityLine(&out.writer, prefix, continuation_indent_width, chunk, first);
            remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        }
        row_count += 1;
        first = false;
    }

    if (row.len == 0) try out.writer.writeAll(row);
    const allocation = try out.toOwnedSlice();
    return .{ .bytes = allocation, .allocation = allocation };
}

pub fn paintActivityIntoSurface(
    surface: *frame_surface.FrameSurface,
    input: ActivityPaintInput,
) !paint_plan.ActivityPaintResult {
    return switch (surface.plan.activity) {
        .none => .{ .painted = false, .row = 0, .overlay = false },
        .transient_row => |activity| blk: {
            if (activity.tool_row) |tool_row| {
                const tool_label = input.tool_label orelse return error.MissingToolActivityLabel;
                _ = try paintPlannedActivityRow(surface, .{
                    .label = tool_label,
                    .shimmer_pos = input.shimmer_pos,
                    .style = .tool_marker,
                }, tool_row, false);
            }
            const primary = if (activity.tool_row == null) if (input.tool_label) |tool_label|
                ActivityPaintInput{
                    .label = tool_label,
                    .shimmer_pos = input.shimmer_pos,
                    .style = .tool_marker,
                }
            else
                input else input;
            break :blk try paintPlannedActivityRow(surface, primary, activity.row, false);
        },
        .overlay_entry => |row| try paintPlannedActivityRow(surface, input, row, true),
    };
}

fn paintPlannedActivityRow(
    surface: *frame_surface.FrameSurface,
    input: ActivityPaintInput,
    row: u16,
    overlay: bool,
) !paint_plan.ActivityPaintResult {
    if (overlay) {
        if (!surface.plan.transcript_band.containsRow(row)) return error.WriteOutsideBand;
    } else {
        if (!surface.plan.activity_band.containsRow(row)) return error.WriteOutsideBand;
    }

    traceSurfaceShimmerPaint(surface, row, input.label);

    const max_rows = if (overlay)
        @as(u16, 1)
    else
        surface.plan.activity_band.bottom -| row +| 1;
    const static_status = switch (input.style) {
        .live, .neutral, .warning, .success, .danger => true,
        .thinking, .tool_marker => false,
    };
    const preserve_trailing_context = switch (input.style) {
        .warning, .danger => true,
        .thinking, .live, .tool_marker, .neutral, .success => false,
    };
    const preview = if (static_status)
        try wrappedStaticActivityLabel(
            surface.alloc,
            input.label,
            surface.cols,
            max_rows,
            preserve_trailing_context,
        )
    else
        try previewActivityRowLabel(surface.alloc, input.label, surface.cols);
    defer preview.deinit(surface.alloc);
    var buf: [4096]u8 = undefined;
    const text = switch (input.style) {
        .thinking, .live => writeThinkingBlinkText(
            &buf,
            preview.bytes,
            input.thinking_blink orelse markerBlinkVisible(input.shimmer_pos),
        ),
        .tool_marker => writeToolMarkerBlinkText(&buf, preview.bytes, input.shimmer_pos),
        .neutral => writeStaticStyledText(&buf, preview.bytes, ui_render.dim_style),
        .warning => writeStaticStyledText(&buf, preview.bytes, ui_render.warning_style),
        .success => writeStaticStyledText(&buf, preview.bytes, ui_render.green_style),
        .danger => writeStaticStyledText(&buf, preview.bytes, ui_render.red_style),
    };
    const result = if (static_status and max_rows > 1)
        try surface.writeAnsiBandNoWrap(
            row,
            max_rows,
            text,
            .activity,
            if (overlay) .activity_over_transcript else .same_owner,
        )
    else
        try surface.writeAnsiBandNoWrap(
            row,
            1,
            text,
            .activity,
            if (overlay) .activity_over_transcript else .same_owner,
        );
    std.debug.assert(result.rows_touched <= max_rows);

    return .{
        .painted = true,
        .row = row,
        .overlay = overlay,
    };
}

// A steady on/off blink with no fade. Folding in the padding keeps the phase
// non-negative so the blink wraps seamlessly across the fixed cycle.
fn markerBlinkVisible(shimmer_pos: i16) bool {
    const half = render_request.blink_half_period_frames;
    return @mod(shimmer_pos + render_request.animation_padding, 2 * half) < half;
}

fn writeThinkingBlinkText(out: []u8, label: []const u8, marker_visible: bool) []const u8 {
    const marker = "•";
    if (!std.mem.startsWith(u8, label, marker)) {
        return writeStaticStyledText(out, label, ui_render.dim_style);
    }
    var w: std.Io.Writer = .fixed(out);
    if (marker_visible) {
        w.print("{s}{s}{s}", .{ ui_render.permission_auto_style, marker, ui_render.reset_style }) catch return label;
    } else {
        w.writeAll(" ") catch return label;
    }
    const rest = label[marker.len..];
    // The token suffix recedes into the muted gray; the verb and elapsed
    // counter keep the brighter label gray.
    if (std.mem.find(u8, rest, " (↑")) |token_suffix| {
        w.print("{s}{s}{s}{s}{s}", .{
            ui_render.permission_auto_style,
            rest[0..token_suffix],
            ui_render.dim_style,
            rest[token_suffix..],
            ui_render.reset_style,
        }) catch return label;
    } else {
        w.print("{s}{s}{s}", .{
            ui_render.permission_auto_style,
            rest,
            ui_render.reset_style,
        }) catch return label;
    }
    return w.buffered();
}

test "thinking blink keeps the counter bright and dims only the token suffix" {
    var out: [256]u8 = undefined;
    const result = writeThinkingBlinkText(&out, "• Thinking (5s) (↑10 ↓20)", true);

    const label_idx = std.mem.find(u8, result, "Thinking (5s)") orelse return error.TestUnexpectedResult;
    const dim_idx = std.mem.find(u8, result, ui_render.dim_style) orelse return error.TestUnexpectedResult;
    const tokens_idx = std.mem.find(u8, result, "(↑10 ↓20)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(label_idx < dim_idx);
    try std.testing.expect(dim_idx < tokens_idx);

    const plain = writeThinkingBlinkText(&out, "• Thinking (5s)", true);
    try std.testing.expect(std.mem.find(u8, plain, ui_render.dim_style) == null);
}

test "marker blink is on and off for equal halves of the 40-frame cycle" {
    var on: usize = 0;
    var pos: i16 = -8;
    while (pos <= 31) : (pos += 1) {
        if (markerBlinkVisible(pos)) on += 1;
    }
    try std.testing.expectEqual(@as(usize, 20), on);
    try std.testing.expect(!markerBlinkVisible(31));
    try std.testing.expect(markerBlinkVisible(-8));
}

fn writeStaticStyledText(out: []u8, label: []const u8, style: []const u8) []const u8 {
    const required = style.len + label.len + ui_render.reset_style.len;
    if (required > out.len) return label;
    var end: usize = 0;
    @memcpy(out[end .. end + style.len], style);
    end += style.len;
    @memcpy(out[end .. end + label.len], label);
    end += label.len;
    @memcpy(out[end .. end + ui_render.reset_style.len], ui_render.reset_style);
    end += ui_render.reset_style.len;
    return out[0..end];
}

test "activity status styles paint static colored text" {
    var buf: [128]u8 = undefined;
    const result = writeStaticStyledText(&buf, "⚠ API error", ui_render.warning_style);
    var expected_buf: [128]u8 = undefined;
    const expected = std.mem.print(
        &expected_buf,
        "{s}⚠ API error{s}",
        .{ ui_render.warning_style, ui_render.reset_style },
    ) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, result);
}

fn writeToolMarkerBlinkText(out: []u8, label: []const u8, shimmer_pos: i16) []const u8 {
    var marker_start: usize = 0;
    while (marker_start < label.len and label[marker_start] == 0x1b) {
        const ansi_end = display_width.ansiSequenceEnd(label, marker_start);
        if (ansi_end <= marker_start) break;
        marker_start = ansi_end;
    }
    const marker_unit = display_width.displayUnitAt(label, marker_start);
    if (marker_unit.byte_len == 0) return label;
    const marker_end = @min(marker_start + marker_unit.byte_len, label.len);
    const marker = label[marker_start..marker_end];
    if (!std.mem.eql(u8, marker, "●") and !std.mem.eql(u8, marker, "└")) return label;

    var marker_buf: [64]u8 = undefined;
    var marker_writer: std.Io.Writer = .fixed(&marker_buf);
    if (markerBlinkVisible(shimmer_pos)) {
        marker_writer.print("{s}{s}{s}", .{
            ui_render.permission_auto_style,
            label[marker_start..marker_end],
            ui_render.reset_style,
        }) catch return label;
    } else {
        marker_writer.writeAll(" ") catch return label;
    }
    const animated_marker = marker_writer.buffered();
    const prefix = label[0..marker_start];
    const suffix = label[marker_end..];
    const required = prefix.len * 2 + animated_marker.len + suffix.len + ui_render.reset_style.len;
    if (required > out.len) return label;

    var end: usize = 0;
    @memcpy(out[end .. end + prefix.len], prefix);
    end += prefix.len;
    @memcpy(out[end .. end + animated_marker.len], animated_marker);
    end += animated_marker.len;
    @memcpy(out[end .. end + prefix.len], prefix);
    end += prefix.len;
    @memcpy(out[end .. end + suffix.len], suffix);
    end += suffix.len;
    @memcpy(out[end .. end + ui_render.reset_style.len], ui_render.reset_style);
    end += ui_render.reset_style.len;
    return out[0..end];
}

test "tool marker shimmer accepts the minimal final connector" {
    var out: [256]u8 = undefined;
    const result = writeToolMarkerBlinkText(&out, "└ Running zig build", 0);
    try std.testing.expect(std.mem.find(u8, result, "Running zig build") != null);
    try std.testing.expect(!std.mem.eql(u8, result, "└ Running zig build"));

    const unchanged = writeToolMarkerBlinkText(&out, "├ Read runtime.zig", 0);
    try std.testing.expectEqualStrings("├ Read runtime.zig", unchanged);
}

fn traceSurfaceShimmerPaint(surface: *const frame_surface.FrameSurface, row: u16, label: []const u8) void {
    debug_trace.logf(
        "paint",
        surface_shimmer_paint_trace_fmt,
        .{
            row,
            if (row >= 1 and row <= surface.rows) "true" else "false",
            if (surface.plan.footer_band.containsRow(row)) "true" else "false",
            label.len,
            std.hash.Wyhash.hash(0, label),
        },
    );
}

fn testPlan(
    activity: render_engine.activity_overlay.ActivityPlacement,
    activity_band: paint_plan.FrameBand,
) paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 6,
            .cols = 32,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 5,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 3,
        },
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 5,
            .picker_divider = 5,
            .picker_start = 6,
            .bottom_divider = 5,
            .hint = 6,
            .total_rows = 2,
        },
        .activity = activity,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 4, .owner = .transcript },
        .activity_band = activity_band,
        .footer_band = .{ .top = 5, .bottom = 6, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 5, .col = 1, .visible = true },
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn testSurface(plan: paint_plan.PaintPlan) !struct {
    shadow: vt_emulator.Grid,
    surface: frame_surface.FrameSurface,
} {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, plan.layout.cols, plan.layout.rows);
    errdefer shadow.deinit();
    try shadow.feed("\x1b[1;1Hshell");

    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    errdefer surface.deinit();
    return .{ .shadow = shadow, .surface = surface };
}

test "activity surface painter writes transient activity only on planned row" {
    var fixtures = try testSurface(testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    ));
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{ .label = "thinking", .shimmer_pos = 0 });

    try std.testing.expect(result.painted);
    try std.testing.expect(!result.overlay);
    try std.testing.expectEqual(@as(u16, 4), result.row);
    try std.testing.expectEqual(@as(u21, 't'), fixtures.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.activity, fixtures.surface.cellAt(4, 1).?.owner);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.transcript, fixtures.surface.cellAt(3, 1).?.owner);
    try std.testing.expectEqual(paint_plan.CellOwner.footer, fixtures.surface.cellAt(5, 1).?.owner);
}

test "activity surface painter clamps long transient label to one row" {
    var plan = testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    );
    plan.layout.cols = 8;
    var fixtures = try testSurface(plan);
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "abcdefghijklmnopqrstuvwxyz",
        .shimmer_pos = -8,
    });

    try std.testing.expect(result.painted);
    try std.testing.expectEqual(@as(u16, 4), result.row);
    try std.testing.expectEqual(@as(u21, 'a'), fixtures.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, '.'), fixtures.surface.cellAt(4, 6).?.codepoint);
    try std.testing.expectEqual(@as(u21, '.'), fixtures.surface.cellAt(4, 7).?.codepoint);
    try std.testing.expectEqual(@as(u21, '.'), fixtures.surface.cellAt(4, 8).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(5, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.footer, fixtures.surface.cellAt(5, 1).?.owner);
}

test "activity surface painter wraps static status labels under marker" {
    var plan = testPlan(
        .{ .transient_row = .{ .row = 3, .row_count = 3, .gap_above_rows = 0 } },
        .{ .top = 3, .bottom = 5, .owner = .activity },
    );
    plan.layout.rows = 7;
    plan.layout.cols = 42;
    plan.footer_band = .{ .top = 6, .bottom = 7, .owner = .footer };
    plan.footer.top = 6;
    plan.footer.top_divider = 6;
    plan.footer.banner = 6;
    plan.footer.input_base = 6;
    plan.footer.picker_divider = 6;
    plan.footer.picker_start = 7;
    plan.footer.bottom_divider = 6;
    plan.footer.hint = 7;

    var fixtures = try testSurface(plan);
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "⚠ API access denied · HTTP 403 · Provider: wafer · Your team has restricted access to this provider. Contact the owner of the account.",
        .shimmer_pos = -8,
        .style = .danger,
    });

    try std.testing.expect(result.painted);
    try std.testing.expectEqual(@as(u16, 3), result.row);
    try std.testing.expectEqual(@as(u21, '⚠'), fixtures.surface.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(4, 2).?.codepoint);
    try std.testing.expect(fixtures.surface.cellAt(4, 3).?.codepoint != ' ');
    try std.testing.expectEqual(paint_plan.CellOwner.activity, fixtures.surface.cellAt(5, 1).?.owner);
    try std.testing.expectEqual(paint_plan.CellOwner.footer, fixtures.surface.cellAt(6, 1).?.owner);
    try fixtures.surface.validate();
}

test "static status truncation preserves recovery action and attempt suffix" {
    const preview = try wrappedStaticActivityLabel(
        std.testing.allocator,
        "⚠ Provider unavailable · no_available_providers: No providers are currently available · retrying request in 4s · attempt 4/10",
        32,
        3,
        true,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, preview.bytes, "⚠ Provider unavailable ·"));
    try std.testing.expect(std.mem.find(u8, preview.bytes, "no_available_providers:") != null);
    try std.testing.expect(std.mem.find(u8, preview.bytes, "...") != null);
    try std.testing.expect(std.mem.endsWith(u8, preview.bytes, "attempt 4/10"));

    var lines = std.mem.splitScalar(u8, preview.bytes, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        line_count += 1;
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 32);
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);
}

test "static status truncation preserves leading context for non-error statuses" {
    const preview = try wrappedStaticActivityLabel(
        std.testing.allocator,
        "✓ Recovered · resumed after provider retry · later details are omitted",
        24,
        2,
        false,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, preview.bytes, "✓ Recovered · resumed"));
    try std.testing.expect(std.mem.endsWith(u8, preview.bytes, "..."));
    try std.testing.expect(std.mem.find(u8, preview.bytes, "later details") == null);
}

test "activity surface painter breaks static status rows at word boundaries" {
    var plan = testPlan(
        .{ .transient_row = .{ .row = 3, .row_count = 2, .gap_above_rows = 0 } },
        .{ .top = 3, .bottom = 4, .owner = .activity },
    );
    plan.layout.cols = 12;
    var fixtures = try testSurface(plan);
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "⚠ aaaaaa bbbb",
        .shimmer_pos = -8,
        .style = .danger,
    });

    try std.testing.expect(result.painted);
    try std.testing.expectEqual(@as(u21, '⚠'), fixtures.surface.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'a'), fixtures.surface.cellAt(3, 8).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(3, 10).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(4, 2).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), fixtures.surface.cellAt(4, 3).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), fixtures.surface.cellAt(4, 6).?.codepoint);
    try fixtures.surface.validate();
}

test "static status row that starts with a bare mark is drawn on a dotted circle in a cell of its own" {
    const alloc = std.testing.allocator;

    // The text after the status sign starts its row after a cell that is no
    // base for a mark, so a mark that starts it takes a circle of its own, and
    // so does one that starts a row after a soft break at a space. A mark on a
    // base gets none.
    const first = try wrappedStaticActivityLabel(alloc, "⚠ \u{0E49}abc", 40, 3, false);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("⚠ \u{25CC}\u{0E49}abc", first.bytes);

    const on_base = try wrappedStaticActivityLabel(alloc, "⚠ a\u{0E49}bc", 40, 3, false);
    defer on_base.deinit(alloc);
    try std.testing.expectEqualStrings("⚠ a\u{0E49}bc", on_base.bytes);

    const soft = try wrappedStaticActivityLabel(alloc, "⚠ aaaa \u{0E49}bbb", 8, 3, false);
    defer soft.deinit(alloc);
    try std.testing.expectEqualStrings("⚠ aaaa\n  \u{25CC}\u{0E49}bbb", soft.bytes);

    // The same for a label that is cut with an omission marker.
    const cut = try wrappedStaticActivityLabel(alloc, "⚠ \u{0E49}abcdefghijklmnopqrstuvwxyz", 12, 1, false);
    defer cut.deinit(alloc);
    try std.testing.expectEqualStrings("⚠ \u{25CC}\u{0E49}abcdef...", cut.bytes);
}

test "static status counts the circle of a bare mark in its rows at every width" {
    const alloc = std.testing.allocator;
    const label = "⚠ \u{0E49}abcdefghijklmnopqrstuvwxyz0123456789";

    // The circle takes one of the cells after the sign, so each row keeps
    // inside the width, the circle is drawn once, and no letter is lost.
    var cols: u16 = 4;
    while (cols <= 48) : (cols += 1) {
        const preview = try wrappedStaticActivityLabel(alloc, label, cols, 40, false);
        defer preview.deinit(alloc);
        var lines = std.mem.splitScalar(u8, preview.bytes, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, preview.bytes, "\u{25CC}"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, preview.bytes, "a"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, preview.bytes, "z"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, preview.bytes, "9"));
    }

    // A label cut after its second row keeps inside the width as well, down to
    // a row with no cell left for text after the omission marker.
    cols = 4;
    while (cols <= 48) : (cols += 1) {
        for ([_]bool{ false, true }) |preserve_trailing_context| {
            const preview = try wrappedStaticActivityLabel(alloc, label, cols, 2, preserve_trailing_context);
            defer preview.deinit(alloc);
            var lines = std.mem.splitScalar(u8, preview.bytes, '\n');
            var line_count: usize = 0;
            while (lines.next()) |line| : (line_count += 1) {
                try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            }
            try std.testing.expect(line_count <= 2);
            if (cols <= 20) try std.testing.expectEqual(@as(usize, 2), line_count);
        }
    }

    // The bare mark of a row after a soft break is the last row's whole text
    // when the row has no cell left for text after the omission marker.
    cols = 4;
    while (cols <= 8) : (cols += 1) {
        const preview = try wrappedStaticActivityLabel(alloc, "⚠ aaa \u{0E49}bbbbbb", cols, 2, false);
        defer preview.deinit(alloc);
        var lines = std.mem.splitScalar(u8, preview.bytes, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }
}

test "activity surface painter draws a status row that starts with a bare mark on a circle" {
    var plan = testPlan(
        .{ .transient_row = .{ .row = 3, .row_count = 2, .gap_above_rows = 0 } },
        .{ .top = 3, .bottom = 4, .owner = .activity },
    );
    plan.layout.cols = 8;
    var fixtures = try testSurface(plan);
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "⚠ aaaa \u{0E49}bbb",
        .shimmer_pos = -8,
        .style = .danger,
    });

    try std.testing.expect(result.painted);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(4, 2).?.codepoint);
    try std.testing.expectEqual(@as(u21, 0x25CC), fixtures.surface.cellAt(4, 3).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), fixtures.surface.cellAt(4, 4).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), fixtures.surface.cellAt(4, 6).?.codepoint);
    try fixtures.surface.validate();
}

test "activity surface painter falls back to the tool label when the stack cannot fit" {
    var fixtures = try testSurface(testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    ));
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    _ = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "• Thinking",
        .tool_label = "● Running read_file",
        .shimmer_pos = 0,
    });

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    var target = try fixtures.surface.copyToTargetGrid(std.testing.allocator);
    defer target.deinit();
    try target.rowText(4, &row);
    try std.testing.expect(std.mem.find(u8, row.items, "Running read_file") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Thinking") == null);
}

test "activity surface painter uses width-fitting omission markers" {
    const Case = struct {
        cols: u16,
        marker: []const u8,
    };
    const cases = [_]Case{
        .{ .cols = 1, .marker = "." },
        .{ .cols = 2, .marker = ".." },
        .{ .cols = 3, .marker = "..." },
    };

    for (cases) |case| {
        var plan = testPlan(
            .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
            .{ .top = 4, .bottom = 4, .owner = .activity },
        );
        plan.layout.cols = case.cols;
        var fixtures = try testSurface(plan);
        defer fixtures.surface.deinit();
        defer fixtures.shadow.deinit();

        const result = try paintActivityIntoSurface(&fixtures.surface, .{
            .label = "\x1b[1mabcdefg\x1b[0m",
            .shimmer_pos = -8,
        });

        try std.testing.expect(result.painted);
        for (case.marker, 0..) |byte, index| {
            try std.testing.expectEqual(@as(u21, byte), fixtures.surface.cellAt(4, @intCast(index + 1)).?.codepoint);
        }
        try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(5, 1).?.codepoint);
        try std.testing.expectEqual(paint_plan.CellOwner.footer, fixtures.surface.cellAt(5, 1).?.owner);
        try fixtures.surface.validate();
    }
}

test "activity surface painter treats multiline transient label as one row" {
    var plan = testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    );
    plan.layout.cols = 12;
    var fixtures = try testSurface(plan);
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{
        .label = "cat > ~/Desktop/hello-world.html <<'EOF'\n<html>\nEOF",
        .shimmer_pos = -8,
    });

    try std.testing.expect(result.painted);
    try std.testing.expectEqual(@as(u16, 4), result.row);
    try std.testing.expectEqual(@as(u21, 'c'), fixtures.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, '.'), fixtures.surface.cellAt(4, 12).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(5, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.footer, fixtures.surface.cellAt(5, 1).?.owner);
}

test "activity surface painter overlays planned transcript row" {
    var fixtures = try testSurface(testPlan(
        .{ .overlay_entry = 3 },
        paint_plan.FrameBand.empty(.activity),
    ));
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    _ = try fixtures.surface.writeAnsiBand(3, 1, "body", .transcript, .same_owner);
    try std.testing.expectEqual(@as(u21, 'b'), fixtures.surface.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.transcript, fixtures.surface.cellAt(3, 1).?.owner);

    const result = try paintActivityIntoSurface(&fixtures.surface, .{ .label = "go", .shimmer_pos = 0 });

    try std.testing.expect(result.painted);
    try std.testing.expect(result.overlay);
    try std.testing.expectEqual(@as(u16, 3), result.row);
    try std.testing.expectEqual(@as(u21, 'g'), fixtures.surface.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.activity, fixtures.surface.cellAt(3, 1).?.owner);
    try fixtures.surface.validate();
}

test "activity surface painter limits tool animation to its marker" {
    const plan = testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    );
    var first = try testSurface(plan);
    defer first.surface.deinit();
    defer first.shadow.deinit();
    var second = try testSurface(plan);
    defer second.surface.deinit();
    defer second.shadow.deinit();

    const label = "● Running command\x1b[0m";
    _ = try paintActivityIntoSurface(&first.surface, .{
        .label = label,
        .shimmer_pos = -8,
        .style = .tool_marker,
    });
    _ = try paintActivityIntoSurface(&second.surface, .{
        .label = label,
        .shimmer_pos = 4,
        .style = .tool_marker,
    });

    const first_marker = first.surface.cellAt(4, 1).?;
    const second_marker = second.surface.cellAt(4, 1).?;
    const first_text = first.surface.cellAt(4, 3).?;
    const second_text = second.surface.cellAt(4, 3).?;
    try std.testing.expectEqual(@as(u21, '●'), first_marker.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), second_marker.codepoint);
    try std.testing.expect(first_text.style.eql(second_text.style));
    try std.testing.expect(!first_text.style.flags.bold);

    _ = try paintActivityIntoSurface(&first.surface, .{
        .label = "thinking",
        .shimmer_pos = -8,
        .style = .thinking,
    });
    _ = try paintActivityIntoSurface(&second.surface, .{
        .label = "thinking",
        .shimmer_pos = 0,
        .style = .thinking,
    });
    try std.testing.expect(first.surface.cellAt(4, 1).?.style.fg.eql(second.surface.cellAt(4, 1).?.style.fg));
}

test "activity surface painter honors the thinking blink override" {
    const plan = testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    );
    var hidden = try testSurface(plan);
    defer hidden.surface.deinit();
    defer hidden.shadow.deinit();
    var visible = try testSurface(plan);
    defer visible.surface.deinit();
    defer visible.shadow.deinit();

    _ = try paintActivityIntoSurface(&hidden.surface, .{
        .label = "• Thinking (1s)",
        .shimmer_pos = -render_request.animation_padding,
        .thinking_blink = false,
    });
    _ = try paintActivityIntoSurface(&visible.surface, .{
        .label = "• Thinking (1s)",
        .shimmer_pos = 4,
        .thinking_blink = true,
    });

    try std.testing.expectEqual(@as(u21, ' '), hidden.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, '•'), visible.surface.cellAt(4, 1).?.codepoint);
}

test "activity surface painter blinks the live bullet with the thinking row" {
    const plan = testPlan(
        .{ .transient_row = .{ .row = 4, .gap_above_rows = 0 } },
        .{ .top = 4, .bottom = 4, .owner = .activity },
    );
    var hidden = try testSurface(plan);
    defer hidden.surface.deinit();
    defer hidden.shadow.deinit();
    var visible = try testSurface(plan);
    defer visible.surface.deinit();
    defer visible.shadow.deinit();

    // A retry status blinks its bullet in step with the thinking row, and
    // its text holds still.
    _ = try paintActivityIntoSurface(&hidden.surface, .{
        .label = "• Gateway error · retrying · attempt 2",
        .style = .live,
        .shimmer_pos = -render_request.animation_padding,
        .thinking_blink = false,
    });
    _ = try paintActivityIntoSurface(&visible.surface, .{
        .label = "• Gateway error · retrying · attempt 2",
        .style = .live,
        .shimmer_pos = 4,
        .thinking_blink = true,
    });
    try std.testing.expectEqual(@as(u21, ' '), hidden.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, '•'), visible.surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'G'), hidden.surface.cellAt(4, 3).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'G'), visible.surface.cellAt(4, 3).?.codepoint);
}

test "activity surface painter rejects activity over footer" {
    var fixtures = try testSurface(testPlan(
        .{ .overlay_entry = 5 },
        paint_plan.FrameBand.empty(.activity),
    ));
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    try std.testing.expectError(
        error.WriteOutsideBand,
        paintActivityIntoSurface(&fixtures.surface, .{ .label = "go", .shimmer_pos = 0 }),
    );
}

test "activity surface painter skips none placement without writing cells" {
    var fixtures = try testSurface(testPlan(
        .none,
        paint_plan.FrameBand.empty(.activity),
    ));
    defer fixtures.surface.deinit();
    defer fixtures.shadow.deinit();

    const result = try paintActivityIntoSurface(&fixtures.surface, .{ .label = "hidden", .shimmer_pos = 0 });

    try std.testing.expect(!result.painted);
    try std.testing.expect(!result.overlay);
    try std.testing.expectEqual(@as(u16, 0), result.row);
    try std.testing.expectEqual(@as(u21, ' '), fixtures.surface.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(paint_plan.CellOwner.transcript, fixtures.surface.cellAt(2, 1).?.owner);
}

test "activity paint trace formats omit label payload" {
    const label = "secret prompt text";
    const label_hash = std.hash.Wyhash.hash(0, label);

    var surface_buf: [256]u8 = undefined;
    const surface_line = try std.mem.print(
        &surface_buf,
        surface_shimmer_paint_trace_fmt,
        .{ @as(u16, 3), "true", "false", label.len, label_hash },
    );
    try std.testing.expect(std.mem.find(u8, surface_line, "label=\"") == null);
    try std.testing.expect(std.mem.find(u8, surface_line, label) == null);
}
