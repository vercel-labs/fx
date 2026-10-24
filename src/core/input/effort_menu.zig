//! State of the `/effort` menu: the reasoning effort levels the current
//! model offers, the one in use, and the one highlighted.

const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// `default`, then every level a model can declare.
pub const max_options = types.ReasoningEffort.max_options + 1;

/// Call `close` with the allocator passed to `open`.
pub const State = struct {
    active: bool = false,
    /// The model whose levels the menu lists.
    model: std.ArrayList(u8) = .empty,
    /// `default`, then the model's levels in the order it declares them.
    options: [max_options]types.ReasoningEffort = undefined,
    option_count: usize = 0,
    /// The level in use when the menu opened.
    current: usize = 0,
    selected: usize = 0,
    /// The first level shown when they do not all fit.
    window_start: usize = 0,

    /// Opens the menu on `model`'s levels with `current` highlighted. A level
    /// the model does not offer highlights `default`. Leaves the state as it
    /// was when the copy of `model` fails.
    pub fn open(
        self: *State,
        alloc: Allocator,
        model: []const u8,
        capabilities: model_capabilities.Capabilities,
        current: types.ReasoningEffort,
    ) Allocator.Error!void {
        try self.model.ensureTotalCapacity(alloc, model.len);
        self.model.clearRetainingCapacity();
        self.model.appendSliceAssumeCapacity(model);
        const declared = capabilities.reasoning_efforts.slice();
        const count = @min(declared.len, max_options - 1);
        self.options[0] = .auto;
        @memcpy(self.options[1 .. count + 1], declared[0..count]);
        self.option_count = count + 1;
        self.current = @min(model_capabilities.reasoningEffortIndex(capabilities, current), count);
        self.selected = self.current;
        self.window_start = 0;
        self.active = true;
    }

    /// Moves the highlight, wrapping past the first and the last level as
    /// the `/model` menu does.
    pub fn move(self: *State, delta: i32) void {
        if (!self.active or self.option_count == 0) return;
        const count: i64 = @intCast(self.option_count);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
    }

    pub fn selectedEffort(self: *const State) ?types.ReasoningEffort {
        if (!self.active or self.option_count == 0) return null;
        return self.options[self.selected];
    }

    pub fn levels(self: *const State) []const types.ReasoningEffort {
        return self.options[0..self.option_count];
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.model.deinit(alloc);
        self.* = .{};
    }
};
