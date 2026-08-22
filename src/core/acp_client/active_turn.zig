const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Shared state for one ACP agent turn running off the UI thread. The UI
/// thread owns `update` (drained once per tick); the turn thread owns
/// everything below it while `running` is set.
pub const ActiveTurn = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    /// Update text queued for the UI thread. Empty means nothing pending.
    update: std.ArrayList(u8) = .empty,
    /// Agent name shown with each streamed update.
    agent_name: []u8,
    running: bool = true,
    /// Set by the UI thread when the user interrupts the turn.
    cancel_requested: bool = false,
    /// Set once the turn thread finished; the UI thread joins and frees.
    finished: bool = false,
    turn_thread: ?std.Thread = null,
    /// Display text for the final block (owned by `alloc`). Present once
    /// `finished` is set and the outcome rendered successfully.
    result_text: ?[]u8 = null,
    /// True when the turn failed and the text should render as a warning.
    result_is_warning: bool = false,
    /// Model value ids cached from the run (owned by `alloc`).
    model_values: []const []const u8 = &.{},
    /// Reasoning-effort value ids cached from the run (owned by `alloc`).
    effort_values: []const []const u8 = &.{},

    pub fn init(alloc: Allocator, agent_name: []const u8) !*ActiveTurn {
        const self = try alloc.create(ActiveTurn);
        self.* = .{
            .alloc = alloc,
            .agent_name = try alloc.dupe(u8, agent_name),
        };
        return self;
    }

    pub fn deinit(self: *ActiveTurn) void {
        if (self.turn_thread) |thread| thread.join();
        if (self.result_text) |text| self.alloc.free(text);
        self.update.deinit(self.alloc);
        for (self.model_values) |value| self.alloc.free(value);
        self.alloc.free(self.model_values);
        for (self.effort_values) |value| self.alloc.free(value);
        self.alloc.free(self.effort_values);
        self.alloc.free(self.agent_name);
        self.alloc.destroy(self);
    }

    /// Called from the reader thread. Appends `text` to the pending update
    /// buffer the UI thread drains.
    pub fn appendUpdate(self: *ActiveTurn, text: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.update.appendSlice(self.alloc, text) catch return;
    }

    /// Called from the UI thread. Returns the accumulated update text,
    /// clearing the buffer. Caller frees.
    pub fn takeUpdate(self: *ActiveTurn, alloc: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.update.items.len == 0) return null;
        const text = try alloc.dupe(u8, self.update.items);
        self.update.clearRetainingCapacity();
        return text;
    }

    /// Called from the UI thread to interrupt the active turn.
    pub fn requestCancel(self: *ActiveTurn) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.cancel_requested = true;
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn cancelRequested(self: *ActiveTurn) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.cancel_requested;
    }

    /// Turn-thread side: true once the UI thread asked to cancel.
    pub fn cancelRequestedTurnThread(self: *ActiveTurn) bool {
        return self.cancelRequested();
    }

    fn markFinished(
        self: *ActiveTurn,
        result_text: ?[]u8,
        is_warning: bool,
        model_values: []const []const u8,
        effort_values: []const []const u8,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.result_text = result_text;
        self.result_is_warning = is_warning;
        self.model_values = model_values;
        self.effort_values = effort_values;
        self.running = false;
        self.finished = true;
    }

    /// Turn-thread side: publishes the outcome and stops running.
    pub fn finishWithOutcome(
        self: *ActiveTurn,
        text: []u8,
        model_values: []const []const u8,
        effort_values: []const []const u8,
    ) void {
        self.markFinished(text, false, model_values, effort_values);
    }

    /// Turn-thread side: publishes a failure and stops running.
    pub fn finishWithFailure(self: *ActiveTurn, text: []u8) void {
        self.markFinished(text, true, &.{}, &.{});
    }
};

test "active turn update buffer drains atomically" {
    const alloc = std.testing.allocator;
    var turn = try ActiveTurn.init(alloc, "gemini");
    defer turn.deinit();

    turn.appendUpdate("hello ");
    turn.appendUpdate("world");

    const drained = (try turn.takeUpdate(alloc)).?;
    defer alloc.free(drained);
    try std.testing.expectEqualStrings("hello world", drained);
    try std.testing.expect(try turn.takeUpdate(alloc) == null);
}

test "active turn cancel flag round-trips" {
    const alloc = std.testing.allocator;
    var turn = try ActiveTurn.init(alloc, "gemini");
    defer turn.deinit();

    try std.testing.expect(!turn.cancelRequested());
    turn.requestCancel();
    try std.testing.expect(turn.cancelRequested());
    try std.testing.expect(turn.cancelRequestedTurnThread());
}

test "active turn outcome publication is visible to the UI thread" {
    const alloc = std.testing.allocator;
    var turn = try ActiveTurn.init(alloc, "gemini");
    defer turn.deinit();

    const text = try alloc.dupe(u8, "done");
    const models = try alloc.alloc([]const u8, 1);
    models[0] = try alloc.dupe(u8, "flash");
    turn.finishWithOutcome(text, models, &.{});

    try std.testing.expect(turn.finished);
    try std.testing.expect(!turn.running);
    try std.testing.expect(!turn.result_is_warning);
    try std.testing.expectEqualStrings("done", turn.result_text.?);
    try std.testing.expectEqual(@as(usize, 1), turn.model_values.len);
    try std.testing.expectEqualStrings("flash", turn.model_values[0]);
}

test "active turn failure publication sets warning" {
    const alloc = std.testing.allocator;
    var turn = try ActiveTurn.init(alloc, "gemini");
    defer turn.deinit();

    const text = try alloc.dupe(u8, "failed");
    turn.finishWithFailure(text);

    try std.testing.expect(turn.finished);
    try std.testing.expect(turn.result_is_warning);
}
