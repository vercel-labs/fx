const std = @import("std");
const types = @import("../shared/types.zig");
const model_capabilities = @import("../config/model_capabilities.zig");

/// Why a personal shortcut preset cannot be applied to the agent on screen.
/// Each refusal leaves the current model, effort, and speed untouched.
pub const Refusal = enum {
    provider_mismatch,
    model_not_in_catalog,
    effort_unsupported,
    fast_unsupported,
};

/// The facts about a preset that the runtime samples before it applies it.
pub const Facts = struct {
    same_provider: bool,
    model_in_catalog: bool,
    effort: types.ReasoningEffort,
    fast_mode: bool,
};

/// Returns the first reason a preset must not be applied, or null when it may.
/// Pure: it reads only its arguments, so a refusal never falls back to a
/// different effort or speed.
pub fn check(facts: Facts, capabilities: model_capabilities.Capabilities) ?Refusal {
    if (!facts.same_provider) return .provider_mismatch;
    if (!facts.model_in_catalog) return .model_not_in_catalog;
    if (!model_capabilities.reasoningEffortSupported(capabilities, facts.effort)) return .effort_unsupported;
    if (facts.fast_mode and !capabilities.supports_fast_mode) return .fast_unsupported;
    return null;
}

test "preset is refused on provider, catalog, effort, or speed mismatch" {
    const high = types.ReasoningEffort.literal("high");
    const efforts = [_]types.ReasoningEffort{high};
    const caps: model_capabilities.Capabilities = .{
        .supports_reasoning = true,
        .reasoning_efforts = .fromSlice(&efforts),
        .supports_fast_mode = true,
    };
    const no_fast: model_capabilities.Capabilities = .{
        .supports_reasoning = true,
        .reasoning_efforts = .fromSlice(&efforts),
    };
    const ok: Facts = .{ .same_provider = true, .model_in_catalog = true, .effort = high, .fast_mode = true };
    try std.testing.expectEqual(@as(?Refusal, null), check(ok, caps));

    var facts = ok;
    facts.same_provider = false;
    try std.testing.expectEqual(@as(?Refusal, .provider_mismatch), check(facts, caps));

    facts = ok;
    facts.model_in_catalog = false;
    try std.testing.expectEqual(@as(?Refusal, .model_not_in_catalog), check(facts, caps));

    facts = ok;
    facts.effort = types.ReasoningEffort.literal("low");
    try std.testing.expectEqual(@as(?Refusal, .effort_unsupported), check(facts, caps));

    try std.testing.expectEqual(@as(?Refusal, .fast_unsupported), check(ok, no_fast));

    facts = ok;
    facts.fast_mode = false;
    try std.testing.expectEqual(@as(?Refusal, null), check(facts, no_fast));
}
