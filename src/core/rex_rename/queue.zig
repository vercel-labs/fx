//! The rename queue's decisions: when a request starts the background task,
//! what the task does next, and what the exit stop leaves. No I/O, no clock,
//! no allocation. The renamer holds a `State` under its mutex and carries out
//! each result. `tests/tla/rex_rename/RexRename.tla` models it.

const std = @import("std");

/// What the main thread and the task share. One title waits at most: a newer
/// one replaces it.
pub const State = struct {
    waiting: bool = false,
    running: bool = false,
    stopped: bool = false,
};

pub const RequestResult = struct {
    state: State,
    /// The caller copies the title into the waiting slot.
    keep_title: bool,
    /// The caller starts the task, after it waits for the last one to end.
    start_task: bool,
};

/// The main thread asks for a title.
pub fn request(state: State) RequestResult {
    if (state.stopped) return .{ .state = state, .keep_title = false, .start_task = false };
    var next = state;
    next.waiting = true;
    next.running = true;
    return .{ .state = next, .keep_title = true, .start_task = !state.running };
}

pub const TakeResult = struct {
    state: State,
    /// The task applies the waiting title. When false, the task ends.
    apply_title: bool,
};

/// The task asks for its next title. It marks itself ended in the same step
/// that finds none, so a request made after this step starts a new task.
pub fn take(state: State) TakeResult {
    var next = state;
    if (state.waiting and !state.stopped) {
        next.waiting = false;
        return .{ .state = next, .apply_title = true };
    }
    next.waiting = false;
    next.running = false;
    return .{ .state = next, .apply_title = false };
}

/// The task could not start. Nothing runs, and the waiting title is dropped.
pub fn startFailed(state: State) State {
    var next = state;
    next.waiting = false;
    next.running = false;
    return next;
}

/// The exit stop: no title applies after it, and no task starts.
pub fn stop(state: State) State {
    var next = state;
    next.stopped = true;
    return next;
}

test "the first request starts the task and later ones only replace the title" {
    const first = request(.{});
    try std.testing.expect(first.keep_title and first.start_task);
    const second = request(first.state);
    try std.testing.expect(second.keep_title and !second.start_task);

    const applied = take(second.state);
    try std.testing.expect(applied.apply_title);
    const ended = take(applied.state);
    try std.testing.expect(!ended.apply_title);
    try std.testing.expect(!ended.state.running);

    // A request after the task ended starts a new one.
    try std.testing.expect(request(ended.state).start_task);
}

test "after the stop no title applies and no task starts" {
    const queued = request(.{});
    const stopped = stop(queued.state);
    try std.testing.expect(!take(stopped).apply_title);
    const late = request(stopped);
    try std.testing.expect(!late.keep_title and !late.start_task);
}

test "a task that cannot start drops its title and lets the next request start one" {
    const queued = request(.{});
    const failed = startFailed(queued.state);
    try std.testing.expect(!failed.waiting and !failed.running);
    try std.testing.expect(request(failed).start_task);
}
