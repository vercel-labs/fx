const std = @import("std");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const activity_overlay = @import("activity_overlay.zig");
const frame_layout = @import("frame_layout.zig");

pub fn resolve(
    projection: activity_runtime.ActivityProjection,
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    return switch (projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            resolveToolSlot(slot, activity, layout)
        else
            .none,
        .turn_thinking => resolveTransient(activity, layout),
    };
}

fn resolveToolSlot(
    slot: activity_runtime.ActivityProjection.ToolSlot,
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    const placement = resolveTransient(activity, layout);
    if (slot.thinking_label == null) return placement;
    return switch (placement) {
        .transient_row => |transient| if (layout.tool_activity_row) |tool_row|
            .{ .transient_row = .{
                .row = transient.row,
                .row_count = transient.row_count,
                .gap_above_rows = transient.gap_above_rows,
                .footer_clearance_rows = transient.footer_clearance_rows,
                .tool_row = tool_row,
            } }
        else
            placement,
        .none, .overlay_entry => placement,
    };
}

fn resolveTransient(
    activity: frame_layout.ActivityState,
    layout: frame_layout.FrameLayout,
) activity_overlay.ActivityPlacement {
    return switch (activity) {
        .thinking => |thinking| if (layout.activity_row) |row|
            .{ .transient_row = .{
                .row = row,
                .row_count = @max(layout.activity_rows, 1),
                .gap_above_rows = thinking.gap_above_activity,
                .footer_clearance_rows = thinking.footer_gap_after_activity,
            } }
        else
            .none,
        .overlay_entry => |row| if (layout.transcript_area.containsRow(row))
            .{ .overlay_entry = row }
        else
            .none,
        .none => .none,
    };
}

fn testLayout() frame_layout.FrameLayout {
    return frame_layout.solve(.{
        .terminal = .{
            .rows = 12,
            .cols = 80,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top = 1,
        .footer = .{ .natural_rows = 4, .min_rows = 1, .max_rows = 4 },
        .transcript = .{ .natural_visual_rows = 5 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });
}

test "activity placement maps projection only through solved layout" {
    const layout = testLayout();

    try std.testing.expectEqual(
        activity_overlay.ActivityPlacement.none,
        resolve(.none, .none, layout),
    );
    switch (resolve(
        .{ .turn_thinking = .{ .label = "thinking" } },
        .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } },
        layout,
    )) {
        .transient_row => |activity| {
            try std.testing.expectEqual(layout.activity_row.?, activity.row);
            try std.testing.expectEqual(@as(u16, 1), activity.gap_above_rows);
            try std.testing.expectEqual(@as(u16, 1), activity.footer_clearance_rows);
        },
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(
        activity_overlay.ActivityPlacement.none,
        resolve(
            .{ .turn_thinking = .{ .label = "thinking" } },
            .{ .overlay_entry = 99 },
            layout,
        ),
    );
}

test "active tool slot stays transient when its entry is visible" {
    const layout = frame_layout.solve(.{
        .terminal = .{
            .rows = 12,
            .cols = 80,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top = 1,
        .footer = .{ .natural_rows = 4, .min_rows = 1, .max_rows = 4 },
        .transcript = .{ .natural_visual_rows = 8 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });
    const active = activity_runtime.ActivityProjection{ .tool_slot = .{
        .entry_id = 9,
        .fallback_label = "running",
        .active = true,
        .kind = .command,
    } };

    switch (resolve(
        active,
        .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } },
        layout,
    )) {
        .transient_row => |placement| {
            try std.testing.expectEqual(layout.activity_row.?, placement.row);
            try std.testing.expectEqual(@as(u16, 1), placement.gap_above_rows);
            try std.testing.expectEqual(@as(u16, 1), placement.footer_clearance_rows);
        },
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }

    var terminal = active;
    terminal.tool_slot.active = false;
    try std.testing.expectEqual(
        activity_overlay.ActivityPlacement.none,
        resolve(
            terminal,
            .{ .thinking = .{ .gap_above_activity = 1 } },
            layout,
        ),
    );
}
