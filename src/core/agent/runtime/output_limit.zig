//! What fx does after a reply that stopped at its output limit.
//!
//! A tool call the provider finished before the cut is whole, so fx runs it;
//! a call cut off mid-arguments never runs. A reply cut before any tool call
//! keeps its text, and the model goes on from where it stopped; a reply cut
//! before any text spent its limit thinking, and the model is asked to take a
//! smaller step. Either way fx tells the model in the same turn what was cut,
//! so it can go on without a person. The third cut reply in a row ends the
//! turn as failed. Pure: no I/O, no clock, no allocation
//! (`tests/tla/agent_runtime/OutputLimit.tla`).

const std = @import("std");

/// Notes fx sends after cut replies in a row. The next cut reply ends the turn
/// (`tests/tla/agent_runtime/OutputLimit.tla` EndsAfterThird).
pub const max_notes_in_a_row: usize = 2;

pub const Reply = struct {
    /// Cut replies in a row before this one. A step that ends without a cut
    /// starts the count again.
    earlier_cuts: usize,
    /// Tool calls the provider finished before the cut, with arguments fx can
    /// read.
    complete_calls: usize,
    /// The complete calls pass the identity checks every finished reply's
    /// calls pass before one runs: ids that are set, distinct, and storable.
    complete_calls_admitted: bool,
    /// Tool calls that started and did not finish, or whose arguments were cut.
    cut_calls: usize,
    /// The reply showed text before the cut.
    text: bool,
    /// A tool the provider runs itself, such as a web search, came back in the
    /// reply, so fx cannot tell the model what did and did not run.
    provider_executed: bool,
    /// The step limit lets fx start another step.
    step_left: bool,
};

pub const Action = enum {
    /// Run the complete calls, then tell the model what was cut.
    run_complete_calls,
    /// Run nothing, and ask the model to do the same work in smaller steps.
    ask_smaller_steps,
    /// The reply started no tool call: keep its text, and ask the model to go
    /// on from where it stopped.
    continue_text,
    /// The reply had no text and no tool call, so it spent its limit
    /// thinking: ask the model to take a smaller step.
    act_now,
    /// End the turn as failed: the notes are spent, no step is left, or a
    /// provider tool ran.
    end_turn,
};

pub fn decide(reply: Reply) Action {
    if (reply.provider_executed) return .end_turn;
    if (reply.earlier_cuts >= max_notes_in_a_row) return .end_turn;
    const tool_cut = reply.complete_calls > 0 or reply.cut_calls > 0;
    // The calls run in this step, as a valid tool reply's do, even when no
    // step is left after it. Calls that fail the identity checks never run.
    if (reply.complete_calls > 0 and reply.complete_calls_admitted) return .run_complete_calls;
    if (!reply.step_left) return .end_turn;
    if (tool_cut) return .ask_smaller_steps;
    return if (reply.text) .continue_text else .act_now;
}

test "a cut reply runs its complete calls, asks for smaller steps or the rest, and ends on the third in a row" {
    const Case = struct { earlier: usize, complete: usize, admitted: bool = true, cut: usize, text: bool = false, provider: bool = false, step_left: bool = true, expected: Action };
    const cases = [_]Case{
        .{ .earlier = 0, .complete = 0, .cut = 0, .text = true, .expected = .continue_text },
        .{ .earlier = 1, .complete = 0, .cut = 0, .text = true, .expected = .continue_text },
        .{ .earlier = 0, .complete = 0, .cut = 0, .expected = .act_now },
        .{ .earlier = 1, .complete = 0, .cut = 0, .expected = .act_now },
        .{ .earlier = 2, .complete = 0, .cut = 0, .text = true, .expected = .end_turn },
        .{ .earlier = 2, .complete = 0, .cut = 0, .expected = .end_turn },
        .{ .earlier = 0, .complete = 0, .cut = 0, .text = true, .step_left = false, .expected = .end_turn },
        .{ .earlier = 0, .complete = 0, .cut = 0, .step_left = false, .expected = .end_turn },
        .{ .earlier = 0, .complete = 0, .cut = 0, .text = true, .provider = true, .expected = .end_turn },
        .{ .earlier = 0, .complete = 3, .cut = 1, .expected = .run_complete_calls },
        .{ .earlier = 1, .complete = 1, .cut = 0, .step_left = false, .expected = .run_complete_calls },
        .{ .earlier = 0, .complete = 0, .cut = 1, .expected = .ask_smaller_steps },
        .{ .earlier = 0, .complete = 0, .cut = 1, .text = true, .expected = .ask_smaller_steps },
        .{ .earlier = 1, .complete = 0, .cut = 1, .expected = .ask_smaller_steps },
        .{ .earlier = 0, .complete = 2, .admitted = false, .cut = 0, .expected = .ask_smaller_steps },
        .{ .earlier = 0, .complete = 2, .admitted = false, .cut = 1, .step_left = false, .expected = .end_turn },
        .{ .earlier = 0, .complete = 0, .cut = 1, .step_left = false, .expected = .end_turn },
        .{ .earlier = 2, .complete = 4, .cut = 1, .expected = .end_turn },
        .{ .earlier = 2, .complete = 0, .cut = 1, .expected = .end_turn },
        .{ .earlier = 0, .complete = 1, .cut = 0, .provider = true, .expected = .end_turn },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, decide(.{
        .earlier_cuts = case.earlier,
        .complete_calls = case.complete,
        .complete_calls_admitted = case.admitted,
        .cut_calls = case.cut,
        .text = case.text,
        .provider_executed = case.provider,
        .step_left = case.step_left,
    }));
}
