//! Front door for agents: the per-conversation state the app runs. Code
//! outside `src/core/agents/` imports only this file.

const std = @import("std");
const builtin = @import("builtin");

pub const Agent = @import("agent.zig").Agent;
pub const Role = @import("agent.zig").Role;
pub const max_history_turns = @import("agent.zig").max_history_turns;
pub const ChildRun = @import("child_run.zig").ChildRun;
pub const ChildRunCompletion = @import("child_run.zig").Completion;

/// True when `Host` keeps its conversation state in a `main_agent` field that
/// has `name`. Hosts that carry no agent state answer false. Inline, so the
/// answer is comptime-known at every call site and an untaken branch is never
/// analyzed, exactly like `@hasField`.
pub inline fn hasAgentField(comptime Host: type, comptime name: []const u8) bool {
    if (!@hasField(Host, "main_agent")) return false;
    return @hasField(@FieldType(Host, "main_agent"), name);
}

threadlocal var on_loop_thread: bool = false;
var loop_started = std.atomic.Value(bool).init(false);

/// Marks the calling thread as the main loop's. Called once, when the
/// interactive app starts.
pub fn markLoopThread() void {
    on_loop_thread = true;
    loop_started.store(true, .release);
}

/// An agent's token and search totals are written by its worker during a
/// turn and read by the main loop at any time, so every access that can
/// overlap a running turn goes through these. A single-threaded build has
/// no such overlap, and its targets may lack 64-bit atomics.
pub fn storeTotal(total: *u64, value: u64) void {
    if (comptime builtin.single_threaded) {
        total.* = value;
        return;
    }
    @atomicStore(u64, total, value, .monotonic);
}

/// Adds to a total, saturating as `+|=` does.
pub fn addTotal(total: *u64, value: u64) void {
    if (comptime builtin.single_threaded) {
        total.* +|= value;
        return;
    }
    var current = @atomicLoad(u64, total, .monotonic);
    while (@cmpxchgWeak(u64, total, current, current +| value, .monotonic, .monotonic)) |seen| current = seen;
}

pub fn loadTotal(total: *const u64) u64 {
    if (comptime builtin.single_threaded) return total.*;
    return @atomicLoad(u64, total, .monotonic);
}

/// Asserts, in debug and test builds, that the main loop's own thread is
/// calling once the loop runs: whose transcript the screen holds is the
/// loop's to know, never a worker's. fx builds keep no frame pointers
/// or unwind tables, so the panic names this file's anchor and the reader's
/// return address `caller`, which a driver symbolizes.
pub fn assertLoopThread(caller: usize) void {
    if (comptime !(builtin.is_test or builtin.optimize == .debug)) return;
    if (!loop_started.load(.acquire) or on_loop_thread) return;
    std.debug.panic("screen read off the loop thread: anchor=0x{x} ret=0x{x}", .{ @intFromPtr(&markLoopThread), caller });
}

/// The agent whose transcript `app`'s screen holds, for main-loop screen
/// code only. A test app that has no screen answers with its own agent.
pub fn screenAgentOf(app: anytype) @TypeOf(&app.main_agent) {
    if (comptime !@hasField(@TypeOf(app.*), "screen_owner")) return app.agent();
    assertLoopThread(@returnAddress());
    return app.screen_owner orelse &app.main_agent;
}

test {
    _ = @import("agent.zig");
    _ = @import("child_run.zig");
}

test "an agent's totals are stored, loaded, and added to saturating" {
    var total: u64 = 0;
    storeTotal(&total, 41);
    addTotal(&total, 1);
    try std.testing.expectEqual(@as(u64, 42), loadTotal(&total));
    storeTotal(&total, std.math.maxInt(u64) - 1);
    addTotal(&total, 5);
    try std.testing.expectEqual(std.math.maxInt(u64), loadTotal(&total));
}
