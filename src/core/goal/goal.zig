pub const goal_types = @import("goal_types.zig");
pub const goal_store = @import("goal_store.zig");
pub const goal_service = @import("goal_service.zig");
pub const goal_accounting = @import("goal_accounting.zig");
pub const goal_steering = @import("goal_steering.zig");
pub const goal_tool = @import("goal_tool.zig");
pub const goal_runtime = @import("goal_runtime.zig");

pub const GoalToolContext = goal_tool.GoalToolContext;

test {
    _ = goal_types;
    _ = goal_store;
    _ = goal_service;
    _ = goal_accounting;
    _ = goal_steering;
    _ = goal_tool;
    _ = goal_runtime;
}
