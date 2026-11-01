//! How fx resends a model request after a transient failure.
//!
//! `src/core/recovery/` decides when to resend. This file decides what the
//! resent request says, from what the failed attempt already delivered: a
//! request that never left, or an answer that broke off before any tool call,
//! resends unchanged, with no word to the model that it was interrupted, and
//! a tool call the model started is regenerated, continued, or reconciled
//! depending on whether it ran. Pure: no I/O, no clock, no allocation.

const std = @import("std");

pub const Delivery = enum {
    definitely_unsent,
    possibly_sent,
};

pub const ToolEvidence = enum {
    none,
    /// The stream started a local tool call that fx never ran.
    proven_unexecuted,
    /// The provider ran the tool and fx admitted its result.
    confirmed,
    /// A tool may have run, and fx cannot prove whether it did.
    uncertain,
};

pub const Strategy = enum {
    retry_request,
    regenerate_tool,
    continue_after_confirmed_tool,
    /// The resent request asks the model to reconcile the tool evidence, and
    /// fx sends it with `tool_choice = none` so no tool can run again.
    reconcile_tool,
};

pub fn select(delivery: Delivery, tool: ToolEvidence) Strategy {
    if (delivery == .definitely_unsent) return .retry_request;
    return switch (tool) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => .retry_request,
    };
}

pub const regenerate_tool_prompt =
    "The previous response ended during an incomplete tool call. fx did not execute that call. Recreate it only if it is still needed.";
pub const continue_after_confirmed_tool_prompt =
    "Continue from the confirmed tool result above without repeating the tool.";
pub const reconcile_tool_prompt =
    "Reconcile the available tool evidence above before continuing. Do not repeat the tool unless the evidence proves it is safe.";

/// The user message the resent request ends with, if the strategy needs one.
pub fn prompt(strategy: Strategy) ?[]const u8 {
    return switch (strategy) {
        .retry_request => null,
        .regenerate_tool => regenerate_tool_prompt,
        .continue_after_confirmed_tool => continue_after_confirmed_tool_prompt,
        .reconcile_tool => reconcile_tool_prompt,
    };
}

test "an unsent request resends unchanged whatever the stream showed" {
    for (std.enums.values(ToolEvidence)) |tool| {
        try std.testing.expectEqual(Strategy.retry_request, select(.definitely_unsent, tool));
    }
}

test "a possibly sent request follows the tool evidence" {
    try std.testing.expectEqual(Strategy.regenerate_tool, select(.possibly_sent, .proven_unexecuted));
    try std.testing.expectEqual(Strategy.continue_after_confirmed_tool, select(.possibly_sent, .confirmed));
    try std.testing.expectEqual(Strategy.reconcile_tool, select(.possibly_sent, .uncertain));
    // A broken-off answer with no tool call is the same request again.
    try std.testing.expectEqual(Strategy.retry_request, select(.possibly_sent, .none));
}

test "only strategies that change the request add a prompt" {
    try std.testing.expect(prompt(.retry_request) == null);
    for ([_]Strategy{ .regenerate_tool, .continue_after_confirmed_tool, .reconcile_tool }) |strategy| {
        try std.testing.expect(prompt(strategy).?.len > 0);
    }
}
