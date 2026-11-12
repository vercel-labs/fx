pub const activity_overlay = @import("render_engine/activity_overlay.zig");
pub const activity_placement = @import("render_engine/activity_placement.zig");
pub const frame_builder = @import("render_engine/frame_builder.zig");
pub const frame_cell_match = @import("render_engine/frame_cell_match.zig");
pub const frame_fixed_point = @import("render_engine/frame_fixed_point.zig");
pub const frame_layout = @import("render_engine/frame_layout.zig");
pub const frame_retention = @import("render_engine/frame_retention.zig");
pub const frame_scroll_plan = @import("render_engine/frame_scroll_plan.zig");
pub const frame_surface = @import("render_engine/frame_surface.zig");
pub const footer_layout = @import("render_engine/footer_layout.zig");
pub const markdown_document = @import("render_engine/markdown_document.zig");
pub const paint_plan = @import("render_engine/paint_plan.zig");
pub const terminal_diff = @import("render_engine/terminal_diff.zig");
pub const transcript_blocks = @import("render_engine/transcript_blocks.zig");
pub const ui_observer = @import("render_engine/ui_observer.zig");
pub const viewport_selection = @import("render_engine/viewport_selection.zig");

comptime {
    _ = activity_placement;
    _ = frame_cell_match;
    _ = frame_fixed_point;
    _ = frame_layout;
    _ = frame_retention;
    _ = frame_scroll_plan;
}
