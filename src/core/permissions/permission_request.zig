const std = @import("std");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_external_scope_tail_bytes =
    file_mutation_contract.max_external_scope_tail_bytes;
pub const max_tool_arguments_preview_bytes = diff_mod.max_encoded_label_bytes;
const max_explanation_bytes: usize = 256;
const max_subagent_origin_bytes: usize = 128;
pub const FileApprovalIntent = file_mutation_contract.FileApprovalIntent;
pub const FileApprovalScope = file_mutation_contract.FileApprovalScope;

pub const FileApprovalRequest = struct {
    kind: file_mutation_contract.Kind,
    intent: FileApprovalIntent,
    preview: diff_mod.FileChangePreview,
    scope: FileApprovalScope,
};

pub const RequestOrigin = union(enum) {
    active_session,
    subagent: []const u8,
};

pub const PermissionRequest = struct {
    id: u64 = 0,
    label: []const u8,
    origin: RequestOrigin = .active_session,
    /// Optional bounded, terminal-safe text displayed as the approval reason.
    explanation: ?[]const u8 = null,
    /// Optional bounded display projection of dynamic tool arguments.
    /// Renderers must still treat these bytes as untrusted terminal input.
    /// Execution must continue to use the original tool call payload.
    tool_arguments_preview: ?[]const u8 = null,
    command: ?[]const u8 = null,
    file: ?FileApprovalRequest = null,
    amendment_allowed: bool = true,
    confirmation_only: bool = false,

    pub fn eql(a: PermissionRequest, b: PermissionRequest) bool {
        if (a.id != b.id) return false;
        if (!std.mem.eql(u8, a.label, b.label)) return false;
        if (!requestOriginEql(a.origin, b.origin)) return false;
        if ((a.explanation == null) != (b.explanation == null)) return false;
        if (a.explanation) |explanation| if (!std.mem.eql(u8, explanation, b.explanation.?)) return false;
        if ((a.tool_arguments_preview == null) != (b.tool_arguments_preview == null)) return false;
        if (a.tool_arguments_preview) |preview| if (!std.mem.eql(u8, preview, b.tool_arguments_preview.?)) return false;
        if ((a.command == null) != (b.command == null)) return false;
        if (a.command) |command| if (!std.mem.eql(u8, command, b.command.?)) return false;
        if (a.amendment_allowed != b.amendment_allowed) return false;
        if (a.confirmation_only != b.confirmation_only) return false;
        if (a.file) |a_file| {
            const b_file = b.file orelse return false;
            return fileApprovalRequestEql(a_file, b_file);
        }
        return b.file == null;
    }
};

test "permission request exposes amendment capability" {
    try std.testing.expect(@hasField(PermissionRequest, "amendment_allowed"));
    try std.testing.expect(@hasField(OwnedPermissionRequest, "amendment_allowed"));
}

test "owned permission request carries an independent explanation" {
    const request: PermissionRequest = .{
        .label = "shell.run touch marker.txt",
        .explanation = "Auto agent couldn’t approve because the action needs review",
    };
    var owned = try OwnedPermissionRequest.dupe(std.testing.allocator, request);
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    try std.testing.expectEqualStrings(request.explanation.?, view.explanation.?);
    try std.testing.expect(request.explanation.?.ptr != view.explanation.?.ptr);
    try std.testing.expect(PermissionRequest.eql(request, view));
}

test "owned permission request carries an independent tool arguments preview" {
    const request: PermissionRequest = .{
        .label = "mcp_fixture_echo",
        .tool_arguments_preview = "{\"text\":\"sentinel\"}",
    };
    var owned = try OwnedPermissionRequest.dupe(std.testing.allocator, request);
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    try std.testing.expectEqualStrings(
        request.tool_arguments_preview.?,
        view.tool_arguments_preview.?,
    );
    try std.testing.expect(
        request.tool_arguments_preview.?.ptr != view.tool_arguments_preview.?.ptr,
    );
    try std.testing.expect(PermissionRequest.eql(request, view));
}

test "owned permission request carries an independent subagent origin" {
    const request: PermissionRequest = .{
        .label = "shell.run touch marker.txt",
        .origin = .{ .subagent = "approval-child" },
    };
    var owned = try OwnedPermissionRequest.dupe(std.testing.allocator, request);
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    switch (view.origin) {
        .active_session => return error.TestExpectedSubagentOrigin,
        .subagent => |child_name| {
            try std.testing.expectEqualStrings("approval-child", child_name);
            try std.testing.expect(
                child_name.ptr != request.origin.subagent.ptr,
            );
        },
    }
    try std.testing.expect(PermissionRequest.eql(request, view));
}

test "permission request bounds the optional explanation" {
    const explanation = try std.testing.allocator.alloc(u8, max_explanation_bytes + 1);
    defer std.testing.allocator.free(explanation);
    @memset(explanation, 'x');

    try std.testing.expectError(
        error.ExplanationTooLong,
        OwnedPermissionRequest.dupe(std.testing.allocator, .{
            .label = "shell.run touch marker.txt",
            .explanation = explanation,
        }),
    );
}

test "permission request bounds the optional tool arguments preview" {
    const preview = try std.testing.allocator.alloc(
        u8,
        max_tool_arguments_preview_bytes + 1,
    );
    defer std.testing.allocator.free(preview);
    @memset(preview, 'x');

    try std.testing.expectError(
        error.ToolArgumentsPreviewTooLong,
        OwnedPermissionRequest.dupe(std.testing.allocator, .{
            .label = "mcp_fixture_echo",
            .tool_arguments_preview = preview,
        }),
    );
}

test "permission request bounds the subagent origin" {
    const child_name = try std.testing.allocator.alloc(u8, 129);
    defer std.testing.allocator.free(child_name);
    @memset(child_name, 'x');

    try std.testing.expectError(
        error.SubagentOriginTooLong,
        OwnedPermissionRequest.dupe(std.testing.allocator, .{
            .label = "shell.run touch marker.txt",
            .origin = .{ .subagent = child_name },
        }),
    );
}

pub const PreviewCloneError = diff_mod.PreviewValidationError || error{
    OutOfMemory,
    RequestProjectionTooLarge,
};

pub const RequestCloneError = PreviewCloneError || error{
    ExplanationTooLong,
    LabelTooLong,
    ScopeProjectionTooLarge,
    SubagentOriginTooLong,
    ToolArgumentsPreviewTooLong,
    RequestIdExhausted,
};

pub const OwnedPermissionRequest = struct {
    id: u64 = 0,
    label: []u8,
    origin: RequestOrigin = .active_session,
    explanation: ?[]u8 = null,
    tool_arguments_preview: ?[]u8 = null,
    command: ?[]u8 = null,
    file: ?FileApprovalRequest = null,
    amendment_allowed: bool = true,
    confirmation_only: bool = false,

    pub fn dupe(
        alloc: Allocator,
        request: PermissionRequest,
    ) RequestCloneError!OwnedPermissionRequest {
        try preflightRequest(request);

        const label = try alloc.dupe(u8, request.label);
        errdefer alloc.free(label);
        const origin = try dupeRequestOrigin(alloc, request.origin);
        errdefer deinitRequestOrigin(alloc, origin);
        const explanation = if (request.explanation) |value| try alloc.dupe(u8, value) else null;
        errdefer if (explanation) |value| alloc.free(value);
        const tool_arguments_preview = if (request.tool_arguments_preview) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (tool_arguments_preview) |value| alloc.free(value);
        const command = if (request.command) |value| try alloc.dupe(u8, value) else null;
        errdefer if (command) |value| alloc.free(value);
        const file = if (request.file) |file_request|
            try dupeFileApprovalRequest(alloc, file_request)
        else
            null;

        return .{
            .id = request.id,
            .label = label,
            .origin = origin,
            .explanation = explanation,
            .tool_arguments_preview = tool_arguments_preview,
            .command = command,
            .file = file,
            .amendment_allowed = request.amendment_allowed,
            .confirmation_only = request.confirmation_only,
        };
    }

    pub fn view(self: *const OwnedPermissionRequest) PermissionRequest {
        return .{
            .id = self.id,
            .label = self.label,
            .origin = self.origin,
            .explanation = self.explanation,
            .tool_arguments_preview = self.tool_arguments_preview,
            .command = self.command,
            .file = self.file,
            .amendment_allowed = self.amendment_allowed,
            .confirmation_only = self.confirmation_only,
        };
    }

    pub fn deinit(self: *OwnedPermissionRequest, alloc: Allocator) void {
        if (self.file) |file_request| {
            deinitFileApprovalRequest(alloc, file_request);
        }
        if (self.command) |command| alloc.free(command);
        if (self.tool_arguments_preview) |preview| alloc.free(preview);
        if (self.explanation) |explanation| alloc.free(explanation);
        deinitRequestOrigin(alloc, self.origin);
        alloc.free(self.label);
        self.* = undefined;
    }
};

fn requestOriginEql(a: RequestOrigin, b: RequestOrigin) bool {
    return switch (a) {
        .active_session => b == .active_session,
        .subagent => |a_name| switch (b) {
            .active_session => false,
            .subagent => |b_name| std.mem.eql(u8, a_name, b_name),
        },
    };
}

fn dupeRequestOrigin(
    alloc: Allocator,
    origin: RequestOrigin,
) error{OutOfMemory}!RequestOrigin {
    return switch (origin) {
        .active_session => .active_session,
        .subagent => |child_name| .{
            .subagent = try alloc.dupe(u8, child_name),
        },
    };
}

fn deinitRequestOrigin(alloc: Allocator, origin: RequestOrigin) void {
    switch (origin) {
        .active_session => {},
        .subagent => |child_name| alloc.free(@constCast(child_name)),
    }
}

pub const OwnedPermissionResponse = struct {
    allocator: Allocator,
    decision: types.ToolPermissionDecision,
    feedback: ?[]u8 = null,

    pub fn init(
        alloc: Allocator,
        decision: types.ToolPermissionDecision,
        feedback: ?[]u8,
    ) OwnedPermissionResponse {
        return .{
            .allocator = alloc,
            .decision = decision,
            .feedback = feedback,
        };
    }

    pub fn deinit(self: *OwnedPermissionResponse) void {
        if (self.feedback) |feedback| self.allocator.free(feedback);
        self.* = undefined;
    }
};

fn checkedConstAdd(comptime a: usize, comptime b: usize) usize {
    return std.math.add(usize, a, b) catch
        @compileError("file permission request capacity overflows usize");
}

fn checkedConstMul(comptime a: usize, comptime b: usize) usize {
    return std.math.mul(usize, a, b) catch
        @compileError("file permission request capacity overflows usize");
}

pub const max_file_request_footprint_bytes = checkedConstAdd(
    checkedConstAdd(
        checkedConstAdd(
            checkedConstAdd(
                checkedConstAdd(
                    checkedConstAdd(
                        checkedConstAdd(
                            checkedConstAdd(
                                @sizeOf(OwnedPermissionRequest),
                                diff_mod.max_encoded_label_bytes,
                            ),
                            max_subagent_origin_bytes,
                        ),
                        max_explanation_bytes,
                    ),
                    max_tool_arguments_preview_bytes,
                ),
                diff_mod.max_encoded_path_bytes,
            ),
            max_external_scope_tail_bytes,
        ),
        checkedConstMul(
            diff_mod.max_preview_lines,
            @sizeOf(diff_mod.PreviewLine),
        ),
    ),
    diff_mod.max_encoded_preview_bytes,
);

pub fn fileRequestFootprint(
    request: PermissionRequest,
) RequestCloneError!usize {
    if (request.label.len > diff_mod.max_encoded_label_bytes) {
        return error.LabelTooLong;
    }
    const file_request = request.file orelse
        return error.RequestProjectionTooLarge;
    try file_request.preview.validate();

    var footprint: usize = @sizeOf(OwnedPermissionRequest);
    footprint = try checkedAddFootprint(footprint, request.label.len);
    footprint = try checkedAddFootprint(footprint, try requestOriginLen(request.origin));
    footprint = try checkedAddFootprint(footprint, try explanationLen(request));
    footprint = try checkedAddFootprint(
        footprint,
        try toolArgumentsPreviewLen(request),
    );
    footprint = try checkedAddFootprint(
        footprint,
        file_request.preview.path.len,
    );
    footprint = try checkedAddFootprint(
        footprint,
        switch (file_request.scope) {
            .workspace_files => 0,
            .external_tree => |root_tail| blk: {
                if (root_tail.len > max_external_scope_tail_bytes) {
                    return error.ScopeProjectionTooLarge;
                }
                break :blk root_tail.len;
            },
        },
    );
    footprint = try checkedAddFootprint(
        footprint,
        std.math.mul(
            usize,
            file_request.preview.lines.len,
            @sizeOf(diff_mod.PreviewLine),
        ) catch return error.RequestProjectionTooLarge,
    );
    for (file_request.preview.lines) |line| {
        footprint = try checkedAddFootprint(footprint, line.text.len);
    }
    if (footprint > max_file_request_footprint_bytes) {
        return error.RequestProjectionTooLarge;
    }
    return footprint;
}

fn checkedAddFootprint(a: usize, b: usize) RequestCloneError!usize {
    return std.math.add(usize, a, b) catch
        error.RequestProjectionTooLarge;
}

fn explanationLen(request: PermissionRequest) RequestCloneError!usize {
    const explanation = request.explanation orelse return 0;
    if (explanation.len > max_explanation_bytes) return error.ExplanationTooLong;
    return explanation.len;
}

fn toolArgumentsPreviewLen(request: PermissionRequest) RequestCloneError!usize {
    const preview = request.tool_arguments_preview orelse return 0;
    if (preview.len > max_tool_arguments_preview_bytes) {
        return error.ToolArgumentsPreviewTooLong;
    }
    return preview.len;
}

fn requestOriginLen(origin: RequestOrigin) RequestCloneError!usize {
    return switch (origin) {
        .active_session => 0,
        .subagent => |child_name| blk: {
            if (child_name.len > max_subagent_origin_bytes) {
                return error.SubagentOriginTooLong;
            }
            break :blk child_name.len;
        },
    };
}

pub fn dupeFileApprovalRequest(
    alloc: Allocator,
    request: FileApprovalRequest,
) RequestCloneError!FileApprovalRequest {
    const preview = try dupePreview(alloc, request.preview);
    errdefer deinitPreview(alloc, preview);
    const scope: FileApprovalScope = switch (request.scope) {
        .workspace_files => .workspace_files,
        .external_tree => |root_tail| .{
            .external_tree = try alloc.dupe(u8, root_tail),
        },
    };
    return .{
        .kind = request.kind,
        .intent = request.intent,
        .preview = preview,
        .scope = scope,
    };
}

pub fn deinitFileApprovalRequest(
    alloc: Allocator,
    request: FileApprovalRequest,
) void {
    deinitPreview(alloc, request.preview);
    switch (request.scope) {
        .workspace_files => {},
        .external_tree => |root_tail| alloc.free(@constCast(root_tail)),
    }
}

fn fileApprovalRequestEql(
    a: FileApprovalRequest,
    b: FileApprovalRequest,
) bool {
    if (a.kind != b.kind or a.intent != b.intent) return false;
    if (!diff_mod.FileChangePreview.eql(a.preview, b.preview)) return false;
    return switch (a.scope) {
        .workspace_files => b.scope == .workspace_files,
        .external_tree => |a_root| switch (b.scope) {
            .workspace_files => false,
            .external_tree => |b_root| std.mem.eql(u8, a_root, b_root),
        },
    };
}

fn dupePreview(
    alloc: Allocator,
    preview: diff_mod.FileChangePreview,
) PreviewCloneError!diff_mod.FileChangePreview {
    _ = try previewProjectionCharge(preview);
    const path = try alloc.dupe(u8, preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(diff_mod.PreviewLine, preview.lines.len);
    errdefer alloc.free(lines);
    var initialized: usize = 0;
    errdefer for (lines[0..initialized]) |line| alloc.free(@constCast(line.text));
    for (preview.lines, lines) |source, *destination| {
        destination.* = source;
        destination.text = try alloc.dupe(u8, source.text);
        initialized += 1;
    }
    return .{
        .path = path,
        .path_basename_start = preview.path_basename_start,
        .path_source_truncated = preview.path_source_truncated,
        .lines = lines,
        .additions = preview.additions,
        .deletions = preview.deletions,
        .truncated = preview.truncated,
    };
}

fn deinitPreview(alloc: Allocator, preview: diff_mod.FileChangePreview) void {
    for (preview.lines) |line| alloc.free(@constCast(line.text));
    alloc.free(@constCast(preview.lines));
    alloc.free(@constCast(preview.path));
}

fn preflightRequest(request: PermissionRequest) RequestCloneError!void {
    if (request.label.len > diff_mod.max_encoded_label_bytes) {
        return error.LabelTooLong;
    }
    if (request.file != null) {
        _ = try fileRequestFootprint(request);
        return;
    }
    var footprint = request.label.len;
    footprint = try checkedAddFootprint(
        footprint,
        try requestOriginLen(request.origin),
    );
    footprint = try checkedAddFootprint(footprint, try explanationLen(request));
    footprint = try checkedAddFootprint(
        footprint,
        try toolArgumentsPreviewLen(request),
    );
    if (footprint > diff_mod.max_request_projection_bytes) {
        return error.RequestProjectionTooLarge;
    }
}

fn previewProjectionCharge(
    preview: diff_mod.FileChangePreview,
) PreviewCloneError!usize {
    try preview.validate();

    var charge = preview.path.len;
    const line_storage = std.math.mul(
        usize,
        @sizeOf(diff_mod.PreviewLine),
        preview.lines.len,
    ) catch return error.RequestProjectionTooLarge;
    charge = std.math.add(usize, charge, line_storage) catch
        return error.RequestProjectionTooLarge;
    for (preview.lines) |line| {
        charge = std.math.add(usize, charge, line.text.len) catch
            return error.RequestProjectionTooLarge;
    }
    if (charge > diff_mod.max_request_projection_bytes) {
        return error.RequestProjectionTooLarge;
    }
    return charge;
}

fn samplePreview() diff_mod.FileChangePreview {
    return .{
        .path = "note.txt",
        .lines = &.{
            .{ .op = .deletion, .old_line = 2, .text = "beta" },
            .{ .op = .addition, .new_line = 2, .text = "BETA" },
        },
        .additions = 1,
        .deletions = 1,
        .truncated = false,
    };
}

fn checkOwnedRequestAllocFailures(alloc: Allocator) !void {
    var owned = try OwnedPermissionRequest.dupe(alloc, .{
        .id = 41,
        .label = "file_mutation",
        .explanation = "Auto agent couldn’t approve because the action needs review",
        .tool_arguments_preview = "{\"text\":\"allocation failure sentinel\"}",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = samplePreview(),
            .scope = .{ .external_tree = "/tmp/project" },
        },
    });
    defer owned.deinit(alloc);
}

test "owned permission request deep copies every byte range" {
    const preview = samplePreview();
    const request: PermissionRequest = .{
        .id = 41,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .equality_disclosure,
            .preview = preview,
            .scope = .{ .external_tree = "/tmp/project" },
        },
    };
    var owned = try OwnedPermissionRequest.dupe(std.testing.allocator, request);
    defer owned.deinit(std.testing.allocator);

    const view = owned.view();
    try std.testing.expectEqual(request.id, view.id);
    try std.testing.expectEqualStrings(request.label, view.label);
    try std.testing.expect(request.label.ptr != view.label.ptr);
    try std.testing.expectEqual(
        file_mutation_contract.Kind.edit,
        view.file.?.kind,
    );
    try std.testing.expectEqual(
        FileApprovalIntent.equality_disclosure,
        view.file.?.intent,
    );
    try std.testing.expect(diff_mod.FileChangePreview.eql(preview, view.file.?.preview));
    try std.testing.expect(preview.path.ptr != view.file.?.preview.path.ptr);
    try std.testing.expect(preview.lines.ptr != view.file.?.preview.lines.ptr);
    for (preview.lines, view.file.?.preview.lines) |source, clone| {
        try std.testing.expect(source.text.ptr != clone.text.ptr);
    }
    try std.testing.expectEqualStrings(
        "/tmp/project",
        view.file.?.scope.external_tree,
    );
    try std.testing.expect(
        request.file.?.scope.external_tree.ptr !=
            view.file.?.scope.external_tree.ptr,
    );
    try std.testing.expect(PermissionRequest.eql(request, view));
}

test "file request footprint counts root and owned backing exactly once" {
    const request: PermissionRequest = .{
        .id = 9,
        .label = "file",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = samplePreview(),
            .scope = .{ .external_tree = "/tmp/project" },
        },
    };
    const expected =
        @sizeOf(OwnedPermissionRequest) +
        request.label.len +
        request.file.?.preview.path.len +
        request.file.?.scope.external_tree.len +
        request.file.?.preview.lines.len * @sizeOf(diff_mod.PreviewLine) +
        request.file.?.preview.lines[0].text.len +
        request.file.?.preview.lines[1].text.len;
    try std.testing.expectEqual(expected, try fileRequestFootprint(request));
}

test "workspace scope has no separately owned backing" {
    const request: PermissionRequest = .{
        .label = "file",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = samplePreview(),
            .scope = .workspace_files,
        },
    };
    const expected =
        @sizeOf(OwnedPermissionRequest) +
        request.label.len +
        request.file.?.preview.path.len +
        request.file.?.preview.lines.len * @sizeOf(diff_mod.PreviewLine) +
        request.file.?.preview.lines[0].text.len +
        request.file.?.preview.lines[1].text.len;
    try std.testing.expectEqual(expected, try fileRequestFootprint(request));
}

test "file request accepts exact component and aggregate capacity" {
    const alloc = std.testing.allocator;
    const label = try alloc.alloc(u8, diff_mod.max_encoded_label_bytes);
    defer alloc.free(label);
    @memset(label, 'l');
    const explanation = try alloc.alloc(u8, max_explanation_bytes);
    defer alloc.free(explanation);
    @memset(explanation, 'e');
    const tool_arguments_preview = try alloc.alloc(
        u8,
        max_tool_arguments_preview_bytes,
    );
    defer alloc.free(tool_arguments_preview);
    @memset(tool_arguments_preview, 'a');
    const origin = try alloc.alloc(u8, max_subagent_origin_bytes);
    defer alloc.free(origin);
    @memset(origin, 'o');
    const path = try alloc.alloc(u8, diff_mod.max_encoded_path_bytes);
    defer alloc.free(path);
    @memset(path, 'p');
    const scope = try alloc.alloc(u8, max_external_scope_tail_bytes);
    defer alloc.free(scope);
    @memset(scope, 's');
    const line_text = try alloc.alloc(u8, diff_mod.max_encoded_line_bytes);
    defer alloc.free(line_text);
    @memset(line_text, 'x');

    const lines = [_]diff_mod.PreviewLine{
        .{ .op = .deletion, .old_line = 1, .text = line_text },
        .{ .op = .addition, .new_line = 1, .text = line_text },
        .{ .op = .deletion, .old_line = 2, .text = line_text },
        .{ .op = .addition, .new_line = 2, .text = line_text },
        .{ .op = .deletion, .old_line = 3, .text = line_text },
        .{ .op = .addition, .new_line = 3, .text = line_text },
    };
    const request: PermissionRequest = .{
        .label = label,
        .origin = .{ .subagent = origin },
        .explanation = explanation,
        .tool_arguments_preview = tool_arguments_preview,
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = path,
                .path_basename_start = path.len - 1,
                .lines = &lines,
                .additions = 3,
                .deletions = 3,
                .truncated = false,
            },
            .scope = .{ .external_tree = scope },
        },
    };

    try std.testing.expectEqual(
        max_file_request_footprint_bytes,
        try fileRequestFootprint(request),
    );
    var owned = try OwnedPermissionRequest.dupe(alloc, request);
    owned.deinit(alloc);
}

test "file request rejects one byte over every owned component boundary" {
    const alloc = std.testing.allocator;
    const over_label = try alloc.alloc(u8, diff_mod.max_encoded_label_bytes + 1);
    defer alloc.free(over_label);
    @memset(over_label, 'l');
    const over_path = try alloc.alloc(u8, diff_mod.max_encoded_path_bytes + 1);
    defer alloc.free(over_path);
    @memset(over_path, 'p');
    const over_scope = try alloc.alloc(u8, max_external_scope_tail_bytes + 1);
    defer alloc.free(over_scope);
    @memset(over_scope, 's');
    const over_line = try alloc.alloc(u8, diff_mod.max_encoded_line_bytes + 1);
    defer alloc.free(over_line);
    @memset(over_line, 'x');

    const base = samplePreview();
    try std.testing.expectError(
        error.LabelTooLong,
        fileRequestFootprint(.{
            .label = over_label,
            .file = .{
                .kind = .write,
                .intent = .mutation,
                .preview = base,
                .scope = .workspace_files,
            },
        }),
    );

    var over_path_preview = base;
    over_path_preview.path = over_path;
    over_path_preview.path_basename_start = over_path.len - 1;
    try std.testing.expectError(
        error.PathTooLong,
        fileRequestFootprint(.{
            .label = "file",
            .file = .{
                .kind = .write,
                .intent = .mutation,
                .preview = over_path_preview,
                .scope = .workspace_files,
            },
        }),
    );

    try std.testing.expectError(
        error.ScopeProjectionTooLarge,
        fileRequestFootprint(.{
            .label = "file",
            .file = .{
                .kind = .write,
                .intent = .mutation,
                .preview = base,
                .scope = .{ .external_tree = over_scope },
            },
        }),
    );

    const lines = [_]diff_mod.PreviewLine{
        .{ .op = .addition, .new_line = 1, .text = over_line },
    };
    var over_line_preview = base;
    over_line_preview.lines = &lines;
    over_line_preview.additions = 1;
    over_line_preview.deletions = 0;
    try std.testing.expectError(
        error.LineTooLong,
        fileRequestFootprint(.{
            .label = "file",
            .file = .{
                .kind = .write,
                .intent = .mutation,
                .preview = over_line_preview,
                .scope = .workspace_files,
            },
        }),
    );
}

test "owned permission request cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOwnedRequestAllocFailures,
        .{},
    );
}
