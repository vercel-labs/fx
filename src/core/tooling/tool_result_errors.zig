const std = @import("std");
const builtin = @import("builtin");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const DetailValue = union(enum) {
    string: []const u8,
    integer: i64,
    unsigned: u64,
    boolean: bool,
};

pub const Detail = struct {
    name: []const u8,
    value: DetailValue,
};

pub const ExecutionFailure = struct {
    tool_name: []const u8,
    message: []const u8,
    details: []const Detail = &.{},
    suggestion: ?[]const u8 = null,
};

pub const TerminalActionFieldConflict = [2][]const u8;

pub const TerminalActionFieldCorrection = struct {
    action: []const u8,
    invalid_fields: []const []const u8,
    missing_fields: []const []const u8,
    allowed_fields: []const []const u8,
    conflicts: []const TerminalActionFieldConflict,
};

pub const TerminalActionFieldCorrectionView = struct {
    invalid_field_count: usize,
};

const terminal_action_field_error_code = "invalid_action_fields";

pub fn terminalActionFieldCorrectionJson(
    alloc: Allocator,
    correction: TerminalActionFieldCorrection,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(.{ .@"error" = .{
        .code = terminal_action_field_error_code,
        .action = correction.action,
        .invalid_fields = correction.invalid_fields,
        .missing_fields = correction.missing_fields,
        .allowed_fields = correction.allowed_fields,
        .conflicts = correction.conflicts,
    } }, .{}, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn inspectTerminalActionFieldCorrection(
    alloc: Allocator,
    output: []const u8,
) Allocator.Error!?TerminalActionFieldCorrectionView {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        output,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const error_value = switch (root.get("error") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    const code = switch (error_value.get("code") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (std.mem.eql(u8, code, "invalid_shell_request")) {
        const executed = error_value.get("executed") orelse return null;
        if (executed != .bool or executed.bool) return null;
        const problems = error_value.get("problems") orelse return null;
        if (problems != .array or problems.array.items.len == 0) return null;
        for (problems.array.items) |problem| {
            if (problem != .string) return null;
        }
        return .{ .invalid_field_count = problems.array.items.len };
    }
    if (!std.mem.eql(u8, code, terminal_action_field_error_code)) return null;
    const action = error_value.get("action") orelse return null;
    if (action != .string) return null;
    const invalid_fields = switch (error_value.get("invalid_fields") orelse return null) {
        .array => |value| value,
        else => return null,
    };
    return .{
        .invalid_field_count = invalid_fields.items.len,
    };
}

pub const ToolOutputClassification = enum {
    structured_tool_execution_failed,
    active_legacy_tool_failure,
    adapter_semantic_failure,
    non_failure,
};

const adapter_semantic_failure_prefixes = [_][]const u8{
    "Unsupported tool:",
    "read_file failed:",
    "edit_file failed:",
    "open_url not supported",
    "failed to open ",
};

pub fn toolPermissionDeniedJson(alloc: Allocator, tool_name: []const u8, reason: types.ToolPermissionDenialReason) Allocator.Error![]u8 {
    switch (reason) {
        .user_denied, .auto_denied, .policy_denied, .permission_required => {},
        .review_caution, .review_evidence_incomplete, .review_unavailable => unreachable,
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":") catch return error.OutOfMemory;
    std.json.Stringify.value(tool_name, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll(",\"message\":") catch return error.OutOfMemory;
    writeMaskedJsonString(alloc, &out.writer, permissionDeniedMessage(tool_name, reason)) catch return error.OutOfMemory;
    out.writer.writeAll(",\"reason\":") catch return error.OutOfMemory;
    std.json.Stringify.value(@tagName(reason), .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll(",\"denied\":true,\"suggestion\":") catch return error.OutOfMemory;
    writeMaskedJsonString(alloc, &out.writer, permissionDeniedSuggestion(reason)) catch return error.OutOfMemory;
    out.writer.writeAll("}}") catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn toolReviewHeldJson(
    alloc: Allocator,
    tool_name: []const u8,
    reason: types.ToolPermissionDenialReason,
    advice: ?[]const u8,
    review_cause: ?auto_classifier.InvalidReason,
) Allocator.Error![]u8 {
    switch (reason) {
        .review_caution, .review_evidence_incomplete, .review_unavailable => {},
        .user_denied, .auto_denied, .policy_denied, .permission_required => unreachable,
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("{\"error\":{\"type\":\"tool_review_held\",\"tool_name\":") catch
        return error.OutOfMemory;
    std.json.Stringify.value(tool_name, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll(",\"message\":") catch return error.OutOfMemory;
    writeMaskedJsonString(
        alloc,
        &out.writer,
        permissionDeniedMessage(tool_name, reason),
    ) catch return error.OutOfMemory;
    out.writer.writeAll(",\"reason\":") catch return error.OutOfMemory;
    std.json.Stringify.value(@tagName(reason), .{}, &out.writer) catch
        return error.OutOfMemory;
    if (review_cause) |cause| {
        out.writer.writeAll(",\"review_cause\":") catch return error.OutOfMemory;
        std.json.Stringify.value(@tagName(cause), .{}, &out.writer) catch
            return error.OutOfMemory;
    }
    out.writer.writeAll(",\"held\":true") catch return error.OutOfMemory;
    if (advice) |value| {
        if (value.len > 0) {
            out.writer.writeAll(",\"advice\":") catch return error.OutOfMemory;
            writeMaskedJsonString(alloc, &out.writer, value) catch return error.OutOfMemory;
        }
    }
    out.writer.writeAll(",\"suggestion\":") catch return error.OutOfMemory;
    writeMaskedJsonString(
        alloc,
        &out.writer,
        permissionDeniedSuggestion(reason),
    ) catch return error.OutOfMemory;
    out.writer.writeAll("}}") catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn permissionDeniedMessage(tool_name: []const u8, reason: types.ToolPermissionDenialReason) []const u8 {
    return switch (reason) {
        .user_denied => "Permission denied by user",
        .auto_denied => "Blocked by automatic safety policy",
        .review_caution => "Action held after safety review",
        .review_evidence_incomplete => "Safety review evidence incomplete; action held",
        .review_unavailable => "Safety reviewer unavailable; action held",
        .policy_denied => if (is_network_tool(tool_name))
            "Network or browser access was denied by configured policy"
        else
            "Tool access was denied by configured policy",
        .permission_required => if (std.mem.eql(u8, tool_name, "run_command") or
            std.mem.eql(u8, tool_name, "terminal") or
            std.mem.eql(u8, tool_name, "shell"))
            "Shell command approval is required before this tool can run"
        else if (is_network_tool(tool_name))
            "Network or browser approval is required before this tool can run"
        else
            "Tool approval is required before this tool can run",
    };
}

fn permissionDeniedSuggestion(
    reason: types.ToolPermissionDenialReason,
) []const u8 {
    return switch (reason) {
        .user_denied => "The tool did not run. Do not retry unchanged; explain the denial or use a safer allowed alternative.",
        .auto_denied => "The tool did not run. This is a legacy automatic denial; choose a materially different safe action or explain the blocker.",
        .review_caution => "The action did not run. Use the review advice to choose a materially different safe action, or explain why no safe path remains.",
        .review_evidence_incomplete => "The action did not run because safety review could not inspect the complete exact action. Do not retry unchanged; reduce the action or supporting evidence to fit the review limits, or choose a materially different fully inspectable action.",
        .review_unavailable => "The action did not run because safety review was unavailable. Continue with a different safe action or retry later.",
        .policy_denied => "The tool did not run. Do not retry unchanged; explain the configured policy blocker or use an allowed alternative.",
        .permission_required => "The tool did not run. Noninteractive mode cannot show an approval prompt. Rerun interactively to approve, or configure a narrow permission rule before retrying.",
    };
}

fn is_network_tool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_search");
}

pub fn isToolPermissionDeniedOutput(output: []const u8) bool {
    return isToolErrorOutputType(output, "tool_permission_denied");
}

pub fn isToolReviewHeldOutput(output: []const u8) bool {
    return isToolErrorOutputType(output, "tool_review_held");
}

pub fn toolPermissionDenialReason(output: []const u8) ?types.ToolPermissionDenialReason {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, output, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const error_value = switch (root.get("error") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const type_value = switch (error_value.get("type") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const review_held = std.mem.eql(u8, type_value, "tool_review_held");
    if (!review_held and !std.mem.eql(u8, type_value, "tool_permission_denied")) return null;
    const reason_value = switch (error_value.get("reason") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const reason = std.meta.stringToEnum(
        types.ToolPermissionDenialReason,
        reason_value,
    ) orelse return null;
    const review_reason = switch (reason) {
        .review_caution, .review_evidence_incomplete, .review_unavailable => true,
        .user_denied, .auto_denied, .policy_denied, .permission_required => false,
    };
    if (review_held != review_reason) return null;
    return reason;
}

pub fn toolExecutionFailureJson(alloc: Allocator, failure: ExecutionFailure) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.writeAll("{\"error\":{\"type\":\"tool_execution_failed\",\"tool_name\":") catch return error.OutOfMemory;
    writeMaskedJsonString(alloc, &out.writer, failure.tool_name) catch return error.OutOfMemory;
    out.writer.writeAll(",\"message\":") catch return error.OutOfMemory;
    writeMaskedJsonString(alloc, &out.writer, failure.message) catch return error.OutOfMemory;
    if (failure.details.len > 0) {
        out.writer.writeAll(",\"details\":{") catch return error.OutOfMemory;
        for (failure.details, 0..) |detail, i| {
            if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            std.json.Stringify.value(detail.name, .{}, &out.writer) catch return error.OutOfMemory;
            out.writer.writeByte(':') catch return error.OutOfMemory;
            writeDetailValue(alloc, &out.writer, detail.value) catch return error.OutOfMemory;
        }
        out.writer.writeByte('}') catch return error.OutOfMemory;
    }
    if (failure.suggestion) |suggestion| {
        out.writer.writeAll(",\"suggestion\":") catch return error.OutOfMemory;
        writeMaskedJsonString(alloc, &out.writer, suggestion) catch return error.OutOfMemory;
    }
    out.writer.writeAll("}}") catch return error.OutOfMemory;

    return try out.toOwnedSlice();
}

pub fn formatToolExecutionErrorJson(
    alloc: Allocator,
    tool_name: []const u8,
    err: anyerror,
) Allocator.Error![]u8 {
    const details = [_]Detail{
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = executionErrorMessage(err) orelse "Tool execution failed",
        .details = &details,
        .suggestion = executionErrorSuggestion(err),
    });
}

pub fn executionErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.McpInputTimedOut => "MCP elicitation timed out while user input was pending",
        error.McpAuthorityChanged => "MCP configuration or authority changed before execution",
        else => null,
    };
}

pub fn executionErrorSuggestion(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.McpInputTimedOut => "Tell the user the form timed out with input pending, then retry only if they want to complete it again.",
        error.McpAuthorityChanged => "Retry the tool on the next model step so fx can validate it against the current MCP runtime.",
        else => null,
    };
}

pub fn isFilesystemAccessDenied(err: anyerror) bool {
    return err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "PermissionDenied");
}

pub fn filesystemAccessDeniedJson(
    alloc: Allocator,
    tool_name: []const u8,
    path: []const u8,
    err: anyerror,
) Allocator.Error![]u8 {
    const details = [_]Detail{
        .{ .name = "path", .value = .{ .string = path } },
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = "Operating system denied filesystem access",
        .details = &details,
        .suggestion = filesystemAccessDeniedSuggestion(),
    });
}

fn filesystemAccessDeniedSuggestion() []const u8 {
    if (builtin.os.tag == .macos) {
        return "Do not retry this path unchanged or propose a symlink. fx permissions cannot override the operating system. If the path is in a protected folder such as Desktop, Documents, or Downloads, ask the user to grant the terminal app Files and Folders or Full Disk Access. Otherwise, ask the user to correct OS filesystem permissions or move/copy the project to an accessible location.";
    }
    return "Do not retry this path unchanged or propose a symlink. fx permissions cannot override the operating system. Ask the user to correct OS filesystem permissions or move/copy the project to an accessible location.";
}

pub fn malformedToolArgumentsJson(alloc: Allocator, tool_name: []const u8) Allocator.Error![]u8 {
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = "Tool arguments were not valid JSON.",
        .suggestion = "Reissue the tool call with complete valid JSON arguments matching the tool schema.",
    });
}

pub fn nonObjectToolArgumentsJson(alloc: Allocator, tool_name: []const u8) Allocator.Error![]u8 {
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = "Tool arguments must be a JSON object. The call was not executed.",
        .suggestion = "Reissue the tool call with a JSON object matching the tool schema.",
    });
}

pub fn preToolUseBlockedJson(
    alloc: Allocator,
    tool_name: []const u8,
    reason: []const u8,
) Allocator.Error![]u8 {
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = reason,
        .suggestion = "Do not retry the same tool call unchanged. Adjust the request or use an allowed alternative.",
    });
}

pub fn preToolUseFailedClosedJson(
    alloc: Allocator,
    tool_name: []const u8,
) Allocator.Error![]u8 {
    return toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = "Tool use was blocked because a pre-execution lifecycle check failed.",
        .suggestion = "Do not retry unchanged. Adjust the request or try a safer alternative.",
    });
}

pub fn isToolExecutionFailedOutput(output: []const u8) bool {
    return isToolErrorOutputType(output, "tool_execution_failed");
}

pub fn isToolOutputError(output: []const u8) bool {
    return switch (classifyToolOutput(output)) {
        .structured_tool_execution_failed, .active_legacy_tool_failure => true,
        .adapter_semantic_failure, .non_failure => false,
    };
}

pub fn classifyToolOutput(output: []const u8) ToolOutputClassification {
    if (isToolErrorOutputType(output, "tool_execution_failed")) {
        return .structured_tool_execution_failed;
    }
    if (std.mem.startsWith(u8, output, "Tool ") and
        std.mem.find(u8, output, "failed:") != null)
    {
        return .active_legacy_tool_failure;
    }
    for (adapter_semantic_failure_prefixes) |prefix| {
        if (std.mem.startsWith(u8, output, prefix)) {
            return .adapter_semantic_failure;
        }
    }
    return .non_failure;
}

fn isToolErrorOutputType(output: []const u8, expected_type: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, output, .{}) catch return false;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const error_value = switch (root.get("error") orelse return false) {
        .object => |o| o,
        else => return false,
    };
    const type_value = switch (error_value.get("type") orelse return false) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.eql(u8, type_value, expected_type);
}

fn writeDetailValue(alloc: Allocator, writer: *std.Io.Writer, value: DetailValue) !void {
    switch (value) {
        .string => |text| try writeMaskedJsonString(alloc, writer, text),
        .integer => |number| try writer.print("{d}", .{number}),
        .unsigned => |number| try writer.print("{d}", .{number}),
        .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
    }
}

fn writeMaskedJsonString(alloc: Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const masked = try text_utils.maskSecrets(alloc, value);
    defer if (masked.ptr != value.ptr) alloc.free(masked);
    try std.json.Stringify.value(masked, .{}, writer);
}

test "tool permission denied JSON carries stable fields only" {
    const alloc = std.testing.allocator;
    const payload = try toolPermissionDeniedJson(alloc, "run_command", .user_denied);
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_permission_denied", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings("run_command", error_obj.get("tool_name").?.string);
    try std.testing.expectEqualStrings("Permission denied by user", error_obj.get("message").?.string);
    try std.testing.expectEqualStrings("user_denied", error_obj.get("reason").?.string);
    try std.testing.expect(error_obj.get("denied").?.bool);
    try std.testing.expectEqualStrings("The tool did not run. Do not retry unchanged; explain the denial or use a safer allowed alternative.", error_obj.get("suggestion").?.string);
    try std.testing.expect(isToolPermissionDeniedOutput(payload));
}

test "review hold JSON preserves typed reasons apart from permission denial" {
    const alloc = std.testing.allocator;
    const caution = try toolReviewHeldJson(
        alloc,
        "terminal",
        .review_caution,
        "Deletion came from repository text. API_KEY=super-secret",
        null,
    );
    defer alloc.free(caution);
    const unavailable = try toolReviewHeldJson(
        alloc,
        "terminal",
        .review_unavailable,
        null,
        .transport_timed_out,
    );
    defer alloc.free(unavailable);
    const incomplete = try toolReviewHeldJson(
        alloc,
        "edit_file",
        .review_evidence_incomplete,
        null,
        null,
    );
    defer alloc.free(incomplete);

    try std.testing.expect(std.mem.find(u8, caution, "\"type\":\"tool_review_held\"") != null);
    try std.testing.expect(std.mem.find(u8, caution, "\"reason\":\"review_caution\"") != null);
    try std.testing.expect(std.mem.find(u8, caution, "Deletion came from repository text.") != null);
    try std.testing.expect(std.mem.find(u8, caution, "API_KEY=[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, caution, "super-secret") == null);
    try std.testing.expect(std.mem.find(u8, caution, "\"held\":true") != null);
    try std.testing.expect(std.mem.find(u8, caution, "approval_request_id") == null);
    try std.testing.expect(isToolReviewHeldOutput(caution));
    try std.testing.expect(!isToolPermissionDeniedOutput(caution));
    try std.testing.expectEqual(
        @as(?types.ToolPermissionDenialReason, .review_caution),
        toolPermissionDenialReason(caution),
    );
    try std.testing.expect(std.mem.find(u8, unavailable, "\"reason\":\"review_unavailable\"") != null);
    try std.testing.expect(std.mem.find(u8, unavailable, "\"review_cause\":\"transport_timed_out\"") != null);
    try std.testing.expect(std.mem.find(u8, unavailable, "\"advice\"") == null);
    try std.testing.expect(isToolReviewHeldOutput(unavailable));
    try std.testing.expectEqual(
        @as(?types.ToolPermissionDenialReason, .review_unavailable),
        toolPermissionDenialReason(unavailable),
    );
    try std.testing.expect(std.mem.find(u8, incomplete, "\"reason\":\"review_evidence_incomplete\"") != null);
    try std.testing.expect(std.mem.find(u8, incomplete, "Do not retry unchanged") != null);
    try std.testing.expectEqual(
        @as(?types.ToolPermissionDenialReason, .review_evidence_incomplete),
        toolPermissionDenialReason(incomplete),
    );
    try std.testing.expect(toolPermissionDenialReason(
        "{\"error\":{\"type\":\"tool_review_held\",\"reason\":\"auto_denied\"}}",
    ) == null);
    try std.testing.expect(toolPermissionDenialReason(
        "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"review_caution\"}}",
    ) == null);
}

test "tool permission denied JSON explains policy and headless blockers" {
    const alloc = std.testing.allocator;
    const auto_payload = try toolPermissionDeniedJson(alloc, "write_file", .auto_denied);
    defer alloc.free(auto_payload);
    const policy_payload = try toolPermissionDeniedJson(alloc, "web_search", .policy_denied);
    defer alloc.free(policy_payload);
    const headless_payload = try toolPermissionDeniedJson(alloc, "run_command", .permission_required);
    defer alloc.free(headless_payload);
    const web_search_payload = try toolPermissionDeniedJson(alloc, "web_search", .permission_required);
    defer alloc.free(web_search_payload);

    var auto_denied = try std.json.parseFromSlice(std.json.Value, alloc, auto_payload, .{});
    defer auto_denied.deinit();
    var policy = try std.json.parseFromSlice(std.json.Value, alloc, policy_payload, .{});
    defer policy.deinit();
    var headless = try std.json.parseFromSlice(std.json.Value, alloc, headless_payload, .{});
    defer headless.deinit();
    var web_search = try std.json.parseFromSlice(std.json.Value, alloc, web_search_payload, .{});
    defer web_search.deinit();

    const auto_error = auto_denied.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("Blocked by automatic safety policy", auto_error.get("message").?.string);
    try std.testing.expectEqualStrings("auto_denied", auto_error.get("reason").?.string);
    try std.testing.expectEqualStrings(
        "The tool did not run. This is a legacy automatic denial; choose a materially different safe action or explain the blocker.",
        auto_error.get("suggestion").?.string,
    );
    try std.testing.expectEqual(
        types.ToolPermissionDenialReason.auto_denied,
        toolPermissionDenialReason(auto_payload).?,
    );
    try std.testing.expect(toolPermissionDenialReason("not json") == null);
    try std.testing.expect(toolPermissionDenialReason("{\"error\":{\"type\":\"different\",\"reason\":\"auto_denied\"}}") == null);

    const policy_error = policy.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("Network or browser access was denied by configured policy", policy_error.get("message").?.string);
    try std.testing.expectEqualStrings("policy_denied", policy_error.get("reason").?.string);
    try std.testing.expect(std.mem.find(u8, policy_error.get("suggestion").?.string, "The tool did not run.") != null);

    const headless_error = headless.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("Shell command approval is required before this tool can run", headless_error.get("message").?.string);
    try std.testing.expectEqualStrings("The tool did not run. Noninteractive mode cannot show an approval prompt. Rerun interactively to approve, or configure a narrow permission rule before retrying.", headless_error.get("suggestion").?.string);

    const web_search_error = web_search.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("Network or browser approval is required before this tool can run", web_search_error.get("message").?.string);
    try std.testing.expect(std.mem.find(u8, web_search_error.get("suggestion").?.string, "The tool did not run.") != null);
}

test "tool execution failure JSON carries details and masks secrets" {
    const alloc = std.testing.allocator;
    const details = [_]Detail{
        .{ .name = "command", .value = .{ .string = "printf secret" } },
        .{ .name = "exit_code", .value = .{ .integer = 1 } },
        .{ .name = "stderr", .value = .{ .string = "bad AKIA0123456789ABCDEF" } },
    };
    const payload = try toolExecutionFailureJson(alloc, .{
        .tool_name = "run_command",
        .message = "Command exited with non-zero status",
        .details = &details,
        .suggestion = "Inspect stderr and adjust the command.",
    });
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings("run_command", error_obj.get("tool_name").?.string);
    const details_obj = error_obj.get("details").?.object;
    try std.testing.expectEqual(@as(i64, 1), details_obj.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("bad [redacted]", details_obj.get("stderr").?.string);
    try std.testing.expect(std.mem.find(u8, payload, "AKIA0123456789ABCDEF") == null);
    try std.testing.expect(isToolExecutionFailedOutput(payload));
}

test "tool execution error JSON carries the runtime error name" {
    const alloc = std.testing.allocator;
    const payload = try formatToolExecutionErrorJson(
        alloc,
        "read_file",
        error.FileNotFound,
    );
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings("read_file", error_obj.get("tool_name").?.string);
    try std.testing.expectEqualStrings("Tool execution failed", error_obj.get("message").?.string);
    try std.testing.expectEqualStrings("FileNotFound", error_obj.get("details").?.object.get("error").?.string);
}

test "MCP input timeout tells the model that user input was pending" {
    const alloc = std.testing.allocator;
    const payload = try formatToolExecutionErrorJson(
        alloc,
        "mcp_server_tool",
        error.McpInputTimedOut,
    );
    defer alloc.free(payload);

    try std.testing.expect(std.mem.find(u8, payload, "user input was pending") != null);
    try std.testing.expect(std.mem.find(u8, payload, "form timed out with input pending") != null);
}

test "MCP authority change tells the model to retry on the next step" {
    const alloc = std.testing.allocator;
    const payload = try formatToolExecutionErrorJson(
        alloc,
        "mcp_server_tool",
        error.McpAuthorityChanged,
    );
    defer alloc.free(payload);

    try std.testing.expect(std.mem.find(u8, payload, "MCP configuration or authority changed before execution") != null);
    try std.testing.expect(std.mem.find(u8, payload, "next model step") != null);
}

test "filesystem access denial JSON preserves recovery details" {
    const alloc = std.testing.allocator;
    const errors = [_]anyerror{ error.AccessDenied, error.PermissionDenied };

    for (errors) |err| {
        const payload = try filesystemAccessDeniedJson(alloc, "glob_files", "/tmp/blocked", err);
        defer alloc.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
        defer parsed.deinit();

        const error_obj = parsed.value.object.get("error").?.object;
        const details = error_obj.get("details").?.object;
        const suggestion = error_obj.get("suggestion").?.string;
        try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
        try std.testing.expectEqualStrings("glob_files", error_obj.get("tool_name").?.string);
        try std.testing.expectEqualStrings("/tmp/blocked", details.get("path").?.string);
        try std.testing.expectEqualStrings(@errorName(err), details.get("error").?.string);
        try std.testing.expect(std.mem.find(u8, suggestion, "Do not retry") != null);
        try std.testing.expect(std.mem.find(u8, suggestion, "symlink") != null);
        try std.testing.expect(std.mem.find(u8, suggestion, "fx permissions") != null);
        if (builtin.os.tag == .macos) {
            try std.testing.expect(std.mem.find(u8, suggestion, "If the path is in a protected folder") != null);
            try std.testing.expect(std.mem.find(u8, suggestion, "Files and Folders") != null);
        }
        try std.testing.expect(std.mem.find(u8, suggestion, "correct OS filesystem permissions") != null);
        try std.testing.expect(isToolExecutionFailedOutput(payload));
        try std.testing.expect(isToolOutputError(payload));
    }
}

test "isToolOutputError recognizes active tool failure shape" {
    try std.testing.expect(isToolOutputError("Tool read_file failed: file not found"));
    try std.testing.expect(isToolOutputError("{\"error\":{\"type\":\"tool_execution_failed\",\"tool_name\":\"read_file\",\"message\":\"failed\"}}"));
    try std.testing.expect(!isToolOutputError("file content here"));
    try std.testing.expect(!isToolOutputError("Tool result: success"));
}

test "tool output classification preserves structured and legacy categories" {
    try std.testing.expectEqual(
        ToolOutputClassification.structured_tool_execution_failed,
        classifyToolOutput("{\"error\":{\"type\":\"tool_execution_failed\",\"tool_name\":\"read_file\",\"message\":\"failed\"}}"),
    );
    try std.testing.expectEqual(
        ToolOutputClassification.active_legacy_tool_failure,
        classifyToolOutput("Tool read_file failed: file not found"),
    );

    const adapter_failures = [_][]const u8{
        "Unsupported tool: legacy_tool",
        "read_file failed: missing.txt",
        "edit_file failed: old_string not found",
        "open_url not supported on this OS",
        "failed to open https://example.test",
    };
    for (adapter_failures) |output| {
        try std.testing.expectEqual(
            ToolOutputClassification.adapter_semantic_failure,
            classifyToolOutput(output),
        );
        try std.testing.expect(!isToolOutputError(output));
    }

    const non_failures = [_][]const u8{
        "",
        "{",
        "[]",
        "null",
        "{\"error\":\"tool_execution_failed\"}",
        "{\"error\":{\"type\":\"tool_permission_denied\"}}",
        "Tool read_file failed",
        "Tooling read_file failed:",
        "prefix read_file failed: missing.txt",
        "Browser not reachable (snapshot): NoTargetsFound",
        "CDP error: Cannot find context",
        "agent-browser failed to start: FileNotFound",
        "agent-browser exited 2: bad args",
        "agent-browser terminated abnormally",
        "browser operation timed out (snapshot) after 1ms",
        "Navigated to https://example.test",
    };
    for (non_failures) |output| {
        try std.testing.expectEqual(
            ToolOutputClassification.non_failure,
            classifyToolOutput(output),
        );
        try std.testing.expect(!isToolExecutionFailedOutput(output));
        try std.testing.expect(!isToolOutputError(output));
    }
}

test "malformed tool arguments JSON requests a schema-valid retry" {
    const alloc = std.testing.allocator;
    const payload = try malformedToolArgumentsJson(alloc, "ask_user_question");
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_execution_failed", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings("ask_user_question", error_obj.get("tool_name").?.string);
    try std.testing.expect(std.mem.find(u8, error_obj.get("message").?.string, "valid JSON") != null);
    try std.testing.expect(std.mem.find(u8, error_obj.get("suggestion").?.string, "tool schema") != null);
}
