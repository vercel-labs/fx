//! Host-only launch policy reuses native rules and UI without inventing a model tool.
const std = @import("std");
const action_mod = @import("executable_action.zig");
const permissions = @import("permissions.zig");
const request_mod = @import("permission_request.zig");
const session_state = @import("session_permission_state.zig");
const classifier = @import("auto_classifier.zig");
const types = @import("../shared/types.zig");
const admission = @import("../tooling/tool_admission.zig");
const identity_prefix = "fx-native-executable-v1\x00";
const warning = "This executable is not sandboxed. It can access files, use the network, and retain credentials.";
const action_schema = "{\"type\":\"object\",\"required\":[\"extension_id\",\"provider_id\",\"executable_identity\",\"privilege_scope\"],\"additionalProperties\":false,\"properties\":{\"extension_id\":{\"type\":\"string\"},\"provider_id\":{\"type\":\"string\"},\"executable_identity\":{\"type\":\"string\"},\"privilege_scope\":{\"const\":\"unsandboxed_host\"}}}";

/// A non-tool prompt capability keeps native CLI and terminal presentation on their existing routes.
pub const Prompt = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, request_mod.PermissionRequest) anyerror!request_mod.OwnedPermissionResponse,
};

/// Caller owns temporary renderings; cached child authority never outranks a current deny.
pub fn authorize(alloc: std.mem.Allocator, input: admission.Input, action: action_mod.Action, review_turn: classifier.ReviewTurnContext, mode: types.PermissionMode, previous: ?types.PermissionMode, prompt: ?Prompt) !types.PermissionMode {
    if (mode == .yolo) return mode;
    if (review_turn.current_root_request.len == 0) return error.ExtensionRootAuthorityRequired;
    const target = try std.fmt.allocPrint(alloc, "{s}:{s}:{s}", .{ action.extension_id, action.provider_id, action.executable_identity });
    defer alloc.free(target);
    const configured = permissions.ruleDecisionForPermissionPattern(input.permission_rules, action_mod.permission_name, target, .none);
    if (configured == .deny) return error.ExtensionExecutionDenied;
    const encoded = try std.json.Stringify.valueAlloc(alloc, action, .{});
    defer alloc.free(encoded);
    const canonical = try std.mem.concat(alloc, u8, &.{ identity_prefix, encoded });
    defer alloc.free(canonical);
    const key = try session_state.RuleKey.init(.structured_tool, canonical);
    var snapshot: ?session_state.State = null;
    defer if (snapshot) |*value| value.deinit(alloc);
    if (input.session_permission_state_provider) |provider| snapshot = try provider.snapshot(alloc);
    const state = if (snapshot) |*value| value else input.session_permission_state;
    const saved = if (state) |value| session_state.decide(value.*, key) else .unresolved;
    if (saved == .deny) return error.ExtensionExecutionDenied;
    if (configured == .allow or saved == .allow or previous == mode) return mode;
    if (mode == .auto) {
        // An extension key cannot review its own unactivated transport or become a Gateway key.
        const reviewer = if (input.auto_classifier.provider_input.credential_source == .extension_api_key) classifier.Classifier.disabled() else input.auto_classifier;
        const targets = [_]permissions.PermissionCallTarget{.{ .role = "unsandboxed_executable", .path = target }};
        const review_request: classifier.ReviewRequest = .{ .review_turn = review_turn, .targets = &targets, .action = .{ .tool = .{ .tool_name = action_mod.permission_name, .arguments_json = encoded, .schema_json = action_schema, .schema_required = true } } };
        var reviewed = try reviewer.review(alloc, review_request);
        defer reviewed.deinit(alloc);
        return switch (classifier.validatedHostDisposition(review_request, reviewed)) {
            .clear => mode,
            .caution => error.ExtensionExecutionCaution,
            .unavailable => error.ExtensionExecutionAutoReviewUnavailable,
        };
    }
    const label = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ action_mod.label_prefix, target });
    defer alloc.free(label);
    const request: request_mod.PermissionRequest = .{ .label = label, .explanation = warning, .tool_arguments_preview = encoded, .amendment_allowed = false, .confirmation_only = true };
    var response = if (prompt) |transport| try transport.request_fn(transport.context, alloc, request) else try input.worker.requestPermissionBlocking(alloc, request);
    defer response.deinit();
    return switch (response.decision) {
        .once, .always => mode,
        else => error.ExtensionExecutionDenied,
    };
}
