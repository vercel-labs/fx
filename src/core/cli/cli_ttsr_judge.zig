//! The model behind `proto-fx ttsr test --llm` (D253), as proto's
//! `ttsr-cli.ts` loads its judge: an `llm:` condition asks the first of its
//! roles (`tiny`, then `small`, by default) that resolves on the profile's
//! provider, or the profile's own model when none does (D207), with the
//! credential `proto-fx ask` would use. Each answer is one bounded call.
const std = @import("std");
const ttsr = @import("../ttsr/ttsr.zig");
const model_roles = @import("../config/model_roles.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const text_completion = @import("../agent/runtime/text_completion.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const snapshot = @import("../output/ttsr_snapshot.zig");

const Allocator = std.mem.Allocator;

/// Resolves a role to a model on the profile's provider; null when it picks none.
pub const RoleResolver = struct {
    ctx: *const anyopaque,
    pick: *const fn (ctx: *const anyopaque, role: model_roles.Role) ?[]const u8,
};

pub const Binding = struct {
    stream: stream_provider.Provider,
    credential: stream_provider.CredentialLease,
    /// The profile's model on its provider, which answers when no role does.
    session_model: []const u8,
    roles: RoleResolver,
    cancel: std.atomic.Value(bool) = .init(false),
    /// What the judge did, for the report. Strings borrow the resolver's.
    report: snapshot.JudgeReport = .{},

    pub fn completer(self: *Binding) ttsr.judge.Completer {
        return .{ .ctx = self, .complete = complete };
    }
};

/// The model `roles` pick, and the role that picked it; the session's
/// model, with no role, when none of them resolves.
pub fn pickModel(binding: *const Binding, roles: []const []const u8) struct { model: []const u8, role: ?[]const u8 } {
    for (roles) |name| {
        const role = model_roles.Role.parse(name) orelse continue;
        if (binding.roles.pick(binding.roles.ctx, role)) |model| return .{ .model = model, .role = role.label() };
    }
    return .{ .model = binding.session_model, .role = null };
}

fn complete(raw: *anyopaque, alloc: Allocator, roles: []const []const u8, prompt: []const u8) ?[]u8 {
    const self: *Binding = @ptrCast(@alignCast(raw));
    const picked = pickModel(self, roles);
    if (picked.model.len == 0) {
        self.report.unavailable = "no model is set for this provider";
        return null;
    }
    self.report.model = picked.model;
    self.report.role = picked.role;
    self.report.calls += 1;
    const outcome = text_completion.complete(alloc, .{
        .stream_provider = self.stream,
        .credential = self.credential,
        .model = picked.model,
        .retry_count = 1,
        .cancel_flag = &self.cancel,
        .max_output_tokens = 2048,
        .max_bytes = 8 * 1024,
        .trace_ctx = .{},
        .system = "",
        .user = prompt,
    }) catch |err| {
        self.report.unavailable = @errorName(err);
        return null;
    };
    return switch (outcome) {
        .text => |text| blk: {
            self.report.answered += 1;
            break :blk text;
        },
        .failed => |failure| blk: {
            debug_trace.logf("ttsr", "cli judge failed reason={s} {s}", .{ @tagName(failure.reason), failure.detail });
            alloc.free(failure.detail);
            self.report.unavailable = switch (failure.reason) {
                .transport => "the model could not be reached",
                .provider => "the provider refused the request",
                .tool_call => "the model called a tool instead of answering",
                .incomplete => "the model stopped before answering",
                .truncated => "the answer was too long",
            };
            break :blk null;
        },
    };
}

const TestRoles = struct {
    small: ?[]const u8,
    fn pick(raw: *const anyopaque, role: model_roles.Role) ?[]const u8 {
        const self: *const TestRoles = @ptrCast(@alignCast(raw));
        return if (role == .small) self.small else null;
    }
};

test "the judge takes the first role that resolves, else the session's model" {
    var roles: TestRoles = .{ .small = "cento-mini" };
    var binding: Binding = .{
        .stream = undefined,
        .credential = .host_managed,
        .session_model = "claude-cento",
        .roles = .{ .ctx = &roles, .pick = TestRoles.pick },
    };
    const picked = pickModel(&binding, &.{ "tiny", "small" });
    try std.testing.expectEqualStrings("cento-mini", picked.model);
    try std.testing.expectEqualStrings("small", picked.role.?);
    roles.small = null;
    const fallback = pickModel(&binding, &.{ "tiny", "small", "nonsense" });
    try std.testing.expectEqualStrings("claude-cento", fallback.model);
    try std.testing.expect(fallback.role == null);
}
